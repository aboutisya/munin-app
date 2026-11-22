import Foundation
import Testing
@testable import MnemosyneCore

struct TranscriptTests {
    /// Сегмент из слов с равномерными таймкодами: по 0,4 с на слово.
    func seg(_ text: String, at start: Double, noSpeech: Double? = nil, logprob: Double? = nil) -> RecognizedSegment {
        let parts = text.split(separator: " ").map(String.init)
        let words = parts.enumerated().map { i, w in Word(text: w, start: start + Double(i) * 0.4, end: start + Double(i) * 0.4 + 0.35) }
        return RecognizedSegment(start: start, end: words.last?.end ?? start, text: text, words: words,
                                 noSpeechProb: noSpeech, avgLogprob: logprob)
    }

    // MARK: - Whisper JSON

    @Test func parsesWhisperJSON() throws {
        let json = """
        {"text": " Привет всем.", "language": "ru", "segments": [
          {"id": 0, "start": 0.0, "end": 1.2, "text": " Привет всем.", "no_speech_prob": 0.01, "avg_logprob": -0.2,
           "words": [{"word": " Привет", "start": 0.0, "end": 0.5, "probability": 0.9},
                     {"word": " всем.", "start": 0.6, "end": 1.2, "probability": 0.8}]}
        ]}
        """
        let (lang, segments) = try WhisperOutput.parse(Data(json.utf8))
        #expect(lang == "ru")
        #expect(segments.count == 1)
        #expect(segments[0].text == "Привет всем.")
        #expect(segments[0].words.map(\.text) == ["Привет", "всем."])
    }

    @Test func parsesVerboseProgress() {
        #expect(WhisperOutput.progressSeconds(fromLine: "[01:23.500 --> 01:27.000]  Текст") == 87)
        #expect(WhisperOutput.progressSeconds(fromLine: "[1:02:03.000 --> 1:02:04.250] x") == 3724.25)
        #expect(WhisperOutput.progressSeconds(fromLine: "Detected language: Russian") == nil)
    }

    // MARK: - Галлюцинации

    @Test(arguments: [
        "Продолжение следует...",
        "Субтитры сделал DimaTorzok",
        "Субтитры создавал DimaTorzok",
        "Корректор А.Кулакова",
        "Спасибо за просмотр!",
        "Музыка",
        "ПОДПИШИСЬ НА КАНАЛ",
        "...",
        "Воспоминание Воспоминание Воспоминание Воспоминание Воспоминание Воспоминание Воспоминание",
        "Да, да, да, да, да, да, да, да",
    ])
    func dropsHallucinations(text: String) {
        #expect(HallucinationFilter.isHallucination(seg(text, at: 0)))
    }

    @Test(arguments: [
        "Продолжение следует обсуждать на следующей неделе, когда будут данные по квотам",
        "Музыка играет у соседей, извините",
        "Спасибо, давайте начнём",
        "Да",
        "Да, да, да, конечно, давайте так и сделаем",
    ])
    func keepsRealSpeech(text: String) {
        #expect(!HallucinationFilter.isHallucination(seg(text, at: 0)))
    }

