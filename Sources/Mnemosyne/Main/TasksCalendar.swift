import MnemosyneCore
import SwiftUI

/// Календарь задач: неделя, месяц или год. Задачи раскладываются по сроку; задачу можно
/// перетащить на другой день, на полоску «Без срока» — снять срок.
struct TasksCalendar: View {
    @Bindable var library: LibraryModel
    let tasks: [TaskItem]
    let range: String
    @Binding var anchor: Date
    /// Перейти к другому виду: из года в месяц, из «ещё N» в неделю.
    let open: (_ range: String, _ date: Date) -> Void

    @State private var popTask: String?
    @State private var newDay: String?
    @State private var target: String?
    @State private var hoverDay: String?

    private var cal: Calendar { TaskDates.calendar }
    private static let noDueKey = "-"

    var body: some View {
        let byDay = Dictionary(grouping: tasks.filter { !$0.due.isEmpty }, by: \.due)
        switch range {
        case "week": week(byDay)
        case "year": year(byDay)
        default: month(byDay)
        }
    }

    // MARK: - Подпись и листание

    static func label(_ d: Date, range: String) -> String {
        let cal = TaskDates.calendar
        let loc = UILanguage.locale
        switch range {
        case "week":
            guard let w = cal.dateInterval(of: .weekOfYear, for: d),
                  let last = cal.date(byAdding: .day, value: 6, to: w.start) else { return "" }
            if cal.isDate(w.start, equalTo: last, toGranularity: .month) {
                return "\(cal.component(.day, from: w.start))–" + last.formatted(.dateTime.day().month(.wide).locale(loc))
            }
            return w.start.formatted(.dateTime.day().month(.abbreviated).locale(loc)) + " – "
                + last.formatted(.dateTime.day().month(.abbreviated).locale(loc))
        case "year":
            return String(cal.component(.year, from: d))
        default:
            let f = DateFormatter()
            f.locale = loc
            f.dateFormat = "LLLL yyyy"
            let s = f.string(from: d)
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    static func shift(_ d: Date, range: String, by n: Int) -> Date {
        let unit: Calendar.Component = range == "week" ? .weekOfYear : range == "year" ? .year : .month
        return TaskDates.calendar.date(byAdding: unit, value: n, to: d) ?? d
    }

    /// «Пн», «Вт»… с понедельника.
    private var weekdays: [String] {
        let s = cal.shortStandaloneWeekdaySymbols
        return (Array(s[1...]) + [s[0]]).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    // MARK: - Месяц

    private func month(_ byDay: [String: [TaskItem]]) -> some View {
        let start = cal.dateInterval(of: .month, for: anchor)?.start ?? anchor
        let lead = (cal.component(.weekday, from: start) + 5) % 7
        let gridStart = cal.date(byAdding: .day, value: -lead, to: start) ?? start
        let length = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
        let rows = (lead + length + 6) / 7
        let m = cal.component(.month, from: anchor)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { w in
                    Text(w).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec)
                        .padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { c in
                            let d = cal.date(byAdding: .day, value: r * 7 + c, to: gridStart) ?? gridStart
                            dayCell(d, items: byDay[TaskDates.iso(d)] ?? [], outside: cal.component(.month, from: d) != m)
                        }
                    }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            noDue.padding(.top, 16)
        }
    }

    private func dayCell(_ d: Date, items: [TaskItem], outside: Bool) -> some View {
        let key = TaskDates.iso(d)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                dayNumber(d, outside: outside)
                Spacer(minLength: 0)
                if hoverDay == key || newDay == key { plus(key) }
            }
            .padding(.bottom, 2)
            ForEach(items.prefix(3)) { chip($0, wrap: false) }
            if items.count > 3 {
                Button(String(localized: "ещё \(items.count - 3)")) { open("week", d) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.sec)
                    .padding(.horizontal, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
        .clipped()
        .modifier(DayTarget(key: key, library: library, target: $target, hoverDay: $hoverDay))
    }

    private func dayNumber(_ d: Date, outside: Bool) -> some View {
        let key = TaskDates.iso(d)
        let today = key == TaskDates.today
        let day = cal.component(.day, from: d)
        let text = day == 1 ? d.formatted(.dateTime.day().month(.abbreviated).locale(UILanguage.locale)) : "\(day)"
        return Text(text)
            .font(.system(size: 12, weight: today ? .semibold : .regular))
            .foregroundStyle(today ? Theme.win : outside ? Theme.sec.opacity(0.55) : Theme.ink)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(today ? Theme.ink : .clear))
    }

    private func plus(_ key: String) -> some View {
        Button { newDay = key } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.sec)
                .frame(width: 22, height: 22).contentShape(Circle())
                .background(Circle().fill(newDay == key ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .help("Новая задача на этот день")
        .popover(isPresented: Binding(get: { newDay == key }, set: { if !$0, newDay == key { newDay = nil } }),
                 arrowEdge: .trailing) { newEditor(key) }
    }

    // MARK: - Неделя

    private func week(_ byDay: [String: [TaskItem]]) -> some View {
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: start) ?? start
                    let key = TaskDates.iso(d)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(weekdays[i]).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec)
                            dayNumber(d, outside: false)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(byDay[key] ?? []) { chip($0, wrap: true) }
                            if hoverDay == key || newDay == key {
                                Button { newDay = key } label: {
                                    Text("+ Задача").font(.system(size: 12)).foregroundStyle(Theme.sec)
                                        .padding(.horizontal, 8).frame(height: 24)
                                        .hoverHighlight(radius: 12)
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: Binding(get: { newDay == key }, set: { if !$0, newDay == key { newDay = nil } }),
                                         arrowEdge: .trailing) { newEditor(key) }
                            }
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
                    }
                    .modifier(DayTarget(key: key, library: library, target: $target, hoverDay: $hoverDay))
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            noDue.padding(.top, 16)
        }
    }

    // MARK: - Год

    private func year(_ byDay: [String: [TaskItem]]) -> some View {
        let y = cal.component(.year, from: anchor)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top), count: 4)
        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(1...12, id: \.self) { m in
                    miniMonth(cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? anchor, byDay)
                }
            }
            HStack(spacing: 16) {
                legend(Theme.ink, String(localized: "есть задачи"))
                legend(Theme.red, String(localized: "просрочено"))
                legend(Theme.sec.opacity(0.4), String(localized: "всё выполнено"))
                Text("Щелчок по месяцу открывает его")
            }
            .font(.system(size: 12)).foregroundStyle(Theme.sec)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 6, height: 6); Text(text) }
    }

    private func miniMonth(_ start: Date, _ byDay: [String: [TaskItem]]) -> some View {
        let lead = (cal.component(.weekday, from: start) + 5) % 7
        let length = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let f = DateFormatter()
        f.locale = UILanguage.locale
        f.dateFormat = "LLLL"
        let raw = f.string(from: start)
        let name = raw.prefix(1).uppercased() + raw.dropFirst()
        let open = (1...length).reduce(0) { n, d in
            let key = TaskDates.iso(cal.date(byAdding: .day, value: d - 1, to: start) ?? start)
            return n + (byDay[key]?.filter { !$0.done }.count ?? 0)
        }
        let letters = weekdays.map { String($0.prefix(1)) }
        let current = cal.isDate(start, equalTo: Date(), toGranularity: .month)
        return Button { self.open("month", start) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(current ? Theme.ink : Theme.ink.opacity(0.85))
                    if open > 0 { Text("\(open)").font(.system(size: 12)).foregroundStyle(Theme.sec) }
                }
                .padding(.leading, 2)
                Grid(horizontalSpacing: 0, verticalSpacing: 1) {
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            Text(letters[i]).font(.system(size: 10)).foregroundStyle(Theme.sec)
                                .frame(maxWidth: .infinity, minHeight: 16)
                        }
                    }
                    ForEach(0..<6, id: \.self) { r in
                        GridRow {
                            ForEach(0..<7, id: \.self) { c in
                                let n = r * 7 + c - lead + 1
                                if n >= 1 && n <= length {
                                    miniDay(cal.date(byAdding: .day, value: n - 1, to: start) ?? start, byDay)
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, minHeight: 23, maxHeight: 23)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .hoverHighlight(radius: 10)
        }
        .buttonStyle(.plain)
    }

    private func miniDay(_ d: Date, _ byDay: [String: [TaskItem]]) -> some View {
        let key = TaskDates.iso(d)
        let items = byDay[key] ?? []
        let openItems = items.filter { !$0.done }
        let today = key == TaskDates.today
        let late = !openItems.isEmpty && key < TaskDates.today
        let dot: Color? = items.isEmpty ? nil : late ? Theme.red : openItems.isEmpty ? Theme.sec.opacity(0.4) : Theme.ink
        return ZStack {
            if today { Circle().fill(Theme.ink).frame(width: 18, height: 18) }
            Text("\(cal.component(.day, from: d))")
                .font(.system(size: 11, weight: today || !openItems.isEmpty ? .semibold : .regular))
                .foregroundStyle(today ? Theme.win : openItems.isEmpty ? Theme.sec.opacity(items.isEmpty ? 0.6 : 1) : Theme.ink)
        }
        .frame(maxWidth: .infinity, minHeight: 23, maxHeight: 23)
        .overlay(alignment: .bottom) {
            if let dot, !today { Circle().fill(dot).frame(width: 4, height: 4).offset(y: 1) }
        }
    }

    // MARK: - Задача в календаре

    private func chip(_ t: TaskItem, wrap: Bool) -> some View {
        let late = TasksView.late(t)
        return HStack(alignment: wrap ? .top : .center, spacing: 2) {
            TaskCheck(done: t.done, late: late, size: 10) { library.setDone(t, !t.done) }
                .padding(.top, wrap ? 1 : 0)
            Button { popTask = t.id } label: {
                Text(t.what)
                    .font(.system(size: wrap ? 13 : 12))
                    .lineLimit(wrap ? 4 : 1)
                    .multilineTextAlignment(.leading)
                    .strikethrough(t.done)
                    .foregroundStyle(t.done ? Theme.sec : late ? Theme.red : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, wrap ? 2 : 0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 1).padding(.trailing, 5).padding(.vertical, wrap ? 2 : 1)
        .hoverHighlight(selected: popTask == t.id, radius: 6)
        .help(t.mine || t.who.isEmpty ? t.what : "\(t.what) — \(t.who)")
        .draggable(t.id) { dragPreview(t) }
        .contextMenu { TasksView.menu(t, library: library) { popTask = t.id } }
        .popover(isPresented: Binding(get: { popTask == t.id }, set: { if !$0, popTask == t.id { popTask = nil } }),
                 arrowEdge: .trailing) { editor(t) }
    }

    private func dragPreview(_ t: TaskItem) -> some View {
        HStack(spacing: 6) {
            TaskMark(done: false, size: 9)
            Text(t.what).font(.system(size: 12)).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Theme.win))
        .overlay(Capsule().strokeBorder(Theme.line))
    }

    private func editor(_ t: TaskItem) -> some View {
        TaskEditor(style: .card, caption: TasksView.caption(t), what: t.what, who: t.who, due: t.due,
                   openMeeting: t.meetingId.map { id in { popTask = nil; library.openMeeting(id) } },
                   save: { w, p, d in popTask = nil; library.updateTask(t, what: w, who: p, due: d) },
                   cancel: { popTask = nil })
            .taskPopover()
    }

    private func newEditor(_ key: String) -> some View {
        TaskEditor(style: .card, caption: String(localized: "Новая задача · \(TaskDates.human(key))"),
                   what: "", who: "", due: key,
                   save: { w, p, d in newDay = nil; library.addTask(what: w, who: p, due: d) },
                   cancel: { newDay = nil })
            .taskPopover()
    }

    // MARK: - Без срока

    private var noDue: some View {
        let items = tasks.filter { $0.due.isEmpty }
        return FlowLayout(spacing: 6) {
            Text("Без срока").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec).padding(.trailing, 6)
            ForEach(items) { t in
                chip(t, wrap: false)
                    .frame(maxWidth: 320)
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
            Text(items.isEmpty ? String(localized: "перетащите сюда, чтобы снять срок")
                               : String(localized: "перетащите на день, чтобы назначить срок"))
                .font(.system(size: 12)).foregroundStyle(Theme.sec).padding(.leading, 6)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .overlay {
            if target == Self.noDueKey {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sec.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: "")
        } isTargeted: { on in
            if on { target = Self.noDueKey } else if target == Self.noDueKey { target = nil }
        }
    }

    private func move(_ ids: [String], to due: String) -> Bool {
        guard let id = ids.first, let t = library.tasks.first(where: { $0.id == id }) else { return false }
        library.moveTask(t, to: due)
        return true
    }
}

/// Ячейка дня: линии сетки, наведение, приём перетащенной задачи (пунктир, пока над ней).
private struct DayTarget: ViewModifier {
    let key: String
    let library: LibraryModel
    @Binding var target: String?
    @Binding var hoverDay: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .overlay {
                if target == key {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.sec.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onHover { on in
                if on { hoverDay = key } else if hoverDay == key { hoverDay = nil }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let t = library.tasks.first(where: { $0.id == id }) else { return false }
                library.moveTask(t, to: key)
                return true
            } isTargeted: { on in
                if on { target = key } else if target == key { target = nil }
            }
    }
}
