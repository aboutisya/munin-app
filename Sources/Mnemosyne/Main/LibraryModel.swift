import AppKit
import AVFoundation
import MnemosyneCore
import MnemosynePipeline
import Observation

/// Список встреч, поиск и выбранная встреча для главного окна.
@MainActor
@Observable
final class LibraryModel {
    struct Item: Identifiable, Equatable {
        var folder: URL
        var meta: MeetingMeta
        var id: UUID { meta.id }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Саммари", publicText = "Публичное", transcript = "Транскрипт", diagrams = "Диаграммы", feedback = "Тональность и фидбек", notes = "Мои заметки"
        var id: String { rawValue }
    }

    enum Section { case meetings, tasks }

    private(set) var items: [Item] = []
    var section: Section = .meetings { didSet { if section == .tasks { loadTasks() } } }
    private(set) var tasks: [TaskItem] = []
    var query = "" { didSet { runSearch() } }
    private(set) var hits: [SearchIndex.Hit]?
    var selectedId: UUID? { didSet { if oldValue != selectedId { loadDetail() } } }
    var tab: Tab = .summary
    private(set) var detail: MeetingDetail?
    /// Справочник тегов; перечитывается вместе со списком, чтобы правки из настроек появлялись сами.
    private(set) var tagDirectory = TagDirectory(tags: [])
    /// Фильтр списка по тегам: встреча показывается, если у неё есть все выбранные.
    var tagFilter: Set<UUID> = []

    let controller: AppController
    let player = PlayerModel()
    @ObservationIgnored private let index: SearchIndex?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSignature = ""

    var store: MeetingStore { controller.recorder.store }
    var editing: MeetingEditing { MeetingEditing(store: store) }

    init(controller: AppController) {
        self.controller = controller
        index = try? SearchIndex(url: controller.recorder.store.root.appending(path: ".index.sqlite"))
        reload()
    }

    /// Пока окно открыто, раз в 2 с сверяем папки: обработка и анализ меняют файлы в фоне.
    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        player.pause()
    }

    func reload() {
        let dir = TagDirectory.load(root: store.root)
        if dir != tagDirectory {
            tagDirectory = dir
            tagFilter.formIntersection(dir.tags.map(\.id))
        }
        let list = store.list().map { Item(folder: $0.folder, meta: $0.meta) }
        let signature = list.map { "\($0.meta.tags ?? [])\($0.meta.id)\($0.meta.title)\($0.meta.status.rawValue)\($0.folder.lastPathComponent)\($0.meta.analysisHash ?? "")\($0.meta.publicHash ?? "")\($0.meta.steps?["public"]?.status.rawValue ?? "")\($0.meta.steps?["analyze"]?.status.rawValue ?? "")" }.joined()
        guard signature != lastSignature else { return }
        lastSignature = signature
        items = list
        loadTasks()
        if selectedId == nil { selectedId = items.first?.id } else { refreshDetail() }
        let index = self.index, store = self.store
        Task.detached { index?.sync(store: store) }
    }

    /// Встречи, отфильтрованные поиском, сгруппированные «Сегодня / Эта неделя / Ранее».
    var groups: [(title: String, items: [Item])] {
        let found = hits.map { hits in hits.compactMap { h in items.first { $0.id == h.id } } } ?? items
        let visible = found.filter { TagDirectory.matches($0.meta.tags, selected: tagFilter) }
        if hits != nil { return [("Найдено", visible)] }
        let cal = Calendar.current
        let now = Date()
        var today: [Item] = [], week: [Item] = [], earlier: [Item] = []
        for item in visible {
            if cal.isDateInToday(item.meta.startedAt) { today.append(item) }
            else if let d = cal.dateComponents([.day], from: item.meta.startedAt, to: now).day, d < 7 { week.append(item) }
            else { earlier.append(item) }
        }
        return [("Сегодня", today), ("Эта неделя", week), ("Ранее", earlier)].filter { !$0.1.isEmpty }
    }

    func tags(of item: Item) -> [MeetingTag] { tagDirectory.tags(for: item.meta.tags) }

    func toggleFilter(_ id: UUID) {
        if tagFilter.contains(id) { tagFilter.remove(id) } else { tagFilter.insert(id) }
    }

    /// Поставить или снять тег у выбранной встречи.
    func setTag(_ tag: MeetingTag, on: Bool, meeting: UUID) {
        try? store.setTag(tag.id, on: on, meeting: meeting)
        refresh()
    }

    func snippet(for id: UUID) -> String? { hits?.first { $0.id == id }?.snippet }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let index else { hits = nil; return }
        index.sync(store: store)
        hits = index.search(q)
    }

    // MARK: - Задачи

    func loadTasks() {
        let editing = self.editing
        let myName = controller.settings.myName
        var all: [TaskItem] = []
        for item in items {
            guard let a = editing.analysis(item.folder) else { continue }
            all += TaskList.items(from: a, meta: item.meta, transcript: editing.transcript(item.folder), myName: myName)
        }
        tasks = TaskList.sorted(all)
    }

    func setDone(_ task: TaskItem, _ done: Bool) {
        _ = try? store.update(id: task.meetingId) { TaskList.setDone(done, key: task.key, in: &$0) }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].done = done }
        if let i = items.firstIndex(where: { $0.id == task.meetingId }), let m = try? store.read(items[i].folder) { items[i].meta = m }
    }

    var myOpenTasks: Int { tasks.filter { $0.mine && !$0.done }.count }

    func openMeeting(_ id: UUID, tab: Tab = .summary) {
        section = .meetings
        select(id, tab: tab)
    }

    // MARK: - Деталь

    func select(_ id: UUID, tab: Tab? = nil) {
        selectedId = id
        if let tab { self.tab = tab }
    }

    private func loadDetail() {
        player.unload()
        guard let id = selectedId, let item = items.first(where: { $0.id == id }) else { detail = nil; return }
        detail = MeetingDetail(item: item, editing: editing)
        tab = detail?.analysis == nil && detail?.transcript != nil ? .transcript : .summary
    }

    /// Перечитать карточку после правки файлов из окна.
    func refresh() {
        lastSignature = ""
        reload()
        refreshDetail()
    }

    private func refreshDetail() {
        guard let id = selectedId, let item = items.first(where: { $0.id == id }) else { return }
        detail = MeetingDetail(item: item, editing: editing)
    }

    /// Перейти к таймкоду: вкладка «Транскрипт», плеер на этом месте.
    func jump(to ts: String) {
        guard let seconds = Timestamp.seconds(ts), let d = detail else { return }
        tab = .transcript
        player.ensureLoaded(d)
        player.seek(to: max(0, seconds - 1), play: true)
        player.scrollTarget = seconds
    }
}

