import AppKit
import MnemosyneCore
import SwiftUI

/// «Люди»: неназванные голоса и знакомые люди. Голос можно послушать (слепок 3–5 с) и назвать —
/// имя встанет во всех встречах, где звучит этот голос, а дальше Мунин будет узнавать человека сам.
struct PeopleView: View {
    @Bindable var library: LibraryModel
    @State private var filter = "all"
    @State private var openPerson: UUID?
    @State private var naming: String?
    @State private var player = SamplePlayer()
    @State private var backfilled = false

    var body: some View {
        Group {
            if let id = openPerson, let person = library.people?.known.first(where: { $0.id == id }) {
                PersonCard(library: library, person: person, player: player) {
                    player.stop()
                    openPerson = nil
                }
            } else {
                list
            }
        }
        .onAppear { library.loadPeople() }
        .onDisappear { player.stop() }
        .task(id: library.people?.known.count) { await backfillSamples() }
    }

    // MARK: - Список

    private var list: some View {
        let overview = library.people
        let unknown = overview?.unknown ?? []
        let known = overview?.known ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 46)
                Text("Люди").font(.system(size: 30, weight: .bold)).padding(.top, 24)
                Text("Голос запоминается, когда вы называете собеседника. Дальше Мунин узнаёт его сам.")
                    .font(.system(size: 13)).foregroundStyle(Theme.sec).padding(.top, 10)
                HStack(spacing: 6) {
                    ChipButton(title: String(localized: "Все"), on: filter == "all") { filter = "all" }
                    ChipButton(title: String(localized: "Не распознаны"), on: filter == "unknown") { filter = "unknown" }
                    ChipButton(title: String(localized: "Знакомые"), on: filter == "known") { filter = "known" }
                }
                .padding(.top, 24)

