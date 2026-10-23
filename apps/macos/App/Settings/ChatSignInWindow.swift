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

    init(step: ChatLinkData.Step, title: String, onDone: @escaping ([String: String], String?) -> Void) {
        self.step = step
        self.onDone = onDone
        let configuration = WKWebViewConfiguration()
        // Its own store, gone with the window: the sign-in lives in the chat service, not in Nook.
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
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
        window.orderOut(nil)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        checking?.invalidate()
        checking = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await check() }
    }

    /// Hands over what the step asks for once you are signed in.
    private func check() async {
        guard !finished, case .browser(_, _, let start, _, let collect, let done) = step else { return }
        let address = web.url?.absoluteString ?? ""
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        // The store holds only this sign-in: every cookie in it may be asked for (Messenger signs in on facebook.com
        // too); one of the site the step started on wins over one of the same name elsewhere.
        var jar: [String: String] = [:]
        for cookie in cookies where !Self.belongs(cookie.domain, to: start) { jar[cookie.name] = cookie.value }
        for cookie in cookies where Self.belongs(cookie.domain, to: start) { jar[cookie.name] = cookie.value }
        let storage = await localStorage(collect.filter { $0.source == .localStorage }.map(\.name))
        let values = ChatLinkData.collected(collect, cookies: jar, storage: storage)
        guard ChatLinkData.hasCookies(collect, values: values) else { return }
        // A pattern for the page after signing in waits for it; without one the cookies are enough.
        if done != nil, !ChatLinkData.isDone(address, pattern: done) { return }
        finished = true
        onDone(values, address.isEmpty ? nil : address)
        close()
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
