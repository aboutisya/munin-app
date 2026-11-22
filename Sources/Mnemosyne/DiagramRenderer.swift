import AppKit
import MnemosyneCore
import WebKit

/// Диаграммы анализа → `diagrams/NN-type.mmd` и `.png` (2x, светлая тема, белый фон — для Mattermost).
/// Mermaid, который не разобрался, остаётся только исходником и в публичное саммари не попадает (§7).
@MainActor
final class DiagramRenderer: NSObject, WKScriptMessageHandler {
    private var web: WKWebView!
    private var window: NSWindow!
    private var continuation: CheckedContinuation<Result<CGSize, Error>, Never>?

    struct RenderError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Отрисовать все диаграммы встречи. Уже готовые PNG того же исходника не перерисовываются.
    /// Возвращает диаграммы, у которых есть PNG.
    static func renderAll(folder: URL, analysis: Analysis) async -> [PublicInput.DiagramRef] {
        guard !analysis.diagrams.isEmpty else { return [] }
        let dir = folder.appending(path: "diagrams")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let renderer = DiagramRenderer()
        defer { renderer.close() }
        var refs: [PublicInput.DiagramRef] = []
        for (i, d) in analysis.diagrams.enumerated() {
            let base = PublicInput.diagramBase(index: i, type: d.type)
            let mmd = dir.appending(path: "\(base).mmd"), png = dir.appending(path: "\(base).png")
            let err = dir.appending(path: "\(base).error.txt")
            let old = try? String(contentsOf: mmd, encoding: .utf8)
            if old == d.mermaid, FileManager.default.fileExists(atPath: png.path) {
                refs.append(.init(title: d.title, file: "diagrams/\(base).png"))
                continue
            }
            try? d.mermaid.write(to: mmd, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: png)
            do {
                let data = try await renderer.png(d.mermaid)
                try data.write(to: png, options: .atomic)
                try? FileManager.default.removeItem(at: err)
                refs.append(.init(title: d.title, file: "diagrams/\(base).png"))
            } catch {
                Log.app.error("диаграмма \(base): \(error.localizedDescription)")
                try? error.localizedDescription.write(to: err, atomically: true, encoding: .utf8)
            }
        }
        return refs
    }

    /// PNG уже отрисованной диаграммы встречи, если он есть.
    static func pngURL(folder: URL, index: Int, type: String) -> URL? {
        let url = folder.appending(path: "diagrams/\(PublicInput.diagramBase(index: index, type: type)).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func copyToPasteboard(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Mattermost берёт картинку из буфера как PNG; файловый URL — для вставки в Finder и почту.
        pb.writeObjects([image, url as NSURL])
        pb.setData(data, forType: .png)
        return true
    }

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "done")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1000), configuration: config)
        web.appearance = NSAppearance(named: .aqua)
        // Снимок WKWebView требует окна; держим его за пределами экрана.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1400, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "done")
        window.orderOut(nil)
        window.contentView = nil
    }

    func png(_ source: String) async throws -> Data {
        web.setFrameSize(NSSize(width: 4000, height: 3000))
        window.setContentSize(NSSize(width: 4000, height: 3000))
        let size = try await render(source).get()
        let w = ceil(size.width), h = ceil(size.height)
        web.setFrameSize(NSSize(width: w, height: h))
        window.setContentSize(NSSize(width: w, height: h))
        try await Task.sleep(for: .milliseconds(80))
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: w, height: h)
        let image = try await web.takeSnapshot(configuration: config)
        return try Self.png(image, width: Int(w) * 2, height: Int(h) * 2)
    }

    private func render(_ source: String) async -> Result<CGSize, Error> {
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;background:#fff}#box{display:inline-block;padding:24px;background:#fff}pre{margin:0}</style>
        <script>\(MermaidWeb.script)</script></head><body>
        <div id="box"><pre class="mermaid">\(escaped)</pre></div>
        <script>
          const natural = {useMaxWidth:false};
          mermaid.initialize({startOnLoad:false, theme:'neutral', fontFamily:'-apple-system, Helvetica, sans-serif',
                              flowchart:natural, sequence:natural, timeline:natural});
          mermaid.run({querySelector:'.mermaid', suppressErrors:false}).then(() => {
            const svg = document.querySelector('#box svg');
            const r = svg ? svg.getBoundingClientRect() : {width:0, height:0};
            window.webkit.messageHandlers.done.postMessage({w: r.width + 48, h: r.height + 48});
          }).catch(e => window.webkit.messageHandlers.done.postMessage({error: String(e && e.message || e)}));
        </script></body></html>
        """
        return await withCheckedContinuation { c in
            continuation = c
            web.loadHTMLString(html, baseURL: nil)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(.failure(RenderError(message: "Mermaid не ответил за 15 с")))
            }
        }
    }

    private func finish(_ result: Result<CGSize, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: result)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let body = message.body as? [String: Any] ?? [:]
            let error = body["error"] as? String
            let w = (body["w"] as? NSNumber)?.doubleValue ?? 0, h = (body["h"] as? NSNumber)?.doubleValue ?? 0
            if let error { finish(.failure(RenderError(message: "Mermaid: \(error)"))) }
            else if w < 10 || h < 10 { finish(.failure(RenderError(message: "Mermaid вернул пустую картинку"))) }
            else { finish(.success(CGSize(width: w, height: h))) }
        }
    }

    private static func png(_ image: NSImage, width: Int, height: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RenderError(message: "не удалось создать картинку")
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError(message: "не удалось сохранить PNG") }
        return data
    }
}
