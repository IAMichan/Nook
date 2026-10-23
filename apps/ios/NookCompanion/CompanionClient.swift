import Foundation
import Network
import UIKit
import UserNotifications

/// The phone's side: one short connection per request (connect, send a sealed request, read the sealed answer, close).
/// While the app is in front it asks for the list every few seconds; nothing runs in the background.
@MainActor
final class CompanionClient: ObservableObject {
    static let shared = CompanionClient()

    enum Phase: Equatable {
        case unpaired
        case pairing
        case connected
        case offline(String)
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sessions: [SessionDigest] = []
    @Published private(set) var macName = ""
    @Published var notice: String?
    /// Set when a notification was tapped: the session to open.
    @Published var openSession: String?
    /// The session whose screen is open, so a push about it arrives without a banner.
    var visibleSession: String?
    /// A `nook://prompt` link that was opened: the New session sheet shows with its text.
    @Published var pendingPrompt: PromptLink?
    /// Whether the Mac has push set up (answer to the last `register`), nil while unknown.
    @Published private(set) var macPushReady: Bool?
    /// `CompanionFeature` values the Mac understands; empty for a Mac that only answers what waits.
    @Published private(set) var features: Set<String> = []
    /// What a new session can start with, once asked.
    @Published private(set) var launchOptions: LaunchOptions?
    /// The conversation of each session that was opened, by session id.
    @Published private(set) var timelines: [String: [TimelineEntry]] = [:]
    /// Nook's own chats, and the messages of each one that was opened.
    @Published private(set) var conversations: [ChatDigest] = []
    @Published private(set) var chatLines: [String: [ChatLine]] = [:]
    /// False when the Mac said Nook has no brain set up, so chatting cannot work yet.
    @Published private(set) var brainReady = true
    /// Nook's home (what waits, agenda, player, limits) and the usage page, once asked.
    @Published private(set) var home: HomeDigest?
    @Published private(set) var usage: UsageDigest?
    /// The Mac's Chats tab: every chat app in one inbox, and the messages of each chat that was opened, by chat id.
    @Published private(set) var inbox: [InboxChatDigest] = []
    @Published private(set) var inboxLines: [String: [InboxLine]] = [:]
    /// Unread messages in every chat, for the badge on the Chats tab.
    var inboxUnread: Int { inbox.reduce(0) { $0 + $1.unread } }
    /// Why the inbox may be empty: "chatsoff" (nothing is collected on the Mac) or "chatsaccess" (macOS does not let
    /// Nook read the notifications); nil when it is fine.
    @Published private(set) var inboxStatus: String?
    /// When `home` was read: the player's position runs on from here.
    @Published private(set) var homeRead = Date()
    private(set) var pushToken: String?

    private var link: PairingLink?
    /// Whether a `hello` or `list` answer told us what the Mac can do. An old Mac sends no `features`: then the
    /// empty set is known too, so a screen does not keep asking.
    private var featuresKnown = false
    private var poll: Task<Void, Never>?

    init() {
        link = PairingStore.load()
        macName = link?.macName ?? ""
        phase = link == nil ? .unpaired : .offline("")
    }

    // MARK: Pairing

    /// Pairs with the code the Mac shows. The first request, `hello`, proves the phone holds the key; the Mac then keeps the device.
    func pair(link text: String) {
        guard let parsed = PairingLink.parse(text) else { notice = String(localized: "That is not a valid pairing code."); return }
        phase = .pairing
        notice = nil
        Task {
            do {
                let response = try await request(CompanionRequest(op: .hello, text: UIDevice.current.name), using: parsed)
                guard response.ok else { throw CompanionClientError.refused(response.error) }
                guard PairingStore.save(parsed) else { throw CompanionClientError.storage }
                link = parsed
                macName = response.macName ?? parsed.macName
                sessions = response.sessions ?? []
                features = Set(response.features ?? [])
                featuresKnown = true
                Notifications.setBadge(sessions.needingYou)
                phase = .connected
                startPolling()
                await Notifications.requestAndRegister()
            } catch {
                phase = link == nil ? .unpaired : .offline(error.localizedDescription)
                notice = String(localized: "Pairing failed: \(error.localizedDescription) The code works once, for five minutes; make a new one on your Mac.")
            }
        }
    }

    func unpair() {
        poll?.cancel()
        Task { await LiveActivities.shared.endAll() }
        PairingStore.clear()
        link = nil
        sessions = []
        features = []
        featuresKnown = false
        launchOptions = nil
        timelines = [:]
        conversations = []
        chatLines = [:]
        home = nil
        usage = nil
        inbox = []
        inboxLines = [:]
        inboxStatus = nil
        phase = .unpaired
    }

