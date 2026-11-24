import MnemosyneCore
import SwiftUI

/// Над саммари: выбор стиля, версии и копирование. Стиль без готовой версии
/// пересобирается отдельным вызовом Claude — сначала спрашиваем.
struct StyleBar: View {
    let library: LibraryModel
    let detail: MeetingDetail
    var copied: Bool
    var copy: () -> Void
    @State private var pending: SummaryStyle?

    private var directory: StyleDirectory { StyleDirectory.load(root: library.store.root) }
    private var meta: MeetingMeta { detail.meta }
    private var activeId: String { detail.styledSummary == nil ? SummaryStyle.businessId : (meta.summaryStyle ?? SummaryStyle.businessId) }
    private var versions: [SummaryVersion] { meta.summaryVersions ?? [] }

    var body: some View {
        let analysis = library.controller.analysis
        let dir = directory
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                styleMenu(dir)
                if !versions.isEmpty {
                    Text("Версии:").font(.system(size: 12)).foregroundStyle(Theme.sec).padding(.leading, 4)
                    versionChip(id: SummaryStyle.businessId, name: String(localized: "Деловой"))
                    ForEach(versions, id: \.style) { v in versionChip(id: v.style, name: dir.style(v.style)?.uiName ?? v.name) }
                }
                Spacer()
                Button(copied ? "Скопировано" : "Скопировать саммари", action: copy)
                    .buttonStyle(Pill(dark: true))
                    .disabled(detail.transcript == nil)
            }

            if let running = analysis.restyling(meta.id) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Пересобираю саммари в стиле «\(running.uiName)». Обычно это около минуты.")
                }
                .font(.system(size: 13))
                .banner()
            } else if let style = pending {
                HStack(spacing: 12) {
                    Text("Пересобрать саммари в стиле «\(style.uiName)»? Транскрипт и задачи не изменятся, текущая версия сохранится.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Отмена") { pending = nil }
                    Button("Пересобрать") {
                        analysis.restyle(meta.id, style: style)
                        pending = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .font(.system(size: 13))
                .banner()
            } else if let error = analysis.styleErrors[meta.id] {
                Text("Не удалось пересобрать: \(error)").font(.system(size: 13)).foregroundStyle(Theme.red)
            }
        }
    }

    private func styleMenu(_ dir: StyleDirectory) -> some View {
        let current = dir.style(activeId) ?? SummaryStyle.presets[0]
        return Menu {
            Section("Встроенные") {
                ForEach(SummaryStyle.presets) { item($0) }
            }
            if !dir.styles.isEmpty {
                Section("Мои стили") {
                    ForEach(dir.styles) { item($0) }
                }
            }
            Divider()
            Button("Свой стиль…") { library.controller.showSettings(newStyle: true) }
        } label: {
            HStack(spacing: 5) {
                Text("Стиль:").foregroundStyle(Theme.sec)
                Text(current.uiName).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.sec)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 28)
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(detail.analysis == nil)
    }

    private func item(_ style: SummaryStyle) -> some View {
        Button {
            choose(style)
        } label: {
            if style.id == activeId { Label(style.uiName, systemImage: "checkmark") } else { Text(style.uiName) }
            Text(style.uiHint)
        }
    }

    private func versionChip(id: String, name: String) -> some View {
        let on = id == activeId
        return Button { choose(id: id) } label: {
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.ink : Theme.sec)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(on ? Theme.hover : .clear))
                .overlay(Capsule().strokeBorder(Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ style: SummaryStyle) {
        if style.isBusiness || versions.contains(where: { $0.style == style.id }) {
            choose(id: style.id)
        } else {
            pending = style
        }
    }

    private func choose(id: String) {
        pending = nil
        try? library.store.setActiveStyle(id, meeting: meta.id)
        library.refresh()
    }
}

private extension View {
    /// Голубая плашка с вопросом или ходом пересборки.
    func banner() -> some View {
        padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.18)))
    }
}
