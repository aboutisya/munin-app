import Foundation

/// Поиск ссылки на видеозвонок в полях события.
public enum CallLink {
    /// Платформы, которыми пользуются на встречах. Порядок — приоритет при нескольких ссылках.
    static let hosts: [String] = [
        "ktalk.ru",            // Контур.Толк: <tenant>.ktalk.ru/<room>
        "meet.google.com",
        "telemost.yandex.ru",
        "telemost.360.yandex.ru",
        "zoom.us",             // в т. ч. <company>.zoom.us/j/…
        "jazz.sber.ru",
        "salutejazz.ru",
        "mts-link.ru",         // МТС Линк: <tenant>.mts-link.ru
        "my.mts-link.ru",
        "teams.microsoft.com",
        "teams.live.com",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Первая ссылка на звонок из переданных текстов (url события, место, описание).
    public static func find(in texts: [String?]) -> URL? {
        var found: [(rank: Int, url: URL)] = []
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let rank = rank(of: url) else { continue }
                found.append((rank, url))
            }
        }
        return found.min { $0.rank < $1.rank }?.url
    }

    public static func isCallLink(_ url: URL) -> Bool { rank(of: url) != nil }

    static func rank(of url: URL) -> Int? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        for (i, h) in hosts.enumerated() where host == h || host.hasSuffix("." + h) {
            // У Zoom и Teams ссылка на звонок — с путём, голый домен не считается.
            if (h == "zoom.us" || h.hasPrefix("teams.")) && url.path.count < 3 { continue }
            return i
        }
        return nil
    }
}

/// Выбор события для записи.
public enum EventMatcher {
    /// Окно вокруг начала: запись за 5 минут до начала уже относится к событию.
    public static let earlyStart: TimeInterval = 5 * 60

    /// События, которые идут сейчас, по убыванию уместности.
    /// Отбрасываем события на весь день и отклонённые мной.
    /// Приоритет: есть ссылка на звонок → есть другие участники → началось ближе всего к «сейчас».
    public static func candidates(_ events: [CalendarEventInfo], at now: Date) -> [CalendarEventInfo] {
        events
            .filter { !$0.isAllDay && $0.myStatus != .declined }
            .filter { $0.start.addingTimeInterval(-earlyStart) <= now && now < $0.end }
            .sorted { a, b in
                let ka = score(a), kb = score(b)
                if ka != kb { return ka > kb }
                return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
            }
    }

    static func score(_ e: CalendarEventInfo) -> Int {
        (e.callURL != nil ? 2 : 0) + (e.others.isEmpty ? 0 : 1)
    }

    /// События, пересекающиеся с интервалом записи, — для перепривязки.
    /// Сортировка по величине пересечения.
    public static func overlapping(_ events: [CalendarEventInfo], start: Date, end: Date) -> [CalendarEventInfo] {
        events
            .filter { !$0.isAllDay && $0.start < end && start < $0.end }
            .sorted { overlap($0, start, end) > overlap($1, start, end) }
    }

    static func overlap(_ e: CalendarEventInfo, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(e.end, end).timeIntervalSince(max(e.start, start)))
    }

    /// События, о которых стоит напомнить: начинаются в ближайшие `window` секунд,
    /// со ссылкой на звонок или с другими участниками, не отклонены.
    public static func upcoming(_ events: [CalendarEventInfo], now: Date, window: TimeInterval = 90) -> [CalendarEventInfo] {
        events.filter {
            !$0.isAllDay && $0.myStatus != .declined
                && $0.start > now && $0.start.timeIntervalSince(now) <= window
                && ($0.callURL != nil || !$0.others.isEmpty)
        }
    }
}

/// Подсказка режима записи по событию.
public enum ModeSuggestion {
    /// Режим при старте. Офлайн никогда не выбираем сами: если ошиблись,
    /// потеряли бы звук собеседников. Офлайн предлагаем позже, по тишине.
    public static func atStart(for event: CalendarEventInfo?) -> RecordingMode {
        guard let event else { return .online }
        let hasRoom = !(event.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !CallLink.isOnlyLink(event.location)
        if event.callURL != nil && hasRoom { return .hybrid }
        return .online
    }

    /// Предложить офлайн: у события есть переговорная, нет ссылки и минуту нет звука приложений.
    public static func shouldSuggestOffline(event: CalendarEventInfo?, systemAudioSilentFirstMinute: Bool) -> Bool {
        guard let event, systemAudioSilentFirstMinute, event.callURL == nil else { return false }
        return !(event.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension CallLink {
    /// Поле «место» содержит только ссылку (часто так пишут Zoom/Meet) — это не переговорная.
    static func isOnlyLink(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return find(in: [text]).map { text.hasPrefix("http") && !text.contains(" ") && isCallLink($0) } ?? false
    }
}
