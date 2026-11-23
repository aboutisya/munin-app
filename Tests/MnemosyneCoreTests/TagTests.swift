import Foundation
import Testing
@testable import MnemosyneCore

struct TagTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-tags-\(UUID().uuidString)")
    var store: MeetingStore { MeetingStore(root: root) }

    @Test func presetsWhenNoFile() {
        let dir = TagDirectory.load(root: root)
        #expect(dir.tags.map(\.name) == ["Личное", "Работа", "Неважное"])
        // Id постоянные: повторная загрузка без сохранения даёт те же теги.
        #expect(TagDirectory.load(root: root) == dir)
    }

    @Test func emptyListSurvivesReload() throws {
        try TagDirectory(tags: []).save(root: root)
        #expect(TagDirectory.load(root: root).tags.isEmpty)
    }

    @Test func filterIsAnd() {
        let a = UUID(), b = UUID()
        #expect(TagDirectory.matches([a, b], selected: [a, b]))
        #expect(!TagDirectory.matches([a], selected: [a, b]))
        #expect(TagDirectory.matches(nil, selected: []))
        #expect(!TagDirectory.matches(nil, selected: [a]))
    }

    @Test func setAndDeleteTag() throws {
        let work = TagDirectory.presets[1], meh = TagDirectory.presets[2]
        let m = MeetingMeta(title: "Синк", startedAt: Date(), mode: .online)
        _ = try store.create(m)
        try store.setTag(work.id, on: true, meeting: m.id)
        try store.setTag(meh.id, on: true, meeting: m.id)
        try store.setTag(work.id, on: true, meeting: m.id) // повтор не дублирует
        #expect(store.list().first?.meta.tags == [work.id, meh.id])
        #expect(store.tagCounts()[work.id] == 1)

        try store.deleteTag(work.id)
        #expect(store.list().first?.meta.tags == [meh.id])
        #expect(TagDirectory.load(root: root).tag(work.id) == nil)

        try store.setTag(meh.id, on: false, meeting: m.id)
        #expect(store.list().first?.meta.tags == nil)
    }
}
