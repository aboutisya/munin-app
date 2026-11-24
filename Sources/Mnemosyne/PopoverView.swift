import AppKit
import MnemosyneCore
import Observation
import SwiftUI

@MainActor
@Observable
final class PopoverModel {
    let controller: AppController
    var recorder: Recorder { controller.recorder }
    private var settings: AppSettings { controller.settings }
    var recent: [(folder: URL, meta: MeetingMeta)] = []
    var hotKeyAvailable = true
    var notice: String?

    init(controller: AppController) {
        self.controller = controller
    }

    func reloadRecent() {
        recent = Array(recorder.store.list().prefix(3))
    }

    var micUID: String? {
        get { recorder.preferredMicUID }
        set {
            recorder.preferredMicUID = newValue
            settings.micUID = newValue
        }
    }

    var echoCancellation: Bool {
        get { recorder.echoCancellationEnabled }
        set {
            recorder.echoCancellationEnabled = newValue
            settings.echoCancellation = newValue
        }
    }

    /// Режим для следующей записи: `nil` — «Авто» по событию.
    var modeOverride: RecordingMode? {
        get { recorder.modeOverride }
        set {
            recorder.modeOverride = newValue
            settings.modeOverride = newValue
        }
    }

    /// «Сейчас · 14:30–15:15»
    static func eventTime(_ e: CalendarEventInfo) -> String {
        "\(TitleView.time(e.start))–\(TitleView.time(e.end))"
    }

    /// «Микрофон MacBook · AirPods Pro»
    var deviceCaption: String {
        let mic = recorder.plannedMic.map(Self.micTitle) ?? String(localized: "Системный микрофон")
        var parts = [mic, recorder.devices.outputTitle]
        if recorder.plannedVoiceProcessing { parts.append(String(localized: "эхоподавление")) }
        return parts.joined(separator: " · ")
    }

    var recordingCaption: String {
        var parts = [recorder.devices.outputTitle]
        if recorder.voiceProcessingActive { parts.append(String(localized: "эхоподавление включено")) }
        else if let mic = recorder.micName { parts.append(mic) }
        return parts.joined(separator: " · ")
    }

    static func micTitle(_ device: AudioDevice) -> String {
        device.isBuiltIn ? String(localized: "Микрофон MacBook") : device.name
    }
}

// MARK: - Views

struct PopoverView: View {
    @Bindable var model: PopoverModel
    let close: () -> Void

