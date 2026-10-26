import Foundation

// How the phone reaches the Mac, and keeps reaching it. Shared by the Mac app and the iPhone app; Foundation only, so the
// rules are tested on Linux (docs/COMPANION.md, "Staying connected").
//
// - A paired Mac has an ordered list of routes (its .local name, LAN addresses, its Tailscale address). The phone tries
//   them all at once and connects over the first one that answers, preferring the earlier ones.
// - The Mac reports the addresses it can be reached at now; the phone keeps them as learned routes and drops the ones the
//   Mac stops reporting, so a new Wi-Fi address or a Tailscale address is picked up without pairing again.
// - While connected over a later route, the phone checks the earlier ones now and then and moves back when one answers.
// - Every message stays sealed with the pairing key: a route that reaches another machine simply cannot answer.

enum CompanionAddress {
    /// What kind of network an address belongs to; the order of preference of routes follows it.
    enum Kind: String, Codable, Sendable {
        case loopback, lan, tailnet, vpn, internet
    }

    /// The four octets of a dotted IPv4 address, or nil.
    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    static func classify(_ rawHost: String) -> Kind {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host == "::1" { return .loopback }
        if let o = ipv4(host) {
            switch (o[0], o[1]) {
            case (127, _): return .loopback
            case (10, _), (192, 168), (169, 254): return .lan
            case (172, 16...31): return .lan
            // The shared address space: Tailscale uses it, and so do other VPNs. Only the Mac can say it is its tailnet.
            case (100, 64...127): return .vpn
            default: return .internet
            }
        }
        if host.contains(":") {
            if host.hasPrefix("fd7a:115c:a1e0:") { return .tailnet }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") { return .lan }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return .lan }
            return .internet
        }
        if host.hasSuffix(".ts.net") { return .tailnet }
        if host.hasSuffix(".local") || !host.contains(".") { return .lan }
        return .internet
    }
}

/// One way to reach the paired Mac.
struct CompanionRoute: Codable, Equatable, Hashable, Sendable {
    var host: String
    var port: UInt16
    /// Reported by the Mac, not part of what was paired: it goes away when the Mac stops reporting it.
    var learned: Bool
    /// The Mac said this is its Tailscale address (a 100.64/10 address could be any VPN otherwise).
    var tailnet: Bool
    /// Set for the route through the relay (`CompanionRelay`): the relay's address. `host` and `port` are unused then.
    var relay: String?

    init(host: String, port: UInt16, learned: Bool = false, tailnet: Bool = false, relay: String? = nil) {
        self.host = host; self.port = port; self.learned = learned; self.tailnet = tailnet; self.relay = relay
    }

    /// The route through a relay; the Mac says which one (`CompanionResponse.relay`).
    static func viaRelay(_ address: String) -> CompanionRoute {
        CompanionRoute(host: URLComponents(string: address)?.host ?? address, port: 443, relay: address)
    }

    var isRelay: Bool { relay != nil }
    var kind: CompanionAddress.Kind { tailnet ? .tailnet : CompanionAddress.classify(host) }
    /// The same address, whatever port it listens on now.
    var hostKey: String { relay.map { "relay:" + $0.lowercased() } ?? host.lowercased() }
}

/// An address the Mac reports it can be reached at (in `CompanionResponse.endpoints`).
struct CompanionEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: UInt16
    var tailnet: Bool?
}

enum CompanionRoutes {
    /// The order of preference: this device, the local network, the tailnet (or another VPN), the internet.
    static func rank(_ route: CompanionRoute) -> Int {
        // The relay goes through the internet twice: the last resort, after anything direct.
        if route.isRelay { return 4 }
        switch route.kind {
        case .loopback: return 0
        case .lan: return 1
        case .tailnet, .vpn: return 2
        case .internet: return 3
        }
    }

    /// Adds a route after the ones that are at least as good, so a new LAN address comes before a Tailscale one.
    static func insert(_ routes: [CompanionRoute], _ route: CompanionRoute) -> [CompanionRoute] {
        var next = routes
        let index = next.firstIndex { rank($0) > rank(route) } ?? next.count
        next.insert(route, at: index)
        return next
    }

