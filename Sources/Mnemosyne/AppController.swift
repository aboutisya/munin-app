import AppKit
import MnemosyneCore
import Observation

/// Связывает запись, календарь, уведомления и окно названия.
@MainActor
@Observable
final class AppController {
    let recorder: Recorder
    let calendar: CalendarService
    let settings: AppSettings
    let queue: ProcessingQueue
    let analysis: AnalysisQueue
    @ObservationIgnored let notifications: Notifications
    @ObservationIgnored private(set) lazy var mainWindow = MainWindowController(library: LibraryModel(controller: self))
    /// Установка распознавания — общая для онбординга и настроек.
    let whisperSetup = WhisperSetup()
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(controller: self)
    @ObservationIgnored private lazy var onboardingWindow = OnboardingWindowController(controller: self)

    func showSettings(newTag: Bool = false, scrollToTags: Bool = false) { settingsWindow.show(newTag: newTag, scrollToTags: scrollToTags) }
    func showOnboarding() { onboardingWindow.show() }

    /// Пока открыто хоть одно обычное окно, приложение в Dock и ⌘Tab; закрылось последнее — снова только в строке меню.
    func restoreActivationPolicy(closing: NSWindow?) {
        DispatchQueue.main.async {
            let open = NSApp.windows.filter { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Открыть главное окно, при необходимости на встрече.
    func openMain(meeting id: UUID? = nil, tab: LibraryModel.Tab? = nil) {
        mainWindow.show(meeting: id, tab: tab)
    }
    @ObservationIgnored private var titleWindow: TitleWindowController?
    @ObservationIgnored private var ticker: Timer?

    /// События, которые идут сейчас (для поповера в ожидании).
    private(set) var candidates: [CalendarEventInfo] = []
    /// Событие, выбранное для следующей записи. `nil` — первое из кандидатов.
    var chosenEventId: String?
    /// Пользователь явно выбрал «Без события».
    var noEventChosen = false

    // Напоминания
    /// О каких событиях уже напомнили. Хранится в UserDefaults, чтобы после
    /// перезапуска (в т. ч. запуска кликом по уведомлению) не напоминать снова.
    @ObservationIgnored private var notifiedStarts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notifiedStarts") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "notifiedStarts") }
    }
    @ObservationIgnored private var endReminderAt: Date?
    @ObservationIgnored private var endNotifiedFor: Date?

    init(recorder: Recorder, settings: AppSettings) {
        self.recorder = recorder
        self.settings = settings
        calendar = CalendarService()
        notifications = Notifications()
        queue = ProcessingQueue(store: recorder.store)
        analysis = AnalysisQueue(store: recorder.store)
        notifications.onAction = { [weak self] action in self?.handle(action) }
        queue.onFinished = { [weak self] id, title, error in
            guard let self else { return }
            if let error {
                self.notifications.postProcessingFailed(title: title, error: error.localizedDescription)
                return
            }
            let meta = self.recorder.store.locate(id: id).flatMap { try? self.recorder.store.read($0) }
            if meta?.skipAnalysis == true, let folder = self.recorder.store.locate(id: id) {
                // Анализ не нужен — уведомляем о транскрипте. Иначе ждём саммари: одно уведомление на встречу.
                self.notifications.postTranscriptReady(title: title, file: folder.appending(path: "transcript.md"))
            } else {
                self.analysis.enqueue(id)
            }
        }
        analysis.onEvent = { [weak self] event in
            guard let self else { return }
            let store = self.recorder.store
            switch event {
            case .done(let id, let title):
                if let folder = store.locate(id: id) {
                    self.notifications.postSummaryReady(title: title, file: folder.appending(path: "summary_personal.md"))
                }
            case .limit(let title, let retryAt):
                self.notifications.postLimit(title: title, retryAt: AnalysisQueue.time(retryAt))
            case .failed(let id, let title, let error):
                let file = store.locate(id: id)?.appending(path: "transcript.md")
                self.notifications.postAnalysisFailed(title: title, error: error, transcript: file)
            }
        }
    }

    func launch() async {
        await calendar.requestAccess()
        await notifications.requestAuthorization()
        refreshCandidates()
        let today = Calendar.current.startOfDay(for: Date())
        let events = calendar.events(from: today, to: today.addingTimeInterval(7 * 86400))
        Log.app.info("calendar access=\(String(describing: self.calendar.access), privacy: .public) events7d=\(events.count, privacy: .public) withLink=\(events.filter { $0.callURL != nil }.count, privacy: .public) candidates=\(self.candidates.count, privacy: .public)")
        purgeOldAudioIfEnabled()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    // MARK: - Срок хранения аудио

    @ObservationIgnored private var lastPurge: Date?

    /// Только если в настройках стоит галочка; проверяем при запуске и раз в 6 часов.
    func purgeOldAudioIfEnabled() {
        guard settings.deleteOldAudio else { return }
        lastPurge = Date()
        let store = recorder.store
        let n = AudioRetention.purge(store: store)
        if n > 0 { Log.app.info("audio retention: removed audio of \(n, privacy: .public) meetings") }
    }

    // MARK: - Событие для записи

    var plannedEvent: CalendarEventInfo? {
        guard !noEventChosen else { return nil }
        if let id = chosenEventId, let e = candidates.first(where: { $0.id == id }) { return e }
        return candidates.first
    }

    func choose(_ event: CalendarEventInfo?) {
        if let event {
            chosenEventId = event.id
            noEventChosen = false
        } else {
            chosenEventId = nil
            noEventChosen = true
        }
    }

    func refreshCandidates() {
        candidates = calendar.currentCandidates()
        if let id = chosenEventId, !candidates.contains(where: { $0.id == id }) { chosenEventId = nil }
    }

    /// События для смены привязки во время записи.
    var recordingAlternatives: [CalendarEventInfo] {
        guard let start = recorder.startedAt else { return [] }
        return calendar.overlapping(start: start, end: max(Date(), start.addingTimeInterval(60)))
    }

    // MARK: - Старт и стоп

    func toggle() {
        switch recorder.phase {
        case .idle: startRecording(event: plannedEvent)
        case .recording: stopRecording()
        case .saving: break
        }
    }

    func startRecording(event: CalendarEventInfo?) {
        Task {
            await recorder.start(event: event)
            endReminderAt = nil
            endNotifiedFor = nil
            noEventChosen = false
            chosenEventId = nil
        }
    }

    /// Стоп → сразу окно названия; запись сохраняется параллельно.
    func stopRecording() {
        guard recorder.phase == .recording, let startedAt = recorder.startedAt else { return }
        let model = TitleModel(
            title: recorder.title, event: recorder.event, startedAt: startedAt, endedAt: Date(),
            mode: recorder.mode, store: recorder.store,
            alternatives: { [weak self] in self?.calendar.overlapping(start: startedAt, end: Date()) ?? [] })
        showTitleWindow(model)
        notifications.removeEndReminder()
        Task {
            let folder = await recorder.stop()
            model.saved(folder: folder, error: recorder.lastError)
            // Обработка стартует сразу, не дожидаясь названия: она идёт по UUID встречи.
            if let folder, let meta = try? recorder.store.read(folder) { queue.enqueue(meta.id) }
        }
    }

    private func showTitleWindow(_ model: TitleModel) {
        titleWindow?.close()
        let controller = TitleWindowController(model: model)
        controller.onClose = { [weak self] in self?.titleWindow = nil }
        titleWindow = controller
        controller.show()
    }

    // MARK: - Напоминания

    private func tick() {
        if settings.deleteOldAudio, Date().timeIntervalSince(lastPurge ?? .distantPast) > 6 * 3600 { purgeOldAudioIfEnabled() }
        refreshCandidates()
        let now = Date()

        // За минуту до начала: «Начинается «…» — записать?»
        if recorder.phase == .idle {
            let soon = EventMatcher.upcoming(calendar.events(from: now, to: now.addingTimeInterval(120)), now: now)
            for event in soon where notifiedStarts.insert(event.id).inserted {
                notifications.postStart(event)
            }
        }

        // Через N минут после конца события: «Похоже, встреча закончилась»
        if recorder.phase == .recording, let event = recorder.event {
            let end = calendar.refreshed(event)?.end ?? event.end
            let due = endReminderAt ?? end.addingTimeInterval(TimeInterval(settings.endReminderMinutes * 60))
            if now >= due, endNotifiedFor != due {
                endNotifiedFor = due
                notifications.postEnd(title: recorder.title)
            }
        }
    }

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .record(let eventId):
            guard recorder.phase == .idle else { return }
            let now = Date()
            let event = calendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(600))
                .first { $0.id == eventId }
            startRecording(event: event)
        case .stop:
            stopRecording()
        case .snooze:
            endReminderAt = Date().addingTimeInterval(15 * 60)
        case .open(let path):
            // Уведомление о готовом саммари или транскрипте открывает карточку встречи.
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            if let meta = try? recorder.store.read(folder) {
                openMain(meeting: meta.id, tab: path.hasSuffix("transcript.md") ? .transcript : .summary)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }
}
