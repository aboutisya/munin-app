import Foundation

/// Файлы, приложенные к встрече: скриншоты, документы. Лежат в `attachments/` внутри папки встречи,
/// поэтому переезжают вместе с ней при переименовании и не попадают под срок хранения аудио.
public enum Attachments {
    public static let folder = "attachments"

    public static func directory(_ meeting: URL) -> URL {
        meeting.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Приложенные файлы, новые сверху. Скрытые пропускаются.
    public static func list(_ meeting: URL) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isRegularFileKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory(meeting), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func added(_ url: URL) -> Date {
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        return items.sorted { added($0) != added($1) ? added($0) > added($1) : $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Скопировать файл или папку во вложения. Исходник не трогаем. Возвращает новый путь.
    @discardableResult
    public static func add(_ source: URL, to meeting: URL) throws -> URL {
        let dir = directory(meeting)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = uniqueName(source.lastPathComponent, in: dir)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// Сохранить данные без файла (картинка, перетащенная из браузера) под заданным именем.
    @discardableResult
    public static func add(data: Data, named name: String, to meeting: URL) throws -> URL {
        let dir = directory(meeting)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = uniqueName(name, in: dir)
        try data.write(to: target, options: .withoutOverwriting)
        return target
    }

    /// `скрин.png` → `скрин 2.png`, `скрин 3.png`… если имя занято.
    public static func uniqueName(_ name: String, in dir: URL) -> URL {
        // Чистим имя без расширения: длинное имя обрезается, а расширение должно остаться.
        let rawExt = (name as NSString).pathExtension
        let ext = rawExt.isEmpty ? "" : MeetingStore.sanitize(rawExt).replacingOccurrences(of: " ", with: "")
        let base = MeetingStore.sanitize((name as NSString).deletingPathExtension)
        func file(_ suffix: String) -> URL {
            dir.appending(path: ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
        }
        var candidate = file("")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = file(" \(n)")
            n += 1
        }
        return candidate
    }
}
