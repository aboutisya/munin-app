import Foundation
import MnemosyneCore

/// Шаг «анализ»: вызов 1 (`meeting-analysis`) → `analysis.json` + `summary_personal.md`.
public actor Analyzer {
    public static let skill = "meeting-analysis"

    public enum Outcome: Sendable {
        case done(usage: ClaudeResult.Usage?)
        /// Вход не изменился с прошлого раза — вызов не нужен.
        case skipped
    }

    private let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    public static var skillFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills/\(skill)/SKILL.md")
    }

    public func analyze(id: UUID, model: String = "sonnet", force: Bool = false, owner: OwnerProfile? = nil) async throws -> Outcome {
        guard let cli = ClaudeCLI(workDir: store.root.appending(path: ".work/claude")) else { throw ClaudeCLI.CLIError.notInstalled }
        guard let folder = store.locate(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let meta = try store.read(folder)
        let transcript = try MeetingProcessor.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json")))

        let skillText = (try? String(contentsOf: Self.skillFile, encoding: .utf8)) ?? ""
        guard !skillText.isEmpty else { throw ClaudeCLI.CLIError.badOutput("нет скилла \(Self.skillFile.path)") }
        let version = AnalysisInput.skillVersion(skillFile: skillText)
        let input = AnalysisInput.build(meta: meta, transcript: transcript, owner: owner)
        let hash = AnalysisInput.hash(input: input, skillVersion: version, model: model)

        if !force, meta.analysisHash == hash,
           FileManager.default.fileExists(atPath: folder.appending(path: "analysis.json").path) {
            return .skipped
        }

        _ = try await cli.checkSubscription()
        try mark(id, .running, status: .analyzing)
        let result = try await cli.runSkill(Self.skill, input: input, schema: AnalysisSchema.json, model: model)
        guard let data = result.structuredOutput else {
            throw ClaudeCLI.CLIError.badOutput(String((result.result ?? "пустой ответ").prefix(300)))
        }
        let analysis: Analysis
        do {
            analysis = try Analysis.decoder.decode(Analysis.self, from: data)
        } catch {
            throw ClaudeCLI.CLIError.badOutput("\(error)")
        }

        // Записываем в актуальную папку: её могли переименовать, пока шёл вызов.
        let target = store.locate(id: id) ?? folder
        try Analysis.encoder.encode(analysis).write(to: target.appending(path: "analysis.json"), options: .atomic)
        let current = try store.read(target)
        let md = PersonalSummary.render(analysis, meta: current, transcript: transcript)
        try md.write(to: target.appending(path: "summary_personal.md"), atomically: true, encoding: .utf8)

        try store.update(id: id) { m in
            m.analysisHash = hash
            m.analysisContext = m.analysisContextKey
            if m.status == .transcribed || m.status == .analyzing { m.status = .done }
            if let u = result.usage {
                m.usage = (m.usage ?? []) + [UsageRecord(step: "analyze", model: model, at: Date(),
                                                         inputTokens: u.totalInput, outputTokens: u.outputTokens,
                                                         durationMs: result.durationMs ?? 0)]
            }
            var s = m.steps?["analyze"] ?? StepState(status: .pending)
            s.status = .done
            s.finishedAt = Date()
            s.error = nil
            m.steps = (m.steps ?? [:]).merging(["analyze": s]) { $1 }
        }
        return .done(usage: result.usage)
    }

    private func mark(_ id: UUID, _ status: StepState.Status, status meetingStatus: MeetingStatus) throws {
        try store.update(id: id) { m in
            var s = m.steps?["analyze"] ?? StepState(status: .pending)
            s.status = status
            s.startedAt = Date()
            s.finishedAt = nil
            s.error = nil
            m.steps = (m.steps ?? [:]).merging(["analyze": s]) { $1 }
            m.status = meetingStatus
        }
    }
}
