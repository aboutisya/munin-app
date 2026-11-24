import Foundation
import Testing
@testable import MnemosyneCore

struct ProjectTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-projects-\(UUID().uuidString)")
    var store: MeetingStore { MeetingStore(root: root) }

    @Test func emptyWhenNoFile() {
        #expect(ProjectDirectory.load(root: root).projects.isEmpty)
    }

    @Test func addRenameSorted() throws {
        #expect(try store.addProject(named: "   ") == nil)
        let b = try #require(try store.addProject(named: " Альфа "))
        _ = try store.addProject(named: "Мунин")
        _ = try store.addProject(named: "Ава")
        #expect(b.name == "Альфа")
        try store.renameProject(b.id, to: "Ярус")
        try store.renameProject(b.id, to: "  ") // пустое имя не применяется
        #expect(ProjectDirectory.load(root: root).sorted.map(\.name) == ["Ава", "Мунин", "Ярус"])
    }

    @Test func moveAndDelete() throws {
        let p = try #require(try store.addProject(named: "Альфа"))
        let m = MeetingMeta(title: "Синк", startedAt: Date(), mode: .online)
        let other = MeetingMeta(title: "Другая", startedAt: Date().addingTimeInterval(-3600), mode: .online)
        _ = try store.create(m)
        _ = try store.create(other)
        try store.setProject(p.id, meeting: m.id)
        #expect(store.projectCounts()[p.id] == 1)

        // Удаление проекта не трогает встречи, только снимает с них проект.
        try store.deleteProject(p.id)
        #expect(store.list().count == 2)
        #expect(store.list().allSatisfy { $0.meta.project == nil })
        #expect(ProjectDirectory.load(root: root).project(p.id) == nil)
    }

    @Test func oldMetaDecodesWithoutProject() throws {
        let m = MeetingMeta(title: "Старая", startedAt: Date(), mode: .online)
        let folder = try store.create(m)
        #expect(try store.read(folder).project == nil)
    }
}
