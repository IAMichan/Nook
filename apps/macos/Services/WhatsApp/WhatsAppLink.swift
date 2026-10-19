import Foundation
import AppKit
import Combine

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
    /// A new message shows in the notch with a field to answer it.
    static var notify: Bool {
        get { defaults.object(forKey: "whatsappNotify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "whatsappNotify") }
    }
    /// Read receipts when a message is answered or marked read in the notch; never on mere reception.
    static var markReadOnReply: Bool {
        get { defaults.object(forKey: "whatsappMarkRead") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "whatsappMarkRead") }
    }
    static var filters: WAFilters {
        get {
            WAFilters(muteGroups: defaults.object(forKey: "whatsappMuteGroups") as? Bool ?? true,
                      ignored: Set(defaults.stringArray(forKey: "whatsappIgnored") ?? []))
        }
        set {
            defaults.set(newValue.muteGroups, forKey: "whatsappMuteGroups")
            defaults.set(Array(newValue.ignored).sorted(), forKey: "whatsappIgnored")
        }
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

    static func makeProvider() -> WhatsAppProvider? {
        guard let base = URL(string: url), base.scheme?.hasPrefix("http") == true, base.host != nil else { return nil }
        switch gateway {
        case .gowa: return GOWAProvider(base: base, basicAuth: credential)
        case .openwa: return OpenWAProvider(base: base, apiKey: credential)
        }
    }
}

// MARK: - Link

/// WhatsApp, live: Nook talks to the local gateway the user runs (GOWA, which Nook can install and start, or OpenWA),
/// receives new messages on a webhook bound to 127.0.0.1 (polling when none comes), and keeps the conversations in
/// memory only: nothing of a message is written to disk or to a log, and everything is forgotten when Nook quits or
/// WhatsApp is turned off. Sending goes only to chats that are on the phone, a few a minute at most, and only after the
/// user typed the answer or approved Nook's plan.
///
/// The lifecycle after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
@MainActor
final class WhatsAppLink: ObservableObject {
    static let shared = WhatsAppLink()
    nonisolated static let webhookPath = "/whatsapp"

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

    @Published private(set) var inbox = WAInbox()
    @Published private(set) var link: Link = .off
    @Published private(set) var webhook: Webhook = .off
    @Published private(set) var qrPNG: Data?
    /// This account (JID or number), once linked.
    @Published private(set) var me: String?
    /// The chats on the phone (names to send to), refreshed every few minutes while linked.
    @Published private(set) var knownChats: [WAChatInfo] = []
    @Published var filters = WhatsAppSettings.filters {
        didSet { WhatsAppSettings.filters = filters }
    }

    /// A new message reached you (not a muted group, not your own): the notch shows it.
    var onMessage: ((_ chat: String) -> Void)?

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
    private var namingGroups: Set<String> = []
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
            .sink { _ in MainActor.assumeIsolated { WhatsAppGOWAProcess.shared.stopNow() } }
            .store(in: &bag)
    }

    /// Called once at launch.
    func start() { update() }

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
        startListener(kind: provider.kind)
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
        namingGroups = []
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
                me = status.me
                switch status.link {
                case .connected:
                    if link != .connected { qrPNG = nil }
                    link = .connected
                    if webhook == .listening { await register(provider, gen: gen) }
                    if !backfilled, gen == generation { await backfill(provider, gen: gen) }
                    if Date().timeIntervalSince(lastChatList) > 300 { await loadChats(provider, gen: gen) }
                case .needsQR:
                    link = .needsQR
                    if qrPNG == nil || Date() > qrExpiry {
                        // Not asked again for 15 s even when nothing came: each GOWA login call restarts the pairing.
                        qrExpiry = Date().addingTimeInterval(15)
                        if let qr = try await provider.qrCode(), gen == generation {
                            qrPNG = qr.png
                            qrExpiry = Date().addingTimeInterval(TimeInterval(qr.seconds))
                        }
                    }
                case .connecting:
                    link = .connecting
                }
            } catch let error as WAError {
                if gen == generation { apply(error) }
            } catch {
                if gen == generation { apply(.unreachable) }
            }
        }
    }

    private func apply(_ error: WAError) {
        switch error {
        case .unreachable: link = .unreachable
        case .unauthorized: link = .unauthorized
        case .notLoggedIn: link = .needsQR
        case .refused(let why): link = .failed(why)
        }
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
        guard case .message(let message)? = WAWebhook.parse(kind: kind, body: body, me: me) else { return }
        ingest([message], announce: true)
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
        knownChats = chats.map { WAChatInfo(jid: WAJID.normalized($0.jid), name: $0.name, last: $0.last) }
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
        for message in messages {
            let key = WAJID.normalized(message.chat)
            let outcome = inbox.add(message, filters: filters)
            nameGroupIfNeeded(key)
            if outcome == .notify, !message.fromMe { fresh = key }
        }
        if announce, let fresh { onMessage?(fresh) }
    }

    /// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
    private func nameGroupIfNeeded(_ chat: String) {
        guard WAJID.isGroup(chat), let provider, let conversation = inbox.conversations[chat],
              conversation.name == WAJID.displayNumber(chat), !namingGroups.contains(chat) else { return }
        namingGroups.insert(chat)
        let gen = generation
        Task {
            if let name = await provider.groupName(chat), gen == generation { inbox.rename(chat, to: name) }
        }
    }

    /// The newest messages of one chat, from the gateway (falls back to what Nook kept).
    func messages(of chat: String, limit: Int = 20) async throws -> [WAMessage] {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let key = WAJID.normalized(chat)
        if let fetched = try? await provider.messages(chat: key, limit: limit, me: me), !fetched.isEmpty {
            for message in fetched { inbox.add(message, filters: filters, history: true) }
            return fetched
        }
        return inbox.conversations[key]?.messages ?? []
    }

    /// Marks the chat read here and on WhatsApp (up to its newest received message).
    func markRead(_ chat: String) {
        let key = WAJID.normalized(chat)
        guard let provider, let conversation = inbox.conversations[key] else { return }
        let hadUnread = conversation.unread > 0
        inbox.markRead(key)
        guard hadUnread, WhatsAppSettings.markReadOnReply else { return }
        let last = conversation.messages.last { !$0.fromMe }?.id
        Task { try? await provider.markRead(chat: key, lastIncoming: last) }
    }

    // MARK: Sending

    /// Who a name, number or chat id means: a chat on the phone or one that wrote to you. Never a new number: Nook is no
    /// bulk sender and a wrong guess must not reach a stranger.
    func resolve(_ recipient: String) -> (jid: String, name: String)? {
        let wanted = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        var chats: [(jid: String, name: String)] = inbox.sorted.map { ($0.id, $0.name) }
        for chat in knownChats where !chats.contains(where: { $0.jid == chat.jid }) {
            chats.append((chat.jid, chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name))
        }
        return WhatsAppRecipients.match(wanted, in: chats)
    }

    /// Sends a text to a chat. Throws with a sentence the user can act on.
    @discardableResult
    func send(_ text: String, to recipient: String) async throws -> String {
        guard let provider, isConnected else { throw NookError(statusLine) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard body.count <= WAReply.maxLength else { throw NookError(tr("whatsapp.reply.tooLong")) }
        guard let target = resolve(recipient) else {
            let names = (inbox.sorted.map(\.name) + knownChats.prefix(12).map(\.name)).filter { !$0.isEmpty }
            var unique: [String] = []
            for name in names where !unique.contains(name) { unique.append(name) }
            throw NookError(tr("whatsapp.reply.unknown", recipient, unique.prefix(12).joined(separator: ", ")))
        }
        guard rateLimit.allow() else { throw NookError(tr("whatsapp.reply.tooFast")) }
        let gen = generation
        do {
            let id = try await provider.send(text: body, to: target.jid)
            guard gen == generation else { return target.name }
            var mine = WAMessage(id: id ?? "nook-\(UUID().uuidString)", chat: target.jid, sender: me ?? "",
                                 senderName: "", text: body, date: Date(), fromMe: true)
            mine.chatName = target.name
            inbox.add(mine, filters: filters, name: target.name)
            // Answering reads the conversation.
            if WhatsAppSettings.markReadOnReply {
                let last = inbox.conversations[target.jid]?.messages.last { !$0.fromMe }?.id
                Task { try? await provider.markRead(chat: target.jid, lastIncoming: last) }
            }
            Log.connectors.info("WhatsApp: message sent")
            return target.name
        } catch let error as WAError {
            switch error {
            case .unreachable: throw NookError(tr("whatsapp.status.unreachable"))
            case .unauthorized: throw NookError(tr("whatsapp.status.unauthorized"))
            case .notLoggedIn: throw NookError(tr("whatsapp.status.needsQR"))
            case .refused(let why): throw NookError(why)
            }
        }
    }

    func ignore(_ chat: String) {
        let key = WAJID.normalized(chat)
        filters.ignored.insert(key)
        inbox.remove(key)
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
