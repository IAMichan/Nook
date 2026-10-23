import Foundation
import AppKit
import WebKit

/// Your Instagram direct messages, read and sent the way Beeper does it: you sign in once on instagram.com inside Nook
/// (Settings › Chats › Instagram › Log in, which opens Instagram beside the chat), and Nook then asks Instagram's own web
/// API with that sign-in, every half minute. The requests run in Instagram's inbox page, which Nook keeps out of sight on
/// the same cookies as Instagram beside the chat, so the sign-in stays in Nook's own store on this Mac and only ever
/// goes to instagram.com. Signing out (here, or "Forget" on Instagram beside the chat) removes it.
///
/// Instagram's inbox page keeps its own live line open (a WebSocket). Nook does not read what comes over it; it only
/// notices that something came (`liveScript`) and reads the inbox right away, so a new message shows within a second or
/// two. While that line is open the half-minute read becomes a slow check for what it may have missed.
@MainActor
final class InstagramBridge: ObservableObject, ChatBridge {
    let app = "instagram"
    var interval: TimeInterval { isLive ? 300 : 30 }

    /// Instagram's own live line in its page is open: a change makes Nook read at once (`onChange`).
    private(set) var isLive = false
    /// Something came in on the live line: read now, not at the next turn.
    var onChange: () -> Void = {}
    private var lastLiveRead = Date.distantPast
    private var laterRead: Task<Void, Never>?

    enum State: Equatable {
        case signedOut
        /// Instagram is open beside the chat and Nook waits until you signed in there.
        case waiting
        case signedIn
    }

    @Published private(set) var state: State
    private(set) var isWorking = false
    var isReady: Bool { state == .signedIn }

    /// Called once the sign-in you started from Instagram's row is noticed, so the chats come in right away.
    var onSignedIn: () -> Void = {}

    private static let signedInKey = "chats.instagram.signedIn"
    /// The newest activity per thread at the last read: only threads that moved are brought again.
    private var seen: [String: Date] = [:]
    /// Instagram's id of every thread by its name in Nook: where what you send from Nook goes.
    private var threadIDs: [String: String] = [:]
    private var page: WKWebView?
    private var watching: Task<Void, Never>?


    init() {
        state = UserDefaults.standard.bool(forKey: Self.signedInKey) ? .signedIn : .signedOut
        Task { await refresh() }
    }

    private var webApp: EmbeddedApp? { EmbeddedAppCatalog.all.first { $0.id == app } }
    private var store: WKWebsiteDataStore? { webApp.map(EmbeddedAppStore.dataStore(for:)) }

    // MARK: Signing in

    /// The CSRF token from Nook's instagram.com store, while its session cookie is there; nil while signed out.
    private func csrfToken() async -> String? {
        guard let store else { return nil }
        let cookies = await store.httpCookieStore.allCookies()
        guard cookies.contains(where: { InstagramData.isSession(name: $0.name, domain: $0.domain, value: $0.value) }) else { return nil }
        let csrf = cookies.first { $0.name == "csrftoken" && InstagramData.isInstagram($0.domain) }?.value ?? ""
        return csrf
    }

    /// Whether the sign-in is still there; a sign-in made elsewhere in Nook (Instagram beside the chat) counts too. It
    /// only shows: switching Instagram on is up to you, or to logging in from its row.
    func refresh() async {
        guard state != .waiting else { return }
        let signedIn = await csrfToken() != nil
        if signedIn != (state == .signedIn) { setSignedIn(signedIn) }
    }

