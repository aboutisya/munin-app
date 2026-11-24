import Foundation

/// Языки встреч и саммари. Распознавание: `auto`, `ru`, `en`.
/// Язык саммари: `meeting` (как у встречи), `ru`, `en`.
public enum MeetingLanguage {
    public static let auto = "auto"
    public static let sameAsMeeting = "meeting"

    /// «русский», «английский»; незнакомый код — как есть.
    public static func name(_ code: String) -> String {
        switch code.lowercased() {
        case "ru": "русский"
        case "en": "английский"
        default: code
        }
    }

    /// «Русский», «Английский» — для интерфейса.
    public static func title(_ code: String) -> String { name(code).capitalizedFirstLetter }

    /// Итоговый язык саммари: настройка или язык встречи из транскрипта.
    public static func summary(setting: String, transcriptLanguage: String) -> String {
        if setting == sameAsMeeting || setting.isEmpty {
            let l = transcriptLanguage.lowercased()
            return l.isEmpty || l == auto ? "ru" : l
        }
        return setting
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
