import Foundation

/// Проект — папка встреч. Встреча лежит в одном проекте или ни в одном; теги работают поверх.
public struct MeetingProject: Codable, Equatable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Справочник проектов: `~/Meetings/.projects.json`. У встречи в `meta.json` хранится только id проекта.
public struct ProjectDirectory: Codable, Equatable, Sendable {
    public var schema = 1
    public var projects: [MeetingProject]

    public init(projects: [MeetingProject]) { self.projects = projects }

    public static func url(root: URL) -> URL { root.appending(path: ".projects.json") }

    public static func load(root: URL) -> ProjectDirectory {
        guard let data = try? Data(contentsOf: url(root: root)),
              let dir = try? JSONDecoder().decode(ProjectDirectory.self, from: data) else { return ProjectDirectory(projects: []) }
        return dir
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(root: root), options: .atomic)
    }

    public func project(_ id: UUID?) -> MeetingProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Проекты по алфавиту — так их проще найти в сайдбаре и меню.
    public var sorted: [MeetingProject] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension MeetingStore {
    /// Создать проект. Пустое имя не создаёт ничего.
    @discardableResult
    public func addProject(named name: String) throws -> MeetingProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var dir = ProjectDirectory.load(root: root)
        let project = MeetingProject(name: trimmed)
        dir.projects.append(project)
        try dir.save(root: root)
        return project
    }

    public func renameProject(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var dir = ProjectDirectory.load(root: root)
        guard let i = dir.projects.firstIndex(where: { $0.id == id }) else { return }
        dir.projects[i].name = trimmed
        try dir.save(root: root)
    }

    /// Удалить проект. Встречи остаются, просто без проекта.
    public func deleteProject(_ id: UUID) throws {
        var dir = ProjectDirectory.load(root: root)
        dir.projects.removeAll { $0.id == id }
        try dir.save(root: root)
        for (_, meta) in list() where meta.project == id {
            _ = try update(id: meta.id) { $0.project = nil }
        }
    }

    /// Перенести встречу в проект (`nil` — без проекта).
    public func setProject(_ project: UUID?, meeting: UUID) throws {
        _ = try update(id: meeting) { $0.project = project }
    }

    /// Сколько встреч в каждом проекте.
    public func projectCounts() -> [UUID: Int] {
        var r: [UUID: Int] = [:]
        for (_, m) in list() { if let p = m.project { r[p, default: 0] += 1 } }
        return r
    }
}
