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
    private(set) var pushToken: String?

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

    private static let featuresKey = "companion.features"

    init() {
        link = PairingStore.load()
        macName = link?.macName ?? ""
        phase = link == nil ? .unpaired : .offline("")
        if let link { routes = PairingStore.loadRoutes() ?? CompanionRoutes.initial(from: link) }
        // What the Mac could do last time, so a message written before the first answer can already wait in the outbox.
        features = Set(UserDefaults.standard.stringArray(forKey: Self.featuresKey) ?? [])
        outbox = OutboxStore.load()
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
                guard PairingStore.save(parsed) else { throw CompanionClientError.storage }
                stopConnection()
                link = parsed
                routes = candidates
                PairingStore.saveRoutes(routes)
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

    func unpair() {
        stopConnection()
        Task { await LiveActivities.shared.endAll() }
        PairingStore.clear()
        link = nil
        routes = []
        activeRoute = nil
        outbox = CompanionOutbox()
        OutboxStore.save(outbox)
        UserDefaults.standard.removeObject(forKey: Self.featuresKey)
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

    // MARK: Staying connected

    /// The app came to the front: connect, or check the connection. After a real break the connection is replaced at
    /// once (iOS may have killed the socket without a word); after a glance elsewhere a quick probe is enough.
    func appBecameActive() {
        let wakeup = CompanionWakeup.onActive(backgroundedAt: backgroundedAt, now: Date())
        backgroundedAt = nil
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
            replacing = true
            channel.close()
        case .probe:
            Task { await probe(channel) }
        }
    }

    func appWentToBackground() {
        backgroundedAt = Date()
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
            // Every route is asked for the list: any Mac answers it, and the answer says whether it keeps a live
            // connection, so a Mac that was updated (or rolled back) in the meantime is met as it is now.
            guard let picked = await RouteProbe.pick(attemptOrder(), key: link.key, makeRequest: { CompanionRequest.versioned(.list) }) else {
                if Task.isCancelled { return }
                // Nothing answered: the Mac may listen on another port now; Bonjour finds it on the local network.
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
            guard picked.answer.ok else {
                failures += 1
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
            let response = try await channel.request(CompanionRequest.versioned(.subscribe), timeout: 10)
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
            if Task.isCancelled { return }
            if Date().timeIntervalSince(since) >= RetryBackoff.stableAfter { failures = 0 }
            if !replacing {
                failures += 1
                phase = .offline("")
            }
        } catch {
            channel.close()
            if self.channel === channel { self.channel = nil }
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
        await LiveActivities.shared.reconcile(sessions)
        await drainOutbox()
        await refreshInbox()
    }

    private func refreshInbox() async {
        guard phase == .connected, can(CompanionFeature.inbox) else { return }
        await perform(CompanionRequest(op: .inbox), quiet: true)
    }

    /// What the Mac sent by itself over the live connection.
    private func received(_ update: CompanionResponse) {
        apply(update, to: CompanionRequest(op: .list))
        Task { await LiveActivities.shared.reconcile(sessions) }
    }

    /// A quick look whether the channel still answers; if not, it is replaced at once.
    private func probe(_ channel: CompanionChannel) async {
        do {
            _ = try await channel.request(CompanionRequest(op: .ping), timeout: CompanionTiming.probeTimeout)
        } catch {
            guard self.channel === channel else { return }
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
        PairingStore.saveRoutes(routes)
        return true
    }

    /// Takes in the addresses the Mac reported; a better route than the one in use is checked right away.
    private func learn(_ reported: [CompanionEndpoint]) {
        guard let merged = CompanionRoutes.merge(routes, reported: reported) else { return }
        routes = merged
        PairingStore.saveRoutes(merged)
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
            OutboxStore.save(outbox)
            notice = String(localized: "A message that waited more than a day for your Mac was not sent.")
        }
        while let entry = outbox.entries.first {
            let request = CompanionOutbox.resend(entry, now: Date())
            guard let response = try? await transport(request, link: link) else { return }
            // Refused for now (still being handled, a burst, the clocks): it waits for the next try.
            if !response.ok, let error = response.error, [CompanionError.replay, .stale, .rateLimited, .busy, .failed].contains(error) { return }
            outbox.remove(entry.id)
            OutboxStore.save(outbox)
            if response.ok {
                apply(response, to: request)
                if response.message == "queued" { notice = String(localized: "Queued: the session is still busy.") }
            } else if response.error == .unknownSession {
                notice = String(localized: "This session is gone; your message was not sent.")
            } else {
                notice = String(localized: "Your Mac refused this.")
            }
        }
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

    /// A message to a session. With a Mac that answers repeats once (`CompanionFeature.retry`) it goes through the
    /// outbox: kept on the phone until the Mac took it, so it is not lost when the Mac cannot be reached right now.
    func send(_ session: SessionDigest, text: String) async {
        let request = CompanionRequest(op: .send, session: session.id, text: text)
        guard can(CompanionFeature.retry), outbox.enqueue(request, now: Date()) else {
            await perform(request)
            return
        }
        OutboxStore.save(outbox)
        await drainOutbox()
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
        return CompanionDiagnosis.diagnose(.init(online: isOnline, probes: probes, compatibility: compatibility, lastError: lastRefusal))
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
        if let name = response.macName, name != macName { macName = name }
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
            UserDefaults.standard.set(features, forKey: Self.featuresKey)
        }
        if let endpoints = response.endpoints { learn(endpoints) }
        // The relay the Mac uses now ("" when none): the route through it follows.
        if let relay = CompanionRoutes.withRelay(routes, relay: response.relay) {
            routes = relay
            PairingStore.saveRoutes(relay)
        }
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

    /// Sends a request: over the live connection when there is one, else over one short connection to the route in use
    /// (or the best known one). A request the Mac answers once (`CompanionFeature.retry`) may go again after the live
    /// connection broke under it: a repeat gets the first answer, it is never carried out twice.
    private func transport(_ req: CompanionRequest, link: PairingLink) async throws -> CompanionResponse {
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
        return response
    }
}

/// Messages that wait for the Mac, in a file of the app that only opens while the phone is unlocked.
enum OutboxStore {
    private static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("companion-outbox.json")
    }

    static func load() -> CompanionOutbox {
        guard let url, let data = try? Data(contentsOf: url),
              let outbox = try? JSONDecoder().decode(CompanionOutbox.self, from: data) else { return CompanionOutbox() }
        return outbox
    }

    static func save(_ outbox: CompanionOutbox) {
        guard let url else { return }
        if outbox.entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(outbox) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
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
