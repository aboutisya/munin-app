import Foundation

/// Разбор ответа `claude -p --output-format json`.
public struct ClaudeResult: Sendable, Equatable {
    public struct Usage: Codable, Sendable, Equatable {
        public var inputTokens: Int
        public var cacheCreationInputTokens: Int
        public var cacheReadInputTokens: Int
        public var outputTokens: Int

        public var totalInput: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }
    }

    public var isError: Bool
    public var result: String?
    /// Объект по `--json-schema`, сериализованный обратно в JSON.
    public var structuredOutput: Data?
    public var apiErrorStatus: Int?
    public var usage: Usage?
    public var durationMs: Int?
    public var numTurns: Int?

    public static func parse(_ data: Data) throws -> ClaudeResult {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var usage: Usage?
        if let u = obj["usage"] as? [String: Any] {
            usage = Usage(inputTokens: u["input_tokens"] as? Int ?? 0,
                          cacheCreationInputTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                          cacheReadInputTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                          outputTokens: u["output_tokens"] as? Int ?? 0)
        }
        let structured = (obj["structured_output"]).flatMap { v -> Data? in
            guard !(v is NSNull) else { return nil }
            return try? JSONSerialization.data(withJSONObject: v)
        }
        return ClaudeResult(
            isError: obj["is_error"] as? Bool ?? false,
            result: obj["result"] as? String,
            structuredOutput: structured,
            apiErrorStatus: obj["api_error_status"] as? Int,
            usage: usage,
            durationMs: obj["duration_ms"] as? Int,
            numTurns: obj["num_turns"] as? Int)
    }

    /// Ответ — исчерпанный лимит подписки.
    public var isUsageLimit: Bool {
        if apiErrorStatus == 429 { return true }
        guard isError || structuredOutput == nil, let text = result?.lowercased() else { return false }
        return Self.limitMarkers.contains { text.contains($0) }
    }

    public static let limitMarkers = ["usage limit", "limit reached", "rate limit", "limit will reset", "resets at", "лимит"]
}

/// Когда повторить после исчерпанного лимита.
public enum LimitRetry {
    /// Бэкофф по номеру попытки: 15 → 30 → 60 минут, дальше по 60.
    public static func backoff(attempt: Int) -> TimeInterval {
        [15, 30, 60][min(max(attempt, 0), 2)] * 60
    }

    /// Время сброса из текста ответа: «resets 3pm», «resets at 15:10», «resets 3:30pm».
    /// Возвращает ближайший такой момент после `now`.
    public static func resetTime(in text: String, now: Date, calendar: Calendar = .current) -> Date? {
        // CLI может назвать пояс: «resets 3pm (Europe/Moscow)». Тогда время — в нём.
        var calendar = calendar
        if let re = try? NSRegularExpression(pattern: #"\(([A-Za-z]+/[A-Za-z_+\-]+)\)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), let tz = TimeZone(identifier: String(text[r])) {
            calendar.timeZone = tz
        }
        let lower = text.lowercased()
        guard let r = lower.range(of: "reset") else { return nil }
        let tail = String(lower[r.upperBound...].prefix(40))
        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let range = Range(m.range(at: i), in: tail) else { return nil }
            return String(tail[range])
        }
        guard var hour = group(1).flatMap(Int.init) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        if let ampm = group(3) {
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        } else if group(2) == nil {
            return nil // голое число — не время
        }
        guard hour < 24, minute < 60 else { return nil }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        guard var date = calendar.date(from: c) else { return nil }
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date.addingTimeInterval(60) // минута запаса
    }
}
