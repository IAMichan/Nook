import Combine
import SwiftUI
import WebKit
import Security

/// The browser in Nook's window, with one or more tabs (`BrowserPage`). You browse as usual; Nook can read the open page
/// when you ask (a read tool), and only navigates on its own after your approval (an action). It keeps no history beyond
/// the session and stores no passwords. Everything that acts on "the page" (agents, the bridge, the chat) acts on the
/// tab in view.
@MainActor
final class BrowserStore: ObservableObject {
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

    /// One tab as the side panel's tab row shows it.
    struct Tab: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    /// The open tabs, in order; there is always at least one.
    @Published private(set) var pages: [BrowserPage]
    /// The tab in view.
    @Published private(set) var page: BrowserPage
    /// The tabs with their titles, kept current for the tab row.
    @Published private(set) var tabs: [Tab] = []
    /// How many browser pages (notch, workspace window) show the web view now. While one does, a page Nook opens is
    /// already in sight and needs no popup.
    var shownInWorkbench = 0
    private var watchers: [UUID: AnyCancellable] = [:]

    /// One website data store for every tab, so a sign-in in one tab holds in the others. Nothing of it is written to disk.
    let dataStore = WKWebsiteDataStore.nonPersistent()

    private init() {
        let first = BrowserPage(dataStore: dataStore)
        pages = [first]
        page = first
        watch(first)
        updateTabs()
    }

    /// Whether `page` is in sight now: the tab in view while a browser page, the popup or a chat corner shows it.
    func isShowing(_ page: BrowserPage) -> Bool {
        page === self.page
            && (shownInWorkbench > 0 || BrowserPopup.shared.isVisible || SessionBrowserOwner.shared.shownInChat > 0)
    }

    /// Opens an empty tab after the one in view and brings it into view.
    @discardableResult
    func newTab() -> BrowserPage {
        let made = BrowserPage(dataStore: dataStore)
        let index = pages.firstIndex { $0 === page }.map { $0 + 1 } ?? pages.count
        pages.insert(made, at: index)
        watch(made)
        select(made.id)
        return made
    }

    /// Brings a tab into view; the one that was in view may be put away after a while (see `BrowserPage.outOfSight`).
    func select(_ id: UUID) {
        guard let next = pages.first(where: { $0.id == id }), next !== page else { return }
        let previous = page
        page = next
        updateTabs()
        previous.outOfSight()
        next.inSight()
    }

    /// Closes a tab; the one next to it comes into view. The last tab stays: closing it closes the browser's panel tab.
    func close(_ id: UUID) {
        guard pages.count > 1, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let closing = pages.remove(at: index)
        watchers[closing.id] = nil
        closing.discard()
        if closing === page {
            page = pages[min(index, pages.count - 1)]
            page.inSight()
        }
        updateTabs()
    }