    /// The routes of a fresh pairing: the code's host first (what the user scanned), then the addresses it listed,
    /// which are learned (the Mac reports them again once connected, and drops the ones that went away).
    static func initial(from link: PairingLink) -> [CompanionRoute] {
        var routes = [CompanionRoute(host: link.host, port: link.port)]
        var seen: Set<String> = [link.host.lowercased()]
        for host in link.alternates where seen.insert(host.lowercased()).inserted {
            routes = insert(routes, CompanionRoute(host: host, port: link.port, learned: true))
        }
        if let relay = link.relay { routes = insert(routes, .viaRelay(relay)) }
        return routes
    }

    /// The routes after the Mac said which relay it uses: nil (a Mac that does not say) changes nothing, an empty
    /// address removes the relay route, any other replaces it. Nil when nothing changed.
    static func withRelay(_ saved: [CompanionRoute], relay: String?) -> [CompanionRoute]? {
        guard let relay else { return nil }
        var next = saved.filter { !$0.isRelay }
        if let address = CompanionRelay.normalize(relay), !relay.isEmpty { next = insert(next, .viaRelay(address)) }
        return next == saved ? nil : next
    }

    /// The routes after the Mac reported where it can be reached; nil when nothing changed.
    /// Routes that were paired stay (with the port the Mac reports for them); learned routes follow the report; a
    /// loopback address never becomes a route, since it would name the phone itself.
    static func merge(_ saved: [CompanionRoute], reported: [CompanionEndpoint]) -> [CompanionRoute]? {
        var byHost: [String: CompanionEndpoint] = [:]
        var order: [String] = []
        for endpoint in reported where PairingLink.validHost(endpoint.host) && endpoint.port > 0 {
            let key = endpoint.host.lowercased()
            guard CompanionAddress.classify(key) != .loopback, byHost[key] == nil else { continue }
            byHost[key] = endpoint
            order.append(key)
        }
        var next: [CompanionRoute] = []
        var known: Set<String> = []
        for route in saved {
            if route.isRelay {
                next.append(route)
                continue
            }
            guard let endpoint = byHost[route.hostKey] else {
                if !route.learned, known.insert(route.hostKey).inserted { next.append(route) }
                continue
            }
            guard known.insert(route.hostKey).inserted else { continue }
            var updated = route
            updated.port = endpoint.port
            updated.tailnet = endpoint.tailnet ?? route.tailnet
            next.append(updated)
        }
        for key in order where !known.contains(key) {
            guard let endpoint = byHost[key] else { continue }
            known.insert(key)
            next = insert(next, CompanionRoute(host: endpoint.host, port: endpoint.port, learned: true, tailnet: endpoint.tailnet ?? false))
        }
        return next == saved ? nil : next
    }

    /// Which route to use while the checks of all routes run at once (`answered` in route order: true answered, false
    /// stayed silent or failed, nil still running). The earliest route that answered, once every earlier one has failed;
    /// after the head start, any route that answered, the earliest first. `.wait` while that is not settled yet,
    /// `.unreachable` when every route failed.
    enum Pick: Equatable { case route(Int), wait, unreachable }

    static func pick(_ answered: [Bool?], headStartPassed: Bool) -> Pick {
        for (index, result) in answered.enumerated() {
            if result == true { return .route(index) }
            if result == nil {
                if headStartPassed, let later = answered[index...].firstIndex(where: { $0 == true }) { return .route(later) }
                return .wait
            }
        }
        return .unreachable
    }
}

/// When to try again after a connection failed: exponential with jitter, so phones of a restarted Mac do not all come
/// back in the same second, and capped so a Mac that is off is not looked for constantly.
enum RetryBackoff {
    static let base: TimeInterval = 1
    static let cap: TimeInterval = 60
    /// A connection that stayed up this long resets the ladder.
    static let stableAfter: TimeInterval = 30

    /// The delay after `failures` failures in a row (1 or more); `random` in 0...1.
    static func delay(failures: Int, random: Double) -> TimeInterval {
        let ceiling = min(cap, base * Double(1 << min(max(failures, 1), 10)))
        return ceiling / 2 + ceiling / 2 * min(max(random, 0), 1)
    }
}

