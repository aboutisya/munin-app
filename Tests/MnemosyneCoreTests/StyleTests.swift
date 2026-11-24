import Foundation
import Testing
@testable import MnemosyneCore

struct StyleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-styles-\(UUID().uuidString)")
    var store: MeetingStore { MeetingStore(root: root) }

    @Test func presetsFirstThenCustom() throws {
        let mine = SummaryStyle.custom(name: " Для руководителя ", prompt: "Три пункта: решения, риски, что нужно от руководителя.")
        try store.saveStyle(mine)
        let dir = StyleDirectory.load(root: root)
        #expect(dir.all.first?.id == SummaryStyle.businessId)
        #expect(dir.all.last?.name == "Для руководителя")
        #expect(dir.style(nil)?.isBusiness == true)
        #expect(mine.isCustom && mine.hint.hasSuffix("…"))

        try store.deleteStyle(mine.id)
        #expect(StyleDirectory.load(root: root).styles.isEmpty)
    }

    @Test func cleanStripsFence() {
        #expect(StyleInput.clean("```markdown\n## Итоги\n- Да\n```") == "## Итоги\n- Да")
        #expect(StyleInput.clean("  - Пункт \n") == "- Пункт")
    }

    @Test func activeVersionReadsFile() throws {
        let m = MeetingMeta(title: "Синк", startedAt: Date(), mode: .online)
        let folder = try store.create(m)
        #expect(store.activeStyledSummary(folder, meta: try store.read(folder)) == nil)

        let v = SummaryVersion(style: "short", name: "Краткий", createdAt: Date())
        try FileManager.default.createDirectory(at: folder.appending(path: "summaries"), withIntermediateDirectories: true)
        try "- Квоты не поднимаем".write(to: folder.appending(path: v.file), atomically: true, encoding: .utf8)
        _ = try store.update(id: m.id) { $0.summaryVersions = [v] }
        try store.setActiveStyle("short", meeting: m.id)
        #expect(store.activeStyledSummary(folder, meta: try store.read(folder)) == "- Квоты не поднимаем")

        // «Деловой» — обычный разбор, в meta не хранится.
        try store.setActiveStyle(SummaryStyle.businessId, meeting: m.id)
        #expect(try store.read(folder).summaryStyle == nil)
    }

    @Test func inputHasStyleAndAnalysis() {
        let style = SummaryStyle.presets[1]
        let input = StyleInput.build(style: style, analysisJSON: "{\"tldr\":[]}", analysisInput: "## Транскрипт")
        #expect(input.contains("Краткий") && input.contains(style.prompt) && input.contains("\"tldr\"") && input.hasSuffix("## Транскрипт"))
    }
}
