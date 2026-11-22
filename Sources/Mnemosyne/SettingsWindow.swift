import AppKit
import MnemosyneCore
import MnemosynePipeline
import Observation
import ServiceManagement
import SwiftUI

/// Окно настроек. Открывается из поповера и по ⌘, из главного окна.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let controller: AppController

    init(controller: AppController) { self.controller = controller }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Настройки Мунина"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 480)
            w.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel(controller: controller)))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.restoreActivationPolicy(closing: window)
    }
}

@MainActor
@Observable
final class SettingsModel {
    let controller: AppController
    var settings: AppSettings { controller.settings }
    let voice: VoiceEnrollment

    var myName: String { didSet { settings.myName = myName } }
    var myRole: String { didSet { settings.myRole = myRole } }
    var messenger: PublicInput.Messenger { didSet { settings.messenger = messenger } }
    var theme: AppTheme { didSet { settings.theme = theme } }
    var language: String { didSet { settings.language = language } }
    var vocabulary: String { didSet { settings.vocabularyText = vocabulary } }
    var model: String { didSet { settings.claudeModel = model } }
    var endReminder: Int { didSet { settings.endReminderMinutes = endReminder } }
    var deleteOldAudio: Bool {
        didSet {
            settings.deleteOldAudio = deleteOldAudio
            if deleteOldAudio { controller.purgeOldAudioIfEnabled() }
        }
    }
    var micUID: String? {
        didSet { controller.recorder.preferredMicUID = micUID; settings.micUID = micUID }
    }
    var echo: Bool {
        didSet { controller.recorder.echoCancellationEnabled = echo; settings.echoCancellation = echo }
    }
    var launchAtLogin: Bool
    var launchError: String?

    var claudeStatus: String?
    var checkingClaude = false
    private(set) var people: [PeopleDirectory.Record] = []

    init(controller: AppController) {
        self.controller = controller
        let s = controller.settings
        voice = VoiceEnrollment(store: controller.recorder.store)
        myName = s.myName
        myRole = s.myRole
        messenger = s.messenger
        theme = s.theme
        language = s.language
        vocabulary = s.vocabularyText
        model = s.claudeModel
        endReminder = s.endReminderMinutes
        deleteOldAudio = s.deleteOldAudio
        micUID = s.micUID
        echo = s.echoCancellation
        launchAtLogin = SMAppService.mainApp.status == .enabled
        reloadPeople()
    }

    func reloadPeople() {
        people = PeopleDirectory.load(root: controller.recorder.store.root).people.sorted { ($0.isMe == true ? 0 : 1, $0.name) < ($1.isMe == true ? 0 : 1, $1.name) }
    }

    func forget(_ person: PeopleDirectory.Record) {
        let root = controller.recorder.store.root
        var dir = PeopleDirectory.load(root: root)
        dir.people.removeAll { $0.id == person.id }
        try? dir.save(root: root)
        reloadPeople()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Не получилось: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func checkClaude() {
        checkingClaude = true
        claudeStatus = nil
        let workDir = controller.recorder.store.root.appending(path: ".work/claude")
        Task {
            defer { checkingClaude = false }
            guard let cli = ClaudeCLI(workDir: workDir) else { claudeStatus = "Claude Code не найден"; return }
            do {
                let s = try await cli.checkSubscription()
                var text = "Подписка \(s.subscriptionType.capitalized)"
                if let exp = s.loginExpiresAt { text += ", вход действует до \(Format.day(exp))" }
                claudeStatus = text
            } catch {
                claudeStatus = error.localizedDescription
            }
        }
    }

    /// Расход Claude за сегодня и за 7 дней по `usage` из встреч.
    var usage: (todayCalls: Int, todayTokens: Int, weekCalls: Int, weekTokens: Int) {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let week = now.addingTimeInterval(-7 * 86400)
        var r = (0, 0, 0, 0)
        for (_, m) in controller.recorder.store.list() {
            for u in m.usage ?? [] {
                let tokens = u.inputTokens + u.outputTokens
                if u.at >= today { r.0 += 1; r.1 += tokens }
                if u.at >= week { r.2 += 1; r.3 += tokens }
            }
        }
        return r
    }

    var whisperInstalled: Bool { WhisperRunner() != nil }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Общие") {
                TextField("Как вас зовут", text: $model.myName)
                TextField("Чем занимаетесь", text: $model.myRole, prompt: Text("например, продакт-менеджер платформы платежей"))
                Picker("Тема", selection: $model.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Напомнить остановить запись", selection: $model.endReminder) {
                    Text("Не напоминать").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("через \($0) мин после конца события").tag($0) }
                }
                Toggle("Запускать при входе в систему", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let e = model.launchError { Text(e).font(.caption).foregroundStyle(Theme.red) }
                LabeledContent("Начать или остановить запись", value: "⌃⌥⌘R")
            }

