import Foundation

/// Очередь анализа на диске (`~/Meetings/.queue.json`): переживает перезапуск и сон Mac.
public struct AnalysisQueueState: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: UUID
        /// Не запускать раньше этого времени (ждём сброса лимита).
        public var notBefore: Date?
        /// Сколько раз упёрлись в лимит подряд — для бэкоффа 15 → 30 → 60 мин.
        public var limitHits: Int

        public init(id: UUID, notBefore: Date? = nil, limitHits: Int = 0) {
            self.id = id
            self.notBefore = notBefore
            self.limitHits = limitHits
        }
    }

    public var items: [Item] = []

    public init(items: [Item] = []) {
        self.items = items
    }

    public mutating func add(_ id: UUID) {
        guard !items.contains(where: { $0.id == id }) else { return }
        // Если очередь уже ждёт лимита, новая встреча ждёт вместе со всеми.
        items.append(Item(id: id, notBefore: waitingUntil))
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Первая встреча, которую можно запускать сейчас.
    public func next(now: Date) -> UUID? {
        items.first { ($0.notBefore ?? .distantPast) <= now }?.id
    }

    /// Упёрлись в лимит: лимит общий, поэтому ждёт вся очередь.
    /// Время берём из ответа CLI, иначе бэкофф по числу попаданий подряд.
    @discardableResult
    public mutating func hitLimit(on id: UUID, resetAt: Date?, now: Date) -> Date {
        let hits = (items.first { $0.id == id }?.limitHits ?? 0)
        let retry = resetAt ?? now.addingTimeInterval(LimitRetry.backoff(attempt: hits))
        for i in items.indices {
            items[i].notBefore = retry
            if items[i].id == id { items[i].limitHits = hits + 1 }
        }
        return retry
    }

    /// «Повторить сейчас».
    public mutating func retryNow() {
        for i in items.indices { items[i].notBefore = nil }
    }

    /// Ждём сброса лимита до этого времени (nil — не ждём).
    public var waitingUntil: Date? {
        let waits = items.compactMap(\.notBefore)
        guard !waits.isEmpty, waits.count == items.count else { return nil }
        return waits.min()
    }

    // MARK: - Диск

    public static func load(from url: URL) -> AnalysisQueueState {
        guard let data = try? Data(contentsOf: url) else { return AnalysisQueueState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(AnalysisQueueState.self, from: data)) ?? AnalysisQueueState()
    }

    public func save(to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: url, options: .atomic)
    }
}
