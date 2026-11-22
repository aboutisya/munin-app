import Foundation

/// Узнавание людей по голосу (§4): эмбеддинги спикеров встречи сравниваются с `people.json`.
/// - Свой голос (отпечаток из онбординга) отличает меня от людей в комнате в офлайн- и гибрид-режиме.
/// - Собеседник подставляется автоматически, только если голос похож **и** человек приглашён на встречу.
///   Иначе — подсказка «Похоже на …?», которую подтверждают руками.
public enum VoiceMatcher {
    /// Пороги косинусной близости. Допущение по первым записям: один голос через телефон давал 0,42–0,59
    /// на клипах по 5–10 с, разные голоса — до 0,47. Калибруем на реальных встречах.
    public static let autoThreshold: Float = 0.65
    public static let suggestThreshold: Float = 0.5
    public static let meThreshold: Float = 0.55

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Близость к человеку: лучшее из «к среднему голосу» и «к ближайшей записи».
    public static func similarity(_ e: [Float], to voices: [[Float]]) -> Float {
        let valid = voices.filter { $0.count == e.count }
        guard !valid.isEmpty else { return 0 }
        var mean = [Float](repeating: 0, count: e.count)
        for v in valid { for i in v.indices { mean[i] += v[i] / Float(valid.count) } }
        return max(cosine(e, mean), valid.map { cosine(e, $0) }.max() ?? 0)
    }

    public static func apply(_ transcript: Transcript, people: PeopleDirectory, invited: [Person]) -> Transcript {
        var t = transcript
        markMe(&t, people: people)
        nameOthers(&t, people: people, invited: invited)
        return t
    }

    /// Спикер дорожки микрофона, похожий на мой отпечаток, становится «Я».
    static func markMe(_ t: inout Transcript, people: PeopleDirectory) {
        guard !t.speakers.contains(where: { $0.id == "me" }),
              let me = people.people.first(where: { $0.isMe == true }), !me.voices.isEmpty else { return }
        let scored = t.speakers.filter { $0.track == .me && $0.embedding != nil }
            .map { ($0.id, similarity($0.embedding!, to: me.voices)) }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= meThreshold else { return }
        // Два похожих кандидата — не угадываем.
        if scored.count > 1, best.1 - scored[1].1 < 0.1 { return }
        let old = best.0
        for i in t.utterances.indices where t.utterances[i].speaker == old { t.utterances[i].speaker = "me" }
        if let i = t.speakers.firstIndex(where: { $0.id == old }) {
            t.speakers[i].id = "me"
            t.speakers[i].label = "Я"
            t.speakers[i].nameSource = "me"
        }
        renumberRoom(&t)
    }

    /// После того как один из «В комнате N» оказался мной, нумерация остальных сдвигается.
    static func renumberRoom(_ t: inout Transcript) {
        var n = 0
        for i in t.speakers.indices where t.speakers[i].track == .me && t.speakers[i].id != "me" && t.speakers[i].nameSource == "generic" {
            n += 1
            t.speakers[i].label = "В комнате \(n)"
        }
    }

    static func nameOthers(_ t: inout Transcript, people: PeopleDirectory, invited: [Person]) {
        let candidates = people.people.filter { $0.isMe != true && !$0.voices.isEmpty }
        guard !candidates.isEmpty else { return }
        var pairs: [(speaker: Int, person: PeopleDirectory.Record, score: Float)] = []
        for (i, s) in t.speakers.enumerated() where s.id != "me" && s.nameSource == "generic" {
            guard let e = s.embedding else { continue }
            for p in candidates {
                let score = similarity(e, to: p.voices)
                if score >= suggestThreshold { pairs.append((i, p, score)) }
            }
        }
        var usedSpeakers = Set<Int>(), usedPeople = Set<UUID>()
        // Имена, уже стоящие в транскрипте (например, из календаря 1:1), второй раз не раздаём.
        let taken = Set(t.speakers.filter { $0.nameSource != "generic" }.map { $0.label.lowercased() })
        for pair in pairs.sorted(by: { $0.score > $1.score }) {
            guard !usedSpeakers.contains(pair.speaker), !usedPeople.contains(pair.person.id),
                  !taken.contains(pair.person.name.lowercased()) else { continue }
            usedSpeakers.insert(pair.speaker)
            usedPeople.insert(pair.person.id)
            let isInvited = invited.contains { inv in
                (inv.email != nil && inv.email?.lowercased() == pair.person.email?.lowercased())
                    || inv.displayName.lowercased() == pair.person.name.lowercased()
            }
            if isInvited, pair.score >= autoThreshold {
                t.speakers[pair.speaker].label = pair.person.name
                t.speakers[pair.speaker].email = pair.person.email
                t.speakers[pair.speaker].nameSource = "voice"
            } else {
                t.speakers[pair.speaker].suggestedName = pair.person.name
                t.speakers[pair.speaker].suggestedEmail = pair.person.email
            }
        }
    }
}
