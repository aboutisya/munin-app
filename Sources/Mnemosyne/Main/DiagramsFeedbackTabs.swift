import AppKit
import MnemosyneCore
import SwiftUI
import WebKit

/// «Диаграммы»: Mermaid из анализа, отрисованный встроенным mermaid.js.
struct DiagramsTab: View {
    let detail: MeetingDetail

    var body: some View {
        let diagrams = detail.analysis?.diagrams ?? []
        if diagrams.isEmpty {
            Text(detail.analysis == nil ? "Диаграммы появятся после анализа." : "В этой встрече не было процессов или схем, которые стоит рисовать.")
                .font(.system(size: 15)).foregroundStyle(Theme.sec)
        } else {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(Array(diagrams.enumerated()), id: \.offset) { i, d in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Text(d.title).font(.system(size: 17, weight: .semibold))
                            Spacer()
                            if let png = DiagramRenderer.pngURL(folder: detail.folder, index: i, type: d.type) {
                                LinkButton("Скопировать PNG") { _ = DiagramRenderer.copyToPasteboard(png) }
                            }
                            LinkButton("Mermaid") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(d.mermaid, forType: .string)
                            }
                        }
                        MermaidView(source: d.mermaid)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                    }
                }
            }
        }
    }
}

/// WKWebView с mermaid.js из ресурсов приложения. Высота подстраивается под картинку.
struct MermaidView: View {
    let source: String
    @State private var height: CGFloat = 200

    var body: some View {
        MermaidWeb(source: source, height: $height)
            .frame(height: height)
    }
}

struct MermaidWeb: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    static let script: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "size")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        load(web)
        context.coordinator.source = source
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.source != source else { return }
        context.coordinator.source = source
        load(web)
    }

    private func load(_ web: WKWebView) {
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          body{margin:0;padding:20px;background:transparent;font-family:-apple-system,sans-serif;}
          .mermaid{display:flex;justify-content:center}
          .err{color:#d93036;font-size:13px;white-space:pre-wrap}
        </style>
        <script>\(Self.script)</script></head><body>
        <pre class="mermaid">\(escaped)</pre>
        <script>
          const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
          mermaid.initialize({startOnLoad:false, theme: dark ? 'dark' : 'neutral', fontFamily:'-apple-system'});
          mermaid.run().catch(e => { document.body.innerHTML = '<div class="err">Не удалось отрисовать: ' + e.message + '</div>'; })
            .finally(() => setTimeout(() => window.webkit.messageHandlers.size.postMessage(document.body.scrollHeight), 50));
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var source = ""
        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let h = message.body as? Double { height.wrappedValue = max(80, CGFloat(h)) }
            else if let h = message.body as? Int { height.wrappedValue = max(80, CGFloat(h)) }
        }
    }
}

/// «Тональность и фидбек»: общая шкала, участники с цитатами, конфликт и что улучшить в моей речи.
struct FeedbackTab: View {
    let library: LibraryModel
    let detail: MeetingDetail

    var body: some View {
        if let a = detail.analysis {
            let names = detail.names
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap("Тональность")
                    Text(a.sentiment.overall.label.capitalizedFirst).font(.system(size: 17, weight: .semibold))
                    scale(a.sentiment.overall.score)
                    ForEach(Array(a.sentiment.overall.evidence.enumerated()), id: \.offset) { _, q in quote(q.quote, q.ts) }
                }
                if !a.sentiment.perParticipant.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionCap("Участники")
                        ForEach(Array(a.sentiment.perParticipant.enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(names[p.speaker] ?? p.speaker).font(.system(size: 15, weight: .semibold)).frame(width: 150, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(p.label.capitalizedFirst).font(.system(size: 13)).foregroundStyle(Theme.sec)
                                    ForEach(Array(p.evidence.enumerated()), id: \.offset) { _, q in quote(q.quote, q.ts) }
                                }
                            }
                        }
                    }
                }
                if a.conflict.detected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.red).frame(width: 7, height: 7)
                            Text("Был конфликт" + (a.conflict.kinds.isEmpty ? "" : ": " + a.conflict.kinds.joined(separator: ", ")))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(a.conflict.summary).font(.system(size: 15)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    if !a.conflict.mySpeechFeedback.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionCap("Что улучшить в моей речи")
                            ForEach(Array(a.conflict.mySpeechFeedback.enumerated()), id: \.offset) { _, f in feedback(f) }
                        }
                    }
                } else {
                    Text("Конфликта не было, фидбек по речи не нужен.").font(.system(size: 15)).foregroundStyle(Theme.sec)
                }
            }
        } else {
            Text("Тональность и фидбек появятся после анализа.").font(.system(size: 15)).foregroundStyle(Theme.sec)
        }
    }

    private func scale(_ score: Double) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line).frame(height: 4)
                    Circle().fill(Theme.ink).frame(width: 12, height: 12)
                        .offset(x: (geo.size.width - 12) * CGFloat((min(1, max(-1, score)) + 1) / 2))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack {
                Text("Негатив"); Spacer(); Text("Позитив")
            }
            .font(.system(size: 12)).foregroundStyle(Theme.sec)
        }
        .frame(maxWidth: 420)
    }

    private func quote(_ text: String, _ ts: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("«\(text)»").font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            Timestamp(ts) { library.jump(to: ts) }
        }
    }

    private func feedback(_ f: Analysis.Feedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("«\(f.quote)»").font(.system(size: 15, weight: .semibold))
                Spacer()
                Timestamp(f.ts) { library.jump(to: f.ts) }
            }
            Text(f.problem).font(.system(size: 15)).foregroundStyle(Theme.sec).fixedSize(horizontal: false, vertical: true)
            (Text("Лучше: ").foregroundStyle(Theme.sec) + Text("«\(f.better)»"))
                .font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            Text(PersonalSummary.principleTitle(f.principle).capitalizedFirst).font(.system(size: 12)).foregroundStyle(Theme.sec)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .textSelection(.enabled)
    }
}
