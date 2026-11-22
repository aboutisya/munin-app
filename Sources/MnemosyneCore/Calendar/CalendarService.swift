@preconcurrency import EventKit
import Foundation
import Observation

/// Доступ к Календарю macOS через EventKit. Аккаунты Google и Exchange,
/// добавленные в Календарь, подхватываются автоматически.
@MainActor
@Observable
public final class CalendarService {
    public enum Access: Equatable { case unknown, granted, denied }

    public private(set) var access: Access = .unknown
    /// Увеличивается при каждом изменении календаря — чтобы UI перечитал события.
    public private(set) var revision = 0

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    public func requestAccess() async {
        guard access != .granted else { return }
        do {
            let granted = try await store.requestFullAccessToEvents()
            access = granted ? .granted : .denied
        } catch {
            Log.app.error("calendar access: \(String(describing: error), privacy: .public)")
            access = .denied
        }
    }

    /// События в интервале. Пустой список, если доступа нет.
    public func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.info)
    }

    /// События, которые идут сейчас (для старта записи), по убыванию уместности.
    public func currentCandidates(at now: Date = Date()) -> [CalendarEventInfo] {
        EventMatcher.candidates(events(from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(EventMatcher.earlyStart + 60)), at: now)
    }

    /// События, пересекающиеся с записью (для перепривязки).
    public func overlapping(start: Date, end: Date) -> [CalendarEventInfo] {
        EventMatcher.overlapping(events(from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600)), start: start, end: end)
    }

    /// Свежая версия события (время или участники могли поменяться).
    public func refreshed(_ event: CalendarEventInfo) -> CalendarEventInfo? {
        events(from: event.start.addingTimeInterval(-60), to: event.end.addingTimeInterval(60))
            .first { $0.eventId == event.eventId && abs($0.start.timeIntervalSince(event.start)) < 1 }
    }

    // MARK: - Маппинг

    public static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    nonisolated static let notesLimit = 4000

    nonisolated static func info(_ e: EKEvent) -> CalendarEventInfo {
        let attendees = (e.attendees ?? []).map(person)
        let organizer = e.organizer.map { p -> Person in
            var o = person(p)
            o.isOrganizer = true
            return o
        }
        let me = attendees.first(where: \.isMe)
        let notes = e.notes.map { String($0.prefix(notesLimit)) }
        let callURL = CallLink.find(in: [e.url?.absoluteString, e.location, e.notes])
        return CalendarEventInfo(
            eventId: e.eventIdentifier ?? e.calendarItemIdentifier,
            start: e.startDate, end: e.endDate,
            title: (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            calendar: e.calendar?.title,
            isAllDay: e.isAllDay,
            location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            callURL: callURL?.absoluteString,
            organizer: organizer,
            attendees: attendees,
            myStatus: me?.status)
    }

    nonisolated static func person(_ p: EKParticipant) -> Person {
        let email: String? = {
            let s = p.url.absoluteString
            guard s.lowercased().hasPrefix("mailto:") else { return nil }
            return String(s.dropFirst(7)).removingPercentEncoding
        }()
        let status: Person.Status = switch p.participantStatus {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
        return Person(name: p.name ?? email ?? "", email: email, status: status, isMe: p.isCurrentUser)
    }
}
