import SwiftUI
import WebKit

/// A page an agent showed in its timeline (`render_page`, see `RenderedPage`): its title, then the page at the height the
/// agent asked for (capped). The page runs as an MCP app's page does, in a sandboxed frame under a policy that lets nothing
/// load or connect, but with nothing to talk to: no message handler, no navigation, no popups. It folds like a step.
struct RenderedPageRow: View, Equatable {
    let event: RunEvent
    @State private var hidden = false
    /// The page, read from its file off the main thread; `missing` once that found nothing.
    @State private var html: String?
    @State private var missing = false
    /// The page's scripts run only while its row is on screen; otherwise the web view goes, so a page that animates or
    /// loops costs nothing out of sight. The energy plan has no say here: a page on screen is something you look at, not
    /// background work, and a build (when agents show pages) would leave an empty frame for as long as it keeps the Mac busy.
    @State private var onScreen = false

    static func == (lhs: RenderedPageRow, rhs: RenderedPageRow) -> Bool { lhs.event == rhs.event }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            TranscriptWorkLine(symbol: "macwindow", label: event.text, open: !hidden) {
                withAnimation(NookTheme.reveal) { hidden.toggle() }
            }
            .help(tr("ws.page.help"))
            if !hidden, !missing || html != nil {
                if let html, onScreen {
                    SandboxedPageView(html: html)
                        .frame(maxWidth: .infinity)
                        .frame(height: RenderedPage.height(of: event))
                        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                            .stroke(NookTheme.line2, lineWidth: 1))
                        .padding(.leading, TranscriptStyle.workIndent)
                } else {
                    // Being read: the room it will take, so the timeline does not jump when it arrives.
                    Color.clear.frame(height: RenderedPage.height(of: event))
                }
            } else if !hidden {
                Text(tr("ws.page.gone"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.leading, TranscriptStyle.workIndent)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: event.detail) {
            let path = event.detail
            let base = NookPaths.supportDirectory
            let read = await Task.detached(priority: .utility) { Self.html(path, base: base) }.value
            html = read
            missing = read == nil
        }
    }

    /// The page's file, only from the folder Nook keeps pages in; nil when it is missing or points elsewhere.
    private nonisolated static func html(_ path: String?, base: URL) -> String? {
        guard let path, RenderedPage.isOwnFile(path, base: base),
              let data = FileManager.default.contents(atPath: path), data.count <= RenderedPage.maxHTMLBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A web view for an untrusted page: a non-persistent store, no script message handlers, no window opening, and every
/// navigation after the first load cancelled (a link in the page goes nowhere).
private struct SandboxedPageView: NSViewRepresentable {
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
        view.loadHTMLString(RenderedPage.hostPage(html), baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(RenderedPage.hostPage(html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// The page Nook loads and its own frame's srcdoc; everything else (links, redirects, forms) goes nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url?.absoluteString ?? ""
            return url == "about:blank" || url == "about:srcdoc" ? .allow : .cancel
        }

        /// macOS can end the page's process (memory pressure, a crash); the frame would stay empty until the row is rebuilt.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let loaded else { return }
            webView.loadHTMLString(RenderedPage.hostPage(loaded), baseURL: nil)
        }
    }
}
