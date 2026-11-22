import Foundation

/// Справочник людей и голосов: `~/Meetings/.people/people.json`.
/// Когда спикера переназначают на человека, сюда сохраняется эмбеддинг его голоса —
/// по нему на следующих встречах человек будет узнаваться (этап 7).
public struct PeopleDirectory: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var email: String?
        /// Эмбеддинги голоса (WeSpeaker, 256 значений) — по одному с каждой встречи.
        public var voices: [[Float]]
        public var isMe: Bool?

        public init(id: UUID = UUID(), name: String, email: String? = nil, voices: [[Float]] = [], isMe: Bool? = nil) {
            self.id = id
            self.name = name
            self.email = email
            self.voices = voices
            self.isMe = isMe
        }
    }

    public var schema = 1
    public var people: [Record] = []

    public init(people: [Record] = []) {
        self.people = people
    }

    public static func url(root: URL) -> URL { root.appending(path: ".people/people.json") }

    public static func load(root: URL) -> PeopleDirectory {
        guard let data = try? Data(contentsOf: url(root: root)) else { return PeopleDirectory() }
        return (try? JSONDecoder().decode(PeopleDirectory.self, from: data)) ?? PeopleDirectory()
    }

    public func save(root: URL) throws {
        let url = Self.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    /// Найти человека по email, иначе по имени (без учёта регистра).
    public func find(name: String, email: String?) -> Record? {
        if let email, let r = people.first(where: { $0.email?.lowercased() == email.lowercased() }) { return r }
        return people.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Запомнить голос человека. Хранится не больше `maxVoices` последних эмбеддингов.
    public static let maxVoices = 10

    @discardableResult
    public mutating func remember(name: String, email: String?, voice: [Float]?) -> Record {
        var record = find(name: name, email: email) ?? Record(name: name, email: email)
        if record.email == nil { record.email = email }
        if let voice, !voice.isEmpty {
            record.voices.append(voice)
            if record.voices.count > Self.maxVoices { record.voices.removeFirst(record.voices.count - Self.maxVoices) }
        }
        if let i = people.firstIndex(where: { $0.id == record.id }) { people[i] = record } else { people.append(record) }
        return record
    }

    /// Мой голосовой отпечаток из онбординга: заменяет прежние записи моего голоса.
    public mutating func setMyVoice(name: String, voice: [Float]) {
        if let i = people.firstIndex(where: { $0.isMe == true }) {
            people[i].voices = [voice]
            if !name.isEmpty { people[i].name = name }
        } else {
            people.append(Record(name: name.isEmpty ? "Я" : name, voices: [voice], isMe: true))
        }
    }

    public var myVoice: Record? { people.first { $0.isMe == true && !$0.voices.isEmpty } }
}