/// Всё, что нужно карточке встречи. Пересобирается при изменении файлов.
struct MeetingDetail {
    var folder: URL
    var meta: MeetingMeta
    var transcript: Transcript?
    var analysis: Analysis?
    var publicSummary: String?
    /// Исходный ответ модели: сравниваем с `publicSummary`, чтобы показать «ваши правки».
    var publicGenerated: String?

    init(item: LibraryModel.Item, editing: MeetingEditing) {
        folder = item.folder
        meta = item.meta
        transcript = editing.transcript(item.folder)
        analysis = editing.analysis(item.folder)
        publicSummary = try? String(contentsOf: item.folder.appending(path: Publisher.publicFile), encoding: .utf8)
        publicGenerated = try? String(contentsOf: item.folder.appending(path: Publisher.generatedFile), encoding: .utf8)
    }

    /// Код спикера в анализе (`Я`, `С1`) → имя для показа.
    var names: [String: String] {
        guard let a = analysis, let t = transcript else { return [:] }
        return PersonalSummary.speakerNames(a, transcript: t)
    }

    func label(for speakerId: String) -> String {
        transcript?.speaker(speakerId)?.label ?? speakerId
    }

    /// «Сегодня · 14:31–15:15 · 44 мин»
    var dateLine: String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(meta.startedAt) { day = "Сегодня" }
        else if cal.isDateInYesterday(meta.startedAt) { day = "Вчера" }
        else { day = meta.startedAt.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))) }
        var parts = [day]
        let time = { (d: Date) in d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU"))) }
        if let end = meta.endedAt { parts.append("\(time(meta.startedAt))–\(time(end))") } else { parts.append(time(meta.startedAt)) }
        if let d = meta.durationSeconds { parts.append(Format.duration(d)) }
        return parts.joined(separator: " · ")
    }

    /// Все люди встречи для аватаров: я, участники события, названные спикеры.
    var people: [String] {
        var names = ["Я"]
        for p in meta.participants ?? [] where !p.isMe { names.append(p.displayName) }
        for s in transcript?.speakers ?? [] where s.id != "me" && s.nameSource != "generic" && !names.contains(s.label) {
            names.append(s.label)
        }
        return names
    }
}

/// Плеер записи: обе дорожки сведены в одну композицию со смещениями из `meta.json`.
@MainActor
@Observable
final class PlayerModel {
    private(set) var isPlaying = false
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var unavailable = false
    /// Куда прокрутить транскрипт (секунды) — выставляется при переходе по таймкоду.
    var scrollTarget: Double?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loadedId: UUID?

    func ensureLoaded(_ d: MeetingDetail) {
        guard loadedId != d.meta.id else { return }
        unload()
        loadedId = d.meta.id
        let composition = AVMutableComposition()
        let offsets = d.meta.trackOffsets
        var any = false
        for track in d.meta.tracks where track.file.hasSuffix(".m4a") {
            let url = d.folder.appending(path: track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            // Синхронно, чтобы не усложнять: файлы локальные и маленькие по метаданным.
            guard let source = asset.tracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let at = CMTime(seconds: offsets[track.role] ?? 0, preferredTimescale: 600)
            try? target.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: source, at: at)
            any = true
        }
        unavailable = !any
        guard any else { duration = d.meta.durationSeconds ?? 0; return }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        self.player = player
        duration = composition.duration.seconds
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = t.seconds
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }
    }

    func unload() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        loadedId = nil
        isPlaying = false
        current = 0
        duration = 0
        unavailable = false
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double, play: Bool) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = seconds
        if play { player.play(); isPlaying = true }
    }
}
