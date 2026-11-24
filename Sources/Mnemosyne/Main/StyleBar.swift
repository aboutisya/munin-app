import MnemosyneCore
import SwiftUI

/// Над саммари: текущий стиль, «Изменить стиль», готовые версии и копирование.
struct StyleBar: View {
    let library: LibraryModel
    let detail: MeetingDetail
    var copied: Bool
    var copy: () -> Void
    @State private var choosing = false

    private var directory: StyleDirectory { StyleDirectory.load(root: library.store.root) }
    private var meta: MeetingMeta { detail.meta }
    private var activeId: String { detail.styledSummary == nil ? SummaryStyle.businessId : (meta.summaryStyle ?? SummaryStyle.businessId) }
    private var versions: [SummaryVersion] { meta.summaryVersions ?? [] }

    var body: some View {
        let analysis = library.controller.analysis
        let dir = directory
        let running = analysis.restyling(meta.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                (Text("Стиль: ").foregroundStyle(Theme.sec) + Text((dir.style(activeId) ?? SummaryStyle.presets[0]).uiName).fontWeight(.semibold))
                    .font(.system(size: 13))
                Button("Изменить стиль") { choosing = true }
                    .buttonStyle(Pill())
                    .disabled(detail.analysis == nil || running != nil)
                if !versions.isEmpty {
                    Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 2)
                    versionChip(id: SummaryStyle.businessId, name: String(localized: "Деловой"))
                    ForEach(versions, id: \.style) { v in versionChip(id: v.style, name: dir.style(v.style)?.uiName ?? v.name) }
                }
                Spacer()
                Button(copied ? String(localized: "Скопировано") : String(localized: "Скопировать саммари"), action: copy)
                    .buttonStyle(Pill(dark: true))
                    .disabled(detail.transcript == nil)
            }