    // MARK: Polling and actions

    func startPolling() {
        poll?.cancel()
        guard link != nil else { return }
        poll = Task { [weak self] in
            var delay: UInt64 = 5
            while !Task.isCancelled {
                await self?.refresh()
                // While the Mac cannot be reached, wait longer each time (10, 20, 40, then 60 s) instead of trying again and
                // again, which keeps the radio awake; pulling to refresh still tries at once.
                if case .offline? = self?.phase { delay = min(delay * 2, 60) } else { delay = 5 }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    func stopPolling() { poll?.cancel() }

    func refresh() async {
        guard link != nil else { return }
        await perform(CompanionRequest(op: .list))
        guard phase == .connected else { return }
        // The Live Activities follow the list (and the Mac gets the tokens it does not have yet).
        await LiveActivities.shared.reconcile(sessions)
        // The chats too, for the badge on the Chats tab.
        if can(CompanionFeature.inbox) { await perform(CompanionRequest(op: .inbox), quiet: true) }
    }

    /// The token iOS gave this app for pushes: kept, and sent to the Mac (sealed) so it can notify this phone.
    func registerPush(token: Data) async {
        let hex = APNsJWT.tokenHex(token)
        pushToken = hex
        await sendPushRegistration()
    }

    /// Whether this build's push tokens are for Apple's production service; a debug build has sandbox tokens.
    static var apnsProduction: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    func sendPushRegistration() async {
        guard let link, let pushToken else { return }
        let environment = Self.apnsProduction ? "production" : "development"
        if let response = try? await request(CompanionRequest(op: .register, item: environment, text: pushToken), using: link), response.ok {
            macPushReady = response.message == "push"
        }
    }

    /// Hands the Mac a Live Activity token (or says one ended, or that they are off). The Mac's "push"/"nopush" when it
    /// took it, nil when it could not be reached or does not know Live Activities.
    func registerLive(_ registration: LiveActivityRegistration) async -> String? {
        guard let link, can(CompanionFeature.liveActivity),
              let response = try? await request(CompanionRequest(op: .liveActivity, live: registration), using: link),
              response.ok else { return nil }
        return response.message ?? "nopush"
    }

    /// An action from a notification (Allow / Deny), done without opening the app.
    func decide(sessionID: String, itemID: String, allow: Bool) async {
        await perform(CompanionRequest(op: .decide, session: sessionID, item: itemID, allow: allow))
    }

    func decide(_ session: SessionDigest, item: SessionDigest.Item, allow: Bool) async {
        await perform(CompanionRequest(op: .decide, session: session.id, item: item.id, allow: allow))
    }

    func answer(_ session: SessionDigest, item: SessionDigest.Item, text: String) async {
        await perform(CompanionRequest(op: .answer, session: session.id, item: item.id, text: text))
    }

    func send(_ session: SessionDigest, text: String) async {
        await perform(CompanionRequest(op: .send, session: session.id, text: text))
    }

    func stop(_ session: SessionDigest) async {
        await perform(CompanionRequest(op: .stop, session: session.id))
    }

    // MARK: Starting a session

    func can(_ feature: String) -> Bool { features.contains(feature) }

    /// `can`, after asking the Mac first when its features are not known yet (a screen that loads right after launch,
    /// before the first `list` came back).
    private func supports(_ feature: String) async -> Bool {
        if !featuresKnown, link != nil { await refresh() }
        return can(feature)
    }

    func loadLaunchOptions() async {
        guard await supports(CompanionFeature.start) else { return }
        await perform(CompanionRequest(op: .options))
    }

    /// Starts a session on the Mac; the id of the new session, or nil when it did not start (the reason is in `notice`).
    func start(_ launch: LaunchRequest) async -> String? {
        await perform(CompanionRequest(op: .start, launch: launch))?.created
    }

    // MARK: A session's conversation

    func loadTimeline(_ sessionID: String) async {
        guard await supports(CompanionFeature.timeline) else { return }
        await perform(CompanionRequest(op: .timeline, session: sessionID), quiet: true)
    }

    // MARK: Nook's own chats

    func loadChats() async {
        guard await supports(CompanionFeature.chat) else { return }
        await perform(CompanionRequest(op: .chats), quiet: true)
    }

    func loadChat(_ conversationID: String) async {
        guard await supports(CompanionFeature.chat) else { return }
        await perform(CompanionRequest(op: .chat, conversation: conversationID), quiet: true)
    }

    /// Asks Nook; nil `conversationID` starts a new chat. The id of the chat, or nil when the Mac refused.
    func ask(_ text: String, in conversationID: String?) async -> String? {
        let response = await perform(CompanionRequest(op: .ask, text: text, conversation: conversationID))
        if response != nil { await loadChats() }
        return response?.created
    }

    // MARK: Home and usage

    func loadHome() async {
        guard await supports(CompanionFeature.home) else { return }
        await perform(CompanionRequest(op: .home), quiet: true)
    }

    /// `range`: "today", "week" or "month".
    func loadUsage(range: String) async {
        guard await supports(CompanionFeature.usage) else { return }
        await perform(CompanionRequest(op: .usage, item: range), quiet: true)
    }

    /// "playpause", "next" or "previous".
    func music(_ command: String) async {
        guard await supports(CompanionFeature.music) else { return }
        await perform(CompanionRequest(op: .music, text: command), quiet: true)
    }

    // MARK: The Chats tab

    func loadInbox() async {
        guard await supports(CompanionFeature.inbox) else { return }
        await perform(CompanionRequest(op: .inbox), quiet: true)
    }

    func loadInboxChat(_ chatID: String) async {
        guard await supports(CompanionFeature.inbox) else { return }
        await perform(CompanionRequest(op: .inboxChat, item: chatID), quiet: true)
    }

    /// Your own words to a chat (a WhatsApp chat on the Mac), as an answer to `replyTo` when one is quoted. Whether it went.
    func sendInbox(_ text: String, to chatID: String, replyTo: String? = nil) async -> Bool {
        let sent = await perform(CompanionRequest(op: .inboxSend, item: chatID, text: text, replyTo: replyTo)) != nil
        if sent { await loadInbox() }
        return sent
    }

    /// Read (`read`) or unread by hand; read tells WhatsApp too.
    func markInbox(_ chatID: String, read: Bool) async {
        await perform(CompanionRequest(op: .inboxMark, item: chatID, allow: read))
    }

    func stopChat(_ conversationID: String) async {
        await perform(CompanionRequest(op: .chatStop, conversation: conversationID))
    }

    /// Sends a request and takes in whatever the answer carries. The answer when the Mac said yes, else nil with the reason
    /// in `notice`. `quiet` is for the requests a screen repeats by itself: a session or chat that is gone says so on that
    /// screen instead of in an alert every few seconds.
    @discardableResult
    private func perform(_ req: CompanionRequest, quiet: Bool = false) async -> CompanionResponse? {
        guard let link else { return nil }
        do {
            let response = try await request(req, using: link)
            if response.ok {
                apply(response, to: req)
                if phase != .connected { phase = .connected }
                if let message = response.message {
                    switch message {
                    case "queued": notice = String(localized: "Queued: the session is still busy.")
                    case "nobrain": brainReady = false
                    default: break
                    }
                } else if req.op == .chats {
                    brainReady = true
                }
                return response
            }
            if quiet, response.error == .unknownSession { return nil }
            if quiet, response.error == .unknownItem, req.op == .inboxChat { return nil }
            switch response.error {
            case .notAllowedFromPhone where req.op == .inboxSend:
                notice = String(localized: "Nook can only read this chat: answer it in its own app.")
            case .notAllowedFromPhone: notice = String(localized: "Not possible from your phone: open it on your Mac.")
            case .unknownSession where req.conversation != nil: notice = String(localized: "This chat is gone."); await loadChats()
            case .unknownItem where req.op == .inboxSend || req.op == .inboxMark:
                notice = String(localized: "This chat is gone."); await loadInbox()
            case .unknownItem, .unknownSession: notice = String(localized: "That has already been handled."); await refresh()
            case .stale: notice = String(localized: "The clocks of your phone and your Mac are too far apart.")
            case .rateLimited: notice = String(localized: "Slow down a little.")
            case .failed where response.message == "nobrain":
                brainReady = false
                notice = String(localized: "Nook has no brain set up on your Mac yet: choose one in Nook › Settings.")
            case .failed where response.message?.isEmpty == false:
                notice = String(localized: "Your Mac could not do this: \(response.message ?? "")")
            default: notice = String(localized: "Your Mac refused this.")
            }
        } catch {
            phase = .offline(error.localizedDescription)
        }
        return nil
    }

    /// Takes in what an answer carries. Every poll answers, mostly with the same data: a value is only assigned when it
    /// changed, so the screens are not redrawn each time.
    private func apply(_ response: CompanionResponse, to req: CompanionRequest) {
        // The badge is set on (re)connecting too, so one left from before is corrected.
        if let list = response.sessions, list != sessions || phase != .connected {
            if list.needingYou != sessions.needingYou || phase != .connected { Notifications.setBadge(list.needingYou) }
            if list != sessions { sessions = list }
        }
        if let name = response.macName, name != macName { macName = name }
        if let features = response.features, Set(features) != self.features { self.features = Set(features) }
        if req.op == .list || req.op == .hello { featuresKnown = true }
        if let options = response.launch, options != launchOptions { launchOptions = options }
        if let timeline = response.timeline, let session = req.session, timelines[session] != timeline { timelines[session] = timeline }
        if let list = response.conversations, list != conversations { conversations = list }
        if let lines = response.messages, let conversation = response.created ?? req.conversation, chatLines[conversation] != lines {
            chatLines[conversation] = lines
        }
        // The player's position runs on from when it was read, so that time is kept even when nothing else changed.
        if let home = response.home {
            if home != self.home { self.home = home }
            homeRead = Date()
        }
        if let usage = response.usage, usage != self.usage { self.usage = usage }
        if let chats = response.inbox {
            if chats != inbox { inbox = chats }
            if response.message != inboxStatus { inboxStatus = response.message }
        }
        if let lines = response.inboxLines, let chat = req.item, inboxLines[chat] != lines { inboxLines[chat] = lines }
    }

    // MARK: Transport

    private func request(_ req: CompanionRequest, using link: PairingLink) async throws -> CompanionResponse {
        let deviceID = PairedDevice.identifier(forKey: link.key)
        let plain = try JSONEncoder().encode(req)
        let sealed = try CompanionSeal.seal(plain, pairingKey: link.key, deviceID: deviceID, direction: .request)
        guard let framed = CompanionFrameReader.frame(sealed), let port = NWEndpoint.Port(rawValue: link.port) else {
            throw CompanionClientError.badRequest
        }
        let reply = try await Exchange.run(host: link.host, port: port, payload: framed)
        let opened = try CompanionSeal.open(reply, pairingKey: link.key, direction: .response)
        let response = try JSONDecoder().decode(CompanionResponse.self, from: opened)
        guard response.id == req.id else { throw CompanionClientError.badRequest }
        return response
    }
}

enum CompanionClientError: LocalizedError {
    case refused(CompanionError?)
    case storage, badRequest, timeout, closed

    var errorDescription: String? {
        switch self {
        case .refused: return String(localized: "Your Mac refused the code.")
        case .storage: return String(localized: "The key could not be saved.")
        case .badRequest: return String(localized: "Unreadable reply from your Mac.")
        case .timeout: return String(localized: "Your Mac does not answer. Is the companion on, and are you on the same Wi‑Fi?")
        case .closed: return String(localized: "The connection was lost.")
        }
    }
}

/// One connection: send the frame, read until one whole frame came back, with a timeout.
private enum Exchange {
    static func run(host: String, port: NWEndpoint.Port, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let queue = DispatchQueue(label: "nook.companion.client")
            let box = Once(continuation)
            var reader = CompanionFrameReader()

            func finish(_ result: Result<Data, Error>) {
                connection.cancel()
                box.resume(result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        let frames = reader.feed(data)
                        if let first = frames.first { return finish(.success(first)) }
                        if reader.overflowed { return finish(.failure(CompanionClientError.badRequest)) }
                    }
                    if error != nil || complete { return finish(.failure(CompanionClientError.closed)) }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { finish(.failure(CompanionClientError.closed)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { finish(.failure(CompanionClientError.timeout)) }
        }
    }

    /// Resumes a continuation once, however many callbacks race.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?

        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        func resume(_ result: Result<Data, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}

/// Notification permission, the push token, the buttons on a notification and the badge.
enum Notifications {
    static func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        registerCategories()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound, .timeSensitive])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func registerCategories() {
        let deny = UNNotificationAction(identifier: PushCategory.actionDeny, title: String(localized: "Deny"), options: [.destructive])
        let allow = UNNotificationAction(identifier: PushCategory.actionAllow, title: String(localized: "Allow"), options: [])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: PushCategory.approvalDeny, actions: [deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.approvalAllow, actions: [deny, allow], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.question, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.info, actions: [], intentIdentifiers: [], options: [])
        ])
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
}
