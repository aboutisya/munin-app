import AppKit
import MnemosyneCore
import SwiftUI

struct MainView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library)
                .frame(width: 260)
                .background(Theme.side)
            Rectangle().fill(Theme.line).frame(width: 1)
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
        .background(Button("") { library.controller.showSettings() }.keyboardShortcut(",").opacity(0))
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 960, minHeight: 600)
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
            nav("Встречи", .meetings, count: nil)
            nav("Задачи", .tasks, count: library.myOpenTasks)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.sec)
                TextField("Поиск по встречам", text: $library.query)
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
                    if library.groups.isEmpty, !library.query.isEmpty || !library.tagFilter.isEmpty {
                        Text(library.query.isEmpty ? "Нет встреч со всеми выбранными тегами." : "Ничего не нашлось")
                            .font(.system(size: 13)).foregroundStyle(Theme.sec).padding(10)
                    }
                }
            }
            .scrollIndicators(.never)

            RecordButton(controller: library.controller)
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
                Text(tag?.name ?? "Все").font(.system(size: 12, weight: on ? .semibold : .regular))
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
        let on = library.section == section
        return Button { library.section = section } label: {
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
    }

    /// «14:31 · 44 мин», «Чт · 30 мин», «в очереди», «ошибка анализа».
    static func detail(_ item: LibraryModel.Item, library: LibraryModel) -> String {
        let m = item.meta
        switch m.status {
        case .recording: return "идёт запись"
        case .saved, .transcribing, .diarizing, .merging:
            return library.controller.queue.current?.id == m.id ? "обработка" : "в очереди"
        case .analyzing: return "саммари готовится"
        case .failed: return m.steps?["analyze"]?.status == .failed ? "ошибка анализа" : "ошибка обработки"
        case .transcribed where library.controller.analysis.isQueued(m.id):
            return m.steps?["analyze"]?.status == .queuedLimit ? "ждёт лимита" : "ждёт анализа"
        default: break
        }
        let cal = Calendar.current
        let ru = Locale(identifier: "ru_RU")
        let when: String
        if cal.isDateInToday(m.startedAt) { when = m.startedAt.formatted(.dateTime.hour().minute().locale(ru)) }
        else if let d = cal.dateComponents([.day], from: m.startedAt, to: Date()).day, d < 7 {
            when = m.startedAt.formatted(.dateTime.weekday(.abbreviated).locale(ru)).capitalizedFirst
        } else { when = m.startedAt.formatted(.dateTime.day().month(.abbreviated).locale(ru)) }
        guard let d = m.durationSeconds else { return when }
        return "\(when) · \(Format.duration(d))"
    }
}

struct RecordButton: View {
    let controller: AppController

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
                    Text("Записать")
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
