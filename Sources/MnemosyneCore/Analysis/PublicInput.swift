import CryptoKit
import Foundation

/// Вход вызова 2 (`meeting-public`): только публичное подмножество анализа.
/// Тональность, оценки участников, конфликт и фидбек по речи сюда не попадают физически (§5.3).
public enum PublicInput {
    public struct DiagramRef: Sendable, Equatable {
        public var title: String
        public var file: String
        public init(title: String, file: String) { self.title = title; self.file = file }
    }

    /// Куда владелец вставляет саммари: от этого зависит разметка (§8).
    public enum Messenger: String, CaseIterable, Sendable {
        case mattermost, slack, telegram
        public var title: String {
            switch self {
            case .mattermost: "Mattermost"
            case .slack: "Slack"
            case .telegram: "Telegram"
            }
        }
    }

    /// Ответ скилла: итоговый текст в разметке мессенджера.
    public struct Output: Codable, Sendable { public var markdown: String }

    public static let schemaVersion = 1
    public static let schema = #"{"additionalProperties":false,"properties":{"markdown":{"type":"string"}},"required":["markdown"],"type":"object"}"#

    /// Имена для публичного текста: код спикера → имя. Безымянные спикеры («Собеседник 1») → пусто,
    /// владелец → его имя из календаря, если оно есть.
    public static func names(_ a: Analysis, meta: MeetingMeta, transcript t: Transcript) -> [String: String] {
        var names = PersonalSummary.speakerNames(a, transcript: t)
        let codes = AnalysisInput.codes(for: t)
        for s in t.speakers where s.nameSource == "generic" {
            guard let c = codes[s.id], names[c] == s.label else { continue }
            names[c] = ""
        }
        names["Я"] = meta.participants?.first(where: \.isMe)?.displayName ?? "Я"
        return names
    }

    public static func build(_ a: Analysis, meta: MeetingMeta, transcript t: Transcript,
                             diagrams: [DiagramRef], messenger: Messenger = .mattermost, proofread: Bool = true,
                             calendar: Calendar = .current) -> String {
        let names = names(a, meta: meta, transcript: t)
        func person(_ s: String) -> String {
            let v = s.trimmingCharacters(in: .whitespaces)
            return names[v] ?? v
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd, EEEE"

        var lines = ["# Встреча", ""]
        lines.append("- Мессенджер: \(messenger.title)")
        lines.append("- Вычитка через ru-text: \(proofread ? "да" : "нет")")
        lines.append("- Название: \(meta.title)")
        lines.append("- Дата: \(df.string(from: meta.startedAt))")
        let owner = names["Я"] ?? "Я"
        lines.append("- Автор сообщения: \(owner == "Я" ? "владелец записи" : owner)")
        var people: [String] = []
        for p in meta.participants ?? [] where !people.contains(p.displayName) { people.append(p.displayName) }
        for (code, n) in names.sorted(by: { $0.key < $1.key }) where code != "Я" && !n.isEmpty && !people.contains(n) {
            people.append(n)
        }
        if !people.isEmpty { lines.append("- Участники: " + people.joined(separator: ", ")) }

        lines += ["", "## Главное"]
        lines += a.tldr.map { "- \($0)" }

        lines += ["", "## Договорённости"]
        if a.decisions.isEmpty { lines.append("- нет") }
        for d in a.decisions {
            let o = person(d.owner)
            lines.append("- \(d.text)" + (o.isEmpty ? "" : " (отвечает: \(o))"))
        }

        lines += ["", "## Задачи", "", "| Что | Кто | Срок (дата) | Срок (как сказали) |", "|---|---|---|---|"]
        if a.actionItems.isEmpty { lines.append("| нет | | | |") }
        for i in a.actionItems {
            let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
            lines.append("| \(cell(i.what)) | \(cell(person(i.who))) | \(i.due) | \(cell(i.dueSaid)) |")
        }

        if !diagrams.isEmpty {
            lines += ["", "## Схемы (приложу картинками отдельно)"]
            lines += diagrams.map { "- \($0.title)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Версия `ru-text`: у скилла нет поля версии, берём хэш SKILL.md.
    public static func contentVersion(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(input: String, skillVersion: String, ruTextVersion: String, model: String) -> String {
        let material = "\(input)\n--\nskill=\(skillVersion)\nru-text=\(ruTextVersion)\nmodel=\(model)\nschema=\(schemaVersion)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Имя файла диаграммы: `01-process`.
    public static func diagramBase(index: Int, type: String) -> String {
        String(format: "%02d-%@", index + 1, type.isEmpty ? "diagram" : type)
    }

    /// Страховка: модель всё же вставила `@логин` или обернула текст в блок кода.
    public static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t = t.replacingOccurrences(of: #"(^|[\s(])@([A-Za-z0-9._-]+)"#, with: "$1$2", options: .regularExpression)
        return t + "\n"
    }
}
