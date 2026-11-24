import MnemosyneCore
import SwiftUI

/// Раздел «Проекты» в сайдбаре: папки встреч, создание, переименование и удаление.
struct ProjectsSection: View {
    @Bindable var library: LibraryModel
    @State private var adding = false
    @State private var draft = ""
    @State private var renaming: UUID?
    @State private var deleting: MeetingProject?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Проекты").font(.system(size: 12)).foregroundStyle(Theme.sec)
                Spacer()
                Button { startAdding() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.sec)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .hoverHighlight(radius: 5)
                }
                .buttonStyle(.plain)
                .help("Новый проект")
                .accessibilityLabel("Новый проект")
            }
            .padding(.leading, 10).padding(.top, 14).padding(.bottom, 2)

            ForEach(library.projects) { p in
                if renaming == p.id {
                    field(placeholder: p.name) { library.renameProject(p.id, to: $0) }
                } else {
                    row(p)
                }
            }
            if adding {
                field(placeholder: String(localized: "Название проекта")) { library.addProject(named: $0) }
            } else if library.projects.isEmpty {
                Button { startAdding() } label: {
                    Text("Папка для встреч одной темы").font(.system(size: 13)).foregroundStyle(Theme.sec)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .hoverHighlight(radius: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Удалить проект «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Отмена", role: .cancel) { deleting = nil }
            Button("Удалить", role: .destructive) {
                if let p = deleting { library.deleteProject(p.id) }
                deleting = nil
            }
        } message: {
            Text("Встречи останутся, просто без проекта.")
        }
    }

    private func row(_ p: MeetingProject) -> some View {
        let on = library.projectFilter == p.id
        let count = library.count(in: p.id)
        return Button { library.projectFilter = on ? nil : p.id } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "folder.fill" : "folder").font(.system(size: 13)).foregroundStyle(Theme.sec)
                    .frame(width: 16)
                Text(p.name).font(.system(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.sec) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(selected: on, radius: 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Переименовать…") { draft = p.name; renaming = p.id; fieldFocused = true }
            Button("Удалить проект…", role: .destructive) { deleting = p }
        }
    }

    /// Поле ввода на месте строки: Enter — применить, Esc или потеря фокуса — отмена.
    private func field(placeholder: String, commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.sec).frame(width: 16)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit {
                    let name = draft
                    finish()
                    commit(name)
                }
                .onExitCommand { finish() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.win))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .onChange(of: fieldFocused) { _, focused in if !focused { finish() } }
    }

    private func startAdding() {
        renaming = nil
        draft = ""
        adding = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func finish() {
        adding = false
        renaming = nil
        draft = ""
    }
}

/// Кнопка проекта в шапке встречи: показывает проект и переносит встречу в другой.
struct ProjectMenu: View {
    let library: LibraryModel
    let meta: MeetingMeta
    @State private var naming = false
    @State private var draft = ""

    var body: some View {
        let current = library.project(of: meta)
        Menu {
            Section("Проект встречи") {
                ForEach(library.projects) { p in
                    Toggle(p.name, isOn: Binding(get: { meta.project == p.id },
                                                 set: { if $0 { library.setProject(p.id, meeting: meta.id) } }))
                }
                Toggle("Без проекта", isOn: Binding(get: { meta.project == nil },
                                                   set: { if $0 { library.setProject(nil, meeting: meta.id) } }))
            }
            Divider()
            Button("Новый проект…") { draft = ""; naming = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(current?.name ?? String(localized: "Без проекта"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.sec)
            }
            .font(.system(size: 12))
            .foregroundStyle(current == nil ? Theme.sec : Theme.ink)
            .padding(.horizontal, 9).frame(height: 24)
            .overlay(Capsule().strokeBorder(Theme.line))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Новый проект", isPresented: $naming) {
            TextField("Название проекта", text: $draft)
            Button("Отмена", role: .cancel) {}
            Button("Создать") { library.addProject(named: draft, moving: meta.id) }
        } message: {
            Text("Встреча «\(meta.title)» сразу попадёт в него.")
        }
    }
}
