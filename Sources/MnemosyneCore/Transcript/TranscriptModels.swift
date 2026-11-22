import Foundation

/// Отрезок времени в секундах на шкале встречи (0 — начало самой ранней дорожки).
public struct TimeSpan: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }

    public func overlap(_ other: TimeSpan) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func shifted(by offset: Double) -> TimeSpan { TimeSpan(start + offset, end + offset) }
}

/// Слово от распознавателя.
public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Double?

    public init(text: String, start: Double, end: Double, probability: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }

    public var span: TimeSpan { TimeSpan(start, end) }
}

/// Сегмент распознавателя: фраза со словами.
public struct RecognizedSegment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
    public var noSpeechProb: Double?
    public var avgLogprob: Double?

    public init(start: Double, end: Double, text: String, words: [Word], noSpeechProb: Double? = nil, avgLogprob: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
    }
}

/// Отрезок диаризации: кто говорил когда (время дорожки).
public struct SpeakerTurn: Codable, Hashable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var span: TimeSpan { TimeSpan(start, end) }
}

public struct TranscriptSpeaker: Codable, Hashable, Sendable {
    /// `me`, `others:S1`, `mic:S2` — уникален в пределах встречи.
    public var id: String
    /// Подпись в транскрипте: «Я», «Мария Смирнова», «Собеседник 1».
    public var label: String
    public var track: TrackInfo.Role
    /// Откуда имя: `me`, `calendar-1on1`, `generic`, позже `voice`, `manual`.
    public var nameSource: String
    public var email: String?
    /// Эмбеддинг голоса (WeSpeaker, 256 значений) — для узнавания на следующих встречах.
    public var embedding: [Float]?
    public var talkSeconds: Double
    /// Голос похож на известного человека, но его нет среди приглашённых — только предлагаем («Мария?»).
    public var suggestedName: String?
    public var suggestedEmail: String?

    public init(id: String, label: String, track: TrackInfo.Role, nameSource: String, email: String? = nil,
                embedding: [Float]? = nil, talkSeconds: Double = 0) {
        self.id = id
        self.label = label
        self.track = track
        self.nameSource = nameSource
        self.email = email
        self.embedding = embedding
        self.talkSeconds = talkSeconds
    }
}

public struct Utterance: Codable, Hashable, Sendable {
    public var speaker: String
    public var track: TrackInfo.Role
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(speaker: String, track: TrackInfo.Role, start: Double, end: Double, text: String, words: [Word]) {
        self.speaker = speaker
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    public var span: TimeSpan { TimeSpan(start, end) }
}

public struct Transcript: Codable, Sendable {
    public var schema = 1
    public var meetingId: UUID
    public var language: String
    public var createdAt: Date
    public var speakers: [TranscriptSpeaker]
    public var utterances: [Utterance]
    /// Сколько реплик «Я» удалено как эхо собеседников.
    public var removedEcho: Int
    /// Сколько сегментов удалено как галлюцинации распознавателя.
    public var removedHallucinations: Int
    /// Реплики «Я», удалённые как эхо, — для проверки порога на реальных встречах.
    public var echoRemoved: [Utterance]?

    public init(meetingId: UUID, language: String, createdAt: Date, speakers: [TranscriptSpeaker],
                utterances: [Utterance], removedEcho: Int, removedHallucinations: Int) {
        self.meetingId = meetingId
        self.language = language
        self.createdAt = createdAt
        self.speakers = speakers
        self.utterances = utterances
        self.removedEcho = removedEcho
        self.removedHallucinations = removedHallucinations
    }

    public func speaker(_ id: String) -> TranscriptSpeaker? { speakers.first { $0.id == id } }
}
