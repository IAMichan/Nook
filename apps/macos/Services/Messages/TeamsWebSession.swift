import AppKit
import WebKit

/// Teams the way Nook links Instagram and LinkedIn: you sign in on teams.microsoft.com in a window of Nook's own, as in
/// your browser, and Nook takes the session token the Teams website itself sends when it reads your chats. No app of
/// Nook's in Microsoft Entra is needed. The website's sign-in stays in a store of its own on this Mac (not shared with
/// Safari or Nook's other windows); when the token is about to run out, the website is loaded again out of sight and
/// renews it by itself. The token is kept in the Keychain and only goes back to Teams' own chat service.
@MainActor
final class TeamsWebSession: NSObject, ObservableObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = TeamsWebSession()

    /// The session to read with; nil until you signed in, and again after signing out.
    @Published private(set) var session: TeamsWebData.Session?
    /// The sign-in window is open.
    @Published private(set) var isSigningIn = false
    /// Why the last sign-in did not link Teams, shown until the next one.
    @Published private(set) var problem: String?

    var isSignedIn: Bool { session != nil }

    private static let start = URL(string: "https://teams.microsoft.com/v2/")!
    private static let sessionAccount = "chats.teams.web.session"
    /// The website's own store, kept between launches so it stays signed in and can renew the token.
    private static let storeID = UUID(uuidString: "4E4F4F4B-5445-414D-5357-454253544F52")!
    private static let handler = "nookTeamsToken"

    private var window: NSWindow?
    private var web: WKWebView?
    private var onSignedIn: (() -> Void)?
    /// A renewal out of sight under way, and who waits for it.
    private var renewing: [CheckedContinuation<TeamsWebData.Session?, Never>] = []
    private var renewTimeout: Task<Void, Never>?
    /// Looks for the website's sign-in itself while the website is open, for when its requests come from where the
    /// script cannot see them (a worker of its own).
    private var watch: Timer?
    /// Tokens already offered to Teams' sign-in service, so each is asked once.
    private var tried: Set<String> = []

    override init() {
        super.init()
        if let json = CloudHelp.secret(Self.sessionAccount)?.data(using: .utf8) {
            session = try? JSONDecoder().decode(TeamsWebData.Session.self, from: json)
        }
    }

    /// Opens teams.microsoft.com to sign in; once the website reads your chats, its token is kept and the window closes.
    func signIn(title: String, onSignedIn: @escaping () -> Void) {
        close()
        self.onSignedIn = onSignedIn
        let web = makeWebView()
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
        problem = nil
        web.load(URLRequest(url: Self.start))
        startWatching()
    }

    /// A fresh token from the website, loaded out of sight with the sign-in it kept; nil when it is signed out there
    /// (only signing in again helps) or did not answer within a minute.
    func renew() async -> TeamsWebData.Session? {
        guard session != nil else { return nil }
        return await withCheckedContinuation { continuation in
            renewing.append(continuation)
            guard renewing.count == 1 else { return }
            let web = makeWebView()
            self.web = web
            web.load(URLRequest(url: Self.start))
            startWatching()
            renewTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.finishRenewing(nil)
            }
        }
    }

    /// Forgets the token and the website's sign-in on this Mac.
    func signOut() {
        close()
        session = nil
        Keychain.remove(Self.sessionAccount)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: Self.storeID) }
    }

    /// The token was refused (a 401): the next read renews it first.
    func expire() {
        guard var current = session else { return }
        current.expires = .distantPast
        session = current
    }

    /// Your name, once a message of yours says it.
    func named(_ name: String) {
        guard var current = session, current.name != name else { return }
        current.name = name
        keep(current)
    }

    // MARK: The website

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        configuration.applicationNameForUserAgent = Self.safariName
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: false))
        configuration.userContentController.add(TokenListener { [weak self] url, header in self?.heard(url: url, header: header) },
                                                name: Self.handler)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        web.navigationDelegate = self
        self.web = web
        return web
    }

    /// Present as the Safari on this Mac: without it Teams calls the web view an unsupported browser, and it also turns
    /// away Safari versions older than the latest two, so a fixed version would stop working after a macOS update.
    private static var safariName: String {
        let version = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }

    private func heard(url: String, header: String) {
        let found = url == "authz" ? ChatJSON.object(Data(header.utf8)).flatMap { TeamsWebData.session(authz: $0) }
            : TeamsWebData.session(url: url, header: header)
        if let found { take(found) }
    }

    private func take(_ found: TeamsWebData.Session) {
        var kept = found
        if let name = session?.name, session?.me == found.me { kept.name = name }
        keep(kept)
        if isSigningIn {
            let done = onSignedIn
            close()
            done?()
        }
        finishRenewing(kept)
    }

    private func startWatching() {
        watch?.invalidate()
        tried = []
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// The website's sign-in, found without its requests: the tokens for Teams' chat service it keeps in its storage
    /// and its `authtoken` cookie, each offered once to Teams' sign-in service for a session token.
    private func look() {
        guard let web else { return }
        Task {
            var tokens: [String] = []
            if let found = try? await web.evaluateJavaScript(Self.storedTokens) as? [String] { tokens += found }
            tokens += await Self.cookieTokens()
            await offer(tokens)
        }
    }

    private func offer(_ tokens: [String]) async {
        for token in tokens where !tried.contains(token) && TeamsWebData.isSpacesToken(token) {
            tried.insert(token)
            guard let found = await Self.authorize(token) else { continue }
            take(found)
            return
        }
    }

    private static func cookieTokens() async -> [String] {
        let cookies = await WKWebsiteDataStore(forIdentifier: storeID).httpCookieStore.allCookies()
        return cookies.filter { $0.name.lowercased() == "authtoken" }.compactMap { TeamsWebData.bearer(cookie: $0.value) }
    }

    /// Asks Teams' sign-in service, as the website does, for the session token that goes with a token of yours.
    private static func authorize(_ token: String) async -> TeamsWebData.Session? {
        var request = URLRequest(url: URL(string: "https://teams.microsoft.com/api/authsvc/v1.0/authz")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = Data()
        guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let json = ChatJSON.object(data) else { return nil }
        return TeamsWebData.session(authz: json)
    }

    private func keep(_ found: TeamsWebData.Session) {
        session = found
        problem = nil
        if let data = try? JSONEncoder().encode(found), let json = String(data: data, encoding: .utf8) {
            Keychain.write(json, account: Self.sessionAccount)
        }
    }

    private func finishRenewing(_ found: TeamsWebData.Session?) {
        guard !renewing.isEmpty else { return }
        renewTimeout?.cancel()
        renewTimeout = nil
        let waiting = renewing
        renewing = []
        if window == nil {
            watch?.invalidate()
            watch = nil
            dropWebView()
        }
        for continuation in waiting { continuation.resume(returning: found) }
    }

    private func close() {
        watch?.invalidate()
        watch = nil
        isSigningIn = false
        onSignedIn = nil
        if let window {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        window = nil
        if renewing.isEmpty { dropWebView() }
    }

    private func dropWebView() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        web = nil
    }

    /// Closed before Nook took over the sign-in: one more look in the website's cookies, and else why it did not link.
    func windowWillClose(_ notification: Notification) {
        window = nil
        isSigningIn = false
        let done = onSignedIn
        onSignedIn = nil
        watch?.invalidate()
        watch = nil
        if renewing.isEmpty { dropWebView() }
        let before = session
        Task {
            await offer(await Self.cookieTokens())
            if session != before {
                done?()
            } else if session == nil {
                problem = tr("chats.teams.web.notTaken")
            }
        }
    }

    /// The tokens the website keeps in its storage (as MSAL keeps them: JSON with the token as its "secret").
    private static let storedTokens = """
    (() => {
      const found = new Set();
      for (const store of [localStorage, sessionStorage]) {
        for (let index = 0; index < store.length; index++) {
          const value = store.getItem(store.key(index)) || '';
          if (!/spaces\\.skype\\.com/.test(value)) continue;
          for (const token of value.match(/eyJ[\\w-]+\\.eyJ[\\w-]+\\.[\\w-]+/g) || []) found.add(token);
        }
      }
      return Array.from(found).slice(0, 20);
    })();
    """

    /// Runs in the website before its own scripts: when it asks Teams' chat service for something (by fetch or
    /// XMLHttpRequest), the address and its session token go to Nook. Nothing else is looked at.
    private static let script = """
    (() => {
      const tell = (url, value) => {
        try {
          if (!/\\/api\\/chatsvc\\//.test(String(url)) || !/skypetoken|^bearer /i.test(String(value))) return;
          window.webkit.messageHandlers.\(handler).postMessage([String(url), String(value)]);
        } catch (error) {}
      };
      const pick = (name, value, url) => {
        const key = String(name).toLowerCase();
        if (key === 'authentication' || key === 'authorization') tell(url, value);
        if (key === 'x-skypetoken') tell(url, 'skypetoken=' + value);
      };
      const absolute = (url) => { try { return new URL(String(url), location.href).href; } catch (error) { return String(url); } };
      // Teams' sign-in service answers with the session token and the chat service of your region.
      const isAuthz = (url) => /\\/api\\/authsvc\\/v1\\.0\\/authz/.test(String(url));
      const answered = (text) => {
        try { if (/skypeToken/.test(String(text))) window.webkit.messageHandlers.\(handler).postMessage(['authz', String(text)]); } catch (error) {}
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__nookURL = absolute(url);
        if (isAuthz(this.__nookURL)) this.addEventListener('load', () => { try { answered(this.responseText); } catch (error) {} });
        return open.apply(this, arguments);
      };
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) { pick(name, value, this.__nookURL); return setHeader.call(this, name, value); };
      const nativeFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          const url = absolute(typeof input === 'string' ? input : (input && input.url) || '');
          const given = (init && init.headers) || (input && input.headers);
          if (given) new Headers(given).forEach((value, name) => pick(name, value, url));
        } catch (error) {}
        const answer = nativeFetch.apply(this, arguments);
        try {
          const url = absolute(typeof input === 'string' ? input : (input && input.url) || '');
          if (isAuthz(url)) answer.then((response) => response.clone().text()).then(answered, () => {});
        } catch (error) {}
        return answer;
      };
    })();
    """
}

/// Hands what the website sent to the session; the content controller keeps it, so it holds the session only through a
/// weak closure.
private final class TokenListener: NSObject, WKScriptMessageHandler {
    let heard: @MainActor (String, String) -> Void

    init(_ heard: @escaping @MainActor (String, String) -> Void) {
        self.heard = heard
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let pair = message.body as? [String], pair.count == 2 else { return }
        MainActor.assumeIsolated { heard(pair[0], pair[1]) }
    }
}
