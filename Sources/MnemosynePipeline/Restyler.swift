import Foundation
import MnemosyneCore

/// Пересборка саммари в другом стиле: вызов `meeting-style` → `summaries/<стиль>.md`.
/// Распознавание и основной разбор не повторяются: на входе готовый `analysis.json` и транскрипт.
public actor Restyler {
    public static let skill = "meeting-style"

    private let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    public func restyle(id: UUID, style: SummaryStyle, model: String = "sonnet", owner: OwnerProfile? = nil) async throws -> ClaudeResult.Usage? {
        guard !style.isBusiness else { return nil }
        guard let cli = ClaudeCLI(workDir: store.root.appending(path: ".work/claude")) else { throw ClaudeCLI.CLIError.notInstalled }
        guard let folder = store.locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let meta = try store.read(folder)
        let transcript = try MeetingProcessor.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json")))
        let analysisJSON = try String(contentsOf: folder.appending(path: "analysis.json"), encoding: .utf8)

        let base = AnalysisInput.build(meta: meta, transcript: transcript, owner: owner)
        let input = StyleInput.build(style: style, analysisJSON: analysisJSON, analysisInput: base)

        _ = try await cli.checkSubscription()
        try mark(id, .running)
        let result = try await cli.runSkill(Self.skill, input: input, schema: StyleInput.schema, model: model)
        guard let data = result.structuredOutput,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["markdown"] as? String else {
            throw ClaudeCLI.CLIError.badOutput(String((result.result ?? "пустой ответ").prefix(300)))
        }
        let markdown = StyleInput.clean(raw)
        guard !markdown.isEmpty else { throw ClaudeCLI.CLIError.badOutput("пустое саммари") }

        // Пишем в актуальную папку: её могли переименовать, пока шёл вызов.
        let target = store.locate(id: id) ?? folder
        let version = SummaryVersion(style: style.id, name: style.name, createdAt: Date())
        let file = target.appending(path: version.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: file, atomically: true, encoding: .utf8)

        try store.update(id: id) { m in
            var versions = m.summaryVersions ?? []
            versions.removeAll { $0.style == style.id }
            versions.append(version)
            m.summaryVersions = versions
            m.summaryStyle = style.id
            if let u = result.usage {
                m.usage = (m.usage ?? []) + [UsageRecord(step: "style", model: model, at: Date(),
                                                         inputTokens: u.totalInput, outputTokens: u.outputTokens,
                                                         durationMs: result.durationMs ?? 0)]
            }
            var s = m.steps?["style"] ?? StepState(status: .pending)
            s.status = .done
            s.finishedAt = Date()
            s.error = nil
            m.steps = (m.steps ?? [:]).merging(["style": s]) { $1 }
        }
        return result.usage
    }

    private func mark(_ id: UUID, _ status: StepState.Status) throws {
        try store.update(id: id) { m in
            var s = StepState(status: status)
            s.startedAt = Date()
            m.steps = (m.steps ?? [:]).merging(["style": s]) { $1 }
        }
    }
}
