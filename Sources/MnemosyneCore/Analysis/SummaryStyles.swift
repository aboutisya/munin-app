import Foundation

/// Стиль личного саммари. «Деловой» — обычный разбор встречи, без отдельного вызова.
/// Остальные стили пересобирают текст саммари отдельным вызовом `meeting-style`;
/// транскрипт, задачи, схемы и фидбек при этом не меняются.
public struct SummaryStyle: Codable, Equatable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Подпись в меню: в двух-трёх словах, что внутри.
    public var hint: String
    /// Инструкция для модели. У своих стилей — то, что пользователь написал своими словами.
    public var prompt: String

    public init(id: String, name: String, hint: String, prompt: String) {
        self.id = id
        self.name = name
        self.hint = hint
        self.prompt = prompt
    }

    public var isBusiness: Bool { id == SummaryStyle.businessId }
    public var isCustom: Bool { id.hasPrefix("custom-") }

    public static let businessId = "business"

    public static let presets: [SummaryStyle] = [
        SummaryStyle(id: businessId, name: "Деловой", hint: "Коротко, решения, задачи, темы", prompt: ""),
        SummaryStyle(id: "short", name: "Краткий", hint: "Три–пять пунктов",
                     prompt: "Три–пять пунктов списком: что решили, что делаем дальше, кто и к какому сроку. Без разделов, без пересказа хода обсуждения. Не длиннее 80 слов."),
        SummaryStyle(id: "detailed", name: "Подробный", hint: "Контекст, ход обсуждения, итоги",
                     prompt: "Разделы: «Контекст» (зачем собрались), «Ход обсуждения» (по темам: позиции, аргументы, к чему пришли), «Решения», «Задачи», «Открытые вопросы». Сохраняй цифры и формулировки участников."),
        SummaryStyle(id: "oneonone", name: "1:1", hint: "Самочувствие, договорённости, рост",
                     prompt: "Встреча один на один. Разделы: «Как дела» (настроение, нагрузка, что беспокоит), «Договорённости», «Рост и развитие» (если говорили), «К следующей встрече». Бережно к личному: без оценок человека."),
        SummaryStyle(id: "interview", name: "Интервью", hint: "Вопросы, ответы, инсайты",
                     prompt: "Интервью с пользователем или кандидатом. Разделы: «О собеседнике», «Ключевые ответы» (вопрос → суть ответа, с дословными цитатами в кавычках там, где важна формулировка), «Боли и потребности», «Инсайты», «Что проверить дальше»."),
        SummaryStyle(id: "lecture", name: "Лекция", hint: "Тезисы и термины",
                     prompt: "Лекция или доклад. Разделы: «Главная мысль» (одним-двумя предложениями), «Тезисы» (по порядку изложения), «Термины и определения», «Примеры и цифры», «Что почитать или попробовать» (если упоминали)."),
    ]

    /// Свой стиль из названия и описания. Подпись — начало описания.
    public static func custom(name: String, prompt: String, id: String = "custom-\(UUID().uuidString.prefix(8).lowercased())") -> SummaryStyle {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = p.count > 40 ? String(p.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : p
        return SummaryStyle(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), hint: hint, prompt: p)
    }
}

/// Свои стили пользователя: `~/Meetings/.styles.json`.
public struct StyleDirectory: Codable, Equatable, Sendable {
    public var schema = 1
    public var styles: [SummaryStyle]

    public init(styles: [SummaryStyle]) { self.styles = styles }

    public static func url(root: URL) -> URL { root.appending(path: ".styles.json") }

    public static func load(root: URL) -> StyleDirectory {
        guard let data = try? Data(contentsOf: url(root: root)),
              let dir = try? JSONDecoder().decode(StyleDirectory.self, from: data) else { return StyleDirectory(styles: []) }
        return dir
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(root: root), options: .atomic)
    }

    /// Встроенные и свои — в одном списке, встроенные первыми.
    public var all: [SummaryStyle] { SummaryStyle.presets + styles }

    public func style(_ id: String?) -> SummaryStyle? {
        let id = id ?? SummaryStyle.businessId
        return all.first { $0.id == id }
    }
}

/// Версия саммари в другом стиле: файл `summaries/<id стиля>.md` в папке встречи.
public struct SummaryVersion: Codable, Equatable, Sendable {
    public var style: String
    /// Название стиля на момент сборки: свой стиль могут переименовать или удалить.
    public var name: String
    public var createdAt: Date

    public init(style: String, name: String, createdAt: Date) {
        self.style = style
        self.name = name
        self.createdAt = createdAt
    }

    public var file: String { "summaries/\(style).md" }
}

/// Вход и схема вызова `meeting-style`.
public enum StyleInput {
    public static let schema = #"{"type":"object","additionalProperties":false,"required":["markdown"],"properties":{"markdown":{"type":"string"}}}"#

    /// Стиль + готовый разбор + обычный вход анализа (владелец, встреча, спикеры, транскрипт).
    public static func build(style: SummaryStyle, analysisJSON: String, analysisInput: String) -> String {
        var lines = ["# Стиль", "", "- Название: \(style.name)", "", "## Каким должно быть саммари", style.prompt, ""]
        lines += ["# Готовый разбор встречи", "", "```json", analysisJSON, "```", ""]
        lines.append(analysisInput)
        return lines.joined(separator: "\n")
    }

    /// Достать Markdown из ответа: модель иногда оборачивает его в ```.
    public static func clean(_ markdown: String) -> String {
        var s = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MeetingStore {
    /// Добавить или обновить свой стиль.
    public func saveStyle(_ style: SummaryStyle) throws {
        var dir = StyleDirectory.load(root: root)
        if let i = dir.styles.firstIndex(where: { $0.id == style.id }) { dir.styles[i] = style } else { dir.styles.append(style) }
        try dir.save(root: root)
    }

    /// Удалить свой стиль. Уже собранные версии саммари остаются у встреч.
    public func deleteStyle(_ id: String) throws {
        var dir = StyleDirectory.load(root: root)
        dir.styles.removeAll { $0.id == id }
        try dir.save(root: root)
    }

    /// Показать встречу в уже собранном стиле (`business` — обычный разбор).
    public func setActiveStyle(_ style: String, meeting: UUID) throws {
        _ = try update(id: meeting) { $0.summaryStyle = style == SummaryStyle.businessId ? nil : style }
    }

    /// Markdown активной версии, если активен не «Деловой».
    public func activeStyledSummary(_ folder: URL, meta: MeetingMeta) -> String? {
        guard let style = meta.summaryStyle, let v = meta.summaryVersions?.first(where: { $0.style == style }) else { return nil }
        return try? String(contentsOf: folder.appending(path: v.file), encoding: .utf8)
    }
}
