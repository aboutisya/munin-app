import Foundation
import Testing
@testable import MnemosyneCore

struct VoiceTests {
    /// Единичный вектор по оси `i` плюс немного шума по оси `j` — управляемая близость.
    func v(_ i: Int, _ noise: Float = 0, at j: Int = 7) -> [Float] {
        var x = [Float](repeating: 0, count: 16)
        x[i] = 1
        x[j] += noise
        return x
    }

    func transcript(_ speakers: [TranscriptSpeaker]) -> Transcript {
        let utterances = speakers.map { Utterance(speaker: $0.id, track: $0.track, start: 0, end: 1, text: "привет", words: []) }
        return Transcript(meetingId: UUID(), language: "ru", createdAt: Date(), speakers: speakers,
                          utterances: utterances, removedEcho: 0, removedHallucinations: 0)
    }

    @Test func cosineBasics() {
        #expect(abs(VoiceMatcher.cosine(v(0), v(0)) - 1) < 1e-5)
        #expect(abs(VoiceMatcher.cosine(v(0), v(1))) < 1e-5)
        #expect(VoiceMatcher.cosine([1, 2], [1]) == 0)
    }

    @Test func invitedPersonIsNamedAutomatically() {
        let people = PeopleDirectory(people: [.init(name: "Мария Смирнова", email: "m@x.ru", voices: [v(1)])])
        let t = transcript([
            TranscriptSpeaker(id: "me", label: "Я", track: .me, nameSource: "me"),
            TranscriptSpeaker(id: "others:S1", label: "Собеседник 1", track: .others, nameSource: "generic", embedding: v(1, 0.2)),
            TranscriptSpeaker(id: "others:S2", label: "Собеседник 2", track: .others, nameSource: "generic", embedding: v(2)),
        ])
        let r = VoiceMatcher.apply(t, people: people, invited: [Person(name: "Мария", email: "M@x.ru")])
        #expect(r.speakers[1].label == "Мария Смирнова")
        #expect(r.speakers[1].nameSource == "voice")
        #expect(r.speakers[2].label == "Собеседник 2")
        #expect(r.speakers[2].suggestedName == nil)
    }

    @Test func notInvitedIsOnlySuggested() {
        let people = PeopleDirectory(people: [.init(name: "Олег", voices: [v(1)])])
        let t = transcript([TranscriptSpeaker(id: "others:S1", label: "Собеседник 1", track: .others, nameSource: "generic", embedding: v(1))])
        let r = VoiceMatcher.apply(t, people: people, invited: [Person(name: "Мария")])
        #expect(r.speakers[0].label == "Собеседник 1")
        #expect(r.speakers[0].suggestedName == "Олег")
    }

    @Test func onePersonGetsOnlyTheClosestSpeaker() {
        let people = PeopleDirectory(people: [.init(name: "Мария", voices: [v(1)])])
        let t = transcript([
            TranscriptSpeaker(id: "others:S1", label: "Собеседник 1", track: .others, nameSource: "generic", embedding: v(1, 0.5)),
            TranscriptSpeaker(id: "others:S2", label: "Собеседник 2", track: .others, nameSource: "generic", embedding: v(1, 0.1)),
        ])
        let r = VoiceMatcher.apply(t, people: people, invited: [Person(name: "Мария")])
        #expect(r.speakers[1].label == "Мария")
        #expect(r.speakers[0].label == "Собеседник 1")
        #expect(r.speakers[0].suggestedName == nil)
    }

    @Test func myFingerprintMarksMeInRoom() {
        let people = PeopleDirectory(people: [.init(name: "Илья", voices: [v(3)], isMe: true)])
        let t = transcript([
            TranscriptSpeaker(id: "me:S1", label: "В комнате 1", track: .me, nameSource: "generic", embedding: v(4)),
            TranscriptSpeaker(id: "me:S2", label: "В комнате 2", track: .me, nameSource: "generic", embedding: v(3, 0.3)),
            TranscriptSpeaker(id: "me:S3", label: "В комнате 3", track: .me, nameSource: "generic", embedding: v(5)),
        ])
        let r = VoiceMatcher.apply(t, people: people, invited: [])
        #expect(r.speakers.map(\.id) == ["me:S1", "me", "me:S3"])
        #expect(r.speakers.map(\.label) == ["В комнате 1", "Я", "В комнате 2"])
        #expect(r.utterances[1].speaker == "me")
    }

    @Test func ambiguousFingerprintIsIgnored() {
        let people = PeopleDirectory(people: [.init(name: "Я", voices: [v(3)], isMe: true)])
        let t = transcript([
            TranscriptSpeaker(id: "me:S1", label: "В комнате 1", track: .me, nameSource: "generic", embedding: v(3, 0.2)),
            TranscriptSpeaker(id: "me:S2", label: "В комнате 2", track: .me, nameSource: "generic", embedding: v(3, 0.25)),
        ])
        let r = VoiceMatcher.apply(t, people: people, invited: [])
        #expect(!r.speakers.contains { $0.id == "me" })
    }
}
