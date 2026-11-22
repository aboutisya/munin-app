import Foundation

/// Разбор JSON, который пишет `mlx_whisper --output-format json --word-timestamps True`.
public enum WhisperOutput {
    struct Raw: Decodable {
        struct Segment: Decodable {
            var start: Double
            var end: Double
            var text: String
            var words: [RawWord]?
            var no_speech_prob: Double?
            var avg_logprob: Double?
        }
        struct RawWord: Decodable {
            var word: String
            var start: Double
            var end: Double
            var probability: Double?
        }
        var text: String?
        var language: String?
        var segments: [Segment]
    }

    public static func parse(_ data: Data) throws -> (language: String?, segments: [RecognizedSegment]) {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let segments = raw.segments.map { s in
            RecognizedSegment(
                start: s.start, end: s.end,
                text: s.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: (s.words ?? []).map {
                    Word(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end, probability: $0.probability)
                }.filter { !$0.text.isEmpty },
                noSpeechProb: s.no_speech_prob, avgLogprob: s.avg_logprob)
        }
        return (raw.language, segments)
    }

    /// Прогресс из строк `--verbose True`: «[01:23.456 --> 01:27.000] текст». Возвращает конец сегмента, с.
    public static func progressSeconds(fromLine line: String) -> Double? {
        guard line.hasPrefix("["), let arrow = line.range(of: "-->"), let close = line.firstIndex(of: "]") else { return nil }
        let end = line[arrow.upperBound..<close].trimmingCharacters(in: .whitespaces)
        return parseTimestamp(end)
    }

    static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

/// Фильтр типичных галлюцинаций Whisper на тишине и музыке.
public enum HallucinationFilter {
    /// Фразы, которые Whisper выдумывает на паузах (выучены на субтитрах YouTube).
    static let stopPhrases: [String] = [
        "продолжение следует",
        "субтитры сделал",
        "субтитры создавал",
        "субтитры подогнал",
        "редактор субтитров",
        "корректор",
        "спасибо за просмотр",
        "спасибо за внимание",
        "подписывайтесь на канал",
        "подпишись на канал",
        "ставьте лайки",
        "до новых встреч",
        "динамичная музыка",
        "спокойная музыка",
        "музыка",
        "аплодисменты",
        "смех",
        "dimatorzok",
        "thank you for watching",
        "thanks for watching",
    ]

    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let letters = lowered.unicodeScalars.map { CharacterSet.letters.union(.decimalDigits).contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Сегмент целиком — галлюцинация: совпадает с фразой стоп-листа или начинается с неё
    /// и короткий, либо модель сама уверена, что речи нет, а текст короткий.
    public static func isHallucination(_ segment: RecognizedSegment) -> Bool {
        let norm = normalize(segment.text)
        if norm.isEmpty { return true }
        let wordCount = norm.split(separator: " ").count
        for phrase in stopPhrases {
            if norm == phrase { return true }
            // Хвост вроде «Субтитры сделал DimaTorzok» или «Корректор А. Кулакова».
            // Для однословных фраз («музыка») хвост не разрешаем: это может быть живая речь.
            let prefixAllowed = phrase.contains(" ") || phrase == "корректор"
            if prefixAllowed, norm.hasPrefix(phrase + " "), wordCount <= phrase.split(separator: " ").count + 4 { return true }
        }
        if let p = segment.noSpeechProb, p > 0.8, (segment.avgLogprob ?? 0) < -1.0, wordCount <= 4 { return true }
        if isRepetitionLoop(norm) { return true }
        return false
    }

    /// Зацикливание: «Воспоминание Воспоминание Воспоминание…». Живая речь
    /// почти никогда не состоит из одного-двух слов, повторённых много раз.
    public static func isRepetitionLoop(_ norm: String) -> Bool {
        let words = norm.split(separator: " ")
        guard words.count >= 6 else { return false }
        let unique = Set(words).count
        return Double(unique) / Double(words.count) <= 0.25
    }

    /// Слова, которые не попадают ни в один отрезок речи VAD, выбрасываем:
    /// на тишине Whisper дорисовывает слова, которых не было.
    public static func keepWordsInSpeech(_ words: [Word], speech: [TimeSpan], tolerance: Double = 0.3) -> [Word] {
        guard !speech.isEmpty else { return words }
        return words.filter { w in
            let span = TimeSpan(w.start - tolerance, w.end + tolerance)
            return speech.contains { $0.overlap(span) > 0 }
        }
    }
}
