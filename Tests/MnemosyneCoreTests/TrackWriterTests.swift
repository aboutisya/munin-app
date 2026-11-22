@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MnemosyneCore

struct TrackWriterTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-tw-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Синусоида заданной длительности в нужном формате.
    private func sine(seconds: Double, rate: Double, channels: AVAudioChannelCount, amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        }
        return buffer
    }

    @Test func expectedFramesMath() {
        #expect(TrackWriter.expectedFrames(startNanos: 0, nowNanos: 1_000_000_000, sampleRate: 48_000) == 48_000)
        #expect(TrackWriter.expectedFrames(startNanos: 5, nowNanos: 1, sampleRate: 48_000) == 0)
    }

    @Test func writesContinuousAudioWithoutPadding() throws {
        let url = dir.appending(path: "a.caf")
        let writer = try TrackWriter(url: url)
        let t0: UInt64 = 10_000_000_000
        for i in 0..<10 {
            writer.write(sine(seconds: 0.1, rate: 48_000, channels: 1), hostNanos: t0 + UInt64(i) * 100_000_000)
        }
        writer.close()
        #expect(writer.paddedSeconds == 0)
        #expect(abs(writer.durationSeconds - 1.0) < 0.001)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.length == 48_000)
    }

    @Test func padsGapWithSilence() throws {
        let writer = try TrackWriter(url: dir.appending(path: "gap.caf"))
        let t0: UInt64 = 1_000_000_000
        writer.write(sine(seconds: 1, rate: 48_000, channels: 1), hostNanos: t0)
        // Источник пропал на 2 секунды (переподключение микрофона).
        writer.write(sine(seconds: 1, rate: 48_000, channels: 1), hostNanos: t0 + 3_000_000_000)
        writer.close()
        #expect(abs(writer.paddedSeconds - 2) < 0.001)
        #expect(abs(writer.durationSeconds - 4) < 0.001)
    }

    @Test func ignoresSmallJitter() throws {
        let writer = try TrackWriter(url: dir.appending(path: "jitter.caf"))
        writer.write(sine(seconds: 1, rate: 48_000, channels: 1), hostNanos: 0)
        writer.write(sine(seconds: 1, rate: 48_000, channels: 1), hostNanos: 1_050_000_000) // +50 мс
        writer.close()
        #expect(writer.paddedSeconds == 0)
    }

    @Test func convertsStereo44kToMono48k() throws {
        let url = dir.appending(path: "conv.caf")
        let writer = try TrackWriter(url: url)
        for i in 0..<5 {
            writer.write(sine(seconds: 0.2, rate: 44_100, channels: 2), hostNanos: UInt64(i) * 200_000_000)
        }
        writer.close()
        #expect(abs(writer.durationSeconds - 1.0) < 0.02)
        #expect(writer.level > 0.1)
    }

    @Test func cafToM4AKeepsDuration() throws {
        let caf = dir.appending(path: "x.caf")
        let writer = try TrackWriter(url: caf)
        writer.write(sine(seconds: 3, rate: 48_000, channels: 1), hostNanos: 0)
        writer.close()

        let m4a = dir.appending(path: "x.m4a")
        try AudioFileConverter.cafToM4A(caf, destination: m4a)
        let duration = try #require(AudioFileConverter.duration(of: m4a))
        #expect(abs(duration - 3) < 0.1)
        let size = try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as! Int
        // ~24 КБ звука + ~60 КБ заголовка m4a; CAF тех же 3 с весит 288 КБ.
        #expect(size < 120_000)
    }

    @Test func finalizeConvertsTracksAndMarksSaved() throws {
        let store = MeetingStore(root: dir.appending(path: "Meetings"))
        var meta = MeetingMeta(title: "Тест", startedAt: Date(), mode: .online)
        let folder = try store.create(meta)
        for name in ["audio_me.caf", "audio_others.caf"] {
            let w = try TrackWriter(url: folder.appending(path: name))
            w.write(sine(seconds: 1, rate: 48_000, channels: 1), hostNanos: 0)
            w.close()
        }
        meta.tracks = [
            TrackInfo(role: .me, file: "audio_me.caf"),
            TrackInfo(role: .others, file: "audio_others.caf"),
        ]
        let saved = try Recorder.finalize(folder: folder, meta: meta, store: store)
        #expect(saved.status == .saved)
        #expect(saved.tracks.map(\.file) == ["audio_me.m4a", "audio_others.m4a"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["audio_me.m4a", "audio_others.m4a", "meta.json"])
        #expect(try store.read(folder).status == .saved)
    }
}
