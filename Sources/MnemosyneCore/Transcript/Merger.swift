import Foundation

/// Данные одной дорожки для склейки.
public struct TrackInput: Sendable {
    public var role: TrackInfo.Role
    /// Сколько секунд прибавить к времени дорожки, чтобы получить время встречи.
    public var offset: Double
    public var segments: [RecognizedSegment]
    /// Отрезки речи по VAD (время дорожки). Пусто — VAD не запускался.
    public var speech: [TimeSpan]
    /// Диаризация (время дорожки). `nil` — вся дорожка один говорящий («Я» в онлайне).
    public var turns: [SpeakerTurn]?
    /// Эмбеддинги спикеров диаризации.
    public var embeddings: [String: [Float]]

    public init(role: TrackInfo.Role, offset: Double, segments: [RecognizedSegment], speech: [TimeSpan] = [],
                turns: [SpeakerTurn]? = nil, embeddings: [String: [Float]] = [:]) {
        self.role = role
        self.offset = offset
        self.segments = segments
        self.speech = speech
        self.turns = turns
        self.embeddings = embeddings
    }
}

/// Склейка дорожек в один транскрипт: спикеры, реплики, чистка эха и галлюцинаций.
public enum Merger {
    /// Пауза, после которой начинается новая реплика того же спикера.
    public static let utteranceGap: Double = 1.5

    public static func merge(meetingId: UUID, language: String, tracks: [TrackInput], mode: RecordingMode,
                             calendarOthers: [Person] = [], createdAt: Date = Date()) -> Transcript {
        var removedHallucinations = 0
        var labeled: [(speaker: String, role: TrackInfo.Role, word: Word)] = []
        var embeddings: [String: [Float]] = [:]

        for track in tracks {
            var words: [Word] = []
            for segment in track.segments {
                if HallucinationFilter.isHallucination(segment) {
                    removedHallucinations += 1
                    continue
                }
                words += HallucinationFilter.keepWordsInSpeech(segment.words, speech: track.speech)
            }
            for word in words {
                let id: String
                if let turns = track.turns, !turns.isEmpty {
                    id = "\(track.role.rawValue):\(speaker(for: word, in: turns))"
                } else {
                    id = track.role == .me ? "me" : "\(track.role.rawValue):S1"
                }
                var w = word
                w.start += track.offset
                w.end += track.offset
                labeled.append((id, track.role, w))
            }
            for (k, v) in track.embeddings { embeddings["\(track.role.rawValue):\(k)"] = v }
        }

        var utterances = group(labeled)
        let echo: [Utterance]
        (utterances, echo) = EchoDedup.removeEcho(from: utterances)
        utterances = joinUninterrupted(utterances.sorted { $0.start < $1.start })
        // Зацикливание бывает размазано по многим сегментам из одного слова —
        // проверяем ещё раз уже на склеенных репликах.
        let before = utterances.count
        utterances.removeAll { HallucinationFilter.isRepetitionLoop(HallucinationFilter.normalize($0.text)) }
        removedHallucinations += before - utterances.count

        let speakers = makeSpeakers(utterances: utterances, mode: mode, calendarOthers: calendarOthers, embeddings: embeddings)
        var t = Transcript(meetingId: meetingId, language: language, createdAt: createdAt, speakers: speakers,
                           utterances: utterances, removedEcho: echo.count, removedHallucinations: removedHallucinations)
        t.echoRemoved = echo.isEmpty ? nil : echo
        return t
    }

    /// Спикер слова: отрезок диаризации с наибольшим пересечением, иначе ближайший.
    static func speaker(for word: Word, in turns: [SpeakerTurn]) -> String {
        var best: (String, Double)?
        for t in turns {
            let o = t.span.overlap(word.span)
            if o > 0, o > (best?.1 ?? 0) { best = (t.speaker, o) }
        }
        if let best { return best.0 }
        let mid = (word.start + word.end) / 2
        return turns.min { distance(mid, $0) < distance(mid, $1) }!.speaker
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// Слова одного спикера подряд → реплика; пауза больше `utteranceGap` — новая реплика.
    /// Группируем внутри спикера, а не по общей ленте, чтобы перекрывающаяся речь
    /// не рвала реплики на куски.
    static func group(_ labeled: [(speaker: String, role: TrackInfo.Role, word: Word)]) -> [Utterance] {
        var bySpeaker: [String: [(TrackInfo.Role, Word)]] = [:]
        for item in labeled { bySpeaker[item.speaker, default: []].append((item.role, item.word)) }
        var result: [Utterance] = []
        for (speaker, items) in bySpeaker {
            let sorted = items.sorted { $0.1.start < $1.1.start }
            var current: [Word] = []
            var role = sorted.first!.0
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                result.append(Utterance(speaker: speaker, track: role, start: first.start, end: last.end,
                                        text: join(current), words: current))
                current = []
            }
            for (r, w) in sorted {
                if let last = current.last, w.start - last.end > utteranceGap { flush() }
                role = r
                current.append(w)
            }
            flush()
        }
        return result
    }

