@preconcurrency import AVFoundation
import Foundation

/// Слепок голоса: 3–5 секунд речи собеседника, чтобы послушать и понять, кто это.
/// Вырезается из аудио встречи; у названных людей копия хранится в `.people/samples/`,
/// поэтому не пропадает, когда аудио встречи удалят по сроку хранения.
public enum VoiceSamples {
    public static let maxSeconds: Double = 5
    public static let minSeconds: Double = 2

    /// Отрезок для слепка: дорожка и время внутри её файла.
    public struct Clip: Sendable, Equatable {
        public var track: TrackInfo.Role
        public var start: Double
        public var duration: Double
    }

    /// Лучшая реплика спикера: длинная и без наложения чужой речи.
    public static func pick(_ t: Transcript, speaker: String, meta: MeetingMeta) -> Clip? {
        let mine = t.utterances.filter { $0.speaker == speaker && $0.end - $0.start >= minSeconds }
        let others = t.utterances.filter { $0.speaker != speaker }
        func score(_ u: Utterance) -> Double {
            let len = min(u.end - u.start, maxSeconds + 1)
            let overlap = others.reduce(0) { $0 + u.span.overlap($1.span) }
            return len - overlap * 3
        }
        guard let best = mine.max(by: { score($0) < score($1) }) else { return nil }
        let offset = meta.trackOffsets[best.track] ?? 0
        let lead = min(0.2, (best.end - best.start) / 10)
        let start = max(0, best.start - offset + lead)
        let duration = min(maxSeconds, best.end - best.start - lead)
        return Clip(track: best.track, start: start, duration: duration)
    }

    /// Вырезать слепок в `target` (m4a). Аудио встречи нет — ошибка.
    public static func export(folder: URL, meta: MeetingMeta, transcript: Transcript, speaker: String, to target: URL) async throws {
        guard let clip = pick(transcript, speaker: speaker, meta: meta),
              let track = meta.track(clip.track) else { throw SampleError.noSpeech }
        let source = folder.appending(path: track.file)
        guard FileManager.default.fileExists(atPath: source.path) else { throw SampleError.noAudio }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SampleError.export
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                        duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
        try await session.export(to: target, as: .m4a)
    }

    /// Огибающая для полоски-волны: `count` значений 0…1.
    public static func envelope(_ url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return [] }
        let n = Int(buffer.frameLength)
        guard n > 0, count > 0 else { return [] }
        let step = max(1, n / count)
        var out: [Float] = []
        for i in 0..<count {
            let from = i * step, to = min(n, from + step)
            guard from < to else { out.append(0); continue }
            var sum: Float = 0
            for j in from..<to { sum += data[j] * data[j] }
            out.append((sum / Float(to - from)).squareRoot())
        }
        let peak = out.max() ?? 0
        // Корень — чтобы тихие слоги тоже было видно, а не только пики.
        return peak > 0 ? out.map { ($0 / peak).squareRoot() } : out
    }

    public enum SampleError: LocalizedError {
        case noSpeech, noAudio, export
        public var errorDescription: String? {
            switch self {
            case .noSpeech: "Нет реплик длиннее двух секунд"
            case .noAudio: "Аудио встречи удалено"
            case .export: "Не удалось вырезать фрагмент"
            }
        }
    }
}
