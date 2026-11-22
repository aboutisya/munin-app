import CryptoKit
import Foundation

/// Результат вызова 1 (`meeting-analysis`): всё для личного саммари.
/// Ключи в JSON — snake_case, как в схеме и скилле.
public struct Analysis: Codable, Sendable, Equatable {
    public struct Quote: Codable, Sendable, Equatable { public var quote: String; public var ts: String }
    public struct Person: Codable, Sendable, Equatable {
        public var speaker: String
        public var name: String
        public var source: [String]
        public var confidence: Double
    }
    public struct Participants: Codable, Sendable, Equatable {
        public var count: Int
        public var people: [Person]
        public var mentionedNotPresent: [String]
    }
    public struct Topic: Codable, Sendable, Equatable { public var topic: String; public var start: String; public var markdown: String }
    public struct Insight: Codable, Sendable, Equatable { public var text: String; public var ts: String }
    public struct Decision: Codable, Sendable, Equatable { public var text: String; public var ts: String; public var owner: String }
    public struct ActionItem: Codable, Sendable, Equatable {
        public var what: String
        public var who: String
        public var due: String
        public var dueSaid: String
        public var ts: String
    }
    public struct Diagram: Codable, Sendable, Equatable { public var type: String; public var title: String; public var mermaid: String }
    public struct Tone: Codable, Sendable, Equatable { public var label: String; public var score: Double; public var evidence: [Quote] }
    public struct ParticipantTone: Codable, Sendable, Equatable { public var speaker: String; public var label: String; public var evidence: [Quote] }
    public struct Sentiment: Codable, Sendable, Equatable { public var overall: Tone; public var perParticipant: [ParticipantTone] }
    public struct Feedback: Codable, Sendable, Equatable {
        public var quote: String
        public var ts: String
        public var problem: String
        public var better: String
        public var principle: String
    }
    public struct Conflict: Codable, Sendable, Equatable {
        public var detected: Bool
        public var kinds: [String]
        public var summary: String
        public var mySpeechFeedback: [Feedback]
    }

    public var schemaVersion: Int
    public var language: String
    public var participants: Participants
    public var tldr: [String]
    public var summaryByTopics: [Topic]
    public var insights: [Insight]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var diagrams: [Diagram]
    public var sentiment: Sentiment
    public var conflict: Conflict

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// JSON Schema для `claude -p --json-schema`. Версия схемы входит в хэш шага.
public enum AnalysisSchema {
    public static let version = 1

    public static let json: String = {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": Array(props.keys).sorted(), "properties": props]
        }
        let str: [String: Any] = ["type": "string"]
        func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
        let quote = obj(["quote": str, "ts": str])
        let schema = obj([
            "schema_version": ["type": "integer"],
            "language": str,
            "participants": obj([
                "count": ["type": "integer"],
                "people": arr(obj([
                    "speaker": str, "name": str,
                    "source": arr(["type": "string", "enum": ["calendar", "voice", "mentioned", "transcript"]]),
                    "confidence": ["type": "number"],
                ])),
                "mentioned_not_present": arr(str),
            ]),
            "tldr": arr(str),
            "summary_by_topics": arr(obj(["topic": str, "start": str, "markdown": str])),
            "insights": arr(obj(["text": str, "ts": str])),
            "decisions": arr(obj(["text": str, "ts": str, "owner": str])),
            "action_items": arr(obj(["what": str, "who": str, "due": str, "due_said": str, "ts": str])),
            "diagrams": arr(obj([
                "type": ["type": "string", "enum": ["flowchart", "sequence", "timeline"]],
                "title": str, "mermaid": str,
            ])),
            "sentiment": obj([
                "overall": obj(["label": str, "score": ["type": "number"], "evidence": arr(quote)]),
                "per_participant": arr(obj(["speaker": str, "label": str, "evidence": arr(quote)])),
            ]),
            "conflict": obj([
                "detected": ["type": "boolean"],
                "kinds": arr(str),
                "summary": str,
                "my_speech_feedback": arr(obj(["quote": str, "ts": str, "problem": str, "better": str, "principle": str])),
            ]),
        ])
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }()
}

