import Foundation
import Testing
@testable import MnemosyneCore

struct SharingTests {
    let base = AnalysisTests()

    @Test func ownerAndVocabularyGoToAnalysisInput() {
        let owner = OwnerProfile(name: "Аня", role: "дизайнер мобильного банка", vocabulary: ["Figma", "дизайн-ревью"])
        let input = AnalysisInput.build(meta: base.meta, transcript: base.transcript(), owner: owner)
        #expect(input.hasPrefix("# Владелец\n\n- Имя: Аня\n- Чем занимается: дизайнер мобильного банка"))
        #expect(input.contains("## Словарь\nFigma, дизайн-ревью"))
        // Без профиля — как раньше.
        #expect(AnalysisInput.build(meta: base.meta, transcript: base.transcript()).hasPrefix("# Встреча"))
    }

    @Test func messengerAndProofreadInPublicInput() {
        let input = PublicInput.build(base.sample, meta: base.meta, transcript: base.transcript(), diagrams: [],
                                      messenger: .slack, proofread: false)
        #expect(input.contains("- Мессенджер: Slack"))
        #expect(input.contains("- Вычитка через ru-text: нет"))
    }

    @Test func versionCompare() {
        #expect(SkillInstaller.isNewer("1.10.0", than: "1.9.3"))
        #expect(SkillInstaller.isNewer("1.1", than: "1.0.9"))
        #expect(!SkillInstaller.isNewer("1.0.0", than: "1.0"))
        #expect(!SkillInstaller.isNewer("1.0.1", than: "1.1.0"))
    }

    @Test func installerCopiesUpgradesAndKeepsBackup() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "munin-skills-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let bundled = tmp.appending(path: "bundle"), user = tmp.appending(path: "user")
        func skill(_ dir: URL, _ name: String, _ version: String, _ body: String) throws {
            let d = dir.appending(path: name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try "---\nname: \(name)\nmetadata:\n  version: \(version)\n---\n\(body)".write(to: d.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try skill(bundled, "meeting-analysis", "1.1.0", "новый")
        try skill(bundled, "meeting-public", "1.1.0", "новый")
        try skill(user, "meeting-analysis", "1.0.1", "мои правки")

        var r = try SkillInstaller.install(from: bundled, to: user)
        #expect(r.installed == ["meeting-analysis", "meeting-public"])
        #expect(try String(contentsOf: user.appending(path: "meeting-analysis/SKILL.md"), encoding: .utf8).contains("новый"))
        #expect(try String(contentsOf: user.appending(path: "meeting-analysis/SKILL.md.1.0.1.bak"), encoding: .utf8).contains("мои правки"))

        // Та же версия — не трогаем, даже если пользователь поправил текст.
        try skill(user, "meeting-public", "1.1.0", "правка пользователя")
        r = try SkillInstaller.install(from: bundled, to: user)
        #expect(r.installed.isEmpty)
        #expect(try String(contentsOf: user.appending(path: "meeting-public/SKILL.md"), encoding: .utf8).contains("правка пользователя"))
        #expect(SkillInstaller.isInstalled("meeting-public", in: user))
        #expect(!SkillInstaller.isInstalled("ru-text", in: user))
    }
}
