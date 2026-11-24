import Foundation
import MnemosyneCore
import MnemosynePipeline
import Observation

/// Очередь обработки записей: по одной встрече за раз.
@MainActor
@Observable
final class ProcessingQueue {
    struct Current: Equatable {
        var id: UUID
        var title: String
        var progress: ProcessingProgress
        var startedAt: Date
        var meetingSeconds: Double
    }

    private(set) var current: Current?
    private(set) var pending: [UUID] = []

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let processor: MeetingProcessor
    @ObservationIgnored var onFinished: ((UUID, String, Error?) -> Void)?

    init(store: MeetingStore) {
        self.store = store
        processor = MeetingProcessor(store: store)
    }

    func enqueue(_ id: UUID) {
        guard current?.id != id, !pending.contains(id) else { return }
        pending.append(id)
        runNext()
    }

    /// При запуске: всё, что не дообработалось (в т. ч. прерванное посередине).
    func resumeInterrupted() {
        for (_, meta) in store.list().reversed() where meta.status.needsProcessing {
            enqueue(meta.id)
        }
    }

    /// Встречи в статусе `saved`, которых нет ни в работе, ни в очереди. Такое бывает,
    /// если постановка в очередь сорвалась; вызывается по таймеру.
    func enqueueStranded() {
        for (_, meta) in store.list().reversed() where meta.status == .saved
            && current?.id != meta.id && !pending.contains(meta.id) {
            Log.app.info("stranded meeting enqueued: \(meta.id, privacy: .public)")
            enqueue(meta.id)
        }
    }

    /// Повторить после ошибки.
    func retry(_ id: UUID) {
        _ = try? store.update(id: id) { $0.status = .saved }
        enqueue(id)
    }

    /// Оценка оставшегося времени по скорости распознавания.
    var remainingText: String? {
        guard let c = current, c.progress.step == .transcribe, c.progress.fraction > 0.05 else { return nil }
        let elapsed = Date().timeIntervalSince(c.startedAt)
        let left = elapsed / c.progress.fraction * (1 - c.progress.fraction)
        return left < 60 ? String(localized: "Меньше минуты") : String(localized: "Около \(Int((left / 60).rounded(.up))) мин")
    }

    private func runNext() {
        guard current == nil, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        guard let folder = store.locate(id: id), let meta = try? store.read(folder) else { runNext(); return }
        let length = meta.durationSeconds ?? meta.tracks.compactMap(\.durationSeconds).max() ?? 0
        current = Current(id: id, title: meta.title, progress: .init(step: .prepare, fraction: 0, diarizationDone: false),
                          startedAt: Date(), meetingSeconds: length)
        let processor = self.processor
        Task {
            var failure: Error?
            do {
                let settings = AppSettings()
                try await processor.process(id: id, language: settings.language, vocabulary: settings.vocabulary) { p in
                    Task { @MainActor [weak self] in
                        guard let self, self.current?.id == id else { return }
                        self.current?.progress = p
                    }
                }
            } catch {
                failure = error
                Log.app.error("processing \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                _ = try? store.update(id: id) { meta in
                    meta.status = .failed
                    let running = meta.steps?.first { $0.value.status == .running }?.key ?? "transcribe"
                    var s = meta.steps?[running] ?? StepState(status: .failed)
                    s.status = .failed
                    s.error = error.localizedDescription
                    s.finishedAt = Date()
                    meta.steps = (meta.steps ?? [:]).merging([running: s]) { $1 }
                }
            }
            let title = (store.locate(id: id).flatMap { try? store.read($0) })?.title ?? meta.title
            current = nil
            onFinished?(id, title, failure)
            runNext()
        }
    }
}
