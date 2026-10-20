import SwiftUI
import WebKit
import Security

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
    /// How many browser pages (notch, workspace window) show the web view now. While one does, a page Nook opens is
    /// already in sight and needs no popup.
    var shownInWorkbench = 0
    let webView: WKWebView

    /// Apple's browser entitlement. A build signed with it gets the system's passkeys in this web view: iCloud Keychain,
    /// a phone nearby (over Bluetooth or a QR code) and security keys, like Safari. Apple grants it on request; see
    /// docs/BROWSER-PASSKEYS.md.
    static let passkeyEntitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Whether this build is signed with the browser entitlement, so WebKit can handle passkeys itself.
    static var hasPasskeyEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, passkeyEntitlement as CFString, nil) else { return false }
        return (value as? Bool) == true
    }

    /// Without the entitlement passkeys cannot work here: sites like Google then ask for Bluetooth and a nearby phone
    /// and stop there. Hiding them makes such sites offer a password, a code or the phone prompt instead. Other
    /// credential requests pass through.
    private static let hidePasskeys = """
    (function () {
      try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
      var credentials = navigator.credentials;
      if (!credentials) { return; }
      ['get', 'create'].forEach(function (name) {
        var original = credentials[name];
        if (typeof original !== 'function') { return; }
        credentials[name] = function (options) {
          if (options && options.publicKey) {
            return Promise.reject(new DOMException('Passkeys are not available in this browser.', 'NotAllowedError'));
          }
          return original.apply(credentials, arguments);
        };
      });
    })();
    """

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
        if !Self.hasPasskeyEntitlement {
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.hidePasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // Present as Safari, so sign-in pages treat it like the browser it is built on instead of refusing an unknown one.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
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

    /// Opens a page Nook's chat asked for, without waiting for it.
    func open(_ url: URL) {
        openedBy = nil
        lastError = nil
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
                    BrowserStore.shared.open(url)
                    // The chat stays where it is; the page shows in a small window to follow along.
                    BrowserPopup.shared.show()
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

    /// The open page in the user's own browser, for what does not work inside an app (passkeys, some sign-ins).
    func openInDefaultBrowser() {
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
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

struct WebViewHost: NSViewRepresentable {
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
    /// Shown beside the chat: a button that puts the browser away again.
    var onClose: (() -> Void)?

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
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                    .onSubmit { store.go(store.address) }
                Button { store.openInDefaultBrowser() } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(tr("browser.openExternal"))
                    .disabled(store.webView.url == nil)
                Button {
                    askAboutPage()
                } label: {
                    Label(tr("workbench.browser.ask"), systemImage: "sparkles")
                }
                .disabled(store.webView.url == nil || asking)
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .help(tr("embedded.close"))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
            // A line only above a page; the empty browser runs on into the background.
            Rectangle().fill(NookTheme.line).frame(height: 1)
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
            if store.webView.url == nil && !store.loading {
                WSEmptyState(symbol: "safari", title: tr("workbench.browser.emptyTitle"), message: tr("workbench.browser.emptyMessage"), action: nil)
            }
            WebViewHost(webView: store.webView)
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
        }
        // In view: whatever an agent opens here is seen, also while you watch.
        .onAppear {
            bridge.markBrowserSeen()
            store.shownInWorkbench += 1
            // The web view can only be in one place: here now, so the popup goes.
            BrowserPopup.shared.close()
        }
        .onDisappear { store.shownInWorkbench = max(0, store.shownInWorkbench - 1) }
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
                // The page stays in sight next to the chat, unless an app is open there already.
                if EmbeddedAppStore.shared.current == nil { app.viewModel.browserBesideChat = true }
                app.showChat()
            } catch {
                app.viewModel.present(app.errorCard(error.localizedDescription))
            }
        }
    }
}

/// A small floating window that shows Nook's browser when the chat or an agent opens a page while no browser page is in
/// view, so you can follow along. It does not take focus from the app you are in.
@MainActor
final class BrowserPopup: NSObject, NSWindowDelegate {
    static let shared = BrowserPopup()
    private var panel: NSPanel?

    func show() {
        let store = BrowserStore.shared
        guard store.shownInWorkbench == 0 else { return }
        if let panel, panel.isVisible { return }
        // A fresh window each time: the web view may have moved to a browser page since the last one.
        let root = BrowserPopupView(store: store, expand: { [weak self] in self?.expand() })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 220)
        panel.setContentSize(NSSize(width: 440, height: 320))
        panel.delegate = self
        if !panel.setFrameUsingName("NookBrowserPopup"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        panel.setFrameAutosaveName("NookBrowserPopup")
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    /// The full browser: in the main window when that is in front, otherwise in the notch.
    private func expand() {
        close()
        AppModel.shared.showWorkbench(.browser)
    }
}

private struct BrowserPopupView: View {
    @ObservedObject var store: BrowserStore
    let expand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let agent = store.openedBy {
                    AgentMark(agent: agent, account: nil, size: 14, ring: .clear)
                } else {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.title.isEmpty ? tr("browser.popup.title") : store.title)
                        .font(NookTheme.font(12, .semibold))
                        .lineLimit(1)
                    Text(store.address)
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.openInDefaultBrowser() } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(tr("browser.openExternal"))
                    .disabled(store.webView.url == nil)
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("browser.popup.expand"))
            }
            .buttonStyle(.borderless)
            // Room for the window's own buttons on the left.
            .padding(.leading, 64)
            .padding(.trailing, 10)
            .frame(height: 38)
            Divider()
            WebViewHost(webView: store.webView)
        }
        .background(NookTheme.field)
        .ignoresSafeArea()
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
