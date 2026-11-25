import Foundation
import Testing
@testable import MnemosyneCore

struct PeopleIndexTests {
    func meeting(_ title: String, days: Double, speakers: [TranscriptSpeaker], utterances: [Utterance] = [],
                 participants: [Person] = []) -> (meta: MeetingMeta, transcript: Transcript?) {
        var meta = MeetingMeta(title: title, startedAt: Date(timeIntervalSince1970: 1_700_000_000 + days * 86400), mode: .online)
        meta.participants = participants
        let t = Transcript(meetingId: meta.id, language: "ru", createdAt: meta.startedAt, speakers: speakers,
                           utterances: utterances, removedEcho: 0, removedHallucinations: 0)
        return (meta, t)
    }

    func speaker(_ id: String, _ label: String, source: String = "generic", voice: [Float]? = nil, talk: Double = 30) -> TranscriptSpeaker {
        TranscriptSpeaker(id: id, label: label, track: .others, nameSource: source, embedding: voice, talkSeconds: talk)
    }

    @Test func countsKnownAndClustersUnknown() {
        var people = PeopleDirectory()
        people.remember(name: "Мария Смирнова", email: "maria@example.com", voice: [1, 0, 0])
        let a = meeting("Синк", days: 2, speakers: [speaker("others:S1", "Мария Смирнова", source: "manual"),
                                                     speaker("others:S2", "Собеседник 2", voice: [0, 1, 0])])
        let b = meeting("Демо", days: 1, speakers: [speaker("others:S1", "Собеседник 1", voice: [0, 0.99, 0.05]),
                                                     speaker("others:S2", "Собеседник 2", voice: [0, 0, 1]),
                                                     speaker("others:S3", "Собеседник 3", voice: [1, 1, 1], talk: 1)],
                        participants: [Person(name: "М. Смирнова", email: "maria@example.com", status: .accepted)])
        let o = PeopleIndex.build([a, b], people: people)
        let maria = o.known.first { $0.record.name == "Мария Смирнова" }
        #expect(maria?.meetings.map(\.title) == ["Синк", "Демо"])
        #expect(maria?.calendarMeetings == 1)
        // Похожие голоса с двух встреч — одна строка, короткая реплика не в счёт.
        #expect(o.unknown.count == 2)
        #expect(o.unknown.first { $0.refs.count == 2 }?.refs.map(\.meetingTitle) == ["Синк", "Демо"])
    }

    @Test func attendeesSkipMeAndNamedSpeakers() {
        let m = meeting("Синк", days: 1, speakers: [speaker("others:S1", "Мария Смирнова", source: "manual"),
                                                     speaker("others:S2", "Собеседник 2")],
                        participants: [Person(name: "Я", isMe: true),
                                       Person(name: "Мария Смирнова", email: "maria@example.com"),
                                       Person(name: "Олег Петров", email: "oleg@example.com")])
        let o = PeopleIndex.build([m], people: PeopleDirectory())
        #expect(o.unknown.first?.refs.first?.attendees.map(\.displayName) == ["Олег Петров"])
    }

    @Test func picksLongestCleanUtterance() {
        var meta = MeetingMeta(title: "x", startedAt: Date(), mode: .online)
        meta.tracks = [TrackInfo(role: .others, file: "audio_others.m4a")]
        let u = [
            Utterance(speaker: "others:S1", track: .others, start: 10, end: 11, text: "да", words: []),
            Utterance(speaker: "others:S1", track: .others, start: 20, end: 30, text: "длинная, но перебивают", words: []),
            Utterance(speaker: "others:S2", track: .others, start: 21, end: 29, text: "перебиваю", words: []),
            Utterance(speaker: "others:S1", track: .others, start: 40, end: 44, text: "чисто", words: [])
        ]
        let t = Transcript(meetingId: meta.id, language: "ru", createdAt: Date(), speakers: [], utterances: u,
                           removedEcho: 0, removedHallucinations: 0)
        let clip = VoiceSamples.pick(t, speaker: "others:S1", meta: meta)
        #expect(clip.map { Int($0.start) } == 40)
        #expect(clip.map { $0.duration <= VoiceSamples.maxSeconds } == true)
        #expect(VoiceSamples.pick(t, speaker: "others:S9", meta: meta) == nil)
    }
}