    /// Склейка слов в текст. Whisper отдаёт «раз» и «-раз» отдельными словами — дефис прилипает.
    static func join(_ words: [Word]) -> String {
        var out = ""
        for w in words.map(\.text) {
            let attach = out.isEmpty
                || (w.hasPrefix("-") && w.count > 1 && w.dropFirst().first?.isLetter == true)
                || [",", ".", "!", "?", ":", ";", "…"].contains(where: { w.hasPrefix($0) })
            out += (attach ? "" : " ") + w
        }
        return out
    }

    /// Соседние реплики одного спикера склеиваем, если между ними никто не говорил
    /// и пауза меньше `continuationGap`: длинная пауза посреди фразы не должна рвать реплику.
    public static let continuationGap: Double = 8

    static func joinUninterrupted(_ sorted: [Utterance]) -> [Utterance] {
        var result: [Utterance] = []
        for u in sorted {
            if var last = result.last, last.speaker == u.speaker, u.start - last.end < continuationGap {
                last.end = max(last.end, u.end)
                last.words += u.words
                last.text = join(last.words)
                result[result.count - 1] = last
            } else {
                result.append(u)
            }
        }
        return result
    }

    /// Подписи спикеров. «Я» — дорожка микрофона в онлайне. Собеседники нумеруются
    /// по первому появлению. Если собеседник один и в событии ровно один другой
    /// участник — подставляем его имя (встреча 1:1).
    static func makeSpeakers(utterances: [Utterance], mode: RecordingMode, calendarOthers: [Person],
                             embeddings: [String: [Float]]) -> [TranscriptSpeaker] {
        var order: [String] = []
        var talk: [String: Double] = [:]
        var roles: [String: TrackInfo.Role] = [:]
        for u in utterances.sorted(by: { $0.start < $1.start }) {
            if !order.contains(u.speaker) { order.append(u.speaker) }
            talk[u.speaker, default: 0] += u.end - u.start
            roles[u.speaker] = u.track
        }
        let othersIds = order.filter { $0 != "me" && roles[$0] == .others }
        let roomIds = order.filter { $0 != "me" && roles[$0] == .me }
        let oneOnOne = mode == .online && othersIds.count == 1 && calendarOthers.count == 1

        return order.map { id in
            if id == "me" {
                return TranscriptSpeaker(id: id, label: "Я", track: .me, nameSource: "me", talkSeconds: talk[id] ?? 0)
            }
            if oneOnOne, othersIds.first == id, let person = calendarOthers.first {
                return TranscriptSpeaker(id: id, label: person.displayName, track: .others, nameSource: "calendar-1on1",
                                         email: person.email, embedding: embeddings[id], talkSeconds: talk[id] ?? 0)
            }
            let isRoom = roles[id] == .me
            let n = (isRoom ? roomIds : othersIds).firstIndex(of: id)! + 1
            let label = isRoom ? "В комнате \(n)" : "Собеседник \(n)"
            return TranscriptSpeaker(id: id, label: label, track: roles[id] ?? .others, nameSource: "generic",
                                     embedding: embeddings[id], talkSeconds: talk[id] ?? 0)
        }
    }
}

/// Третий слой эхоподавления: реплика «Я», которая совпадает по времени и по тексту
/// с речью собеседника, — это эхо из динамиков, удаляем.
public enum EchoDedup {
    /// Допуск по времени с учётом задержки эха и неточности таймкодов.
    public static let window: Double = 1.5
    /// Доля слов реплики «Я», найденных по порядку в речи собеседника.
    public static let threshold: Double = 0.6

    /// Возвращает оставшиеся реплики и удалённые как эхо (их сохраняем для проверки порога).
    public static func removeEcho(from utterances: [Utterance]) -> ([Utterance], [Utterance]) {
        let othersWords = utterances.filter { $0.track == .others }.flatMap(\.words).sorted { $0.start < $1.start }
        guard !othersWords.isEmpty else { return (utterances, []) }
        var removed: [Utterance] = []
        let kept = utterances.filter { u in
            guard u.speaker == "me" else { return true }
            let window = TimeSpan(u.start - Self.window, u.end + Self.window)
            let nearby = othersWords.filter { window.overlap($0.span) > 0 }
            if isEcho(mine: u.words.map(\.text), theirs: nearby.map(\.text)) {
                removed.append(u)
                return false
            }
            return true
        }
        return (kept, removed)
    }

    static func isEcho(mine: [String], theirs: [String]) -> Bool {
        let a = tokens(mine), b = tokens(theirs)
        guard a.count >= 2, !b.isEmpty else { return false }
        return Double(lcs(a, b)) / Double(a.count) >= threshold
    }

    static func tokens(_ words: [String]) -> [String] {
        words.flatMap { HallucinationFilter.normalize($0).split(separator: " ").map(String.init) }
    }

    /// Длина наибольшей общей подпоследовательности слов.
    static func lcs(_ a: [String], _ b: [String]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[b.count]
    }
}
