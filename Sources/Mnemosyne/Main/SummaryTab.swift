import AppKit
import MnemosyneCore
import SwiftUI

/// «Саммари»: документ в колонке — коротко, решения, задачи, темы, инсайты, участники.
struct SummaryTab: View {
    let library: LibraryModel
    let detail: MeetingDetail
    var copied = false
    var copy: () -> Void = {}

    var body: some View {
        if let styled = detail.styledSummary, detail.analysis != nil {
            VStack(alignment: .leading, spacing: 36) {
                StyleBar(library: library, detail: detail, copied: copied, copy: copy)
                    .padding(.bottom, -12)
                MarkdownText(styled)
                ParticipantsSection(library: library, detail: detail)
            }
        } else if let a = detail.analysis {
            VStack(alignment: .leading, spacing: 36) {
                StyleBar(library: library, detail: detail, copied: copied, copy: copy)
                    .padding(.bottom, -12)
                if !a.tldr.isEmpty {
                    section(String(localized: "Коротко")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(a.tldr.enumerated()), id: \.offset) { _, t in
                                ListRow(ts: nil, jump: nil) { Text("—").foregroundStyle(Theme.sec) } content: { Text(t) }
                            }
                        }
                    }
                }
                if !a.decisions.isEmpty {
                    section(String(localized: "Решения")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(a.decisions.enumerated()), id: \.offset) { _, d in
                                ListRow(ts: d.ts, jump: library.jump) { Text("—").foregroundStyle(Theme.sec) } content: {
                                    let owner = detail.names[d.owner] ?? d.owner
                                    (Text(d.text) + Text(owner.isEmpty ? "" : " — \(owner)").foregroundStyle(Theme.sec))
                                }
                            }
                        }
                    }
                }
                if !a.actionItems.isEmpty {
                    section(String(localized: "Задачи")) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(a.actionItems.enumerated()), id: \.offset) { _, i in
                                ListRow(ts: i.ts, jump: library.jump) {
                                    Circle().strokeBorder(Theme.sec, lineWidth: 1.5).frame(width: 16, height: 16).offset(y: 3)
                                } content: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i.what)
                                        Text(taskMeta(i)).font(.system(size: 13)).foregroundStyle(Theme.sec)
                                    }
                                }
                            }
                        }
                    }
                }
                if !a.summaryByTopics.isEmpty {
                    section(String(localized: "По темам")) {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(Array(a.summaryByTopics.enumerated()), id: \.offset) { _, t in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(t.topic).font(.system(size: 17, weight: .semibold))
                                        Spacer()
                                        Timestamp(t.start) { library.jump(to: t.start) }
                                    }
                                    MarkdownText(t.markdown)
                                }
                            }
                        }
                    }
                }
                if !a.insights.isEmpty {
                    section(String(localized: "Инсайты")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(a.insights.enumerated()), id: \.offset) { _, i in
                                ListRow(ts: i.ts, jump: library.jump) { Text("—").foregroundStyle(Theme.sec) } content: { Text(i.text) }
                            }
                        }
                    }
                }
                ParticipantsSection(library: library, detail: detail)
            }
        } else {
            VStack(alignment: .leading, spacing: 36) {
                AnalysisStatus(library: library, detail: detail)
                ParticipantsSection(library: library, detail: detail)
            }
        }
    }

    private func taskMeta(_ i: Analysis.ActionItem) -> String {
        let names = detail.names
        let who = i.who.isEmpty ? String(localized: "исполнитель не назван") : (names[i.who] ?? i.who)
        let due: String
        if let date = Self.isoDate(i.due) {
            due = String(localized: "до \(date.formatted(.dateTime.day().month(.abbreviated).locale(UILanguage.locale)))")
        } else { due = i.dueSaid.isEmpty ? String(localized: "срок не назван") : i.dueSaid }
        return "\(who) · \(due)"
    }

    static func isoDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCap(title)
            content()
        }
    }
}

