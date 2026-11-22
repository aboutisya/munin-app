import Foundation
import Testing
@testable import MnemosyneCore

struct StorageTests {
    let root: URL
    let store: MeetingStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-tests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        return f.date(from: s)!
    }

    private var moscow: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    @Test func folderNameFormat() {
        let name = MeetingStore.folderName(title: "Синк по квотам", date: date("2026-11-24T14:30:00+03:00"), calendar: moscow)
        #expect(name == "2026-11-24_1430_Синк по квотам")
    }

    @Test(arguments: [
        ("Синк: квоты / Q1", "Синк квоты Q1"),
        ("  много   пробелов \n и перевод ", "много пробелов и перевод"),
        ("...скрытая", "скрытая"),
        ("a*b?c\"d<e>f|g\\h", "a b c d e f g h"),
        ("", "Без названия"),
        ("///", "Без названия"),
    ])
    func sanitize(input: String, expected: String) {
        #expect(MeetingStore.sanitize(input) == expected)
    }

    @Test func sanitizeLimitsLength() {
        let long = String(repeating: "Очень длинное название ", count: 10)
        let s = MeetingStore.sanitize(long)
        #expect(s.count <= 80)
        #expect(!s.hasSuffix(" "))
    }

    @Test func createReadAndUniqueFolders() throws {
        let meta = MeetingMeta(title: "Демо", startedAt: date("2026-11-22T10:00:00+03:00"), mode: .online)
        let a = try store.create(meta)
        let b = try store.create(MeetingMeta(title: "Демо", startedAt: meta.startedAt, mode: .online))
        #expect(a.lastPathComponent.hasSuffix("_Демо"))
        #expect(b.lastPathComponent.hasSuffix("_Демо (2)"))
        #expect(try store.read(a) == meta)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func renameKeepsIdAndMovesFolder() throws {
        let meta = MeetingMeta(title: "Встреча", startedAt: date("2026-11-22T10:00:00+03:00"), mode: .online)
        let folder = try store.create(meta)
        try Data("x".utf8).write(to: folder.appending(path: "audio_me.m4a"))

        let renamed = try store.rename(folder, to: "Планирование Q1")
        #expect(renamed.lastPathComponent.hasSuffix("_Планирование Q1"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: renamed.appending(path: "audio_me.m4a").path))
        let after = try store.read(renamed)
        #expect(after.id == meta.id)
        #expect(after.title == "Планирование Q1")

        // То же название — папка не меняется и не получает «(2)».
        let same = try store.rename(renamed, to: "Планирование Q1")
        #expect(same.standardizedFileURL == renamed.standardizedFileURL)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func listSortsNewestFirstAndFindsInterrupted() throws {
        var old = MeetingMeta(title: "Старая", startedAt: date("2026-11-20T10:00:00+03:00"), mode: .online)
        old.status = .saved
        let new = MeetingMeta(title: "Новая", startedAt: date("2026-11-22T10:00:00+03:00"), mode: .offline)
        _ = try store.create(old)
        _ = try store.create(new)
        try FileManager.default.createDirectory(at: root.appending(path: ".people"), withIntermediateDirectories: true)

        let list = store.list()
        #expect(list.map(\.meta.title) == ["Новая", "Старая"])
        #expect(store.interrupted().map(\.meta.title) == ["Новая"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func trackOffset() {
        #expect(MeetingMeta.offset(me: 1_000_000_000, others: 1_250_000_000) == 0.25)
        #expect(MeetingMeta.offset(me: 2_000_000_000, others: 1_500_000_000) == -0.5)
        #expect(MeetingMeta.offset(me: nil, others: 1) == nil)
    }
}
