import AppKit
import MnemosyneCore
import MnemosynePipeline
import SwiftUI

/// «Публичное»: текст для Mattermost с предпросмотром и правкой, копирование текста и диаграмм по отдельности (§8).
struct PublicTab: View {
    let library: LibraryModel
    let detail: MeetingDetail
    @Binding var copied: Bool
    let copy: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var copiedDiagram: Int?

    var body: some View {
        if let text = detail.publicSummary {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text(library.controller.settings.ruTextActive
                         ? String(localized: "Для \(messenger.title), вычитано через /ru-text. Без тональности и фидбека.")
                         : String(localized: "Для \(messenger.title). Без тональности и фидбека."))
                        .font(.system(size: 13)).foregroundStyle(Theme.sec)
                    Spacer()
                    LinkButton(editing ? String(localized: "Готово") : String(localized: "Редактировать")) { editing ? save() : startEditing(text) }
                    Button(copied ? "Скопировано" : "Скопировать текст") { if editing { save() }; copy() }
                        .buttonStyle(Pill(dark: true))
                }
                notes(text)
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .frame(minHeight: 360)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                } else {
                    MattermostPreview(text: text, messenger: messenger)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                }
                diagrams
                HStack(spacing: 6) {
                    status.font(.system(size: 13)).foregroundStyle(Theme.sec)
                    Spacer()
                    if !busy { LinkButton(String(localized: "Сформировать заново")) { regenerate() }.help("Один вызов Claude. Ручные правки заменятся.") }
                }
            }
            .onChange(of: detail.meta.id) { _, _ in editing = false }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(String(localized: "Публичное саммари"))
                status.font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                if detail.analysis != nil, !busy, detail.meta.steps?["public"]?.status != .queuedLimit {
                    Button("Сформировать") { regenerate() }.buttonStyle(Pill(dark: true))
                } else if detail.meta.steps?["public"]?.status == .queuedLimit {
                    Button("Повторить сейчас") { library.controller.analysis.retryNow() }.buttonStyle(Pill(dark: true))
                }
            }
        }
    }

    private var messenger: PublicInput.Messenger { library.controller.settings.messenger }

    private var busy: Bool {
        let q = library.controller.analysis
        return q.running == detail.meta.id || q.isQueued(detail.meta.id)
    }

    @ViewBuilder private var status: some View {
        let q = library.controller.analysis
        let step = detail.meta.steps?["public"]
        if q.running == detail.meta.id {
            Text(q.runningStep == "public" ? "Claude пишет публичное саммари…" : "Сначала анализ встречи, потом публичное саммари.")
        } else if step?.status == .queuedLimit, let until = q.waitingUntil {
            Text("В очереди: лимит подписки, повтор в \(AnalysisQueue.time(until)).")
        } else if q.isQueued(detail.meta.id) {
            Text("Ждёт очереди.")
        } else if step?.status == .failed, let e = step?.error {
            Text("Не удалось: \(e)").foregroundStyle(Theme.red)
        } else if detail.publicSummary != nil {
            Text(step?.finishedAt.map { String(localized: "Сформировано \(UIFormat.day($0))") } ?? "")
        } else if detail.meta.skipAnalysis == true {
            Text("Анализ отключён для этой встречи.")
        } else if detail.analysis == nil {
            Text("Появится после анализа: короткий текст для \(messenger.title) без тональности и фидбека.")
                .foregroundStyle(Theme.sec)
        } else {
            Text("Публичного саммари ещё нет. Это один вызов Claude: текст для \(messenger.title) без тональности и фидбека.")
                .foregroundStyle(Theme.sec)
        }
    }

    @ViewBuilder private func notes(_ text: String) -> some View {
        let generated = detail.publicGenerated
        if let generated, generated != text {
            HStack(spacing: 10) {
                Text(detail.meta.steps?["public"]?.error != nil ? "Модель сделала новую версию, но здесь ваши правки." : "Здесь ваши правки.")
                    .font(.system(size: 13))
                LinkButton(String(localized: "Вернуть версию модели")) { write(generated) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
        }
    }

    @ViewBuilder private var diagrams: some View {
        let list = detail.analysis?.diagrams ?? []
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(String(localized: "Схемы — вставляйте в Mattermost отдельно от текста"))
                ForEach(Array(list.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 14) {
                        if let url = DiagramRenderer.pngURL(folder: detail.folder, index: i, type: d.type), let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 120, height: 64)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                            Text(d.title).font(.system(size: 15))
                            Spacer()
                            Button(copiedDiagram == i ? "Скопировано" : "Скопировать диаграмму") {
                                if DiagramRenderer.copyToPasteboard(url) {
                                    copiedDiagram = i
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copiedDiagram == i { copiedDiagram = nil } }
                                }
                            }
                            .buttonStyle(Pill())
                        } else {
                            Text(d.title).font(.system(size: 15))
                            Spacer()
                            Text("не отрисовалась, в публичное не вошла").font(.system(size: 13)).foregroundStyle(Theme.sec)
                        }
                    }
                }
            }
        }
    }

    private func startEditing(_ text: String) {
        draft = text
        editing = true
    }

    private func save() {
        editing = false
        if draft != detail.publicSummary { write(draft) }
    }

    private func write(_ text: String) {
        guard let folder = library.store.locate(id: detail.meta.id) else { return }
        try? text.write(to: folder.appending(path: Publisher.publicFile), atomically: true, encoding: .utf8)
        library.refresh()
    }

    private func regenerate() {
        editing = false
        _ = try? library.store.update(id: detail.meta.id) { $0.skipAnalysis = false }
        library.controller.analysis.republish(detail.meta.id)
        library.refresh()
    }
}

/// Предпросмотр того, как мессенджер покажет текст: `####`, жирные подзаголовки, списки, таблицы.
struct MattermostPreview: View {
    let text: String
    var messenger: PublicInput.Messenger = .mattermost

    enum Block {
        case heading(String), paragraph(String), bullet(String), table([[String]])
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var table: [[String]] = []
        func flush() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for raw in text.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") {
                let cells = s.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }) { table.append(cells) }
                continue
            }
            flush()
            if s.isEmpty { continue }
            if s.hasPrefix("#") { out.append(.heading(s.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))) }
            else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ") || s.hasPrefix("— ") { out.append(.bullet(String(s.dropFirst(2)))) }
            else { out.append(.paragraph(s)) }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(Self.normalized(text, messenger)).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let s): Text(MarkdownText.inline(s)).font(.system(size: 17, weight: .semibold)).padding(.bottom, 2)
                case .paragraph(let s): Text(MarkdownText.inline(s)).fixedSize(horizontal: false, vertical: true)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.sec)
                        Text(MarkdownText.inline(s)).fixedSize(horizontal: false, vertical: true)
                    }
                case .table(let rows): table(rows)
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(3)
        .textSelection(.enabled)
    }

    /// В Slack жирный — одной звёздочкой; для предпросмотра приводим к Markdown.
    static func normalized(_ text: String, _ m: PublicInput.Messenger) -> String {
        guard m == .slack else { return text }
        return text.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, with: "**$1**", options: .regularExpression)
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(MarkdownText.inline(c < row.count ? row[c] : ""))
                            .font(.system(size: 14, weight: r == 0 ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(r == 0 ? Theme.hover : .clear)
                            .border(Theme.line, width: 0.5)
                    }
                }
            }
        }
    }
}
