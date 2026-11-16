import AppKit
import Combine
import WebKit

/// Snapchat the way Nook links Slack and Teams: you sign in on snapchat.com/web in a window of Nook's own, as in your
/// browser. Snapchat has no service another program may read your chats from, so after that the website stays open out
/// of sight, in a store of its own on this Mac (not shared with Safari or Nook's other windows), and Nook reads what it
/// shows with the scripts in `SnapchatWebData`. Nothing is taken from the website: its sign-in stays in that store.
/// One thing happens at a time in the page (reading the list, opening a chat, typing an answer). A whole web app is a
/// lot to keep running all day, so it is let go once nothing used it for a few minutes and while no one can see the
/// screen (`EnergyPlan.unseen`), and loaded again by the next read (`loaded()`).
@MainActor
final class SnapchatWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = SnapchatWebSession()

    /// You signed in once and did not sign out since; the website may still have signed you out (`read` says so).
    @Published private(set) var isSignedIn: Bool
    /// The sign-in window is open.
    @Published private(set) var isSigningIn = false

    private static let linkedKey = "chats.snapchat.web.linked"
    /// The website's own store, kept between launches.
    private static let storeID = UUID(uuidString: "4E4F4F4B-534E-4150-5357-454253544F52")!

    private var window: NSWindow?
    /// The website, in the sign-in window or out of sight; one for both, so signing in carries over.
    private var web: WKWebView?
    private var onSignedIn: (() -> Void)?
    private var watch: Timer?
    /// The work in the page now; the next waits for it.
    private var queue: Task<Void, Never>?
    /// How many of the works in `queue` have not finished yet: the website is only let go when none is left.
    private var pending = 0
    /// Lets the website go once it went unused for `idleAfter`.
    private var idle: Timer?
    private static let idleAfter: TimeInterval = 5 * 60
    /// The screen going dark or locking: the website is let go then.
    private var planWatch: AnyCancellable?

    enum Problem: LocalizedError {
        case signedOut
        case notFound(String)
        case page(String)
        case draft
        case notSent

        var errorDescription: String? {
            switch self {
            case .signedOut: return tr("chats.snapchat.signedOut")
            case .notFound(let name): return tr("chats.snapchat.notFound", name)
            case .page(let step): return tr("chats.snapchat.pageChanged", step)
            case .draft: return tr("chats.snapchat.draft")
            case .notSent: return tr("chats.snapchat.notSent")
            }
        }
    }

    override init() {
        isSignedIn = UserDefaults.standard.bool(forKey: Self.linkedKey)
        super.init()
        planWatch = EnergyMonitor.shared.$plan.map(\.unseen).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] unseen in
                if unseen { self?.releaseIfIdle() }
            }
    }

    // MARK: Signing in

    /// Opens snapchat.com/web to sign in; once it shows your chats, the window closes and the website stays open out
    /// of sight.
    func signIn(title: String, onSignedIn: @escaping () -> Void) {
        closeWindow()
        self.onSignedIn = onSignedIn
        let web = self.web ?? makeWebView()
        self.web = web
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        isSigningIn = true
        web.load(URLRequest(url: SnapchatWebData.start))
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// Forgets the sign-in, here and in the website's store on this Mac.
    func signOut() {
        closeWindow()
        dropWebView()
        setSignedIn(false)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: Self.storeID) }
    }

    /// Whether the website in the sign-in window shows your chats yet.
    private func look() {
        guard isSigningIn, let web, SnapchatWebData.isChatPage(web.url) else { return }
        Task {
            guard case .chats(_) = SnapchatWebData.listOutcome(try? await web.callAsyncJavaScript(
                SnapchatWebData.listScript, arguments: [:], contentWorld: .defaultClient)) else { return }
            guard isSigningIn else { return }
            setSignedIn(true)
            let done = onSignedIn
            closeWindow()
            done?()
        }
    }

    private func setSignedIn(_ value: Bool) {
        isSignedIn = value
        UserDefaults.standard.set(value, forKey: Self.linkedKey)
    }

    // MARK: Reading and typing

    /// The chat list as the website shows it now.
    func list() async throws -> [SnapchatWebData.Row] {
        try await serially { web in
            for _ in 0..<20 {
                switch SnapchatWebData.listOutcome(try? await self.run(SnapchatWebData.listScript, in: web)) {
                case .chats(let rows): return rows
                case .signedOut: throw self.signedOut()
                case .failed(let step): throw Problem.page(step)
                case .waiting: try await Task.sleep(for: .seconds(1))
                }
            }
            // Signed in, but no chat in the list: a new account, or one that cleared them all.
            return []
        }
    }

    /// The messages of a chat, oldest first, after opening it as a click in the list does. Snapchat counts that as
    /// you opening it, as on your phone. `pictures` names the pictures among them to save (by their `source`): those
    /// are read from the page while the chat is still open, as JPEG or PNG bytes by source.
    func read(_ row: SnapchatWebData.Row, pictures: @escaping @MainActor ([SnapchatWebData.Line]) -> [String] = { _ in [] })
        async throws -> (lines: [SnapchatWebData.Line], pictures: [String: Data]) {
        try await serially { web in
            try await self.open(row, in: web)
            var last: [SnapchatWebData.Line]?
            // The chat is in once two reads a moment apart agree.
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(700))
                switch SnapchatWebData.readOutcome(try? await self.run(SnapchatWebData.readScript, in: web)) {
                case .lines(let lines):
                    if lines == last { return (lines, await self.pictures(pictures(lines), in: web)) }
                    last = lines
                case .signedOut: throw self.signedOut()
                case .noChat: continue
                case .failed(let step): throw Problem.page(step)
                }
            }
            guard let last else { throw Problem.page("chat") }
            return (last, await self.pictures(pictures(last), in: web))
        }
    }

    /// The pictures at these addresses in the open chat (`SnapchatWebData.picturesScript`), by address.
    private func pictures(_ sources: [String], in web: WKWebView) async -> [String: Data] {
        guard !sources.isEmpty,
              let answer = try? await web.callAsyncJavaScript(SnapchatWebData.picturesScript, arguments: ["sources": sources],
                                                              contentWorld: .defaultClient) as? [String: Any] else { return [:] }
        return answer.reduce(into: [:]) { found, entry in
            if let url = entry.value as? String, let data = SnapchatWebData.pictureData(url) { found[entry.key] = data }
        }
    }

    /// Sends a picture (with its caption) in the chat, as you would on the website; after your own click in Nook.
    func sendPicture(_ data: Data, name: String, type: String, caption: String, to row: SnapchatWebData.Row) async throws {
        let encoded = data.base64EncodedString()
        try await serially { web in
            try await self.open(row, in: web)
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(500))
                let answer = try? await web.callAsyncJavaScript(
                    SnapchatWebData.sendPictureScript,
                    arguments: ["data": encoded, "name": name, "type": type,
                                "caption": String(caption.prefix(SnapchatWebData.maxText))],
                    contentWorld: .defaultClient)
                switch SnapchatWebData.sendOutcome(answer) {
                case .sent: return
                case .noChat: continue
                case .signedOut: throw self.signedOut()
                case .draft: throw Problem.draft
                case .notSent: throw Problem.notSent
                case .failed(let step): throw Problem.page(step)
                }
            }
            throw Problem.page("field")
        }
    }

    /// Types `text` into the chat and sends it, as you would; after your own click in Nook.
    func send(_ text: String, to row: SnapchatWebData.Row) async throws {
        try await serially { web in
            try await self.open(row, in: web)
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(500))
                let answer = try? await web.callAsyncJavaScript(SnapchatWebData.sendScript,
                                                                arguments: ["text": String(text.prefix(SnapchatWebData.maxText))],
                                                                contentWorld: .defaultClient)
                switch SnapchatWebData.sendOutcome(answer) {
                case .sent: return
                case .noChat: continue
                case .signedOut: throw self.signedOut()
                case .draft: throw Problem.draft
                case .notSent: throw Problem.notSent
                case .failed(let step): throw Problem.page(step)
                }
            }
            throw Problem.page("field")
        }
    }

    private func open(_ row: SnapchatWebData.Row, in web: WKWebView) async throws {
        let id = row.id == row.name ? "" : row.id
        let answer = try? await web.callAsyncJavaScript(SnapchatWebData.openScript, arguments: ["id": id, "name": row.name],
                                                        contentWorld: .defaultClient)
        guard let status = (answer as? [String: Any])?["status"] as? String else { throw Problem.page("open") }
        switch status {
        case "opened": return
        case "signedOut": throw signedOut()
        default: throw Problem.notFound(row.name)
        }
    }

    private func run(_ script: String, in web: WKWebView) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], contentWorld: .defaultClient)
    }

    /// Signed out on the website: Nook stops reading until you sign in again.
    private func signedOut() -> Problem {
        setSignedIn(false)
        dropWebView()
        return .signedOut
    }

    /// Runs `work` in the website once the work before it is done, loading the website out of sight first when it is
    /// not open.
    private func serially<T: Sendable>(_ work: @escaping @MainActor (WKWebView) async throws -> T) async throws -> T {
        let before = queue
        pending += 1
        idle?.invalidate()
        idle = nil
        let task = Task { @MainActor () -> Result<T, Error> in
            await before?.value
            defer {
                self.pending -= 1
                self.armIdleRelease()
            }
            do {
                guard self.isSignedIn else { throw Problem.signedOut }
                return .success(try await work(try await self.loaded()))
            } catch {
                return .failure(error)
            }
        }
        queue = Task { _ = await task.value }
        return try await task.value.get()
    }

    /// The website, open and on the chat page.
    private func loaded() async throws -> WKWebView {
        if let web, SnapchatWebData.isChatPage(web.url), !web.isLoading { return web }
        let web = self.web ?? makeWebView()
        self.web = web
        if !SnapchatWebData.isChatPage(web.url) { web.load(URLRequest(url: SnapchatWebData.start)) }
        var waited = 0
        while web.isLoading || web.url == nil, waited < 30 {
            try await Task.sleep(for: .seconds(1))
            waited += 1
        }
        guard SnapchatWebData.isChatPage(web.url) else { throw signedOut() }
        return web
    }

    // MARK: The website

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addGoogleSignInHelp()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        configuration.applicationNameForUserAgent = Self.safariName
        // Out of sight the website keeps running, so its list stays current between reads.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        return web
    }

    /// Present as the Safari on this Mac: Snapchat for Web turns away browsers it does not know.
    private static var safariName: String {
        let version = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // Links to the Snapchat app ("snapchat://…") stay out of this window.
        guard url.scheme == "https" || url.scheme == "about" || url.scheme == "blob" else { return .cancel }
        // Signing in with Google needs the window to call itself Firefox there.
        if webView.presentsItself(for: navigationAction, otherwise: nil) { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        look()
    }

    /// A window the website opens of its own (signing in with Google or Apple) opens in the same one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// Closes the sign-in window; the website itself stays open out of sight while you are signed in.
    private func closeWindow() {
        isSigningIn = false
        onSignedIn = nil
        watch?.invalidate()
        watch = nil
        if let window {
            window.delegate = nil
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        window = nil
        if !isSignedIn { dropWebView() }
    }

    /// Lets the website go after `idleAfter` without work, when it is open out of sight.
    private func armIdleRelease() {
        idle?.invalidate()
        idle = nil
        guard pending == 0, web != nil, window == nil else { return }
        // Work asked for while no one can see the screen (opening a chat from a notification): let go right after.
        if EnergyMonitor.shared.plan.unseen { releaseIfIdle(); return }
        idle = Timer.scheduledTimer(withTimeInterval: Self.idleAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseIfIdle() }
        }
        idle?.tolerance = 30
    }

    /// Lets the website out of sight go when no work waits for it; the sign-in window keeps its own. The sign-in itself
    /// stays in the website's store, so the next read only loads the page again.
    private func releaseIfIdle() {
        idle?.invalidate()
        idle = nil
        guard pending == 0, !isSigningIn, window == nil, web != nil else { return }
        dropWebView()
    }

    private func dropWebView() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        closeWindow()
    }
}
