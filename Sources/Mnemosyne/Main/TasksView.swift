import AppKit
import MnemosyneCore
import SwiftUI

/// «Задачи»: action items из всех встреч. Отметка «выполнено» хранится в `meta.json` встречи.
struct TasksView: View {
    @Bindable var library: LibraryModel
    @State private var mineOnly = true
    @State private var showDone = false

    var body: some View {
        let visible = library.tasks.filter { (!mineOnly || $0.mine) && (showDone || !$0.done) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Задачи").font(.system(size: 30, weight: .bold))
                    HStack(spacing: 16) {
                        Picker("", selection: $mineOnly) {
                            Text("Мои").tag(true)
                            Text("Все").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                        Toggle("Выполненные", isOn: $showDone).toggleStyle(.checkbox).font(.system(size: 13))
                        Spacer()
                    }
                }
                .padding(.bottom, 24)

                if visible.isEmpty {
                    Text(library.tasks.isEmpty ? "Задачи появятся после анализа встреч." : "Открытых задач нет.")
                        .font(.system(size: 15)).foregroundStyle(Theme.sec)
                }
                ForEach(groups(visible), id: \.title) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.system(size: 12)).foregroundStyle(g.title == String(localized: "Просрочено") ? Theme.red : Theme.sec)
                            .padding(.top, 18).padding(.bottom, 6)
                        ForEach(g.items) { row($0) }
                    }
                }
            }
            .frame(width: Theme.column, alignment: .leading)
            .padding(.top, 56).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            library.loadTasks()
            // Моих задач нет, а чужие есть — сразу показываем все, чтобы экран не был пустым.
            if library.myOpenTasks == 0, library.tasks.contains(where: { !$0.done }) { mineOnly = false }
        }
    }

    private func groups(_ items: [TaskItem]) -> [(title: String, items: [TaskItem])] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        let week = f.string(from: Date().addingTimeInterval(7 * 86400))
        var overdue: [TaskItem] = [], soon: [TaskItem] = [], later: [TaskItem] = [], none: [TaskItem] = []
        for t in items {
            if t.due.isEmpty { none.append(t) }
            else if t.due < today && !t.done { overdue.append(t) }
            else if t.due <= week { soon.append(t) }
            else { later.append(t) }
        }
        return [(String(localized: "Просрочено"), overdue), (String(localized: "Ближайшие 7 дней"), soon),
                (String(localized: "Позже"), later), (String(localized: "Без срока"), none)].filter { !$0.1.isEmpty }
    }

    private func row(_ t: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { library.setDone(t, !t.done) } label: {
                Image(systemName: t.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(t.done ? Theme.sec : Theme.ink)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.what).font(.system(size: 15))
                    .strikethrough(t.done).foregroundStyle(t.done ? Theme.sec : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(meta(t)).foregroundStyle(Theme.sec)
                    LinkButton(t.meetingTitle) { library.openMeeting(t.meetingId) }
                }
                .font(.system(size: 13))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contextMenu {
            Button("Скопировать") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.what + (t.who.isEmpty ? "" : " — \(t.who)"), forType: .string)
            }
            Button("Открыть встречу") { library.openMeeting(t.meetingId) }
        }
    }

    private func meta(_ t: TaskItem) -> String {
        var parts: [String] = []
        if !mineOnly || !t.mine { parts.append(t.who.isEmpty ? String(localized: "не назначен") : t.who) }
        if !t.due.isEmpty { parts.append(String(localized: "до \(Self.due(t.due))")) }
        parts.append("")
        return parts.joined(separator: " · ")
    }

    static func due(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.dateTime.day().month(.wide).weekday(.abbreviated).locale(UILanguage.locale))
    }
}
