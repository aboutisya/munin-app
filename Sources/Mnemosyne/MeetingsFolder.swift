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
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять встречи. Уже записанные останутся в прежней папке."
        panel.directoryURL = settings.meetingsRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, url != settings.meetingsRoot else { return }
        settings.meetingsRoot = url
        let alert = NSAlert()
        alert.messageText = "Папка встреч изменится после перезапуска"
        alert.informativeText = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        alert.addButton(withTitle: "Перезапустить")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
