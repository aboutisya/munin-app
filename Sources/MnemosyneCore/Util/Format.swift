import Foundation

public enum Format {
    /// `4:05`, `23:41`, `1:02:07`
    public static func timer(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `44 мин`, `1 ч 05 мин`
    public static func duration(_ seconds: TimeInterval) -> String {
        // Меньше минуты — секундами: «0 мин» у короткой реплики выглядит как ошибка.
        if seconds < 59.5 { return "\(max(0, Int(seconds.rounded()))) с" }
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) мин" }
        return String(format: "%d ч %02d мин", minutes / 60, minutes % 60)
    }

    /// «сегодня», «вчера», «чт», «12 нояб.»
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "сегодня" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "вчера"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        f.dateFormat = days < 7 ? "EEEEEE" : "d MMM"
        return f.string(from: date).lowercased()
    }
}

extension String {
    /// `nil`, если строка пустая или из одних пробелов.
    public var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
