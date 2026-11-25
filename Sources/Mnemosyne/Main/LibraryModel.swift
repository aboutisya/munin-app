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
        case summary = "Саммари", publicText = "Публичное", transcript = "Транскрипт", diagrams = "Диаграммы", feedback = "Тональность и фидбек", notes = "Мои заметки", attachments = "Приложения"
        var id: String { rawValue }
        /// Название вкладки в языке интерфейса (`rawValue` — стабильный идентификатор).
        var title: String {
            switch self {
            case .summary: String(localized: "Саммари")
            case .publicText: String(localized: "Публичное")
            case .transcript: String(localized: "Транскрипт")
            case .diagrams: String(localized: "Диаграммы")
            case .feedback: String(localized: "Тональность и фидбек")
            case .notes: String(localized: "Мои заметки")
            case .attachments: String(localized: "Приложения")
            }
        }
    }

    enum Section { case meetings, tasks, people }

    private(set) var items: [Item] = []
    var section: Section = .meetings {
        didSet {
            if section == .tasks { loadTasks() }
            if section == .people { loadPeople() }
        }
    }
    /// Сводка для раздела «Люди»; `nil` — ещё не считали.
    private(set) var people: PeopleOverview?
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
    /// Справочник проектов, перечитывается вместе со списком.
    private(set) var projectDirectory = ProjectDirectory(projects: [])
    /// Открытый проект: список показывает только его встречи, новая запись попадает в него.
    var projectFilter: UUID? {
        didSet {
            controller.targetProject = projectFilter
            if projectFilter != nil { section = .meetings }
            if let id = selectedId, let first = groups.first?.items.first,
               !groups.contains(where: { $0.items.contains { $0.id == id } }) { selectedId = first.id }
        }
    }

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
        let projects = ProjectDirectory.load(root: store.root)
        if projects != projectDirectory {
            projectDirectory = projects
            if let p = projectFilter, projects.project(p) == nil { projectFilter = nil }
        }
        let list = store.list().map { Item(folder: $0.folder, meta: $0.meta) }
        let signature = list.map { "\($0.meta.project?.uuidString ?? "")\($0.meta.tags ?? [])\($0.meta.id)\($0.meta.title)\($0.meta.status.rawValue)\($0.folder.lastPathComponent)\($0.meta.analysisHash ?? "")\($0.meta.publicHash ?? "")\($0.meta.steps?["public"]?.status.rawValue ?? "")\($0.meta.steps?["analyze"]?.status.rawValue ?? "")\($0.meta.summaryStyle ?? "")\($0.meta.summaryVersions?.map(\.style) ?? [])\($0.meta.steps?["style"]?.finishedAt?.timeIntervalSince1970 ?? 0)" }.joined()
        guard signature != lastSignature else { return }
        lastSignature = signature
        items = list
        loadTasks()
        loadPeople()
        if selectedId == nil { selectedId = items.first?.id } else { refreshDetail() }
        let index = self.index, store = self.store
        Task.detached { index?.sync(store: store) }
    }

    /// Встречи, отфильтрованные поиском, сгруппированные «Сегодня / Эта неделя / Ранее».
    var groups: [(title: String, items: [Item])] {
        let found = hits.map { hits in hits.compactMap { h in items.first { $0.id == h.id } } } ?? items
        let visible = found.filter {
            TagDirectory.matches($0.meta.tags, selected: tagFilter) && (projectFilter == nil || $0.meta.project == projectFilter)
        }
        if hits != nil { return [(String(localized: "Найдено"), visible)] }
        let cal = Calendar.current
        let now = Date()
        var today: [Item] = [], week: [Item] = [], earlier: [Item] = []
        for item in visible {
            if cal.isDateInToday(item.meta.startedAt) { today.append(item) }
            else if let d = cal.dateComponents([.day], from: item.meta.startedAt, to: now).day, d < 7 { week.append(item) }
            else { earlier.append(item) }
        }
        return [(String(localized: "Сегодня"), today), (String(localized: "Эта неделя"), week), (String(localized: "Ранее"), earlier)].filter { !$0.1.isEmpty }
    }

    func tags(of item: Item) -> [MeetingTag] { tagDirectory.tags(for: item.meta.tags) }

    // MARK: - Проекты

    var projects: [MeetingProject] { projectDirectory.sorted }

    func count(in project: UUID) -> Int { items.filter { $0.meta.project == project }.count }

    func project(of meta: MeetingMeta) -> MeetingProject? { projectDirectory.project(meta.project) }

    /// Создать проект и сразу открыть его. Если передана встреча — перенести её туда.
    func addProject(named name: String, moving meeting: UUID? = nil) {
        guard let p = try? store.addProject(named: name) else { return }
        if let meeting { try? store.setProject(p.id, meeting: meeting) }
        refresh()
        projectFilter = p.id
    }

    func renameProject(_ id: UUID, to name: String) {
        try? store.renameProject(id, to: name)
        refresh()
    }

    func deleteProject(_ id: UUID) {
        try? store.deleteProject(id)
        if projectFilter == id { projectFilter = nil }
        refresh()
    }

    /// Распознать запись заново на другом языке. Транскрипт, разбор и версии в других стилях соберутся заново.
    func retranscribe(_ id: UUID, language: String) {
        _ = try? store.update(id: id) { m in
            m.language = language
            m.summaryVersions = nil
            m.summaryStyle = nil
            m.status = .saved
        }
        controller.queue.enqueue(id)
        refresh()
    }

    /// Спросить и переместить папку встречи в Корзину. Выбор переходит на соседнюю встречу.
    func confirmDelete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Удалить «\(item.meta.title)»?")
        alert.informativeText = String(localized: "Папка с аудио, транскриптом и саммари переместится в Корзину.")
        alert.addButton(withTitle: String(localized: "Удалить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let visible = groups.flatMap(\.items)
        let next = visible.firstIndex(where: { $0.id == id }).flatMap { i in
            visible.indices.contains(i + 1) ? visible[i + 1].id : (i > 0 ? visible[i - 1].id : nil)
        }
        if selectedId == id { player.unload() }
        let folder = store.locate(id: id) ?? item.folder
        NSWorkspace.shared.recycle([folder]) { @Sendable _, _ in
            Task { @MainActor in
                if self.selectedId == id { self.selectedId = next }
                self.refresh()
            }
        }
    }

    func setProject(_ project: UUID?, meeting: UUID) {
        try? store.setProject(project, meeting: meeting)
        refresh()
    }

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
        all += TaskList.items(from: TaskBook.load(root: store.root), myName: myName)
        tasks = TaskList.sorted(all)
    }

    func setDone(_ task: TaskItem, _ done: Bool) {
        if let id = task.manualId {
            try? TaskBook.update(root: store.root) { b in
                if let i = b.tasks.firstIndex(where: { $0.id == id }) { b.tasks[i].done = done }
            }
        } else if let mid = task.meetingId {
            _ = try? store.update(id: mid) { TaskList.setDone(done, key: task.key, in: &$0) }
            reloadMeta(mid)
        }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].done = done }
    }

    /// Сохранить правку задачи: текст, исполнитель, срок. Пустой текст не сохраняем.
    func updateTask(_ task: TaskItem, what: String, who: String, due: String) {
        let w = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = who.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, w != task.what || p != task.who || due != task.due else { return }
        if let id = task.manualId {
            try? TaskBook.update(root: store.root) { b in
                guard let i = b.tasks.firstIndex(where: { $0.id == id }) else { return }
                b.tasks[i].what = w
                b.tasks[i].who = p
                b.tasks[i].due = due
            }
        } else if let mid = task.meetingId {
            _ = try? store.update(id: mid) { TaskList.setEdit(TaskEdit(what: w, who: p, due: due), key: task.key, in: &$0) }
            reloadMeta(mid)
        }
        loadTasks()
    }

    /// Перенести задачу на другой день (перетаскивание в календаре).
    func moveTask(_ task: TaskItem, to due: String) {
        updateTask(task, what: task.what, who: task.who, due: due)
    }

    /// Вернуть задачу из анализа к исходному виду.
    func revertTask(_ task: TaskItem) {
        guard let mid = task.meetingId else { return }
        _ = try? store.update(id: mid) { TaskList.setEdit(nil, key: task.key, in: &$0) }
        reloadMeta(mid)
        loadTasks()
    }

    func deleteTask(_ task: TaskItem) {
        if let id = task.manualId {
            try? TaskBook.update(root: store.root) { $0.tasks.removeAll { $0.id == id } }
        } else if let mid = task.meetingId {
            _ = try? store.update(id: mid) { TaskList.setEdit(TaskEdit(deleted: true), key: task.key, in: &$0) }
            reloadMeta(mid)
        }
        loadTasks()
    }

    /// Новая задача без встречи. Пустой текст — ничего не создаём.
    func addTask(what: String, who: String, due: String) {
        let w = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        try? TaskBook.update(root: store.root) {
            $0.tasks.append(ManualTask(what: w, who: who.trimmingCharacters(in: .whitespaces), due: due))
        }
        loadTasks()
    }

    // MARK: - Люди

    /// Пересчитать сводку по людям: читает транскрипты всех встреч, поэтому в фоне.
    func loadPeople() {
        let store = self.store
        let list = items.map(\.meta)
        Task.detached(priority: .userInitiated) {
            let editing = MeetingEditing(store: store)
            let pairs: [(meta: MeetingMeta, transcript: Transcript?)] = list.map { m in
                (m, store.locate(id: m.id).flatMap { editing.transcript($0) })
            }
            let overview = PeopleIndex.build(pairs, people: PeopleDirectory.load(root: store.root))
            await MainActor.run { self.people = overview }
        }
    }

    /// Неназванных голосов — для счётчика в сайдбаре.
    var unknownVoices: Int { people?.unknown.count ?? 0 }

    /// Назвать голос на всех его встречах и сохранить слепок человеку, если его ещё нет.
    func nameVoice(_ voice: PeopleOverview.Unknown, name: String, email: String? = nil) {
        let editing = self.editing
        guard let record = try? editing.nameVoice(voice.refs, name: name, email: email) else { return }
        if record.sample == nil, let ref = voice.refs.max(by: { $0.talkSeconds < $1.talkSeconds }) {
            let source = Self.sampleSource(ref.meetingTitle, ref.date)
            Task {
                try? await editing.makeSample(person: record.id, meeting: ref.meetingId, speaker: ref.speakerId, source: source)
                self.loadPeople()
            }
        }
        refreshDetail()
        loadPeople()
    }

    /// Голос — мой: имя из настроек, голос добавляется к моему отпечатку.
    func nameVoiceAsMe(_ voice: PeopleOverview.Unknown) {
        let dir = PeopleDirectory.load(root: store.root)
        let name = dir.me?.name ?? (controller.settings.myName.isEmpty ? "Я" : controller.settings.myName)
        nameVoice(voice, name: name)
    }

    /// Поля карточки человека. `reload: false` — при наборе текста, без пересчёта сводки.
    func updatePerson(_ id: UUID, reload: Bool = true, _ change: (inout PeopleDirectory.Record) -> Void) {
        var dir = PeopleDirectory.load(root: store.root)
        dir.update(id, change)
        try? dir.save(root: store.root)
        if reload { loadPeople() }
    }

    func renamePerson(_ id: UUID, to name: String) {
        try? editing.renamePerson(id, to: name)
        refreshDetail()
        loadPeople()
    }

    func clearVoice(_ id: UUID) {
        try? editing.clearVoice(id)
        loadPeople()
    }

    func removePerson(_ id: UUID) {
        var dir = PeopleDirectory.load(root: store.root)
        if let file = dir.person(id)?.sample {
            try? FileManager.default.removeItem(at: PeopleDirectory.sampleURL(root: store.root, file: file))
        }
        dir.remove(id)
        try? dir.save(root: store.root)
        loadPeople()
    }

    /// Взять слепок с другой встречи: следующая по списку, где человек говорил и аудио ещё есть.
    /// Возвращает текст ошибки, если подходящей встречи нет.
    func nextSample(for person: PeopleOverview.Known) async -> String? {
        let spoken = person.meetings.filter { $0.speakerId != nil && $0.talkSeconds >= 3 }
        guard !spoken.isEmpty else { return String(localized: "Нет встреч, где человек говорил") }
        let current = person.record.sampleSource
        let start = (spoken.firstIndex { Self.sampleSource($0.title, $0.date) == current }).map { $0 + 1 } ?? 0
        for k in 0..<spoken.count {
            let m = spoken[(start + k) % spoken.count]
            do {
                try await editing.makeSample(person: person.id, meeting: m.id, speaker: m.speakerId!,
                                             source: Self.sampleSource(m.title, m.date))
                loadPeople()
                return nil
            } catch { continue }
        }
        return String(localized: "Аудио этих встреч уже удалено")
    }

    /// Файл слепка: у человека — сохранённый; у неизвестного голоса — вырезается из аудио встречи.
    func sampleURL(for person: PeopleDirectory.Record) -> URL? {
        guard let file = person.sample else { return nil }
        let url = PeopleDirectory.sampleURL(root: store.root, file: file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func sampleURL(for voice: PeopleOverview.Unknown) async -> URL? {
        for ref in voice.refs.sorted(by: { $0.talkSeconds > $1.talkSeconds }) {
            if let url = try? await editing.unknownSample(ref) { return url }
        }
        return nil
    }

    static func sampleSource(_ title: String, _ date: Date) -> String {
        "\(title), " + date.formatted(.dateTime.day().month(.abbreviated).locale(UILanguage.locale))
    }

    private func reloadMeta(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }), let m = try? store.read(items[i].folder) { items[i].meta = m }
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
    /// Саммари в выбранном стиле; `nil` — показываем обычный разбор («Деловой»).
    var styledSummary: String?

    init(item: LibraryModel.Item, editing: MeetingEditing) {
        folder = item.folder
        meta = item.meta
        transcript = editing.transcript(item.folder)
        analysis = editing.analysis(item.folder)
        publicSummary = try? String(contentsOf: item.folder.appending(path: Publisher.publicFile), encoding: .utf8)
        publicGenerated = try? String(contentsOf: item.folder.appending(path: Publisher.generatedFile), encoding: .utf8)
        styledSummary = editing.store.activeStyledSummary(item.folder, meta: item.meta)
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
        if cal.isDateInToday(meta.startedAt) { day = String(localized: "Сегодня") }
        else if cal.isDateInYesterday(meta.startedAt) { day = String(localized: "Вчера") }
        else { day = meta.startedAt.formatted(.dateTime.day().month(.wide).locale(UILanguage.locale)) }
        var parts = [day]
        let time = { (d: Date) in d.formatted(.dateTime.hour().minute().locale(UILanguage.locale)) }
        if let end = meta.endedAt { parts.append("\(time(meta.startedAt))–\(time(end))") } else { parts.append(time(meta.startedAt)) }
        if let d = meta.durationSeconds { parts.append(UIFormat.duration(d)) }
        return parts.joined(separator: " · ")
    }

    /// Все люди встречи для аватаров: я, участники события, названные спикеры.
    var people: [String] {
        var names = [String(localized: "Я")]
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
