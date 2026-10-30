import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import QuickLookThumbnailing

// MARK: - Settings

/// WhatsApp through a local gateway (Settings › Accounts & connections › WhatsApp, live). The gateway's password and
/// the webhook's signing secret live in the Keychain; harmless choices go to UserDefaults.
enum WhatsAppSettings {
    static let credentialAccount = "whatsapp-gateway-credential"
    static let secretAccount = "whatsapp-webhook-secret"
    static let defaultPort = 47823

    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.bool(forKey: "whatsappEnabled") }
        set { defaults.set(newValue, forKey: "whatsappEnabled") }
    }
    static var gateway: WAGatewayKind {
        get { WAGatewayKind(rawValue: defaults.string(forKey: "whatsappGateway") ?? "") ?? .gowa }
        set { defaults.set(newValue.rawValue, forKey: "whatsappGateway") }
    }
    /// The gateway's address; empty means the gateway's own default (GOWA 127.0.0.1:3000).
    static var url: String {
        get {
            let stored = (defaults.string(forKey: "whatsappURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? gateway.defaultURL : stored
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "whatsappURL") }
    }
    /// The port of Nook's own webhook (always on 127.0.0.1).
    static var port: Int {
        get { let value = defaults.integer(forKey: "whatsappPort"); return (1024...65535).contains(value) ? value : defaultPort }
        set { defaults.set(newValue, forKey: "whatsappPort") }
    }

    /// The accounts linked besides the first one, in the order they were added (see `WAAccount`).
    static var accounts: [WAAccount] {
        get { defaults.data(forKey: "whatsappAccounts").flatMap { try? JSONDecoder().decode([WAAccount].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "whatsappAccounts") }
    }

    /// What you call the first account; empty, it goes by its number.
    static var mainName: String {
        get { defaults.string(forKey: "whatsappAccountName") ?? "" }
        set { defaults.set(WAAccount.cleanName(newValue), forKey: "whatsappAccountName") }
    }

    /// Where an account keeps a choice of its own: the first account under the key it always had, another under the key
    /// with its id after it.
    static func key(_ base: String, account: String) -> String {
        account.isEmpty ? base : base + "." + account
    }

    /// The port of an account's webhook: the first account's own, each other account the next one up, in the order
    /// they were added. Nil for one that would go past the last port.
    static func port(account: String) -> Int? {
        guard !account.isEmpty else { return port }
        guard let index = accounts.firstIndex(where: { $0.id == account }), port + index + 1 <= 65535 else { return nil }
        return port + index + 1
    }
    /// When each chat was last read, by its JID: in Nook ("whatsappReadInNook") or in WhatsApp itself
    /// ("whatsappReadInWhatsApp"). Kept so a restart does not bring back what you already read; marks older than
    /// `ChatReadMarks.maxAge` are forgotten.
    static func readMarks(_ key: String) -> [String: Date] {
        ChatReadMarks.pruned((defaults.dictionary(forKey: key) as? [String: Date]) ?? [:])
    }

    static func setReadMarks(_ marks: [String: Date], _ key: String) {
        defaults.set(ChatReadMarks.pruned(marks), forKey: key)
    }

    /// Each chat's unread messages when Nook last ran (see `WAUnreadCarry`), by its JID.
    static func unreadCarry(account: String) -> [String: WAUnreadCarry] {
        defaults.data(forKey: key("whatsappUnreadCarry", account: account))
            .flatMap { try? JSONDecoder().decode([String: WAUnreadCarry].self, from: $0) } ?? [:]
    }

    static func setUnreadCarry(_ carry: [String: WAUnreadCarry], account: String) {
        defaults.set(try? JSONEncoder().encode(carry), forKey: key("whatsappUnreadCarry", account: account))
    }

    /// The chats pinned on the phone as far as Nook knows, by their JID: the ones you pinned from Nook, and what the
    /// gateway's chat list says (OpenWA). Forgotten when WhatsApp is turned off.
    static func pinnedChats(account: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key("whatsappPinnedChats", account: account)) ?? [])
    }

    static func setPinnedChats(_ chats: Set<String>, account: String) {
        defaults.set(Array(chats).sorted(), forKey: key("whatsappPinnedChats", account: account))
    }

    /// What an account you removed kept on this Mac: its read marks, its unread counts, its pins, its votes and ticks.
    static func forget(account: String) {
        guard !account.isEmpty else { return }
        for base in ["whatsappUnreadCarry", "whatsappPinnedChats", "whatsappReadInNook", "whatsappReadInWhatsApp",
                     "whatsappMarkedUnread"] {
            defaults.removeObject(forKey: key(base, account: account))
        }
        try? FileManager.default.removeItem(at: WAPollStore.file(account: account))
        try? FileManager.default.removeItem(at: WAReceiptStore.file(account: account))
    }

    /// GOWA: `user:pass` for basic auth. OpenWA: the API key.
    static var credential: String? { SecretStore.read(credentialAccount) }

    static func setCredential(_ value: String) {
        SecretStore.write(value, account: credentialAccount)
    }

    /// The webhook's signing secret, made once (random, 64 hex characters).
    static func webhookSecret() -> String {
        if let secret = SecretStore.read(secretAccount), secret.count >= 16 { return secret }
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let secret = Data(bytes).waHex
        SecretStore.write(secret, account: secretAccount)
        return secret
    }

    /// The gateway as one account talks to it: every account on the same gateway, each on a device (GOWA) or session
    /// (OpenWA) of its own.
    static func makeProvider(account: String = "") -> WhatsAppProvider? {
        guard let base = URL(string: url), base.scheme?.hasPrefix("http") == true, base.host != nil else { return nil }
        let own = account.isEmpty ? nil : account
        let others = Set(accounts.map(\.id))
        switch gateway {
        case .gowa: return GOWAProvider(base: base, basicAuth: credential, account: own, others: others)
        case .openwa: return OpenWAProvider(base: base, apiKey: credential, account: own, others: others)
        }
    }
}

// MARK: - Link

/// WhatsApp, live: Nook talks to the local gateway the user runs (GOWA, which Nook can install and start, or OpenWA),
/// receives new messages on a webhook bound to 127.0.0.1 (polling when none comes), and keeps the conversations in
/// memory only: nothing of a message is written to disk or to a log, and everything is forgotten when Nook quits or
/// WhatsApp is turned off. Only the votes on polls are kept on disk (`WAPollStore`: who chose which option, by poll id),
/// since no gateway keeps them; they go when WhatsApp is turned off. Sending goes only to chats that are on the phone, a few a minute at most, and only after the
/// user typed the answer or approved Nook's plan.
///
/// The lifecycle after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
/// A message's file as the notch card shows it: saved in Nook's own temporary folder (emptied when Nook starts and
/// quits), with a small picture of it when there is one.
struct WAPreview {
    let file: URL
    let image: NSImage?
}

@MainActor
final class WhatsAppLink: ObservableObject {
    /// The first account, the one Nook always linked; the others are in `WhatsAppAccounts`.
    static let shared = WhatsAppLink(account: "")
    /// The account this link is for: empty for the first, else its `WAAccount` id.
    let account: String
    nonisolated static let webhookPath = "/whatsapp"
    /// A message older than this when it reaches Nook is a catch-up (after a sleep or an outage), never announced:
    /// the webhook is instant and polling at most half a minute late.
    static let freshness: TimeInterval = 120

    enum Link: Equatable {
        case off
        case connecting
        /// The gateway runs, WhatsApp isn't linked: the QR is shown in Settings.
        case needsQR
        case connected
        case unreachable
        case unauthorized
        case failed(String)
    }

    enum Webhook: Equatable {
        case off, listening, registered, portBusy
        case refused(String)
    }

    /// Votes received are kept on disk (see `WAPollLedger`), so a poll shows them again after a restart.
    @Published private(set) var inbox: WAInbox {
        didSet {
            if inbox.pollLedger != oldValue.pollLedger { WAPollStore.save(inbox.pollLedger, to: WAPollStore.file(account: account)) }
            if inbox.receiptLedger.revision != oldValue.receiptLedger.revision { saveReceipts() }
            keepUnread()
        }
    }
    @Published private(set) var link: Link = .off {
        didSet {
            switch link {
            case .connected: linkedUntil = nil; wasLinked = true
            case .off, .needsQR, .unauthorized: linkedUntil = nil; wasLinked = false
            case .connecting, .unreachable, .failed:
                if oldValue == .connected { linkedUntil = Date().addingTimeInterval(Self.linkGrace) }
            }
        }
    }
    /// The phone was linked, and the gateway only stopped answering for now (a restart, the Mac waking, one failed
    /// check): its chats stay in the Chats tab meanwhile, until `linkedUntil`, instead of vanishing and coming back.
    private var wasLinked = false
    private var linkedUntil: Date?
    /// How long a gateway that stopped answering still holds its chats in the Chats tab.
    private static let linkGrace: TimeInterval = 600
    /// Its chats show: linked now, or linked until a moment ago and the gateway only stopped answering.
    var holdsChats: Bool { isConnected || (wasLinked && (linkedUntil ?? .distantPast) > Date()) }
    @Published private(set) var webhook: Webhook = .off
    @Published private(set) var qrPNG: Data?
    /// Who the numbers are: your Contacts and the phone's, refreshed with the chat list (see `WANameBook`).
    @Published private(set) var names = WANameBook()
    /// The gateway's contact list as it last answered.
    private var gatewayContacts: [WAContact] = []
    private var receiptSave: Task<Void, Never>?