/// Markdown из ответа модели: абзацы и списки, без сложной вёрстки.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, line in
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("#") {
                    // Заголовок раздела из пересборки в другом стиле.
                    Text(Self.inline(s.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 14)
                } else if s.hasPrefix("- ") || s.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("—").foregroundStyle(Theme.sec)
                        Text(Self.inline(String(s.dropFirst(2))))
                    }
                } else {
                    Text(Self.inline(s))
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Что с анализом, если `analysis.json` ещё нет.
struct AnalysisStatus: View {
    let library: LibraryModel
    let detail: MeetingDetail

    var body: some View {
        let m = detail.meta
        let analysis = library.controller.analysis
        if let stage = ProcessingStage.of(m, controller: library.controller) {
            ProcessingSteps(library: library, meta: m, stage: stage)
            Text("Пока идёт обработка, можно писать во вкладке «Мои заметки».")
                .font(.system(size: 13)).foregroundStyle(Theme.sec).padding(.top, -22)
        } else {
            status(m, analysis: analysis)
        }
    }

    @ViewBuilder private func status(_ m: MeetingMeta, analysis: AnalysisQueue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCap(String(localized: "Саммари"))
            Group {
                if m.status.needsProcessing {
                    Text("Сначала распознаём запись. Саммари появится следом.")
                } else if analysis.running == m.id, analysis.runningStep != "public" {
                    Text("Claude анализирует встречу…")
                } else if m.steps?["analyze"]?.status == .queuedLimit, let until = analysis.waitingUntil {
                    Text("В очереди: лимит подписки, повтор в \(AnalysisQueue.time(until)). Транскрипт уже готов.")
                } else if analysis.isQueued(m.id) {
                    Text("Ждёт анализа.")
                } else if m.skipAnalysis == true {
                    Text("Анализ отключён для этой встречи — есть только транскрипт.")
                } else if let error = m.steps?["analyze"]?.error, m.steps?["analyze"]?.status == .failed {
                    Text("Анализ не удался: \(error)").foregroundStyle(Theme.red)
                } else {
                    Text("Саммари ещё нет.")
                }
            }
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)

            if detail.transcript != nil, !analysis.isQueued(m.id), analysis.running != m.id, !m.status.needsProcessing {
                HStack(spacing: 8) {
                    if m.steps?["analyze"]?.status == .queuedLimit {
                        Button("Повторить сейчас") { analysis.retryNow() }.buttonStyle(Pill(dark: true))
                    } else {
                        Button("Проанализировать") {
                            _ = try? library.store.update(id: m.id) { $0.skipAnalysis = false }
                            analysis.reanalyze(m.id)
                        }
                        .buttonStyle(Pill(dark: true))
                    }
                }
            } else if m.steps?["analyze"]?.status == .queuedLimit {
                Button("Повторить сейчас") { analysis.retryNow() }.buttonStyle(Pill(dark: true))
            }
        }
    }
}

