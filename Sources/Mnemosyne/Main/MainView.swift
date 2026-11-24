import AppKit
import MnemosyneCore
import SwiftUI

struct MainView: View {
    @Bindable var library: LibraryModel
    /// Боковая панель скрыта: кнопка у светофора или ⌃⌘S. Запоминается между запусками.
    @AppStorage("sidebarHidden") private var sidebarHidden = false

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                Sidebar(library: library)
                    .frame(width: 260)
                    .background(Theme.side)
                    .transition(.move(edge: .leading))
                Rectangle().fill(Theme.line).frame(width: 1)
            }
            Group {
                if library.section == .tasks {
                    TasksView(library: library)
                } else if let detail = library.detail {
                    MeetingView(library: library, detail: detail)
                } else {
                    VStack(spacing: 8) {
                        BrandMark(size: 56).padding(.bottom, 10)
                        Text("Встреч пока нет").font(.system(size: 17, weight: .semibold))
                        Text("Нажмите «Записать» или ⌃⌥⌘R").foregroundStyle(Theme.sec)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.win)
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { sidebarToggle }
        .background(Button("") { library.controller.showSettings() }.keyboardShortcut(",").opacity(0))
        .background(Button("") { toggleSidebar() }.keyboardShortcut("s", modifiers: [.control, .command]).opacity(0))
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 960, minHeight: 600)
    }


    /// Кнопка справа от светофора, на одном месте при открытой и скрытой панели.
    private var sidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Theme.sec)
                .frame(width: 28, height: 24).contentShape(Rectangle())
                .hoverHighlight(radius: 6)
        }
        .buttonStyle(.plain)
        .help(sidebarHidden ? "Показать боковую панель (⌃⌘S)" : "Скрыть боковую панель (⌃⌘S)")
        .accessibilityLabel(sidebarHidden ? "Показать боковую панель" : "Скрыть боковую панель")
        .padding(.leading, 76).padding(.top, 2)
        // Оверлей иначе встаёт под заголовком окна, а кнопка должна быть в одну линию со светофором.
        .ignoresSafeArea()
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { sidebarHidden.toggle() }
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @Bindable var library: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 38) // место под кнопки окна
            HStack(spacing: 8) {
                BrandMark(size: 20)
                Text("Мунин").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                Spacer()
                Button { library.controller.showSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Theme.sec)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                        .hoverHighlight(radius: 6)
                }
                .buttonStyle(.plain)
                .help("Настройки (⌘,)")
                .accessibilityLabel("Настройки")
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.bottom, 14)
            nav(String(localized: "Встречи"), .meetings, count: nil)
            nav(String(localized: "Задачи"), .tasks, count: library.myOpenTasks)
            ProjectsSection(library: library)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.sec)
                TextField(library.projectFilter.flatMap { library.projectDirectory.project($0) }.map { String(localized: "Поиск в «\($0.name)»") } ?? String(localized: "Поиск по встречам"),
                          text: $library.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !library.query.isEmpty {
                    Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sec) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hover))
            .padding(.top, 12)
            .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .shift]).opacity(0))

            if !library.tagDirectory.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    filterChip(nil)
                    ForEach(library.tagDirectory.tags) { filterChip($0) }
                }
                .padding(.top, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(library.groups, id: \.title) { group in
                        Text(group.title).font(.system(size: 12)).foregroundStyle(Theme.sec)
                            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                        ForEach(group.items) { item in row(item) }
                    }
                    if library.groups.isEmpty, library.projectFilter != nil, library.query.isEmpty, library.tagFilter.isEmpty {
                        Text("В проекте пока нет встреч. Новая запись попадёт сюда, а старую можно перенести из её карточки.")
                            .font(.system(size: 13)).foregroundStyle(Theme.sec).padding(10)
                    } else if library.groups.isEmpty, !library.query.isEmpty || !library.tagFilter.isEmpty {
                        Text(library.query.isEmpty ? "Нет встреч со всеми выбранными тегами." : "Ничего не нашлось")
                            .font(.system(size: 13)).foregroundStyle(Theme.sec).padding(10)
                    }
                }
            }
            .scrollIndicators(.never)

            RecordButton(controller: library.controller,
                         project: library.projectFilter.flatMap { library.projectDirectory.project($0) }?.name)
                .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    /// Чип фильтра: `nil` — «Все».
    private func filterChip(_ tag: MeetingTag?) -> some View {
        let on = tag.map { library.tagFilter.contains($0.id) } ?? library.tagFilter.isEmpty
        return Button {
            if let tag { library.toggleFilter(tag.id) } else { library.tagFilter = [] }
        } label: {
            HStack(spacing: 6) {
                if let tag { TagDot(color: tag.color) }
                Text(tag?.name ?? String(localized: "Все")).font(.system(size: 12, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Theme.ink : Theme.sec)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(on ? Theme.hover : .clear))
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func nav(_ title: String, _ section: LibraryModel.Section, count: Int?) -> some View {
        let on = library.section == section && (section != .meetings || library.projectFilter == nil)
        return Button {
            library.section = section
            if section == .meetings { library.projectFilter = nil }
        } label: {
            HStack {
                Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.sec) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(selected: on, radius: 6)
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: LibraryModel.Item) -> some View {
        let selected = library.section == .meetings && library.selectedId == item.id
        return Button {
            library.section = .meetings
            library.select(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meta.title)
                    .font(.system(size: 14))
                    .foregroundStyle(item.meta.title == MeetingStore.defaultTitle ? Theme.sec : Theme.ink)
                    .lineLimit(1)
                if let snippet = library.snippet(for: item.id) {
                    Text(snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.sec).lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        if ProcessingStage.of(item.meta, controller: library.controller) != nil {
                            ProgressView().controlSize(.mini)
                        }
                        Text(Self.detail(item, library: library))
                            .font(.system(size: 12))
                            .foregroundStyle(item.meta.status == .failed ? Theme.red : Theme.sec)
                        ForEach(library.tags(of: item)) { TagDot(color: $0.color, size: 7).help($0.name) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
            Divider()
            Button("Удалить встречу…", role: .destructive) { library.confirmDelete(item.id) }
                .disabled(item.meta.status == .recording)
        }
    }

    /// «14:31 · 44 мин», «Чт · 30 мин», «в очереди», «ошибка анализа».
    static func detail(_ item: LibraryModel.Item, library: LibraryModel) -> String {
        let m = item.meta
        if let label = ProcessingStage.listLabel(m, controller: library.controller) { return label }
        switch m.status {
        case .recording: return String(localized: "идёт запись")
        case .failed: return m.steps?["analyze"]?.status == .failed ? String(localized: "ошибка анализа") : String(localized: "ошибка обработки")
        case .transcribed where library.controller.analysis.isQueued(m.id):
            return m.steps?["analyze"]?.status == .queuedLimit ? String(localized: "ждёт лимита") : String(localized: "ждёт анализа")
        default: break
        }
        let cal = Calendar.current
        let ru = UILanguage.locale
        let when: String
        if cal.isDateInToday(m.startedAt) { when = m.startedAt.formatted(.dateTime.hour().minute().locale(ru)) }
        else if let d = cal.dateComponents([.day], from: m.startedAt, to: Date()).day, d < 7 {
            when = m.startedAt.formatted(.dateTime.weekday(.abbreviated).locale(ru)).capitalizedFirst
        } else { when = m.startedAt.formatted(.dateTime.day().month(.abbreviated).locale(ru)) }
        guard let d = m.durationSeconds else { return when }
        return "\(when) · \(UIFormat.duration(d))"
    }
}

struct RecordButton: View {
    let controller: AppController
    /// Открытый проект: новая запись попадёт в него.
    var project: String?

    var body: some View {
        let recording = controller.recorder.phase == .recording
        Button {
            controller.toggle()
        } label: {
            HStack(spacing: 8) {
                if recording {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.red).frame(width: 9, height: 9)
                    Text("Остановить")
                } else {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Записать")
                        if let project {
                            Text("в проект «\(project)»").font(.system(size: 11)).foregroundStyle(Theme.sec).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Text("⌃⌥⌘R").foregroundStyle(Theme.sec).font(.system(size: 12))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Capsule())
            .hoverHighlight(selected: true, radius: 18)
        }
        .buttonStyle(.plain)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
