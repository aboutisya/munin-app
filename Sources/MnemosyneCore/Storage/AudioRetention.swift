import Foundation

/// Срок хранения аудио: включается галочкой в настройках, по умолчанию выключен.
/// Удаляются только `.m4a`; транскрипт, саммари и диаграммы остаются.
public enum AudioRetention {
    public static let days = 30

    /// Встречи, у которых аудио старше срока и ещё лежит на диске.
    public static func expired(_ list: [(folder: URL, meta: MeetingMeta)], days: Int = days, now: Date = Date()) -> [(folder: URL, meta: MeetingMeta)] {
        let limit = now.addingTimeInterval(-Double(days) * 86400)
        return list.filter { item in
            let m = item.meta
            guard !m.status.needsProcessing, m.status != .recording else { return false }
            guard (m.endedAt ?? m.startedAt) < limit else { return false }
            return audioFiles(item.folder).isEmpty == false
        }
    }

    public static func audioFiles(_ folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["m4a", "caf"].contains($0.pathExtension.lowercased()) }
    }

    /// Удалить аудио у просроченных встреч. Возвращает число встреч.
    @discardableResult
    public static func purge(store: MeetingStore, days: Int = days, now: Date = Date()) -> Int {
        var n = 0
        for item in expired(store.list(), days: days, now: now) {
            for f in audioFiles(item.folder) { try? FileManager.default.removeItem(at: f) }
            _ = try? store.update(id: item.meta.id) { $0.audioDeletedAt = now }
            n += 1
        }
        return n
    }
}