/// «Участники»: кто был, откуда известно имя, «Указать, кто это» для безымянных и «Добавить».
struct ParticipantsSection: View {
    let library: LibraryModel
    let detail: MeetingDetail
    @State private var askingName: (speaker: String?, title: String)?
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionCap(String(localized: "Участники"))
                Menu {
                    ForEach(invitedNotListed, id: \.self) { name in
                        Button(name) { add(name) }
                    }
                    if !invitedNotListed.isEmpty { Divider() }
                    Button("Новый человек…") { nameDraft = ""; askingName = (nil, String(localized: "Кого добавить")) }
                } label: {
                    Text("Добавить").font(.system(size: 13)).underline().foregroundStyle(Theme.sec)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.key) { row in
                    HStack(spacing: 10) {
                        Avatar(name: row.generic ? "?" : row.name)
                        Text(row.name).foregroundStyle(row.generic ? Theme.sec : Theme.ink)
                        Text(row.source).font(.system(size: 13)).foregroundStyle(Theme.sec)
                        if let speaker = row.speaker, let suggested = row.suggested {
                            Text("· похоже на \(suggested)?").font(.system(size: 13)).foregroundStyle(Theme.sec)
                            LinkButton(String(localized: "Да")) { rename(speaker, to: suggested, email: row.suggestedEmail) }
                        }
                        if let speaker = row.speaker, row.speaker != "me" {
                            Menu {
                                ForEach(invitedNames, id: \.self) { n in Button(n) { rename(speaker, to: n) } }
                                if !invitedNames.isEmpty { Divider() }
                                Button("Другое имя…") { nameDraft = row.generic ? "" : row.name; askingName = (speaker, String(localized: "Кто это — \(row.name)?")) }
                            } label: {
                                Text(row.generic ? "Указать, кто это" : "Изменить").font(.system(size: 13)).underline().foregroundStyle(Theme.sec)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    .font(.system(size: 15))
                }
            }
        }
        .sheet(isPresented: Binding(get: { askingName != nil }, set: { if !$0 { askingName = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text(askingName?.title ?? "").font(.system(size: 15, weight: .semibold))
                TextField("Имя и фамилия", text: $nameDraft).textFieldStyle(.roundedBorder).frame(width: 320)
                    .onSubmit(submitName)
                HStack {
                    Spacer()
                    Button("Отмена") { askingName = nil }.keyboardShortcut(.cancelAction)
                    Button("Сохранить", action: submitName).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private struct Row {
        var key: String; var name: String; var source: String; var speaker: String?; var generic: Bool
        var suggested: String? = nil; var suggestedEmail: String? = nil
    }

    /// Спикеры транскрипта + участники события, которые не говорили.
    private var rows: [Row] {
        var result: [Row] = []
        var seen = Set<String>()
        for s in detail.transcript?.speakers ?? [] {
            let source: String = switch s.nameSource {
            case "me": String(localized: "это вы")
            case "manual": String(localized: "указано вручную")
            case "calendar-1on1": String(localized: "из календаря")
            case "voice": String(localized: "по голосу")
            default: String(localized: "говорил \(UIFormat.duration(s.talkSeconds))")
            }
            result.append(Row(key: s.id, name: s.label, source: source, speaker: s.id, generic: s.nameSource == "generic",
                              suggested: s.nameSource == "generic" ? s.suggestedName : nil, suggestedEmail: s.suggestedEmail))
            seen.insert(s.label.lowercased())
        }
        for p in detail.meta.participants ?? [] where !p.isMe && !seen.contains(p.displayName.lowercased()) {
            result.append(Row(key: "p:\(p.displayName)", name: p.displayName, source: String(localized: "приглашён, без реплик"), speaker: nil, generic: false))
        }
        return result
    }

    private var invitedNames: [String] {
        (detail.meta.event?.participants ?? detail.meta.participants ?? []).filter { !$0.isMe }.map(\.displayName)
    }

    private var invitedNotListed: [String] {
        let listed = Set(rows.map { $0.name.lowercased() })
        return (detail.meta.event?.participants ?? []).filter { !$0.isMe }.map(\.displayName).filter { !listed.contains($0.lowercased()) }
    }

    private func submitName() {
        guard let ask = askingName else { return }
        let name = nameDraft
        askingName = nil
        if let speaker = ask.speaker { rename(speaker, to: name) } else { add(name) }
    }

    private func rename(_ speaker: String, to name: String, email known: String? = nil) {
        let email = known ?? (detail.meta.participants ?? []).first { $0.displayName == name }?.email
        try? library.editing.renameSpeaker(id: detail.meta.id, speaker: speaker, to: name, email: email)
        library.refresh()
    }

    private func add(_ name: String) {
        let email = (detail.meta.event?.participants ?? []).first { $0.displayName == name }?.email
        try? library.editing.addParticipant(id: detail.meta.id, name: name, email: email)
        library.refresh()
    }
}

