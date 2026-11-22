import Foundation

/// Участник встречи. Источник — календарь, позже — ручное добавление и голоса.
public struct Person: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case accepted, declined, tentative, pending, unknown }

    public var name: String
    public var email: String?
    public var status: Status
    public var isMe: Bool
    public var isOrganizer: Bool

    public init(name: String, email: String? = nil, status: Status = .unknown, isMe: Bool = false, isOrganizer: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.isMe = isMe
        self.isOrganizer = isOrganizer
    }

    /// Имя для показа: «Мария Смирнова», а если имени нет — часть email до @.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.contains("@") { return trimmed }
        if let email, let local = email.split(separator: "@").first { return String(local) }
        return trimmed.isEmpty ? "Без имени" : trimmed
    }
}

/// Снимок события календаря на момент привязки. Хранится в `meta.json`,
/// чтобы карточка встречи не зависела от того, что событие потом удалят.
public struct CalendarEventInfo: Codable, Hashable, Sendable, Identifiable {
    /// `EKEvent.eventIdentifier`. У повторяющихся событий общий для серии.
    public var eventId: String
    /// Начало конкретного вхождения: вместе с `eventId` однозначно задаёт встречу.
    public var start: Date
    public var end: Date
    public var title: String
    public var calendar: String?
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var callURL: String?
    public var organizer: Person?
    public var attendees: [Person]
    /// Мой статус: отклонённые события не предлагаем.
    public var myStatus: Person.Status?

    public var id: String { "\(eventId)@\(Int(start.timeIntervalSince1970))" }

    public init(eventId: String, start: Date, end: Date, title: String, calendar: String? = nil,
                isAllDay: Bool = false, location: String? = nil, notes: String? = nil, callURL: String? = nil,
                organizer: Person? = nil, attendees: [Person] = [], myStatus: Person.Status? = nil) {
        self.eventId = eventId
        self.start = start
        self.end = end
        self.title = title
        self.calendar = calendar
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.callURL = callURL
        self.organizer = organizer
        self.attendees = attendees
        self.myStatus = myStatus
    }

    /// Другие участники, кроме меня. Отклонившие не считаются.
    public var others: [Person] {
        attendees.filter { !$0.isMe && $0.status != .declined }
    }

    /// Участники для `meta.json`: организатор и приглашённые без дублей, отклонившие убраны.
    public var participants: [Person] {
        var result: [Person] = []
        var seen = Set<String>()
        for p in ([organizer].compactMap { $0 } + attendees) where p.status != .declined {
            let key = (p.email ?? p.name).lowercased()
            guard seen.insert(key).inserted else {
                if p.isOrganizer, let i = result.firstIndex(where: { ($0.email ?? $0.name).lowercased() == key }) {
                    result[i].isOrganizer = true
                }
                continue
            }
            result.append(p)
        }
        return result
    }
}
