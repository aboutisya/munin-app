import FluidAudio
import Foundation
import MnemosyneCore

/// Голосовой отпечаток: эмбеддинг голоса из короткой записи (онбординг, «Записать голос заново»).
public enum VoiceEnroller {
    public enum EnrollError: LocalizedError {
        case tooQuiet
        public var errorDescription: String? { "Голос почти не слышно. Говорите ближе к микрофону и запишите ещё раз." }
    }

    /// Эмбеддинг основного голоса в файле. Тот же диаризатор, что и при обработке встреч, — эмбеддинги сравнимы.
    public static func embedding(of audio: URL) async throws -> [Float] {
        let samples = try AudioConverter().resampleAudioFile(audio)
        let wav = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try MeetingProcessor.writeWAV(samples, to: wav)
        let result = try await Task.detached { () throws -> DiarizationResult in
            let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await diarizer.prepareModels()
            return try await diarizer.process(wav)
        }.value
        var talk: [String: Double] = [:]
        for s in result.segments { talk[s.speakerId, default: 0] += Double(s.endTimeSeconds - s.startTimeSeconds) }
        guard let main = talk.max(by: { $0.value < $1.value }), main.value >= 5,
              let e = result.speakerDatabase?[main.key] else { throw EnrollError.tooQuiet }
        return e
    }
}
