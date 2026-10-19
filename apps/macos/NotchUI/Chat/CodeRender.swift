import SwiftUI
import AppKit
import WebKit

/// A code block of HTML, SVG or Mermaid shown as what it draws (HTML render and Mermaid diagrams). Agent HTML
/// runs without JavaScript, in a store that keeps nothing, and cannot navigate anywhere; Mermaid gets only Nook's own page
/// with the pinned Mermaid script.
struct CodeRenderView: NSViewRepresentable {
    let language: String
    let code: String

    static func canRender(_ language: String) -> Bool {
        ["html", "svg", "mermaid"].contains(language.lowercased())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = language.lowercased() == "mermaid"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view, context.coordinator)
        return view
    }

    /// A block that is still being written (the agent streams it) shows its latest version.
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != code else { return }
        load(view, context.coordinator)
    }

    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.shown = code
        switch language.lowercased() {
        case "mermaid":
            let escaped = code.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let page = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>body{margin:0;padding:12px;background:#0F0F13;color:#F4F3F7;font-family:-apple-system}</style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script></head>
            <body><pre class="mermaid">\(escaped)</pre>
            <script>mermaid.initialize({startOnLoad:true,theme:'dark',securityLevel:'strict'});</script></body></html>
            """
            view.loadHTMLString(page, baseURL: nil)
        case "svg":
            view.loadHTMLString("<!doctype html><html><body style=\"margin:0;background:#fff\">\(code)</body></html>", baseURL: nil)
        default:
            view.loadHTMLString(code, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The code on screen, so an update only reloads when it changed.
        var shown = ""

        /// Only the page itself (loaded as about:blank); links and redirects go nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}

/// An MCP app's page from a tool result (see McpUI): with its scripts, as such pages need them, but in a store that keeps
/// nothing, without any way into Nook, and without navigating: a link you click opens in your browser.
struct McpAppView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.shown = html
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            if url?.absoluteString == "about:blank" || navigationAction.targetFrame?.isMainFrame == false { return .allow }
            if navigationAction.navigationType == .linkActivated, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return .cancel
        }
    }
}

/// The MCP app of a tool result: its page, or a button to open the page it points to.
struct McpAppBlock: View {
    let resource: McpUI.Resource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square.dashed").font(.system(size: 10, weight: .semibold))
                Text(tr("ws.mcpApp.title")).font(NookTheme.font(11, .medium))
                Text(resource.uri).font(NookTheme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .foregroundStyle(NookTheme.textSecondary)
            if let html = resource.html {
                McpAppView(html: html)
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(NookTheme.line2, lineWidth: 1))
            } else if let link = resource.link {
                Button(tr("ws.mcpApp.open")) { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help(link.absoluteString)
            }
        }
    }
}
