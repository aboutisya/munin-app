import Foundation
import Testing
@testable import MnemosyneCore

struct AnalysisTests {
    func transcript() -> Transcript {
        let w = { (t: String, s: Double) in Word(text: t, start: s, end: s + 0.4) }
        return Transcript(
            meetingId: UUID(), language: "ru", createdAt: Date(),
            speakers: [
                TranscriptSpeaker(id: "me", label: "Я", track: .me, nameSource: "me", talkSeconds: 30),
                TranscriptSpeaker(id: "others:S1", label: "Собеседник 1", track: .others, nameSource: "generic", talkSeconds: 60),
                TranscriptSpeaker(id: "me:S1", label: "В комнате 1", track: .me, nameSource: "generic", talkSeconds: 10),
            ],
            utterances: [
                Utterance(speaker: "others:S1", track: .others, start: 4, end: 6, text: "Перенесём релиз?", words: [w("Перенесём", 4)]),
                Utterance(speaker: "me", track: .me, start: 754, end: 756, text: "Нет, это не наша задача", words: [w("Нет", 754)]),
            ],
            removedEcho: 0, removedHallucinations: 0)
    }

    var meta: MeetingMeta {
        var m = MeetingMeta(title: "Синк", startedAt: Date(timeIntervalSince1970: 1_800_000_000), mode: .online)
        m.endedAt = m.startedAt.addingTimeInterval(1800)
        m.participants = [Person(name: "Мария Смирнова", status: .accepted, isOrganizer: true), Person(name: "Я", isMe: true)]
        return m
    }

    var sample: Analysis {
        Analysis(
            schemaVersion: 1, language: "ru",
            participants: .init(count: 2, people: [.init(speaker: "С1", name: "Мария Смирнова", source: ["calendar"], confidence: 0.9)],
                                mentionedNotPresent: ["Олег"]),
            tldr: ["Релиз не переносим"],
            summaryByTopics: [.init(topic: "Релиз", start: "00:00:04", markdown: "- Обсудили перенос")],
            insights: [],
            decisions: [.init(text: "Релиз в четверг", ts: "00:12:40", owner: "")],
            actionItems: [.init(what: "Подготовить сборку", who: "С1", due: "2026-11-26", dueSaid: "к четвергу", ts: "00:12:50"),
                          .init(what: "Записать в задачи", who: "", due: "", dueSaid: "", ts: "00:13:00")],
            diagrams: [],
            sentiment: .init(overall: .init(label: "напряжённая", score: -0.3, evidence: [.init(quote: "Нет, это не наша задача", ts: "00:12:34")]),
                             perParticipant: []),
            conflict: .init(detected: true, kinds: ["зоны ответственности"], summary: "Спор о том, кто готовит релиз.",
                            mySpeechFeedback: [.init(quote: "Нет, это не наша задача", ts: "00:12:34", problem: "Позиционный торг",
                                                     better: "Давай поймём, что нужно к релизу", principle: "interests_not_positions")]))
    }

