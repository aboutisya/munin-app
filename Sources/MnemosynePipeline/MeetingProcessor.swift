@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MnemosyneCore

/// Прогресс обработки одной встречи для поповера.
public struct ProcessingProgress: Sendable, Equatable {
    public enum Step: String, Sendable { case prepare, transcribe, diarize, merge }
    public var step: Step
    /// 0…1 по транскрибации (самый долгий шаг).
    public var fraction: Double
    public var diarizationDone: Bool

    public init(step: Step, fraction: Double, diarizationDone: Bool) {
        self.step = step
        self.fraction = fraction
        self.diarizationDone = diarizationDone
    }
}

/// Обработка записанной встречи: VAD → mlx-whisper по дорожкам ‖ диаризация → склейка → transcript.json/md.
/// Работает по UUID встречи, а не по пути: папку могут переименовать во время обработки.
public actor MeetingProcessor {
    public static let sampleRate = 16_000

    private let store: MeetingStore
    private var vad: VadManager?

    public init(store: MeetingStore) {
        self.store = store
    }

    public func process(id: UUID, language: String = "ru", vocabulary: [String] = [],
                        progress: @escaping @Sendable (ProcessingProgress) -> Void) async throws {
        guard let whisper = WhisperRunner() else { throw PipelineError.whisperNotFound }
        guard let folder = store.locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let meta = try store.read(folder)
        let work = store.workDirectory(for: id)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        progress(.init(step: .prepare, fraction: 0, diarizationDone: false))
        try mark(id, step: "transcribe", .running, status: .transcribing)

        // 1. Дорожки → 16 кГц моно, VAD, WAV с заглушённой тишиной для Whisper.
        var prepared: [(info: TrackInfo, samples: [Float], speech: [TimeSpan], wav: URL, clean: URL)] = []
        for track in meta.tracks {
            let source = folder.appending(path: track.file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let samples = try AudioConverter().resampleAudioFile(source)
            guard !samples.isEmpty else { continue }
            let speech = try await speechSpans(samples)
            let clean = work.appending(path: "\(track.role.rawValue).wav")
            try Self.writeWAV(samples, to: clean)
            let muted = work.appending(path: "\(track.role.rawValue)_vad.wav")
            try Self.writeWAV(Self.mute(samples, keeping: speech), to: muted)
            prepared.append((track, samples, speech, muted, clean))
        }
        guard !prepared.isEmpty else { throw PipelineError.noAudio }

        // 2. Диаризация параллельно с распознаванием: она на Neural Engine, Whisper — на GPU.
        let diarizeRoles: [TrackInfo.Role] = switch meta.mode {
        case .online: [.others]
        case .offline: [.me]
        case .hybrid: [.me, .others]
        }
        let toDiarize = prepared.filter { diarizeRoles.contains($0.info.role) }.map { ($0.info.role, $0.clean) }
        // Менеджер создаём внутри задачи: он не Sendable. Модели берутся из кэша на диске.
        let diarization = Task.detached { () throws -> [TrackInfo.Role: DiarizationResult] in
            guard !toDiarize.isEmpty else { return [:] }
            let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await diarizer.prepareModels()
            var result: [TrackInfo.Role: DiarizationResult] = [:]
            for (role, url) in toDiarize { result[role] = try await diarizer.process(url) }
            return result
        }

        // 3. Распознавание дорожек по очереди, чтобы не делить GPU.
        // Язык, заданный у самой встречи (распознать заново на другом языке), важнее настройки.
        let language = meta.language ?? language
        let prompt = Self.prompt(meta: meta, vocabulary: vocabulary, language: language)
        let total = prepared.reduce(0.0) { $0 + Double($1.samples.count) } / Double(Self.sampleRate)
        var done = 0.0
        var recognized: [TrackInfo.Role: [RecognizedSegment]] = [:]
        var detectedLanguage = language
        for track in prepared {
            let base = done
            let json = try await whisper.transcribe(wav: track.wav, outputDir: work, language: language, prompt: prompt) { s in
                progress(.init(step: .transcribe, fraction: min(1, (base + s) / max(total, 1)), diarizationDone: false))
            }
            let parsed = try WhisperOutput.parse(Data(contentsOf: json))
            recognized[track.info.role] = parsed.segments
            if let l = parsed.language { detectedLanguage = l }
            done += Double(track.samples.count) / Double(Self.sampleRate)
        }
        try mark(id, step: "transcribe", .done, status: .diarizing)

        // 4. Ждём диаризацию.
        try mark(id, step: "diarize", .running)
        progress(.init(step: .diarize, fraction: 1, diarizationDone: false))
        let diarized = try await diarization.value
        try mark(id, step: "diarize", .done, status: .merging)

        // 5. Склейка.
        progress(.init(step: .merge, fraction: 1, diarizationDone: true))
        try mark(id, step: "merge", .running)
        let offsets = meta.trackOffsets
        let inputs = prepared.map { track -> TrackInput in
            let d = diarized[track.info.role]
            return TrackInput(
                role: track.info.role,
                offset: offsets[track.info.role] ?? 0,
                segments: recognized[track.info.role] ?? [],
                speech: track.speech,
                turns: d.map { $0.segments.map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) } },
                embeddings: d?.speakerDatabase ?? [:])
        }
        // Свежая meta: название и участники могли поменяться, пока шла обработка.
        let current = try store.read(store.locate(id: id) ?? folder)
        let others = (current.participants ?? []).filter { !$0.isMe }
        var transcript = Merger.merge(meetingId: id, language: detectedLanguage, tracks: inputs,
                                      mode: current.mode, calendarOthers: others)
        // Узнавание по голосу: мой отпечаток и люди из прошлых встреч.
        transcript = VoiceMatcher.apply(transcript, people: PeopleDirectory.load(root: store.root),
                                        invited: current.participants ?? [])
        try write(transcript, id: id)
        try mark(id, step: "merge", .done, status: .transcribed)
        try? FileManager.default.removeItem(at: work)
    }

    /// Перерисовать transcript.md (например, после переименования встречи).
    public func writeMarkdown(id: UUID) throws {
        guard let folder = store.locate(id: id) else { return }
        let data = try Data(contentsOf: folder.appending(path: "transcript.json"))
        let t = try Self.decoder.decode(Transcript.self, from: data)
        let md = TranscriptMarkdown.render(t, meta: try store.read(folder))
        try md.write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - private

    private func write(_ t: Transcript, id: UUID) throws {
        guard let folder = store.locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        try Self.encoder.encode(t).write(to: folder.appending(path: "transcript.json"), options: .atomic)
        let md = TranscriptMarkdown.render(t, meta: try store.read(folder))
        try md.write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    }

    private func mark(_ id: UUID, step: String, _ status: StepState.Status, status meetingStatus: MeetingStatus? = nil) throws {
        try store.update(id: id) { meta in
            var s = meta.steps?[step] ?? StepState(status: .pending)
            s.status = status
            if status == .running { s.startedAt = Date(); s.finishedAt = nil; s.error = nil }
            if status == .done { s.finishedAt = Date() }
            meta.steps = (meta.steps ?? [:]).merging([step: s]) { $1 }
            if let meetingStatus { meta.status = meetingStatus }
        }
    }

    private func speechSpans(_ samples: [Float]) async throws -> [TimeSpan] {
        if vad == nil { vad = try await VadManager() }
        let config = VadSegmentationConfig(minSpeechDuration: 0.2, minSilenceDuration: 0.6, maxSpeechDuration: 30, speechPadding: 0.3)
        return try await vad!.segmentSpeech(samples, config: config).map { TimeSpan($0.startTime, $0.endTime) }
    }

    /// Подсказка для Whisper: имена участников и словарь терминов.
    /// Подсказка Whisper на языке встречи: русская подсказка на английской речи тянет к русскому.
    /// При автоопределении — только имена и термины, без слов какого-либо языка.
    static func prompt(meta: MeetingMeta, vocabulary: [String], language: String = "ru") -> String? {
        let names = (meta.participants ?? []).map(\.displayName).filter { !$0.isEmpty }
        if language == MeetingLanguage.auto {
            let all = names + vocabulary
            return all.isEmpty ? nil : all.joined(separator: ", ") + "."
        }
        let (people, terms) = language == "en" ? ("Participants", "Terms") : ("Участники", "Термины")
        var parts: [String] = []
        if !names.isEmpty { parts.append("\(people): " + names.joined(separator: ", ") + ".") }
        if !vocabulary.isEmpty { parts.append("\(terms): " + vocabulary.joined(separator: ", ") + ".") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Обнулить всё вне отрезков речи: на тишине Whisper сочиняет текст.
    static func mute(_ samples: [Float], keeping speech: [TimeSpan]) -> [Float] {
        guard !speech.isEmpty else { return samples }
        var out = [Float](repeating: 0, count: samples.count)
        for span in speech {
            let a = max(0, Int(span.start * Double(sampleRate)))
            let b = min(samples.count, Int(span.end * Double(sampleRate)))
            if a < b { out.replaceSubrange(a..<b, with: samples[a..<b]) }
        }
        return out
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(sampleRate), AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk = 16_000 * 60
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buf)
            i += n
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
