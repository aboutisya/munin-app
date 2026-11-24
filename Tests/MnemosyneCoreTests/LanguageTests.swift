import Foundation
import Testing
@testable import MnemosyneCore

struct LanguageTests {
    private func transcript(_ language: String) -> Transcript {
        let speakers = [TranscriptSpeaker(id: "me", label: "Я", track: .me, nameSource: "me")]
        let u = Utterance(speaker: "me", track: .me, start: 0, end: 2, text: "Let's ship it",
                          words: [Word(text: "Let's ship it", start: 0, end: 2)])
        return Transcript(meetingId: UUID(), language: language, createdAt: Date(), speakers: speakers, utterances: [u],
                          removedEcho: 0, removedHallucinations: 0)
    }

    @Test(arguments: [
        ("meeting", "en", "en"),
        ("meeting", "ru", "ru"),
        ("meeting", "auto", "ru"),
        ("meeting", "", "ru"),
        ("ru", "en", "ru"),
        ("en", "ru", "en"),
    ])
    func summaryLanguage(setting: String, meeting: String, expected: String) {
        #expect(MeetingLanguage.summary(setting: setting, transcriptLanguage: meeting) == expected)
    }

    @Test func russianSummaryKeepsOldInput() {
        // Для русского блок не добавляется: хэши старых встреч не меняются.
        let meta = MeetingMeta(title: "Синк", startedAt: Date(), mode: .online)
        let ru = AnalysisInput.build(meta: meta, transcript: transcript("ru"), owner: OwnerProfile(name: "Мария"))
        #expect(!ru.contains("Язык саммари"))
        let en = AnalysisInput.build(meta: meta, transcript: transcript("en"), owner: OwnerProfile(name: "Мария"))
        #expect(en.contains("# Язык саммари") && en.contains("английский (en)"))
        let forcedRu = AnalysisInput.build(meta: meta, transcript: transcript("en"), owner: OwnerProfile(summaryLanguage: "ru"))
        #expect(!forcedRu.contains("Язык саммари"))
    }

    @Test func titles() {
        #expect(MeetingLanguage.title("en") == "Английский")
        #expect(MeetingLanguage.title("de") == "De")
    }
}
