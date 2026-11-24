import AppKit
import MnemosyneCore

/// Язык интерфейса. Строки — ключами по-русски: `Text("Отмена")` и `String(localized:)` берут
/// перевод из `Resources/en.lproj/Localizable.strings`, русский остаётся исходником.
/// Ядро (`MnemosyneCore`) не локализуется: его строки уходят в Claude и в файлы встреч.
enum UILanguage: String, CaseIterable {
    case system, ru, en

    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .ru: "Русский"
        case .en: "English"
        }
    }

    /// Выбор хранится в `AppleLanguages` приложения: macOS применяет его при следующем запуске.
    static var chosen: UILanguage {
        get {
            guard let first = UserDefaults.standard.stringArray(forKey: "uiLanguageChoice")?.first else { return .system }
            return UILanguage(rawValue: first) ?? .system
        }
        set {
            let d = UserDefaults.standard
            d.set([newValue.rawValue], forKey: "uiLanguageChoice")
            switch newValue {
            case .system: d.removeObject(forKey: "AppleLanguages")
            case .ru, .en: d.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Язык, на котором интерфейс показан сейчас.
    static var current: String { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "ru" }
    static var isEnglish: Bool { current == "en" }
    /// Для дат и чисел в интерфейсе (не во входе Claude — там всегда русский).
    static var locale: Locale { isEnglish ? Locale(identifier: "en_US") : Locale(identifier: "ru_RU") }

    /// Перезапуск, чтобы новый язык применился.
    @MainActor static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Число со словом: «3 встречи» / «3 meetings».
func plural(_ n: Int, ru: (one: String, few: String, many: String), en: (one: String, many: String)) -> String {
    if UILanguage.isEnglish { return "\(n) \(n == 1 ? en.one : en.many)" }
    let m10 = n % 10, m100 = n % 100
    let word = m10 == 1 && m100 != 11 ? ru.one : (2...4).contains(m10) && !(12...14).contains(m100) ? ru.few : ru.many
    return "\(n) \(word)"
}

/// Форматы из ядра в языке интерфейса. Ядро всегда пишет по-русски: оно же готовит вход для Claude.
enum UIFormat {
    /// `44 мин`, `1 ч 05 мин` / `44 min`, `1 h 05 min`
    static func duration(_ seconds: TimeInterval) -> String {
        guard UILanguage.isEnglish else { return Format.duration(seconds) }
        if seconds < 59.5 { return "\(max(0, Int(seconds.rounded()))) s" }
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// «сегодня», «вчера», «чт», «12 нояб.» / «today», «yesterday», «Thu», «Nov 12»
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard UILanguage.isEnglish else { return Format.day(date, now: now, calendar: calendar) }
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter()
        f.locale = UILanguage.locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        f.dateFormat = days < 7 ? "EEE" : "MMM d"
        return f.string(from: date)
    }
}

extension RecordingMode {
    /// Название режима в языке интерфейса (`title` из ядра — для входа Claude).
    var uiTitle: String {
        switch self {
        case .online: String(localized: "Онлайн")
        case .offline: String(localized: "Офлайн")
        case .hybrid: String(localized: "Гибрид")
        }
    }
}

extension TagColor {
    var uiTitle: String {
        switch self {
        case .red: String(localized: "Красный")
        case .orange: String(localized: "Оранжевый")
        case .yellow: String(localized: "Жёлтый")
        case .green: String(localized: "Зелёный")
        case .teal: String(localized: "Бирюзовый")
        case .blue: String(localized: "Синий")
        case .purple: String(localized: "Фиолетовый")
        case .gray: String(localized: "Серый")
        }
    }
}

extension SummaryStyle {
    /// Встроенные стили — по-английски в английском интерфейсе; свои — как назвал пользователь.
    var uiName: String {
        switch id {
        case SummaryStyle.businessId: String(localized: "Деловой")
        case "short": String(localized: "Краткий")
        case "detailed": String(localized: "Подробный")
        case "oneonone": "1:1"
        case "interview": String(localized: "Интервью")
        case "lecture": String(localized: "Лекция")
        default: name
        }
    }

    var uiHint: String {
        switch id {
        case SummaryStyle.businessId: String(localized: "Коротко, решения, задачи, темы")
        case "short": String(localized: "Три–пять пунктов")
        case "detailed": String(localized: "Контекст, ход обсуждения, итоги")
        case "oneonone": String(localized: "Самочувствие, договорённости, рост")
        case "interview": String(localized: "Вопросы, ответы, инсайты")
        case "lecture": String(localized: "Тезисы и термины")
        default: hint
        }
    }
}

extension MeetingLanguage {
    /// «Русский» / «Russian» для интерфейса.
    static func uiTitle(_ code: String) -> String {
        switch code.lowercased() {
        case "ru": String(localized: "Русский")
        case "en": String(localized: "Английский")
        default: code
        }
    }
}
