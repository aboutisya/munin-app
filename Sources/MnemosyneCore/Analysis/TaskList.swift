import Foundation

/// Сквозной список задач: из проанализированных встреч и добавленные вручную.
public struct TaskItem: Identifiable, Sendable, Equatable {
    public var id: String {
        if let meetingId { return "\(meetingId)#\(key)" }
        return "manual#\(manualId?.uuidString ?? key)"
    }
    /// Встреча, из которой задача. `nil` — задача добавлена вручную.
    public var meetingId: UUID?
    public var meetingTitle: String
    public var meetingDate: Date
    public var what: String
    /// Имя исполнителя для показа; пусто — не назван.
    public var who: String
    public var mine: Bool
    /// `ГГГГ-ММ-ДД` или пусто.
    public var due: String
    public var dueSaid: String
    public var ts: String
    public var done: Bool
    /// Ключ задачи во встрече: текст из анализа. По нему хранятся отметка «выполнено» и правки,
    /// поэтому он не меняется, когда задачу переименовали.
    public var key: String
    /// Задачу правили руками.
    public var edited: Bool
    /// Id ручной задачи в `TaskBook`.
    public var manualId: UUID?

    public init(meetingId: UUID?, meetingTitle: String, meetingDate: Date, what: String, who: String, mine: Bool,
                due: String, dueSaid: String = "", ts: String = "", done: Bool, key: String? = nil,
                edited: Bool = false, manualId: UUID? = nil) {
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.what = what
        self.who = who
        self.mine = mine
        self.due = due
        self.dueSaid = dueSaid
        self.ts = ts
        self.done = done
        self.key = key ?? TaskList.key(what)
        self.edited = edited
        self.manualId = manualId
    }

    public var isManual: Bool { meetingId == nil }
}

/// Правка задачи из анализа. Хранится в `meta.json` встречи; сам анализ не трогаем,
/// поэтому правку можно отменить, а повторный анализ её не затирает.
public struct TaskEdit: Codable, Equatable, Sendable {
    public var what: String?
    public var who: String?
    public var due: String?
    public var deleted: Bool?

    public init(what: String? = nil, who: String? = nil, due: String? = nil, deleted: Bool? = nil) {
        self.what = what
        self.who = who
        self.due = due
        self.deleted = deleted
    }
}

/// Задача, добавленная вручную, без встречи.
public struct ManualTask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var what: String
    public var who: String
    public var due: String
    public var done: Bool
    public var created: Date

    public init(id: UUID = UUID(), what: String, who: String, due: String, done: Bool = false, created: Date = Date()) {
        self.id = id
        self.what = what
        self.who = who
        self.due = due
        self.done = done
        self.created = created
    }
}

/// Ручные задачи: `~/Meetings/.tasks.json`, рядом со справочником проектов.
public struct TaskBook: Codable, Equatable, Sendable {
    public var schema = 1
    public var tasks: [ManualTask]

    public init(tasks: [ManualTask] = []) { self.tasks = tasks }

    public static func url(root: URL) -> URL { root.appending(path: ".tasks.json") }

    public static func load(root: URL) -> TaskBook {
        guard let data = try? Data(contentsOf: url(root: root)) else { return TaskBook() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(TaskBook.self, from: data)) ?? TaskBook()
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: Self.url(root: root), options: .atomic)
    }

    /// Изменить ручную задачу по id и сохранить.
    public static func update(root: URL, _ change: (inout TaskBook) -> Void) throws {
        var book = load(root: root)
        change(&book)
        try book.save(root: root)
    }
}

public enum TaskList {
    public static func key(_ what: String) -> String {
        what.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Исполнитель — это я: «Я» или моё имя из настроек.
    public static func isMine(_ who: String, myName: String?) -> Bool {
        let w = who.lowercased().trimmingCharacters(in: .whitespaces)
        let me = myName?.lowercased().trimmingCharacters(in: .whitespaces)
        return w == "я" || (me?.isEmpty == false && w == me)
    }

    public static func items(from a: Analysis, meta: MeetingMeta, transcript: Transcript?, myName: String?) -> [TaskItem] {
        let names = transcript.map { PersonalSummary.speakerNames(a, transcript: $0) } ?? ["Я": "Я"]
        let done = Set(meta.doneTasks ?? [])
        let edits = meta.taskEdits ?? [:]
        return a.actionItems.compactMap { i in
            let k = key(i.what)
            let edit = edits[k]
            if edit?.deleted == true { return nil }
            let raw = i.who.trimmingCharacters(in: .whitespaces)
            let who = edit?.who ?? (names[raw] ?? raw)
            let mine = (edit?.who == nil && raw == "Я") || isMine(who, myName: myName)
            return TaskItem(meetingId: meta.id, meetingTitle: meta.title, meetingDate: meta.startedAt,
                            what: edit?.what ?? i.what, who: mine ? "Я" : who, mine: mine, due: edit?.due ?? i.due,
                            dueSaid: edit?.due == nil ? i.dueSaid : "", ts: i.ts, done: done.contains(k), key: k,
                            edited: edit != nil)
        }
    }

    public static func items(from book: TaskBook, myName: String?) -> [TaskItem] {
        book.tasks.map { t in
            let mine = t.who.isEmpty || isMine(t.who, myName: myName)
            return TaskItem(meetingId: nil, meetingTitle: "", meetingDate: t.created, what: t.what,
                            who: mine ? "Я" : t.who, mine: mine, due: t.due, done: t.done, manualId: t.id)
        }
    }

    /// Порядок: сначала со сроком (раньше — выше), затем без срока по дате встречи (новые выше).
    public static func sorted(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { a, b in
            switch (a.due.isEmpty, b.due.isEmpty) {
            case (false, false): return a.due == b.due ? a.meetingDate > b.meetingDate : a.due < b.due
            case (false, true): return true
            case (true, false): return false
            case (true, true): return a.meetingDate > b.meetingDate
            }
        }
    }

    /// Отметить задачу выполненной или вернуть в работу.
    public static func setDone(_ done: Bool, key: String, in meta: inout MeetingMeta) {
        var set = meta.doneTasks ?? []
        set.removeAll { $0 == key }
        if done { set.append(key) }
        meta.doneTasks = set.isEmpty ? nil : set
    }

    /// Записать правку задачи; `nil` — вернуть как было в анализе.
    public static func setEdit(_ edit: TaskEdit?, key: String, in meta: inout MeetingMeta) {
        var all = meta.taskEdits ?? [:]
        all[key] = edit
        meta.taskEdits = all.isEmpty ? nil : all
    }
}
