@preconcurrency import AVFoundation
import Foundation
import Observation

/// Запись встречи: две дорожки, «Я» (микрофон) и «Собеседники» (звук приложений).
@MainActor
@Observable
public final class Recorder {
    public enum Phase: Equatable, Sendable { case idle, recording, saving }

    public private(set) var phase: Phase = .idle
    public private(set) var startedAt: Date?
    public private(set) var title = MeetingStore.defaultTitle
    /// Последние 40 значений уровня для «волны» в поповере, 0…1.
    public private(set) var levels: [Float] = Array(repeating: 0, count: 40)
    public private(set) var micName: String?
    public private(set) var voiceProcessingActive = false
    public private(set) var systemAudioActive = false
    public private(set) var lastError: String?
    public private(set) var lastSaved: URL?
    public private(set) var devices: DeviceMonitor.Snapshot

    /// UID выбранного микрофона. `nil` — автоматически (встроенный MacBook).
    public var preferredMicUID: String?
    public var echoCancellationEnabled = true
    /// Режим, выбранный вручную. `nil` — автоматически по событию календаря.
    public var modeOverride: RecordingMode?
    /// Режим текущей (или следующей) записи.
    public private(set) var mode: RecordingMode = .online
    /// Привязанное событие календаря.
    public private(set) var event: CalendarEventInfo?
    /// Минуту нет звука приложений, у события есть переговорная и нет ссылки.
    public private(set) var offlineSuggested = false

    public let store: MeetingStore
    private let monitor: DeviceMonitor

    private var folder: URL?
    private var meta: MeetingMeta?
    private var tap: SystemAudioTap?
    private let mic = MicCapture()
    private var meWriter: TrackWriter?
    private var othersWriter: TrackWriter?
    private var ticker: Timer?
    private var silenceChecked = false
    private var micStartedNanos: UInt64 = 0
    private var tickCount = 0

    public init(store: MeetingStore = MeetingStore()) {
        self.store = store
        monitor = DeviceMonitor()
        devices = monitor.snapshot
        monitor.onChange = { [weak self] snapshot in self?.devicesChanged(snapshot) }
        mic.onEngineStopped = { [weak self] in
            Task { @MainActor in self?.micConfigurationChanged() }
        }
    }

    public var isRecording: Bool { phase == .recording }

    public var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Микрофон, который будет использован при старте (для подписи в поповере).
    public var plannedMic: AudioDevice? {
        Self.chooseMic(preferredUID: preferredMicUID, inputs: devices.inputs)
    }

    public var plannedVoiceProcessing: Bool {
        Self.needsVoiceProcessing(enabled: echoCancellationEnabled, output: devices.outputKind,
                                  mode: phase == .recording ? mode : (modeOverride ?? .online))
    }

    // MARK: - Политика (чистые функции, покрыты тестами)

    /// Выбранный в настройках, если подключён; иначе встроенный MacBook; иначе не-BT;
    /// иначе `nil` (системный по умолчанию). BT-микрофон без явного выбора не берём:
    /// он переводит AirPods в профиль HFP.
    public nonisolated static func chooseMic(preferredUID: String?, inputs: [AudioDevice]) -> AudioDevice? {
        if let uid = preferredUID, let device = inputs.first(where: { $0.uid == uid }) { return device }
        if let builtIn = inputs.first(where: \.isBuiltIn) { return builtIn }
        return inputs.first { !$0.isBluetooth }
    }

    public nonisolated static func needsVoiceProcessing(enabled: Bool, output: OutputKind, mode: RecordingMode) -> Bool {
        enabled && mode != .offline && output.leaksIntoMic
    }

    // MARK: - Старт и стоп

    public func toggle() async {
        switch phase {
        case .idle: await start()
        case .recording: await stop()
        case .saving: break
        }
    }

