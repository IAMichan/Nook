import Foundation
import AppKit
import WebKit

/// Your Instagram direct messages, read and sent the way Beeper does it: you sign in once on instagram.com inside Nook
/// (Settings › Chats › Instagram › Log in, which opens Instagram beside the chat), and Nook then asks Instagram's own web
/// API with that sign-in, every half minute. The requests run in a small instagram.com page Nook keeps out of sight, on
/// the same cookies as Instagram beside the chat, so the sign-in stays in Nook's own store on this Mac and only ever
/// goes to instagram.com. Signing out (here, or "Forget" on Instagram beside the chat) removes it.
@MainActor
final class InstagramBridge: ObservableObject, ChatBridge {
    let app = "instagram"
    let interval: TimeInterval = 30

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

    /// The page the requests run in: instagram.com's own, but light, so no website runs out of sight.
    private static let requestPage = URL(string: "https://www.instagram.com/robots.txt")!

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
        page = nil
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
            let threads = InstagramData.threads(try await call(InstagramData.inboxPath))
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
        const headers = { 'X-IG-App-ID': appID, 'X-CSRFToken': csrf, 'X-Requested-With': 'XMLHttpRequest',
                          'X-ASBD-ID': '129477', 'X-IG-WWW-Claim': '0', 'Accept': 'application/json' };
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

    /// The instagram.com page the requests run in, loaded once.
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
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            page = view
        }
        view.load(URLRequest(url: Self.requestPage))
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
}