    @Test func schemaIsValidJSONWithAllFieldsRequired() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(AnalysisSchema.json.utf8)) as! [String: Any]
        let required = obj["required"] as! [String]
        #expect(required.contains("conflict"))
        #expect(required.contains("action_items"))
        #expect(obj["additionalProperties"] as? Bool == false)
    }

    @Test func analysisRoundTripsSnakeCase() throws {
        let data = try Analysis.encoder.encode(sample)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"my_speech_feedback\""))
        #expect(text.contains("\"due_said\""))
        #expect(try Analysis.decoder.decode(Analysis.self, from: data) == sample)
    }

    @Test func speakerCodes() {
        #expect(AnalysisInput.codes(for: transcript()) == ["me": "Я", "others:S1": "С1", "me:S1": "К1"])
    }

    @Test func inputContainsMetaAndCodedTranscript() {
        let input = AnalysisInput.build(meta: meta, transcript: transcript())
        #expect(input.contains("- Название: Синк"))
        #expect(input.contains("- Мария Смирнова, организатор"))
        #expect(input.contains("- Я (это владелец записи, Я)"))
        #expect(input.contains("- С1: Собеседник 1"))
        #expect(input.contains("[00:00:04] С1: Перенесём релиз?"))
        #expect(input.contains("[00:12:34] Я: Нет, это не наша задача"))
    }

    @Test func hashChangesWithSkillModelAndInput() {
        let h = AnalysisInput.hash(input: "a", skillVersion: "1.0.0", model: "sonnet")
        #expect(h == AnalysisInput.hash(input: "a", skillVersion: "1.0.0", model: "sonnet"))
        #expect(h != AnalysisInput.hash(input: "b", skillVersion: "1.0.0", model: "sonnet"))
        #expect(h != AnalysisInput.hash(input: "a", skillVersion: "1.0.1", model: "sonnet"))
        #expect(h != AnalysisInput.hash(input: "a", skillVersion: "1.0.0", model: "opus"))
    }

    @Test func skillVersionFromFrontmatter() {
        let skill = "---\nname: meeting-analysis\nmetadata:\n  version: 1.2.3\n---\n# body"
        #expect(AnalysisInput.skillVersion(skillFile: skill) == "1.2.3")
        #expect(AnalysisInput.skillVersion(skillFile: "# без frontmatter") == "0")
    }

    @Test func parsesCLIResultWithStructuredOutput() throws {
        let json = """
        {"type":"result","is_error":false,"result":"","structured_output":{"tldr":["x"]},"duration_ms":5300,"num_turns":1,
         "usage":{"input_tokens":3,"cache_creation_input_tokens":6000,"cache_read_input_tokens":12000,"output_tokens":800}}
        """
        let r = try ClaudeResult.parse(Data(json.utf8))
        #expect(!r.isError)
        #expect(r.usage?.totalInput == 18003)
        #expect(r.structuredOutput.flatMap { String(data: $0, encoding: .utf8) }?.contains("tldr") == true)
        #expect(!r.isUsageLimit)
    }

    @Test func detectsUsageLimit() throws {
        let a = try ClaudeResult.parse(Data(#"{"is_error":true,"api_error_status":429,"result":"Rate limited"}"#.utf8))
        #expect(a.isUsageLimit)
        let b = try ClaudeResult.parse(Data(#"{"is_error":true,"result":"Claude usage limit reached. Your limit will reset at 3pm (Europe/Moscow)."}"#.utf8))
        #expect(b.isUsageLimit)
        let c = try ClaudeResult.parse(Data(#"{"is_error":true,"result":"Internal error"}"#.utf8))
        #expect(!c.isUsageLimit)
    }

    @Test func parsesResetTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 13, minute: 0))!
        let at3pm = LimitRetry.resetTime(in: "limit will reset at 3pm", now: now, calendar: cal)!
        #expect(cal.component(.hour, from: at3pm) == 15)
        #expect(cal.isDate(at3pm, inSameDayAs: now))
        let at1510 = LimitRetry.resetTime(in: "resets 15:10", now: now, calendar: cal)!
        #expect(cal.component(.minute, from: at1510) == 11) // минута запаса
        // Время уже прошло — значит, завтра.
        let at9am = LimitRetry.resetTime(in: "resets 9am", now: now, calendar: cal)!
        #expect(!cal.isDate(at9am, inSameDayAs: now))
        #expect(LimitRetry.resetTime(in: "resets in 5 hours", now: now, calendar: cal) == nil)
        // Пояс в скобках важнее пояса Mac: 23:00 по Москве = 20:00 по Лондону (UTC+0 в ноябре).
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let msk = LimitRetry.resetTime(in: "limit will reset at 11pm (Europe/Moscow)", now: now, calendar: london)!
        #expect(london.component(.hour, from: msk) == 20)
        #expect(LimitRetry.backoff(attempt: 0) == 900)
        #expect(LimitRetry.backoff(attempt: 1) == 1800)
        #expect(LimitRetry.backoff(attempt: 7) == 3600)
    }

    @Test func personalSummaryRendering() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let md = PersonalSummary.render(sample, meta: meta, transcript: transcript(), calendar: cal)
        #expect(md.contains("## Коротко\n- Релиз не переносим"))
        #expect(md.contains("- [ ] **Мария Смирнова**: Подготовить сборку — до 26 ноября, чт (к четвергу) `00:12:50`"))
        #expect(md.contains("- [ ] Записать в задачи — исполнитель не назван"))
        #expect(md.contains("### Фидбек по моей речи"))
        #expect(md.contains("Принцип: интересы, а не позиции"))
        #expect(md.contains("Упоминали, но не говорили: Олег"))
        var b = sample
        b.decisions = [.init(text: "Релиз в четверг", ts: "00:12:40", owner: "С1")]
        #expect(PersonalSummary.render(b, meta: meta, transcript: transcript(), calendar: cal).contains("Релиз в четверг — Мария Смирнова"))
    }

    /// «Копировать саммари»: то же, что на вкладке, без таймкодов и личного разбора.
    @Test func summaryForCopy() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let md = PersonalSummary.render(sample, meta: meta, transcript: transcript(), calendar: cal, forCopy: true)
        #expect(md.contains("## Коротко\n- Релиз не переносим"))
        #expect(md.contains("- [ ] **Мария Смирнова**: Подготовить сборку — до 26 ноября, чт (к четвергу)\n"))
        #expect(md.contains("## Участники"))
        #expect(!md.contains("`"))
        #expect(!md.contains("## Тональность"))
        #expect(!md.contains("Фидбек по моей речи"))
        #expect(!md.contains("## Диаграммы"))
    }
}