    private var recorder: Recorder { model.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch recorder.phase {
            case .idle: idle
            case .recording: recording
            case .saving: saving
            }
        }
        .padding(18)
        .frame(width: 290, alignment: .leading)
    }

    // Ожидание

    @ViewBuilder private var idle: some View {
        idleHeader

        Button {
            model.controller.startRecording(event: model.controller.plannedEvent)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(.white).frame(width: 8, height: 8)
                Text("Записать")
            }
        }
        .buttonStyle(PillStyle(prominent: true))
        .keyboardShortcut(.defaultAction)

        devicesMenu

        if let error = recorder.lastError {
            Text(error).font(.system(size: 12)).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
        } else if let notice = model.notice {
            Caption(notice)
        }

        if let current = model.controller.queue.current {
            Divider()
            ProcessingBlock(current: current, remaining: model.controller.queue.remainingText)
        }

        let analysis = model.controller.analysis
        if let running = analysis.running, let title = model.recent.first(where: { $0.meta.id == running })?.meta.title {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Caption(String(localized: "Саммари · Claude"))
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        } else if let until = analysis.waitingUntil {
            Divider()
            LimitBlock(count: analysis.waitingCount, until: until, retry: analysis.retryNow)
        }

        if !model.recent.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.recent, id: \.meta.id) { item in
                    MenuRow(title: item.meta.title, detail: detail(for: item.meta),
                            detailColor: item.meta.status == .failed ? Palette.red : nil) {
                        open(item)
                    }
                }
            }
        }

        Divider()
        VStack(alignment: .leading, spacing: 10) {
            MenuRow(title: String(localized: "Открыть Мунин"), detail: "⌘O") {
                close()
                model.controller.openMain()
            }
            .keyboardShortcut("o")
            MenuRow(title: String(localized: "Настройки…"), detail: "⌘,") {
                close()
                model.controller.showSettings()
            }
            .keyboardShortcut(",")
            MenuRow(title: String(localized: "Выйти"), detail: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var devicesMenu: some View {
        Menu {
            Picker("Микрофон", selection: $model.micUID) {
                Text("Авто: микрофон MacBook").tag(String?.none)
                ForEach(recorder.devices.inputs) { device in
                    Text(device.isBluetooth ? String(localized: "\(device.name) — хуже качество") : device.name)
                        .tag(Optional(device.uid))
                }
            }
            Picker("Режим", selection: $model.modeOverride) {
                Text("Авто: по событию").tag(RecordingMode?.none)
                ForEach(RecordingMode.allCases, id: \.self) { Text($0.uiTitle).tag(Optional($0)) }
            }
            Toggle("Эхоподавление при динамиках", isOn: $model.echoCancellation)
            if !model.hotKeyAvailable {
                Text("⌃⌥⌘R занят другим приложением")
            }
        } label: {
            Text(model.deviceCaption + (model.modeOverride.map { " · \($0.uiTitle.lowercased())" } ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var idleHeader: some View {
        let controller = model.controller
        VStack(alignment: .leading, spacing: 4) {
            if let event = controller.plannedEvent {
                Caption(String(localized: "Сейчас · \(PopoverModel.eventTime(event))"))
                Text(event.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
            } else {
                Caption(controller.calendar.access == .denied ? String(localized: "Нет доступа к календарю") : String(localized: "Без события"))
                Text("Новая встреча").font(.system(size: 16, weight: .semibold))
            }
            if !controller.candidates.isEmpty {
                EventMenu(label: controller.plannedEvent == nil ? String(localized: "выбрать событие") : String(localized: "изменить"),
                          events: controller.candidates, selected: controller.plannedEvent?.id,
                          choose: controller.choose)
            }
        }
    }

    private func detail(for meta: MeetingMeta) -> String {
        if let label = ProcessingStage.listLabel(meta, controller: model.controller) { return label }
        switch meta.status {
        case .recording: return String(localized: "прервана")
        case .failed: return String(localized: "ошибка · повторить")
        case .saved, .transcribing, .diarizing, .merging:
            return model.controller.queue.current?.id == meta.id ? String(localized: "обработка") : String(localized: "в очереди")
        case .analyzing: return String(localized: "саммари")
        case .transcribed:
            return model.controller.analysis.isQueued(meta.id) ? String(localized: "ждёт анализа") : UIFormat.day(meta.startedAt)
        default: return UIFormat.day(meta.startedAt)
        }
    }

    /// Готовый транскрипт открываем, ошибку — перезапускаем, остальное — папка в Finder.
    /// Главное окно с карточкой встречи появится на этапе 5.
    private func open(_ item: (folder: URL, meta: MeetingMeta)) {
        let transcript = item.folder.appending(path: "transcript.md")
        let summary = item.folder.appending(path: "summary_personal.md")
        if item.meta.status == .failed {
            // Упал анализ — транскрипт есть, повторяем только анализ. Иначе — всю обработку.
            if item.meta.steps?["analyze"]?.status == .failed {
                model.controller.analysis.retry(item.meta.id)
            } else {
                model.controller.queue.retry(item.meta.id)
            }
            model.reloadRecent()
            return
        }
        _ = summary
        close()
        model.controller.openMain(meeting: item.meta.id,
                                  tab: FileManager.default.fileExists(atPath: transcript.path) && !FileManager.default.fileExists(atPath: summary.path) ? .transcript : nil)
    }

    // Запись

    @ViewBuilder private var recording: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(recorder.title)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Format.timer(recorder.elapsed))
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
            }
        }

        Waveform(levels: recorder.levels)
            .frame(height: 28)

        Button {
            model.controller.stopRecording()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                Text("Остановить")
            }
        }
        .buttonStyle(PillStyle(prominent: true))
        .keyboardShortcut(.defaultAction)

        Caption(model.recordingCaption)

        if recorder.offlineSuggested {
            VStack(alignment: .leading, spacing: 8) {
                Text("Звука приложений нет минуту. Похоже, встреча в переговорке.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Режим «Офлайн»") { recorder.setMode(.offline) }.buttonStyle(SmallPill(prominent: true))
                    Button("Нет") { recorder.dismissOfflineSuggestion() }.buttonStyle(SmallPill(prominent: false))
                }
            }
        }

        Divider()
        HStack {
            Text("Событие").font(.system(size: 13))
            Spacer()
            EventMenu(label: (recorder.event?.title ?? String(localized: "Без события")) + " ▾",
                      events: model.controller.recordingAlternatives, selected: recorder.event?.id,
                      choose: { recorder.bind(event: $0) })
        }

        if recorder.mode != .offline && !recorder.systemAudioActive {
            Text("Нет доступа к звуку приложений — пишется только микрофон")
                .font(.system(size: 12)).foregroundStyle(Palette.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Открыть настройки") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
            .buttonStyle(PillStyle(prominent: false))
        }
    }

    // Сохранение

    @ViewBuilder private var saving: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(recorder.title)
            Text("Сохраняем запись").font(.system(size: 16, weight: .semibold))
        }
        ProgressView().progressViewStyle(.linear)
        Caption(String(localized: "Сжимаем дорожки в m4a. Обычно несколько секунд."))
    }
}