/// Кто записывает встречи: имя, чем занимается, словарь терминов. Из настроек приложения.
public struct OwnerProfile: Sendable, Equatable {
    public var name: String
    public var role: String
    public var vocabulary: [String]
    public init(name: String = "", role: String = "", vocabulary: [String] = []) {
        self.name = name
        self.role = role
        self.vocabulary = vocabulary
    }
}

/// Вход вызова 1: владелец, метаданные, участники, спикеры и транскрипт одним блоком.
public enum AnalysisInput {
    /// Короткие коды спикеров для модели: `Я`, `С1`, `К1`. Обратное отображение — для разбора ответа.
    public static func codes(for t: Transcript) -> [String: String] {
        var result: [String: String] = [:]
        var o = 0, r = 0
        for s in t.speakers {
            if s.id == "me" { result[s.id] = "Я"; continue }
            if s.track == .me { r += 1; result[s.id] = "К\(r)" } else { o += 1; result[s.id] = "С\(o)" }
        }
        return result
    }

    public static func build(meta: MeetingMeta, transcript t: Transcript, owner: OwnerProfile? = nil,
                             calendar: Calendar = .current) -> String {
        let codes = codes(for: t)
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd, EEEE, HH:mm"

        var lines: [String] = []
        if let owner, !(owner.name.isEmpty && owner.role.isEmpty) {
            lines += ["# Владелец", ""]
            if !owner.name.isEmpty { lines.append("- Имя: \(owner.name)") }
            if !owner.role.isEmpty { lines.append("- Чем занимается: \(owner.role)") }
            lines.append("")
        }
        lines += ["# Встреча", ""]
        lines.append("- Название: \(meta.title)")
        lines.append("- Дата: \(df.string(from: meta.startedAt))")
        if let d = meta.durationSeconds { lines.append("- Длительность: \(Format.duration(d))") }
        lines.append("- Режим: \(meta.mode.title.lowercased())")
        if let e = meta.event {
            lines.append("- Событие календаря: \(e.title)")
            if let loc = e.location?.nilIfEmpty { lines.append("- Место: \(loc)") }
            if let notes = e.notes?.nilIfEmpty {
                lines.append("")
                lines.append("## Описание события")
                lines.append(String(notes.prefix(2000)))
            }
        }

        let people = meta.participants ?? []
        if !people.isEmpty {
            lines += ["", "## Приглашённые"]
            for p in people {
                var s = "- \(p.displayName)"
                if p.isMe { s += " (это владелец записи, Я)" }
                if p.isOrganizer { s += ", организатор" }
                lines.append(s)
            }
        }

        if let words = owner?.vocabulary, !words.isEmpty {
            lines += ["", "## Словарь", words.joined(separator: ", ")]
        }

        lines += ["", "## Спикеры"]
        for s in t.speakers {
            let code = codes[s.id] ?? s.id
            var line = "- \(code): \(s.label), говорил \(Format.duration(s.talkSeconds))"
            if s.nameSource == "calendar-1on1" { line += " (имя из календаря, встреча один на один)" }
            lines.append(line)
        }

        lines += ["", "## Транскрипт", ""]
        for u in t.utterances {
            lines.append("[\(TranscriptMarkdown.timestamp(u.start))] \(codes[u.speaker] ?? u.speaker): \(u.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Хэш входа шага: вход + версия скилла + модель + версия схемы.
    /// Совпал с прошлым — вызов не нужен.
    public static func hash(input: String, skillVersion: String, model: String) -> String {
        let material = "\(input)\n--\nskill=\(skillVersion)\nmodel=\(model)\nschema=\(AnalysisSchema.version)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Версия скилла из frontmatter `metadata.version`.
    public static func skillVersion(skillFile: String) -> String {
        for line in skillFile.split(separator: "\n").prefix(20) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("version:") { return t.dropFirst("version:".count).trimmingCharacters(in: .whitespaces) }
        }
        return "0"
    }
}