            Section("Запись") {
                Picker("Микрофон", selection: $model.micUID) {
                    Text("Автоматически").tag(String?.none)
                    ForEach(AudioDevices.inputs(), id: \.uid) { d in Text(d.name).tag(Optional(d.uid)) }
                }
                Toggle("Эхоподавление, когда звук идёт в динамики", isOn: $model.echo)
            }

            Section {
                Picker("Язык", selection: $model.language) {
                    Text("Русский").tag("ru")
                    Text("Определять автоматически").tag("auto")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Словарь: имена, продукты, термины — по одному на строку")
                    TextEditor(text: $model.vocabulary)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Распознавание речи")
                    WhisperSetupRow(setup: model.controller.whisperSetup, compact: true)
                }
            } header: {
                Text("Распознавание")
            } footer: {
                Text("Словарь и имена приглашённых подсказывают Whisper, как писать редкие слова.").foregroundStyle(Theme.sec)
            }

            Section("Голос и люди") {
                VoiceEnrollmentView(model: model.voice, name: model.myName)
                    .onChange(of: model.voice.state) { _, _ in model.reloadPeople() }
                ForEach(model.people) { p in
                    HStack {
                        Text(p.isMe == true ? "\(p.name) (вы)" : p.name)
                        Spacer()
                        Text(Self.voices(p.voices.count)).foregroundStyle(Theme.sec)
                        if p.isMe != true {
                            Button("Забыть") { model.forget(p) }.buttonStyle(.borderless)
                        }
                    }
                }
                if model.people.filter({ $0.isMe != true }).isEmpty {
                    Text("Люди появятся, когда вы укажете, кто говорил на встрече. Потом их голоса будут узнаваться сами.")
                        .foregroundStyle(Theme.sec)
                }
            }

            Section {
                Picker("Мессенджер", selection: $model.messenger) {
                    ForEach(PublicInput.Messenger.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                RuTextToggle(settings: model.settings)
            } header: {
                Text("Публичное саммари")
            } footer: {
                Text("От мессенджера зависит разметка: в Mattermost задачи идут таблицей, в Slack и Telegram — списком.")
                    .foregroundStyle(Theme.sec)
            }

            Section {
                Picker("Модель", selection: $model.model) {
                    Text("Sonnet — по умолчанию").tag("sonnet")
                    Text("Opus — глубже, но быстрее тратит лимит").tag("opus")
                }
                HStack {
                    Text(model.claudeStatus ?? "Работает только по подписке, без API-ключей")
                        .foregroundStyle(Theme.sec)
                    Spacer()
                    if model.checkingClaude { ProgressView().controlSize(.small) }
                    else { Button("Проверить") { model.checkClaude() } }
                }
                let u = model.usage
                LabeledContent("Сегодня", value: "\(Self.calls(u.todayCalls)), \(Self.tokens(u.todayTokens))")
                LabeledContent("За 7 дней", value: "\(Self.calls(u.weekCalls)), \(Self.tokens(u.weekTokens))")
            } header: {
                Text("Claude")
            } footer: {
                Text("Токены — вход вместе с кэшем и выход. Кэш расходует лимит заметно меньше.").foregroundStyle(Theme.sec)
            }

            Section {
                LabeledContent("Папка встреч") {
                    HStack(spacing: 10) {
                        Button(model.controller.recorder.store.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                            NSWorkspace.shared.open(model.controller.recorder.store.root)
                        }
                        .buttonStyle(.link)
                        Button("Изменить…") { MeetingsFolder.choose(settings: model.settings) }
                    }
                }
                Toggle("Удалять аудио старше \(AudioRetention.days) дней", isOn: $model.deleteOldAudio)
            } header: {
                Text("Хранение")
            } footer: {
                Text("Транскрипт, саммари и диаграммы остаются. Без галочки аудио хранится, пока вы не удалите встречу.")
                    .foregroundStyle(Theme.sec)
            }

            Section {
                Button("Пройти первоначальную настройку") { model.controller.showOnboarding() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
    }

    static func voices(_ n: Int) -> String {
        n == 0 ? "голоса нет" : n == 1 ? "1 запись голоса" : "записей голоса: \(n)"
    }

    static func calls(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = m10 == 1 && m100 != 11 ? "вызов" : (2...4).contains(m10) && !(12...14).contains(m100) ? "вызова" : "вызовов"
        return "\(n) \(w)"
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(Int((Double(n) / 1000).rounded())) тыс. токенов" : "\(n) токенов"
    }
}
