import AppKit
import MnemosyneCore

/// Выбор папки встреч. Применяется после перезапуска: хранилище, индекс и очередь привязаны к папке.
@MainActor
enum MeetingsFolder {
    static func choose(settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Выбрать")
        panel.message = String(localized: "Куда сохранять встречи. Уже записанные останутся в прежней папке.")
        panel.directoryURL = settings.meetingsRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, url != settings.meetingsRoot else { return }
        settings.meetingsRoot = url
        let alert = NSAlert()
        alert.messageText = String(localized: "Папка встреч изменится после перезапуска")
        alert.informativeText = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        alert.addButton(withTitle: String(localized: "Перезапустить"))
        alert.addButton(withTitle: String(localized: "Позже"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { @Sendable _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
