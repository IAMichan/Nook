import Foundation
import Network
import UIKit
import UserNotifications

/// The phone's side of the companion (docs/COMPANION.md, "Staying connected"). While the app is in front a supervisor
/// keeps one live connection to the Mac (`CompanionChannel`): it checks every route at once (`RouteProbe.pick`), connects
/// over the best one that answers, gets the sessions pushed when they change, and connects again with backoff when the
/// connection dies. A Mac that does not offer live connections yet is asked for the list every few seconds instead.
/// Messages written while the Mac is away wait in an outbox and go as soon as it answers again.
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
    /// A quick action from the app's icon, for `RootView` to act on once (`AppShortcut`).
    @Published var pendingShortcut: AppShortcut?
    /// Whether the Mac has push set up (answer to the last `register`), nil while unknown.
    @Published private(set) var macPushReady: Bool?
    /// `CompanionFeature` values the Mac understands; empty for a Mac that only answers what waits.
    @Published private(set) var features: Set<String> = []
    /// Whether the active Mac advertises features this phone build does not recognize.
    @Published private(set) var hasUnrecognizedMacFeatures = false
    /// What a new session can start with, once asked.
    @Published private(set) var launchOptions: LaunchOptions?
    /// The conversation of each session that was opened, by session id.
    @Published private(set) var timelines: [String: [TimelineEntry]] = [:]
    /// The session on screen whose conversation follows live (`CompanionOp.watch`), kept across reconnects.
    private(set) var watchedSession: String?
    /// The changed files of a session (`CompanionOp.diff`).
    @Published private(set) var diffs: [String: [DiffFileDigest]] = [:]
    /// Messages your Mac refused, per session, to edit and send again or to drop, so a
    /// rejected message is restored into the composer instead of lost.
    @Published var rejected: [RejectedMessage] = []
    /// Nook's own chats, and the messages of each one that was opened.
    @Published private(set) var conversations: [ChatDigest] = []
    @Published private(set) var chatLines: [String: [ChatLine]] = [:]
    /// False when the Mac said Nook has no brain set up, so chatting cannot work yet.
    @Published private(set) var brainReady = true
    /// The Mac's Chats tab: every chat app in one inbox, and the messages of each chat that was opened, by chat id.
    @Published private(set) var inbox: [InboxChatDigest] = []
    @Published private(set) var inboxLines: [String: [InboxLine]] = [:]
    /// Who is typing in each chat that was opened, by chat id, as the Mac last said.
    @Published private(set) var inboxTyping: [String: [InboxTypist]] = [:]
    /// Unread messages in every chat, for the badge on the Chats tab.
    var inboxUnread: Int { inbox.reduce(0) { $0 + $1.unread } }
    /// Why the inbox may be empty: "chatsoff" (nothing is collected on the Mac) or "chatsaccess" (macOS does not let
    /// Nook read the notifications); nil when it is fine.
    @Published private(set) var inboxStatus: String?
    /// Messages that wait for the Mac (`CompanionOutbox`); a session shows its own.
    @Published private(set) var outbox = CompanionOutbox()
    /// The route the live connection (or the last answer) went over.
    @Published private(set) var activeRoute: CompanionRoute?
    /// Whether this app and Nook on the Mac speak a protocol both understand (`CompanionCompatibility`), and the Mac's
    /// app version, from the last `hello`, `list` or `subscribe` answer.
    @Published private(set) var compatibility: CompanionCompatibility = .ok
    @Published private(set) var macAppVersion: String?
    /// What the Mac lets this phone do (`CompanionScope` names), from the last answer that listed features; nil from a
    /// Mac without scopes, which allows everything.
    @Published private(set) var scopes: Set<String>?
    /// Every Mac this phone is paired with (`CompanionPairings`), the active one (the live connection goes there), and
    /// what waits on each of the others, checked now and then.
    @Published private(set) var macs: [PairedMac] = []
    @Published private(set) var activeMacID: String?
    @Published private(set) var otherSessions: [String: [SessionDigest]] = [:]
    /// Pairing another Mac: the pairing screen shows while the current Mac stays paired.
    @Published var addingMac = false
    /// When the active Mac last answered the list, live or (at launch) from what the phone kept (`CompanionCache`):
    /// while it cannot be reached the list says "Last updated HH:mm · not connected".
    @Published private(set) var lastUpdated: Date?
    /// The name of a Mac that removed this iPhone (`CompanionResponse.revoked`), until the user pairs again or lets it go.
    @Published var revokedMac: String?
    /// The conversation a question that waited in the outbox started, by its request id, once the Mac took it.
    @Published private(set) var askedConversations: [String: String] = [:]
    private(set) var pushToken: String?

    /// The last answers of the active Mac, kept for the next launch (`CacheStore`), and the save that is coming.
    private var cache = CompanionCache()
    private var cacheSave: Task<Void, Never>?
    /// What waited when delivered notifications were last cleared (`DeliveredNotifications`).
    private var clearedPending: Set<String>?
    /// Deny and Reply buttons that could not reach their Mac (`NotificationRetries`).
    private var retries = RetryStore.load()
    /// Whether the app is in front; a Mac with `CompanionFeature.foreground` leaves out pushes while it is.
    private var inFront = false
    /// Answers to outbox entries that were sent, by request id, for the one waiting on it (`deliver`).
    private var drained: [String: CompanionResponse] = [:]

    private var pairings = CompanionPairings()
    private var link: PairingLink?
    /// The ways to reach the Mac, the best first (`CompanionRoutes`); what the Mac reports is learned into it.
    private(set) var routes: [CompanionRoute] = []
    /// Whether a `hello` or `list` answer told us what the Mac can do. An old Mac sends no `features`: then the
    /// empty set is known too, so a screen does not keep asking.
    private var featuresKnown = false
    /// When the Mac was last looked for on the network, so a Mac that is off is not searched on every attempt.
    private var lastSearch: Date?

    // The connection: one supervisor while the app is in front, one live channel at a time.
    private var supervisor: Task<Void, Never>?
    private var supervisorGeneration = 0
    private var channel: CompanionChannel?
    private var failures = 0
    /// Set to connect again at once instead of after a backoff: a better route answered, or the app is back after a break.
    private var replacing = false
    /// Cuts a wait between attempts short (back in front, another network).
    private var wakeRequested = false
    /// A better route found while connected over a later one, tried first next; held back for a while when it then fails.
    private var preferredRoute: CompanionRoute?
    private var cooldowns = RouteCooldowns()
    private var backgroundedAt: Date?
    private let pathMonitor = NWPathMonitor()
    private var pathSignature: String?
    private var draining = false
    /// Whether the phone has a network at all, and the last refusal the Mac gave a connection attempt, for
    /// "Why can't I connect?" (`CompanionDiagnosis`).
    private var isOnline = true
    private var lastRefusal: CompanionError?

    /// What the active Mac could do last time, and its outbox, each kept per Mac (`CompanionPairings.storageName`).
    private var featuresKey: String { storageName("companion.features") }
    private var outboxName: String { storageName("companion-outbox.json") }

    private func storageName(_ base: String) -> String {
        guard let id = pairings.active?.id else { return base }
        return CompanionPairings.storageName(base, mac: id, legacyID: pairings.legacyID)
    }

    init() {
        pairings = PairingStore.load()
        phase = .unpaired
        loadActive()
        phase = link == nil ? .unpaired : .offline("")
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular].first { path.usesInterfaceType($0) }
            let signature = "\(kind.map { "\($0)" } ?? "other") \(path.gateways.map { "\($0)" }.joined(separator: ","))"
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(signature: signature, online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "nook.companion.path"))
    }

    // MARK: Pairing

    /// Pairs with the code the Mac shows. The first request, `hello`, proves the phone holds the key; the Mac then keeps the
    /// device. It goes to every address in the code at once, so a phone that cannot resolve the Mac's .local name still
    /// pairs over one of its addresses.
    func pair(link text: String) {
        guard let parsed = PairingLink.parse(text) else { notice = String(localized: "That is not a valid pairing code."); return }
        phase = .pairing
        notice = nil
        let candidates = CompanionRoutes.initial(from: parsed)
        let name = UIDevice.current.name
        Task {
            do {
                guard let picked = await RouteProbe.pick(candidates, key: parsed.key, makeRequest: { CompanionRequest.versioned(.hello, text: name) }) else {
                    throw CompanionClientError.timeout
                }
                let response = picked.answer
                guard response.ok else { throw CompanionClientError.refused(response.error) }
                var next = pairings
                guard next.add(parsed, routes: candidates) else { throw CompanionClientError.tooManyMacs }
                guard PairingStore.save(next) else { throw CompanionClientError.storage }
                stopConnection()
                cacheActiveSessions()
                pairings = next
                loadActive()
                addingMac = false
                revokedMac = nil
                activeRoute = picked.route
                macName = response.macName ?? parsed.macName
                apply(response, to: CompanionRequest(op: .hello))
                Notifications.setBadge(sessions.needingYou)
                phase = .connected
                failures = 0
                superviseIfNeeded()
                await Notifications.requestAndRegister()
            } catch {
                phase = link == nil ? .unpaired : .offline(error.localizedDescription)
                notice = String(localized: "Pairing failed: \(error.localizedDescription) The code works once, for five minutes; make a new one on your Mac.")
            }
        }
    }

    /// Unpairs from the active Mac; another paired Mac becomes the active one.
    func unpair() {
        stopConnection()
        Task { await LiveActivities.shared.endAll() }
        guard let id = pairings.active?.id else { phase = .unpaired; return }
        forgetActive(id)
    }

    /// The Mac removed this iPhone (`CompanionResponse.revoked`): its key is dead, so the pairing goes, with its push key
    /// (`PairingStore.save` keeps only those of paired Macs), its Live Activities and what was kept of it; the phone
    /// says so and offers to pair again, and goes on with another paired Mac if there is one.
    private func revoked() {
        guard let mac = pairings.active else { return }
        CompanionDiagnosticsLog.phone.record("revoked", ["macs": String(pairings.macs.count)])
        stopConnection()
        Task { await LiveActivities.shared.endAll() }
        if let key = mac.link?.key { PushKeyStore.forget(pairingKey: key) }
        revokedMac = mac.name
        forgetActive(mac.id)
    }

    /// Drops the active Mac's pairing and everything kept for it; another paired Mac becomes the active one.
    private func forgetActive(_ id: String) {
        cacheSave?.cancel()
        cacheSave = nil
        outbox = CompanionOutbox()
        OutboxStore.save(outbox, name: outboxName)
        UserDefaults.standard.removeObject(forKey: featuresKey)
        CacheStore.remove(mac: id)
        ClockOffsets.forget(id)
        for entry in retries.waiting(for: id) { retries.remove(entry.id) }
        RetryStore.save(retries)
        pairings.remove(id)
        PairingStore.save(pairings)
        otherSessions[id] = nil
        loadActive()
        guard link != nil else { phase = .unpaired; return }
        phase = .offline("")
        superviseIfNeeded()
    }

    /// Makes another paired Mac the active one: the live connection moves there.
    func switchMac(to id: String) {
        guard id != pairings.active?.id, pairings.contains(id) else { return }
        CompanionDiagnosticsLog.phone.record("switchMac", ["macs": String(pairings.macs.count)])
        stopConnection()
        Task { await LiveActivities.shared.endAll() }
        cacheActiveSessions()
        pairings.select(id)
        PairingStore.save(pairings)
        loadActive()
        phase = .offline("")
        superviseIfNeeded()
        Task { await sendPushRegistration() }
    }

    /// The active Mac's sessions stay in the list under its name once another Mac is active.
    private func cacheActiveSessions() {
        guard let id = pairings.active?.id else { return }
        otherSessions[id] = sessions
    }

    /// Takes in the active Mac: its pairing, routes, features and outbox; what was shown for the previous one goes.
    private func loadActive() {
        // What the previous Mac answered last is written before its place is taken.
        flushCache()
        let mac = pairings.active
        link = mac?.link
        routes = mac?.routes ?? []
        macName = mac?.name ?? ""
        macs = pairings.macs
        activeMacID = mac?.id
        if let id = mac?.id { otherSessions[id] = nil }
        // What the Mac could do last time, so a message written before the first answer can already wait in the outbox.
        features = Set(UserDefaults.standard.stringArray(forKey: featuresKey) ?? [])
        hasUnrecognizedMacFeatures = false
        outbox = OutboxStore.load(name: outboxName)
        // The last the phone saw of this Mac, until it answers: shown as not live ("Last updated …"), never over newer.
        cache = mac.map { CacheStore.load(mac: $0.id) } ?? CompanionCache()
        sessions = cache.sessions
        timelines = cache.allTimelines
        launchOptions = cache.launch
        lastUpdated = cache.savedAt
        clearedPending = nil
        featuresKnown = false
        conversations = []
        chatLines = [:]
        inbox = []
        inboxLines = [:]
        inboxTyping = [:]
        inboxStatus = nil
        compatibility = .ok
        macAppVersion = nil
        scopes = nil
        macPushReady = nil
        activeRoute = nil
        preferredRoute = nil
        cooldowns = RouteCooldowns()
        lastRefusal = nil
        lastSearch = nil
        failures = 0
    }

    /// Keeps the active Mac's routes with its pairing.
    private func saveRoutes(_ next: [CompanionRoute]) {
        guard let id = pairings.active?.id else { return }
        pairings.setRoutes(next, for: id)
        PairingStore.save(pairings)
    }

    /// Writes what the active Mac answered last a moment from now, once for a burst of changes (a conversation that
    /// streams changes every second).
    private func scheduleCacheSave() {
        guard let id = activeMacID, cacheSave == nil else { return }
        cacheSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Cancelled: `flushCache` wrote it already and let go of this task.
            guard let self, !Task.isCancelled else { return }
            self.cacheSave = nil
            guard self.activeMacID == id else { return }
            CacheStore.save(self.cache, mac: id)
        }
    }

    /// Writes a save that is still coming now (before another Mac becomes active).
    private func flushCache() {
        guard let pending = cacheSave, let id = activeMacID else { return }
        pending.cancel()
        cacheSave = nil
        CacheStore.save(cache, mac: id)
    }

    /// Asks every other paired Mac what waits there, for the Agents list; one that does not answer keeps what it said last.
    func refreshOthers() async {
        for mac in pairings.others {
            guard let key = mac.link?.key,
                  let picked = await RouteProbe.pick(mac.routes, key: key, makeRequest: { CompanionRequest.versioned(.list) }),
                  picked.answer.ok, let list = picked.answer.sessions else { continue }
            // Only what that Mac lets this phone see comes back; an empty list is fine.
            otherSessions[mac.id] = list
            // Its notifications about what no longer waits go too; the badge stays the active Mac's.
            Notifications.clearAnswered(pending: DeliveredNotifications.pending(list), mac: mac.id, onlyMac: false, badge: nil)
        }
        let paired = Set(pairings.macs.map(\.id))
        for id in otherSessions.keys where !paired.contains(id) { otherSessions[id] = nil }
    }

    // MARK: Staying connected

    /// The app came to the front: connect, or check the connection. After a real break the connection is replaced at
    /// once (iOS may have killed the socket without a word); after a glance elsewhere a quick probe is enough.
    func appBecameActive() {
        let wakeup = CompanionWakeup.onActive(backgroundedAt: backgroundedAt, now: Date())
        backgroundedAt = nil
        inFront = true
        // Buttons on notifications that could not reach their Mac get another go, quietly.
        if !retries.entries.isEmpty { Task { await retryNotificationActions(mac: nil, quiet: true) } }
        guard link != nil else { return }
        guard supervisor != nil else {
            failures = 0
            superviseIfNeeded()
            return
        }
        wakeUp(resetBackoff: true)
        guard let channel else { return }
        switch wakeup {
        case .reconnect:
            CompanionDiagnosticsLog.phone.record("wakeup", ["action": "reconnect"])
            replacing = true
            channel.close()
        case .probe:
            Task { await probe(channel) }
        }
    }

    func appWentToBackground() {
        backgroundedAt = Date()
        inFront = false
        flushCache()
        // The Mac sends pushes again from now on (`CompanionFeature.foreground`); without this word it does after a few
        // seconds of silence anyway (`ForegroundPolicy`).
        guard let channel, channel.isOpen, can(CompanionFeature.foreground) else { return }
        let work = BackgroundWork("Nook: going to the background")
        Task {
            _ = try? await channel.request(CompanionRequest(op: .ping, foreground: false), timeout: CompanionTiming.probeTimeout)
            work.end()
        }
    }

    private func superviseIfNeeded() {
        guard link != nil, supervisor == nil else { return }
        supervisorGeneration += 1
        let generation = supervisorGeneration
        supervisor = Task { [weak self] in
            await self?.supervise()
            // A supervisor that was replaced in the meantime (paired again) leaves its successor alone.
            if self?.supervisorGeneration == generation { self?.supervisor = nil }
        }
    }

    private func stopConnection() {
        supervisor?.cancel()
        supervisor = nil
        channel?.close()
        channel = nil
    }

    /// Ends a wait between attempts; after a new network or the app coming back, the backoff starts over.
    private func wakeUp(resetBackoff: Bool) {
        if resetBackoff { failures = 0 }
        wakeRequested = true
    }

    private func pause(_ seconds: TimeInterval) async {
        let until = Date().addingTimeInterval(seconds)
        wakeRequested = false
        while Date() < until, !wakeRequested, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        wakeRequested = false
    }

    /// Wi-Fi to cellular, another Wi-Fi network, or back online: look again at once, check the connection, and whether a
    /// better route works now (home again: LAN instead of Tailscale).
    private func networkChanged(signature: String, online: Bool) {
        isOnline = online
        let previous = pathSignature
        pathSignature = online ? signature : nil
        guard online, previous != signature, previous != nil || phase != .connected else { return }
        CompanionDiagnosticsLog.phone.record("network", ["changed": previous == nil ? "online" : "other"])
        wakeUp(resetBackoff: true)
        if let channel {
            Task {
                await probe(channel)
                await checkBetterRoutes(channel)
            }
        }
    }

    /// The routes in the order to try them: a better route that just answered first.
    private func attemptOrder() -> [CompanionRoute] {
        guard let preferred = preferredRoute, let index = routes.firstIndex(where: { $0.hostKey == preferred.hostKey }) else { return routes }
        var ordered = routes
        let route = ordered.remove(at: index)
        ordered.insert(route, at: 0)
        return ordered
    }

    private func supervise() async {
        while !Task.isCancelled, let link {
            let macID = PairedDevice.identifier(forKey: link.key)
            let clockBefore = ClockOffsets.offset(for: macID)
            // Every route is asked for the list: any Mac answers it, and the answer says whether it keeps a live
            // connection, so a Mac that was updated (or rolled back) in the meantime is met as it is now.
            guard let picked = await RouteProbe.pick(attemptOrder(), key: link.key, makeRequest: { CompanionRequest.versioned(.list) }) else {
                if Task.isCancelled { return }
                // Nothing answered: the Mac may listen on another port now; Bonjour finds it on the local network.
                CompanionDiagnosticsLog.phone.record("unreachable", ["routes": attemptOrder().map(\.logKind).joined(separator: ","),
                                                                     "failures": String(failures)])
                if await relocate() { continue }
                failures += 1
                phase = .offline(CompanionClientError.timeout.localizedDescription)
                await pause(RetryBackoff.delay(failures: failures, random: Double.random(in: 0...1)))
                continue
            }
            if Task.isCancelled { return }
            if let preferred = preferredRoute, preferred.hostKey != picked.route.hostKey { cooldowns.hold(preferred, now: Date()) }
            preferredRoute = nil
            lastRefusal = picked.answer.ok ? nil : picked.answer.error
            CompanionDiagnosticsLog.phone.record(picked.answer.ok ? "route" : "refused",
                                                 ["route": picked.route.logKind, "error": picked.answer.error?.rawValue ?? "",
                                                  "failures": String(failures)])
            guard picked.answer.ok else {
                if picked.answer.error == .stale {
                    // The Mac said its time (`CompanionFeature.clock`): the next attempt carries the corrected time, now.
                    if CompanionClock.changed(clockBefore, ClockOffsets.offset(for: macID)) { continue }
                    // A clock that is off does not get better by asking fast: straight to the longest wait.
                    failures = max(failures + 1, 6)
                } else {
                    failures += 1
                }
                phase = .offline(refusalText(picked.answer.error))
                await pause(RetryBackoff.delay(failures: failures, random: Double.random(in: 0...1)))
                continue
            }
            activeRoute = picked.route
            apply(picked.answer, to: CompanionRequest(op: .list))
            if can(CompanionFeature.stream) {
                await runChannel(on: picked.route, link: link)
            } else {
                phase = .connected
                await runPolling()
            }
            if Task.isCancelled { return }
            if replacing {
                replacing = false
                continue
            }
            await pause(RetryBackoff.delay(failures: max(failures, 1), random: Double.random(in: 0...1)))
        }
    }

    /// One live connection over `route`, until it closes.
    private func runChannel(on route: CompanionRoute, link: PairingLink) async {
        guard let channel = CompanionChannel(route: route, key: link.key, onUpdate: { [weak self] update in
            Task { @MainActor in self?.received(update) }
        }) else {
            failures += 1
            return
        }
        do {
            try await channel.open(timeout: 5)
            var subscribe = CompanionRequest.versioned(.subscribe)
            if can(CompanionFeature.foreground) { subscribe.foreground = inFront }
            let response = try await channel.request(subscribe, timeout: 10)
            guard response.ok else {
                channel.close()
                failures += 1
                lastRefusal = response.error
                phase = .offline(refusalText(response.error))
                return
            }
            self.channel = channel
            let since = Date()
            apply(response, to: CompanionRequest(op: .list))
            phase = .connected
            channel.startHeartbeat()
            Task { await afterConnecting() }
            await watch(channel)
            if self.channel === channel { self.channel = nil }
            CompanionDiagnosticsLog.phone.record("closed", ["route": route.logKind, "up": String(Int(Date().timeIntervalSince(since))),
                                                            "replacing": replacing ? "yes" : "no"])
            if Task.isCancelled { return }
            if Date().timeIntervalSince(since) >= RetryBackoff.stableAfter { failures = 0 }
            if !replacing {
                failures += 1
                phase = .offline("")
            }
        } catch {
            channel.close()
            if self.channel === channel { self.channel = nil }
            CompanionDiagnosticsLog.phone.record("channelFailed", ["route": route.logKind, "error": error.localizedDescription])
            failures += 1
            if !Task.isCancelled { phase = .offline(error.localizedDescription) }
        }
    }

    /// While the channel lives: look for a better route now and then, and keep the Chats badge current (the inbox is not
    /// part of what the Mac sends by itself).
    private func watch(_ channel: CompanionChannel) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await channel.waitClosed() }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(CompanionTiming.betterRouteEvery * 1_000_000_000))
                    if Task.isCancelled { return }
                    await self?.checkBetterRoutes(channel)
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    await self?.refreshInbox()
                    await self?.refreshOthers()
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// A Mac without live connections: ask for the list every few seconds over the route that answered, as before.
    private func runPolling() async {
        let since = Date()
        while !Task.isCancelled, !replacing {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            await refresh()
            guard phase == .connected else { break }
            // The Mac was updated: switch to a live connection.
            if can(CompanionFeature.stream) {
                replacing = true
                break
            }
        }
        if Date().timeIntervalSince(since) >= RetryBackoff.stableAfter { failures = 0 }
        if !replacing { failures += 1 }
    }

    private func afterConnecting() async {
        // A new connection has no session open on the Mac yet: the one on screen follows again.
        if let session = watchedSession { await watchSession(session) }
        await LiveActivities.shared.reconcile(sessions)
        await drainOutbox()
        if let id = activeMacID, !retries.waiting(for: id).isEmpty { await retryNotificationActions(mac: id, quiet: true) }
        await refreshInbox()
        await refreshOthers()
    }

    private func refreshInbox() async {
        guard phase == .connected, can(CompanionFeature.inbox) else { return }
        await perform(CompanionRequest(op: .inbox), quiet: true)
    }

    /// What the Mac sent by itself over the live connection.
    private func received(_ update: CompanionResponse) {
        // The Mac removed this iPhone (`CompanionFeature.revoke`): nothing more will open; pair again.
        if update.revoked == true { return revoked() }
        apply(update, to: CompanionRequest(op: .list))
        Task { await LiveActivities.shared.reconcile(sessions) }
    }

    /// A quick look whether the channel still answers; if not, it is replaced at once.
    private func probe(_ channel: CompanionChannel) async {
        do {
            // Says too whether the app is in front, which may have changed since the connection was made.
            _ = try await channel.request(CompanionRequest(op: .ping, foreground: can(CompanionFeature.foreground) ? inFront : nil),
                                          timeout: CompanionTiming.probeTimeout)
        } catch {
            guard self.channel === channel else { return }
            CompanionDiagnosticsLog.phone.record("probeFailed", ["route": channel.route.logKind, "error": error.localizedDescription])
            replacing = true
            channel.close()
        }
    }

    /// While connected over a later route, checks the earlier ones; when one answers, the connection moves to it.
    private func checkBetterRoutes(_ channel: CompanionChannel) async {
        guard let link, self.channel === channel,
              let index = routes.firstIndex(where: { $0.hostKey == channel.route.hostKey }), index > 0 else { return }
        let now = Date()
        let better = routes[..<index].filter { cooldowns.allows($0, now: now) }
        guard !better.isEmpty else { return }
        let key = link.key
        let answered = await withTaskGroup(of: (Int, Bool).self) { group -> [Bool] in
            for (position, route) in better.enumerated() {
                let request = CompanionRequest(op: .ping)
                group.addTask {
                    (position, await RouteProbe.check(route, key: key, request: request, timeout: CompanionTiming.routeCheckTimeout) != nil)
                }
            }
            var results = [Bool](repeating: false, count: better.count)
            for await (position, ok) in group { results[position] = ok }
            return results
        }
        guard let first = answered.firstIndex(of: true), self.channel === channel else { return }
        preferredRoute = better[first]
        CompanionDiagnosticsLog.phone.record("betterRoute", ["from": channel.route.logKind, "to": better[first].logKind])
        replacing = true
        channel.close()
    }

    /// Asks Bonjour where the Mac listens now; true when that is somewhere new (another port, an address not tried yet).
    private func relocate() async -> Bool {
        guard let link, lastSearch.map({ Date().timeIntervalSince($0) > 20 }) ?? true else { return false }
        lastSearch = Date()
        guard let place = await MacFinder.find(name: link.macName) else { return false }
        if routes.contains(where: { $0.hostKey == place.host.lowercased() && $0.port == place.port }) { return false }
        // The Mac listens on one port on every network: all direct routes follow it.
        var next = routes.map { route -> CompanionRoute in
            guard !route.isRelay else { return route }
            var moved = route
            moved.port = place.port
            return moved
        }
        if !next.contains(where: { $0.hostKey == place.host.lowercased() }) {
            next = CompanionRoutes.insert(next, CompanionRoute(host: place.host, port: place.port, learned: true))
        }
        routes = next
        saveRoutes(routes)
        return true
    }

    /// Takes in the addresses the Mac reported; a better route than the one in use is checked right away.
    private func learn(_ reported: [CompanionEndpoint]) {
        guard let merged = CompanionRoutes.merge(routes, reported: reported) else { return }
        routes = merged
        saveRoutes(merged)
        if let channel, let index = merged.firstIndex(where: { $0.hostKey == channel.route.hostKey }), index > 0 {
            Task { await checkBetterRoutes(channel) }
        }
    }

    /// What to try when the Mac cannot be reached from where the phone is now; nil when the relay is set up.
    var awayHint: String? {
        guard link != nil, !routes.contains(where: \.isRelay) else { return nil }
        if routes.contains(where: { $0.kind == .tailnet || $0.kind == .vpn }) {
            return String(localized: "Away from home? Check that Tailscale is on on this iPhone.")
        }
        return String(localized: "Away from home? Turn on Tailscale on this iPhone and on your Mac, or set up a relay in Nook on your Mac.")
    }

    private func refusalText(_ error: CompanionError?) -> String {
        switch error {
        case .stale: return String(localized: "The clocks of your phone and your Mac are too far apart.")
        case .rateLimited: return String(localized: "Slow down a little.")
        default: return String(localized: "Your Mac refused this.")
        }
    }

    // MARK: The outbox

    /// Sends what waits in the outbox, oldest first, until the Mac cannot be reached. Each message keeps its id, so one
    /// whose answer got lost is not carried out twice (`CommandReceipts` on the Mac).
    private func drainOutbox() async {
        guard !draining, let link else { return }
        draining = true
        defer { draining = false }
        if !outbox.expire(now: Date()).isEmpty {
            OutboxStore.save(outbox, name: outboxName)
            notice = String(localized: "What waited too long for your Mac was not sent.")
        }
        while let entry = outbox.entries.first {
            let request = CompanionOutbox.resend(entry, now: Date())
            guard let response = try? await transport(request, link: link) else { return }
            // Refused for now (still being handled, a burst, the clocks): it waits for the next try.
            if !response.ok, let error = response.error, CompanionOutbox.waitsAfter(error, op: request.op) { return }
            outbox.remove(entry.id)
            OutboxStore.save(outbox, name: outboxName)
            if drained.count > 50 { drained.removeAll() }
            drained[entry.id] = response
            if response.ok {
                apply(response, to: request)
                switch request.op {
                case .send where response.message == "queued":
                    notice = String(localized: "Queued: the session is still busy.")
                case .ask:
                    // The chat it started (or went on with) can open now.
                    if let created = response.created { askedConversations[entry.id] = created }
                    await loadChats()
                case .inboxSend:
                    await loadInbox()
                    if let chat = request.item { await loadInboxChat(chat) }
                default:
                    break
                }
            } else if let session = request.session, request.op == .send {
                // Kept with why, in the session, to edit and send again: nothing you wrote is lost.
                rejected.append(RejectedMessage(session: session, text: request.text ?? "", images: request.images ?? [],
                                                reason: RejectedMessage.reason(response)))
            } else if request.op == .start || request.op == .ask || request.op == .inboxSend {
                notice = String(localized: "Your Mac did not take what waited for it: \(RejectedMessage.reason(response))")
            } else {
                notice = String(localized: "Your Mac refused this.")
            }
        }
    }

    /// Something you wrote (a message, a new session, a question to Nook, a message to a chat): through the outbox when
    /// the Mac answers repeats once (`CompanionFeature.retry`), so it waits on the phone while the Mac cannot be reached;
    /// straight to the Mac otherwise.
    private func deliver(_ request: CompanionRequest) async -> Delivery {
        guard can(CompanionFeature.retry), outbox.enqueue(request, now: Date()) else {
            return await perform(request).map(Delivery.sent) ?? .refused
        }
        OutboxStore.save(outbox, name: outboxName)
        // Without a connection it waits for the supervisor to reach the Mac, rather than for a timeout here.
        guard phase == .connected, !draining else { return .waiting }
        await drainOutbox()
        guard let response = drained.removeValue(forKey: request.id) else { return .waiting }
        return response.ok ? .sent(response) : .refused
    }

    enum Delivery {
        /// The Mac took it, with its answer.
        case sent(CompanionResponse)
        /// It waits in the outbox until the Mac can be reached.
        case waiting
        /// The Mac said no (the reason is in `notice`, or with the message in its session).
        case refused
    }

    // MARK: Actions

    func refresh() async {
        guard link != nil else { return }
        await perform(CompanionRequest.versioned(.list))
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
        if let response = try? await transport(CompanionRequest(op: .register, item: environment, text: pushToken), link: link), response.ok {
            macPushReady = response.message == "push"
        }
    }

    /// Hands the Mac a Live Activity token (or says one ended, or that they are off). The Mac's "push"/"nopush" when it
    /// took it, nil when it could not be reached or does not know Live Activities.
    func registerLive(_ registration: LiveActivityRegistration) async -> String? {
        guard let link, can(CompanionFeature.liveActivity),
              let response = try? await transport(CompanionRequest(op: .liveActivity, live: registration), link: link),
              response.ok else { return nil }
        return response.message ?? "nopush"
    }

    func decide(_ session: SessionDigest, item: SessionDigest.Item, allow: Bool) async {
        await perform(CompanionRequest(op: .decide, session: session.id, item: item.id, allow: allow))
    }

    func answer(_ session: SessionDigest, item: SessionDigest.Item, text: String) async {
        await perform(CompanionRequest(op: .answer, session: session.id, item: item.id, text: text))
    }

    /// A message to a session. With a Mac that answers repeats once (`CompanionFeature.retry`) it goes through the
    /// outbox: kept on the phone until the Mac took it, so it is not lost when the Mac cannot be reached right now.
    func send(_ session: SessionDigest, text: String, steer: Bool = false, images: [CompanionImage] = []) async {
        await send(sessionID: session.id, text: text, steer: steer, images: images)
    }

    /// A message to a session by its id, as a reply typed in a notification sends it. `steer`: into the running turn now
    /// rather than after it (a Mac without `CompanionFeature.steer` puts it in line either way).
    func send(sessionID: String, text: String, steer: Bool = false, images: [CompanionImage] = []) async {
        let request = CompanionRequest(op: .send, session: sessionID, text: text,
                                       steer: steer && can(CompanionFeature.steer) ? true : nil,
                                       images: images.isEmpty || !can(CompanionFeature.images) ? nil : images)
        _ = await deliver(request)
    }

    func stop(_ session: SessionDigest) async {
        await perform(CompanionRequest(op: .stop, session: session.id))
    }

    /// Manages a session from afar (rename, archive, snooze, end), as the Mac's Agents list does.
    func manage(_ session: SessionDigest, _ action: SessionAction, text: String? = nil) async {
        guard can(CompanionFeature.manage) else { return }
        await perform(CompanionRequest(op: .manage, session: session.id, item: action.rawValue, text: text))
    }

    // MARK: Starting a session

    func can(_ feature: String) -> Bool { features.contains(feature) }

    /// Whether the Mac lets this phone do what `scope` covers; the screens hide what it may not.
    func allows(_ scope: CompanionScope) -> Bool { scopes?.contains(scope.rawValue) ?? true }

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

    /// Starts a session on the Mac (through the outbox, so it waits while the Mac cannot be reached). `.sent` carries the
    /// new session's id in `created`; `.refused` has the reason in `notice`.
    func start(_ launch: LaunchRequest, images: [CompanionImage] = []) async -> Delivery {
        await deliver(CompanionRequest(op: .start, launch: launch,
                                       images: images.isEmpty || !can(CompanionFeature.images) ? nil : images))
    }

    // MARK: A session's conversation

    func loadTimeline(_ sessionID: String) async {
        guard await supports(CompanionFeature.timeline) else { return }
        await perform(CompanionRequest(op: .timeline, session: sessionID), quiet: true)
    }

    /// Opens a session's conversation live (`CompanionOp.watch`): the Mac answers with it whole, then sends what changes
    /// by itself. False when this Mac cannot, and the screen asks every few seconds instead.
    @discardableResult
    func watchSession(_ sessionID: String) async -> Bool {
        watchedSession = sessionID
        guard await supports(CompanionFeature.liveTimeline), phase == .connected else { return false }
        // The conversation the phone still has (from before, or kept since the last launch): only what came after it.
        let last = can(CompanionFeature.resume) ? timelines[sessionID]?.last?.id : nil
        return await perform(CompanionRequest(op: .watch, session: sessionID, item: last), quiet: true)?.ok == true
    }

    /// The session left the screen: the Mac stops sending its conversation (unless another one opened meanwhile).
    func unwatchSession(_ sessionID: String) async {
        guard watchedSession == sessionID else { return }
        watchedSession = nil
        guard can(CompanionFeature.liveTimeline), phase == .connected else { return }
        await perform(CompanionRequest(op: .watch), quiet: true)
    }

    /// Whether the open session follows live right now, so its screen need not ask.
    var timelineIsLive: Bool { can(CompanionFeature.liveTimeline) && phase == .connected && channel != nil }

    /// What a session changed in its folder (`CompanionOp.diff`).
    func loadDiff(_ sessionID: String) async {
        guard await supports(CompanionFeature.diff) else { return }
        await perform(CompanionRequest(op: .diff, session: sessionID), quiet: true)
    }

    /// A refused message back in your hands: taken off the list, to put in the composer.
    func takeRejected(_ message: RejectedMessage) -> RejectedMessage {
        rejected.removeAll { $0.id == message.id }
        return message
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

    /// Asks Nook; nil `conversationID` starts a new chat. Through the outbox, so a question waits while the Mac cannot be
    /// reached: `.waiting(id)` names the request, whose chat shows up in `askedConversations` once the Mac took it.
    func ask(_ text: String, in conversationID: String?) async -> AskOutcome {
        let request = CompanionRequest(op: .ask, text: text, conversation: conversationID)
        switch await deliver(request) {
        case .sent(let response):
            await loadChats()
            return response.created.map(AskOutcome.asked) ?? .refused
        case .waiting:
            return .waiting(request.id)
        case .refused:
            return .refused
        }
    }

    enum AskOutcome {
        /// The chat it went to.
        case asked(String)
        /// Waits in the outbox, by request id.
        case waiting(String)
        case refused
    }

    /// Something that waits in the outbox is let go: it will not be sent.
    func discardWaiting(_ id: String) {
        outbox.remove(id)
        OutboxStore.save(outbox, name: outboxName)
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

    /// Your own words to a chat (a WhatsApp chat on the Mac), as an answer to `replyTo` when one is quoted. Through the
    /// outbox: it waits while the Mac cannot be reached, shown in the chat as waiting.
    func sendInbox(_ text: String, to chatID: String, replyTo: String? = nil) async -> Delivery {
        let delivery = await deliver(CompanionRequest(op: .inboxSend, item: chatID, text: text, replyTo: replyTo))
        if case .sent = delivery { await loadInbox() }
        return delivery
    }

    /// Read (`read`) or unread by hand; read tells WhatsApp too.
    func markInbox(_ chatID: String, read: Bool) async {
        await perform(CompanionRequest(op: .inboxMark, item: chatID, allow: read))
    }

    func stopChat(_ conversationID: String) async {
        await perform(CompanionRequest(op: .chatStop, conversation: conversationID))
    }

    // MARK: Why it does not connect

    /// Checks every route once more, in detail, and says what stands in the way (`CompanionDiagnosis`).
    func diagnose() async -> CompanionDiagnosis.Result {
        guard let link else { return CompanionDiagnosis.diagnose(.init(online: isOnline, probes: [])) }
        let key = link.key
        let checked = routes
        let outcomes = await withTaskGroup(of: (Int, CompanionDiagnosis.RouteOutcome).self) { group -> [CompanionDiagnosis.RouteOutcome] in
            for (index, route) in checked.enumerated() {
                group.addTask { (index, await RouteDiagnostics.probe(route, key: key)) }
            }
            var results = [CompanionDiagnosis.RouteOutcome](repeating: .unchecked, count: checked.count)
            for await (index, outcome) in group { results[index] = outcome }
            return results
        }
        let probes = zip(checked, outcomes).map { CompanionDiagnosis.Probe(route: $0.0, outcome: $0.1) }
        let result = CompanionDiagnosis.diagnose(.init(online: isOnline, probes: probes, compatibility: compatibility, lastError: lastRefusal))
        var fields = ["cause": result.cause.rawValue]
        for (index, probe) in probes.enumerated() { fields["\(probe.route.logKind).\(index)"] = String(describing: probe.outcome) }
        CompanionDiagnosticsLog.phone.record("diagnosis", fields)
        return result
    }

    /// What "Copy diagnostics" puts on the clipboard: versions, what is set up, and the redacted log. Nothing is sent.
    func diagnosticsBundle() -> String {
        CompanionDiagnosticsLog.phone.bundle(about: [
            "app": CompanionProtocol.appVersion ?? "?", "protocol": String(CompanionProtocol.version),
            "macApp": macAppVersion ?? "?", "macs": String(pairings.macs.count),
            "routes": routes.map(\.logKind).joined(separator: ","), "features": features.sorted().joined(separator: ","),
            "compatibility": String(describing: compatibility), "phase": String(describing: phase),
            "scopes": scopes.map { $0.sorted().joined(separator: ",") } ?? "all",
        ])
    }

    // MARK: Versions

    /// Opens Nook's update panel on the Mac, where the update waits for a click there; nothing is installed from the
    /// phone. Says what happened in `notice`.
    func requestMacUpdate() async {
        guard can(CompanionFeature.requestUpdate), let response = await perform(CompanionRequest(op: .requestUpdate)) else { return }
        switch response.message {
        case "available": notice = String(localized: "The update is waiting on your Mac: install it there.")
        case "none": notice = String(localized: "Nook on your Mac has no update ready yet.")
        default: notice = String(localized: "Nook on your Mac cannot update itself. Update it the way you installed it.")
        }
    }

    /// Sends a request and takes in whatever the answer carries. The answer when the Mac said yes, else nil with the reason
    /// in `notice`. `quiet` is for the requests a screen repeats by itself: a session or chat that is gone says so on that
    /// screen instead of in an alert every few seconds.
    @discardableResult
    private func perform(_ req: CompanionRequest, quiet: Bool = false) async -> CompanionResponse? {
        guard let link else { return nil }
        do {
            let response = try await transport(req, link: link)
            if response.ok {
                apply(response, to: req)
                if phase != .connected {
                    phase = .connected
                    // The Mac answers again while the supervisor waits between attempts: try the live connection now.
                    if channel == nil { wakeUp(resetBackoff: true) }
                }
                if !outbox.entries.isEmpty, !draining { Task { await drainOutbox() } }
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
            // With a live connection the supervisor decides whether the Mac is gone; a request that timed out alone
            // does not say so.
            if channel == nil { phase = .offline(error.localizedDescription) }
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
        if let list = response.sessions { tookList(list) }
        if let name = response.macName, name != macName {
            macName = name
            if let id = pairings.active?.id {
                pairings.rename(id, to: name)
                PairingStore.save(pairings)
                macs = pairings.macs
            }
        }
        // Only these answers report the Mac's feature list. Missing features on an older Mac clear this warning;
        // unrelated answers leave the last handshake result alone.
        if req.op == .hello || req.op == .list || req.op == .subscribe {
            let unknown = CompanionCompatibility.unknownFeatures(response.features)
            let hasUnknown = unknown?.isEmpty == false
            if hasUnknown != hasUnrecognizedMacFeatures { hasUnrecognizedMacFeatures = hasUnknown }
        }
        // Only an answer to hello, list or subscribe says what the Mac speaks (it carries the features too).
        if response.features != nil {
            let compatible = CompanionCompatibility.check(response)
            if compatible != compatibility { compatibility = compatible }
            if response.appVersion != macAppVersion { macAppVersion = response.appVersion }
            let granted = response.scopes.map(Set.init)
            if granted != scopes { scopes = granted }
        }
        if let features = response.features, Set(features) != self.features {
            self.features = Set(features)
            UserDefaults.standard.set(features, forKey: featuresKey)
        }
        if let endpoints = response.endpoints { learn(endpoints) }
        // The relay the Mac uses now ("" when none): the route through it follows.
        if let relay = CompanionRoutes.withRelay(routes, relay: response.relay) {
            routes = relay
            saveRoutes(relay)
        }
        if req.op == .list || req.op == .hello { featuresKnown = true }
        if let options = response.launch, options != launchOptions {
            launchOptions = options
            // Kept, so a new session can be written (and wait in the outbox) while the Mac cannot be reached.
            cache.launch = options
            scheduleCacheSave()
        }
        if let timeline = response.timeline, let session = response.timelineSession ?? req.session {
            // An update builds on the entry the phone already has; missing it, the whole conversation is asked for once.
            if let merged = TimelineDelta.apply(timeline, after: response.timelineAfter, to: timelines[session]) {
                if timelines[session] != merged {
                    timelines[session] = merged
                    cache.record(timeline: merged, session: session, at: Date())
                    scheduleCacheSave()
                }
            } else {
                Task { await loadTimeline(session) }
            }
        }
        if let files = response.diff, let session = req.session, diffs[session] != files { diffs[session] = files }
        if let list = response.conversations, list != conversations { conversations = list }
        if let lines = response.messages, let conversation = response.created ?? req.conversation, chatLines[conversation] != lines {
            chatLines[conversation] = lines
        }
        if let chats = response.inbox {
            if chats != inbox { inbox = chats }
            if response.message != inboxStatus { inboxStatus = response.message }
        }
        if let lines = response.inboxLines, let chat = req.item, inboxLines[chat] != lines { inboxLines[chat] = lines }
        // A Mac that says nothing of typing leaves it empty, never standing from an earlier answer.
        if response.inboxLines != nil, let chat = req.item {
            let typing = response.inboxTyping ?? []
            if inboxTyping[chat] ?? [] != typing { inboxTyping[chat] = typing }
        }
    }


    /// A list the active Mac answered just now: kept for the next launch, and the notifications about what no longer
    /// waits are taken away, with the badge set to what still does.
    private func tookList(_ list: [SessionDigest]) {
        let now = Date()
        // "Last updated HH:mm": a new value only when the minute changed, so a list every second redraws nothing.
        if lastUpdated.map({ Int($0.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) }) ?? true { lastUpdated = now }
        cache.record(sessions: list, at: now)
        scheduleCacheSave()
        let pending = DeliveredNotifications.pending(list)
        guard pending != clearedPending, let mac = activeMacID else { return }
        clearedPending = pending
        Notifications.clearAnswered(pending: pending, mac: mac, onlyMac: pairings.macs.count == 1, badge: list.needingYou)
    }

    // MARK: Buttons on notifications

    /// Reads the pairings again when the app was started while the phone was locked (the Keychain could not be read
    /// then), so a notification's button finds its Mac once the phone is unlocked.
    private func reloadPairingsIfNeeded() {
        guard pairings.isEmpty else { return }
        let stored = PairingStore.load()
        guard !stored.isEmpty else { return }
        pairings = stored
        loadActive()
        phase = .offline("")
    }

    /// Opens a session from a notification: of the Mac that sent it, which becomes the active one when it is not.
    func open(session: String, mac: String?) {
        reloadPairingsIfNeeded()
        if let mac, mac != pairings.active?.id, pairings.contains(mac) { switchMac(to: mac) }
        openSession = session
    }

    /// A button on a notification (Allow, Deny, Reply), for the Mac that sent it (`mac` in the push; a Mac that does not
    /// say means the active one). Over the live connection when that Mac has one; otherwise the app keeps running in the
    /// background for it, looks for the best route to that Mac (the local network, Tailscale, the relay;
    /// `RouteProbe.pick`) and sends it there. When nothing answers, a notification says so: a Deny or a Reply is kept to
    /// try again (`NotificationRetries`), and a Reply also waits in that Mac's outbox.
    func notificationAction(_ request: CompanionRequest, mac macID: String?) async {
        reloadPairingsIfNeeded()
        guard let mac = macID.flatMap({ id in pairings.macs.first { $0.id == id } }) ?? pairings.active else { return }
        let work = BackgroundWork("Nook: answering from a notification")
        defer { work.end() }
        if let response = await deliverOnce(request, to: mac) {
            took(response, for: request, from: mac)
            return
        }
        CompanionDiagnosticsLog.phone.record("actionUnreachable", ["op": request.op.rawValue,
                                                                   "routes": mac.routes.map(\.logKind).joined(separator: ",")])
        let kept = retries.add(request, mac: mac.id, now: Date())
        RetryStore.save(retries)
        if request.op == .send { keepInOutbox(request, mac: mac) }
        await Notifications.couldNotReach(mac.name, mac: mac.id, session: request.session, retry: kept, id: request.id)
    }

    /// Tries again what notification buttons could not deliver, for one Mac or all: on a tap on "Couldn't reach", when
    /// the app comes to the front, and once connected to that Mac. `quiet`: no new notification when it still fails.
    func retryNotificationActions(mac only: String?, quiet: Bool) async {
        reloadPairingsIfNeeded()
        retries.expire(now: Date())
        defer { RetryStore.save(retries) }
        guard !retries.entries.isEmpty else { return }
        let work = BackgroundWork("Nook: trying again")
        defer { work.end() }
        for id in only.map({ [$0] }) ?? retries.macs {
            guard let mac = pairings.macs.first(where: { $0.id == id }) else {
                for entry in retries.waiting(for: id) { retries.remove(entry.id) }
                continue
            }
            for entry in retries.waiting(for: id) {
                var request = entry.request
                request.sent = Date().timeIntervalSince1970
                guard let response = await deliverOnce(request, to: mac) else {
                    if !quiet {
                        await Notifications.couldNotReach(mac.name, mac: mac.id, session: request.session, retry: true, id: entry.id)
                    }
                    // The Mac is out of reach: what else waits for it waits too.
                    break
                }
                retries.remove(entry.id)
                removeFromOutbox(entry.id, mac: mac)
                Notifications.removeCouldNotReach(entry.id)
                took(response, for: request, from: mac)
            }
        }
    }

    /// One request to one Mac, now: over the live connection when it is that Mac's, else over the best route that
    /// answers (`RouteProbe.pick`, the relay included). Nil when the Mac could not be reached. The request keeps its id,
    /// so a repeat after a lost answer is not carried out twice (`CommandReceipts`).
    private func deliverOnce(_ request: CompanionRequest, to mac: PairedMac) async -> CompanionResponse? {
        guard let link = mac.link else { return nil }
        if mac.id == pairings.active?.id, let channel, channel.isOpen,
           let response = try? await channel.request(request, timeout: 15) {
            return response
        }
        let clockBefore = ClockOffsets.offset(for: mac.id)
        // The route is found with a list (any Mac answers it), so the request itself goes over one route only, once.
        guard let picked = await RouteProbe.pick(mac.id == pairings.active?.id ? routes : mac.routes, key: link.key,
                                                 makeRequest: { CompanionRequest.versioned(.list) }) else { return nil }
        if picked.answer.ok, mac.id != pairings.active?.id, let list = picked.answer.sessions { otherSessions[mac.id] = list }
        var response = try? await exchange(request, link: link, route: picked.route)
        // Refused for the clock while the Mac said its time: once more, with the time corrected.
        if response?.error == .stale, CompanionClock.changed(clockBefore, ClockOffsets.offset(for: mac.id)) {
            response = try? await exchange(request, link: link, route: picked.route)
        }
        return response
    }

    /// Takes in a Mac's answer to a button: the active Mac's like any answer, another Mac's into its list. A refusal is
    /// the Mac's last word (the approval was answered on the Mac already): nothing to try again.
    private func took(_ response: CompanionResponse, for request: CompanionRequest, from mac: PairedMac) {
        if mac.id == pairings.active?.id {
            if response.ok { apply(response, to: request) }
            // The Mac answers: the supervisor need not wait out its backoff.
            if phase != .connected, channel == nil { wakeUp(resetBackoff: true) }
        } else if let list = response.sessions {
            otherSessions[mac.id] = list
        }
    }

    /// The outbox file and the features of a Mac, by its pairing id (`CompanionPairings.storageName`).
    private func outboxFile(for mac: PairedMac) -> String {
        CompanionPairings.storageName("companion-outbox.json", mac: mac.id, legacyID: pairings.legacyID)
    }

    /// A Reply that could not go also waits in its Mac's outbox (when that Mac answers repeats once,
    /// `CompanionFeature.retry`): shown in its session, it goes once the phone reaches that Mac.
    private func keepInOutbox(_ request: CompanionRequest, mac: PairedMac) {
        let featuresName = CompanionPairings.storageName("companion.features", mac: mac.id, legacyID: pairings.legacyID)
        guard (UserDefaults.standard.stringArray(forKey: featuresName) ?? []).contains(CompanionFeature.retry) else { return }
        if mac.id == pairings.active?.id {
            guard outbox.enqueue(request, now: Date()) else { return }
            OutboxStore.save(outbox, name: outboxName)
        } else {
            var other = OutboxStore.load(name: outboxFile(for: mac))
            guard other.enqueue(request, now: Date()) else { return }
            OutboxStore.save(other, name: outboxFile(for: mac))
        }
    }

    private func removeFromOutbox(_ id: String, mac: PairedMac) {
        if mac.id == pairings.active?.id {
            guard outbox.entries.contains(where: { $0.id == id }) else { return }
            outbox.remove(id)
            OutboxStore.save(outbox, name: outboxName)
        } else {
            var other = OutboxStore.load(name: outboxFile(for: mac))
            guard other.entries.contains(where: { $0.id == id }) else { return }
            other.remove(id)
            OutboxStore.save(other, name: outboxFile(for: mac))
        }
    }

    // MARK: Transport

    /// Sends a request: over the live connection when there is one, else over one short connection to the route in use
    /// (or the best known one). A request the Mac refused for the clock, while saying its time (`CompanionFeature.clock`),
    /// goes once more with the corrected time.
    private func transport(_ req: CompanionRequest, link: PairingLink) async throws -> CompanionResponse {
        let mac = PairedDevice.identifier(forKey: link.key)
        let clockBefore = ClockOffsets.offset(for: mac)
        let response = try await transportOnce(req, link: link)
        guard response.error == .stale, CompanionClock.changed(clockBefore, ClockOffsets.offset(for: mac)) else { return response }
        return try await transportOnce(req, link: link)
    }

    /// One try of `transport`. A request the Mac answers once (`CompanionFeature.retry`) may go again after the live
    /// connection broke under it: a repeat gets the first answer, it is never carried out twice.
    private func transportOnce(_ req: CompanionRequest, link: PairingLink) async throws -> CompanionResponse {
        if let channel, channel.isOpen {
            do {
                return try await channel.request(req, timeout: 15)
            } catch {
                // A slow answer on a connection that still lives is just slow.
                if channel.isOpen { throw error }
                guard !CommandReceipts.keeps(req.op) || can(CompanionFeature.retry) else { throw error }
            }
        }
        return try await request(req, using: link)
    }

    /// One short connection. When the Mac does not take it, it may have restarted on another port (or got another
    /// address): it is looked for by its Bonjour name, and the request goes there once. The key never changes, so a Mac
    /// that moved keeps working without pairing again.
    private func request(_ req: CompanionRequest, using link: PairingLink) async throws -> CompanionResponse {
        guard let route = activeRoute ?? routes.first else { throw CompanionClientError.timeout }
        do {
            return try await exchange(req, link: link, route: route)
        } catch where MacFinder.unreachable(error) {
            guard await relocate(), let moved = routes.first(where: { $0.hostKey != route.hostKey || $0.port != route.port }) else { throw error }
            let response = try await exchange(req, link: link, route: moved)
            activeRoute = moved
            return response
        }
    }

    private func exchange(_ req: CompanionRequest, link: PairingLink, route: CompanionRoute) async throws -> CompanionResponse {
        let framed = try CompanionChannel.frame(req, key: link.key, deviceID: PairedDevice.identifier(forKey: link.key))
        let reply = try await Exchange.run(route: route, key: link.key, payload: framed)
        let opened = try CompanionSeal.open(reply, pairingKey: link.key, direction: .response)
        let response = try JSONDecoder().decode(CompanionResponse.self, from: opened)
        guard response.id == req.id else { throw CompanionClientError.badRequest }
        ClockOffsets.learn(from: response, mac: PairedDevice.identifier(forKey: link.key))
        return response
    }
}

extension CompanionDiagnosticsLog {
    /// The phone's companion log (docs/COMPANION.md, "Diagnostics"): local only, copied redacted from "Why can't I connect?".
    static let phone = CompanionDiagnosticsLog(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("companion-diagnostics.ndjson"))
}

extension CompanionRoute {
    /// The kind of route for the diagnostics log: never its address.
    var logKind: String { isRelay ? "relay" : kind.rawValue }
}

/// Messages that wait for a Mac, one file per Mac (`name`), of the app, that only opens while the phone is unlocked.
enum OutboxStore {
    private static func url(_ name: String) -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name)
    }

    static func load(name: String) -> CompanionOutbox {
        guard let url = url(name), let data = try? Data(contentsOf: url),
              let outbox = try? JSONDecoder().decode(CompanionOutbox.self, from: data) else { return CompanionOutbox() }
        return outbox
    }

    static func save(_ outbox: CompanionOutbox, name: String) {
        guard let url = url(name) else { return }
        if outbox.entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(outbox) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}


enum CompanionClientError: LocalizedError {
    case refused(CompanionError?)
    case storage, badRequest, timeout, closed, tooManyMacs

    var errorDescription: String? {
        switch self {
        case .refused: return String(localized: "Your Mac refused the code.")
        case .storage: return String(localized: "The key could not be saved.")
        case .badRequest: return String(localized: "Unreadable reply from your Mac.")
        case .timeout: return String(localized: "Your Mac does not answer. Is the companion on, and are you on the same Wi‑Fi?")
        case .closed: return String(localized: "The connection was lost.")
        case .tooManyMacs: return String(localized: "This iPhone is paired with as many Macs as it can keep. Unpair one first.")
        }
    }
}

/// Finds the Mac on the local network by the Bonjour service its companion server announces
/// (`CompanionConstants.bonjourType`, named after the Mac), and where it listens now.
private enum MacFinder {
    struct Place {
        let host: String
        let port: UInt16
    }

    /// Errors that mean nothing listens at the saved place: refused, unreachable, or no answer at all.
    static func unreachable(_ error: Error) -> Bool {
        if case CompanionClientError.timeout = error { return true }
        guard let error = error as? NWError else { return false }
        switch error {
        case .posix(let code): return [.ECONNREFUSED, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ETIMEDOUT].contains(code)
        case .dns: return true
        default: return false
        }
    }

    /// The service named `name`, or the only one there is (the Mac was renamed); nil when none answers in a few seconds.
    static func find(name: String) async -> Place? {
        guard let endpoint = await browse(name: name) else { return nil }
        return await resolve(endpoint)
    }

    private static func browse(name: String) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: CompanionConstants.bonjourType, domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "nook.companion.browse")
            let once = OnceValue<NWEndpoint?>(continuation)
            func finish(_ endpoint: NWEndpoint?) {
                browser.cancel()
                once.resume(endpoint)
            }
            browser.browseResultsChangedHandler = { results, _ in
                let services = results.map(\.endpoint)
                if let named = services.first(where: { if case .service(name, _, _, _) = $0 { return true } else { return false } }) {
                    finish(named)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: queue)
            // Without the exact name, settle for the only Mac that answered.
            queue.asyncAfter(deadline: .now() + 3) {
                let services = browser.browseResults.map(\.endpoint)
                finish(services.count == 1 ? services[0] : nil)
            }
        }
    }

    /// Where a service listens, as an IPv4 address and port: connect to it and read the other end.
    private static func resolve(_ endpoint: NWEndpoint) async -> Place? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let connection = NWConnection(to: endpoint, using: parameters)
            let queue = DispatchQueue(label: "nook.companion.resolve")
            let once = OnceValue<Place?>(continuation)
            func finish(_ place: Place?) {
                connection.cancel()
                once.resume(place)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        let text: String
                        switch host {
                        case .ipv4(let address): text = "\(address)"
                        case .ipv6(let address): text = "\(address)"
                        case .name(let name, _): text = name
                        @unknown default: text = "\(host)"
                        }
                        finish(Place(host: text, port: port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    /// Resumes a continuation once, however many callbacks race.
    private final class OnceValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

        func resume(_ value: Value) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
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
        // The buttons ask for the phone to be unlocked: the pairings (the keys to reach the Mac) only open then.
        let deny = UNNotificationAction(identifier: PushCategory.actionDeny, title: String(localized: "Deny"),
                                        options: [.destructive, .authenticationRequired])
        let allow = UNNotificationAction(identifier: PushCategory.actionAllow, title: String(localized: "Allow"),
                                         options: [.authenticationRequired])
        // Answer the agent right from a notification that its turn ended, without opening the app.
        let reply = UNTextInputNotificationAction(identifier: PushCategory.actionReply, title: String(localized: "Reply"),
                                                  options: [.authenticationRequired],
                                                  textInputButtonTitle: String(localized: "Send"),
                                                  textInputPlaceholder: String(localized: "Message to the agent"))
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: PushCategory.approvalDeny, actions: [deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.approvalAllow, actions: [deny, allow], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.question, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.info, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.retry, actions: [], intentIdentifiers: [], options: [])
        ])
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    /// Takes away the delivered notifications of `mac` about approvals and questions that no longer wait
    /// (`DeliveredNotifications`), and sets the badge to what still does (nil leaves it).
    static func clearAnswered(pending: Set<String>, mac: String, onlyMac: Bool, badge: Int?) {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications().map { note in
                DeliveredNotifications.Delivered(id: note.request.identifier, nook: note.request.content.userInfo["nook"] as? [String: Any])
            }
            let stale = DeliveredNotifications.stale(delivered, pending: pending, mac: mac, onlyMac: onlyMac)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            if let badge { setBadge(badge) }
        }
    }

    /// Says that a button on a notification could not reach the Mac named `name`: with `retry`, a tap tries again
    /// (`CompanionClient.retryNotificationActions`); an Allow is not kept, so it says to answer again.
    static func couldNotReach(_ name: String, mac: String, session: String?, retry: Bool, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Not sent")
        content.body = retry ? String(localized: "Couldn’t reach \(name). Tap to try again.")
            : String(localized: "Couldn’t reach \(name): your answer was not sent. Open the app to answer again.")
        content.categoryIdentifier = PushCategory.retry
        if let session { content.threadIdentifier = session }
        var nook: [String: Any] = ["mac": mac, "retry": retry]
        if let session { nook["session"] = session }
        content.userInfo = ["nook": nook]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: couldNotReachID(id), content: content, trigger: nil))
    }

    static func removeCouldNotReach(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [couldNotReachID(id)])
    }

    private static func couldNotReachID(_ id: String) -> String { "nook-retry-" + id }
}

/// A message your Mac refused (`CompanionClient.rejected`): what you wrote, the pictures with it, and why, in words.
struct RejectedMessage: Identifiable, Equatable {
    let id = UUID()
    let session: String
    let text: String
    let images: [CompanionImage]
    let reason: String

    static func reason(_ response: CompanionResponse) -> String {
        if let message = response.message, !message.isEmpty { return message }
        switch response.error ?? .failed {
        case .unknownSession: return String(localized: "This session is gone.")
        case .badRequest: return String(localized: "The message was empty or too long, or a picture could not be read.")
        case .notAllowedFromPhone: return String(localized: "Your Mac does not let this iPhone send that.")
        default: return String(localized: "Your Mac refused this.")
        }
    }
}