    @Test func dropsLoopSpreadAcrossSegments() {
        // Каждое «Воспоминание» — отдельный сегмент; вместе они склеиваются в одну реплику.
        let segs = (0..<10).map { seg("Воспоминание", at: Double($0) * 0.5) }
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [TrackInput(role: .me, offset: 0, segments: segs)], mode: .online)
        #expect(t.utterances.isEmpty)
        #expect(t.removedHallucinations == 1)
    }

    @Test func dropsLowConfidenceSilence() {
        #expect(HallucinationFilter.isHallucination(seg("Ну вот", at: 0, noSpeech: 0.95, logprob: -1.5)))
        #expect(!HallucinationFilter.isHallucination(seg("Ну вот", at: 0, noSpeech: 0.95, logprob: -0.3)))
    }

    @Test func keepsOnlyWordsInsideVAD() {
        let words = seg("раз два три четыре", at: 0).words // 0.0, 0.4, 0.8, 1.2
        let kept = HallucinationFilter.keepWordsInSpeech(words, speech: [TimeSpan(0, 0.5)], tolerance: 0)
        #expect(kept.map(\.text) == ["раз", "два"])
        #expect(HallucinationFilter.keepWordsInSpeech(words, speech: []).count == 4)
    }

    // MARK: - Склейка

    @Test func onlineMeetingMergesTracksByTime() {
        let me = TrackInput(role: .me, offset: 0, segments: [seg("Привет, как дела?", at: 1), seg("Отлично, договорились", at: 10)])
        let others = TrackInput(role: .others, offset: 0.5, segments: [seg("Нормально, обсудим квоты", at: 4)],
                                turns: [SpeakerTurn(speaker: "S1", start: 3.5, end: 6)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [me, others], mode: .online)
        #expect(t.utterances.map(\.speaker) == ["me", "others:S1", "me"])
        #expect(t.utterances[1].start == 4.5) // смещение дорожки учтено
        #expect(t.speakers.map(\.label) == ["Я", "Собеседник 1"])
    }

    @Test func diarizationSplitsOthersAndNumbersByAppearance() {
        let others = TrackInput(role: .others, offset: 0, segments: [seg("один два три", at: 0), seg("четыре пять", at: 5)],
                                turns: [SpeakerTurn(speaker: "B", start: 0, end: 2), SpeakerTurn(speaker: "A", start: 4.8, end: 7)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [others], mode: .online)
        #expect(t.utterances.map(\.text) == ["один два три", "четыре пять"])
        #expect(t.speaker("others:B")?.label == "Собеседник 1")
        #expect(t.speaker("others:A")?.label == "Собеседник 2")
    }

    @Test func oneOnOneUsesCalendarName() {
        let me = TrackInput(role: .me, offset: 0, segments: [seg("привет Маша", at: 0)])
        let others = TrackInput(role: .others, offset: 0, segments: [seg("привет", at: 3)],
                                turns: [SpeakerTurn(speaker: "S1", start: 2.5, end: 4)], embeddings: ["S1": [0.1, 0.2]])
        let maria = Person(name: "Мария Смирнова", email: "m@x.ru", status: .accepted)
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [me, others], mode: .online, calendarOthers: [maria])
        let s = t.speaker("others:S1")
        #expect(s?.label == "Мария Смирнова")
        #expect(s?.nameSource == "calendar-1on1")
        #expect(s?.embedding == [0.1, 0.2])
    }

    @Test func pauseWithoutInterruptionKeepsUtterance() {
        // Пауза 4 с, никто не вклинился — одна реплика.
        let me = TrackInput(role: .me, offset: 0, segments: [seg("первая мысль", at: 0), seg("вторая мысль", at: 5)])
        #expect(Merger.merge(meetingId: UUID(), language: "ru", tracks: [me], mode: .online).utterances.count == 1)
        // Длинная пауза — новая реплика.
        let long = TrackInput(role: .me, offset: 0, segments: [seg("первая мысль", at: 0), seg("вторая мысль", at: 20)])
        #expect(Merger.merge(meetingId: UUID(), language: "ru", tracks: [long], mode: .online).utterances.count == 2)
        // Собеседник вклинился — две реплики «Я».
        let others = TrackInput(role: .others, offset: 0, segments: [seg("а можно вопрос", at: 2.5)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [me, others], mode: .online)
        #expect(t.utterances.map(\.speaker) == ["me", "others:S1", "me"])
    }

    @Test func joinsHyphenAndPunctuation() {
        let words = ["раз", "-раз", "так", ",", "это", "-", "тест"].enumerated().map { Word(text: $1, start: Double($0), end: Double($0) + 0.5) }
        #expect(Merger.join(words) == "раз-раз так, это - тест")
    }

    @Test func hybridMicSpeakersAreRoom() {
        let mic = TrackInput(role: .me, offset: 0, segments: [seg("в комнате говорим", at: 0)],
                             turns: [SpeakerTurn(speaker: "S1", start: 0, end: 2)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [mic], mode: .hybrid)
        #expect(t.speakers.first?.label == "В комнате 1")
    }

    // MARK: - Эхо

    @Test func removesEchoOfOthersFromMyTrack() {
        // Собеседник сказал фразу; через 0,3 с она же пришла эхом в мой микрофон.
        let others = TrackInput(role: .others, offset: 0, segments: [seg("давайте перенесём релиз на четверг", at: 10)],
                                turns: [SpeakerTurn(speaker: "S1", start: 9, end: 13)])
        let me = TrackInput(role: .me, offset: 0, segments: [seg("давайте перенесём релиз на четверг", at: 10.3),
                                                             seg("я против переноса", at: 20)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [me, others], mode: .online)
        #expect(t.removedEcho == 1)
        #expect(t.echoRemoved?.first?.text == "давайте перенесём релиз на четверг")
        #expect(t.utterances.filter { $0.speaker == "me" }.map(\.text) == ["я против переноса"])
    }

    @Test func keepsMyReplyEvenIfWordsOverlap() {
        // Я повторяю одно слово собеседника — это не эхо.
        #expect(!EchoDedup.isEcho(mine: ["да", "четверг", "подходит", "мне", "нормально"], theirs: ["перенесём", "на", "четверг"]))
        // Частичное эхо с ошибками распознавания — эхо.
        #expect(EchoDedup.isEcho(mine: ["перенесём", "релиз", "на", "четверк"], theirs: ["давайте", "перенесём", "релиз", "на", "четверг"]))
        // Одно слово не считаем эхом: «да» могли сказать оба.
        #expect(!EchoDedup.isEcho(mine: ["да"], theirs: ["да"]))
    }

    @Test func echoRequiresTimeOverlap() {
        let others = TrackInput(role: .others, offset: 0, segments: [seg("давайте перенесём релиз", at: 10)])
        let me = TrackInput(role: .me, offset: 0, segments: [seg("давайте перенесём релиз", at: 40)])
        let t = Merger.merge(meetingId: UUID(), language: "ru", tracks: [me, others], mode: .online)
        #expect(t.removedEcho == 0)
    }

    // MARK: - Markdown и смещения

    @Test func markdownFormat() {
        var meta = MeetingMeta(title: "Синк", startedAt: Date(timeIntervalSince1970: 1_800_000_000), mode: .online)
        meta.endedAt = meta.startedAt.addingTimeInterval(2640)
        meta.participants = [Person(name: "Мария", status: .accepted), Person(name: "Я", isMe: true)]
        let me = TrackInput(role: .me, offset: 0, segments: [seg("Привет", at: 754)])
        let t = Merger.merge(meetingId: meta.id, language: "ru", tracks: [me], mode: .online)
        let md = TranscriptMarkdown.render(t, meta: meta)
        #expect(md.hasPrefix("# Синк\n"))
        #expect(md.contains("44 мин · Онлайн"))
        #expect(md.contains("Участники: Мария\n"))
        #expect(md.contains("**[00:12:34] Я:** Привет"))
    }

    @Test func trackOffsetsFromHostTime() {
        var meta = MeetingMeta(title: "x", startedAt: Date(), mode: .online)
        meta.tracks = [TrackInfo(role: .others, file: "o", startHostNanos: 5_000_000_000),
                       TrackInfo(role: .me, file: "m", startHostNanos: 5_800_000_000)]
        #expect(meta.trackOffsets[.others] == 0)
        #expect(abs((meta.trackOffsets[.me] ?? 0) - 0.8) < 1e-9)
    }
}
