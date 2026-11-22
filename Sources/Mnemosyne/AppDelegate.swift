import AppKit
import MnemosyneCore
import MnemosynePipeline

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var recorder: Recorder!
    private(set) var controller: AppController!
    private var statusBar: StatusBarController!
    private var hotKey: HotKey?
    private let settings = AppSettings()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillTerminate(_ notification: Notification) {
        ChildProcesses.terminateAll()
    }

    /// `kill` (SIGTERM) и Ctrl-C в терминале не вызывают `applicationWillTerminate` —
    /// ловим их сами, чтобы не оставить висеть вызов Claude или Whisper.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                ChildProcesses.terminateAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignals()
        let recorder = Recorder()
        recorder.preferredMicUID = settings.micUID
        recorder.echoCancellationEnabled = settings.echoCancellation
        recorder.modeOverride = settings.modeOverride
        self.recorder = recorder
        let controller = AppController(recorder: recorder, settings: settings)
        self.controller = controller

        statusBar = StatusBarController(controller: controller)

        hotKey = HotKey { [weak self] in self?.controller.toggle() }
        statusBar.hotKeyAvailable = hotKey != nil
        if hotKey == nil {
            Log.app.error("⌃⌥⌘R уже занят другим приложением")
        }

        if ProcessInfo.processInfo.environment["MNEMOSYNE_PROCESS_ALL"] != nil {
            // Отладка конвейера: обработать все встречи в корне и выйти. Итог — в process.txt.
            Task {
                let store = recorder.store
                let processor = MeetingProcessor(store: store)
                var lines: [String] = []
                for (_, meta) in store.list() where meta.status.needsProcessing {
                    let t0 = Date()
                    do {
                        try await processor.process(id: meta.id) { _ in }
                        lines.append("OK \(meta.title) \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    } catch {
                        lines.append("FAIL \(meta.title): \(error.localizedDescription)")
                    }
                }
                try? lines.joined(separator: "\n").write(to: store.root.appending(path: "process.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["MNEMOSYNE_ANALYZE_ALL"] != nil {
            // Отладка анализа: вызов 1 для всех встреч с готовым транскриптом. Итог — в analyze.txt.
            Task {
                let store = recorder.store
                let analyzer = Analyzer(store: store)
                var lines: [String] = []
                for (_, meta) in store.list() where meta.status == .transcribed {
                    let t0 = Date()
                    do {
                        let outcome = try await analyzer.analyze(id: meta.id)
                        var line = "OK \(meta.title) \(String(format: "%.0f", Date().timeIntervalSince(t0))) s"
                        if case .done(let u?) = outcome { line += " in=\(u.totalInput) out=\(u.outputTokens)" }
                        lines.append(line)
                    } catch {
                        lines.append("FAIL \(meta.title): \(error.localizedDescription)")
                    }
                }
                try? lines.joined(separator: "\n").write(to: store.root.appending(path: "analyze.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if let path = ProcessInfo.processInfo.environment["MNEMOSYNE_ENROLL_FILE"] {
            // Отладка отпечатка: эмбеддинг файла и близость к спикерам всех встреч. Итог — в enroll.txt.
            Task {
                let store = recorder.store
                var lines: [String] = []
                do {
                    let e = try await VoiceEnroller.embedding(of: URL(fileURLWithPath: path))
                    lines.append("dim=\(e.count)")
                    for (folder, meta) in store.list() {
                        guard let t = MeetingEditing(store: store).transcript(folder) else { continue }
                        for s in t.speakers where s.embedding != nil {
                            lines.append("\(meta.title) \(s.id): \(String(format: "%.3f", VoiceMatcher.cosine(e, s.embedding!)))")
                        }
                    }
                } catch { lines.append("FAIL \(error.localizedDescription)") }
                try? lines.joined(separator: "\n").write(to: store.root.appending(path: "enroll.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if let raw = ProcessInfo.processInfo.environment["MNEMOSYNE_RERENDER"], let id = UUID(uuidString: raw) {
            // Демо и отладка: пересобрать Markdown и PNG диаграмм встречи без вызовов Claude.
            Task {
                let store = recorder.store
                let editing = MeetingEditing(store: store)
                try? editing.rerender(id: id)
                if let folder = store.locate(id: id), let a = editing.analysis(folder) {
                    let refs = await DiagramRenderer.renderAll(folder: folder, analysis: a)
                    Log.app.info("rerender: \(refs.count, privacy: .public) PNG")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["MNEMOSYNE_SETUP_WHISPER"] != nil {
            // Отладка Д2: поставить окружение распознавания и модель без UI. Итог — в setup.txt.
            Task {
                var lines: [String] = []
                let t0 = Date()
                do {
                    try await WhisperEnvironment.installEnvironment { _ in }
                    lines.append(String(format: "env %.0f с", Date().timeIntervalSince(t0)))
                    let t1 = Date()
                    try await WhisperEnvironment.downloadModel { _ in }
                    lines.append(String(format: "model %.0f с, ready=%@", Date().timeIntervalSince(t1), WhisperEnvironment.isReady ? "да" : "нет"))
                } catch { lines.append("FAIL \(error.localizedDescription)") }
                try? lines.joined(separator: "\n").write(to: recorder.store.root.appending(path: "setup.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["MNEMOSYNE_PUBLISH_ALL"] != nil {
            // Отладка вызова 2: PNG диаграмм и публичное саммари для всех проанализированных встреч. Итог — в publish.txt.
            Task {
                let store = recorder.store
                let publisher = Publisher(store: store)
                var lines: [String] = []
                for (folder, meta) in store.list() where meta.status == .done {
                    guard let analysis = MeetingEditing(store: store).analysis(folder) else { continue }
                    let t0 = Date()
                    let diagrams = await DiagramRenderer.renderAll(folder: folder, analysis: analysis)
                    lines.append("PNG \(meta.title): \(diagrams.count) из \(analysis.diagrams.count)")
                    do {
                        let outcome = try await publisher.publish(id: meta.id, diagrams: diagrams)
                        var line = "OK \(meta.title) \(String(format: "%.0f", Date().timeIntervalSince(t0))) s \(outcome)"
                        if let u = (try? store.read(folder))?.usage?.last(where: { $0.step == "public" }) { line += " in=\(u.inputTokens) out=\(u.outputTokens)" }
                        lines.append(line)
                    } catch {
                        lines.append("FAIL \(meta.title): \(error.localizedDescription)")
                    }
                }
                try? lines.joined(separator: "\n").write(to: store.root.appending(path: "publish.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if let seconds = ProcessInfo.processInfo.environment["MNEMOSYNE_SELFTEST"].flatMap(Double.init) {
            runSelfTest(seconds: seconds)
            return
        }

        // Скиллы из .app → ~/.claude/skills (у друзей их нет, после обновления — новая версия).
        if let skills = Bundle.main.resourceURL?.appending(path: "Skills") {
            do {
                let r = try SkillInstaller.install(from: skills)
                if !r.installed.isEmpty { Log.app.info("skills installed: \(r.installed.joined(separator: ","), privacy: .public)") }
            } catch {
                Log.app.error("skills install: \(error.localizedDescription, privacy: .public)")
            }
        }
        // PATH из login-shell считаем заранее: в первый раз это до 5 секунд.
        Task.detached { _ = ShellEnvironment.searchPath }

        Task {
            await controller.launch()
            let recovered = await recorder.recoverInterrupted()
            controller.queue.resumeInterrupted()
            controller.analysis.start()
            // Отладка: открыть главное окно на нужной вкладке (для скриншотов).
            if let tab = ProcessInfo.processInfo.environment["MNEMOSYNE_OPEN_MAIN"] {
                let meeting = ProcessInfo.processInfo.environment["MNEMOSYNE_OPEN_ID"].flatMap(UUID.init(uuidString:))
                controller.openMain(meeting: meeting, tab: LibraryModel.Tab.allCases.first { "\($0)" == tab })
                if tab == "tasks" { controller.mainWindow.library.section = .tasks }
            }
            if recovered > 0 { statusBar.notice = "Восстановлено прерванных записей: \(recovered)" }
            if !controller.settings.onboardingDone, ProcessInfo.processInfo.environment["MNEMOSYNE_OPEN_MAIN"] == nil {
                controller.showOnboarding()
            }
            if ProcessInfo.processInfo.environment["MNEMOSYNE_OPEN_SETTINGS"] != nil { controller.showSettings() }
            if ProcessInfo.processInfo.environment["MNEMOSYNE_OPEN_ONBOARDING"] != nil { controller.showOnboarding() }
        }
    }

    /// Смоук-тест записи: `make selftest`. Пишет N секунд, сохраняет и выходит,
    /// итог кладёт в `selftest.txt` в корне встреч.
    private func runSelfTest(seconds: Double) {
        Task {
            await recorder.start(title: "Самопроверка")
            try? await Task.sleep(for: .seconds(seconds))
            if ProcessInfo.processInfo.environment["MNEMOSYNE_SELFTEST_UI"] != nil {
                // Показать окно названия, как после обычного «Остановить», и подождать скриншот.
                controller.stopRecording()
                try? await Task.sleep(for: .seconds(6))
            }
            let folder = await recorder.stop() ?? recorder.lastSaved
            var lines = ["error: \(recorder.lastError ?? "-")"]
            if let folder, let meta = try? recorder.store.read(folder) {
                lines.append("folder: \(folder.path)")
                lines.append("status: \(meta.status.rawValue) vp: \(meta.voiceProcessing) output: \(meta.outputKindAtStart?.rawValue ?? "-")")
                for track in meta.tracks {
                    lines.append("track \(track.role.rawValue): \(track.file) device=\(track.device ?? "-") duration=\(track.durationSeconds ?? -1) padded=\(track.paddedSeconds ?? 0)")
                }
                lines.append("offset: \(meta.othersOffsetSeconds.map { String($0) } ?? "-")")
                lines.append("warnings: \(meta.warnings ?? [])")
            }
            let out = recorder.store.root.appending(path: "selftest.txt")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.phase != .idle else { return .terminateNow }
        Task {
            await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Настройки записи в UserDefaults.
@MainActor
final class AppSettings {
    private let defaults = UserDefaults.standard

    var micUID: String? {
        get { defaults.string(forKey: "micUID") }
        set { defaults.set(newValue, forKey: "micUID") }
    }

    var echoCancellation: Bool {
        get { defaults.object(forKey: "echoCancellation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "echoCancellation") }
    }

    /// Режим, выбранный вручную. `nil` — «Авто» по событию календаря.
    var modeOverride: RecordingMode? {
        get { defaults.string(forKey: "modeOverride").flatMap(RecordingMode.init) }
        set { defaults.set(newValue?.rawValue, forKey: "modeOverride") }
    }

    /// Через сколько минут после конца события напомнить остановить запись.
    var endReminderMinutes: Int {
        get { defaults.object(forKey: "endReminderMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "endReminderMinutes") }
    }

    /// Как вас зовут: для отпечатка голоса и списка задач.
    var myName: String {
        get { defaults.string(forKey: "myName") ?? NSFullUserName() }
        set { defaults.set(newValue, forKey: "myName") }
    }

    /// Чем вы занимаетесь — контекст для анализа встреч (роль, команда, продукт).
    var myRole: String {
        get { defaults.string(forKey: "myRole") ?? "" }
        set { defaults.set(newValue, forKey: "myRole") }
    }

    /// Куда вставляете публичное саммари: от этого зависит разметка.
    var messenger: PublicInput.Messenger {
        get { defaults.string(forKey: "messenger").flatMap(PublicInput.Messenger.init) ?? .mattermost }
        set { defaults.set(newValue.rawValue, forKey: "messenger") }
    }

    /// Вычитывать публичное саммари скиллом ru-text, если он установлен. Дороже: ~+60 тыс. токенов с кэшем.
    var useRuText: Bool {
        get { defaults.object(forKey: "useRuText") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useRuText") }
    }

    /// ru-text установлен и включён в настройках.
    var ruTextActive: Bool { useRuText && SkillInstaller.isInstalled("ru-text") }

    var owner: OwnerProfile { OwnerProfile(name: myName, role: myRole, vocabulary: vocabulary) }

    /// Папка встреч. Меняется в онбординге или настройках, применяется после перезапуска.
    var meetingsRoot: URL {
        get { MeetingStore.defaultRoot }
        set { defaults.set(newValue.path, forKey: MeetingStore.rootDefaultsKey) }
    }

    /// Язык распознавания: `ru` или `auto`.
    var language: String {
        get { defaults.string(forKey: "language") ?? "ru" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Словарь терминов для подсказки Whisper: по одному на строку.
    var vocabularyText: String {
        get { defaults.string(forKey: "vocabulary") ?? "" }
        set { defaults.set(newValue, forKey: "vocabulary") }
    }

    var vocabulary: [String] {
        vocabularyText.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Модель Claude: `sonnet` или `opus`.
    var claudeModel: String {
        get { defaults.string(forKey: "claudeModel") ?? "sonnet" }
        set { defaults.set(newValue, forKey: "claudeModel") }
    }

    /// Удалять аудио старше 30 дней. По умолчанию выключено.
    var deleteOldAudio: Bool {
        get { defaults.bool(forKey: "deleteOldAudio") }
        set { defaults.set(newValue, forKey: "deleteOldAudio") }
    }

    var onboardingDone: Bool {
        get { defaults.bool(forKey: "onboardingDone") }
        set { defaults.set(newValue, forKey: "onboardingDone") }
    }
}
