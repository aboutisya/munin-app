import AppKit
import Foundation
import MnemosyneCore
import MnemosynePipeline
import Observation

/// Очередь анализа (вызов 1). По одной встрече за раз, лимит подписки ставит на паузу всю очередь.
@MainActor
@Observable
final class AnalysisQueue {
    enum Event {
        case done(id: UUID, title: String)
        case limit(title: String, retryAt: Date)
        case failed(id: UUID, title: String, error: String)
    }

    private(set) var state: AnalysisQueueState
    /// Встреча, которая сейчас анализируется.
    private(set) var running: UUID?

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let analyzer: Analyzer
    @ObservationIgnored private let publisher: Publisher
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Встречи, которые нужно проанализировать заново, даже если хэш входа не изменился.
    @ObservationIgnored private var forced = Set<UUID>()
    /// Публичное саммари сформировать заново, затерев ручные правки.
    @ObservationIgnored private var forcedPublic = Set<UUID>()
    /// Какой шаг сейчас идёт у `running`: `analyze` или `public`.
    private(set) var runningStep: String?

    // MARK: Пересборка в другом стиле — своя очередь, по одной встрече за раз.
    struct StyleJob: Equatable { var id: UUID; var style: SummaryStyle }
    private(set) var styleJobs: [StyleJob] = []
    private(set) var styleRunning: StyleJob?
    /// Последняя ошибка пересборки по встрече — показываем в карточке.
    private(set) var styleErrors: [UUID: String] = [:]
    @ObservationIgnored private let restyler: Restyler

    init(store: MeetingStore) {
        self.store = store
        analyzer = Analyzer(store: store)
        publisher = Publisher(store: store)
        restyler = Restyler(store: store)
        file = store.root.appending(path: ".queue.json")
        state = AnalysisQueueState.load(from: file)
    }

