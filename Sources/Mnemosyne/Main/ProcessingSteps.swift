import MnemosyneCore
import SwiftUI

/// Где сейчас встреча на пути «сохранение → распознавание → разбор → публичное».
/// `nil` — обработка не идёт (готово, ошибка, анализ отключён или идёт запись).
enum ProcessingStage: Int, CaseIterable {
    case saving, transcribing, analyzing, publicSummary

    @MainActor
    static func of(_ m: MeetingMeta, controller: AppController) -> ProcessingStage? {
        if m.status == .recording { return controller.recorder.phase == .saving ? .saving : nil }
        if m.status.needsProcessing { return .transcribing }
        let a = controller.analysis
        if a.running == m.id { return a.runningStep == "public" ? .publicSummary : .analyzing }
        // Разбор уже готов, в очереди только публичное саммари («Сформировать заново»).
        if a.isQueued(m.id), m.status == .done { return .publicSummary }
        if m.status == .analyzing || a.isQueued(m.id) { return .analyzing }
        return nil
    }

    var title: String {
        switch self {
        case .saving: String(localized: "Сохранение записи")
        case .transcribing: String(localized: "Распознавание речи")
        case .analyzing: String(localized: "Разбор встречи в Claude")
        case .publicSummary: String(localized: "Публичное саммари")
        }
    }

    /// Ключ шага в `meta.steps`: по нему берём время начала.
    var stepKey: String? {
        switch self {
        case .saving: nil
        case .transcribing: "transcribe"
        case .analyzing: "analyze"
        case .publicSummary: "public"
        }
    }

    /// Подпись в списке встреч.
    @MainActor
    static func listLabel(_ m: MeetingMeta, controller: AppController) -> String? {
        guard let stage = of(m, controller: controller) else { return nil }
        switch stage {
        case .saving: return String(localized: "сохраняется")
        case .transcribing: return controller.queue.current?.id == m.id ? String(localized: "распознаётся") : String(localized: "в очереди")
        case .analyzing:
            if controller.analysis.running == m.id { return String(localized: "разбирается") }
            return m.steps?["analyze"]?.status == .queuedLimit ? String(localized: "ждёт лимита") : String(localized: "ждёт анализа")
        case .publicSummary: return String(localized: "публичное саммари")
        }
    }
}

/// Блок в карточке, пока встреча обрабатывается: этапы с галочками, текущий — со спиннером и подсказкой.
struct ProcessingSteps: View {
    let library: LibraryModel
    let meta: MeetingMeta
    let stage: ProcessingStage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Встреча обрабатывается").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("идёт в фоне").font(.system(size: 12)).foregroundStyle(Theme.sec)
            }
            ForEach(ProcessingStage.allCases, id: \.self) { s in row(s) }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.side))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func row(_ s: ProcessingStage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if s.rawValue < stage.rawValue {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                } else if s == stage {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().strokeBorder(Theme.sec.opacity(0.6), lineWidth: 1.5).frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(s.title).foregroundStyle(s.rawValue > stage.rawValue ? Theme.sec : Theme.ink)
                    if s == stage, let key = s.stepKey, let start = meta.steps?[key]?.startedAt,
                       meta.steps?[key]?.status == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(UIFormat.duration(ctx.date.timeIntervalSince(start)))
                                .font(.system(size: 13)).foregroundStyle(Theme.sec).monospacedDigit()
                        }
                    }
                }
                if s == stage, let hint = hint(s) {
                    Text(hint).font(.system(size: 13)).foregroundStyle(Theme.sec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 15))
    }

    private func hint(_ s: ProcessingStage) -> String? {
        let c = library.controller
        switch s {
        case .saving:
            return String(localized: "Сохраняем аудио. Окно можно закрыть: обработка пойдёт в фоне.")
        case .transcribing:
            guard let cur = c.queue.current, cur.id == meta.id else {
                if let other = c.queue.current { return String(localized: "В очереди: сначала обработается «\(other.title)».") }
                return String(localized: "В очереди.")
            }
            switch cur.progress.step {
            case .prepare: return String(localized: "Готовим дорожки.")
            case .transcribe:
                let pct = "\(Int(cur.progress.fraction * 100))%"
                let progress = [pct, c.queue.remainingText].compactMap { $0 }.joined(separator: " · ")
                return String(localized: "\(progress). Транскрипт появится во вкладке «Транскрипт», саммари — следом.")
            case .diarize, .merge: return String(localized: "Определяем, кто говорил.")
            }
        case .analyzing:
            if c.analysis.running == meta.id { return String(localized: "Транскрипт уже готов — его можно читать.") }
            if meta.steps?["analyze"]?.status == .queuedLimit, let until = c.analysis.waitingUntil {
                return String(localized: "Лимит подписки Claude, повтор в \(AnalysisQueue.time(until)). Транскрипт уже готов.")
            }
            return String(localized: "Ждёт своей очереди. Транскрипт уже готов.")
        case .publicSummary:
            return String(localized: "Саммари готово, собираем версию для участников.")
        }
    }
}