/// The timing of a live connection to the Mac.
enum CompanionTiming {
    /// The phone pings this often while connected …
    static let pingEvery: TimeInterval = 5
    /// … and gives up on a connection that sent nothing back for this long.
    static let silenceLimit: TimeInterval = 15
    /// A quick look whether the connection still works (after a network change, or back from a short break).
    static let probeTimeout: TimeInterval = 3
    /// How long each route may take to answer a check, and how long the earlier routes get before a later one is used.
    static let routeCheckTimeout: TimeInterval = 2.5
    static let routeHeadStart: TimeInterval = 0.5
    /// While connected over a later route, how often the earlier ones are checked …
    static let betterRouteEvery: TimeInterval = 60
    /// … and how long a route that answered the check but then failed to connect is left alone.
    static let routeCooldown: TimeInterval = 300
    /// The Mac closes a live connection that sent nothing for this long.
    static let streamIdle: TimeInterval = 45
}

/// What to do when the app comes back to the front. iOS can kill a suspended socket without telling it, so after a real
/// break the connection is replaced at once; after a glance elsewhere a quick probe is enough.
enum CompanionWakeup: Equatable, Sendable {
    case probe, reconnect

    static let reconnectAfter: TimeInterval = 10

    static func onActive(backgroundedAt: Date?, now: Date) -> CompanionWakeup {
        guard let backgroundedAt else { return .probe }
        return now.timeIntervalSince(backgroundedAt) >= reconnectAfter ? .reconnect : .probe
    }
}

/// Routes that answered a check but then failed to connect, held back for a while so a flaky network cannot bounce
/// the connection between routes.
struct RouteCooldowns: Equatable, Sendable {
    private var until: [String: Date] = [:]

    func allows(_ route: CompanionRoute, now: Date) -> Bool { (until[route.hostKey] ?? .distantPast) <= now }

    mutating func hold(_ route: CompanionRoute, now: Date) {
        until[route.hostKey] = now.addingTimeInterval(CompanionTiming.routeCooldown)
    }
}

/// Messages written while the Mac could not be reached. They keep their request id: the Mac answers a repeat of an id
/// it already handled with the answer it gave (`CommandReceipts`), so a message whose answer was lost is never sent twice.
struct CompanionOutbox: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var request: CompanionRequest
        /// When it was written (seconds since 1970).
        var queued: Double
        var id: String { request.id }
    }

    private(set) var entries: [Entry] = []

    static let maxEntries = 50
    /// A message that could not go out within a day is dropped rather than sent into a conversation that moved on.
    static let maxAge: TimeInterval = 24 * 3600

    /// Only a message to a session waits: an approval, an answer or a stop means something only now.
    static func queues(_ op: CompanionOp) -> Bool { op == .send }

    /// False when it cannot wait (another kind of request, or the outbox is full).
    @discardableResult
    mutating func enqueue(_ request: CompanionRequest, now: Date) -> Bool {
        guard Self.queues(request.op), entries.count < Self.maxEntries else { return false }
        guard !entries.contains(where: { $0.id == request.id }) else { return true }
        entries.append(Entry(request: request, queued: now.timeIntervalSince1970))
        return true
    }

    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// Drops what is too old and returns it.
    @discardableResult
    mutating func expire(now: Date) -> [Entry] {
        let limit = now.timeIntervalSince1970 - Self.maxAge
        let old = entries.filter { $0.queued < limit }
        entries.removeAll { $0.queued < limit }
        return old
    }

    func waiting(for session: String) -> [Entry] { entries.filter { $0.request.session == session } }

    /// The request to send now: the same id, with the current time (the Mac refuses requests older than a minute).
    static func resend(_ entry: Entry, now: Date) -> CompanionRequest {
        var request = entry.request
        request.sent = now.timeIntervalSince1970
        return request
    }
}

/// The Mac's answers to requests that change something, by request id, so a repeated request (a retry after a lost
/// answer, or a message from the outbox) gets the same answer instead of being carried out twice.
struct CommandReceipts: Sendable {
    static let capacity = 200
    private var order: [String] = []
    private var stored: [String: CompanionResponse] = [:]

    init() {}

    static func keeps(_ op: CompanionOp) -> Bool {
        switch op {
        case .send, .answer, .decide, .stop, .start, .ask, .inboxSend, .manage, .chatStop: return true
        default: return false
        }
    }

    func response(for id: String) -> CompanionResponse? { stored[id] }

    /// Keeps an answer that settles the request; a passing failure (`failed`, `busy`) may be tried again.
    mutating func record(_ id: String, _ response: CompanionResponse) {
        guard response.ok || (response.error != .failed && response.error != .busy) else { return }
        if stored[id] == nil {
            order.append(id)
            if order.count > Self.capacity { stored[order.removeFirst()] = nil }
        }
        stored[id] = response
    }
}
