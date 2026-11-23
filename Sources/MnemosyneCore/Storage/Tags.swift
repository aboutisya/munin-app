import Foundation

/// Восемь цветов тега. Конкретные оттенки задаёт интерфейс.
public enum TagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, gray

    public var title: String {
        switch self {
        case .red: "Красный"
        case .orange: "Оранжевый"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .teal: "Бирюзовый"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .gray: "Серый"
        }
    }
}

public struct MeetingTag: Codable, Equatable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var color: TagColor

    public init(id: UUID = UUID(), name: String, color: TagColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// Справочник тегов: `~/Meetings/.tags.json`. У встречи в `meta.json` хранятся только id тегов.
public struct TagDirectory: Codable, Equatable, Sendable {
    public var schema = 1
    public var tags: [MeetingTag]

    public init(tags: [MeetingTag]) { self.tags = tags }

    /// Предустановленные теги. Id постоянные, чтобы не разъехаться до первого сохранения.
    public static let presets: [MeetingTag] = [
        MeetingTag(id: UUID(uuidString: "7A6E0000-0000-4000-8000-000000000001")!, name: "Личное", color: .green),
        MeetingTag(id: UUID(uuidString: "7A6E0000-0000-4000-8000-000000000002")!, name: "Работа", color: .blue),
        MeetingTag(id: UUID(uuidString: "7A6E0000-0000-4000-8000-000000000003")!, name: "Неважное", color: .gray),
    ]

    public static func url(root: URL) -> URL { root.appending(path: ".tags.json") }

    /// Нет файла — предустановленные теги. Файл есть, но пустой список — значит, пользователь удалил все.
    public static func load(root: URL) -> TagDirectory {
        guard let data = try? Data(contentsOf: url(root: root)),
              let dir = try? JSONDecoder().decode(TagDirectory.self, from: data) else { return TagDirectory(tags: presets) }
        return dir
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(root: root), options: .atomic)
    }

    public func tag(_ id: UUID) -> MeetingTag? { tags.first { $0.id == id } }

    /// Теги встречи в порядке справочника; удалённые id пропускаются.
    public func tags(for ids: [UUID]?) -> [MeetingTag] {
        let set = Set(ids ?? [])
        return tags.filter { set.contains($0.id) }
    }

    /// Фильтр «и»: у встречи есть все выбранные теги. Пустой выбор пропускает всё.
    public static func matches(_ ids: [UUID]?, selected: Set<UUID>) -> Bool {
        selected.isSubset(of: Set(ids ?? []))
    }
}

extension MeetingStore {
    /// Удалить тег из справочника и снять его со всех встреч.
    public func deleteTag(_ id: UUID) throws {
        var dir = TagDirectory.load(root: root)
        dir.tags.removeAll { $0.id == id }
        try dir.save(root: root)
        for (_, meta) in list() where meta.tags?.contains(id) == true {
            _ = try update(id: meta.id) { $0.tags?.removeAll { $0 == id } }
        }
    }

    /// Поставить или снять тег у встречи.
    public func setTag(_ tagId: UUID, on: Bool, meeting: UUID) throws {
        _ = try update(id: meeting) { m in
            var list = m.tags ?? []
            if on { if !list.contains(tagId) { list.append(tagId) } } else { list.removeAll { $0 == tagId } }
            m.tags = list.isEmpty ? nil : list
        }
    }

    /// Сколько встреч с каждым тегом.
    public func tagCounts() -> [UUID: Int] {
        var r: [UUID: Int] = [:]
        for (_, m) in list() { for t in m.tags ?? [] { r[t, default: 0] += 1 } }
        return r
    }
}
