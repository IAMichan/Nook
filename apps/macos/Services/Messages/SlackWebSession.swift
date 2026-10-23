import AppKit
import WebKit

/// Slack the way Nook links Teams: you sign in on slack.com in a window of Nook's own, as in your browser, and Nook
/// takes the sign-in Slack's web client keeps (its token and the `d` cookie it works with). No app of your own in
/// Slack and no token to paste. The website's sign-in stays in a store of its own on this Mac (not shared with Safari
/// or Nook's other windows); what Nook took is kept in the Keychain and only goes back to Slack.
@MainActor
final class SlackWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = SlackWebSession()

    /// The sign-in to read with; nil until you signed in, and again after signing out.
    @Published private(set) var auth: SlackData.Auth?
    /// The sign-in window is open.
    @Published private(set) var isSigningIn = false

    var isSignedIn: Bool { auth != nil }

    private static let start = URL(string: "https://app.slack.com/client")!
    private static let authAccount = "chats.slack.web.session"
    /// The website's own store, kept between launches.
    private static let storeID = UUID(uuidString: "4E4F4F4B-534C-4143-4B57-454253544F52")!

    private var window: NSWindow?
    private var web: WKWebView?
    private var onSignedIn: (() -> Void)?
    /// Looks for the sign-in while the window is open: Slack's web client sets it up after the page loaded.
    private var watch: Timer?

    override init() {
        super.init()
        if let json = CloudHelp.secret(Self.authAccount)?.data(using: .utf8) {
            auth = try? JSONDecoder().decode(SlackData.Auth.self, from: json)
        }
    }

    /// Opens slack.com to sign in; once Slack's web client is signed in, its sign-in is kept and the window closes.
    func signIn(title: String, onSignedIn: @escaping () -> Void) {
        close()
        self.onSignedIn = onSignedIn
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        configuration.applicationNameForUserAgent = Self.safariName
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
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
        web.load(URLRequest(url: Self.start))
        watch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// Forgets the sign-in, here and in the website's store on this Mac.
    func signOut() {
        close()
        auth = nil
        Keychain.remove(Self.authAccount)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: Self.storeID) }
    }

    // MARK: The website

    /// Present as the Safari on this Mac: Slack's web client turns away browsers it does not know.
    private static var safariName: String {
        let version = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }

    /// Whether Slack's web client is signed in yet: its token in local storage on app.slack.com, its cookie in the store.
    private func look() {
        guard let web, web.url?.host == Self.start.host else { return }
        Task {
            guard let config = try? await web.evaluateJavaScript("localStorage.getItem('localConfig_v2')") as? String,
                  config.contains("xoxc-") else { return }
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            let cookie = cookies.first { $0.name == "d" && $0.domain.hasSuffix("slack.com") }?.value
            guard let found = SlackData.webAuth(localConfig: config, cookie: cookie) else { return }
            signedIn(found)
        }
    }

    private func signedIn(_ found: SlackData.Auth) {
        guard isSigningIn else { return }
        auth = found
        if let data = try? JSONEncoder().encode(found), let json = String(data: data, encoding: .utf8) {
            Keychain.write(json, account: Self.authAccount)
        }
        let done = onSignedIn
        close()
        done?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // Slack's links to its Mac app ("slack://…") stay out of this window.
        guard url.scheme == "https" || url.scheme == "about" || url.scheme == "blob" else { return .cancel }
        // After signing in, Slack offers to open its Mac app; go on to the web client instead.
        if navigationAction.targetFrame?.isMainFrame == true, url.path.hasPrefix("/ssb/redirect") {
            webView.load(URLRequest(url: Self.start))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        look()
    }

    /// Signing in with Google or Apple opens a window of its own on the web; here it opens in the same one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    private func close() {
        isSigningIn = false
        onSignedIn = nil
        watch?.invalidate()
        watch = nil
        if let window {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        window = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        close()
    }
}
