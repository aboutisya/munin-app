import Foundation
import Testing
@testable import MnemosyneCore

struct PublicTests {
    let base = AnalysisTests()

    @Test func publicInputHasNoPrivateFields() {
        let input = PublicInput.build(base.sample, meta: base.meta, transcript: base.transcript(), diagrams: [])
        // Тональность, конфликт, фидбек и цитаты сюда попасть не могут.
        for privateText in ["напряжённая", "Спор о том", "Позиционный торг", "Давай поймём", "Нет, это не наша задача", "00:12", "Олег"] {
            #expect(!input.contains(privateText), "утекло: \(privateText)")
        }
        #expect(input.contains("- Релиз не переносим"))
        #expect(input.contains("- Релиз в четверг"))
        #expect(input.contains("| Подготовить сборку | Мария Смирнова | 2026-11-26 | к четвергу |"))
        #expect(!input.contains("## Схемы"))
    }

    @Test func namesResolveOwnerAndHideGenericLabels() {
        var meta = base.meta
        meta.participants = [Person(name: "Мария Смирнова", status: .accepted, isOrganizer: true), Person(name: "Илья", isMe: true)]
        var a = base.sample
        a.actionItems.append(.init(what: "Сверить квоты", who: "Я", due: "", dueSaid: "", ts: ""))
        a.actionItems.append(.init(what: "Проверить логи", who: "К1", due: "", dueSaid: "", ts: ""))
        let input = PublicInput.build(a, meta: meta, transcript: base.transcript(), diagrams: [.init(title: "Процесс релиза", file: "diagrams/01-flowchart.png")])
        #expect(input.contains("| Сверить квоты | Илья |  |  |"))
        // «В комнате 1» — безымянный спикер: в публичном тексте ответственный не назван.
        #expect(input.contains("| Проверить логи |  |  |  |"))
        #expect(!input.contains("В комнате 1"))
        #expect(!input.contains("Собеседник"))
        #expect(input.contains("- Автор сообщения: Илья"))
        #expect(input.contains("## Схемы (приложу картинками отдельно)\n- Процесс релиза"))
    }

    @Test func tableCellsAreEscaped() {
        var a = base.sample
        a.actionItems = [.init(what: "A | B\nC", who: "", due: "", dueSaid: "", ts: "")]
        let input = PublicInput.build(a, meta: base.meta, transcript: base.transcript(), diagrams: [])
        #expect(input.contains("| A / B C |"))
    }

    @Test func hashDependsOnRuTextAndSkill() {
        let h = PublicInput.hash(input: "x", skillVersion: "1.0.0", ruTextVersion: "aa", model: "sonnet")
        #expect(h == PublicInput.hash(input: "x", skillVersion: "1.0.0", ruTextVersion: "aa", model: "sonnet"))
        #expect(h != PublicInput.hash(input: "x", skillVersion: "1.0.0", ruTextVersion: "bb", model: "sonnet"))
        #expect(h != PublicInput.hash(input: "x", skillVersion: "1.0.1", ruTextVersion: "aa", model: "sonnet"))
        #expect(h != PublicInput.hash(input: "y", skillVersion: "1.0.0", ruTextVersion: "aa", model: "sonnet"))
        #expect(PublicInput.contentVersion("abc") != PublicInput.contentVersion("abd"))
    }

    @Test func cleanStripsMentionsAndFences() {
        #expect(PublicInput.clean("```markdown\n#### Синк\nОтвечает @masha.s, пишите на a@b.ru\n```") == "#### Синк\nОтвечает masha.s, пишите на a@b.ru\n")
        #expect(PublicInput.clean("  текст  ") == "текст\n")
    }

    @Test func schemaIsValid() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(PublicInput.schema.utf8)) as! [String: Any]
        #expect(obj["required"] as? [String] == ["markdown"])
        #expect(PublicInput.diagramBase(index: 0, type: "flowchart") == "01-flowchart")
    }
}