                if overview == nil {
                    ProgressView().controlSize(.small).padding(.top, 28)
                }
                if filter != "known", !unknown.isEmpty {
                    section(String(localized: "Не распознаны · \(unknown.count)")) {
                        ForEach(unknown) { unknownRow($0, known: known) }
                    }
                }
                if filter == "unknown", unknown.isEmpty, overview != nil {
                    Text("Все голоса названы.").font(.system(size: 15)).foregroundStyle(Theme.sec).padding(.top, 28)
                }
                if filter != "unknown", !known.isEmpty {
                    section(String(localized: "Знакомые · \(known.count)")) {
                        ForEach(known) { knownRow($0) }
                    }
                }
            }
            .frame(width: Theme.column, alignment: .leading)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec)
            content()
        }
        .padding(.top, 28)
    }

    private func unknownRow(_ u: PeopleOverview.Unknown, known: [PeopleOverview.Known]) -> some View {
        HStack(spacing: 12) {
            Text("?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sec)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Theme.sec.opacity(0.4), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(u.label).font(.system(size: 15))
                Text(Self.where_(u)).font(.system(size: 13)).foregroundStyle(Theme.sec).lineLimit(1)
            }
            Spacer(minLength: 12)
            VoicePill(id: u.id, player: player) { await library.sampleURL(for: u) }
            Button("Кто это?") { naming = u.id }
                .buttonStyle(Pill())
                .popover(isPresented: Binding(get: { naming == u.id }, set: { if !$0, naming == u.id { naming = nil } }),
                         arrowEdge: .bottom) {
                    WhoDialog(library: library, voice: u, known: known.map(\.record), player: player) { naming = nil }
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .hoverHighlight(selected: naming == u.id)
        .padding(.horizontal, -10)
    }

    private func knownRow(_ k: PeopleOverview.Known) -> some View {
        HStack(spacing: 12) {
            Avatar(name: k.isMe ? "Я" : k.record.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(k.record.name).font(.system(size: 15))
                    if k.isMe { Text("это вы").font(.system(size: 12)).foregroundStyle(Theme.sec) }
                }
                Text(Self.summary(k)).font(.system(size: 13)).foregroundStyle(Theme.sec).lineLimit(1)
            }
            Spacer(minLength: 12)
            if library.sampleURL(for: k.record) != nil {
                VoicePill(id: Self.sampleId(k.record), player: player) { library.sampleURL(for: k.record) }
            } else if k.record.voices.isEmpty {
                Text("голос пока не записан").font(.system(size: 12)).foregroundStyle(Theme.sec)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverHighlight()
        .padding(.horizontal, -10)
        .onTapGesture { player.stop(); openPerson = k.id }
        .contextMenu {
            Button("Открыть") { player.stop(); openPerson = k.id }
            if !k.isMe {
                Divider()
                Button("Удалить из списка", role: .destructive) { library.removePerson(k.id) }
            }
        }
    }

    /// У людей с голосом, но без слепка (назвали до этой версии) — вырезать слепок, пока аудио встреч на месте.
    private func backfillSamples() async {
        guard !backfilled, let known = library.people?.known else { return }
        backfilled = true
        for k in known where k.record.sample == nil && !k.record.voices.isEmpty {
            _ = await library.nextSample(for: k)
        }
    }

    static func sampleId(_ r: PeopleDirectory.Record) -> String { "\(r.id)|\(r.sampleSource ?? "")" }

    static func where_(_ u: PeopleOverview.Unknown) -> String {
        guard let first = u.refs.first else { return "" }
        var s = LibraryModel.sampleSource(first.meetingTitle, first.date)
        if u.refs.count > 1 { s += String(localized: " и ещё \(u.refs.count - 1)") }
        if let hint = u.suggestedName { s += " · " + String(localized: "похоже на \(hint)") }
        return s
    }

    static func summary(_ k: PeopleOverview.Known) -> String {
        let n = plural(k.meetings.count, ru: ("встреча", "встречи", "встреч"), en: ("meeting", "meetings"))
        guard let last = k.meetings.first else {
            return k.isMe ? String(localized: "голос записан в настройках") : n
        }
        return n + " · " + String(localized: "последняя \(last.date.formatted(.dateTime.day().month(.abbreviated).locale(UILanguage.locale)))")
    }
}

// MARK: - «Кто это?»

/// Назвать голос: послушать слепок, прочитать цитату, вписать имя или выбрать знакомого.
private struct WhoDialog: View {
    let library: LibraryModel
    let voice: PeopleOverview.Unknown
    let known: [PeopleDirectory.Record]
    let player: SamplePlayer
    let close: () -> Void

    @State private var name = ""
    /// Почта выбранного через «@» участника — уходит в справочник вместе с именем.
    @State private var picked: Candidate?
    @State private var highlight = 0
    @FocusState private var focused: Bool

    /// Кого можно выбрать через «@»: участники встреч с этим голосом, потом знакомые из справочника.
    struct Candidate: Identifiable, Equatable {
        var name: String
        var email: String?
        var note: String
        var id: String { (email ?? name).lowercased() }
    }

    private var mentioning: Bool { name.hasPrefix("@") }

    private var candidates: [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ c: Candidate) {
            let keys = [c.name.lowercased()] + (c.email.map { [$0.lowercased()] } ?? [])
            guard keys.allSatisfy({ !seen.contains($0) }) else { return }
            keys.forEach { seen.insert($0) }
            out.append(c)
        }
        for r in voice.refs {
            for p in r.attendees { add(Candidate(name: p.displayName, email: p.email, note: r.meetingTitle)) }
        }
        for p in known where p.isMe != true {
            add(Candidate(name: p.name, email: p.email, note: String(localized: "знакомый")))
        }
        let q = name.dropFirst().lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(out.prefix(6)) }
        return Array(out.filter { $0.name.lowercased().contains(q) || ($0.email?.lowercased().contains(q) ?? false) }.prefix(6))
    }

    private var suggestions: [PeopleDirectory.Record] {
        guard !mentioning else { return [] }
        let q = name.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = known.filter { $0.isMe != true }
        if q.isEmpty {
            guard let hint = voice.suggestedName?.lowercased() else { return [] }
            return pool.filter { $0.name.lowercased() == hint }
        }
        return Array(pool.filter { $0.name.lowercased().contains(q) && $0.name.lowercased() != q }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(voice.label + " · " + PeopleView.where_(voice)).font(.system(size: 12)).foregroundStyle(Theme.sec)
            VoicePill(id: voice.id, large: true, player: player) { await library.sampleURL(for: voice) }
            if let quote = voice.refs.first?.quote, !quote.isEmpty {
                Text("«\(quote)»").font(.system(size: 13)).foregroundStyle(Theme.sec).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Имя или @участник", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
                    .focused($focused).onSubmit(save)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onChange(of: name) {
                        highlight = 0
                        if let p = picked, p.name != name { picked = nil }
                    }
                Rectangle().fill(Theme.ink).frame(height: 1)
                if let p = picked, let email = p.email {
                    Text(email).font(.system(size: 12)).foregroundStyle(Theme.sec)
                }
                if mentioning {
                    if candidates.isEmpty {
                        Text("Никого не нашлось — допишите имя без @").font(.system(size: 12)).foregroundStyle(Theme.sec)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { i, c in
                        Button { choose(c) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: c.name).scaleEffect(0.8).frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.system(size: 13))
                                    if let email = c.email {
                                        Text(email).font(.system(size: 11)).foregroundStyle(Theme.sec)
                                    }
                                }
                                Spacer()
                                Text(c.note).font(.system(size: 12)).foregroundStyle(Theme.sec).lineLimit(1)
                                    .frame(maxWidth: 140, alignment: .trailing)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(i == highlight ? Theme.hoverSoft : .clear))
                            .contentShape(Rectangle())
                            .hoverHighlight(radius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                } else if name.isEmpty, voice.refs.contains(where: { !$0.attendees.isEmpty }) {
                    Text("Наберите @, чтобы выбрать из участников встречи").font(.system(size: 12)).foregroundStyle(Theme.sec)
                }
                ForEach(suggestions) { p in
                    Button { name = p.name } label: {
                        HStack(spacing: 10) {
                            Avatar(name: p.name).scaleEffect(0.8).frame(width: 22, height: 22)
                            Text(p.name).font(.system(size: 13))
                            Spacer()
                            Text("добавить голос").font(.system(size: 12)).foregroundStyle(Theme.sec)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .hoverHighlight(radius: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Имя появится во всех встречах, где звучит этот голос: \(plural(voice.refs.count, ru: ("встреча", "встречи", "встреч"), en: ("meeting", "meetings"))).")
                .font(.system(size: 12)).foregroundStyle(Theme.sec)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LinkButton(String(localized: "Это я")) {
                    player.stop()
                    library.nameVoiceAsMe(voice)
                    close()
                }
                Spacer()
                Button("Esc", action: close).buttonStyle(Pill()).keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).buttonStyle(Pill(dark: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (mentioning && candidates.isEmpty))
            }
        }
        .taskPopover()
        .onAppear { focused = true }
    }

    private func move(_ d: Int) -> KeyPress.Result {
        guard mentioning, !candidates.isEmpty else { return .ignored }
        highlight = (highlight + d + candidates.count) % candidates.count
        return .handled
    }

    /// Выбор из списка «@»: имя встаёт в поле, почта запоминается. Сохранить — следующим Enter.
    private func choose(_ c: Candidate) {
        picked = c
        name = c.name
        focused = true
    }

    private func save() {
        if mentioning {
            let list = candidates
            if list.indices.contains(highlight) { choose(list[highlight]) }
            return
        }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        player.stop()
        library.nameVoice(voice, name: n, email: picked?.email)
        close()
    }
}

// MARK: - Карточка человека

private struct PersonCard: View {
    let library: LibraryModel
    let person: PeopleOverview.Known
    let player: SamplePlayer
    let back: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var role = ""
    @State private var notes = ""
    @State private var allMeetings = false
    @State private var sampleError: String?
    @State private var working = false
    @State private var confirmClear = false

    private var r: PeopleDirectory.Record { person.record }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Люди").font(.system(size: 13))
                    }
                    .foregroundStyle(Theme.sec)
                    .padding(.horizontal, 8).frame(height: 26)
                    .hoverHighlight(radius: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Menu {
                    if !r.voices.isEmpty { Button("Сбросить голос…") { confirmClear = true } }
                    if !person.isMe { Button("Удалить из списка", role: .destructive) { library.removePerson(r.id); back() } }
                } label: {
                    Text("•••").font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.hover))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 20)
                    fields.padding(.top, 28)
                    voice.padding(.top, 32)
                    meetings.padding(.top, 32)
                }
                .frame(width: Theme.column, alignment: .leading)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            name = r.name
            email = r.email ?? ""
            role = r.role ?? ""
            notes = r.notes ?? ""
        }
        .alert("Сбросить голос?", isPresented: $confirmClear) {
            Button("Отмена", role: .cancel) {}
            Button("Сбросить", role: .destructive) { player.stop(); library.clearVoice(r.id) }
        } message: {
            Text("Мунин забудет, как звучит этот человек, и перестанет узнавать его по голосу. Имена в прошлых встречах останутся.")
        }
    }

    private func close() {
        saveFields()
        rename()
        library.loadPeople()
        back()
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text(Avatar.initials(person.isMe ? "Я" : r.name))
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.sec)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.hover))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Имя", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 30, weight: .bold))
                    .onSubmit(rename)
                Rectangle().fill(Theme.line).frame(height: 1)
                Text(sinceText).font(.system(size: 13)).foregroundStyle(Theme.sec).padding(.top, 2)
            }
        }
    }

    private var sinceText: String {
        guard let last = person.meetings.first, let first = person.meetings.last else {
            return String(localized: "Пока ни одной встречи")
        }
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(UILanguage.locale)
        let n = plural(person.meetings.count, ru: ("встреча", "встречи", "встреч"), en: ("meeting", "meetings"))
        return n + " " + String(localized: "с \(first.date.formatted(f))") + " · "
            + String(localized: "последняя \(last.date.formatted(f))")
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 28) {
                field(String(localized: "Почта"), text: $email, prompt: String(localized: "Как в приглашениях календаря"),
                      hint: person.calendarMeetings > 0
                        ? String(localized: "По почте узнаётся в участниках календаря: \(plural(person.calendarMeetings, ru: ("встреча", "встречи", "встреч"), en: ("meeting", "meetings")))")
                        : nil)
                field(String(localized: "Роль"), text: $role, prompt: String(localized: "Например, аналитик, команда сплитов"), hint: nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Заметки").font(.system(size: 12)).foregroundStyle(Theme.sec)
                TextField("Что важно помнить об этом человеке", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...6)
                    .onSubmit(saveFields)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .onChange(of: email) { _, _ in saveFields() }
        .onChange(of: role) { _, _ in saveFields() }
        .onChange(of: notes) { _, _ in saveFields() }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.sec)
            TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 15))
            Rectangle().fill(Theme.line).frame(height: 1)
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.sec).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCap(String(localized: "Голос"))
            if let url = library.sampleURL(for: r) {
                HStack(spacing: 14) {
                    VoicePill(id: PeopleView.sampleId(r), large: true, player: player) { url }
                    VStack(alignment: .leading, spacing: 2) {
                        if let src = r.sampleSource { Text("Фрагмент из «\(src)»") }
                        Text("Голос узнаётся по \(plural(r.voices.count, ru: ("записи", "записям", "записям"), en: ("recording", "recordings")))")
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.sec)
                }
            } else if r.voices.isEmpty {
                Text("Голос появится, когда вы назовёте этого человека в транскрипте встречи или среди нераспознанных.")
                    .font(.system(size: 13)).foregroundStyle(Theme.sec)
            } else {
                Text("Слепка пока нет.").font(.system(size: 13)).foregroundStyle(Theme.sec)
            }
            if !r.voices.isEmpty {
                HStack(spacing: 16) {
                    LinkButton(working ? String(localized: "Вырезаю…") : String(localized: "Взять фрагмент из другой встречи")) {
                        guard !working else { return }
                        working = true
                        player.stop()
                        if let url = library.sampleURL(for: r) { player.forget(url) }
                        Task {
                            sampleError = await library.nextSample(for: person)
                            working = false
                        }
                    }
                    LinkButton(String(localized: "Это чужой голос")) { confirmClear = true }
                }
                if let sampleError { Text(sampleError).font(.system(size: 12)).foregroundStyle(Theme.red) }
            }
        }
    }

    private var meetings: some View {
        let list = allMeetings ? person.meetings : Array(person.meetings.prefix(8))
        return VStack(alignment: .leading, spacing: 2) {
            SectionCap(String(localized: "Встречи · \(person.meetings.count)")).padding(.bottom, 4)
            ForEach(list) { m in
                Button { saveFields(); library.openMeeting(m.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(m.date.formatted(.dateTime.day().month(.abbreviated).locale(UILanguage.locale)))
                            .font(.system(size: 13)).foregroundStyle(Theme.sec).frame(width: 84, alignment: .leading)
                        Text(m.title).font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Text(plural(m.participants, ru: ("участник", "участника", "участников"), en: ("participant", "participants")))
                            .font(.system(size: 12)).foregroundStyle(Theme.sec)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .hoverHighlight()
                    .padding(.horizontal, -10)
                }
                .buttonStyle(.plain)
            }
            if person.meetings.count > list.count {
                LinkButton(String(localized: "Все \(person.meetings.count)")) { allMeetings = true }.padding(.top, 4)
            }
        }
    }

    private func rename() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != r.name else { name = r.name; return }
        library.renamePerson(r.id, to: n)
    }

    private func saveFields() {
        let e = email.trimmingCharacters(in: .whitespaces), ro = role.trimmingCharacters(in: .whitespaces)
        let no = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e != (r.email ?? "") || ro != (r.role ?? "") || no != (r.notes ?? "") else { return }
        library.updatePerson(r.id, reload: false) {
            $0.email = e.isEmpty ? nil : e
            $0.role = ro.isEmpty ? nil : ro
            $0.notes = no.isEmpty ? nil : no
        }
    }
}