    /// Writes the kept ticks a moment after the last change: a burst of receipts is one write.
    private func saveReceipts() {
        receiptSave?.cancel()
        receiptSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let ledger = inbox.receiptLedger
            let file = WAReceiptStore.file(account: account)
            await Task.detached(priority: .utility) { WAReceiptStore.save(ledger, to: file) }.value
        }
    }

    /// The name a chat on the phone shows: for a person a saved contact's, as WhatsApp shows it, else what the phone's
    /// chat list calls it.
    func chatName(_ jid: String, fallback: String) -> String {
        guard WAJID.kind(jid) == .person, let saved = names.name(jid) else { return fallback }
        return saved
    }

    /// Who is who in a chat, with your Contacts and the phone's.
    func memberIndex(_ conversation: WAConversation) -> WAMemberIndex {
        WAMemberIndex(conversation, book: names)
    }

    /// This account (JID or number), once linked.
    @Published private(set) var me: String?
    /// The chats on the phone (names to send to), refreshed every few minutes while linked.
    @Published private(set) var knownChats: [WAChatInfo] = [] {
        didSet { knownIndex = Dictionary(knownChats.indices.map { (knownChats[$0].jid, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Where each chat sits in `knownChats`: the Chats tab asks about every chat on each redraw, so a scan per chat
    /// made the list quadratic and stalled the main thread.
    private var knownIndex: [String: Int] = [:]
    /// When a chat was last read in WhatsApp itself: marked read from Nook (by hand), or read on the phone.
    @Published private(set) var readInWhatsApp: [String: Date] {
        didSet { WhatsAppSettings.setReadMarks(readInWhatsApp, WhatsAppSettings.key(Self.readInWhatsAppKey, account: account)); keepUnread() }
    }
    /// When you last read a chat in Nook: WhatsApp's own unread count from before then no longer shows. Kept across
    /// launches, so a chat you read in Nook stays read after a restart.
    @Published private(set) var readInNook: [String: Date] {
        didSet { WhatsAppSettings.setReadMarks(readInNook, WhatsAppSettings.key(Self.readInNookKey, account: account)); keepUnread() }
    }
    /// What each chat counted unread when Nook last ran (see `WAUnreadCarry`): it shows until the chat is read or
    /// answered in, so a restart does not make every chat read.
    private var carriedUnread: [String: WAUnreadCarry]
    /// What the next launch starts from, as last written.
    private var keptUnread: [String: WAUnreadCarry]?
    /// Chats you marked unread by hand while Nook holds none of their messages (a chat known only from the phone's
    /// list): they count one new message until you read them. Kept across launches, as the read marks are.
    @Published private(set) var markedUnread: [String: Date] {
        didSet { WhatsAppSettings.setReadMarks(markedUnread, WhatsAppSettings.key(Self.markedUnreadKey, account: account)) }
    }
    private static let readInNookKey = "whatsappReadInNook"
    private static let markedUnreadKey = "whatsappMarkedUnread"
    private static let readInWhatsAppKey = "whatsappReadInWhatsApp"
    /// Each chat's picture on this Mac (a person's profile photo, a group's), by its JID, once fetched.
    @Published private(set) var avatars: [String: String] = [:]
    /// When a chat's picture was last asked for: a chat without one is asked again after a while, not at every look.
    private var avatarAsked: [String: Date] = [:]
    /// Where each followed channel's picture is, from the channel list (channels have no avatar route of their own).
    private var channelPictures: [String: URL] = [:]
    /// Pictures come from WhatsApp's own picture server: no cookies, no cache, never the gateway's credentials.
    private static let avatarSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
    /// What this account sorts its gateway's messages by: the notice rules every chat app follows, for this account's
    /// own chats (`ChatNoticeRulesStore.filters(account:)`). A hidden chat is not even kept.
    @Published private(set) var filters: WAFilters
    /// The chats muted on the phone, as far as Nook knows: muted from Nook, or so in the gateway's chat list (OpenWA).
    /// Not WhatsApp's notice rules in Nook (`mute(_:)`), which only quiet the chat here.
    @Published private(set) var mutedChats: Set<String> = []
    /// The chats pinned on the phone, as far as Nook knows (see `WhatsAppSettings.pinnedChats`).
    @Published private(set) var pinnedChats: Set<String> {
        didSet { if pinnedChats != oldValue { WhatsAppSettings.setPinnedChats(pinnedChats, account: account) } }
    }

    /// A new message reached you (not a muted group, not your own): the notch shows it. Each of these three gives the
    /// chat's key across accounts (`WAChatKey`), not its JID.
    var onMessage: ((_ chat: String) -> Void)?
    /// Your own messages in a chat got new ticks (delivered, read).
    var onReceipt: ((_ chat: String) -> Void)?
    /// You read a chat on the phone: what Nook still had waiting for it goes.
    var onReadElsewhere: ((_ chat: String) -> Void)?
    /// This account let go of everything it kept (WhatsApp turned off, the account removed): the shared inbox lets go
    /// of its chats' messages too (`WhatsAppGatewayBridge`).
    var onForget: (() -> Void)?

    /// A chat of this account as the rest of Nook knows it (see `WAChatKey`).
    func chatKey(_ jid: String) -> String { WAChatKey.make(jid, account: account) }

    var isConnected: Bool { link == .connected }

    private var provider: WhatsAppProvider?
    private let listener = WhatsAppWebhook()
    private var timer: Timer?
    private var tick = 0
    private var refreshing = false
    private var polling = false
    private var backfilled = false
    private var qrExpiry: Date = .distantPast
    private var lastWebhook: Date?
    private var lastPoll = Date()
    private var lastChatList: Date = .distantPast
    /// When each unnamed group was last asked for its name: one the gateway could not name is asked again later.
    private var namingGroups: [String: Date] = [:]
    /// When each chat's messages were last fetched from the gateway for the notch card or the Chats tab.
    private var historyFetched: [String: Date] = [:]
    /// When each group's members were last asked of the gateway.
    private var membersLoaded: [String: Date] = [:]
    /// Chats whose newest messages were asked for their line in the Chats tab, and the ones still waiting their turn.
    private var linesAsked: Set<String> = []
    private var linesWaiting: [String] = []
    private var linesLoading = false
    /// Files the notch card shows (photos, videos, documents), by message id, oldest first in `previewOrder`.
    private var previews: [String: WAPreview] = [:] {
        didSet { previewRevision &+= 1 }
    }
    /// Counts changes to the fetched files. Published, so an open chat shows a photo, sticker or video the moment it
    /// is fetched, and its bubbles made earlier know they are out of date.
    @Published private(set) var previewRevision = 0
    private var previewOrder: [String] = []
    private var previewsLoading: Set<String> = []
    /// When a preview last failed: it is tried again after `previewRetry`, not at every redraw.
    private var previewFailed: [String: Date] = [:]
    private var rateLimit = WARateLimit(limit: 6, window: 60)
    private var failures = 0
    /// Bumped at each start and stop: an answer from before a restart is dropped.
    private var generation = 0
    private var bag = Set<AnyCancellable>()

    init(account: String) {
        self.account = account
        let key = { (base: String) in WhatsAppSettings.key(base, account: account) }
        inbox = WAInbox(polls: WAPollStore.load(from: WAPollStore.file(account: account)),
                        receipts: WAReceiptStore.load(from: WAReceiptStore.file(account: account)))
        readInWhatsApp = WhatsAppSettings.readMarks(key(Self.readInWhatsAppKey))
        readInNook = WhatsAppSettings.readMarks(key(Self.readInNookKey))
        markedUnread = WhatsAppSettings.readMarks(key(Self.markedUnreadKey))
        carriedUnread = WhatsAppSettings.unreadCarry(account: account).filter {
            Date().timeIntervalSince($0.value.last) < ChatReadMarks.maxAge
        }
        pinnedChats = WhatsAppSettings.pinnedChats(account: account)
        filters = ChatNoticeRulesStore.shared.filters(account: account)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.wake() } }
            .store(in: &bag)
        // The gateway and the opened files are everyone's: the first account lets go of them.
        guard account.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in MainActor.assumeIsolated {
                WhatsAppGOWAProcess.shared.stopNow()
                WhatsAppLink.clearOpenedFiles()
            } }
            .store(in: &bag)
    }

    /// Called once at launch.
    func start() {
        if account.isEmpty { Self.clearOpenedFiles() }
        update()
    }

    /// The account was removed in Settings: the link stops, the gateway lets go of its device or session, and what it
    /// kept on this Mac goes.
    func remove() {
        let provider = provider ?? WhatsAppSettings.makeProvider(account: account)
        stop(forget: true)
        // The ticks written a moment after the last change would bring its file back.
        receiptSave?.cancel()
        WhatsAppSettings.forget(account: account)
        if let provider { Task { await provider.removeAccount() } }
    }

    /// Settings changed (on/off, gateway, address, password, port): start over.
    func settingsChanged() {
        stop(forget: !WhatsAppSettings.enabled)
        update()
    }

    func setEnabled(_ on: Bool) {
        WhatsAppSettings.enabled = on
        settingsChanged()
    }

    private func update() {
        if WhatsAppSettings.enabled && provider == nil { begin() }
        else if !WhatsAppSettings.enabled && provider != nil { stop(forget: true) }
    }

    // MARK: Lifecycle

    private func begin() {
        guard let provider = WhatsAppSettings.makeProvider(account: account) else {
            link = .failed(tr("whatsapp.status.badURL"))
            return
        }
        self.provider = provider
        generation += 1
        link = .connecting
        startListener(kind: provider.kind)
        WhatsAppGOWAProcess.shared.sync()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    private func stop(forget: Bool) {
        generation += 1
        historyFetched = [:]
        membersLoaded = [:]
        linesAsked = []
        linesWaiting = []
        if online, let provider { Task { await provider.setOnline(false, chat: nil) } }
        online = false
        onlineChat = nil
        if forget { gatewayContacts = [] }
        previews = [:]
        previewOrder = []
        previewsLoading = []
        previewFailed = [:]
        refreshing = false
        polling = false
        timer?.invalidate()
        timer = nil
        listener.stop()
        provider = nil
        link = .off
        webhook = .off
        qrPNG = nil
        me = nil
        backfilled = false
        lastWebhook = nil
        namingGroups = [:]
        failures = 0
        if !WhatsAppSettings.enabled { WhatsAppGOWAProcess.shared.stopNow() }
        if forget {
            carriedUnread = [:]
            inbox.clear()
            knownChats = []
            pinnedChats = []
            mutedChats = []
            onForget?()
        }
    }

    private func wake() {
        guard provider != nil else { return }
        // Nothing is trusted after a sleep: the gateway may have restarted without Nook's webhook.
        webhook = webhook == .portBusy ? .portBusy : .listening
        lastWebhook = nil
        refresh()
    }

    private func onTick() {
        tick += 1
        if link != .connected {
            // Every 5 s while linking; every 30 s once the gateway has been down for a minute.
            if failures > 12 && tick % 6 != 0 { return }
            refresh()
        } else {
            if tick % 12 == 0 { refresh() }
            if tick % 4 == 0 { poll() }
        }
    }

    // MARK: Status and QR

    func refresh() {
        guard let provider, !refreshing else { return }
        refreshing = true
        let gen = generation
        Task {
            defer { if gen == generation { refreshing = false } }
            do {
                let status = try await provider.status()
                guard gen == generation else { return }
                failures = 0
                // Asked every few seconds: publish only what changed, since the panel redraws for every write.
                if me != status.me { me = status.me }
                switch status.link {
                case .connected:
                    if link != .connected {
                        qrPNG = nil
                        link = .connected
                    }
                    if webhook == .listening { await register(provider, gen: gen) }
                    if !backfilled, gen == generation { await backfill(provider, gen: gen) }
                    if Date().timeIntervalSince(lastChatList) > 300 { await loadChats(provider, gen: gen) }
                case .needsQR:
                    if link != .needsQR { link = .needsQR }
                    if qrPNG == nil || Date() > qrExpiry {
                        // Not asked again for 15 s even when nothing came: each GOWA login call restarts the pairing.
                        qrExpiry = Date().addingTimeInterval(15)
                        if let qr = try await provider.qrCode(), gen == generation {
                            qrPNG = qr.png
                            qrExpiry = Date().addingTimeInterval(TimeInterval(qr.seconds))
                        }
                    }
                case .connecting:
                    if link != .connecting { link = .connecting }
                }
            } catch let error as WAError {
                if gen == generation { apply(error) }
            } catch {
                if gen == generation { apply(.unreachable) }
            }
        }
    }

    private func apply(_ error: WAError) {
        let next: Link
        switch error {
        case .unreachable: next = .unreachable
        case .unauthorized: next = .unauthorized
        case .notLoggedIn: next = .needsQR
        case .refused(let why): next = .failed(why)
        }
        // A gateway that stays down reports the same every few seconds.
        if link != next { link = next }
        guard error != .notLoggedIn else { return }
        failures += 1
        // GOWA started by Nook and gone (crash, killed): started again, once a minute at most.
        if error == .unreachable { WhatsAppGOWAProcess.shared.sync() }
    }

    /// The link in one sentence, for Settings and for the brain when it cannot reach WhatsApp.
    var statusLine: String {
        switch link {
        case .off: return tr("whatsapp.status.off")
        case .connecting: return tr("whatsapp.status.connecting")
        case .needsQR: return tr("whatsapp.status.needsQR")
        case .connected:
            let who = me.map(WAJID.displayNumber) ?? ""
            return tr("whatsapp.status.connected", who)
        case .unreachable: return tr("whatsapp.status.unreachable")
        case .unauthorized: return tr("whatsapp.status.unauthorized")
        case .failed(let why): return why
        }
    }

    // MARK: Webhook

    private func startListener(kind: WAGatewayKind) {
        let secret = WhatsAppSettings.webhookSecret()
        listener.onRequest = { [weak self] request in
            guard request.method == "POST", request.path.hasPrefix(WhatsAppLink.webhookPath) else { return 404 }
            // Signed by the gateway with Nook's secret, over the exact bytes received.
            guard WAWebhook.verify(kind: kind, headers: request.headers, body: request.body, secret: secret) else { return 401 }
            let body = request.body
            Task { @MainActor in self?.received(body, kind: kind) }
            return 200
        }
        listener.onListening = { [weak self] ok in
            Task { @MainActor in
                guard let link = self, link.provider != nil else { return }
                if !ok { link.webhook = .portBusy }
                else if link.webhook == .off || link.webhook == .portBusy { link.webhook = .listening; link.refresh() }
            }
        }
        guard let port = webhookPort, listener.start(port: UInt16(port)) else { webhook = .portBusy; return }
    }

    /// Each account has a port of its own (see `WhatsAppSettings.port(account:)`).
    var webhookPort: Int? { WhatsAppSettings.port(account: account) }

    private var webhookURL: String { "http://127.0.0.1:\(webhookPort ?? WhatsAppSettings.port)\(Self.webhookPath)" }

    private func register(_ provider: WhatsAppProvider, gen: Int) async {
        do {
            try await provider.registerWebhook(url: webhookURL, secret: WhatsAppSettings.webhookSecret())
            if gen == generation { webhook = .registered }
        } catch WAError.refused(let why) {
            if gen == generation { webhook = .refused(why) }
        } catch {
            // Tried again on the next minute's check.
        }
    }

    private func received(_ body: Data, kind: WAGatewayKind) {
        guard provider != nil else { return }
        lastWebhook = Date()
        if webhook != .registered { webhook = .registered }
        switch WAWebhook.parse(kind: kind, body: body, me: me) {
        case .message(let message)?:
            ingest([message], announce: true)
        case .receipt(let ids, let chat, let status)?:
            if let changed = inbox.applyReceipt(status, ids: ids, chat: chat) { onReceipt?(chatKey(changed)) }
        case .memberReceipt(let ids, let chat, let member, let status)?:
            if let changed = inbox.applyMemberReceipt(status, ids: ids, chat: chat, member: member) { onReceipt?(chatKey(changed)) }
            // Who is in the group says when everyone has it: asked once, the first time a member answers.
            if WAJID.isGroup(chat), membersLoaded[WAJID.normalized(chat)] == nil {
                Task { @MainActor [weak self] in
                    if let self, await self.loadMembers(chat) { self.onReceipt?(self.chatKey(WAJID.normalized(chat))) }
                }
            }
        case .typing(let chat, let people)?:
            let key = WAJID.normalized(chat)
            // In a private chat the chat itself types (its name says who); in a group the member, by their name.
            let group = WAJID.isGroup(key)
            var names = inbox.conversations[key].map(memberIndex)
            for typing in people {
                let person = group ? WAJID.normalized(typing.from) : key
                guard person != me.map(WAJID.normalized) else { continue }
                if typing.active {
                    let name = typing.name.isEmpty ? names?.name(typing.from) ?? "" : typing.name
                    ChatTypingCenter.shared.typing(chat: ChatInbox.key(app: "whatsapp", id: chatKey(key)), person: person, name: group ? name : "",
                                                   kind: typing.recording ? .recording : .text)
                } else {
                    ChatTypingCenter.shared.stopped(chat: ChatInbox.key(app: "whatsapp", id: chatKey(key)), person: person)
                }
            }
        case .readElsewhere(let chat)?:
            readElsewhere(WAJID.normalized(chat))
        case .reaction(let chat, let message, let emoji, let sender, let fromMe)?:
            // A new emoji redraws the chat's card when it is on screen, as new ticks do; it never brings one up.
            if let changed = inbox.applyReaction(emoji, message: message, chat: chat, sender: sender, fromMe: fromMe) {
                onReceipt?(chatKey(changed))
            }
        default:
            break
        }
    }

    /// Read on the phone or in WhatsApp elsewhere: read in Nook and in WhatsApp, so the badge goes and "Mark as read"
    /// has nothing left to tell.
    private func readElsewhere(_ key: String) {
        readInWhatsApp[key] = readMark(key)
        clearMarkedUnread(key)
        guard inbox.conversations[key] != nil else { return }
        inbox.markRead(key)
        onReadElsewhere?(chatKey(key))
    }

    private var webhookAlive: Bool {
        guard let lastWebhook else { return false }
        return Date().timeIntervalSince(lastWebhook) < 300
    }

    // MARK: Messages

    /// The last hours of history, once linked: kept, but nothing counts as new.
    private func backfill(_ provider: WhatsAppProvider, gen: Int) async {
        backfilled = true
        let since = Date().addingTimeInterval(-12 * 3600)
        guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
        for message in messages { inbox.add(message, filters: filters, history: true) }
        for message in messages { nameGroupIfNeeded(WAJID.normalized(message.chat)) }
        lastPoll = Date()
    }

    /// How many of the phone's chats Nook lists at most: every one the gateway knows, short of an account so large
    /// that listing it would slow the Chats tab and search down.
    static let chatListLimit = 5000

    private func loadChats(_ provider: WhatsAppProvider, gen: Int) async {
        lastChatList = Date()
        let chats: [WAChatInfo]
        do {
            chats = try await provider.chats(limit: Self.chatListLimit)
        } catch {
            Log.connectors.error("WhatsApp: chat list failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard gen == generation else { return }
        knownChats = chats.map {
            WAChatInfo(jid: WAJID.normalized($0.jid), name: $0.name, last: $0.last, unread: $0.unread, pinned: $0.pinned)
        }
        // OpenWA sends no word when you read a chat on the phone: its count going to nothing says it.
        if gatewayCountsUnread {
            let read = inbox.readInGateway(knownChats) { key in
                self.carriedUnread[key].flatMap { $0.holds(readSince: self.readSince(key)) ? $0 : nil }
            }
            for key in read {
                // A chat you marked unread after the list's newest message stays so: the phone's count of nothing is
                // from before your mark.
                if let mark = markedUnread[key], let listed = known(key), listed.last <= mark { continue }
                readElsewhere(key)
            }
        }
        // Who the numbers are: your Contacts first (what you call someone), then the phone's address book.
        // A failed request answers with an empty list: the last list stays, rather than every name going back to a number.
        let listed = await provider.contacts()
        if !listed.isEmpty { gatewayContacts = listed }
        let book = WANameBook(contacts: await ContactDirectory.names(), gateway: gatewayContacts)
        if gen == generation, book != names {
            names = book
            inbox.setNames(book)
        }
        // A gateway that says which chats are pinned (OpenWA) is the phone's word: it replaces what Nook remembered.
        let told = knownChats.filter { $0.pinned != nil }
        if !told.isEmpty {
            var pins = pinnedChats
            for chat in told { if chat.pinned == true { pins.insert(chat.jid) } else { pins.remove(chat.jid) } }
            pinnedChats = pins
        }
        let muteTold = knownChats.filter { $0.muted != nil }
        if !muteTold.isEmpty {
            var muted = mutedChats
            for chat in muteTold { if chat.muted == true { muted.insert(chat.jid) } else { muted.remove(chat.jid) } }
            mutedChats = muted
        }
        // Channels come in under their number ("+120363…"): the channel list names them and says where their picture is.
        for channel in await provider.channels() where gen == generation {
            let jid = WAJID.normalized(channel.jid)
            if let picture = channel.picture { channelPictures[jid] = picture }
            guard !channel.name.isEmpty else { continue }
            if let index = knownChats.firstIndex(where: { $0.jid == jid }), WAJID.isPlaceholderName(knownChats[index].name, for: jid) {
                knownChats[index].name = channel.name
            }
            if let shown = inbox.conversations[jid]?.name, WAJID.isPlaceholderName(shown, for: jid) {
                inbox.rename(jid, to: channel.name)
            }
        }
        guard gen == generation else { return }
        // A chat that came in under its id takes the name the phone has for it.
        for chat in knownChats where !WAJID.isPlaceholderName(chat.name, for: chat.jid) {
            if let shown = inbox.conversations[chat.jid]?.name, WAJID.isPlaceholderName(shown, for: chat.jid) {
                inbox.rename(chat.jid, to: chat.name)
            }
        }
        // Groups the gateway only knows by their id ("Group 3162…"): named from the list of your groups (one call),
        // and any left over asked one by one; one still unnamed is asked again a while later.
        let unnamed = knownChats.filter { WAJID.isGroup($0.jid) && WAJID.isPlaceholderName($0.name, for: $0.jid) }.map(\.jid)
            + inbox.conversations.values.filter { WAJID.isGroup($0.id) && WAJID.isPlaceholderName($0.name, for: $0.id) }.map(\.id)
        guard !unnamed.isEmpty else { return }
        let groupList = await provider.groupNames()
        guard gen == generation else { return }
        for jid in Set(unnamed) {
            if let name = groupList[jid] {
                nameGroup(jid, name)
            } else if shouldAskName(jid) {
                guard let name = await provider.groupName(jid), gen == generation else { continue }
                nameGroup(jid, name)
            }
        }
    }

    /// Whether an unnamed group may be asked for its name now: never twice within half an hour.
    private func shouldAskName(_ jid: String) -> Bool {
        if let asked = namingGroups[jid], Date().timeIntervalSince(asked) < 1800 { return false }
        namingGroups[jid] = Date()
        return true
    }

    /// A group the gateway could name is reachable now: its picture, if it had none, is asked for again too.
    private func nameGroup(_ jid: String, _ name: String) {
        if avatars[jid] == nil { avatarAsked[jid] = nil }
        if let index = knownChats.firstIndex(where: { $0.jid == jid }) { knownChats[index].name = name }
        if let shown = inbox.conversations[jid]?.name, WAJID.isPlaceholderName(shown, for: jid) { inbox.rename(jid, to: name) }
    }

    private func poll() {
        guard let provider, !polling, !webhookAlive, backfilled else { return }
        polling = true
        let since = lastPoll.addingTimeInterval(-30)   // a little overlap; duplicates are dropped
        let started = Date()
        let gen = generation
        Task {
            defer { if gen == generation { polling = false } }
            guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
            lastPoll = started
            ingest(messages, announce: true)
        }
    }

    private func ingest(_ messages: [WAMessage], announce: Bool) {
        var fresh: String?
        let quietBefore = Date().addingTimeInterval(-Self.freshness)
        // Added to a copy and published once, only when something changed: a poll overlaps the last one, so most of what
        // it brings is already here, and every write to the published inbox redraws the panel.
        var next = inbox
        var keys: [String] = []
        for message in messages {
            let key = WAJID.normalized(message.chat)
            // Their message is here: they stopped typing it.
            if !message.fromMe {
                ChatTypingCenter.shared.stopped(chat: ChatInbox.key(app: "whatsapp", id: chatKey(key)), person: WAJID.isGroup(key) ? WAJID.normalized(message.sender) : key)
            }
            let outcome = next.add(message, filters: filters, quietBefore: quietBefore)
            if !keys.contains(key) { keys.append(key) }
            if outcome == .notify, !message.fromMe { fresh = key }
        }
        if next != inbox { inbox = next }
        for key in keys { nameGroupIfNeeded(key) }
        if announce, let fresh { onMessage?(chatKey(fresh)) }
    }

    /// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
    private func nameGroupIfNeeded(_ chat: String) {
        guard WAJID.isGroup(chat), let provider, let conversation = inbox.conversations[chat],
              WAJID.isPlaceholderName(conversation.name, for: chat) else { return }
        // A name the chat list already learned comes first: no call at all.
        if let known = known(chat), !WAJID.isPlaceholderName(known.name, for: chat) {
            inbox.rename(chat, to: known.name)
            return
        }
        guard shouldAskName(chat) else { return }
        let gen = generation
        Task {
            if let name = await provider.groupName(chat), gen == generation { nameGroup(chat, name) }
        }
    }

    /// Whether a poll can be voted on from Nook: the gateway has to be able to (OpenWA can, GOWA cannot yet).
    var canVote: Bool { isConnected && provider?.canVote == true }

    /// Your vote on a poll, after your own click: sent through the gateway, and the poll shows it at once.
    func vote(_ choice: [String], poll: String, chat: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        do {
            try await provider.vote(chat: key, poll: poll, choice: choice)
        } catch {
            throw NookError(tr("chat.poll.failed"))
        }
        inbox.applyVote(WAPollVote(poll: poll, choice: choice), chat: key, voter: WAPoll.me)
    }

    /// Fetches the pictures of these chats that Nook does not have yet: the gateway says where each one is on WhatsApp's
    /// own picture server, and only that server is asked for it. One that has none is asked again after six hours.
    func loadAvatars(_ chats: [String]) async {
        guard let provider, isConnected else { return }
        let gen = generation
        for chat in chats.map(WAJID.normalized) where WAJID.kind(chat) != .status {
            // The Chats tab starts this again (and cancels the run before) when the chat list comes in: a cancelled run
            // stops here, before it marks the chats it did not get to as asked for six hours.
            if Task.isCancelled { return }
            if avatars[chat] != nil { continue }
            let target = ChatMedia.destination(key: "wa-avatar-" + chat, name: "avatar.jpg")
            if FileManager.default.fileExists(atPath: target.path) {
                avatars[chat] = target.path
                continue
            }
            let address: URL?
            if WAJID.kind(chat) == .channel {
                // A channel's picture comes with the channel list; until that list is read there is nothing to ask.
                address = channelPictures[chat]
                if address == nil { continue }
            } else {
                if let asked = avatarAsked[chat], Date().timeIntervalSince(asked) < 6 * 3600 { continue }
                address = await provider.avatar(chat)
                // Asked only counts once answered: a request cut off by cancelling is asked again on the next run.
                if Task.isCancelled { return }
                avatarAsked[chat] = Date()
            }
            // Only WhatsApp's own picture servers are asked.
            guard let url = address, gen == generation, WAAvatar.isWhatsApp(url) else { continue }
            let answer = try? await Self.avatarSession.data(from: url)
            if Task.isCancelled {
                avatarAsked[chat] = nil
                return
            }
            guard let answer, gen == generation,
                  (answer.1 as? HTTPURLResponse)?.statusCode == 200, answer.0.count < 2_000_000,
                  Self.thumbnail(answer.0, side: 8) != nil else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? answer.0.write(to: target, options: .atomic)) != nil else { continue }
            avatars[chat] = target.path
        }
    }

    /// The newest messages of one chat: the gateway's history together with what came in live, so a message that
    /// arrived after the gateway's stored history is never left out (falls back to what Nook kept).
    func messages(of chat: String, limit: Int = 20) async throws -> [WAMessage] {
        guard isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        let fetched = (try? await fetchHistory(key, limit: limit).messages) ?? []
        let kept = inbox.conversations[key]?.messages ?? []
        return WAInbox.newest(fetched.filter { !inbox.wasDeleted($0.id) }, kept, limit: limit)
    }

    /// Asks the gateway for a chat's newest `limit` messages and keeps them in the inbox; what came (the polls GOWA keeps
    /// on this Mac among them), and how many of them came from its history: fewer than `limit` means it has nothing older.
    /// Throws when the gateway could not answer, so a failed request is never taken for the chat's start.
    private func fetchHistory(_ key: String, limit: Int) async throws -> (messages: [WAMessage], gateway: Int) {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let history = try await provider.messages(chat: key, limit: limit, me: me)
        var fetched = history
        // GOWA leaves polls out of a chat's history: the ones it keeps on this Mac come in beside it, within the time
        // the history covers (all of them when it reaches back to the chat's start).
        if provider.kind == .gowa {
            let oldest = fetched.count >= limit ? fetched.first?.date : nil
            let polls = await WhatsAppGOWAProcess.shared.storedPolls(chat: key).filter { poll in oldest.map { poll.date >= $0 } ?? true }
            if !polls.isEmpty { fetched = (fetched + polls).sorted { $0.date < $1.date } }
        }
        for message in fetched { inbox.add(message, filters: filters, history: true) }
        // An opened chat keeps the name the chat list showed: the gateway's history may only know it by its id.
        if let shown = inbox.conversations[key]?.name, WAJID.isPlaceholderName(shown, for: key),
           let known = known(key), !WAJID.isPlaceholderName(known.name, for: key) {
            inbox.rename(key, to: known.name)
        }
        nameGroupIfNeeded(key)
        return (fetched, history.count)
    }

    /// "Load older messages": the chat keeps `WAInbox.olderStep` more and asks the gateway for that many (in pages, as
    /// the gateway allows). True when messages were added; the chat remembers when the gateway has nothing older left,
    /// judged by what the gateway gave, not by what the chat kept (a blank or a vote shows nothing but is no start).
    func loadOlder(_ chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        guard isConnected, let limit = inbox.growCapacity(key) else { return false }
        let before = inbox.conversations[key]?.messages.count ?? 0
        guard let fetched = try? await fetchHistory(key, limit: limit) else { return false }
        if fetched.gateway < limit { inbox.markOldestReached(key) }
        return (inbox.conversations[key]?.messages.count ?? 0) > before
    }

    /// A chat's messages from the gateway, so its card can scroll back and shows what the live feed missed (the Mac
    /// slept, a webhook got lost): fetched each time the chat opens, at most once per `WAInbox.historyRefresh`. True
    /// when the conversation changed. A history shorter than a chat keeps is the whole chat: no older ones to load.
    func loadHistory(_ chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        let now = Date()
        guard isConnected, WAInbox.historyDue(last: historyFetched[key], now: now) else { return false }
        historyFetched[key] = now
        let before = inbox.conversations[key]?.messages
        if let fetched = try? await fetchHistory(key, limit: WAInbox.keep), fetched.gateway < WAInbox.keep {
            inbox.markOldestReached(key)
        }
        return inbox.conversations[key]?.messages != before
    }

    /// Whether Nook told WhatsApp this device is online: while a WhatsApp chat is open in Nook, as WhatsApp Web does, so
    /// WhatsApp says who is typing. As long as it is, the phone may hold back its own notifications.
    private var online = false

    /// The chat that is open in Nook, whose presence is watched.
    private var onlineChat: String?

    /// A WhatsApp chat opened in Nook (its JID), or none is open any more (nil).
    func setOnline(_ chat: String?) {
        let key = chat.map(WAJID.normalized)
        guard key != onlineChat || (key != nil) != online, let provider, isConnected else { return }
        online = key != nil
        onlineChat = key
        Task { await provider.setOnline(key != nil, chat: key) }
    }

    /// A chat on the phone that wrote nothing since Nook was linked has no messages here, so its row in the Chats tab
    /// has no line: its newest few are asked of the gateway once, when the row comes into view, one chat at a time.
    func loadLine(_ chat: String) {
        let key = WAJID.normalized(chat)
        guard isConnected, inbox.conversations[key] == nil, linesAsked.insert(key).inserted else { return }
        linesWaiting.append(key)
        guard !linesLoading else { return }
        linesLoading = true
        let gen = generation
        Task {
            while gen == generation, !linesWaiting.isEmpty {
                let next = linesWaiting.removeFirst()
                guard inbox.conversations[next] == nil else { continue }
                _ = try? await fetchHistory(next, limit: Self.lineFetch)
            }
            linesLoading = false
        }
    }

    /// How many messages a row's line is looked for in: a few, as the newest can be a reaction or a vote that shows nothing.
    static let lineFetch = 5

    /// A group's members, asked of the gateway when the chat opens (again after ten minutes, for who joined or left),
    /// so its info lists them and your messages' ticks wait for all of them. True when the conversation changed.
    @discardableResult
    func loadMembers(_ chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        guard isConnected, let provider, WAJID.isGroup(key),
              membersLoaded[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return false }
        membersLoaded[key] = Date()
        let members = WAMembers.others(await provider.groupMembers(key), me: me)
        guard !members.isEmpty else { return false }
        return inbox.setMembers(members, chat: key)
    }

    // MARK: Files

    /// Where opened files wait for the app that shows them: a folder of Nook's own in the temporary folder,
    /// emptied when Nook starts and quits.
    nonisolated static var openedFilesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Nook WhatsApp", isDirectory: true)
    }

    nonisolated static func clearOpenedFiles() {
        try? FileManager.default.removeItem(at: openedFilesFolder)
    }

    /// A message's file on this Mac, fetched from the gateway only when the card shows it or you open it.
    func download(message id: String, chat: String) async throws -> URL {
        if let saved = previews[id]?.file, FileManager.default.fileExists(atPath: saved.path) { return saved }
        let (message, file) = try await fetchFile(message: id, chat: chat)
        let url = try Self.save(file, media: message.media)
        Log.connectors.info("WhatsApp: opened a file")
        return url
    }

    /// A message's file from the gateway, checked: the message is known here, holds a file, and it is not too large.
    private func fetchFile(message id: String, chat: String) async throws -> (WAMessage, WAFile) {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        guard let message = inbox.conversations[key]?.messages.first(where: { $0.id == id }), message.media.isOpenable else {
            throw NookError(tr("whatsapp.file.missing"))
        }
        let file: WAFile
        do {
            file = try await provider.media(chat: key, message: id)
        } catch let error as WAError {
            switch error {
            case .unreachable: throw NookError(tr("whatsapp.status.unreachable"))
            case .unauthorized: throw NookError(tr("whatsapp.status.unauthorized"))
            case .notLoggedIn: throw NookError(tr("whatsapp.status.needsQR"))
            case .refused: throw NookError(tr("whatsapp.file.failed"))
            }
        }
        guard !file.data.isEmpty else { throw NookError(tr("whatsapp.file.failed")) }
        guard file.data.count <= WAFile.maxBytes else { throw NookError(tr("whatsapp.file.tooLarge")) }
        return (message, file)
    }

    /// Saves a fetched file in its own folder under Nook's temporary one, under a name the Mac recognizes.
    private static func save(_ file: WAFile, media: WAMedia) throws -> URL {
        let name = media.safeFileName(given: file.name, mimeType: file.mimeType)
        let folder = openedFilesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try file.data.write(to: url, options: .atomic)
        return url
    }

    /// How many fetched files stay at most; the oldest go first, from memory and from disk.
    static let previewLimit = 48
    /// How long a preview that failed waits before it is tried again.
    static let previewRetry: TimeInterval = 60

    /// A file already fetched for the notch card.
    func preview(_ id: String) -> WAPreview? { previews[id] }

    /// Fetches these messages' files for the card (a photo, a video, a document) with a picture of each: the photo
    /// itself, the video's first frame, the document's first page. One that failed is tried again after a minute.
    /// True when at least one new preview came in while the link stayed the same.
    func loadPreviews(_ ids: [String], chat: String) async -> Bool {
        let gen = generation
        var loaded = false
        for id in ids where previews[id] == nil && !previewsLoading.contains(id) {
            if let failed = previewFailed[id], Date().timeIntervalSince(failed) < Self.previewRetry { continue }
            previewsLoading.insert(id)
            let fetched = try? await fetchFile(message: id, chat: chat)
            previewsLoading.remove(id)
            guard gen == generation else { return false }
            guard let fetched, let url = try? Self.save(fetched.1, media: fetched.0.media) else {
                previewFailed[id] = Date()
                continue
            }
            let image = await Self.picture(of: url, data: fetched.1.data, media: fetched.0.media)
            guard gen == generation else { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return false }
            previewFailed[id] = nil
            previews[id] = WAPreview(file: url, image: image)
            previewOrder.append(id)
            loaded = true
        }
        while previewOrder.count > Self.previewLimit {
            let old = previewOrder.removeFirst()
            if let file = previews.removeValue(forKey: old)?.file {
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
        }
        return loaded
    }

    /// A small picture of a file: the photo, a video's first frame or a document's first page.
    private static func picture(of url: URL, data: Data, media: WAMedia) async -> NSImage? {
        switch media {
        case .image:
            return thumbnail(data)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        case .document:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 128), scale: 2,
                                                       representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        default:
            return nil
        }
    }

    /// The photo at most `side` pixels on its longest side, decoded straight to that size so a large photo costs little.
    nonisolated static func thumbnail(_ data: Data, side: CGFloat = 480) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Marks the chat read in Nook only: WhatsApp (and your phone) keep it unread, and the sender sees no blue ticks.
    func markReadInNook(_ chat: String) {
        let key = WAJID.normalized(chat)
        inbox.markRead(key)
        readInNook[key] = readMark(key)
        clearMarkedUnread(key)
    }

    /// When a read of the chat holds from: now, or its newest message when that is dated later (the phone's or the
    /// server's clock a little ahead of this Mac), so that message never counts as new again after the read.
    private func readMark(_ key: String) -> Date {
        [Date(), inbox.conversations[key]?.messages.last?.date, known(key)?.last].compactMap { $0 }.max() ?? Date()
    }

    /// Takes back a "Mark as unread" once the chat is read.
    private func clearMarkedUnread(_ key: String) {
        if markedUnread[key] != nil { markedUnread[key] = nil }
    }

    /// Whether a chat is still unread in WhatsApp itself: its newest message is someone else's and WhatsApp did not say
    /// it was read there after it arrived (a read on the phone or in WhatsApp on the Mac comes in as it happens). History
    /// loaded at launch counts too: GOWA says nothing of what was read before, and claiming "read in WhatsApp" for a chat
    /// that is not was worse than offering "Mark as read" once too often. Then "Mark as read" can still tell WhatsApp,
    /// also when Nook shows no badge any more.
    func waitsInWhatsApp(_ chat: String) -> Bool {
        let key = WAJID.normalized(chat)
        if carried(key) > 0 { return true }
        let readThere = readInWhatsApp[key] ?? .distantPast
        if let conversation = inbox.conversations[key], let last = conversation.messages.last {
            // OpenWA counts unread itself: a chat it says is read, as of this message or later, is read there.
            if gatewayCountsUnread, let known = known(key), known.unread == 0, known.last >= last.date {
                return false
            }
            return !last.fromMe && last.date > readThere
        }
        guard let known = known(key) else { return false }
        return known.unread > 0 && known.last > readThere
    }

    /// Whether Nook knows where a chat stands in WhatsApp: something new here, read or answered in it, or a gateway
    /// that counts unread messages itself (OpenWA). GOWA counts nothing, so a chat known only from the phone's list or
    /// from history loaded at launch shows no mark in the list rather than a wrong one.
    func readIsKnown(_ chat: String) -> Bool {
        let key = WAJID.normalized(chat)
        if gatewayCountsUnread || readInNook[key] != nil || readInWhatsApp[key] != nil { return true }
        if inbox.conversations[key]?.messages.last?.fromMe == true { return true }
        return unread(key) > 0
    }

    /// Whether the gateway counts unread messages itself (OpenWA). The running gateway's own kind when there is one: the
    /// Chats tab asks this for every chat on each redraw, and a settings read per chat kept the main thread busy.
    private var gatewayCountsUnread: Bool { (provider?.kind ?? WhatsAppSettings.gateway) == .openwa }

    /// The phone's entry for a chat (`jid` normalized), without going through the whole list.
    private func known(_ jid: String) -> WAChatInfo? {
        knownIndex[jid].map { knownChats[$0] }
    }

    /// Where the chat stands, as every chat in the Chats tab says it: new, read in Nook only, or read in WhatsApp too.
    func readState(_ chat: String) -> ChatReadState {
        let count = unread(chat)
        if count > 0 { return .unread(count) }
        return waitsInWhatsApp(chat) ? .readInNook : .read
    }

    /// "Mark as read", by hand: read in Nook and in WhatsApp, so the people who wrote see that you read it (blue ticks
    /// where they have them). Always sent: you chose to. Read in Nook at once; a gateway that refuses (or a phone that is
    /// not linked) throws with a sentence you can act on, as every other chat app's "Mark as read" does.
    func markReadInWhatsApp(_ chat: String) async throws {
        let key = WAJID.normalized(chat)
        readInNook[key] = readMark(key)
        inbox.markRead(key)
        clearMarkedUnread(key)
        guard let provider, isConnected else { throw NookError(statusLine) }
        let last = inbox.conversations[key]?.messages.last { !$0.fromMe }?.id
        do {
            try await provider.markRead(chat: key, lastIncoming: last)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        readInWhatsApp[key] = readMark(key)
    }

    /// The unread count a chat shows in Nook: what came in while Nook ran, else what WhatsApp itself counts (when the
    /// gateway says), until you read it in Nook.
    func unread(_ chat: String) -> Int {
        let key = WAJID.normalized(chat)
        let counted = (inbox.conversations[key]?.unread ?? 0) + carried(key)
        if counted > 0 { return counted }
        // Marked unread by hand, until you read it or answer it (on the phone too).
        if let mark = markedUnread[key], mark > (inbox.conversations[key]?.messages.last { $0.fromMe }?.date ?? .distantPast) {
            return 1
        }
        guard let known = known(key), known.unread > 0 else { return 0 }
        // Read in Nook, or on the phone, since the list's newest message.
        if let read = [readInNook[key], readInWhatsApp[key]].compactMap({ $0 }).max(), known.last <= read { return 0 }
        return known.unread
    }

    /// What a chat still counts unread from before Nook restarted: nothing once it was read or answered in since.
    private func carried(_ key: String) -> Int {
        guard let carry = carriedUnread[key], carry.holds(readSince: readSince(key)) else { return 0 }
        return carry.count
    }

    /// When a chat was last read (in Nook, in WhatsApp) or answered in.
    private func readSince(_ key: String) -> Date? {
        [readInNook[key], readInWhatsApp[key], inbox.conversations[key]?.messages.last { $0.fromMe }?.date].compactMap { $0 }.max()
    }

    /// Writes down what each chat counts unread, for the next launch; only when that changed.
    private func keepUnread() {
        let kept = WAUnreadCarry.kept(carried: carriedUnread, inbox: inbox, readSince: readSince)
        guard kept != keptUnread else { return }
        keptUnread = kept
        WhatsAppSettings.setUnreadCarry(kept, account: account)
    }

    // MARK: The shared inbox

    /// What the shared inbox needs of a chat besides its messages (`WhatsAppExport.Facts`): where it stands by this
    /// link's own count and marks, its picture, whether the phone lists it, and the files fetched for `messages`.
    func exportFacts(_ jid: String, account name: String?, messages: [WAMessage]) -> WhatsAppExport.Facts {
        let key = WAJID.normalized(jid)
        var facts = WhatsAppExport.Facts(key: chatKey(key))
        facts.account = name
        facts.unread = unread(key)
        facts.waitsInApp = waitsInWhatsApp(key)
        facts.readKnown = readIsKnown(key)
        facts.avatar = avatars[key]
        let listed = known(key)
        facts.listed = listed != nil
        facts.activity = listed?.last
        for message in messages {
            if let file = previews[message.id]?.file.path { facts.files[message.id] = file }
        }
        return facts
    }

    /// Marks the chat unread in Nook (WhatsApp itself keeps it as it is).
    func markUnread(_ chat: String) {
        let key = WAJID.normalized(chat)
        carriedUnread[key] = nil
        readInNook[key] = nil
        // The mark is kept on disk, so it holds after a restart too (the count in the inbox lives in memory only); a chat
        // Nook has no messages of yet has no count to raise, and the mark stands in for one.
        markedUnread[key] = Date()
        if inbox.conversations[key] != nil { inbox.markUnread(key) }
    }

    func markRead(_ chat: String) {
        let key = WAJID.normalized(chat)
        let hadUnread = (inbox.conversations[key]?.unread ?? 0) + carried(key) > 0
        readInNook[key] = readMark(key)
        clearMarkedUnread(key)
        guard let provider, let conversation = inbox.conversations[key] else { return }
        inbox.markRead(key)
        guard hadUnread, ChatNoticeRulesStore.shared.rules.readsOnReply("whatsapp") else { return }
        let last = conversation.messages.last { !$0.fromMe }?.id
        Task { try? await provider.markRead(chat: key, lastIncoming: last) }
    }

    // MARK: Sending

    /// Who a name, number or chat id means: a chat on the phone or one that wrote to you, or one of `also` (chats that
    /// WhatsApp on this Mac has, which also name the groups the gateway only knows by their id). Never a new number:
    /// Nook is no bulk sender and a wrong guess must not reach a stranger.
    func resolve(_ recipient: String, also: [(jid: String, name: String)] = []) -> (jid: String, name: String)? {
        let wanted = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        var chats: [(jid: String, name: String)] = inbox.sorted.map { ($0.id, $0.name) }
        for chat in knownChats where !chats.contains(where: { $0.jid == chat.jid }) {
            chats.append((chat.jid, chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name))
        }
        let extra = also.map { (jid: WAJID.normalized($0.jid), name: $0.name) }
            .filter { !$0.jid.isEmpty && !WAJID.isStatus($0.jid) && !$0.jid.contains("broadcast") }
        for index in chats.indices where WAJID.isPlaceholderName(chats[index].name, for: chats[index].jid) {
            if let named = extra.first(where: { $0.jid == chats[index].jid && !WAJID.isPlaceholderName($0.name, for: $0.jid) }) {
                chats[index].name = named.name
            }
        }
        for chat in extra where !chats.contains(where: { $0.jid == chat.jid }) {
            chats.append((chat.jid, chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name))
        }
        return WhatsAppRecipients.match(wanted, in: chats)
    }

    /// The names to suggest when a name matches no chat: the chats that wrote lately, then those on the phone.
    func chatNames() -> [String] {
        let names = (inbox.sorted.map(\.name) + knownChats.prefix(12).map(\.name)).filter { !$0.isEmpty }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique
    }

    /// Sends a text to a chat, as an answer to its message `replyTo` when set. Throws with a sentence the user can act on.
    @discardableResult
    func send(_ text: String, to recipient: String, replyTo: String? = nil,
              also: [(jid: String, name: String)] = []) async throws -> String {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard body.count <= WAReply.maxLength else { throw NookError(tr("whatsapp.reply.tooLong")) }
        guard let target = resolve(recipient, also: also) else {
            throw NookError(tr("whatsapp.reply.unknown", recipient, chatNames().prefix(12).joined(separator: ", ")))
        }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        let gen = generation
        do {
            let id = try await provider.send(text: body, to: target.jid, replyTo: replyTo)
            guard gen == generation else { return target.name }
            var mine = WAMessage(id: id ?? "nook-\(UUID().uuidString)", chat: target.jid, sender: me ?? "",
                                 senderName: "", text: body, date: Date(), fromMe: true)
            mine.chatName = target.name
            mine.replyTo = replyTo
            inbox.add(mine, filters: filters, name: target.name)
            // Answering reads the conversation.
            if ChatNoticeRulesStore.shared.rules.readsOnReply("whatsapp") {
                let last = inbox.conversations[target.jid]?.messages.last { !$0.fromMe }?.id
                Task { try? await provider.markRead(chat: target.jid, lastIncoming: last) }
            }
            Log.connectors.info("WhatsApp: message sent")
            return target.name
        } catch let error as WAError {
            throw Self.sentence(error)
        }
    }

    /// What the linked gateway can send besides text (files, polls, places, contacts); empty while it is not linked.
    var sends: Set<ChatOutgoing.Kind> { isConnected ? provider?.sends ?? [] : [] }

    /// Sends a file, a poll, a place or a contact card to a chat, as an answer to its message `replyTo` when set. A file
    /// is first made to fit what WhatsApp takes (`ChatSendPrep`); once sent, the chat shows it at once, the file from
    /// this Mac. Returns the chat's name. Throws with a sentence the user can act on.
    @discardableResult
    func send(_ outgoing: ChatOutgoing, to recipient: String, replyTo: String? = nil) async throws -> String {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.sends.contains(outgoing.kind) else { throw NookError(tr("chat.compose.unsupported")) }
        guard let target = resolve(recipient) else {
            throw NookError(tr("whatsapp.reply.unknown", recipient, chatNames().prefix(12).joined(separator: ", ")))
        }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        var outgoing = outgoing
        if case .file(let file) = outgoing {
            guard !file.tooLarge else { throw NookError(tr("chat.compose.tooLarge", file.name)) }
            outgoing = .file(try await ChatSendPrep.forWhatsApp(file))
        }
        let gen = generation
        do {
            let id = try await provider.send(outgoing, to: target.jid, replyTo: replyTo) ?? "nook-\(UUID().uuidString)"
            guard gen == generation else { return target.name }
            var mine = WAMessage(id: id, chat: target.jid, sender: me ?? "", senderName: "", text: "", date: Date(), fromMe: true)
            mine.chatName = target.name
            mine.replyTo = replyTo
            switch outgoing {
            case .file(let file):
                mine.text = file.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                mine.media = Self.media(of: file)
                await showSent(file, as: id, media: mine.media)
            case .poll(let poll):
                mine.poll = WAPoll(question: poll.cleanQuestion, options: poll.cleanOptions, multiple: poll.multiple)
            case .location(let place):
                mine.media = .location
                mine.text = place.title
            case .contact(let card):
                mine.media = .contact
                mine.text = card.name
            }
            inbox.add(mine, filters: filters, name: target.name)
            Log.connectors.info("WhatsApp: \(outgoing.kind.rawValue) sent")
            return target.name
        } catch let error as WAError {
            throw Self.sentence(error)
        }
    }

    /// What a sent file is in WhatsApp's own terms; a GIF is the looping video it was sent as.
    private static func media(of file: ChatAttachment) -> WAMedia {
        let seconds = file.seconds.map { Int($0.rounded()) }
        switch file.kind {
        case .photo: return .image
        case .video, .gif: return .video
        case .sticker: return .sticker
        case .audio: return .audio(seconds: seconds)
        case .voice: return .voice(seconds: seconds)
        case .file: return .document(name: file.name)
        }
    }

    /// The file you sent shows in its bubble straight away, from a copy in Nook's temporary folder (the one a card's
    /// previews are kept in, and cleared with them), so it never has to come back from the gateway.
    private func showSent(_ file: ChatAttachment, as id: String, media: WAMedia) async {
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { return }
        let folder = Self.openedFilesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file.url, to: copy)
        } catch {
            return
        }
        let image = await Self.picture(of: copy, data: data, media: media)
        previews[id] = WAPreview(file: copy, image: image)
        previewOrder.append(id)
    }

    /// Puts `emoji` on a message of a chat that is in the inbox, or takes it back when it is already yours. Returns the
    /// chat's name. Throws with a sentence the user can act on.
    @discardableResult
    func react(_ emoji: String, to id: String, chat: String) async throws -> String {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        guard let conversation = inbox.conversations[key],
              let message = conversation.messages.first(where: { $0.id == id }) else {
            throw NookError(tr("whatsapp.react.missing"))
        }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        let old = message.reactions.first(where: \.fromMe)?.emoji
        // The same emoji again takes it back, as on the phone.
        let new = old == emoji ? "" : emoji
        let gen = generation
        do {
            try await provider.react(new, to: id, chat: key, old: old)
            guard gen == generation else { return conversation.name }
            inbox.applyReaction(new, message: id, chat: key, sender: me ?? "", fromMe: true)
            Log.connectors.info("WhatsApp: reaction sent")
            return conversation.name
        } catch let error as WAError {
            throw Self.sentence(error)
        }
    }

    // MARK: Editing, deleting, pinning, archiving

    /// What the linked gateway can do with your messages and chats besides sending (both gateways can all four); false
    /// while it is not linked.
    var canEdit: Bool { isConnected && provider?.canEdit == true }
    var canDelete: Bool { isConnected && provider?.canDelete == true }
    var canPin: Bool { isConnected && provider?.canPin == true }
    var canArchive: Bool { isConnected && provider?.canArchive == true }
    var canMuteInWhatsApp: Bool { isConnected && provider?.canMute == true }

    /// Whether the chat is muted on the phone, as far as Nook knows (see `mutedChats`).
    func isMutedInWhatsApp(_ chat: String) -> Bool { mutedChats.contains(WAJID.normalized(chat)) }

    /// Mutes the chat on the phone for good, or unmutes it, after your own click.
    func setMutedInWhatsApp(_ muted: Bool, chat: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.canMute else { throw NookError(tr("chat.compose.unsupported")) }
        let key = WAJID.normalized(chat)
        let gen = generation
        do {
            try await provider.setMuted(muted, chat: key)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        guard gen == generation else { return }
        if muted { mutedChats.insert(key) } else { mutedChats.remove(key) }
        Log.connectors.info("WhatsApp: chat \(muted ? "muted" : "unmuted")")
    }

    /// Whether the chat is pinned on the phone, as far as Nook knows: pinned from Nook, or so in the gateway's chat
    /// list. False when that is not known.
    func isPinned(_ chat: String) -> Bool { pinnedChats.contains(WAJID.normalized(chat)) }

    /// The new text of your own message, after your own Return or click; the chat shows it at once. Throws with a
    /// sentence the user can act on.
    func edit(_ message: String, chat: String, to text: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.canEdit else { throw NookError(tr("chat.compose.unsupported")) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard body.count <= WAReply.maxLength else { throw NookError(tr("whatsapp.reply.tooLong")) }
        let key = WAJID.normalized(chat)
        // Only your own messages can be changed; one Nook does not keep is left to the gateway to judge.
        if let kept = inbox.conversations[key]?.messages.first(where: { $0.id == message }), !kept.fromMe {
            throw NookError(tr("chat.action.failed"))
        }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        let gen = generation
        do {
            try await provider.edit(message, chat: key, to: body)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        guard gen == generation else { return }
        inbox.applyEdit(body, message: message, chat: key)
        Log.connectors.info("WhatsApp: message edited")
    }

    /// Deletes a message for everyone, after you confirmed it; it leaves the chat in Nook at once, as on the phone.
    /// Throws with a sentence the user can act on.
    func delete(_ message: String, chat: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.canDelete else { throw NookError(tr("chat.compose.unsupported")) }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        let key = WAJID.normalized(chat)
        let gen = generation
        do {
            try await provider.delete(message, chat: key)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        guard gen == generation else { return }
        inbox.applyDelete(message: message, chat: key)
        Log.connectors.info("WhatsApp: message deleted")
    }

    /// Pins the chat on the phone, or unpins it, after your own click; Nook remembers it for `isPinned`.
    func setPinned(_ pinned: Bool, chat: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.canPin else { throw NookError(tr("chat.compose.unsupported")) }
        let key = WAJID.normalized(chat)
        let gen = generation
        do {
            try await provider.setPinned(pinned, chat: key)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        guard gen == generation else { return }
        if pinned { pinnedChats.insert(key) } else { pinnedChats.remove(key) }
        Log.connectors.info("WhatsApp: chat \(pinned ? "pinned" : "unpinned")")
    }

    /// Archives the chat on the phone, after your own click. WhatsApp unpins a chat it archives.
    func archive(_ chat: String) async throws {
        guard let provider, isConnected else { throw NookError(statusLine) }
        guard provider.canArchive else { throw NookError(tr("chat.compose.unsupported")) }
        let key = WAJID.normalized(chat)
        let gen = generation
        do {
            try await provider.archive(key)
        } catch let error as WAError {
            throw Self.actionSentence(error)
        }
        guard gen == generation else { return }
        pinnedChats.remove(key)
        Log.connectors.info("WhatsApp: chat archived")
    }

    /// As `sentence`, except that a refusal without words of the gateway's own (only a status code, or none at all)
    /// becomes Nook's sentence for an action that did not work.
    private static func actionSentence(_ error: WAError) -> NookError {
        if case .refused(let why) = error {
            let reason = why.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty || reason.hasPrefix("HTTP ") { return NookError(tr("chat.action.failed")) }
        }
        return sentence(error)
    }

    private static func sentence(_ error: WAError) -> NookError {
        switch error {
        case .unreachable: return NookError(tr("whatsapp.status.unreachable"))
        case .unauthorized: return NookError(tr("whatsapp.status.unauthorized"))
        case .notLoggedIn: return NookError(tr("whatsapp.status.needsQR"))
        case .refused(let why): return NookError(why)
        }
    }

    func ignore(_ chat: String) {
        ChatNoticeRulesStore.shared.setHidden(true, chat: ChatInbox.key(app: "whatsapp", id: chatKey(WAJID.normalized(chat))))
    }

    /// Keeps the chat but stops it from reaching you (the card's Mute).
    func mute(_ chat: String) {
        ChatNoticeRulesStore.shared.setMode(.muted, for: ChatInbox.key(app: "whatsapp", id: chatKey(WAJID.normalized(chat))))
    }

    /// The notice rules changed (`ChatNoticeRulesStore`): this account follows them, and lets go of a chat now hidden.
    func applyNoticeRules() {
        let next = ChatNoticeRulesStore.shared.filters(account: account)
        guard next != filters else { return }
        filters = next
        for jid in next.ignored where inbox.conversations[jid] != nil { inbox.remove(jid) }
    }

    /// One check from Settings' "Test": what the gateway says, in a sentence.
    func testConnection() async -> String {
        guard let provider = provider ?? WhatsAppSettings.makeProvider(account: account) else { return tr("whatsapp.status.badURL") }
        var attempt = 0
        while true {
            do {
                let status = try await provider.status()
                switch status.link {
                case .connected: return tr("whatsapp.status.connected", status.me.map(WAJID.displayNumber) ?? "")
                case .needsQR: return tr("whatsapp.status.needsQR")
                case .connecting: return tr("whatsapp.status.connecting")
                }
            } catch WAError.unreachable where WhatsAppGOWAProcess.shared.isRunning && attempt < 8 {
                // GOWA just started by Nook: a few seconds to come up.
                attempt += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } catch let error as WAError {
                switch error {
                case .unreachable: return tr("whatsapp.status.unreachable")
                case .unauthorized: return tr("whatsapp.status.unauthorized")
                case .notLoggedIn: return tr("whatsapp.status.needsQR")
                case .refused(let why): return why
                }
            } catch {
                return tr("whatsapp.status.unreachable")
            }
        }
    }
}
