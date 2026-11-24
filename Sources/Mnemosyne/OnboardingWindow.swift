import AppKit
@preconcurrency import AVFoundation
import MnemosyneCore
import MnemosynePipeline
import Observation
import SwiftUI
@preconcurrency import UserNotifications

/// Первоначальная настройка: разрешения, Claude, транскрибатор, голос, памятка (§2, §5.2, §10).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let controller: AppController

    init(controller: AppController) { self.controller = controller }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = String(localized: "Добро пожаловать в Мунин")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let model = OnboardingModel(controller: controller)
            w.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in self?.finish() })
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        controller.settings.onboardingDone = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Закрыли крестиком — тоже считаем пройденной: напоминать при каждом запуске навязчиво.
        controller.settings.onboardingDone = true
        controller.restoreActivationPolicy(closing: window)
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Check: Equatable { case unknown, ok, missing(String) }

    let controller: AppController
    let voice: VoiceEnrollment
    var name: String { didSet { controller.settings.myName = name } }
    var role: String { didSet { controller.settings.myRole = role } }
    var messenger: PublicInput.Messenger { didSet { controller.settings.messenger = messenger } }
    var page = 0

    var mic: Check = .unknown
    var calendar: Check = .unknown
    var notifications: Check = .unknown
    var claude: Check = .unknown
    var checkingClaude = false

    init(controller: AppController) {
        self.controller = controller
        voice = VoiceEnrollment(store: controller.recorder.store)
        name = controller.settings.myName
        role = controller.settings.myRole
        messenger = controller.settings.messenger
        // Отладка: открыть сразу нужный экран (для скриншотов).
        page = ProcessInfo.processInfo.environment["MNEMOSYNE_ONBOARDING_PAGE"].flatMap(Int.init) ?? 0
        refresh()
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .ok
        case .notDetermined: mic = .unknown
        default: mic = .missing(String(localized: "Доступ запрещён — включите в Системных настройках"))
        }
        switch CalendarService.currentAccess() {
        case .granted: calendar = .ok
        case .unknown: calendar = .unknown
        case .denied: calendar = .missing(String(localized: "Доступ запрещён — включите в Системных настройках"))
        }
        controller.whisperSetup.refresh()
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable s in
            let status = s.authorizationStatus
            Task { @MainActor [weak self] in
                self?.notifications = status == .authorized ? .ok : (status == .denied ? .missing(String(localized: "Отключены — включите в Системных настройках")) : .unknown)
            }
        }
    }

    func requestMic() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            refresh()
        }
    }

    func requestCalendar() {
        Task {
            await controller.calendar.requestAccess()
            if CalendarService.currentAccess() != .granted {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            controller.refreshCandidates()
            refresh()
        }
    }

    func requestNotifications() {
        Task {
            await controller.notifications.requestAuthorization()
            refresh()
        }
    }

    func openAudioCapture() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    func checkClaude() {
        checkingClaude = true
        let workDir = controller.recorder.store.root.appending(path: ".work/claude")
        Task {
            defer { checkingClaude = false }
            guard let cli = ClaudeCLI(workDir: workDir) else { claude = .missing(String(localized: "Claude Code не найден")); return }
            do {
                _ = try await cli.checkSubscription()
                claude = .ok
            } catch {
                claude = .missing(error.localizedDescription)
            }
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let done: () -> Void

    /// Знакомство (приветствие + 4 возможности), затем три шага настройки.
    static let tourPages = 5
    private let pages = tourPages + 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch model.page {
                case 0: TourWelcome()
                case 1: TourRecord()
                case 2: TourTranscript()
                case 3: TourAnalysis()
                case 4: TourShare(messenger: model.messenger.title)
                case Self.tourPages: about
                case Self.tourPages + 1: access
                default: voice
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 52)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(model.page)

            footer
        }
        .background(Theme.win)
        .foregroundStyle(Theme.ink)
        .frame(width: 680, height: 640)
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    // MARK: - Экраны

    /// 1. Кто вы и куда сохранять.
    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                BrandMark(size: 30)
                Text("Настроим за три шага").font(.system(size: 24, weight: .bold)).tracking(-0.4)
            }
            Text("Расскажите о себе, дайте доступы и запишите голос — и можно записывать.")
                .font(.system(size: 15)).foregroundStyle(Theme.sec).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                SectionCap(String(localized: "О вас"))
                TextField("Как вас зовут", text: $model.name).textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                TextField("Чем занимаетесь", text: $model.role, prompt: Text("например, продакт-менеджер платформы платежей"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                Text("Claude учтёт это при разборе встреч: какие задачи ваши, какие термины важны.")
                    .font(.system(size: 13)).foregroundStyle(Theme.sec)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionCap(String(localized: "Куда отправляете итоги встреч"))
                Picker("", selection: $model.messenger) {
                    ForEach(PublicInput.Messenger.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                Text("От этого зависит разметка публичного саммари. Поменять можно в настройках.")
                    .font(.system(size: 13)).foregroundStyle(Theme.sec)
                RuTextToggle(settings: model.controller.settings).frame(maxWidth: 520, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionCap(String(localized: "Папка встреч"))
                HStack(spacing: 10) {
                    Text(model.controller.recorder.store.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 15))
                    LinkButton(String(localized: "Изменить")) { MeetingsFolder.choose(settings: model.controller.settings) }
                }
            }
        }
    }

    /// 2. Разрешения и инструменты.
    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Доступы и инструменты").font(.system(size: 24, weight: .bold)).tracking(-0.4)
            VStack(alignment: .leading, spacing: 14) {
                step("mic", String(localized: "Микрофон"), String(localized: "Ваш голос на встрече."), model.mic, action: String(localized: "Разрешить"), model.requestMic)
                step("speaker.wave.2", String(localized: "Звук приложений"), String(localized: "Голоса собеседников из Zoom, Толка, Meet. macOS спросит при первой записи."),
                     .unknown, action: String(localized: "Настройки"), model.openAudioCapture)
                step("calendar", String(localized: "Календарь"), String(localized: "Название встречи и участники."), model.calendar, action: String(localized: "Разрешить"), model.requestCalendar)
                step("bell", String(localized: "Уведомления"), String(localized: "«Встреча начинается — записать?», «Саммари готово»."), model.notifications, action: String(localized: "Разрешить"), model.requestNotifications)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                step("terminal", "Claude Code", String(localized: "Анализ по вашей подписке, без API-ключей. Не вошли — в Терминале: claude /login."),
                     model.claude, action: model.checkingClaude ? String(localized: "Проверяю…") : String(localized: "Проверить"), model.checkClaude)
                WhisperSetupRow(setup: model.controller.whisperSetup)
            }
        }
        .onAppear { if model.claude == .unknown { model.checkClaude() } }
    }

    /// 3. Голос и памятка.
    private var voice: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ваш голос").font(.system(size: 24, weight: .bold)).tracking(-0.4)
            Text("Отпечаток голоса нужен, чтобы на встрече в переговорке отличить вас от остальных. Хранится только на этом Mac. Можно пропустить и записать позже в настройках.")
                .font(.system(size: 13)).foregroundStyle(Theme.sec).fixedSize(horizontal: false, vertical: true)
            VoiceEnrollmentView(model: model.voice, name: model.name)
            VStack(alignment: .leading, spacing: 8) {
                SectionCap(String(localized: "Перед записью"))
                tip(String(localized: "Предупреждайте собеседников, что встреча записывается."))
                tip(String(localized: "В AirPods выберите в Zoom и Meet микрофон MacBook — иначе звук станет хуже."))
                tip(String(localized: "Начать и остановить запись — ⌃⌥⌘R или ворон в строке меню."))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Навигация

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == model.page ? Theme.ink : Theme.line)
                        .frame(width: i == model.page ? 18 : 6, height: 6)
                        // Зазор между знакомством и настройкой.
                        .padding(.leading, i == Self.tourPages ? 8 : 0)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.page)
            Spacer()
            if model.page < Self.tourPages {
                LinkButton(String(localized: "Пропустить знакомство")) {
                    withAnimation(.easeInOut(duration: 0.25)) { model.page = Self.tourPages }
                }
                .padding(.trailing, 6)
            }
            if model.page > 0 {
                Button("Назад") { go(-1) }.buttonStyle(Pill())
            }
            if model.page < pages - 1 {
                Button("Дальше") { go(1) }.buttonStyle(Pill(dark: true)).keyboardShortcut(.defaultAction)
            } else {
                Button("Готово", action: done).buttonStyle(Pill(dark: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func go(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.25)) { model.page = max(0, min(pages - 1, model.page + delta)) }
    }

    private func step(_ icon: String, _ title: String, _ text: String, _ check: OnboardingModel.Check,
                      action: String?, _ perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.sec).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.sec).fixedSize(horizontal: false, vertical: true)
                if case .missing(let why) = check {
                    Text(why).font(.system(size: 13)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if check == .ok {
                Label("Готово", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(Theme.sec)
            } else if let action {
                Button(action, action: perform).buttonStyle(Pill())
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("—").foregroundStyle(Theme.sec)
            Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
