import Foundation

/// Папки встреч в `~/Meetings`. Файлы на диске — источник истины.
public struct MeetingStore: Sendable {
    public static let metaFile = "meta.json"
    public static let maxTitleLength = 80
    public static let defaultTitle = "Без названия"

    public let root: URL

    public init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
    }

    /// Ключ настройки с папкой встреч, выбранной в онбординге или настройках.
    public static let rootDefaultsKey = "meetingsRoot"

    /// `~/Meetings` или папка из настроек; переменная `MNEMOSYNE_ROOT` важнее (для тестов и отладки).
    public static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["MNEMOSYNE_ROOT"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let chosen = UserDefaults.standard.string(forKey: rootDefaultsKey), !chosen.isEmpty {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Meetings", directoryHint: .isDirectory)
    }

    // MARK: - Имена папок

    /// `2026-11-24_1430_Синк по квотам`
    public static func folderName(title: String, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d_%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        return "\(stamp)_\(sanitize(title))"
    }

    /// Убирает символы, недопустимые в именах файлов, и обрезает до 80 символов.
    public static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        var s = String(String.UnicodeScalarView(title.unicodeScalars.map { forbidden.contains($0) ? " " : $0 }))
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxTitleLength {
            s = String(s.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? defaultTitle : s
    }

    /// Свободный путь: при совпадении добавляет « (2)», « (3)»…
    public func uniqueFolder(named name: String, excluding current: URL? = nil) -> URL {
        var candidate = root.appending(path: name, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL != current?.standardizedFileURL {
            candidate = root.appending(path: "\(name) (\(n))", directoryHint: .isDirectory)
            n += 1
        }
        return candidate
    }

    // MARK: - CRUD

    public func create(_ meta: MeetingMeta) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = uniqueFolder(named: Self.folderName(title: meta.title, date: meta.startedAt))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write(meta, to: folder)
        return folder
    }

    public func write(_ meta: MeetingMeta, to folder: URL) throws {
        let data = try Self.encoder.encode(meta)
        try data.write(to: folder.appending(path: Self.metaFile), options: .atomic)
    }

    public func read(_ folder: URL) throws -> MeetingMeta {
        let data = try Data(contentsOf: folder.appending(path: Self.metaFile))
        return try Self.decoder.decode(MeetingMeta.self, from: data)
    }

    /// Переименовать встречу: меняется и `title`, и имя папки. UUID остаётся.
    /// `byUser: true` помечает название как ручное: перепривязка события его больше не меняет.
    @discardableResult
    public func rename(_ folder: URL, to title: String, byUser: Bool = true) throws -> URL {
        var meta = try read(folder)
        meta.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if meta.title.isEmpty { meta.title = Self.defaultTitle }
        if byUser { meta.titleEdited = true }
        return try save(meta, movingFrom: folder)
    }

    /// Привязать встречу к другому событию или отвязать (`nil`).
    /// Название меняется, только если его не правили руками. Участники обновляются по флагу.
    @discardableResult
    public func rebind(_ folder: URL, to event: CalendarEventInfo?, updateParticipants: Bool = true) throws -> URL {
        var meta = try read(folder)
        meta.event = event
        if updateParticipants {
            meta.participants = event?.participants
        }
        if meta.titleEdited != true {
            meta.title = event?.title ?? Self.defaultTitle
        }
        return try save(meta, movingFrom: folder)
    }

    /// Записать meta и, если название изменилось, переименовать папку.
    private func save(_ meta: MeetingMeta, movingFrom folder: URL) throws -> URL {
        let target = uniqueFolder(named: Self.folderName(title: meta.title, date: meta.startedAt), excluding: folder)
        if target.standardizedFileURL != folder.standardizedFileURL {
            try FileManager.default.moveItem(at: folder, to: target)
        }
        try write(meta, to: target)
        return target
    }

    /// Все встречи, новые сверху. Скрытые папки (`.people`) пропускаются.
    public func list() -> [(folder: URL, meta: MeetingMeta)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard let meta = try? read(url) else { return nil }
            return (url, meta)
        }.sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    /// Папка встречи по UUID: имя папки могло поменяться (переименование во время обработки).
    public func locate(id: UUID) -> URL? {
        list().first { $0.meta.id == id }?.folder
    }

    /// Прочитать, изменить и записать meta встречи по UUID.
    @discardableResult
    public func update(id: UUID, _ change: (inout MeetingMeta) -> Void) throws -> URL {
        guard let folder = locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        var meta = try read(folder)
        change(&meta)
        try write(meta, to: folder)
        return folder
    }

    /// Рабочая папка обработки вне папки встречи: переименование встречи её не ломает.
    public func workDirectory(for id: UUID) -> URL {
        root.appending(path: ".work/\(id.uuidString)", directoryHint: .isDirectory)
    }

    /// Встречи, оставшиеся в статусе `recording` после падения приложения.
    public func interrupted() -> [(folder: URL, meta: MeetingMeta)] {
        list().filter { $0.meta.status == .recording }
    }

    // MARK: - JSON

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
