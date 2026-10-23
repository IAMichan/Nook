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
    /// When each chat was last read, by its JID: in Nook ("whatsappReadInNook") or in WhatsApp itself
    /// ("whatsappReadInWhatsApp"). Kept so a restart does not bring back what you already read; marks older than
    /// `ChatReadMarks.maxAge` are forgotten.
    static func readMarks(_ key: String) -> [String: Date] {
        ChatReadMarks.pruned((defaults.dictionary(forKey: key) as? [String: Date]) ?? [:])
    }

    static func setReadMarks(_ marks: [String: Date], _ key: String) {
        defaults.set(ChatReadMarks.pruned(marks), forKey: key)
    }

    /// Read receipts when a message is answered or marked read in the notch; never on mere reception.
    static var markReadOnReply: Bool {
        get { defaults.object(forKey: "whatsappMarkRead") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "whatsappMarkRead") }
    }
    static var filters: WAFilters {
        get {
            let modes = (defaults.dictionary(forKey: "whatsappChatModes") as? [String: String] ?? [:])
                .compactMapValues(WAChatMode.init(rawValue:))
            return WAFilters(muteGroups: defaults.object(forKey: "whatsappMuteGroups") as? Bool ?? true,
                             muteStatus: defaults.object(forKey: "whatsappMuteStatus") as? Bool ?? true,
                             muteChannels: defaults.object(forKey: "whatsappMuteChannels") as? Bool ?? true,
                             ignored: Set(defaults.stringArray(forKey: "whatsappIgnored") ?? []),
                             modes: modes)
        }
        set {
            defaults.set(newValue.muteGroups, forKey: "whatsappMuteGroups")
            defaults.set(newValue.muteStatus, forKey: "whatsappMuteStatus")
            defaults.set(newValue.muteChannels, forKey: "whatsappMuteChannels")
            defaults.set(Array(newValue.ignored).sorted(), forKey: "whatsappIgnored")
            defaults.set(newValue.modes.mapValues(\.rawValue), forKey: "whatsappChatModes")
        }
    }

    /// GOWA: `user:pass` for basic auth. OpenWA: the API key. Beeper: the access token.
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

    static func makeProvider() -> WhatsAppProvider? {
        guard let base = URL(string: url), base.scheme?.hasPrefix("http") == true, base.host != nil else { return nil }
        switch gateway {
        case .gowa: return GOWAProvider(base: base, basicAuth: credential)
        case .openwa: return OpenWAProvider(base: base, apiKey: credential)
        case .beeper: return BeeperProvider(base: base, token: credential)
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
    static let shared = WhatsAppLink()
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
    @Published private(set) var inbox = WAInbox(polls: WAPollStore.load()) {
        didSet { if inbox.pollLedger != oldValue.pollLedger { WAPollStore.save(inbox.pollLedger) } }
    }
    @Published private(set) var link: Link = .off
    @Published private(set) var webhook: Webhook = .off
    @Published private(set) var qrPNG: Data?
    /// This account (JID or number), once linked.
    @Published private(set) var me: String?
    /// The chats on the phone (names to send to), refreshed every few minutes while linked.
    @Published private(set) var knownChats: [WAChatInfo] = []
    /// When a chat was last read in WhatsApp itself: marked read from Nook (by hand), or read on the phone.
    @Published private(set) var readInWhatsApp = WhatsAppSettings.readMarks(WhatsAppLink.readInWhatsAppKey) {
        didSet { WhatsAppSettings.setReadMarks(readInWhatsApp, Self.readInWhatsAppKey) }
    }
    /// When you last read a chat in Nook: WhatsApp's own unread count from before then no longer shows. Kept across
    /// launches, so a chat you read in Nook stays read after a restart.
    @Published private(set) var readInNook = WhatsAppSettings.readMarks(WhatsAppLink.readInNookKey) {
        didSet { WhatsAppSettings.setReadMarks(readInNook, Self.readInNookKey) }
    }
    private static let readInNookKey = "whatsappReadInNook"
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
    @Published var filters = WhatsAppSettings.filters {
        didSet { WhatsAppSettings.filters = filters }
    }

    /// A new message reached you (not a muted group, not your own): the notch shows it.
    var onMessage: ((_ chat: String) -> Void)?
    /// Your own messages in a chat got new ticks (delivered, read).
    var onReceipt: ((_ chat: String) -> Void)?
    /// You read a chat on the phone: what Nook still had waiting for it goes.
    var onReadElsewhere: ((_ chat: String) -> Void)?

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

    private init() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.wake() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in MainActor.assumeIsolated {
                WhatsAppGOWAProcess.shared.stopNow()
                WhatsAppLink.clearOpenedFiles()
            } }
            .store(in: &bag)
    }

    /// Called once at launch.
    func start() {
        Self.clearOpenedFiles()
        update()
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
        guard let provider = WhatsAppSettings.makeProvider() else {
            link = .failed(tr("whatsapp.status.badURL"))
            return
        }
        self.provider = provider
        generation += 1
        link = .connecting
        if provider.kind.hasWebhook { startListener(kind: provider.kind) }
        WhatsAppGOWAProcess.shared.sync()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { WhatsAppLink.shared.onTick() }
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
            inbox.clear()
            knownChats = []
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
            // Without a webhook (Beeper) every tick: its API is on this Mac, so asking costs nothing.
            if tick % 4 == 0 || provider?.kind.hasWebhook == false { poll() }
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
                // Written only when changed: every write redraws whatever watches the link.
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
        let failed: Link
        switch error {
        case .unreachable: failed = .unreachable
        case .unauthorized: failed = .unauthorized
        case .notLoggedIn: failed = .needsQR
        case .refused(let why): failed = .failed(why)
        }
        // A gateway that stays down is asked every few seconds: the same answer redraws nothing.
        if link != failed { link = failed }
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
        listener.onRequest = { request in
            guard request.method == "POST", request.path.hasPrefix(WhatsAppLink.webhookPath) else { return 404 }
            // Signed by the gateway with Nook's secret, over the exact bytes received.
            guard WAWebhook.verify(kind: kind, headers: request.headers, body: request.body, secret: secret) else { return 401 }
            let body = request.body
            Task { @MainActor in WhatsAppLink.shared.received(body, kind: kind) }
            return 200
        }
        listener.onListening = { ok in
            Task { @MainActor in
                let link = WhatsAppLink.shared
                guard link.provider != nil else { return }
                if !ok { link.webhook = .portBusy }
                else if link.webhook == .off || link.webhook == .portBusy { link.webhook = .listening; link.refresh() }
            }
        }
        if !listener.start(port: UInt16(WhatsAppSettings.port)) { webhook = .portBusy }
    }

    private var webhookURL: String { "http://127.0.0.1:\(WhatsAppSettings.port)\(Self.webhookPath)" }

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
            if let changed = inbox.applyReceipt(status, ids: ids, chat: chat) { onReceipt?(changed) }
        case .memberReceipt(let ids, let chat, let member, let status)?:
            if let changed = inbox.applyMemberReceipt(status, ids: ids, chat: chat, member: member) { onReceipt?(changed) }
            // Who is in the group says when everyone has it: asked once, the first time a member answers.
            if WAJID.isGroup(chat), membersLoaded[WAJID.normalized(chat)] == nil {
                Task { @MainActor [weak self] in
                    if let self, await self.loadMembers(chat) { self.onReceipt?(WAJID.normalized(chat)) }
                }
            }
        case .readElsewhere(let chat)?:
            let key = WAJID.normalized(chat)
            readInWhatsApp[key] = Date()
            guard inbox.conversations[key] != nil else { return }
            inbox.markRead(key)
            onReadElsewhere?(key)
        case .reaction(let chat, let message, let emoji, let sender, let fromMe)?:
            // A new emoji redraws the chat's card when it is on screen, as new ticks do; it never brings one up.
            if let changed = inbox.applyReaction(emoji, message: message, chat: chat, sender: sender, fromMe: fromMe) {
                onReceipt?(changed)
            }
        default:
            break
        }
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

    private func loadChats(_ provider: WhatsAppProvider, gen: Int) async {
        lastChatList = Date()
        guard let chats = try? await provider.chats(limit: 200), gen == generation else { return }
        knownChats = chats.map { WAChatInfo(jid: WAJID.normalized($0.jid), name: $0.name, last: $0.last, unread: $0.unread) }
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
        let listed = await provider.groupNames()
        guard gen == generation else { return }
        for jid in Set(unnamed) {
            if let name = listed[jid] {
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
        // Added to a copy and published once, only when something changed: a poll overlaps the one before, so most of
        // what it brings is already here, and each `add` on `inbox` itself would redraw every chat view.
        var next = inbox
        for message in messages {
            let outcome = next.add(message, filters: filters, quietBefore: quietBefore)
            if outcome == .notify, !message.fromMe { fresh = WAJID.normalized(message.chat) }
        }
        if next != inbox { inbox = next }
        for key in Set(messages.map { WAJID.normalized($0.chat) }) { nameGroupIfNeeded(key) }
        if announce, let fresh { onMessage?(fresh) }
    }

    /// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
    private func nameGroupIfNeeded(_ chat: String) {
        guard WAJID.isGroup(chat), let provider, let conversation = inbox.conversations[chat],
              WAJID.isPlaceholderName(conversation.name, for: chat) else { return }
        // A name the chat list already learned comes first: no call at all.
        if let known = knownChats.first(where: { $0.jid == chat }), !WAJID.isPlaceholderName(known.name, for: chat) {
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
        for chat in chats.map(WAJID.normalized) where !WAJID.isBeeper(chat) && WAJID.kind(chat) != .status {
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
        guard let provider, isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        var fetched = (try? await provider.messages(chat: key, limit: limit, me: me)) ?? []
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
           let known = knownChats.first(where: { $0.jid == key }), !WAJID.isPlaceholderName(known.name, for: key) {
            inbox.rename(key, to: known.name)
        }
        nameGroupIfNeeded(key)
        let kept = inbox.conversations[key]?.messages ?? []
        return WAInbox.newest(fetched, kept, limit: limit)
    }

    /// "Load older messages": the chat keeps `WAInbox.olderStep` more and asks the gateway for that many. True when
    /// messages were added; the chat remembers when the gateway has nothing older left.
    func loadOlder(_ chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        guard isConnected, let limit = inbox.growCapacity(key) else { return false }
        let before = inbox.conversations[key]?.messages.count ?? 0
        _ = try? await messages(of: key, limit: limit)
        let after = inbox.conversations[key]?.messages.count ?? 0
        if after < limit { inbox.markOldestReached(key) }
        return after > before
    }

    /// A chat's messages from the gateway, so its card can scroll back and shows what the live feed missed (the Mac
    /// slept, a webhook got lost): fetched each time the chat opens, at most once per `WAInbox.historyRefresh`. True
    /// when the conversation changed.
    func loadHistory(_ chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        let now = Date()
        guard isConnected, WAInbox.historyDue(last: historyFetched[key], now: now) else { return false }
        historyFetched[key] = now
        let before = inbox.conversations[key]?.messages
        _ = try? await messages(of: key, limit: WAInbox.keep)
        return inbox.conversations[key]?.messages != before
    }

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
        readInNook[key] = Date()
    }

    /// Whether a chat is still unread in WhatsApp itself: its newest message is someone else's, it came in unread (or
    /// was read in Nook only since), and it was not read in WhatsApp after it arrived. Then "Mark as read" can still
    /// tell WhatsApp, also when Nook shows no badge any more.
    func waitsInWhatsApp(_ chat: String) -> Bool {
        let key = WAJID.normalized(chat)
        let readThere = readInWhatsApp[key] ?? .distantPast
        if let conversation = inbox.conversations[key], let last = conversation.messages.last {
            guard !last.fromMe, last.date > readThere else { return false }
            return conversation.unread > 0 || (readInNook[key].map { $0 >= last.date } ?? false)
        }
        guard let known = knownChats.first(where: { $0.jid == key }) else { return false }
        return known.unread > 0 && known.last > readThere
    }

    /// Where the chat stands, as every chat in the Chats tab says it: new, read in Nook only, or read in WhatsApp too.
    func readState(_ chat: String) -> ChatReadState {
        let count = unread(chat)
        if count > 0 { return .unread(count) }
        return waitsInWhatsApp(chat) ? .readInNook : .read
    }

    /// "Mark as read", by hand: read in Nook and in WhatsApp, so the people who wrote see that you read it (blue ticks
    /// where they have them). Always sent: you chose to.
    func markReadInWhatsApp(_ chat: String) {
        let key = WAJID.normalized(chat)
        readInNook[key] = Date()
        readInWhatsApp[key] = Date()
        inbox.markRead(key)
        guard let provider, isConnected else { return }
        let last = inbox.conversations[key]?.messages.last { !$0.fromMe }?.id
        Task { try? await provider.markRead(chat: key, lastIncoming: last) }
    }

    /// The unread count a chat shows in Nook: what came in while Nook ran, else what WhatsApp itself counts (when the
    /// gateway says), until you read it in Nook.
    func unread(_ chat: String) -> Int {
        let key = WAJID.normalized(chat)
        if let counted = inbox.conversations[key]?.unread, counted > 0 { return counted }
        guard let known = knownChats.first(where: { $0.jid == key }), known.unread > 0 else { return 0 }
        if let read = readInNook[key], known.last <= read { return 0 }
        return known.unread
    }

    /// Marks the chat unread in Nook (WhatsApp itself keeps it as it is).
    func markUnread(_ chat: String) {
        readInNook[WAJID.normalized(chat)] = nil
        inbox.markUnread(chat)
    }

    func markRead(_ chat: String) {
        let key = WAJID.normalized(chat)
        readInNook[key] = Date()
        guard let provider, let conversation = inbox.conversations[key] else { return }
        let hadUnread = conversation.unread > 0
        inbox.markRead(key)
        guard hadUnread, WhatsAppSettings.markReadOnReply else { return }
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

    /// The chats "@chat …" offers, newest first: those that wrote lately (with how many are new), then the
    /// others on the phone. Never the ones you chose never to see.
    func chatChoices() -> [(name: String, detail: String)] {
        var seen: Set<String> = []
        var choices: [(name: String, detail: String)] = []
        let label = WhatsAppSettings.gateway.chatLabel
        for conversation in inbox.sorted where seen.insert(conversation.id).inserted {
            choices.append((conversation.name, conversation.unread > 0
                ? label + " · " + tr("whatsapp.card.unread", conversation.unread) : label))
        }
        for chat in knownChats.sorted(by: { $0.last > $1.last })
        where !filters.ignored.contains(chat.jid) && seen.insert(chat.jid).inserted {
            choices.append((chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name, label))
        }
        return choices
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
            if WhatsAppSettings.markReadOnReply {
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

    private static func sentence(_ error: WAError) -> NookError {
        switch error {
        case .unreachable: return NookError(tr("whatsapp.status.unreachable"))
        case .unauthorized: return NookError(tr("whatsapp.status.unauthorized"))
        case .notLoggedIn: return NookError(tr("whatsapp.status.needsQR"))
        case .refused(let why): return NookError(why)
        }
    }

    func ignore(_ chat: String) {
        let key = WAJID.normalized(chat)
        filters.ignored.insert(key)
        inbox.remove(key)
    }

    /// Keeps the chat but stops it from reaching you (the card's Mute).
    func mute(_ chat: String) {
        filters.setMode(.muted, for: chat)
    }

    /// Every chat the Settings list can name: the ones with messages, then the gateway's list, newest first.
    var chatsForSettings: [(jid: String, name: String)] {
        var seen = Set<String>()
        var result: [(jid: String, name: String)] = []
        for conversation in inbox.sorted where seen.insert(conversation.id).inserted {
            result.append((conversation.id, conversation.name))
        }
        for chat in knownChats where seen.insert(chat.jid).inserted {
            let fallback = WAJID.kind(chat.jid) == .status ? tr("whatsapp.kind.status") : WAJID.displayNumber(chat.jid)
            result.append((chat.jid, chat.name.isEmpty ? fallback : chat.name))
        }
        return result
    }

    /// One check from Settings' "Test": what the gateway says, in a sentence.
    func testConnection() async -> String {
        guard let provider = provider ?? WhatsAppSettings.makeProvider() else { return tr("whatsapp.status.badURL") }
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
