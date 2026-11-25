import MnemosyneCore
import SwiftUI

/// Даты задач: в задачах срок хранится строкой `ГГГГ-ММ-ДД`. Неделя — с понедельника.
enum TaskDates {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = UILanguage.locale
        return c
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func date(_ s: String) -> Date? { s.isEmpty ? nil : isoFormatter.date(from: s) }
    static var today: String { iso(Date()) }

    static func add(_ s: String, days: Int) -> String {
        guard let d = date(s), let r = calendar.date(byAdding: .day, value: days, to: d) else { return s }
        return iso(r)
    }

    /// «чт, 26 ноября».
    static func human(_ s: String) -> String {
        guard let d = date(s) else { return s }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(UILanguage.locale))
    }

    /// Ближайшая пятница после сегодняшнего дня.
    static var friday: String {
        let wd = calendar.component(.weekday, from: Date())
        let n = (6 - wd + 7) % 7
        return add(today, days: n == 0 ? 7 : n)
    }
}

/// Чип-капсула, как фильтр тегов: выбранный — с подложкой и жирным.
struct ChipButton: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.ink : Theme.sec)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(on ? Theme.hover : .clear))
                .overlay(Capsule().strokeBorder(Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Кружок задачи, как в саммари: просроченная — красный контур, выполненная — залита.
struct TaskMark: View {
    let done: Bool
    var late = false
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if done {
                Circle().fill(Theme.ink)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.win)
            } else {
                Circle().strokeBorder(late ? Theme.red : Theme.sec, lineWidth: size > 12 ? 1.5 : 1.2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Кружок-переключатель «выполнено». Нажимается вся площадь, а не только контур;
/// при наведении в пустом кружке проступает галочка — видно, что его можно нажать.
struct TaskCheck: View {
    let done: Bool
    var late = false
    var size: CGFloat = 16
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                TaskMark(done: done, late: late, size: size)
                if hovering && !done {
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.sec)
                }
            }
            .frame(width: max(size, 20), height: max(size, 20))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(done ? String(localized: "Вернуть в работу") : String(localized: "Отметить выполненной"))
    }
}

extension View {
    /// Всплывающее окно задачи: белый фон, как у окна названия, а не серый системный.
    func taskPopover() -> some View {
        padding(24).frame(width: 400).background(Theme.win).presentationBackground(Theme.win)
    }
}

/// Правка задачи: текст, исполнитель, срок. В списке — прямо на месте строки, в календаре — во всплывающем окне.
struct TaskEditor: View {
    enum Style { case inline, card }

    let style: Style
    let caption: String
    let save: (_ what: String, _ who: String, _ due: String) -> Void
    let cancel: () -> Void
    /// В окне календаря: ссылка «Открыть встречу».
    var openMeeting: (() -> Void)?

    @State private var what: String
    @State private var who: String
    @State private var due: String
    @State private var picking = false
    @FocusState private var focused: Bool

    init(style: Style, caption: String, what: String, who: String, due: String,
         openMeeting: (() -> Void)? = nil,
         save: @escaping (String, String, String) -> Void, cancel: @escaping () -> Void) {
        self.style = style
        self.openMeeting = openMeeting
        self.caption = caption
        self.save = save
        self.cancel = cancel
        _what = State(initialValue: what)
        _who = State(initialValue: who)
        _due = State(initialValue: due)
    }

    private var empty: Bool { what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .card ? 18 : 16) {
            if style == .card {
                Text(caption).font(.system(size: 12)).foregroundStyle(Theme.sec)
            }
            VStack(spacing: 6) {
                TextField("Что сделать", text: $what, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(style == .card ? .system(size: 17, weight: .semibold) : .system(size: 15))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(commit)
                Rectangle().fill(Theme.ink).frame(height: 1)
            }
            if style == .card {
                whoField
                dueField
            } else {
                HStack(alignment: .top, spacing: 28) {
                    whoField.frame(width: 200)
                    dueField
                }
            }
            HStack(spacing: 8) {
                if style == .inline {
                    Text(caption).font(.system(size: 12)).foregroundStyle(Theme.sec)
                } else if let openMeeting {
                    LinkButton(String(localized: "Открыть встречу"), action: openMeeting)
                }
                Spacer()
                Button("Esc", action: cancel).buttonStyle(Pill()).keyboardShortcut(.cancelAction)
                Button("Сохранить", action: commit).buttonStyle(Pill(dark: true))
                    .keyboardShortcut(.defaultAction).disabled(empty)
            }
        }
        .onAppear { focused = true }
    }

    private var whoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Исполнитель").font(.system(size: 12)).foregroundStyle(Theme.sec)
            TextField("Не назначен", text: $who).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(commit)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var dueField: some View {
        let today = TaskDates.today
        let quick: [(String, String)] = [
            (String(localized: "Сегодня"), today),
            (String(localized: "Завтра"), TaskDates.add(today, days: 1)),
            (String(localized: "В пятницу"), TaskDates.friday),
            (String(localized: "Через неделю"), TaskDates.add(today, days: 7)),
            (String(localized: "Без срока"), "")
        ]
        let custom = !quick.contains { $0.1 == due }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Срок").font(.system(size: 12)).foregroundStyle(Theme.sec)
            FlowLayout(spacing: 6) {
                ForEach(quick, id: \.0) { q in
                    ChipButton(title: q.0, on: due == q.1) { due = q.1 }
                }
                ChipButton(title: custom ? TaskDates.human(due) : String(localized: "Другая дата…"), on: custom) { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        DatePicker("", selection: Binding(
                            get: { TaskDates.date(due) ?? Date() },
                            set: { due = TaskDates.iso($0); picking = false }
                        ), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .environment(\.locale, UILanguage.locale)
                        .environment(\.calendar, TaskDates.calendar)
                        .padding(12)
                    }
            }
        }
    }

    private func commit() {
        guard !empty else { return }
        save(what, who, due)
    }
}