    public func start(event: CalendarEventInfo? = nil, title: String? = nil, project: UUID? = nil) async {
        guard phase == .idle else { return }
        lastError = nil
        offlineSuggested = false
        mode = modeOverride ?? ModeSuggestion.atStart(for: event)
        let title = title ?? event?.title.nilIfEmpty ?? MeetingStore.defaultTitle

        guard await Self.requestMicAccess() else {
            lastError = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность → Микрофон."
            return
        }

        let now = Date()
        var meta = MeetingMeta(title: title, startedAt: now, mode: mode)
        meta.outputKindAtStart = devices.outputKind
        meta.event = event
        meta.participants = event?.participants
        meta.project = project
        let folder: URL
        do {
            folder = try store.create(meta)
        } catch {
            lastError = "Не удалось создать папку встречи: \(error.localizedDescription)"
            return
        }

        // Сначала tap: создание aggregate device меняет список устройств,
        // и запущенный раньше микрофон получил бы лишнюю смену конфигурации.
        if mode != .offline {
            do {
                let others = try TrackWriter(url: folder.appending(path: "audio_others.caf"))
                let tap = SystemAudioTap()
                try tap.start(writer: others)
                self.tap = tap
                othersWriter = others
                systemAudioActive = true
                meta.tracks.append(TrackInfo(role: .others, file: "audio_others.caf", device: "все приложения"))
            } catch {
                Log.audio.error("tap: \(String(describing: error), privacy: .public)")
                systemAudioActive = false
                try? FileManager.default.removeItem(at: folder.appending(path: "audio_others.caf"))
                let text = "Нет доступа к звуку приложений — пишется только микрофон"
                meta.warnings = (meta.warnings ?? []) + [text]
                lastError = text
            }
        }

        do {
            mic.resetVoiceProcessingFailure()
            let me = try TrackWriter(url: folder.appending(path: "audio_me.caf"))
            meWriter = me
            let config = MicCapture.Config(device: plannedMic, voiceProcessing: plannedVoiceProcessing)
            try mic.start(config, writer: me)
            micName = mic.active?.device?.name ?? AudioDevices.defaultInput()?.name
            voiceProcessingActive = mic.active?.voiceProcessing ?? false
            meta.voiceProcessing = voiceProcessingActive
            meta.tracks.append(TrackInfo(role: .me, file: "audio_me.caf", device: micName))
            if config.voiceProcessing && !voiceProcessingActive {
                meta.warnings = (meta.warnings ?? []) + ["Эхоподавление не включилось, пишем без него"]
            }
        } catch {
            lastError = "Микрофон не запустился: \(error)"
            mic.stop()
            meWriter?.close()
            meWriter = nil
            tap?.stop()
            tap = nil
            othersWriter?.close()
            othersWriter = nil
            systemAudioActive = false
            try? FileManager.default.removeItem(at: folder)
            return
        }

        try? store.write(meta, to: folder)
        self.meta = meta
        self.folder = folder
        self.title = title
        self.event = event
        startedAt = now
        silenceChecked = false
        phase = .recording
        startTicker()
        micStartedNanos = HostTime.nowNanos
        Log.app.info("recording started: \(folder.lastPathComponent, privacy: .public)")
    }

