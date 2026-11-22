import Foundation
import SQLite3

/// Поиск по встречам: SQLite FTS5 в `~/Meetings/.index.sqlite`.
/// Это только индекс — его можно удалить, он пересоберётся из папок.
public final class SearchIndex: @unchecked Sendable {
    public struct Hit: Equatable, Sendable {
        public var id: UUID
        /// Фрагмент текста с найденным словом в «[…]».
        public var snippet: String
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Self.error(db) }
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS meetings USING fts5(
                id UNINDEXED, title, people, body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS indexed (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    /// Отпечаток встречи: если он не изменился, переиндексировать не нужно.
    public static func fingerprint(folder: URL, meta: MeetingMeta) -> String {
        func mtime(_ name: String) -> String {
            let date = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)[.modificationDate]) as? Date
            return date.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        }
        let people = (meta.participants ?? []).map(\.displayName).joined(separator: ",")
        return [meta.title, people, mtime("transcript.json"), mtime("analysis.json")].joined(separator: "|")
    }

    /// Привести индекс в соответствие с папками: добавить новые, обновить изменённые, убрать удалённые.
    public func sync(store: MeetingStore) {
        let meetings = store.list()
        let known = fingerprints()
        var alive = Set<String>()
        for (folder, meta) in meetings {
            let id = meta.id.uuidString
            alive.insert(id)
            let fp = Self.fingerprint(folder: folder, meta: meta)
            guard known[id] != fp else { continue }
            upsert(id: meta.id, title: meta.title, people: Self.people(meta, folder: folder), body: Self.body(folder: folder), fingerprint: fp)
        }
        for id in known.keys where !alive.contains(id) { delete(id: id) }
    }

    public func upsert(id: UUID, title: String, people: String, body: String, fingerprint: String) {
        lock.withLock {
            _ = run("DELETE FROM meetings WHERE id = ?", [id.uuidString])
            _ = run("INSERT INTO meetings (id, title, people, body) VALUES (?, ?, ?, ?)", [id.uuidString, title, people, body])
            _ = run("INSERT OR REPLACE INTO indexed (id, fingerprint) VALUES (?, ?)", [id.uuidString, fingerprint])
        }
    }

    public func delete(id: String) {
        lock.withLock {
            _ = run("DELETE FROM meetings WHERE id = ?", [id])
            _ = run("DELETE FROM indexed WHERE id = ?", [id])
        }
    }

    /// Поиск: каждое слово запроса ищется по началу («квот» найдёт «квоты», «квотам»).
    /// Русских окончаний FTS5 не знает, поэтому префиксный поиск — разумная замена стеммингу.
    public func search(_ query: String, limit: Int = 50) -> [Hit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return lock.withLock {
            var hits: [Hit] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, snippet(meetings, -1, '[', ']', '…', 12) FROM meetings WHERE meetings MATCH ? ORDER BY rank LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, Self.transient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: idText)) else { continue }
                let snippet = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                hits.append(Hit(id: id, snippet: snippet))
            }
            return hits
        }
    }

    // MARK: - Подготовка текста

    static func matchExpression(_ query: String) -> String? {
        let words = HallucinationFilter.normalize(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    static func people(_ meta: MeetingMeta, folder: URL) -> String {
        var names = (meta.participants ?? []).map(\.displayName)
        if let t = try? MeetingProcessorCodec.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json"))) {
            names += t.speakers.filter { $0.nameSource != "generic" && $0.id != "me" }.map(\.label)
        }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }

    /// Текст для поиска: реплики транскрипта и саммари.
    static func body(folder: URL) -> String {
        var parts: [String] = []
        if let t = try? MeetingProcessorCodec.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json"))) {
            parts += t.utterances.map(\.text)
        }
        if let a = try? Analysis.decoder.decode(Analysis.self, from: Data(contentsOf: folder.appending(path: "analysis.json"))) {
            parts += a.tldr + a.decisions.map(\.text) + a.actionItems.map(\.what) + a.summaryByTopics.map { "\($0.topic) \($0.markdown)" }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func fingerprints() -> [String: String] {
        lock.withLock {
            var result: [String: String] = [:]
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, fingerprint FROM indexed", -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
            }
            return result
        }
    }

    @discardableResult
    private func run(_ sql: String, _ args: [String]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, Self.transient) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(db) }
    }

    private static func error(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "SearchIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"])
    }
}

/// Общий JSON-кодек транскрипта (даты ISO 8601).
public enum MeetingProcessorCodec {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
