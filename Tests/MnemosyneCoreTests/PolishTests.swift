import Foundation
import Testing
@testable import MnemosyneCore

struct RetentionTests {
    @Test func deletesOnlyOldAudioAndKeepsText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-ret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let now = Date()
        func make(_ title: String, daysAgo: Double, status: MeetingStatus) throws -> URL {
            var m = MeetingMeta(title: title, startedAt: now.addingTimeInterval(-daysAgo * 86400 - 3600), mode: .online)
            m.endedAt = now.addingTimeInterval(-daysAgo * 86400)
            m.status = status
            let f = try store.create(m)
            try Data("a".utf8).write(to: f.appending(path: "audio_me.m4a"))
            try Data("t".utf8).write(to: f.appending(path: "transcript.md"))
            return f
        }
        let old = try make("Старая", daysAgo: 31, status: .done)
        let fresh = try make("Свежая", daysAgo: 29, status: .done)
        let stuck = try make("Не обработана", daysAgo: 40, status: .saved)

        #expect(AudioRetention.purge(store: store, now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: "audio_me.m4a").path))
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "transcript.md").path))
        #expect(try store.read(old).audioDeletedAt != nil)
        #expect(FileManager.default.fileExists(atPath: fresh.appending(path: "audio_me.m4a").path))
        #expect(FileManager.default.fileExists(atPath: stuck.appending(path: "audio_me.m4a").path))
        // Повторный проход ничего не трогает.
        #expect(AudioRetention.purge(store: store, now: now) == 0)
    }
}

struct TaskListTests {
    let base = AnalysisTests()

    @Test func resolvesNamesAndMine() {
        var a = base.sample
        a.actionItems.append(.init(what: "Сверить квоты", who: "Я", due: "2026-11-24", dueSaid: "", ts: ""))
        a.actionItems.append(.init(what: "Написать Олегу", who: "Илья", due: "", dueSaid: "", ts: ""))
        var meta = base.meta
        TaskList.setDone(true, key: TaskList.key(" Сверить квоты "), in: &meta)
        let items = TaskList.items(from: a, meta: meta, transcript: base.transcript(), myName: "илья")
        #expect(items[0].who == "Мария Смирнова")
        #expect(!items[0].mine)
        #expect(items[1].who == "")
        #expect(items[2].mine && items[2].done)
        #expect(items[3].mine && items[3].who == "Я")
        let order = TaskList.sorted(items).map(\.what)
        #expect(order.prefix(2) == ["Сверить квоты", "Подготовить сборку"])
        TaskList.setDone(false, key: TaskList.key("Сверить квоты"), in: &meta)
        #expect(meta.doneTasks == nil)
    }

    @Test func myVoiceReplacesOld() {
        var p = PeopleDirectory()
        p.setMyVoice(name: "Илья", voice: [1, 0])
        p.setMyVoice(name: "", voice: [0, 1])
        #expect(p.people.count == 1)
        #expect(p.myVoice?.voices == [[0, 1]])
        #expect(p.myVoice?.name == "Илья")
    }
}