            if let running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Пересобираю саммари в стиле «\(running.uiName)». Обычно это около минуты — можно перейти к другой встрече.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13))
                .banner()
            } else if let error = analysis.styleErrors[meta.id] {
                Text("Не удалось пересобрать: \(error)").font(.system(size: 13)).foregroundStyle(Theme.red)
            }
        }
        .sheet(isPresented: $choosing) {
            StyleDialog(library: library, detail: detail, activeId: activeId, directory: dir) { choosing = false }
        }
    }

    private func versionChip(id: String, name: String) -> some View {
        let on = id == activeId
        return Button {
            try? library.store.setActiveStyle(id, meeting: meta.id)
            library.refresh()
        } label: {
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.ink : Theme.sec)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(on ? Theme.hover : .clear))
                .overlay(Capsule().strokeBorder(Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Окно «Стиль саммари»: выбрать стиль и подтвердить. Новый стиль — отдельный вызов Claude,
/// поэтому показываем, сколько примерно токенов он съест; готовую версию показываем без вызова.
struct StyleDialog: View {
    let library: LibraryModel
    let detail: MeetingDetail
    let activeId: String
    let directory: StyleDirectory
    let close: () -> Void
    @State private var choice: String = ""

    private var meta: MeetingMeta { detail.meta }
    private func isReady(_ id: String) -> Bool {
        id == SummaryStyle.businessId || (meta.summaryVersions ?? []).contains { $0.style == id }
    }

    var body: some View {
        let selected = choice.isEmpty ? defaultChoice : choice
        let same = selected == activeId
        let free = !same && isReady(selected)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Caption(meta.durationSeconds.map { String(localized: "Стиль саммари · \(UIFormat.duration($0))") } ?? String(localized: "Стиль саммари"))
                Text(meta.title).font(.system(size: 20, weight: .semibold)).lineLimit(2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SummaryStyle.presets) { row($0, selected: selected) }
                    if !directory.styles.isEmpty {
                        Caption(String(localized: "Мои стили")).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                        ForEach(directory.styles) { row($0, selected: selected) }
                    }
                }
                .padding(.horizontal, -10)
            }
            .frame(maxHeight: 380)
            .scrollIndicators(.never)

            Group {
                if same {
                    Text("Этот стиль уже показан.").foregroundStyle(Theme.sec)
                } else if free {
                    Text("Эта версия уже собрана — переключимся сразу, без вызова Claude.")
                } else {
                    cost
                }
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))

            HStack(spacing: 8) {
                Button {
                    close()
                    library.controller.showSettings(newStyle: true)
                } label: {
                    Text("Свой стиль — в настройках").font(.system(size: 12)).underline().foregroundStyle(Theme.sec)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Отмена", action: close)
                    .buttonStyle(SmallPill(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(same ? String(localized: "Уже выбран") : free ? String(localized: "Показать") : String(localized: "Пересобрать")) {
                    confirm(selected, free: free)
                }
                .buttonStyle(SmallPill(prominent: !same))
                .disabled(same)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.win)
        .foregroundStyle(Theme.ink)
    }

    /// По умолчанию отмечаем первый стиль, отличный от текущего: окно открыли, чтобы сменить.
    private var defaultChoice: String {
        activeId == SummaryStyle.businessId ? "short" : SummaryStyle.businessId
    }

    @ViewBuilder private var cost: some View {
        let est = StyleCost.estimate(meta: meta, transcript: detail.transcript)
        let amount = StyleCost.format(est.tokens)
        if est.measured {
            Text("**Отдельный вызов Claude: ≈ \(amount) токенов** из лимита подписки — почти как исходный разбор этой встречи. Транскрипт и задачи не меняются, текущая версия сохранится.")
        } else {
            Text("**Отдельный вызов Claude: примерно \(amount) токенов** из лимита подписки (оценка по длине транскрипта). Транскрипт и задачи не меняются, текущая версия сохранится.")
        }
    }

    private func row(_ style: SummaryStyle, selected: String) -> some View {
        let on = style.id == selected
        return Button { choice = style.id } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.uiName).font(.system(size: 14))
                    Text(style.uiHint).font(.system(size: 12)).foregroundStyle(Theme.sec).lineLimit(1)
                }
                Spacer()
                if style.id == activeId { badge(String(localized: "сейчас"), on: on) }
                else if isReady(style.id) { badge(String(localized: "уже собран"), on: on) }
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(on ? 1 : 0).frame(width: 14)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(selected: on)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, on: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.sec)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(on ? Theme.win : Theme.hover))
    }

    private func confirm(_ id: String, free: Bool) {
        if free {
            try? library.store.setActiveStyle(id, meeting: meta.id)
            library.refresh()
        } else if let style = directory.style(id) {
            library.controller.analysis.restyle(meta.id, style: style)
        }
        close()
    }
}

/// Сколько токенов съест пересборка. Берём реальный расход первого разбора встречи
/// (вход почти тот же: транскрипт + скилл, плюс сам разбор), иначе — по длине транскрипта.
enum StyleCost {
    static func estimate(meta: MeetingMeta, transcript: Transcript?) -> (tokens: Int, measured: Bool) {
        if let a = meta.usage?.last(where: { $0.step == "analyze" }) {
            // Вход = вход разбора + сам разбор (~ его выход); выход — короткий текст саммари.
            return (a.inputTokens + a.outputTokens + 2_000, true)
        }
        let chars = transcript?.utterances.reduce(0) { $0 + $1.text.count } ?? 0
        // ~3 символа на токен для русского текста, плюс скилл, разбор и ответ.
        return (chars / 3 + 15_000, false)
    }

    /// «58 тыс.» / «58K»
    static func format(_ tokens: Int) -> String {
        let k = max(1, Int((Double(tokens) / 1000).rounded()))
        return UILanguage.isEnglish ? "\(k)K" : "\(k) тыс."
    }
}

private extension View {
    /// Плашка хода пересборки — как «Событие изменилось» в шапке.
    func banner() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
    }
}
