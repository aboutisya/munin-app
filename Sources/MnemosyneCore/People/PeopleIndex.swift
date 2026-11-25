import Foundation

/// Сводка по людям для раздела «Люди»: кто на каких встречах, какие голоса не названы.
/// Считается по `meta.json` и `transcript.json` всех встреч, ничего не пишет.
public struct PeopleOverview: Sendable {
    /// Встреча, на которой был человек.
    public struct MeetingRef: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var title: String
        public var date: Date
        public var participants: Int
        /// Спикер в транскрипте (если человек говорил) — из него берётся слепок голоса.
        public var speakerId: String?
        public var talkSeconds: Double
    }

    public struct Known: Sendable, Identifiable {
        public var id: UUID { record.id }
        public var record: PeopleDirectory.Record
        /// Новые сверху.
        public var meetings: [MeetingRef]
        /// Из них узнан по почте или имени в участниках календаря.
        public var calendarMeetings: Int
        public var isMe: Bool { record.isMe == true }
    }

    /// Неназванный голос на одной встрече.
    public struct VoiceRef: Sendable, Hashable {
        public var meetingId: UUID
        public var meetingTitle: String
        public var date: Date
        public var speakerId: String
        public var label: String
        public var talkSeconds: Double
        public var quote: String
        public var suggestedName: String?
        public var embedding: [Float]?
        /// Участники встречи из календаря, ещё не названные среди спикеров (кроме меня) — кандидаты для «@».
        public var attendees: [Person] = []
    }

    /// Неназванный голос: один или несколько похожих голосов с разных встреч.
    public struct Unknown: Sendable, Identifiable {
        public var id: String { refs.first.map { "\($0.meetingId)#\($0.speakerId)" } ?? "" }
        /// Новые сверху.
        public var refs: [VoiceRef]
        public var label: String { refs.first?.label ?? "" }
        public var suggestedName: String? { refs.lazy.compactMap(\.suggestedName).first }
    }

    public var known: [Known]
    public var unknown: [Unknown]

}

public enum PeopleIndex {
    /// Голоса короче этого — шум или «угу», в «Не распознаны» не попадают.
    public static let minTalkSeconds: Double = 4

    public static func build(_ meetings: [(meta: MeetingMeta, transcript: Transcript?)],
                             people: PeopleDirectory) -> PeopleOverview {
        var refsByPerson: [UUID: [PeopleOverview.MeetingRef]] = [:]
        var calendarCount: [UUID: Int] = [:]
        var voices: [PeopleOverview.VoiceRef] = []
        let me = people.me

        for (meta, transcript) in meetings {
            let participants = meta.participants ?? []
            let count = max(participants.count, transcript?.speakers.count ?? 0)
            var seen: [UUID: PeopleOverview.MeetingRef] = [:]
            let named = Set((transcript?.speakers ?? []).filter { $0.nameSource != "generic" }.map { $0.label.lowercased() })
            let attendees = participants.filter { !$0.isMe && !named.contains($0.displayName.lowercased()) }

            for s in transcript?.speakers ?? [] {
                if s.id == "me" {
                    if let me { seen[me.id] = ref(meta, count, s) }
                    continue
                }
                if s.nameSource == "generic" {
                    guard s.talkSeconds >= minTalkSeconds, let t = transcript else { continue }
                    voices.append(PeopleOverview.VoiceRef(
                        meetingId: meta.id, meetingTitle: meta.title, date: meta.startedAt, speakerId: s.id,
                        label: s.label, talkSeconds: s.talkSeconds, quote: quote(t, speaker: s.id),
                        suggestedName: s.suggestedName, embedding: s.embedding, attendees: attendees))
                    continue
                }
                if let p = match(people, name: s.label, email: s.email) { seen[p.id] = ref(meta, count, s) }
            }
            for person in participants {
                guard let p = match(people, name: person.displayName, email: person.email) else { continue }
                calendarCount[p.id, default: 0] += 1
                if seen[p.id] == nil { seen[p.id] = ref(meta, count, nil) }
            }
            for (id, r) in seen { refsByPerson[id, default: []].append(r) }
        }

        let known = people.people.map { r in
            PeopleOverview.Known(record: r, meetings: (refsByPerson[r.id] ?? []).sorted { $0.date > $1.date },
                                 calendarMeetings: calendarCount[r.id] ?? 0)
        }
        .sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            if a.meetings.count != b.meetings.count { return a.meetings.count > b.meetings.count }
            return a.record.name.localizedStandardCompare(b.record.name) == .orderedAscending
        }
        return PeopleOverview(known: known, unknown: cluster(voices))
    }

    /// Похожие голоса с разных встреч — одна строка: назвал один раз, имя встало везде.
    static func cluster(_ voices: [PeopleOverview.VoiceRef]) -> [PeopleOverview.Unknown] {
        var groups: [PeopleOverview.Unknown] = []
        for v in voices.sorted(by: { $0.date > $1.date }) {
            if let e = v.embedding,
               let i = groups.firstIndex(where: { g in
                   !g.refs.contains { $0.meetingId == v.meetingId }
                       && g.refs.contains { $0.embedding.map { VoiceMatcher.cosine($0, e) >= VoiceMatcher.autoThreshold } ?? false }
               }) {
                groups[i].refs.append(v)
            } else {
                groups.append(PeopleOverview.Unknown(refs: [v]))
            }
        }
        return groups
    }

    static func match(_ people: PeopleDirectory, name: String, email: String?) -> PeopleDirectory.Record? {
        if let email, !email.isEmpty,
           let r = people.people.first(where: { $0.email?.lowercased() == email.lowercased() }) { return r }
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        return people.people.first { $0.name.lowercased() == n }
    }

    private static func ref(_ meta: MeetingMeta, _ count: Int, _ s: TranscriptSpeaker?) -> PeopleOverview.MeetingRef {
        PeopleOverview.MeetingRef(id: meta.id, title: meta.title, date: meta.startedAt, participants: count,
                                  speakerId: s?.id, talkSeconds: s?.talkSeconds ?? 0)
    }

    /// Самая длинная реплика спикера — чтобы по смыслу вспомнить, кто это.
    static func quote(_ t: Transcript, speaker: String) -> String {
        let best = t.utterances.filter { $0.speaker == speaker }.max { $0.text.count < $1.text.count }?.text ?? ""
        let text = best.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 160 ? String(text.prefix(157)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}