    /// Остановить, закрыть файлы, сконвертировать в m4a. Возвращает папку встречи.
    @discardableResult
    public func stop() async -> URL? {
        guard phase == .recording, let folder, var meta else { return nil }
        phase = .saving
        ticker?.invalidate()
        ticker = nil

        tap?.stop()
        tap = nil
        mic.stop()
        meWriter?.close()
        othersWriter?.close()

        meta.endedAt = Date()
        for (role, writer) in [(TrackInfo.Role.me, meWriter), (.others, othersWriter)] {
            guard let writer, let i = meta.tracks.firstIndex(where: { $0.role == role }) else { continue }
            meta.tracks[i].startHostNanos = writer.startHostNanos
            meta.tracks[i].durationSeconds = writer.durationSeconds
            meta.tracks[i].paddedSeconds = writer.paddedSeconds > 0 ? writer.paddedSeconds : nil
        }
        meta.othersOffsetSeconds = MeetingMeta.offset(me: meWriter?.startHostNanos, others: othersWriter?.startHostNanos)
        meWriter = nil
        othersWriter = nil
        try? store.write(meta, to: folder)

        let store = self.store
        let finalMeta = meta
        let result: Result<MeetingMeta, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Self.finalize(folder: folder, meta: finalMeta, store: store) }
        }.value

        var saved = folder
        switch result {
        case .success(let final):
            // Название могло поменяться во время записи (выбрали событие) — приводим папку в соответствие.
            if let moved = try? store.rename(folder, to: final.title, byUser: final.titleEdited == true) { saved = moved }
            lastSaved = saved
        case .failure(let error): lastError = "Не удалось сохранить запись: \(error.localizedDescription)"
        }
        self.meta = nil
        self.folder = nil
        event = nil
        offlineSuggested = false
        startedAt = nil
        systemAudioActive = false
        voiceProcessingActive = false
        levels = Array(repeating: 0, count: levels.count)
        phase = .idle
        Log.app.info("recording saved: \(saved.lastPathComponent, privacy: .public)")
        return saved
    }

    /// CAF → m4a, удалить CAF, статус `saved`. Вызывается и при восстановлении после падения.
    nonisolated static func finalize(folder: URL, meta: MeetingMeta, store: MeetingStore) throws -> MeetingMeta {
        var meta = meta
        for i in meta.tracks.indices where meta.tracks[i].file.hasSuffix(".caf") {
            let caf = folder.appending(path: meta.tracks[i].file)
            let m4aName = meta.tracks[i].file.replacingOccurrences(of: ".caf", with: ".m4a")
            guard FileManager.default.fileExists(atPath: caf.path) else { continue }
            try AudioFileConverter.cafToM4A(caf, destination: folder.appending(path: m4aName))
            if meta.tracks[i].durationSeconds == nil {
                meta.tracks[i].durationSeconds = AudioFileConverter.duration(of: caf)
            }
            try FileManager.default.removeItem(at: caf)
            meta.tracks[i].file = m4aName
        }
        meta.status = .saved
        try store.write(meta, to: folder)
        return meta
    }

    /// Встречи, прерванные падением: дописываем, что успели, и сохраняем.
    public func recoverInterrupted() async -> Int {
        guard phase == .idle else { return 0 }
        let store = self.store
        return await Task.detached(priority: .utility) {
            var count = 0
            for (folder, var meta) in store.interrupted() {
                meta.recovered = true
                if meta.endedAt == nil {
                    let last = (try? FileManager.default.attributesOfItem(
                        atPath: folder.appending(path: "audio_me.caf").path)[.modificationDate]) as? Date
                    meta.endedAt = last ?? meta.startedAt
                }
                do {
                    _ = try Self.finalize(folder: folder, meta: meta, store: store)
                    count += 1
                } catch {
                    Log.storage.error("recover \(folder.lastPathComponent): \(String(describing: error), privacy: .public)")
                }
            }
            return count
        }.value
    }

    // MARK: - Событие и режим во время записи

    /// Сменить событие во время записи. Папка переименуется после «Остановить».
    public func bind(event newEvent: CalendarEventInfo?) {
        guard phase == .recording, var meta, let folder else { return }
        event = newEvent
        meta.event = newEvent
        meta.participants = newEvent?.participants
        if meta.titleEdited != true {
            meta.title = newEvent?.title.nilIfEmpty ?? MeetingStore.defaultTitle
            title = meta.title
        }
        self.meta = meta
        try? store.write(meta, to: folder)
    }

    /// Поменять режим во время записи. Дорожки продолжают писаться как есть:
    /// режим влияет только на разметку спикеров при обработке.
    public func setMode(_ newMode: RecordingMode) {
        guard phase == .recording, var meta, let folder else { return }
        mode = newMode
        meta.mode = newMode
        offlineSuggested = false
        self.meta = meta
        try? store.write(meta, to: folder)
        addEvent("Режим: \(newMode.title)")
    }

    public func dismissOfflineSuggestion() { offlineSuggested = false }

    // MARK: - Устройства во время записи

    private func devicesChanged(_ snapshot: DeviceMonitor.Snapshot) {
        let previous = devices
        devices = snapshot
        guard phase == .recording else { return }
        if previous.output?.uid != snapshot.output?.uid || previous.outputKind != snapshot.outputKind {
            addEvent("Вывод: \(snapshot.outputTitle)")
            mic.resetVoiceProcessingFailure()
            if previous.output?.uid != snapshot.output?.uid, let tap {
                do {
                    try tap.restart()
                } catch {
                    systemAudioActive = false
                    lastError = "Звук приложений пропал после смены вывода"
                    addEvent("Tap не пересоздался: \(error)")
                }
            }
        }
        restartMicIfNeeded()
    }

    private func micConfigurationChanged() {
        guard phase == .recording else { return }
        devices = DeviceMonitor.Snapshot(
            output: AudioDevices.defaultOutput(),
            outputKind: AudioDevices.defaultOutput().map(AudioDevices.outputKind) ?? .unknown,
            outputTitle: AudioDevices.defaultOutput().map(AudioDevices.outputTitle) ?? "нет вывода",
            inputs: AudioDevices.inputs())
        restartMicIfNeeded(force: true)
    }

    private func restartMicIfNeeded(force: Bool = false) {
        guard let meWriter else { return }
        let wanted = MicCapture.Config(
            device: plannedMic,
            voiceProcessing: plannedVoiceProcessing && !mic.voiceProcessingUnavailable)
        guard force || !mic.isRunning || wanted.device?.uid != mic.active?.device?.uid || wanted.voiceProcessing != mic.active?.voiceProcessing
        else { return }
        do {
            try mic.start(wanted, writer: meWriter)
            micStartedNanos = HostTime.nowNanos
            micName = mic.active?.device?.name ?? AudioDevices.defaultInput()?.name
            voiceProcessingActive = mic.active?.voiceProcessing ?? false
            if voiceProcessingActive { meta?.voiceProcessing = true }
            addEvent("Микрофон: \(micName ?? "по умолчанию"), эхоподавление \(voiceProcessingActive ? "вкл" : "выкл")")
        } catch {
            lastError = "Микрофон отключился: \(error)"
            addEvent("Микрофон не переподключился: \(error)")
        }
    }

    /// Сторож микрофона. Движок может стартовать без ошибки, но не отдавать буферы:
    /// так бывает сразу после переключения на AirPods. Каждую секунду проверяем,
    /// что буферы идут; если тишина от движка дольше 2 с, перезапускаем микрофон.
    /// Если при этом был VP, следующая попытка идёт без него.
    private func checkMicAlive() {
        guard phase == .recording, let writer = meWriter else { return }
        let now = HostTime.nowNanos
        let last = writer.lastWriteNanos ?? micStartedNanos
        guard now > last, Double(now - last) / 1e9 > 2, Double(now - micStartedNanos) / 1e9 > 2 else { return }
        Log.audio.error("mic watchdog: no buffers for 2 s, vp=\(self.voiceProcessingActive, privacy: .public)")
        if voiceProcessingActive && writer.lastWriteNanos == nil { mic.markVoiceProcessingUnavailable() }
        micStartedNanos = now
        restartMicIfNeeded(force: true)
        addEvent("Микрофон молчал, перезапущен")
    }

    private func addEvent(_ text: String) {
        guard var meta, let folder else { return }
        meta.deviceEvents.append(DeviceEvent(at: elapsed, text: text))
        self.meta = meta
        try? store.write(meta, to: folder)
        Log.audio.info("event: \(text, privacy: .public)")
    }

    // MARK: - Уровни

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        tickCount += 1
        if tickCount % 10 == 0 { checkMicAlive() }
        let level = max(meWriter?.level ?? 0, othersWriter?.level ?? 0)
        // RMS речи ~0.01–0.2. Логарифмическая шкала, чтобы тихая речь была видна.
        let db = 20 * log10(max(level, 1e-5))
        let normalized = Float(min(max((db + 60) / 50, 0), 1))
        levels.removeFirst()
        levels.append(normalized)

        if !silenceChecked, elapsed > 60, let tap, tap.totalBuffers > 0 {
            silenceChecked = true
            if tap.nonSilentBuffers == 0 {
                addEvent("Звук приложений: первая минута тишины")
                offlineSuggested = mode == .online
                    && ModeSuggestion.shouldSuggestOffline(event: event, systemAudioSilentFirstMinute: true)
            }
        }
    }

    private static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