// MARK: - Компоненты

enum Palette {
    static let red = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x5A / 255, blue: 0x5F / 255, alpha: 1)
            : NSColor(srgbRed: 0xD9 / 255, green: 0x30 / 255, blue: 0x36 / 255, alpha: 1)
    })
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MenuRow: View {
    let title: String
    let detail: String
    var detailColor: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).foregroundStyle(detailColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(prominent ? Palette.red : Color.primary.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .opacity(0.25 + 0.75 * Double(index) / Double(max(levels.count - 1, 1)))
                        .frame(height: max(2, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

/// Блок «Обработка»: шаги и прогресс распознавания, как в макете поповера.
struct ProcessingBlock: View {
    let current: ProcessingQueue.Current
    let remaining: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Caption(String(localized: "Обработка · \(UIFormat.duration(current.meetingSeconds))"))
                Text(current.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            step(String(localized: "Транскрипт"), state: transcriptState)
            if current.progress.step == .transcribe || current.progress.step == .prepare {
                ProgressView(value: current.progress.fraction).progressViewStyle(.linear).tint(.primary)
            }
            step(String(localized: "Спикеры"), state: speakersState)
            if let remaining { Caption(String(localized: "\(remaining). Пришлём уведомление.")) }
        }
    }

    private var transcriptState: String {
        switch current.progress.step {
        case .prepare: String(localized: "подготовка")
        case .transcribe: "\(Int(current.progress.fraction * 100))%"
        default: String(localized: "готово")
        }
    }

    private var speakersState: String {
        switch current.progress.step {
        case .merge: String(localized: "готово")
        case .diarize: String(localized: "идёт")
        default: ""
        }
    }

    private func step(_ title: String, state: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(state).foregroundStyle(state.isEmpty || state == String(localized: "готово") ? .secondary : .primary)
        }
        .font(.system(size: 13))
        .foregroundStyle(state.isEmpty ? .secondary : .primary)
    }
}

/// Очередь из-за лимита подписки, как в макете поповера «Очередь».
struct LimitBlock: View {
    let count: Int
    let until: Date
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Caption(String(localized: "Лимит подписки Claude"))
                Text(count == 1 ? "Встреча ждёт анализа" : "Встреч ждут анализа: \(count)")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Повторим в \(AnalysisQueue.time(until)), когда лимит обновится. Транскрипты уже готовы.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Повторить сейчас", action: retry).buttonStyle(PillStyle(prominent: false))
        }
    }
}
