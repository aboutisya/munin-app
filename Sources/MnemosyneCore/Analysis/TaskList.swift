import Foundation

/// Сквозной список задач из всех проанализированных встреч.
public struct TaskItem: Identifiable, Sendable, Equatable {
    public var id: String { "\(meetingId)#\(key)" }
    public var meetingId: UUID
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
    /// Ключ отметки «выполнено» в `meta.doneTasks`.
    public var key: String { TaskList.key(what) }
}

public enum TaskList {
    public static func key(_ what: String) -> String {
        what.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func items(from a: Analysis, meta: MeetingMeta, transcript: Transcript?, myName: String?) -> [TaskItem] {
        let names = transcript.map { PersonalSummary.speakerNames(a, transcript: $0) } ?? ["Я": "Я"]
        let done = Set(meta.doneTasks ?? [])
        let me = myName?.lowercased().trimmingCharacters(in: .whitespaces)
        return a.actionItems.map { i in
            let raw = i.who.trimmingCharacters(in: .whitespaces)
            let who = names[raw] ?? raw
            let mine = raw == "Я" || who == "Я" || (me?.isEmpty == false && who.lowercased() == me)
            return TaskItem(meetingId: meta.id, meetingTitle: meta.title, meetingDate: meta.startedAt,
                            what: i.what, who: mine ? "Я" : who, mine: mine, due: i.due, dueSaid: i.dueSaid,
                            ts: i.ts, done: done.contains(key(i.what)))
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
}
