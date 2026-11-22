@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Захват микрофона через AVAudioEngine в отдельную дорожку.
///
/// Системный микрофон по умолчанию не трогаем: устройство выставляется только
/// на нашем AUHAL. Voice processing (встроенный AEC Apple) включается только
/// при выводе в динамики, в наушниках он лишь портит тембр.
public final class MicCapture: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var device: AudioDevice?
        public var voiceProcessing: Bool

        public init(device: AudioDevice?, voiceProcessing: Bool) {
            self.device = device
            self.voiceProcessing = voiceProcessing
        }
    }

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var writer: TrackWriter?
    private var startedAt = Date.distantPast

    /// Фактическая конфигурация после запуска.
    public private(set) var active: Config?
    /// Voice processing не запустился на этом устройстве; повторно не пробуем,
    /// пока не сменится вывод. Сбрасывается через `resetVoiceProcessingFailure()`.
    public private(set) var voiceProcessingUnavailable = false

    /// Движок остановился из-за смены конфигурации (устройство пропало, сменился формат).
    /// Уведомления, на которые движок не остановился, сюда не попадают.
    public var onEngineStopped: (@Sendable () -> Void)?

    public init() {}

    public var isRunning: Bool { engine?.isRunning ?? false }

    public func resetVoiceProcessingFailure() { voiceProcessingUnavailable = false }

    /// Пометить VP недоступным (например, движок стартовал, но буферов нет).
    public func markVoiceProcessingUnavailable() { voiceProcessingUnavailable = true }

    public func start(_ config: Config, writer: TrackWriter) throws {
        stop()
        self.writer = writer

        // Порядок попыток: VP на выбранном устройстве → VP на устройстве по умолчанию
        // (только если это то же устройство) → без VP.
        var attempts: [(Config, setDevice: Bool)] = []
        if config.voiceProcessing && !voiceProcessingUnavailable {
            attempts.append((config, true))
            let defaultUID = AudioDevices.defaultInput()?.uid
            if config.device == nil || config.device?.uid == defaultUID {
                attempts.append((config, false))
            }
        }
        attempts.append((Config(device: config.device, voiceProcessing: false), true))

        var lastError: Error?
        for (attempt, setDevice) in attempts {
            do {
                try startEngine(attempt, setDevice: setDevice)
                if config.voiceProcessing && !attempt.voiceProcessing { voiceProcessingUnavailable = true }
                return
            } catch {
                Log.audio.error("mic start failed (vp=\(attempt.voiceProcessing, privacy: .public) setDevice=\(setDevice, privacy: .public)): \(String(describing: error), privacy: .public)")
                lastError = error
                tearDown()
            }
        }
        throw lastError ?? CoreAudioError(-1, "mic")
    }

    public func stop() {
        tearDown()
        writer = nil
        active = nil
    }

    // MARK: - private

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if engine.inputNode.isVoiceProcessingEnabled {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        engine = nil
    }

    private func startEngine(_ config: Config, setDevice: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Для VP выход и микшер должны существовать до включения VP, иначе VPIO
        // не инициализируется (kAUInitialize на outputNode → -10875).
        // Без VP выход не трогаем: иначе вход и выход движка связываются,
        // и микрофон MacBook при выводе в AirPods не выставляется (-10851).
        let mixer: AVAudioMixerNode? = config.voiceProcessing ? engine.mainMixerNode : nil
        if config.voiceProcessing { _ = engine.outputNode.outputFormat(forBus: 0) }

        // Устройство выставляем до VP. Если выставить после, VPIO стартует,
        // но не отдаёт ни одного буфера. С VP и чужим устройством падаем на
        // следующую попытку (VP на устройстве по умолчанию или без VP).
        if setDevice, let device = config.device {
            try Self.setDevice(device.id, on: input)
        }
        if config.voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }

        // После смены устройства outputFormat может остаться от устройства по умолчанию
        // (например, 24 кГц от AirPods), и installTap бросит ObjC-исключение
        // «Input HW format and tap format not matching». Без VP берём формат железа.
        let hw = input.inputFormat(forBus: 0)
        let format = config.voiceProcessing
            ? input.outputFormat(forBus: 0)
            : AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount) ?? hw
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(-1, "микрофон не отдаёт звук (формат \(format))")
        }

        let firstChannelOnly = config.voiceProcessing && format.channelCount > 1
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let writer = self?.writer else { return }
            let hostNanos = when.isHostTimeValid ? HostTime.nanos(when.hostTime) : HostTime.nowNanos
            if firstChannelOnly {
                // У voice processing обработанный голос лежит в канале 0,
                // остальные каналы служебные. Микшировать их нельзя.
                guard let out = Self.channel0(buffer, into: mono) else { return }
                writer.write(out, hostNanos: hostNanos)
            } else {
                writer.write(buffer, hostNanos: hostNanos)
            }
        }

        if config.voiceProcessing {
            // VPIO работает только при запущенном выходе. Громкость нулевая.
            if let mixer {
                engine.connect(input, to: mixer, format: format)
                mixer.outputVolume = 0
            }
        }

        engine.prepare()
        try engine.start()
        startedAt = Date()
        active = config
        Log.audio.info("mic started: \(config.device?.name ?? "default", privacy: .public) vp=\(config.voiceProcessing, privacy: .public) setDevice=\(setDevice, privacy: .public) format=\(format, privacy: .public)")

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            // Смена конфигурации останавливает движок не всегда. Если он встал,
            // сначала пробуем запустить тот же граф: это быстро и сохраняет tap.
            // VPIO при старте сам создаёт служебное устройство и шлёт такое уведомление.
            guard !engine.isRunning else { return }
            do {
                try engine.start()
                Log.audio.info("mic engine restarted in place")
            } catch {
                Log.audio.error("mic engine stopped: \(String(describing: error), privacy: .public)")
                self?.onEngineStopped?()
            }
        }
    }

    private static func setDevice(_ id: AudioObjectID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw CoreAudioError(-1, "нет audio unit у входа") }
        var device = id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioObjectID>.size)),
                  "set input device \(id)")
    }

    private static func channel0(_ buffer: AVAudioPCMBuffer, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData?[0],
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        dst.update(from: src, count: Int(buffer.frameLength))
        return out
    }
}
