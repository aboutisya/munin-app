import AppKit
import MnemosyneCore
import SwiftUI

/// Иконка в строке меню и поповер.
///
/// Ожидание: шаблонный силуэт ворона, macOS сама красит его под светлую и тёмную строку.
/// Запись: тот же ворон и маленькая красная точка.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let recorder: Recorder
    private let model: PopoverModel
    private let dot = NSView()
    private var timer: Timer?
    private var lastPhase: Recorder.Phase?

    var hotKeyAvailable = true { didSet { model.hotKeyAvailable = hotKeyAvailable } }
    var notice: String? { didSet { model.notice = notice } }

    init(controller: AppController) {
        self.recorder = controller.recorder
        model = PopoverModel(controller: controller)
        super.init()

        guard let button = item.button else { return }
        button.image = Self.ravenImage(height: 16)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.isHidden = true
        button.addSubview(dot)

        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: PopoverView(model: model, close: { [weak self] in
            self?.popover.performClose(nil)
        }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if ProcessInfo.processInfo.environment["MNEMOSYNE_SHOW_POPOVER"] != nil {
            // Отладка: открыть поповер при запуске, чтобы снять скриншот.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.togglePopover() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Ворон для строки меню: тот же контур, что у иконки приложения, шаблонным изображением.
    static func ravenImage(height: CGFloat) -> NSImage {
        let b = ravenBounds
        let scale = height / b.height
        let image = NSImage(size: NSSize(width: ceil(b.width * scale), height: height), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.translateX(by: -b.minX, yBy: -b.minY)
            t.concat()
            NSColor.black.setFill()
            ravenPath().fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Мунин")
        return image
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reloadRecent()
            model.controller.refreshCandidates()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    private func update() {
        guard let button = item.button else { return }
        // Во время записи — только красная точка в углу ворона, без таймера.
        let recording = recorder.phase == .recording
        dot.isHidden = !recording
        if recording, let imageSize = button.image?.size {
            let x = (button.bounds.width + imageSize.width) / 2 - 3
            dot.frame = NSRect(x: x, y: button.bounds.height / 2 + imageSize.height / 2 - 4, width: 5, height: 5)
        }
        if lastPhase == .saving, recorder.phase == .idle { model.reloadRecent() }
        lastPhase = recorder.phase
    }
}
