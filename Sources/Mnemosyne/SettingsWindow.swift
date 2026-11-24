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
    private var model: SettingsModel?
    let controller: AppController

    init(controller: AppController) { self.controller = controller }

    func show(newTag: Bool = false, scrollToTags: Bool = false, newStyle: Bool = false) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = String(localized: "Настройки Мунина")
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 480)
            let model = SettingsModel(controller: controller)
            self.model = model
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        model?.reloadTags()
        model?.reloadStyles()
        // Окно могло только что создаться: прокрутка сработает, когда форма уже на экране.
        if newTag || scrollToTags || newStyle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if newStyle { self?.model?.startNewStyle() }
                else if newTag { self?.model?.startNewTag() } else { self?.model?.scrollToTags += 1 }
            }
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
    var summaryLanguage: String { didSet { settings.summaryLanguage = summaryLanguage } }
    var uiLanguage: UILanguage { didSet { UILanguage.chosen = uiLanguage; uiLanguageChanged = true } }
    var uiLanguageChanged = false
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

    // Теги
    private(set) var tags: [MeetingTag] = []
    private(set) var tagCounts: [UUID: Int] = [:]
    var editingTag: UUID?
    var newTagId: UUID?
    var tagDraftName = ""
    var tagDraftColor: TagColor = .orange
    var confirmDeleteTag: UUID?
    /// Прокрутить к разделу «Теги» (после «Новый тег…» из карточки).
    var scrollToTags = 0

    // Стили саммари
    var defaultStyle: String { didSet { settings.defaultSummaryStyle = defaultStyle } }
    private(set) var styles: [SummaryStyle] = []
    var editingStyle: String?
    var newStyleId: String?
    var styleDraftName = ""
    var styleDraftPrompt = ""
    var confirmDeleteStyle: String?
    var scrollToStyles = 0

    init(controller: AppController) {
        self.controller = controller
        let s = controller.settings
        voice = VoiceEnrollment(store: controller.recorder.store)
        myName = s.myName
        myRole = s.myRole
        messenger = s.messenger
        theme = s.theme
        language = s.language
        summaryLanguage = s.summaryLanguage
        uiLanguage = UILanguage.chosen
        vocabulary = s.vocabularyText
        model = s.claudeModel
        endReminder = s.endReminderMinutes
        deleteOldAudio = s.deleteOldAudio
        micUID = s.micUID
        echo = s.echoCancellation
        launchAtLogin = SMAppService.mainApp.status == .enabled
        defaultStyle = s.defaultSummaryStyle
        reloadPeople()
        reloadTags()
        reloadStyles()
    }

    private var root: URL { controller.recorder.store.root }

    func reloadTags() {
        tags = TagDirectory.load(root: root).tags
        tagCounts = controller.recorder.store.tagCounts()
    }

    func startEditTag(_ t: MeetingTag) {
        cancelTag()
        editingTag = t.id
        tagDraftName = t.name
        tagDraftColor = t.color
    }

    func startNewTag() {
        cancelTag()
        // Свободный цвет, если есть, иначе оранжевый.
        let used = Set(tags.map(\.color))
        let t = MeetingTag(name: "", color: TagColor.allCases.first { !used.contains($0) } ?? .orange)
        tags.append(t)
        startEditTag(t)
        newTagId = t.id
        scrollToTags += 1
    }

    func saveTag() {
        guard let id = editingTag else { return }
        let name = tagDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var dir = TagDirectory.load(root: root)
        if let i = dir.tags.firstIndex(where: { $0.id == id }) {
            dir.tags[i].name = name
            dir.tags[i].color = tagDraftColor
        } else {
            dir.tags.append(MeetingTag(id: id, name: name, color: tagDraftColor))
        }
        try? dir.save(root: root)
        editingTag = nil
        newTagId = nil
        reloadTags()
    }

    func cancelTag() {
        if let n = newTagId { tags.removeAll { $0.id == n } }
        newTagId = nil
        editingTag = nil
        confirmDeleteTag = nil
    }

    func deleteTag(_ id: UUID) {
        try? controller.recorder.store.deleteTag(id)
        confirmDeleteTag = nil
        reloadTags()
    }

    // MARK: Стили

    func reloadStyles() {
        styles = StyleDirectory.load(root: root).styles
        if StyleDirectory.load(root: root).style(defaultStyle) == nil { defaultStyle = SummaryStyle.businessId }
    }

    func startEditStyle(_ s: SummaryStyle) {
        cancelStyle()
        editingStyle = s.id
        styleDraftName = s.name
        styleDraftPrompt = s.prompt
    }

    func startNewStyle() {
        cancelStyle()
        let s = SummaryStyle.custom(name: "", prompt: "")
        styles.append(s)
        startEditStyle(s)
        newStyleId = s.id
        scrollToStyles += 1
    }

    var canSaveStyle: Bool {
        !styleDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !styleDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveStyle() {
        guard let id = editingStyle, canSaveStyle else { return }
        try? controller.recorder.store.saveStyle(SummaryStyle.custom(name: styleDraftName, prompt: styleDraftPrompt, id: id))
        editingStyle = nil
        newStyleId = nil
        reloadStyles()
    }

    func cancelStyle() {
        if let n = newStyleId { styles.removeAll { $0.id == n } }
        newStyleId = nil
        editingStyle = nil
        confirmDeleteStyle = nil
    }

    func deleteStyle(_ id: String) {
        try? controller.recorder.store.deleteStyle(id)
        confirmDeleteStyle = nil
        if defaultStyle == id { defaultStyle = SummaryStyle.businessId }
        reloadStyles()
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
            launchError = String(localized: "Не получилось: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func checkClaude() {
        checkingClaude = true
        claudeStatus = nil
        let workDir = controller.recorder.store.root.appending(path: ".work/claude")
        Task {
            defer { checkingClaude = false }
            guard let cli = ClaudeCLI(workDir: workDir) else { claudeStatus = String(localized: "Claude Code не найден"); return }
            do {
                let s = try await cli.checkSubscription()
                let plan = s.subscriptionType.capitalized
                if let exp = s.loginExpiresAt {
                    claudeStatus = String(localized: "Подписка \(plan), вход действует до \(UIFormat.day(exp))")
                } else {
                    claudeStatus = String(localized: "Подписка \(plan)")
                }
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
    @FocusState private var tagNameFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section("Общие") {
                TextField("Как вас зовут", text: $model.myName)
                TextField("Чем занимаетесь", text: $model.myRole, prompt: Text("например, продакт-менеджер платформы платежей"))
                Picker("Язык интерфейса", selection: $model.uiLanguage) {
                    ForEach(UILanguage.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                if model.uiLanguageChanged {
                    HStack {
                        Text("Язык сменится после перезапуска.").foregroundStyle(Theme.sec)
                        Spacer()
                        Button("Перезапустить") { UILanguage.relaunch() }
                            .disabled(model.controller.recorder.phase != .idle)
                    }
                }
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
                Picker("Язык встреч", selection: $model.language) {
                    Text("Определять автоматически").tag(MeetingLanguage.auto)
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
                }
                Picker("Язык саммари", selection: $model.summaryLanguage) {
                    Text("Как язык встречи").tag(MeetingLanguage.sameAsMeeting)
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
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
                Text("Автоопределение смотрит на первые 30 секунд каждой дорожки. Если язык определился неверно, его можно сменить в карточке встречи — запись распознается заново. Словарь и имена приглашённых подсказывают Whisper, как писать редкие слова.").foregroundStyle(Theme.sec)
            }

            Section("Голос и люди") {
                VoiceEnrollmentView(model: model.voice, name: model.myName)
                    .onChange(of: model.voice.state) { _, _ in model.reloadPeople() }
                ForEach(model.people) { p in
                    HStack {
                        Text(p.isMe == true ? String(localized: "\(p.name) (вы)") : p.name)
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

            tagsSection

            stylesSection

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
                    Text(model.claudeStatus ?? String(localized: "Работает только по подписке, без API-ключей"))
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
        .onChange(of: model.scrollToTags) { _, _ in withAnimation { proxy.scrollTo("tags", anchor: .top) } }
        .onChange(of: model.scrollToStyles) { _, _ in withAnimation { proxy.scrollTo("styles", anchor: .top) } }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Стили саммари

    private var stylesSection: some View {
        Section {
            Picker("Стиль по умолчанию", selection: $model.defaultStyle) {
                ForEach(SummaryStyle.presets) { Text($0.uiName).tag($0.id) }
                if !model.styles.filter({ $0.id != model.newStyleId }).isEmpty {
                    Divider()
                    ForEach(model.styles.filter { $0.id != model.newStyleId }) { Text($0.name).tag($0.id) }
                }
            }
            ForEach(model.styles) { s in
                if model.editingStyle == s.id {
                    styleEditor
                } else if model.confirmDeleteStyle == s.id {
                    HStack {
                        Text("Удалить стиль «\(s.name)»? Уже собранные саммари останутся.")
                        Spacer()
                        Button("Отмена") { model.cancelStyle() }
                        Button("Удалить", role: .destructive) { model.deleteStyle(s.id) }
                    }
                } else {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(s.prompt).font(.system(size: 12)).foregroundStyle(Theme.sec).lineLimit(1)
                        }
                        Spacer()
                        Button("Изменить") { model.startEditStyle(s) }.buttonStyle(.borderless)
                        Button("Удалить") { model.cancelStyle(); model.confirmDeleteStyle = s.id }
                            .buttonStyle(.borderless).foregroundStyle(Theme.red)
                    }
                }
            }
            if model.newStyleId == nil {
                Button("Добавить свой стиль") { model.startNewStyle() }.buttonStyle(.borderless)
            }
        } header: {
            Text("Стили саммари").id("styles")
        } footer: {
            Text("Стиль можно сменить в карточке встречи: саммари пересоберётся отдельным вызовом Claude, прежняя версия сохранится. Если по умолчанию стоит не «Деловой», такой вызов будет после каждой встречи.")
                .foregroundStyle(Theme.sec)
        }
    }

    private var styleEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Название")
                Spacer()
                TextField("", text: $model.styleDraftName, prompt: Text("Например, «Для руководителя»"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 300)
                    .focused($tagNameFocused)
                    .onAppear { tagNameFocused = true }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Каким должно быть саммари")
                TextEditor(text: $model.styleDraftPrompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                Text("Своими словами: что в нём, в каком порядке, какой длины. Например: «Три пункта: что решили, какие риски, что нужно от руководителя».")
                    .font(.system(size: 12)).foregroundStyle(Theme.sec)
            }
            HStack {
                Spacer()
                Button("Отмена") { model.cancelStyle() }
                Button("Сохранить") { model.saveStyle() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSaveStyle)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Теги

    private var tagsSection: some View {
        Section {
            ForEach(model.tags) { t in
                if model.editingTag == t.id {
                    tagEditor
                } else if model.confirmDeleteTag == t.id {
                    HStack {
                        Text("Удалить «\(t.name)»? Снимется с \(Self.meetingsGenitive(model.tagCounts[t.id] ?? 0)).")
                        Spacer()
                        Button("Отмена") { model.cancelTag() }
                        Button("Удалить", role: .destructive) { model.deleteTag(t.id) }
                    }
                } else {
                    HStack(spacing: 10) {
                        TagDot(color: t.color, size: 10)
                        Text(t.name)
                        Spacer()
                        Text(Self.meetings(model.tagCounts[t.id] ?? 0)).foregroundStyle(Theme.sec)
                        Button("Изменить") { model.startEditTag(t) }.buttonStyle(.borderless)
                        Button("Удалить") { model.cancelTag(); model.confirmDeleteTag = t.id }
                            .buttonStyle(.borderless).foregroundStyle(Theme.red)
                    }
                }
            }
            if model.newTagId == nil {
                Button("Добавить тег") { model.startNewTag() }.buttonStyle(.borderless)
            }
        } header: {
            Text("Теги").id("tags")
        } footer: {
            Text("Тег ставится в карточке встречи, по тегам фильтруется список. Удаление снимает тег со всех встреч, сами встречи остаются.")
                .foregroundStyle(Theme.sec)
        }
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Название")
                Spacer()
                TextField("", text: $model.tagDraftName, prompt: Text("Например, «Клиенты»"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 260)
                    .focused($tagNameFocused)
                    .onSubmit { model.saveTag() }
                    .onAppear { tagNameFocused = true }
            }
            HStack(spacing: 8) {
                Text("Цвет")
                Spacer()
                ForEach(TagColor.allCases, id: \.self) { c in
                    Button { model.tagDraftColor = c } label: {
                        Circle().fill(c.color).frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().strokeBorder(model.tagDraftColor == c ? Theme.ink : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(c.uiTitle)
                    .accessibilityLabel(c.uiTitle)
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { model.cancelTag() }
                Button("Сохранить") { model.saveTag() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.tagDraftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    /// «3 встречи», «нет встреч».
    static func meetings(_ n: Int) -> String {
        if n == 0 { return String(localized: "нет встреч") }
        return plural(n, ru: ("встреча", "встречи", "встреч"), en: ("meeting", "meetings"))
    }

    /// «с 1 встречи», «с 5 встреч».
    static func meetingsGenitive(_ n: Int) -> String {
        plural(n, ru: ("встречи", "встреч", "встреч"), en: ("meeting", "meetings"))
    }

    static func voices(_ n: Int) -> String {
        n == 0 ? String(localized: "голоса нет") : n == 1 ? String(localized: "1 запись голоса") : String(localized: "записей голоса: \(n)")
    }

    static func calls(_ n: Int) -> String {
        plural(n, ru: ("вызов", "вызова", "вызовов"), en: ("call", "calls"))
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(localized: "\(Int((Double(n) / 1000).rounded())) тыс. токенов") : String(localized: "\(n) токенов")
    }
}
