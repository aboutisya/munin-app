import Foundation
import Testing
@testable import MnemosyneCore

struct CalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, start: TimeInterval, end: TimeInterval, link: String? = nil, others: Int = 0,
               allDay: Bool = false, declined: Bool = false, location: String? = nil) -> CalendarEventInfo {
        var attendees = (0..<others).map { Person(name: "Человек \($0)", email: "p\($0)@x.ru", status: .accepted) }
        attendees.append(Person(name: "Я", email: "me@x.ru", status: declined ? .declined : .accepted, isMe: true))
        return CalendarEventInfo(eventId: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                                 title: id, isAllDay: allDay, location: location, callURL: link,
                                 attendees: attendees, myStatus: declined ? .declined : .accepted)
    }

    // MARK: - Ссылки на звонки

    @Test(arguments: [
        "https://company.ktalk.ru/abc123",
        "https://meet.google.com/abc-defg-hij",
        "https://company.zoom.us/j/123456789?pwd=x",
        "https://jazz.sber.ru/xyz",
        "https://my.mts-link.ru/j/1/2",
        "https://telemost.yandex.ru/j/123",
    ])
    func detectsCallLinks(link: String) {
        #expect(CallLink.find(in: ["Подключение: \(link) пароль 1"])?.absoluteString == link)
    }

    @Test func ignoresNonCallLinks() {
        #expect(CallLink.find(in: ["Повестка: https://wiki.example.com/pages/1", "https://zoom.us"]) == nil)
        #expect(CallLink.find(in: [nil, ""]) == nil)
    }

    @Test func prefersKtalkOverOthers() {
        let url = CallLink.find(in: ["https://zoom.us/j/1 запасная", "https://team.ktalk.ru/room"])
        #expect(url?.host == "team.ktalk.ru")
    }

    // MARK: - Выбор события

    @Test func picksRunningEventsOnly() {
        let events = [
            event("прошло", start: -7200, end: -3600, others: 2),
            event("идёт", start: -600, end: 1800, others: 2),
            event("скоро", start: 240, end: 3600, others: 2),     // через 4 мин — уже кандидат
            event("потом", start: 900, end: 3600, others: 2),
        ]
        #expect(EventMatcher.candidates(events, at: now).map(\.title).sorted() == ["идёт", "скоро"])
    }

    @Test func skipsAllDayAndDeclined() {
        let events = [
            event("весь день", start: -3600, end: 80000, others: 3, allDay: true),
            event("отклонил", start: -60, end: 1800, link: "https://meet.google.com/a", others: 3, declined: true),
        ]
        #expect(EventMatcher.candidates(events, at: now).isEmpty)
    }

    @Test func prioritizesCallLinkThenAttendees() {
        let events = [
            event("фокус-время", start: -60, end: 3600),
            event("с людьми", start: -60, end: 3600, others: 3),
            event("звонок", start: -1200, end: 3600, link: "https://meet.google.com/a", others: 1),
        ]
        #expect(EventMatcher.candidates(events, at: now).map(\.title) == ["звонок", "с людьми", "фокус-время"])
    }

    @Test func overlappingSortedByOverlap() {
        let events = [
            event("краешком", start: -3600, end: -3000),
            event("целиком", start: -3300, end: 0),
            event("мимо", start: 600, end: 1200),
        ]
        let result = EventMatcher.overlapping(events, start: now.addingTimeInterval(-3300), end: now)
        #expect(result.map(\.title) == ["целиком", "краешком"])
    }

    @Test func upcomingNeedsLinkOrPeople() {
        let events = [
            event("звонок", start: 60, end: 1800, link: "https://meet.google.com/a"),
            event("фокус", start: 60, end: 1800),
            event("через час", start: 3600, end: 5400, others: 2),
        ]
        #expect(EventMatcher.upcoming(events, now: now).map(\.title) == ["звонок"])
    }

    // MARK: - Режим

    @Test func modeSuggestion() {
        #expect(ModeSuggestion.atStart(for: nil) == .online)
        #expect(ModeSuggestion.atStart(for: event("a", start: 0, end: 1, link: "https://meet.google.com/a")) == .online)
        #expect(ModeSuggestion.atStart(for: event("b", start: 0, end: 1, location: "Переговорная 5.12")) == .online)
        #expect(ModeSuggestion.atStart(for: event("c", start: 0, end: 1, link: "https://x.ktalk.ru/r", location: "Переговорная 5.12")) == .hybrid)
        #expect(ModeSuggestion.atStart(for: event("d", start: 0, end: 1, link: "https://x.ktalk.ru/r", location: "https://x.ktalk.ru/r")) == .online)
    }

    @Test func offlineSuggestion() {
        let room = event("r", start: 0, end: 1, location: "Переговорная")
        #expect(ModeSuggestion.shouldSuggestOffline(event: room, systemAudioSilentFirstMinute: true))
        #expect(!ModeSuggestion.shouldSuggestOffline(event: room, systemAudioSilentFirstMinute: false))
        #expect(!ModeSuggestion.shouldSuggestOffline(event: event("z", start: 0, end: 1, link: "https://meet.google.com/a", location: "Переговорная"), systemAudioSilentFirstMinute: true))
        #expect(!ModeSuggestion.shouldSuggestOffline(event: nil, systemAudioSilentFirstMinute: true))
    }

    @Test func participantsDedupAndSkipDeclined() {
        var e = event("e", start: 0, end: 1, others: 2)
        e.organizer = Person(name: "Человек 0", email: "P0@x.ru", status: .accepted, isOrganizer: true)
        e.attendees.append(Person(name: "Отказник", email: "no@x.ru", status: .declined))
        let names = e.participants.map(\.displayName)
        #expect(names == ["Человек 0", "Человек 1", "Я"])
        #expect(e.participants.first?.isOrganizer == true)
        #expect(e.others.count == 2)
    }

    @Test func displayNameFallsBackToEmail() {
        #expect(Person(name: "", email: "maria.s@example.com").displayName == "maria.s")
        #expect(Person(name: "ivan@x.ru", email: "ivan@x.ru").displayName == "ivan")
    }

    // MARK: - Перепривязка

    @Test func rebindFollowsEventUntilTitleEdited() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mnemo-rebind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meta = MeetingMeta(title: "Без названия", startedAt: now, mode: .online)
        var folder = try store.create(meta)

        let sync = event("Синк по квотам", start: 0, end: 1800, others: 2)
        folder = try store.rebind(folder, to: sync)
        var m = try store.read(folder)
        #expect(m.title == "Синк по квотам")
        #expect(folder.lastPathComponent.hasSuffix("_Синк по квотам"))
        #expect(m.participants?.count == 3)
        #expect(m.event?.eventId == "Синк по квотам")

        folder = try store.rename(folder, to: "Квоты Q1")
        folder = try store.rebind(folder, to: event("Другое", start: 0, end: 1800))
        m = try store.read(folder)
        #expect(m.title == "Квоты Q1")            // ручное название сохраняется
        #expect(m.event?.title == "Другое")
        #expect(m.id == meta.id)

        folder = try store.rebind(folder, to: nil)
        m = try store.read(folder)
        #expect(m.event == nil)
        #expect(m.participants == nil)
    }
}
