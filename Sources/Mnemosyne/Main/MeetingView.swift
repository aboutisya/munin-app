import AppKit
import MnemosyneCore
import MnemosynePipeline
import SwiftUI

/// Карточка встречи: шапка, событие, участники, вкладки. Колонка 760 pt, как в макете.
struct MeetingView: View {
    @Bindable var library: LibraryModel
    let detail: MeetingDetail

    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var rebindOpen = false
    @State private var copied = false
    @State private var copiedSummary = false
    @State private var retranscribeTo: String?
    @Namespace private var tabLine

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 24).id("top")
                        header
                        tabs.padding(.top, 28)
                        content(proxy: proxy).padding(.top, 28)
                    }
                    .frame(width: Theme.column, alignment: .leading)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                // Новая встреча или вкладка — с начала. macOS иначе прокручивает к первому элементу с фокусом.
                .onAppear { scrollToTop(proxy) }
                .onChange(of: library.tab) { _, _ in scrollToTop(proxy) }
                .onChange(of: detail.meta.id) { _, _ in scrollToTop(proxy) }
            }
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) { copySummary() }
            } label: {
                Label(copiedSummary ? "Скопировано" : "Копировать саммари", systemImage: copiedSummary ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(Pill())
            .disabled(detail.analysis == nil || detail.transcript == nil)
            .opacity(detail.analysis == nil ? 0.35 : 1)
            .help(detail.analysis == nil ? "Саммари появится после анализа" : "Скопировать саммари в markdown (⌘⌥C)")
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                withAnimation(.easeOut(duration: 0.15)) { copyPublic() }
            } label: {
                Label(copied ? "Скопировано" : "Копировать публичное", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(Pill(dark: true))
            .disabled(detail.publicSummary == nil)
            .opacity(detail.publicSummary == nil ? 0.35 : 1)
            .help(detail.publicSummary == nil ? "Публичное саммари появится после анализа" : "Скопировать для Mattermost (⌘⇧C)")
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Menu {
                moreMenu
            } label: {
                Text("•••").font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.hover))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var moreMenu: some View {
        let m = detail.meta
        let controller = library.controller
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([detail.folder]) }
        Button("Открыть транскрипт .md") { NSWorkspace.shared.open(detail.folder.appending(path: "transcript.md")) }
            .disabled(detail.transcript == nil)
        Divider()
        if detail.transcript != nil {
            Button(detail.analysis == nil ? "Проанализировать" : "Обновить саммари") {
                setSkip(false)
                controller.analysis.reanalyze(m.id)
            }
            .disabled(controller.analysis.isQueued(m.id) || controller.analysis.running == m.id)
        }
        if m.status == .failed, m.steps?["analyze"]?.status != .failed {
            Button("Повторить обработку") { controller.queue.retry(m.id) }
        }
        Toggle("Не анализировать", isOn: Binding(get: { m.skipAnalysis == true }, set: { setSkip($0) }))
        Divider()
        Button("Удалить встречу…", role: .destructive) { deleteMeeting() }
    }

    // MARK: - Теги

    private var tagsRow: some View {
        let mine = library.tagDirectory.tags(for: detail.meta.tags)
        return FlowLayout(spacing: 6) {
            ProjectMenu(library: library, meta: detail.meta)
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 3).padding(.top, 4)
            ForEach(mine) { TagChip(tag: $0) }
            Menu {
                ForEach(library.tagDirectory.tags) { t in
                    Toggle(isOn: Binding(get: { mine.contains(t) }, set: { library.setTag(t, on: $0, meeting: detail.meta.id) })) {
                        Label { Text(t.name) } icon: { Image(nsImage: t.color.menuImage) }
                    }
                }
                Divider()
                Button("Новый тег…") { library.controller.showSettings(newTag: true) }
                Button("Управлять тегами…") { library.controller.showSettings() }
            } label: {
                Text(mine.isEmpty ? "+ Тег" : "+").font(.system(size: 12)).foregroundStyle(Theme.sec)
                    .padding(.horizontal, 9).frame(height: 24)
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.top, 2)
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.dateLine).font(.system(size: 13)).foregroundStyle(Theme.sec)

            if editingTitle {
                TextField("Название", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .onSubmit(commitTitle)
                    .onExitCommand { editingTitle = false }
            } else {
                Text(detail.meta.title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(detail.meta.title == MeetingStore.defaultTitle ? Theme.sec : Theme.ink)
                    .onTapGesture(count: 2) { titleDraft = detail.meta.title; editingTitle = true }
                    .help("Дважды щёлкните, чтобы переименовать")
            }

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.sec)
                    Text(detail.meta.event.map { "\($0.title), \(TitleView.time($0.start))" } ?? String(localized: "Без события"))
                        .font(.system(size: 13)).foregroundStyle(Theme.sec).lineLimit(1)
                    LinkButton(String(localized: "Изменить")) { rebindOpen.toggle() }
                        .popover(isPresented: $rebindOpen, arrowEdge: .bottom) { rebindPopover }
                }
                HStack(spacing: 8) {
                    HStack(spacing: -3) {
                        ForEach(Array(detail.people.prefix(5).enumerated()), id: \.offset) { _, n in Avatar(name: n) }
                    }
                    Text(Self.peopleCount(detail.people.count)).font(.system(size: 13)).foregroundStyle(Theme.sec)
                }
                if let code = detail.transcript?.language {
                    languageMenu(code)
                }
            }

            tagsRow

            if MeetingEditing.analysisIsStale(detail.meta), !library.controller.analysis.isQueued(detail.meta.id) {
                HStack(spacing: 10) {
                    Text("Событие изменилось — обновить саммари? Это один вызов Claude.")
                        .font(.system(size: 13))
                    Button("Обновить") { library.controller.analysis.reanalyze(detail.meta.id) }.buttonStyle(Pill())
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
            }
        }
    }

    /// Язык встречи; из меню — распознать заново на другом.
    private func languageMenu(_ code: String) -> some View {
        let m = detail.meta
        let detected = (m.language ?? library.controller.settings.language) == MeetingLanguage.auto
        let canRedo = m.audioDeletedAt == nil && ProcessingStage.of(m, controller: library.controller) == nil
        return Menu {
            Section("Распознать заново") {
                Button("На русском") { retranscribeTo = "ru" }
                Button("На английском") { retranscribeTo = "en" }
                Button("С автоопределением языка") { retranscribeTo = MeetingLanguage.auto }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 12))
                Text(detected ? String(localized: "\(MeetingLanguage.uiTitle(code)) · определён автоматически") : MeetingLanguage.uiTitle(code))
            }
            .font(.system(size: 13)).foregroundStyle(Theme.sec)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(canRedo ? .visible : .hidden)
        .fixedSize()
        .disabled(!canRedo)
        .help(m.audioDeletedAt != nil ? "Аудио удалено — распознать заново нельзя" : "Язык встречи")
        .alert(retranscribeTitle,
               isPresented: Binding(get: { retranscribeTo != nil }, set: { if !$0 { retranscribeTo = nil } })) {
            Button("Отмена", role: .cancel) { retranscribeTo = nil }
            Button("Распознать") {
                if let l = retranscribeTo { library.retranscribe(m.id, language: l) }
                retranscribeTo = nil
            }
        } message: {
            Text("Транскрипт, саммари и задачи соберутся заново — это распознавание и вызовы Claude. Имена спикеров подтянутся по голосу, если он запомнен. Мои заметки останутся.")
        }
    }

    private var retranscribeTitle: String {
        guard let l = retranscribeTo else { return String(localized: "Распознать запись заново?") }
        if l == MeetingLanguage.auto { return String(localized: "Распознать запись заново с автоопределением?") }
        return MeetingLanguage.name(l) == "русский"
            ? String(localized: "Распознать запись заново на русском?")
            : String(localized: "Распознать запись заново на английском?")
    }

    private var rebindPopover: some View {
        let start = detail.meta.startedAt
        let end = detail.meta.endedAt ?? start.addingTimeInterval(3600)
        let events = library.controller.calendar.overlapping(start: start, end: end)
        return VStack(alignment: .leading, spacing: 2) {
            Text("События во время записи").font(.system(size: 12)).foregroundStyle(Theme.sec).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(events) { e in
                eventRow(title: e.title, time: "\(TitleView.time(e.start))–\(TitleView.time(e.end))", on: e.id == detail.meta.event?.id) { rebind(e) }
            }
            if events.isEmpty {
                Text("Нет событий в это время").font(.system(size: 13)).foregroundStyle(Theme.sec).padding(10)
            }
            eventRow(title: String(localized: "Без события"), time: nil, on: detail.meta.event == nil) { rebind(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func eventRow(title: String, time: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(time == nil ? Theme.sec : Theme.ink)
                if let time { Text(time).font(.system(size: 12)).foregroundStyle(Theme.sec) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Вкладки

    private var tabs: some View {
        HStack(spacing: 24) {
            ForEach(LibraryModel.Tab.allCases) { t in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { library.tab = t } } label: {
                    VStack(spacing: 8) {
                        Text(t.title)
                            .font(.system(size: 14, weight: library.tab == t ? .semibold : .regular))
                            .foregroundStyle(library.tab == t ? Theme.ink : Theme.sec)
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if library.tab == t {
                                Capsule().fill(Theme.ink).frame(height: 2).matchedGeometryEffect(id: "tab", in: tabLine)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(TabStyle())
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    @ViewBuilder private func content(proxy: ScrollViewProxy) -> some View {
        switch library.tab {
        case .summary: SummaryTab(library: library, detail: detail, copied: copiedSummary, copy: copySummaryAnimated)
        case .notes: NotesTab(detail: detail)
        case .publicText: PublicTab(library: library, detail: detail, copied: $copied, copy: copyPublic)
        case .transcript: TranscriptTab(library: library, detail: detail, proxy: proxy)
        case .diagrams: DiagramsTab(detail: detail)
        case .feedback: FeedbackTab(library: library, detail: detail)
        }
    }

    // MARK: - Действия

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard library.player.scrollTarget == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard library.player.scrollTarget == nil else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
            proxy.scrollTo("top", anchor: .top)
        }
    }

    private func commitTitle() {
        editingTitle = false
        let new = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != detail.meta.title else { return }
        let store = library.store
        if let folder = store.locate(id: detail.meta.id) {
            _ = try? store.rename(folder, to: new)
            try? library.editing.rerender(id: detail.meta.id)
        }
        library.reload()
    }

    private func rebind(_ event: CalendarEventInfo?) {
        rebindOpen = false
        let store = library.store
        guard let folder = store.locate(id: detail.meta.id) else { return }
        _ = try? store.rebind(folder, to: event)
        try? library.editing.rerender(id: detail.meta.id)
        library.reload()
    }

    private func setSkip(_ skip: Bool) {
        _ = try? library.store.update(id: detail.meta.id) { $0.skipAnalysis = skip }
        library.reload()
    }

    private func copySummaryAnimated() { withAnimation(.easeOut(duration: 0.15)) { copySummary() } }

    /// Саммари целиком, как на вкладке: коротко, решения, задачи, темы, инсайты, участники.
    private func copySummary() {
        let text: String
        if let styled = detail.styledSummary {
            text = "# \(detail.meta.title)\n\n\(styled)\n"
        } else {
            guard let a = detail.analysis, let t = detail.transcript else { return }
            text = PersonalSummary.render(a, meta: detail.meta, transcript: t, forCopy: true)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSummary = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedSummary = false }
    }

    private func copyPublic() {
        // С диска: правка на вкладке «Публичное» могла только что сохраниться.
        let url = detail.folder.appending(path: Publisher.publicFile)
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? detail.publicSummary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func deleteMeeting() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Удалить «\(detail.meta.title)»?")
        alert.informativeText = String(localized: "Папка с аудио, транскриптом и саммари переместится в Корзину.")
        alert.addButton(withTitle: String(localized: "Удалить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.player.unload()
        NSWorkspace.shared.recycle([detail.folder]) { _, _ in
            Task { @MainActor in
                library.selectedId = nil
                library.reload()
            }
        }
    }

    static func peopleCount(_ n: Int) -> String {
        plural(n, ru: ("участник", "участника", "участников"), en: ("participant", "participants"))
    }
}

/// Вкладка: при наведении текст темнеет.
struct TabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.7 : hovering ? 0.85 : 1)
                .brightness(hovering ? -0.15 : 0)
                .onHover { hovering = $0 }
        }
    }
}
