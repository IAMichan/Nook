import AppKit
import WebKit

/// The window of a link's "sign in on the website" step: the app's own login page (instagram.com, messenger.com…) in a
/// fresh, private browser of its own. You sign in there as you always do; once the page says you are in and the cookies
/// the step asks for are there, they go to the chat service on this Mac (and nowhere else) and the window closes.
/// Closing it yourself stops the step.
@MainActor
final class ChatSignInWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private let step: ChatLinkData.Step
    private let onDone: ([String: String], String?) -> Void
    private let window: NSWindow
    private let web: WKWebView
    private var checking: Timer?
    private var finished = false
    /// A look at the cookies is under way: the timer and a page load must not hand them over twice.
    private var looking = false

    /// The one sign-in window open: a new one closes it, so none is ever left behind out of sight.
    private(set) static var current: ChatSignInWindow?

    /// Opens the sign-in window of `step`, closing any other one first.
    static func open(step: ChatLinkData.Step, title: String, onDone: @escaping ([String: String], String?) -> Void) {
        closeAll()
        let window = ChatSignInWindow(step: step, title: title, onDone: onDone)
        current = window
        window.show()
    }

    /// Closes the sign-in window, if one is open (the step finished, was stopped, or its sheet closed).
    static func closeAll() {
        current?.close()
        current = nil
    }
    /// The request headers the page sent that the step asks for (LinkedIn's), by lower-case name.
    private var headers: [String: String] = [:]

    init(step: ChatLinkData.Step, title: String, onDone: @escaping ([String: String], String?) -> Void) {
        self.step = step
        self.onDone = onDone
        let configuration = WKWebViewConfiguration()
        // Its own store, gone with the window: the sign-in lives in the chat service, not in Nook.
        configuration.websiteDataStore = .nonPersistent()
        let wanted: [String]
        if case .browser(_, _, _, _, let collect, _) = step { wanted = ChatLinkData.pageHeaders(collect) } else { wanted = [] }
        let listener = HeaderListener()
        if let script = Self.headerScript(wanted) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                                           forMainFrameOnly: false))
            configuration.userContentController.add(listener, name: Self.headerHandler)
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        listener.heard = { [weak self] name, value in self?.headers[name] = value }
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        web.navigationDelegate = self
        if case .browser(_, _, let url, let agent, _, _) = step {
            if let agent, !agent.isEmpty { web.customUserAgent = agent }
            web.load(URLRequest(url: url))
        }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The cookies can come in without a page load (a login that answers in the page itself): look every second.
        checking = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func close() {
        checking?.invalidate()
        checking = nil
        window.delegate = nil
        web.navigationDelegate = nil
        web.stopLoading()
        window.orderOut(nil)
        window.close()
        if Self.current === self { Self.current = nil }
    }

    func windowWillClose(_ notification: Notification) {
        checking?.invalidate()
        checking = nil
        if Self.current === self { Self.current = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await check() }
    }

    /// Hands over what the step asks for once you are signed in.
    private func check() async {
        guard !finished, !looking, case .browser(_, _, let start, _, let collect, let done) = step else { return }
        looking = true
        defer { looking = false }
        let address = web.url?.absoluteString ?? ""
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        // The store holds only this sign-in: every cookie in it may be asked for (Messenger signs in on facebook.com
        // too); one of the site the step started on wins over one of the same name elsewhere.
        var jar: [String: String] = [:]
        for cookie in cookies where !Self.belongs(cookie.domain, to: start) { jar[cookie.name] = cookie.value }
        for cookie in cookies where Self.belongs(cookie.domain, to: start) { jar[cookie.name] = cookie.value }
        let storage = await localStorage(collect.filter { $0.source == .localStorage }.map(\.name))
        let values = ChatLinkData.collected(collect, cookies: jar, storage: storage, headers: headers)
        guard ChatLinkData.hasCookies(collect, values: values) else { return }
        // A pattern for the page after signing in waits for it; without one the cookies are enough.
        if done != nil, !ChatLinkData.isDone(address, pattern: done) { return }
        finished = true
        onDone(values, address.isEmpty ? nil : address)
        close()
    }

    private static let headerHandler = "nookSignInHeaders"

    /// Runs in the website before its own scripts: when the page sets one of the request headers the step asks for (on
    /// a fetch or an XMLHttpRequest), its value goes to the window. Nothing else is looked at. The names go in as JSON,
    /// never as code.
    static func headerScript(_ names: [String]) -> String? {
        guard !names.isEmpty, let data = try? JSONSerialization.data(withJSONObject: names),
              let list = String(data: data, encoding: .utf8) else { return nil }
        return """
        (() => {
          const wanted = new Set(\(list));
          const tell = (name, value) => {
            const key = String(name).toLowerCase();
            if (!wanted.has(key) || !value) return;
            try { window.webkit.messageHandlers.\(headerHandler).postMessage([key, String(value)]); } catch (error) {}
          };
          const setHeader = XMLHttpRequest.prototype.setRequestHeader;
          XMLHttpRequest.prototype.setRequestHeader = function (name, value) { tell(name, value); return setHeader.call(this, name, value); };
          const nativeFetch = window.fetch;
          window.fetch = function (input, init) {
            try {
              const given = (init && init.headers) || (input && input.headers);
              if (given) new Headers(given).forEach((value, name) => tell(name, value));
            } catch (error) {}
            return nativeFetch.apply(this, arguments);
          };
        })();
        """
    }

    /// The local storage values the step asks for, by key.
    private func localStorage(_ keys: [String]) async -> [String: String] {
        guard !keys.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: keys),
              let list = String(data: data, encoding: .utf8) else { return [:] }
        let script = "JSON.stringify(Object.fromEntries(\(list).map(k => [k, localStorage.getItem(k) || ''])))"
        guard let answer = try? await web.evaluateJavaScript(script) as? String,
              let json = answer.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: String] else { return [:] }
        return json
    }

    /// A cookie of the site the step started on, or of a domain it belongs to (".instagram.com").
    private static func belongs(_ domain: String, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let bare = domain.lowercased().hasPrefix(".") ? String(domain.lowercased().dropFirst()) : domain.lowercased()
        let site = host.split(separator: ".").suffix(2).joined(separator: ".")
        return host == bare || host.hasSuffix("." + bare) || bare == site || bare.hasSuffix("." + site)
    }
}

/// Hands the request headers the sign-in page sent to its window; the content controller keeps it, so it holds the
/// window only through a weak closure.
private final class HeaderListener: NSObject, WKScriptMessageHandler {
    var heard: @MainActor (String, String) -> Void = { _, _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let pair = message.body as? [String], pair.count == 2 else { return }
        MainActor.assumeIsolated { heard(pair[0], pair[1]) }
    }
}
