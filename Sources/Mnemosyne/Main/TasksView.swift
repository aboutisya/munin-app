import AppKit
import MnemosyneCore
import SwiftUI

/// «Задачи»: задачи из всех встреч и добавленные вручную. Вид — список или календарь (неделя, месяц, год).
/// Отметка «выполнено» и правки задач из встреч хранятся в `meta.json` встречи, ручные задачи — в `.tasks.json`.
struct TasksView: View {
    @Bindable var library: LibraryModel
    @AppStorage("tasksView") private var view = "list"
    @AppStorage("tasksRange") private var range = "month"
    @AppStorage("tasksMineOnly") private var mineOnly = true
    @State private var showDone = false
    @State private var editing: String?
    @State private var adding = false
    @State private var addingPopover = false
    @State private var anchor = Date()
    @Namespace private var tabLine

    private var isCalendar: Bool { view == "calendar" }

    var body: some View {
        let visible = library.tasks.filter { (!mineOnly || $0.mine) && (showDone || !$0.done) }
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Задачи").font(.system(size: 30, weight: .bold)).padding(.top, 24)
                    tabs.padding(.top, 28)
                    controls.padding(.top, 24)
                    if isCalendar {
                        TasksCalendar(library: library, tasks: visible, range: range, anchor: $anchor) { r, d in
                            range = r
                            anchor = d
                        }
                        .padding(.top, 20)
                    } else {
                        list(visible)
                    }
                }
                .frame(maxWidth: isCalendar ? 1000 : Theme.column, alignment: .leading)
                .padding(.horizontal, isCalendar ? 40 : 0)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            library.loadTasks()
            // Моих задач нет, а чужие есть — сразу показываем все, чтобы экран не был пустым.
            if library.myOpenTasks == 0, library.tasks.contains(where: { !$0.done }) { mineOnly = false }
        }
    }

    // MARK: - Шапка

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                if isCalendar { addingPopover = true } else { editing = nil; adding = true }
            } label: {
                Label("Новая задача", systemImage: "plus")
            }
            .buttonStyle(Pill(dark: true))
            .popover(isPresented: $addingPopover, arrowEdge: .bottom) {
                TaskEditor(style: .card, caption: String(localized: "Новая задача · без встречи"),
                           what: "", who: "", due: TaskDates.today,
                           save: { w, p, d in library.addTask(what: w, who: p, due: d); addingPopover = false },
                           cancel: { addingPopover = false })
                    .taskPopover()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var tabs: some View {
        HStack(spacing: 24) {
            tab(String(localized: "Список"), "list")
            tab(String(localized: "Календарь"), "calendar")
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func tab(_ title: String, _ value: String) -> some View {
        let on = view == value
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                view = value
                editing = nil
                adding = false
            }
        } label: {
            VStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.sec)
                ZStack {
                    Rectangle().fill(.clear).frame(height: 2)
                    if on { Capsule().fill(Theme.ink).frame(height: 2).matchedGeometryEffect(id: "tab", in: tabLine) }
                }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(TabStyle())
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ChipButton(title: String(localized: "Мои"), on: mineOnly) { mineOnly = true }
            ChipButton(title: String(localized: "Все"), on: !mineOnly) { mineOnly = false }
            Spacer().frame(width: 10)
            ChipButton(title: String(localized: "Выполненные"), on: showDone) { showDone.toggle() }
            if isCalendar {
                Spacer()
                ChipButton(title: String(localized: "Неделя"), on: range == "week") { range = "week" }
                ChipButton(title: String(localized: "Месяц"), on: range == "month") { range = "month" }
                ChipButton(title: String(localized: "Год"), on: range == "year") { range = "year" }
                Spacer().frame(width: 14)
                arrow("chevron.left") { anchor = TasksCalendar.shift(anchor, range: range, by: -1) }
                Text(TasksCalendar.label(anchor, range: range))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 150)
                arrow("chevron.right") { anchor = TasksCalendar.shift(anchor, range: range, by: 1) }
                Button("Сегодня") { anchor = Date() }.buttonStyle(Pill()).padding(.leading, 8)
            }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec)
                .frame(width: 26, height: 26).contentShape(Rectangle())
                .hoverHighlight(radius: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Список

    @ViewBuilder private func list(_ visible: [TaskItem]) -> some View {
        if adding {
            HStack(alignment: .top, spacing: 12) {
                TaskMark(done: false).padding(.top, 4)
                TaskEditor(style: .inline, caption: String(localized: "Без встречи · Enter — сохранить"),
                           what: "", who: "", due: "",
                           save: { w, p, d in library.addTask(what: w, who: p, due: d); adding = false },
                           cancel: { adding = false })
            }
            .padding(.top, 26)
        }
        if visible.isEmpty && !adding {
            Text(library.tasks.isEmpty ? "Задачи появятся после анализа встреч." : "Открытых задач нет.")
                .font(.system(size: 15)).foregroundStyle(Theme.sec)
                .padding(.top, 28)
        }
        ForEach(groups(visible), id: \.title) { g in
            VStack(alignment: .leading, spacing: 6) {
                Text(g.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(g.late ? Theme.red : Theme.sec)
                ForEach(g.items) { row($0) }
            }
            .padding(.top, 28)
        }
    }

    private func groups(_ items: [TaskItem]) -> [(title: String, late: Bool, items: [TaskItem])] {
        let today = TaskDates.today
        let week = TaskDates.add(today, days: 7)
        var overdue: [TaskItem] = [], soon: [TaskItem] = [], later: [TaskItem] = [], none: [TaskItem] = []
        for t in items {
            if t.due.isEmpty { none.append(t) }
            else if t.due < today && !t.done { overdue.append(t) }
            else if t.due <= week { soon.append(t) }
            else { later.append(t) }
        }
        return [(String(localized: "Просрочено"), true, overdue), (String(localized: "Ближайшие 7 дней"), false, soon),
                (String(localized: "Позже"), false, later), (String(localized: "Без срока"), false, none)].filter { !$0.2.isEmpty }
    }

    @ViewBuilder private func row(_ t: TaskItem) -> some View {
        if editing == t.id {
            HStack(alignment: .top, spacing: 12) {
                TaskMark(done: t.done).padding(.top, 4)
                TaskEditor(style: .inline, caption: Self.caption(t) + " · " + String(localized: "Enter — сохранить"),
                           what: t.what, who: t.who, due: t.due,
                           save: { w, p, d in library.updateTask(t, what: w, who: p, due: d); editing = nil },
                           cancel: { editing = nil })
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .top, spacing: 12) {
                TaskCheck(done: t.done, late: Self.late(t)) { library.setDone(t, !t.done) }
                    .padding(.top, 2).padding(.horizontal, -2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.what).font(.system(size: 15)).lineSpacing(3)
                        .strikethrough(t.done).foregroundStyle(t.done ? Theme.sec : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        let m = meta(t)
                        if !m.isEmpty { Text(m) }
                        if let id = t.meetingId {
                            LinkButton(t.meetingTitle) { library.openMeeting(id) }
                        } else {
                            Text("без встречи")
                        }
                        if t.edited { Text("· изменено") }
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.sec)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .hoverHighlight()
            .padding(.horizontal, -10)
            .onTapGesture { adding = false; editing = t.id }
            .contextMenu { Self.menu(t, library: library) { editing = t.id } }
        }
    }

    private func meta(_ t: TaskItem) -> String {
        var parts: [String] = []
        if !mineOnly || !t.mine { parts.append(t.who.isEmpty ? String(localized: "не назначен") : t.who) }
        if !t.due.isEmpty { parts.append(String(localized: "до \(TaskDates.human(t.due))")) }
        return parts.isEmpty ? "" : parts.joined(separator: " · ") + " ·"
    }

    static func late(_ t: TaskItem) -> Bool { !t.due.isEmpty && !t.done && t.due < TaskDates.today }

    static func caption(_ t: TaskItem) -> String {
        t.isManual ? String(localized: "Без встречи") : String(localized: "Из встречи «\(t.meetingTitle)»")
    }

    /// Меню задачи: в списке и в календаре одно и то же.
    @ViewBuilder static func menu(_ t: TaskItem, library: LibraryModel, edit: @escaping () -> Void) -> some View {
        Button(t.done ? "Вернуть в работу" : "Отметить выполненной") { library.setDone(t, !t.done) }
        Button("Изменить…", action: edit)
        Button("Скопировать") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.what + (t.who.isEmpty ? "" : " — \(t.who)"), forType: .string)
        }
        if let id = t.meetingId {
            Button("Открыть встречу") { library.openMeeting(id) }
        }
        Divider()
        if t.edited {
            Button("Вернуть как было") { library.revertTask(t) }
        }
        Button("Удалить задачу", role: .destructive) { library.deleteTask(t) }
    }
}
