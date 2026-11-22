import AppKit
import SwiftUI

/// Главное окно. Пока оно открыто, приложение видно в Dock и ⌘Tab;
/// после закрытия снова живёт только в строке меню.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let library: LibraryModel

    init(library: LibraryModel) {
        self.library = library
    }

    func show(meeting id: UUID? = nil, tab: LibraryModel.Tab? = nil) {
        if window == nil { makeWindow() }
        library.reload()
        if let id { library.select(id, tab: tab) } else if let tab { library.tab = tab }
        library.startWatching()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Мунин"
        w.minSize = NSSize(width: 960, height: 600)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MainView(library: library))
        w.center()
        w.setFrameAutosaveName("MnemosyneMain")
        w.delegate = self
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        library.stopWatching()
        library.controller.restoreActivationPolicy(closing: window)
    }
}