struct AnalysisQueueTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fifoAndDedup() {
        var q = AnalysisQueueState()
        let a = UUID(), b = UUID()
        q.add(a); q.add(b); q.add(a)
        #expect(q.items.map(\.id) == [a, b])
        #expect(q.next(now: now) == a)
        q.remove(a)
        #expect(q.next(now: now) == b)
    }

    @Test func limitPausesWholeQueueWithBackoff() {
        var q = AnalysisQueueState()
        let a = UUID(), b = UUID()
        q.add(a); q.add(b)
        let first = q.hitLimit(on: a, resetAt: nil, now: now)
        #expect(first == now.addingTimeInterval(900))
        #expect(q.next(now: now) == nil)
        #expect(q.waitingUntil == first)
        #expect(q.next(now: first) == a)
        // Второе попадание подряд — 30 минут.
        let second = q.hitLimit(on: a, resetAt: nil, now: first)
        #expect(second == first.addingTimeInterval(1800))
        // Время из ответа CLI важнее бэкоффа.
        let explicit = now.addingTimeInterval(7200)
        #expect(q.hitLimit(on: a, resetAt: explicit, now: now) == explicit)
    }

    @Test func newItemWaitsWithQueueAndRetryNow() {
        var q = AnalysisQueueState()
        let a = UUID(), c = UUID()
        q.add(a)
        let until = q.hitLimit(on: a, resetAt: nil, now: now)
        q.add(c)
        #expect(q.items.last?.notBefore == until)
        q.retryNow()
        #expect(q.next(now: now) == a)
        #expect(q.waitingUntil == nil)
    }

    @Test func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString)/.queue.json")
        var q = AnalysisQueueState()
        q.add(UUID())
        q.hitLimit(on: q.items[0].id, resetAt: nil, now: now)
        try q.save(to: url)
        #expect(AnalysisQueueState.load(from: url) == q)
        #expect(AnalysisQueueState.load(from: url.appending(path: "nope")).items.isEmpty)
    }
}
