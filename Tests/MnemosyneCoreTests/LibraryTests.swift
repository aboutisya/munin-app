import Foundation
import Testing
@testable import MnemosyneCore

struct LibraryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mnemo-lib-\(UUID().uuidString)")

    func makeMeeting(_ store: MeetingStore, title: String, lines: [(String, String)]) throws -> (URL, MeetingMeta) {
        var meta = MeetingMeta(title: title, startedAt: Date(), mode: .online)
        meta.status = .transcribed
        let folder = try store.create(meta)
        let speakers = [
            TranscriptSpeaker(id: "me", label: "Я", track: .me, nameSource: "me"),
            TranscriptSpeaker(id: "others:S1", label: "Собеседник 1", track: .others, nameSource: "generic", embedding: [0.5, 0.5]),
        ]
        let utterances = lines.enumerated().map { i, l in
            Utterance(speaker: l.0, track: l.0 == "me" ? .me : .others, start: Double(i * 5), end: Double(i * 5 + 3), text: l.1,
                      words: [Word(text: l.1, start: Double(i * 5), end: Double(i * 5 + 3))])
        }
        let t = Transcript(meetingId: meta.id, language: "ru", createdAt: Date(), speakers: speakers, utterances: utterances,
                           removedEcho: 0, removedHallucinations: 0)
        try MeetingProcessorCodec.encoder.encode(t).write(to: folder.appending(path: "transcript.json"))
        return (folder, meta)
    }

    @Test func searchFindsByWordPrefixAndTitle() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let (_, a) = try makeMeeting(store, title: "Синк по квотам", lines: [("me", "Обсудим лимиты экспериментов"), ("others:S1", "Квоты для Лады поднимем")])
        let (_, b) = try makeMeeting(store, title: "Ретро релиза", lines: [("me", "Что пошло не так с релизом")])
        let index = try SearchIndex(url: root.appending(path: ".index.sqlite"))
        index.sync(store: store)

        #expect(index.search("квот").map(\.id) == [a.id])        // префикс: квоты, квотам
        #expect(index.search("ЛАДЫ").map(\.id) == [a.id])        // регистр
        #expect(index.search("релиз").map(\.id) == [b.id])
        #expect(index.search("лимиты экспер").first?.snippet.contains("[") == true)
        #expect(index.search("   ").isEmpty)
        #expect(index.search("несуществующее").isEmpty)
    }

    @Test func syncUpdatesRenamedAndRemovesDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let (folder, meta) = try makeMeeting(store, title: "Без названия", lines: [("me", "привет")])
        let index = try SearchIndex(url: root.appending(path: ".index.sqlite"))
        index.sync(store: store)
        let renamed = try store.rename(folder, to: "Демо для Лады")
        index.sync(store: store)
        #expect(index.search("демо").map(\.id) == [meta.id])
        try FileManager.default.removeItem(at: renamed)
        index.sync(store: store)
        #expect(index.search("демо").isEmpty)
    }

    @Test func renameSpeakerUpdatesTranscriptPeopleAndParticipants() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let (_, meta) = try makeMeeting(store, title: "1:1", lines: [("others:S1", "Привет"), ("me", "Привет, Маша")])
        let editing = MeetingEditing(store: store)
        try editing.renameSpeaker(id: meta.id, speaker: "others:S1", to: "Мария Смирнова", email: "maria@x.ru")

        let folder = store.locate(id: meta.id)!
        let t = editing.transcript(folder)!
        #expect(t.speaker("others:S1")?.label == "Мария Смирнова")
        #expect(t.speaker("others:S1")?.nameSource == "manual")
        let md = try String(contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8)
        #expect(md.contains("Мария Смирнова:** Привет"))
        let people = PeopleDirectory.load(root: root)
        #expect(people.find(name: "мария смирнова", email: nil)?.voices == [[0.5, 0.5]])
        #expect(try store.read(folder).participants?.map(\.name) == ["Мария Смирнова"])

        // Второе переименование того же человека не дублирует участника, голос добавляется.
        try editing.renameSpeaker(id: meta.id, speaker: "others:S1", to: "Мария Смирнова", email: "maria@x.ru")
        #expect(try store.read(folder).participants?.count == 1)
        #expect(PeopleDirectory.load(root: root).people.first?.voices.count == 2)
    }

    @Test func addParticipantAndStaleAnalysis() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let (_, meta) = try makeMeeting(store, title: "Синк", lines: [("me", "привет")])
        let editing = MeetingEditing(store: store)
        try editing.addParticipant(id: meta.id, name: "Ильдар Хасанов")
        try editing.addParticipant(id: meta.id, name: "ильдар хасанов")
        var m = try store.read(store.locate(id: meta.id)!)
        #expect(m.participants?.map(\.name) == ["Ильдар Хасанов"])

        m.analysisContext = m.analysisContextKey
        #expect(!MeetingEditing.analysisIsStale(m))
        m.event = CalendarEventInfo(eventId: "e", start: Date(), end: Date(), title: "Другое")
        #expect(MeetingEditing.analysisIsStale(m))
    }

    @Test func peopleDirectoryKeepsLastVoices() {
        var p = PeopleDirectory()
        for i in 0..<15 { p.remember(name: "Олег", email: nil, voice: [Float(i)]) }
        #expect(p.people.count == 1)
        #expect(p.people[0].voices.count == PeopleDirectory.maxVoices)
        #expect(p.people[0].voices.last == [14])
    }
}
