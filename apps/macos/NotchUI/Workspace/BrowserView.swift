import SwiftUI
import WebKit

/// The browser in Nook's window. You browse as usual; Nook can read the open page when you ask (a read tool), and only
/// navigates on its own after your approval (an action). It keeps no history beyond the session and stores no passwords.
@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate {
    /// Made on first use: a web view starts WebKit's own processes, so Nook only pays for them once the browser is used.
    static var shared: BrowserStore {
        if let instance { return instance }
        let made = BrowserStore()
        instance = made
        return made
    }
    private static var instance: BrowserStore?
    /// The browser if it was ever opened, without starting it.
    static var existing: BrowserStore? { instance }

    @Published var address = ""
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The agent that opened the current page through the workspace bridge; nil once you browse yourself.
    @Published private(set) var openedBy: String?
    /// Why the last page did not load, if it did not.
    @Published private(set) var lastError: String?
    let webView: WKWebView

    /// Collects console errors and warnings (and uncaught errors) of each page, so an agent checking its dev server can
    /// see what went wrong. The list lives in the page itself and starts empty on every load.
    private static let consoleCapture = """
    (function () {
      if (window.__nookConsole) { return; }
      var log = [];
      window.__nookConsole = log;
      function keep(level, parts) {
        try {
          var text = Array.prototype.map.call(parts, function (p) {
            if (p instanceof Error) { return p.stack || String(p); }
            if (typeof p === 'object') { try { return JSON.stringify(p); } catch (e) { return String(p); } }
            return String(p);
          }).join(' ');
          log.push(level + ': ' + text.slice(0, 2000));
          if (log.length > 100) { log.shift(); }
        } catch (e) {}
      }
      ['error', 'warn'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { keep(level, arguments); return original.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) {
        keep('error', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]);
      });
      window.addEventListener('unhandledrejection', function (e) { keep('error', ['Unhandled rejection: ' + e.reason]); });
    })();
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        // Nothing persists between launches: no cookies or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.consoleCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Until the browser is shown it has no size of its own; give it a laptop-sized page so agents can load and read it.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Opens what the user typed: an address, or otherwise a search.
    func go(_ input: String) {
        guard let url = BrowserSearchEngine.address(input, engine: .current()) else { return }
        openedBy = nil
        webView.load(URLRequest(url: url))
    }

    /// Opens a page for an agent and waits (up to `timeout`) until it has loaded. Returns the error when it failed.
    func load(_ url: URL, by agent: String, timeout: TimeInterval = 15) async -> String? {
        openedBy = agent
        lastError = nil
        webView.load(URLRequest(url: url))
        // didStartProvisionalNavigation sets `loading`; wait for it to start, then for it to end.
        let deadline = Date().addingTimeInterval(timeout)
        var started = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if loading { started = true } else if started || webView.url != nil && !webView.isLoading { break }
        }
        if loading { return "Still loading after \(Int(timeout)) seconds." }
        return lastError
    }

    /// Console errors and warnings the open page logged since it loaded.
    func consoleMessages() async -> [String] {
        guard webView.url != nil,
              let result = try? await webView.evaluateJavaScript("JSON.stringify(window.__nookConsole || [])"),
              let text = result as? String, let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    /// The visible part of the page as JPEG, at most `maxWidth` pixels wide.
    func screenshot(maxWidth: Int = 1280) async throws -> Data {
        guard webView.url != nil else { throw NookError(tr("workbench.browser.nothingOpen")) }
        let configuration = WKSnapshotConfiguration()
        let width = max(320, min(maxWidth, 2560))
        if webView.bounds.width > CGFloat(width) { configuration.snapshotWidth = NSNumber(value: width) }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) } else {
                    continuation.resume(throwing: error ?? NookError("The browser could not take a screenshot."))
                }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw NookError("The browser could not take a screenshot.")
        }
        return jpeg
    }

    /// The visible text of the open page (for Nook to read), with its address.
    func pageText() async throws -> (title: String, url: String, text: String) {
        guard let url = webView.url else { throw NookError(tr("workbench.browser.nothingOpen")) }
        let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        let text = ((result as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (webView.title ?? url.absoluteString, url.absoluteString, String(text.prefix(14_000)))
    }

    // MARK: Tools

    /// Reading the open page runs right away; going somewhere is an action that waits for approval. Static, so offering
    /// the tools to the model does not start the browser.
    static var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "read_nook_browser",
                description: "Reads the text of the page open in Nook's own browser (Agents › Browser), with its title and address.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Read Nook's browser" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    // Never opened: nothing to read, and no reason to start the browser for that.
                    guard let browser = BrowserStore.instance else { throw NookError(tr("workbench.browser.nothingOpen")) }
                    let page = try await browser.pageText()
                    return "## \(page.title)\nURL: \(page.url)\n\n\(page.text)\n\n" + ReferenceParser.line(title: page.title, url: page.url, detail: "Nook browser")
                }
            ),
            ToolSpec(
                name: "open_in_nook_browser",
                description: "Opens a web address in Nook's own browser so the user can look at it together with Nook. Only https addresses.",
                schema: ["type": "object", "properties": ["url": ["type": "string", "description": "The full https address."]], "required": ["url"]],
                kind: .action,
                summarize: { input in "Browser: open \((input["url"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    guard let raw = input["url"] as? String, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
                        throw NookError("Only https addresses can be opened.")
                    }
                    BrowserStore.shared.webView.load(URLRequest(url: url))
                    if WorkspaceWindowController.shared.isKey {
                        AppModel.shared.openMainWindow(.sessions, tool: .browser)
                    } else {
                        AppModel.shared.showWorkbench(.browser)
                    }
                    return "Opened \(url.absoluteString) in Nook's browser"
                }
            )
        ]
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh(loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh(loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastError = error.localizedDescription
        refresh(loading: false)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastError = error.localizedDescription
        refresh(loading: false)
    }

    /// Only web pages open inside; mail, phone and app links go to the system, other schemes are refused.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        if scheme == "mailto", let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return .cancel
    }

    private func refresh(loading: Bool) {
        self.loading = loading
        title = webView.title ?? ""
        if let url = webView.url?.absoluteString { address = url }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

/// Hosts the browser's web view in a container without an intrinsic size, so the window's layout does not loop.
private final class WebViewContainer: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = WebViewContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// Agents › Browser.
struct BrowserView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { store.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!store.canGoBack)
                Button { store.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!store.canGoForward)
                Button {
                    if store.loading { store.webView.stopLoading() } else { _ = store.webView.reload() }
                } label: {
                    Image(systemName: store.loading ? "xmark" : "arrow.clockwise")
                }
                TextField(tr("workbench.browser.address"), text: $store.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.go(store.address) }
                Button {
                    askAboutPage()
                } label: {
                    Label(tr("workbench.browser.ask"), systemImage: "sparkles")
                }
                .disabled(store.webView.url == nil || asking)
            }
            .buttonStyle(.borderless)
            .padding(10)
            if let agent = store.openedBy {
                HStack(spacing: 6) {
                    AgentMark(agent: agent, account: nil, size: 12, ring: .clear)
                    Text(tr("bridge.browserBy", agent))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            Divider()
            if store.webView.url == nil && !store.loading {
                WSEmptyState(symbol: "safari", title: tr("workbench.browser.emptyTitle"), message: tr("workbench.browser.emptyMessage"), action: nil)
            }
            WebViewHost(webView: store.webView)
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
        }
        // In view: whatever an agent opens here is seen, also while you watch.
        .onAppear { bridge.markBrowserSeen() }
        .onChange(of: bridge.unseen) { _, _ in bridge.markBrowserSeen() }
    }

    /// Hands the open page to the chat as an attachment, like dropping a file.
    private func askAboutPage() {
        asking = true
        Task {
            defer { asking = false }
            do {
                let page = try await store.pageText()
                app.attachText(name: page.title, text: "URL: \(page.url)\n\n\(page.text)")
                if WorkspaceWindowController.shared.isKey { app.openMainWindow(.chat) } else { app.showChat() }
            } catch {
                app.viewModel.present(app.errorCard(error.localizedDescription))
            }
        }
    }
}

/// The tools that work alongside the agents: terminals, the browser and worktrees.
enum WorkbenchTool: String, CaseIterable, Identifiable {
    case terminals, browser, worktrees
    var id: String { rawValue }
    var title: String { tr("workbench." + rawValue) }
    var symbol: String {
        switch self {
        case .terminals: return "terminal"
        case .browser: return "safari"
        case .worktrees: return "arrow.triangle.branch"
        }
    }
}
