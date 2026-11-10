import SwiftUI
import AppKit
import WebKit

/// Text with formulas, typeset by the KaTeX that ships with Nook (`Resources/katex`), so math needs no network. Only a
/// block that holds math gets one (`MathText`): every other message stays plain text. While an answer streams the page
/// is set again a moment after the last change, not on every token, as `CodeRenderView` does for diagrams.
struct MathView: View {
    /// The text with its TeX, as written in the answer.
    let text: String
    /// The whole text is one display formula (a ```math block, `$$…$$`).
    var display = false
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 0

    var body: some View {
        MathPage(html: MathText.html(text, display: display), size: size, dark: colorScheme == .dark, height: $height)
            .frame(height: max(height, display ? 36 : size * 1.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel(text)
            .contextMenu {
                // The TeX itself, as the agent wrote it.
                Button(tr("math.copyTeX")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}

/// The web page behind `MathView`: no network, no navigation, JavaScript only for KaTeX on Nook's own page.
private struct MathPage: NSViewRepresentable {
    let html: String
    let size: CGFloat
    let dark: Bool
    @Binding var height: CGFloat

    /// KaTeX's script and its style with the fonts inside it, read once, when the first formula draws.
    private static let script: String? = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: "katex")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let style: String? = {
        guard let folder = Bundle.main.url(forResource: "katex", withExtension: nil),
              var css = try? String(contentsOf: folder.appendingPathComponent("katex.min.css"), encoding: .utf8) else { return nil }
        // The fonts as data, so the page needs no file access.
        let fonts = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("fonts"), includingPropertiesForKeys: nil)) ?? []
        for font in fonts where font.pathExtension == "woff2" {
            guard let data = try? Data(contentsOf: font) else { continue }
            css = css.replacingOccurrences(of: "url(fonts/\(font.lastPathComponent))",
                                           with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        return css
    }()

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if let script = Self.script {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = MathWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = $height
        let page = self.page
        if coordinator.pending != nil, coordinator.waiting == page { return }
        coordinator.pending?.cancel()
        coordinator.pending = nil
        guard coordinator.shown != page else { return }
        coordinator.waiting = page
        coordinator.pending = Task { @MainActor [weak view] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let view else { return }
            coordinator.pending = nil
            load(view, coordinator)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.pending?.cancel()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        let page = self.page
        coordinator.shown = page
        view.loadHTMLString(page, baseURL: nil)
    }

    /// The page: the theme's text color for this appearance, the size of the text around it, and the formulas set by
    /// KaTeX (an error shows the TeX in the error color instead of breaking the page). Its height goes back to SwiftUI.
    private var page: String {
        let palette = NookTheme.palette(dark: dark)
        let text = NookColor.string(palette.textStrong), code = NookColor.string(palette.graphite)
        let error = NookColor.string(palette.coral)
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(Self.style ?? "")
        html,body{margin:0;padding:0;background:transparent;color:\(text);font:\(size)px/1.55 -apple-system,system-ui,sans-serif;
        -webkit-font-smoothing:antialiased;overflow:hidden}
        code{font:\(size * 0.85)px ui-monospace,Menlo,monospace;background:\(code);border-radius:4px;padding:1px 4px}
        .katex{font-size:1.1em}.katex-display{margin:.3em 0;overflow-x:auto;overflow-y:hidden;padding:2px 0}
        .katex-error{color:\(error)}
        </style></head><body><div id="m">\(html)</div><script>
        function post(){window.webkit.messageHandlers.height.postMessage(document.getElementById('m').getBoundingClientRect().height)}
        if(window.katex){document.querySelectorAll('.tex').forEach(function(e){try{katex.render(e.dataset.tex,e,
        {displayMode:e.classList.contains('display'),throwOnError:false,output:'htmlAndMathml'})}catch(x){}})}
        post();new ResizeObserver(post).observe(document.getElementById('m'));
        if(document.fonts){document.fonts.ready.then(post)}
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var shown = ""
        var pending: Task<Void, Never>?
        var waiting = ""

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let next = ceil(CGFloat(value))
            MainActor.assumeIsolated {
                if abs(height.wrappedValue - next) > 0.5 { height.wrappedValue = next }
            }
        }

        /// Only the page itself (loaded as about:blank); links and redirects go nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}

/// A web view that hands vertical scrolling to the conversation around it: a formula only scrolls sideways.
private final class MathWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
