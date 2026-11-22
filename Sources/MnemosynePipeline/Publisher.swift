import Foundation
import MnemosyneCore

/// Шаг «публичное»: вызов 2 (`meeting-public` → `/ru-text`) → `summary_public.md`.
/// На вход идёт только публичное подмножество анализа.
public actor Publisher {
    public static let skill = "meeting-public"
    public static let generatedFile = "summary_public.generated.md"
    public static let publicFile = "summary_public.md"

    public enum Outcome: Sendable { case done, skipped }

    private let store: MeetingStore

    public init(store: MeetingStore) { self.store = store }

    static var skillsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills") }

    /// `diagrams` — только те, что отрисовались в PNG: сломанный Mermaid в публичное не попадает.
    /// `overwriteEdits` — заменить ручные правки (пользователь сам попросил сформировать заново).
    public func publish(id: UUID, diagrams: [PublicInput.DiagramRef], model: String = "sonnet",
                        messenger: PublicInput.Messenger = .mattermost, useRuText: Bool = true,
                        force: Bool = false, overwriteEdits: Bool = false) async throws -> Outcome {
        guard let cli = ClaudeCLI(workDir: store.root.appending(path: ".work/claude")) else { throw ClaudeCLI.CLIError.notInstalled }
        guard let folder = store.locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let meta = try store.read(folder)
        let analysis = try Analysis.decoder.decode(Analysis.self, from: Data(contentsOf: folder.appending(path: "analysis.json")))
        let transcript = try MeetingProcessor.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json")))

        let skillText = (try? String(contentsOf: Self.skillsDir.appending(path: "\(Self.skill)/SKILL.md"), encoding: .utf8)) ?? ""
        guard !skillText.isEmpty else { throw ClaudeCLI.CLIError.badOutput("нет скилла ~/.claude/skills/\(Self.skill)") }
        // ru-text необязателен: установлен и включён — вычитываем им, иначе скилл вычитывает сам.
        let ruText = useRuText ? ((try? String(contentsOf: Self.skillsDir.appending(path: "ru-text/SKILL.md"), encoding: .utf8)) ?? "") : ""
        let proofread = !ruText.isEmpty

        let input = PublicInput.build(analysis, meta: meta, transcript: transcript, diagrams: diagrams,
                                      messenger: messenger, proofread: proofread)
        let hash = PublicInput.hash(input: input, skillVersion: AnalysisInput.skillVersion(skillFile: skillText),
                                    ruTextVersion: proofread ? PublicInput.contentVersion(ruText) : "none", model: model)
        if !force, meta.publicHash == hash, FileManager.default.fileExists(atPath: folder.appending(path: Self.publicFile).path) {
            return .skipped
        }

        _ = try await cli.checkSubscription()
        try mark(id, .running)
        // Инструменты только для /ru-text: сам скилл и чтение его справочников. Без ru-text — никаких.
        let result = try await cli.runSkill(Self.skill, input: input, schema: PublicInput.schema, model: model,
                                            tools: proofread ? "Skill,Read" : "",
                                            extraArgs: proofread ? ["--allowedTools", "Skill", "Read(~/.claude/skills/ru-text/**)"] : [],
                                            rawOutput: store.workDirectory(for: id).appending(path: "public.json"))
        guard let data = result.structuredOutput,
              let out = try? JSONDecoder().decode(PublicInput.Output.self, from: data),
              !out.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCLI.CLIError.badOutput(String((result.result ?? "пустой ответ").prefix(300)))
        }
        let text = PublicInput.clean(out.markdown)

        let target = store.locate(id: id) ?? folder
        let generatedURL = target.appending(path: Self.generatedFile)
        let publicURL = target.appending(path: Self.publicFile)
        let previous = try? String(contentsOf: generatedURL, encoding: .utf8)
        let current = try? String(contentsOf: publicURL, encoding: .utf8)
        // Ручные правки не затираем: текст меняется, только если его не трогали.
        let edited = current != nil && current != previous
        try text.write(to: generatedURL, atomically: true, encoding: .utf8)
        if !edited || overwriteEdits { try text.write(to: publicURL, atomically: true, encoding: .utf8) }

        try store.update(id: id) { m in
            m.publicHash = hash
            if let u = result.usage {
                m.usage = (m.usage ?? []) + [UsageRecord(step: "public", model: model, at: Date(),
                                                         inputTokens: u.totalInput, outputTokens: u.outputTokens,
                                                         durationMs: result.durationMs ?? 0)]
            }
            var s = m.steps?["public"] ?? StepState(status: .pending)
            s.status = .done
            s.finishedAt = Date()
            s.error = edited && !overwriteEdits ? "есть ручные правки, новая версия в \(Self.generatedFile)" : nil
            m.steps = (m.steps ?? [:]).merging(["public": s]) { $1 }
        }
        return .done
    }

    private func mark(_ id: UUID, _ status: StepState.Status) throws {
        try store.update(id: id) { m in
            var s = m.steps?["public"] ?? StepState(status: .pending)
            s.status = status
            s.startedAt = Date()
            s.finishedAt = nil
            s.error = nil
            m.steps = (m.steps ?? [:]).merging(["public": s]) { $1 }
        }
    }
}
