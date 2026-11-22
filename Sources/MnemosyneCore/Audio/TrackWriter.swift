@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Пишет одну дорожку в CAF (моно, 48 кГц, 16 бит).
///
/// Принимает буферы любого формата и приводит их к формату файла.
/// Держит дорожку на шкале host time: если источник прервался
/// (переподключение микрофона, пересоздание tap при смене вывода),
/// дописывает тишину, чтобы обе дорожки остались синхронными.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 48_000

    public let url: URL
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var closed = false

    /// Host time (нс) первого записанного сэмпла.
    public private(set) var startHostNanos: UInt64?
    public private(set) var framesWritten: AVAudioFramePosition = 0
    /// Сколько секунд тишины вставлено на месте разрывов.
    public private(set) var paddedSeconds: Double = 0
    /// Последний уровень сигнала (RMS, 0…1) — для «волны» в поповере.
    public private(set) var level: Float = 0
    /// Когда последний раз пришёл буфер (host time, нс). Для сторожа микрофона.
    public var lastWriteNanos: UInt64? { lock.withLock { _lastWriteNanos } }
    private var _lastWriteNanos: UInt64?

    /// Разрыв короче этого порога считаем дрожанием таймера и не заполняем.
    static let gapThreshold: Double = 0.2

    public init(url: URL) throws {
        self.url = url
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: fileSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        format = file.processingFormat
    }

    public var durationSeconds: Double {
        lock.withLock { Double(framesWritten) / Self.sampleRate }
    }

    /// Записать буфер. `hostNanos` — host time первого сэмпла буфера в наносекундах.
    public func write(_ buffer: AVAudioPCMBuffer, hostNanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, buffer.frameLength > 0 else { return }

        guard let converted = convert(buffer) else { return }

        if let start = startHostNanos {
            let expected = Self.expectedFrames(startNanos: start, nowNanos: hostNanos, sampleRate: Self.sampleRate)
            let gap = expected - framesWritten
            if Double(gap) / Self.sampleRate > Self.gapThreshold {
                writeSilence(frames: gap)
                paddedSeconds += Double(gap) / Self.sampleRate
            }
        } else {
            startHostNanos = hostNanos
        }

        do {
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
        } catch {
            Log.audio.error("write \(self.url.lastPathComponent): \(String(describing: error), privacy: .public)")
        }
        level = Self.rms(converted)
        _lastWriteNanos = HostTime.nowNanos
    }

    /// Закрыть файл. После этого `write` игнорируется.
    public func close() {
        lock.withLock {
            closed = true
            file.close()
        }
    }

    // MARK: - Чистые функции (тестируются)

    static func expectedFrames(startNanos: UInt64, nowNanos: UInt64, sampleRate: Double) -> AVAudioFramePosition {
        guard nowNanos > startNanos else { return 0 }
        return AVAudioFramePosition((Double(nowNanos - startNanos) / 1e9 * sampleRate).rounded())
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    // MARK: - private

    private func writeSilence(frames: AVAudioFramePosition) {
        var left = frames
        let chunk: AVAudioFrameCount = 48_000
        while left > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), left))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            silence.frameLength = n // буфер уже обнулён
            do { try file.write(from: silence) } catch { return }
            framesWritten += AVAudioFramePosition(n)
            left -= AVAudioFramePosition(n)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.audio.error("convert: \(String(describing: error), privacy: .public)")
            return nil
        }
        return out
    }
}

public enum HostTime {
    public static func nanos(_ hostTime: UInt64) -> UInt64 { AudioConvertHostTimeToNanos(hostTime) }
    public static var nowNanos: UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
}