    private func watch(_ page: BrowserPage) {
        // Every change in the tab in view reaches the views watching the store; a title change in any tab reaches the tab row.
        watchers[page.id] = page.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak page] in
                guard let self, let page else { return }
                if page === self.page { self.objectWillChange.send() }
                self.updateTabs()
            }
    }

    private func updateTabs() {
        let next = pages.map { Tab(id: $0.id, title: $0.title) }
        if next != tabs { tabs = next }
    }

    // MARK: The tab in view

    var address: String {
        get { page.address }
        set { page.address = newValue }
    }
    var title: String { page.title }
    var loading: Bool { page.loading }
    var canGoBack: Bool { page.canGoBack }
    var canGoForward: Bool { page.canGoForward }
    var openedBy: String? { page.openedBy }
    var lastError: String? { page.lastError }
    var webView: WKWebView { page.webView }
    var pageURL: URL? { page.pageURL }
    var pageTitle: String { page.pageTitle }

    func go(_ input: String) { page.go(input) }
    func open(_ url: URL) { page.open(url) }
    func load(_ url: URL, by agent: String, timeout: TimeInterval = 15) async -> String? {
        await page.load(url, by: agent, timeout: timeout)
    }
    func consoleMessages() async -> [String] { await page.consoleMessages() }
    func screenshot(maxWidth: Int = 1280) async throws -> Data { try await page.screenshot(maxWidth: maxWidth) }
    func pageText() async throws -> (title: String, url: String, text: String) { try await page.pageText() }
    func evaluate(_ script: String) async throws -> Any { try await page.evaluate(script) }
    func openInDefaultBrowser() { page.openInDefaultBrowser() }

    /// No browser page and no popup shows the browser any more: every tab may be put away after a while.
    func outOfSight() { pages.forEach { $0.outOfSight() } }

    /// The browser shows again: the tab in view comes back.
    func inSight() { page.inSight() }

    /// Shows a page you asked for (a pull request Nook made, say) in Nook's own browser: the small window beside where you
    /// are, unless a browser page is already in view.
    static func show(_ url: URL) {
        shared.open(url)
        BrowserPopup.shared.show()
    }

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
    static let hidePasskeys = """
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
}

/// One tab of Nook's browser: its own web view and page.
@MainActor
final class BrowserPage: NSObject, ObservableObject, WKNavigationDelegate {
    let id = UUID()
    @Published var address = ""
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The agent that opened the current page through the workspace bridge; nil once you browse yourself.
    @Published private(set) var openedBy: String?
    /// Why the last page did not load, if it did not.
    @Published private(set) var lastError: String?
    /// When the page was last loaded again after its process crashed.
    private var lastCrashReload = Date.distantPast
    let webView: WKWebView
    /// The page put away while the browser was out of sight (see `outOfSight`), and its title.
    private var parked: (url: URL, title: String)?
    private var parkTask: Task<Void, Never>?
    private static let parkSeconds: UInt64 = 15 * 60

    /// The open page, also while it is put away.
    var pageURL: URL? { parked?.url ?? webView.url }
    var pageTitle: String { parked?.title ?? webView.title ?? "" }

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

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        // Nothing persists between launches: no cookies or storage on disk.
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.consoleCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if !BrowserStore.hasPasskeyEntitlement {
            configuration.userContentController.addUserScript(
                WKUserScript(source: BrowserStore.hidePasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // Present as Safari, so sign-in pages treat it like the browser it is built on instead of refusing an unknown one.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        // Until the browser is shown it has no size of its own; give it a laptop-sized page so agents can load and read it.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Not in sight any more (the browser went away, or another tab came into view): after `parkSeconds` the page is put away, since a page can
    /// hold hundreds of MB and keep running its scripts for no one. It comes back as soon as the browser is shown or read.
    func outOfSight() {
        parkTask?.cancel()
        parkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.parkSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.parked == nil, BrowserStore.existing?.isShowing(self) != true,
                  !self.loading, let url = self.webView.url, url.scheme != "about" else { return }
            self.parked = (url, self.webView.title ?? "")
            self.webView.loadHTMLString("", baseURL: nil)
        }
    }

    /// The browser shows again: the page put away comes back.
    func inSight() {
        parkTask?.cancel()
        guard let parked else { return }
        self.parked = nil
        webView.load(URLRequest(url: parked.url))
    }

    /// Before the page is read: back from where it was put away, loaded.
    private func restoreParked() async {
        guard let parked else { return }
        self.parked = nil
        let by = openedBy
        _ = await load(parked.url, by: by ?? "")
        openedBy = by
    }

    /// Opens what the user typed: an address, or otherwise a search.
    func go(_ input: String) {
        guard let url = BrowserSearchEngine.address(input, engine: .current()) else { return }
        parked = nil
        openedBy = nil
        SessionBrowserOwner.shared.owner = nil
        webView.load(URLRequest(url: url))
    }

    /// Opens a page Nook's chat asked for, without waiting for it.
    func open(_ url: URL) {
        parked = nil
        openedBy = nil
        SessionBrowserOwner.shared.owner = nil
        lastError = nil
        webView.load(URLRequest(url: url))
    }

    /// Opens a page for an agent and waits (up to `timeout`) until it has loaded. Returns the error when it failed.
    func load(_ url: URL, by agent: String, timeout: TimeInterval = 15) async -> String? {
        parked = nil
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
        await restoreParked()
        guard webView.url != nil,
              let result = try? await webView.evaluateJavaScript("JSON.stringify(window.__nookConsole || [])"),
              let text = result as? String, let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    /// The visible part of the page as JPEG, at most `maxWidth` pixels wide.
    func screenshot(maxWidth: Int = 1280) async throws -> Data {
        await restoreParked()
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
        await restoreParked()
        guard let url = webView.url else { throw NookError(tr("workbench.browser.nothingOpen")) }
        let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        let text = ((result as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (webView.title ?? url.absoluteString, url.absoluteString, String(text.prefix(14_000)))
    }

    /// Runs an agent's script on the open page (see BridgeBrowserScript), first bringing back a page that was put away.
    func evaluate(_ script: String) async throws -> Any {
        await restoreParked()
        guard webView.url != nil else { throw NookError(tr("workbench.browser.nothingOpen")) }
        return try await webView.evaluateJavaScript(script) as Any
    }

    // MARK: Tools

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

    /// The tab was closed: its page goes and its web view stops.
    func discard() {
        parkTask?.cancel()
        parked = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The page's process crashed or was ended by macOS (memory pressure): the view would stay blank, so load the page
    /// again, at most once per ten seconds so a page that crashes on load does not loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        guard now.timeIntervalSince(lastCrashReload) > 10 else {
            lastError = tr("ws.browser.crashed")
            refresh(loading: false)
            return
        }
        lastCrashReload = now
        if webView.url != nil { webView.reload() } else if let url = URL(string: address) { webView.load(URLRequest(url: url)) }
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
/// Holds a web view that several places can show, such as the chat corner and the side panel. A web view can only be in
/// one of them: the place shown last has it, and a place that leaves the screen hands it back to the one shown before it.
/// Without that, a place on its way out (the corner card during its closing animation) could take the web view back
/// after the new place got it, and the page would go black once the card was gone.
private final class WebViewContainer: NSView {
    let webView: WKWebView
    /// The places showing each web view, oldest first.
    private static var hosts: [ObjectIdentifier: [WeakContainer]] = [:]
    private struct WeakContainer { weak var view: WebViewContainer? }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        // A page held at its size while a panel's line is dragged (`WebViewResize`) does not draw past the panel.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    private var key: ObjectIdentifier { ObjectIdentifier(webView) }

    /// Shown here now: this place is the newest, so it takes the web view.
    func claim() {
        var list = (Self.hosts[key] ?? []).filter { $0.view != nil && $0.view !== self }
        list.append(WeakContainer(view: self))
        Self.hosts[key] = list
        attach()
    }

    /// Takes the web view back unless a newer place has it, also one still being put on screen.
    func reclaimIfOrphaned() {
        guard webView.superview !== self, window != nil else { return }
        if let holder = webView.superview as? WebViewContainer, holder.isNewer(than: self) { return }
        attach()
    }

    private func isNewer(than other: WebViewContainer) -> Bool {
        let list = Self.hosts[key] ?? []
        guard let mine = list.firstIndex(where: { $0.view === self }) else { return false }
        guard let theirs = list.firstIndex(where: { $0.view === other }) else { return true }
        return mine > theirs
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // Put on screen (also a tab shown once more): this is now the place shown last.
            claim()
            return
        }
        // Off screen: the newest place still on screen gets the web view back.
        let list = (Self.hosts[key] ?? []).filter { $0.view != nil && $0.view !== self }
        Self.hosts[key] = list
        guard webView.superview === self, let next = list.last(where: { $0.view?.window != nil })?.view else { return }
        next.attach()
    }

    private func attach() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        // Sized here (`resizeSubviews`), not by its mask, so it can keep its size while a panel is dragged.
        webView.autoresizingMask = []
        addSubview(webView)
    }

    /// The web view fills the place, except while a panel's line is dragged: then it keeps its size, pinned to the top
    /// left, and only the place around it changes.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard webView.superview === self else { return super.resizeSubviews(withOldSize: oldSize) }
        // The window itself being resized by hand holds the page the same way a dragged panel line does.
        if window?.inLiveResize == true { WebViewResize.hold() }
        if WebViewResize.held {
            webView.setFrameOrigin(NSPoint(x: 0, y: bounds.height - webView.frame.height))
        } else {
            fit()
        }
    }

    private func fit() {
        if webView.frame != bounds { webView.frame = bounds }
    }

    /// Every web view on screen takes the size of its place again.
    static func fitAll() {
        for list in hosts.values {
            for host in list { if let view = host.view, view.webView.superview === view { view.fit() } }
        }
    }
}

/// Keeps web pages at their size while a panel's line is dragged (`PanelDrag`), and lays them out again when the line
/// rests a moment or is let go. A web view laid out on every frame of the drag relays the whole page in WebKit's own
/// process each time, which made dragging the side panel next to the browser stutter.
@MainActor
enum WebViewResize {
    private(set) static var held = false
    private static var settle: DispatchWorkItem?
    /// How long the line rests before the pages take their new size during the drag.
    private static let restSeconds = 0.18

    /// A drag step: pages keep their size until the line rests. Resting lets go of them too, so a drag that never
    /// reports its end cannot leave them held.
    static func hold() {
        held = true
        settle?.cancel()
        let work = DispatchWorkItem { release() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restSeconds, execute: work)
    }

    /// The drag ended: the pages take their size.
    static func release() {
        settle?.cancel()
        settle = nil
        guard held else { return }
        held = false
        WebViewContainer.fitAll()
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = WebViewContainer(webView: webView)
        container.claim()
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        (container as? WebViewContainer)?.reclaimIfOrphaned()
    }
}

/// Agents › Browser.
struct BrowserView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @State private var asking = false
    /// The pointer is on the address field, which shows its fill only then.
    @State private var addressHovering = false
    /// Shown beside the chat: a button that puts the browser away again.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // The page's own bar: back, forward and reload together, the address, then
            // what to do with the page.
            HStack(spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    ToolbarIconButton("chevron.left", tr("a11y.back"), enabled: store.canGoBack) { store.webView.goBack() }
                    ToolbarIconButton("chevron.right", tr("a11y.forward"), enabled: store.canGoForward) { store.webView.goForward() }
                    ToolbarIconButton(store.loading ? "xmark" : "arrow.clockwise", tr(store.loading ? "a11y.stopLoading" : "a11y.reload")) {
                        if store.loading { store.webView.stopLoading() } else { _ = store.webView.reload() }
                    }
                }
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: store.webView.url?.scheme == "https" ? "lock.fill" : "globe")
                        .font(NookTheme.font(9.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                    TextField(tr("workbench.browser.address"), text: $store.address)
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.paper)
                        .onSubmit { store.go(store.address) }
                }
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: SidePanelMetrics.toolbar)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                    .fill(addressHovering ? WS.subtle : .clear))
                .onHover { addressHovering = $0 }
                ToolbarIconButton("arrow.up.forward.app", tr("browser.openExternal"), enabled: store.webView.url != nil) {
                    store.openInDefaultBrowser()
                }
                ToolbarIconButton("plus.bubble", tr("workbench.browser.askHelp"), enabled: store.webView.url != nil && !asking) {
                    askAboutPage()
                }
                if let onClose {
                    SidePanelCloseButton(help: tr("embedded.close"), action: onClose)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            .frame(height: SidePanelMetrics.toolbar)
            if let agent = store.openedBy {
                HStack(spacing: NookTheme.Spacing.sm) {
                    AgentMark(agent: agent, account: nil, size: 12, ring: .clear)
                    Text(tr("bridge.browserBy", agent))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.bottom, NookTheme.Spacing.sm)
            }
            // A line only above a page; the empty browser runs on into the background.
            NookDivider()
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
            if store.webView.url == nil && !store.loading {
                WSEmptyState(symbol: "safari", title: tr("workbench.browser.emptyTitle"), message: tr("workbench.browser.emptyMessage"), action: nil)
            }
            // A container of its own for each tab: a container holds one web view.
            WebViewHost(webView: store.webView)
                .id(store.page.id)
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
        }
        // In view: whatever an agent opens here is seen, also while you watch.
        .onAppear {
            bridge.markBrowserSeen()
            store.shownInWorkbench += 1
            store.inSight()
            // The web view can only be in one place: here now, so the popup goes.
            BrowserPopup.shared.close()
        }
        .onDisappear {
            store.shownInWorkbench = max(0, store.shownInWorkbench - 1)
            if store.shownInWorkbench == 0, SessionBrowserOwner.shared.shownInChat == 0 { store.outOfSight() }
        }
        .onChange(of: bridge.unseen) { _, _ in bridge.markBrowserSeen() }
    }

    /// Hands the open page to the chat as an attachment, like dropping a file.
    private func askAboutPage() {
        asking = true
        Task {
            defer { asking = false }
            do {
                let page = try await store.pageText()
                // Each page gets a chat of its own, never the end of an older conversation.
                app.chat.startNew()
                app.attachText(name: page.title, text: "URL: \(page.url)\n\n\(page.text)")
                // The page stays in sight next to the chat, unless an app is open there already.
                if EmbeddedAppStore.shared.current == nil {
                    app.viewModel.terminalBesideChat = nil
                    app.viewModel.browserBesideChat = true
                }
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
    private var frameMemory: WindowFrameMemory?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let store = BrowserStore.shared
        guard store.shownInWorkbench == 0 else { return }
        if let panel, panel.isVisible { return }
        store.inSight()
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
        let frameMemory = WindowFrameMemory(window: panel, name: "NookBrowserPopup")
        if !frameMemory.restore(), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        self.frameMemory = frameMemory
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        if let store = BrowserStore.existing, store.shownInWorkbench == 0, SessionBrowserOwner.shared.shownInChat == 0 {
            store.outOfSight()
        }
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
            HStack(spacing: NookTheme.Spacing.md) {
                if let agent = store.openedBy {
                    AgentMark(agent: agent, account: nil, size: 14, ring: .clear)
                } else {
                    Image(systemName: "safari")
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.title.isEmpty ? tr("browser.popup.title") : store.title)
                        .font(NookTheme.TextStyle.strong)
                        .lineLimit(1)
                    Text(store.address)
                        .font(NookTheme.TextStyle.caption)
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
            WebViewHost(webView: store.webView).id(store.page.id)
        }
        .background(NookTheme.field)
        .ignoresSafeArea()
    }
}

/// Which session's agent opened the page in Nook's browser. That page shows small in the bottom right corner of that
/// session's chat (`SessionBrowserCorner`) and nowhere else: not in a window over every app, not in other chats. Its own
/// object, so a chat can watch it without starting the browser.
@MainActor
final class SessionBrowserOwner: ObservableObject {
    static let shared = SessionBrowserOwner()

    struct Owner: Equatable {
        /// The session Nook runs, when it is one.
        let run: UUID?
        /// Where the agent works; identifies a session Nook does not run.
        let directory: String
    }

    /// The session whose agent opened the current page; nil once you browse yourself or put the page away.
    @Published var owner: Owner?
    /// How many chats show the page in their corner now: while one does, the page is in sight and is not put away.
    var shownInChat = 0

    func opened(by caller: BridgeCaller) {
        switch caller.kind {
        case .run(let id): owner = Owner(run: id, directory: caller.directory)
        case .external: owner = Owner(run: nil, directory: caller.directory)
        }
    }

    /// Whether the session shown with `runID` in `directory` is the one whose agent opened the page.
    func owns(runID: UUID?, directory: String) -> Bool {
        guard let owner else { return false }
        if let run = owner.run, let runID { return run == runID }
        guard !owner.directory.isEmpty, !directory.isEmpty else { return false }
        return WorkspacePathPolicy.normalize(owner.directory) == WorkspacePathPolicy.normalize(directory)
    }
}

/// The page an agent opened, small in the bottom right corner of its own session's chat, just above the composer, so
/// you follow along without leaving the conversation. Only that session shows it; expanding opens the browser tab in the
/// side panel, the cross puts it away until the agent opens a page again.
struct SessionBrowserCorner: View {
    let runID: UUID?
    let directory: String
    /// The session shows the browser in a panel already.
    let hidden: Bool
    /// The room the card may move in, from its resting place: how far it can go left and up.
    var room: CGSize = CGSize(width: 10_000, height: 10_000)
    /// How far it can go down from its resting place above the composer, over the composer to the chat's bottom edge.
    var below: CGFloat = 0
    /// How far it can go right from its resting place, over the panels beside the chat to the row's edge.
    var right: CGFloat = 0
    let expand: () -> Void
    @ObservedObject private var owner = SessionBrowserOwner.shared
    /// Where you dragged the card to, from its corner; it keeps that while the chat is open.
    @State private var moved: CGSize = .zero
    @State private var dragStart: CGSize?

    private func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: min(right, max(-room.width, size.width)), height: min(below, max(-room.height, size.height)))
    }

    var body: some View {
        let shown = !hidden && owner.owns(runID: runID, directory: directory)
        ZStack(alignment: .bottomTrailing) {
            if shown {
                SessionBrowserCard(store: BrowserStore.shared, directory: directory, expand: expand, close: { owner.owner = nil },
                                   drag: { translation in
                    let start = dragStart ?? clamped(moved)
                    dragStart = start
                    moved = clamped(CGSize(width: start.width + translation.width, height: start.height + translation.height))
                }, dragEnded: { dragStart = nil })
                    // Clamped here too: a panel that closes takes the room the card was moved into with it.
                    .offset(clamped(moved))
                    .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(NookTheme.reveal, value: shown)
    }
}

struct SessionBrowserCard: View {
    @ObservedObject var store: BrowserStore
    let directory: String
    let expand: () -> Void
    let close: () -> Void
    /// Called while the header is dragged, with how far the pointer moved since the drag began.
    let drag: (CGSize) -> Void
    let dragEnded: () -> Void

    static let size = CGSize(width: 380, height: 260)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if let agent = store.openedBy {
                    AgentMark(agent: agent, account: nil, size: 12, ring: .clear)
                } else {
                    Image(systemName: "safari")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.title.isEmpty ? tr("browser.popup.title") : store.title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(store.address)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.loading { ProgressView().controlSize(.mini) }
                ToolbarIconButton("arrow.up.left.and.arrow.down.right", tr("browser.popup.expand"), expand)
                SidePanelCloseButton(help: tr("embedded.close"), action: close)
            }
            .padding(.leading, NookTheme.Spacing.md)
            .padding(.trailing, NookTheme.Spacing.xs)
            .frame(height: 34)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { drag($0.translation) }
                .onEnded { _ in dragEnded() })
            NookDivider()
            WebViewHost(webView: store.webView).id(store.page.id)
        }
        // Its usual size, narrower when the conversation it floats over is narrow (see `SessionTools`).
        .frame(maxWidth: Self.size.width)
        .frame(height: Self.size.height)
        .background(NookTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).stroke(NookTheme.fieldStroke, lineWidth: 1))
        .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
        .onAppear {
            SessionBrowserOwner.shared.shownInChat += 1
            store.inSight()
            // The web view can only be in one place: here now, so the popup goes.
            BrowserPopup.shared.close()
            WorkspaceBridge.shared.markSeen(directory, SessionTool.browser.rawValue)
        }
        .onDisappear {
            let owner = SessionBrowserOwner.shared
            owner.shownInChat = max(0, owner.shownInChat - 1)
            if owner.shownInChat == 0, store.shownInWorkbench == 0, !BrowserPopup.shared.isVisible { store.outOfSight() }
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
