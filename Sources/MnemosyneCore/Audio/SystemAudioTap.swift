@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Захват звука всех приложений, кроме нашего, через Core Audio process tap.
///
/// Tap снимает звук процессов до устройства вывода, поэтому сигнал одинаковый
/// для AirPods, проводных наушников и динамиков. Aggregate device собираем
/// только из tap, без физического устройства: иначе при выводе в AirPods
/// включился бы их микрофон и гарнитура ушла бы в профиль HFP.
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.mnemosyne.tap", qos: .userInitiated)
    private var writer: TrackWriter?

    /// Сколько буферов пришло с ненулевым сигналом. Если за минуту ноль,
    /// скорее всего нет разрешения на звук приложений (tap отдаёт тишину).
    public private(set) var nonSilentBuffers = 0
    public private(set) var totalBuffers = 0

    public init() {}

    public var isRunning: Bool { procID != nil }

    public func start(writer: TrackWriter) throws {
        precondition(procID == nil, "tap уже запущен")
        self.writer = writer

        let excluded = AudioObject.processObject(pid: ProcessInfo.processInfo.processIdentifier)
            .map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Mnemosyne"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var tapFormat = try AudioObject.scalar(
            tapID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &tapFormat) else {
            stop()
            throw CoreAudioError(-1, "unsupported tap format")
        }
        Log.audio.info("tap format: \(format, privacy: .public)")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mnemosyne System Audio",
            kAudioAggregateDeviceUIDKey: "local.mnemosyne.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg),
                      "AudioHardwareCreateAggregateDevice")
        } catch {
            stop()
            throw error
        }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handle(inInputData, time: inInputTime, format: format)
        }
        do {
            try check(status, "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart")
        } catch {
            stop()
            throw error
        }
    }

    /// Пересоздать tap и aggregate device с тем же файлом. Вызывается при смене
    /// устройства вывода: tap, созданный при выводе в динамики, может не видеть звук,
    /// который приложения отправляют в AirPods. Разрыв заполнит тишиной TrackWriter.
    public func restart() throws {
        guard let writer else { return }
        teardown()
        try start(writer: writer)
    }

    public func stop() {
        teardown()
        writer = nil
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        // Дождаться последнего вызова IOProc, прежде чем закрывать файл.
        queue.sync {}
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func handle(_ data: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, format: AVAudioFormat) {
        guard let writer,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: data, deallocator: nil)
        else { return }
        let ts = time.pointee
        let hostNanos = ts.mFlags.contains(.hostTimeValid) ? HostTime.nanos(ts.mHostTime) : HostTime.nowNanos
        writer.write(buffer, hostNanos: hostNanos)
        totalBuffers += 1
        if writer.level > 1e-5 { nonSilentBuffers += 1 }
    }
}
