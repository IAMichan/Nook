import SwiftUI
import AppKit
import WebKit

/// A code block of HTML, SVG or Mermaid shown as what it draws. Agent HTML
/// runs without JavaScript, in a store that keeps nothing, and cannot navigate anywhere; Mermaid gets only Nook's own page
/// (`MermaidPage`) with the script that ships with Nook, so a diagram needs no network.
struct CodeRenderView: NSViewRepresentable {
    let language: String
    let code: String

    static func canRender(_ language: String) -> Bool {
        ["html", "svg", "mermaid"].contains(language.lowercased())
    }

    /// Read once, when the first diagram draws.
    private static let mermaidScript: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let mermaid = language.lowercased() == "mermaid"
        configuration.defaultWebpagePreferences.allowsContentJavaScript = mermaid
        if mermaid, let script = Self.mermaidScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view, context.coordinator)
        return view
    }

    /// A block that is still being written (the agent streams it) shows its latest version, a moment after the last
    /// change: reloading the page (and, for Mermaid, its script) on every streamed token made the chat stutter.
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        // A redraw for something else (text streaming in after the block) keeps the reload already waiting.
        if coordinator.pending != nil, coordinator.waiting == code { return }
        coordinator.pending?.cancel()
        coordinator.pending = nil
        guard coordinator.shown != code else { return }
        coordinator.waiting = code
        coordinator.pending = Task { @MainActor [weak view] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let view else { return }
            coordinator.pending = nil
            load(view, coordinator)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.pending?.cancel()
    }

    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.shown = code
        switch language.lowercased() {
        case "mermaid":
            view.loadHTMLString(Self.mermaidScript == nil ? "<pre>\(MermaidPage.escaped(code))</pre>" : MermaidPage.html(code), baseURL: nil)
        case "svg":
            view.loadHTMLString("<!doctype html><html><body style=\"margin:0;background:#fff\">\(code)</body></html>", baseURL: nil)
        default:
            view.loadHTMLString(code, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The code on screen, so an update only reloads when it changed.
        var shown = ""
        /// The reload waiting for the code to stop changing.
        var pending: Task<Void, Never>?
        /// The code that reload will show.
        var waiting = ""

        /// Only the page itself (loaded as about:blank); links and redirects go nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}