    /// Waits while you sign in on Instagram beside the chat, for a quarter of an hour at most.
    func watchSignIn() {
        watching?.cancel()
        state = .waiting
        watching = Task {
            let end = Date().addingTimeInterval(15 * 60)
            while Date() < end, !Task.isCancelled {
                if await csrfToken() != nil {
                    setSignedIn(true)
                    onSignedIn()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if !Task.isCancelled, state == .waiting { state = .signedOut }
        }
    }

    func cancelSignIn() {
        watching?.cancel()
        watching = nil
        if state == .waiting { state = .signedOut }
    }

    /// Signs out of Instagram in Nook: its cookies go, and so does Instagram beside the chat's sign-in, which is the
    /// same one. The chats it brought stay until they grow old.
    func signOut() async {
        cancelSignIn()
        forgotten()
        guard let store else { return }
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    /// The sign-in went (Instagram beside the chat was forgotten): Nook lets go of its page and stops reading.
    func forgotten() {
        page?.stopLoading()
        page?.configuration.userContentController.removeScriptMessageHandler(forName: Self.liveHandler)
        page = nil
        isLive = false
        laterRead?.cancel()
        laterRead = nil
        seen = [:]
        threadIDs = [:]
        isWorking = false
        setSignedIn(false)
    }

    private func setSignedIn(_ on: Bool) {
        watching?.cancel()
        watching = nil
        state = on ? .signedIn : .signedOut
        UserDefaults.standard.set(on, forKey: Self.signedInKey)
        if !on { seen = [:] }
    }

    // MARK: ChatBridge

    func read() async throws -> [BridgedChat] {
        guard isReady else { isWorking = false; return [] }
        do {
            let inbox = try await call(InstagramData.inboxPath)
            // An answer without an inbox is one Nook does not understand: say so, rather than show no chats at all.
            guard InstagramData.hasInbox(inbox) else { throw NookError(tr("chats.instagram.refused", InstagramData.summary(inbox))) }
            let threads = InstagramData.threads(inbox)
            var result: [BridgedChat] = []
            for thread in threads {
                threadIDs[thread.name] = thread.id
                guard thread.last.map({ seen[thread.id] != $0 }) ?? (seen[thread.id] == nil) else { continue }
                seen[thread.id] = thread.last ?? .distantPast
                guard !thread.messages.isEmpty else { continue }
                result.append(BridgedChat(app: app, name: thread.name, messages: thread.messages, unread: thread.unread,
                                          members: thread.isGroup ? thread.members : nil))
            }
            isWorking = true
            return result
        } catch {
            isWorking = false
            throw error
        }
    }

    // MARK: Sending

    /// Instagram's id of the thread Nook shows as `name`, once a read brought it in.
    func threadID(named name: String) -> String? {
        isReady ? threadIDs[name] : nil
    }

    /// Sends what you typed to a thread, as the website does. The thread shows it at the next read, which comes right
    /// away. Throws with a sentence you can act on.
    func send(text: String, to thread: String) async throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard message.count <= InstagramData.maxText else { throw NookError(tr("chats.instagram.tooLong", InstagramData.maxText)) }
        let form = InstagramData.sendForm(thread: thread, text: message, context: InstagramData.newContext())
        _ = try await call(InstagramData.sendPath, body: InstagramData.form(form))
        seen[thread] = nil
    }

    // MARK: Requests

    /// One request to Instagram's API (a GET, or a POST of a form), made inside Nook's own instagram.com page with its
    /// sign-in; the answer as JSON. A sign-in Instagram no longer accepts signs Nook out, so the row asks to log in.
    private func call(_ path: String, body: String? = nil) async throws -> [String: Any] {
        guard let csrf = await csrfToken() else {
            forgotten()
            throw NookError(tr("chats.instagram.signedOut"), kind: .auth)
        }
        let page = try await requestPage()
        let script = """
        // What the website itself sends with each request, the claim it keeps for this session included.
        let claim = '0';
        try { claim = sessionStorage.getItem('www-claim-v2') || '0'; } catch (error) {}
        const headers = { 'X-IG-App-ID': appID, 'X-CSRFToken': csrf, 'X-Requested-With': 'XMLHttpRequest',
                          'X-ASBD-ID': '129477', 'X-IG-WWW-Claim': claim, 'Accept': '*/*' };
        if (body !== null) headers['Content-Type'] = 'application/x-www-form-urlencoded';
        const response = await fetch(path, { method: body === null ? 'GET' : 'POST', headers, credentials: 'include',
                                              body: body === null ? undefined : body });
        return { status: response.status, url: response.url, body: await response.text() };
        """
        // The path, the form and the token go in as arguments, never into the script's source.
        let raw = try await page.callAsyncJavaScript(script, arguments: [
            "path": path, "body": body ?? NSNull(), "csrf": csrf, "appID": InstagramData.appID,
        ], in: nil, contentWorld: .defaultClient)
        guard let answer = raw as? [String: Any] else { throw NookError(tr("chats.instagram.refused", "answer")) }
        do {
            return try InstagramData.check(status: (answer["status"] as? NSNumber)?.intValue ?? 0,
                                           url: (answer["url"] as? String) ?? "", body: (answer["body"] as? String) ?? "")
        } catch let error as NookError where error.kind == .auth && error.message == tr("chats.instagram.signedOut") {
            forgotten()
            throw error
        }
    }

    /// The page the requests run in, loaded once: Instagram's own inbox, so they come from where the website makes them.
    private func requestPage() async throws -> WKWebView {
        if let page, page.url?.host?.hasSuffix("instagram.com") == true, !page.isLoading { return page }
        guard let store else { throw NookError(tr("chats.instagram.signedOut"), kind: .auth) }
        let view: WKWebView
        if let page {
            view = page
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            // The same browser as Instagram beside the chat, and not put to sleep while out of sight.
            configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
            configuration.preferences.inactiveSchedulingPolicy = .none
            configuration.userContentController.addUserScript(WKUserScript(source: Self.liveScript, injectionTime: .atDocumentStart,
                                                                           forMainFrameOnly: true))
            configuration.userContentController.add(LiveListener { [weak self] signal in self?.heard(signal) }, name: Self.liveHandler)
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            page = view
        }
        view.load(URLRequest(url: InstagramData.site))
        // The load starts a moment after it is asked for: until then the view still holds the page before.
        try await Task.sleep(nanoseconds: 500_000_000)
        let end = Date().addingTimeInterval(20)
        while view.isLoading || view.url == nil, Date() < end {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard view.url?.host?.hasSuffix("instagram.com") == true, !view.isLoading else {
            throw NookError(tr("chats.instagram.unreachable"))
        }
        return view
    }

    // MARK: Live line

    private static let liveHandler = "nookInstagramLive"

    /// Runs in Instagram's page before its own scripts: every WebSocket the page opens to its chat servers tells Nook when
    /// it opens, closes, and when something comes in (once per short burst; keep-alive pings of a few bytes left out).
    /// Nothing that came in is passed on: only that something did.
    static let liveScript = """
    (() => {
      const Native = window.WebSocket;
      if (!Native || Native.nookWatched) return;
      const tell = (signal) => { try { window.webkit.messageHandlers.\(liveHandler).postMessage(signal); } catch (error) {} };
      let pending = null;
      const changed = () => { if (pending === null) pending = setTimeout(() => { pending = null; tell('changed'); }, 600); };
      const size = (data) => typeof data === 'string' ? data.length : (data && (data.byteLength ?? data.size)) || 0;
      function Watched(url, protocols) {
        const socket = protocols === undefined ? new Native(url) : new Native(url, protocols);
        if (/edge-chat|lightspeed|realtime|mqtt/i.test(String(url))) {
          socket.addEventListener('open', () => tell('open'));
          socket.addEventListener('close', () => tell('close'));
          socket.addEventListener('message', (message) => { if (size(message.data) > 8) changed(); });
        }
        return socket;
      }
      Watched.prototype = Native.prototype;
      Object.assign(Watched, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3, nookWatched: true });
      window.WebSocket = Watched;
    })();
    """

    private func heard(_ signal: String) {
        switch signal {
        case "open":
            isLive = true
        case "close":
            isLive = false
            onChange()
        case "changed":
            // A busy chat sends bursts: one read every few seconds keeps up, and the last of a burst is never dropped.
            let wait = 3 - Date().timeIntervalSince(lastLiveRead)
            guard wait > 0 else {
                lastLiveRead = Date()
                onChange()
                return
            }
            guard laterRead == nil else { return }
            laterRead = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.laterRead = nil
                self.lastLiveRead = Date()
                self.onChange()
            }
        default:
            break
        }
    }
}

/// Hands the live line's signals from Instagram's page to the bridge. The page's content controller keeps it, so it
/// holds the bridge only weakly through its closure.
private final class LiveListener: NSObject, WKScriptMessageHandler {
    private let heard: @MainActor (String) -> Void

    init(_ heard: @escaping @MainActor (String) -> Void) {
        self.heard = heard
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let signal = message.body as? String else { return }
        MainActor.assumeIsolated { heard(signal) }
    }
}