    /// Модель из настроек: Sonnet по умолчанию, Opus расходует лимит быстрее.
    var model: String { UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet" }

    func start() {
        // Встречи с готовым транскриптом, которые ещё не в очереди (например, после сбоя).
        for (_, meta) in store.list() where meta.status == .transcribed && meta.skipAnalysis != true {
            state.add(meta.id)
        }
        save()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNext() }
        }
        // После сна Mac таймер мог пропустить время сброса лимита.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNext() }
        }
        runNext()
    }

    func enqueue(_ id: UUID) {
        state.add(id)
        save()
        runNext()
    }

    func retryNow() {
        state.retryNow()
        save()
        runNext()
    }

    /// «Проанализировать» / «Обновить саммари» из карточки: новый вызов даже при том же входе.
    func reanalyze(_ id: UUID) {
        forced.insert(id)
        _ = try? store.update(id: id) { $0.status = .transcribed }
        state.retryNow()
        enqueue(id)
    }

    /// «Сформировать заново» на вкладке «Публичное»: только вызов 2, анализ не трогаем.
    func republish(_ id: UUID) {
        forcedPublic.insert(id)
        state.retryNow()
        enqueue(id)
    }

    /// Повторить анализ встречи с ошибкой.
    func retry(_ id: UUID) {
        _ = try? store.update(id: id) { $0.status = .transcribed }
        enqueue(id)
    }

    var waitingUntil: Date? { running == nil ? state.waitingUntil : nil }
    var waitingCount: Int { state.items.count }

    func isQueued(_ id: UUID) -> Bool { state.items.contains { $0.id == id } }

    private func save() { try? state.save(to: file) }

    private func runNext() {
        guard running == nil, let id = state.next(now: Date()) else { return }
        guard let folder = store.locate(id: id), let meta = try? store.read(folder) else {
            state.remove(id); save(); runNext(); return
        }
        // Пустой транскрипт (никто ничего не сказал) — вызывать Claude незачем.
        if Self.isEmptyTranscript(folder) {
            _ = try? store.update(id: id) { m in
                m.status = .done
                m.steps = (m.steps ?? [:]).merging(["analyze": StepState(status: .done, error: "пустой транскрипт")]) { $1 }
            }
            state.remove(id); save(); runNext(); return
        }
        running = id
        let analyzer = self.analyzer, publisher = self.publisher
        let model = self.model
        // Анализ нужен, если его ещё нет или его попросили обновить; иначе сразу публичное.
        let needsAnalysis = meta.status != .done || !FileManager.default.fileExists(atPath: folder.appending(path: "analysis.json").path)
        Task {
            var step = "analyze"
            do {
                if needsAnalysis {
                    runningStep = "analyze"
                    let force = forced.remove(id) != nil
                    _ = try await analyzer.analyze(id: id, model: model, force: force, owner: AppSettings().owner)
                }
                step = "public"
                runningStep = "public"
                let target = store.locate(id: id) ?? folder
                guard let analysis = MeetingEditing(store: store).analysis(target) else { throw ClaudeCLI.CLIError.badOutput("нет analysis.json") }
                let diagrams = await DiagramRenderer.renderAll(folder: target, analysis: analysis)
                let overwrite = forcedPublic.remove(id) != nil
                _ = try await publisher.publish(id: id, diagrams: diagrams, model: model, messenger: AppSettings().messenger,
                                                useRuText: AppSettings().useRuText,
                                                summaryLanguage: AppSettings().summaryLanguage,
                                                force: overwrite, overwriteEdits: overwrite)
                state.remove(id)
                onEvent?(.done(id: id, title: currentTitle(id) ?? meta.title))
                if needsAnalysis { applyDefaultStyle(id) }
            } catch ClaudeCLI.CLIError.usageLimit(let resetAt, _) {
                let retry = state.hitLimit(on: id, resetAt: resetAt, now: Date())
                markStep(id, step, .queuedLimit, error: "Лимит подписки, повтор в \(retry.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU"))))",
                         status: step == "analyze" ? .transcribed : nil)
                onEvent?(.limit(title: currentTitle(id) ?? meta.title, retryAt: retry))
            } catch {
                state.remove(id)
                forcedPublic.remove(id)
                let text = step == "public" ? String(localized: "Публичное саммари: \(error.localizedDescription)") : error.localizedDescription
                markStep(id, step, .failed, error: error.localizedDescription, status: step == "analyze" ? .failed : nil)
                onEvent?(.failed(id: id, title: currentTitle(id) ?? meta.title, error: text))
            }
            save()
            running = nil
            runningStep = nil
            runNext()
        }
    }

    /// Пересобрать саммари встречи в стиле. Уже идущую или ждущую пересборку не дублируем.
    func restyle(_ id: UUID, style: SummaryStyle) {
        guard !style.isBusiness else { return }
        styleErrors[id] = nil
        let job = StyleJob(id: id, style: style)
        guard styleRunning != job, !styleJobs.contains(job) else { return }
        styleJobs.append(job)
        runNextStyle()
    }

    func restyling(_ id: UUID) -> SummaryStyle? {
        if styleRunning?.id == id { return styleRunning?.style }
        return styleJobs.first { $0.id == id }?.style
    }

    /// После нового разбора: если по умолчанию выбран не «Деловой», сразу пересобираем в нём.
    private func applyDefaultStyle(_ id: UUID) {
        let styleId = AppSettings().defaultSummaryStyle
        guard styleId != SummaryStyle.businessId,
              let style = StyleDirectory.load(root: store.root).style(styleId) else { return }
        restyle(id, style: style)
    }

    private func runNextStyle() {
        guard styleRunning == nil, !styleJobs.isEmpty else { return }
        let job = styleJobs.removeFirst()
        styleRunning = job
        let restyler = self.restyler, model = self.model
        Task {
            do {
                _ = try await restyler.restyle(id: job.id, style: job.style, model: model, owner: AppSettings().owner)
            } catch ClaudeCLI.CLIError.usageLimit(let resetAt, _) {
                styleErrors[job.id] = resetAt.map { String(localized: "Лимит подписки Claude. Попробуйте после \(Self.time($0)).") }
                    ?? String(localized: "Лимит подписки Claude.")
                markStep(job.id, "style", .failed, error: "лимит подписки", status: nil)
            } catch {
                styleErrors[job.id] = error.localizedDescription
                markStep(job.id, "style", .failed, error: error.localizedDescription, status: nil)
            }
            styleRunning = nil
            runNextStyle()
        }
    }

    private func currentTitle(_ id: UUID) -> String? {
        store.locate(id: id).flatMap { try? store.read($0) }?.title
    }

    private func markStep(_ id: UUID, _ step: String, _ status: StepState.Status, error: String, status meetingStatus: MeetingStatus?) {
        _ = try? store.update(id: id) { m in
            var s = m.steps?[step] ?? StepState(status: status)
            s.status = status
            s.error = error
            s.finishedAt = Date()
            m.steps = (m.steps ?? [:]).merging([step: s]) { $1 }
            if let meetingStatus { m.status = meetingStatus }
        }
    }

    static func isEmptyTranscript(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appending(path: "transcript.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let utterances = obj["utterances"] as? [Any] else { return false }
        return utterances.isEmpty
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(UILanguage.locale))
    }
}
