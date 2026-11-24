import AppKit
import MnemosyneCore
import Observation
import SwiftUI

/// Окно названия после «Остановить». Открывается сразу, запись сохраняется параллельно.
/// Enter — сохранить, Esc — оставить как есть (название из события или «Без названия»).
@MainActor
@Observable
final class TitleModel {
    var title: String
    var event: CalendarEventInfo?
    let startedAt: Date
    let endedAt: Date
    let mode: RecordingMode

    private(set) var saving = true
    private(set) var error: String?
    @ObservationIgnored private let initialTitle: String
    @ObservationIgnored private let initialEvent: CalendarEventInfo?
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored let alternatives: () -> [CalendarEventInfo]
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var pendingSave = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored var onFinish: (() -> Void)?

    init(title: String, event: CalendarEventInfo?, startedAt: Date, endedAt: Date, mode: RecordingMode,
         store: MeetingStore, alternatives: @escaping () -> [CalendarEventInfo]) {
        self.title = title
        self.event = event
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.store = store
        self.alternatives = alternatives
        initialTitle = title
        initialEvent = event
    }

    /// Название по умолчанию выделено целиком — можно сразу печатать.
    var selectAllOnOpen: Bool { event == nil }

    var durationText: String { UIFormat.duration(endedAt.timeIntervalSince(startedAt)) }

    func choose(_ newEvent: CalendarEventInfo?) {
        // Если название не трогали, оно следует за событием.
        let autoTitle = event?.title.nilIfEmpty ?? MeetingStore.defaultTitle
        if title == autoTitle { title = newEvent?.title.nilIfEmpty ?? MeetingStore.defaultTitle }
        event = newEvent
    }

    func saved(folder: URL?, error: String?) {
        self.folder = folder
        self.error = folder == nil ? (error ?? String(localized: "Запись не сохранилась")) : nil
        saving = false
        if let message = self.error, finished {
            Log.app.error("recording save failed after title window closed: \(message, privacy: .public)")
        }
        if pendingSave { apply() }
    }

    /// Если запись ещё сохраняется (CAF → m4a идёт долго на длинных встречах), окно
    /// закрывается сразу, а название и событие применяются, когда файл будет готов.
    func save() {
        pendingSave = true
        if saving { finish() } else { apply() }
    }

    func cancel() { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?()
    }

    private func apply() {
        guard var folder else { finish(); return }
        do {
            if event?.id != initialEvent?.id {
                folder = try store.rebind(folder, to: event)
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let auto = event?.title.nilIfEmpty ?? MeetingStore.defaultTitle
            if trimmed != initialTitle || trimmed != auto {
                // Ручное название: перепривязка события его больше не поменяет.
                folder = try store.rename(folder, to: trimmed, byUser: trimmed != auto)
            }
        } catch {
            pendingSave = false
            // Окно уже закрыто — ошибку некому показать, пишем в лог; встреча остаётся под прежним названием.
            if finished {
                Log.app.error("rename after save failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.error = String(localized: "Не удалось переименовать: \(error.localizedDescription)")
            return
        }
        finish()
    }
}

final class TitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TitleWindowController {
    private let panel: TitlePanel
    var onClose: (() -> Void)?

    init(model: TitleModel) {
        panel = TitlePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                           styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // NSPanel по умолчанию прячется, когда приложение неактивно. macOS может не
        // дать активироваться приложению из строки меню, а окно должно быть видно.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSHostingController с preferredContentSize сам подгоняет размер окна под SwiftUI.
        let host = NSHostingController(rootView: TitleView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        model.onFinish = { [weak self] in self?.close() }
    }

    func show() {
        if let view = panel.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0, size.height > 0 { panel.setContentSize(size) }
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY + f.height * 0.12))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
        onClose?()
    }
}

struct TitleView: View {
    @Bindable var model: TitleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Caption(model.saving ? String(localized: "Сохраняем запись · \(model.durationText)") : String(localized: "Запись сохранена · \(model.durationText)"))

            VStack(spacing: 6) {
                TitleField(text: $model.title, selectAll: model.selectAllOnOpen,
                           onSubmit: model.save, onCancel: model.cancel)
                    .frame(height: 28)
                Rectangle().fill(Color.primary).frame(height: 1)
            }

            eventLine

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.red)
            }

            HStack(spacing: 8) {
                Caption(model.event == nil ? String(localized: "Название выделено — печатайте") : String(localized: "Enter — сохранить"))
                Spacer()
                Button("Esc", action: model.cancel).buttonStyle(SmallPill(prominent: false))
                Button("Сохранить", action: model.save).buttonStyle(SmallPill(prominent: true))
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    @ViewBuilder private var eventLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let event = model.event {
                    Caption(String(localized: "Из календаря: \(event.title), \(Self.time(event.start)) ·"))
                } else {
                    Caption(String(localized: "Не привязано к событию ·"))
                }
                EventMenu(label: model.event == nil ? String(localized: "выбрать") : String(localized: "изменить"),
                          events: model.alternatives(), selected: model.event?.id,
                          choose: model.choose)
            }
            if let people = Self.people(model.event) {
                Caption(people)
            } else if model.event == nil {
                Caption(model.mode.uiTitle)
            }
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(UILanguage.locale))
    }

    /// «Мария Смирнова, Олег Петров и ещё 4»
    static func people(_ event: CalendarEventInfo?) -> String? {
        guard let others = event?.others, !others.isEmpty else { return nil }
        let names = others.prefix(2).map(\.displayName).joined(separator: ", ")
        return others.count > 2 ? String(localized: "\(names) и ещё \(others.count - 2)") : names
    }
}

/// Меню выбора события: пересекающиеся с записью и «Без события».
struct EventMenu: View {
    let label: String
    let events: [CalendarEventInfo]
    let selected: String?
    let choose: (CalendarEventInfo?) -> Void

    var body: some View {
        Menu {
            ForEach(events) { e in
                Button {
                    choose(e)
                } label: {
                    Text("\(e.id == selected ? "✓ " : "")\(e.title) · \(TitleView.time(e.start))–\(TitleView.time(e.end))")
                }
            }
            if !events.isEmpty { Divider() }
            Button("Без события") { choose(nil) }
        } label: {
            Text(label).font(.system(size: 12)).underline().foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SmallPill: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color(nsColor: .textBackgroundColor) : Color.primary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(prominent ? Color.primary : Color.primary.opacity(0.06)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// NSTextField: нужен, чтобы выделить текст при открытии и поймать Enter и Esc.
struct TitleField: NSViewRepresentable {
    @Binding var text: String
    let selectAll: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() else { return }
            if selectAll { editor.selectAll(nil) } else { editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        init(_ parent: TitleField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
