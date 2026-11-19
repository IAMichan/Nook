import Foundation

/// How much of a forge's API limit is left, read from the headers of every answer Nook gets (`X-RateLimit-*` on GitHub
/// and Gitea, `RateLimit-*` on GitLab), per host and per limit (GitHub counts REST, GraphQL and search separately).
///
/// GitHub gives an account 5000 REST requests an hour, shared by every app and CLI signed in as that account. Nook's
/// badges, branch syncs and watched pull requests poll, so with many sessions open they used the whole hour, and then
/// every read failed until the reset. With this budget:
/// - the polls that read GitHub in the background wait longer as the limit runs low (`slowdown`) and stop under the
///   last tenth (`allowsBackground`), which is kept for what you do yourself (opening a pull request, merging);
/// - once the limit is used up, `ForgeRateGate` answers each request itself, without the network, until the reset;
/// - a pull request's status goes through GitHub's GraphQL API, batched and on a limit of its own, with REST as the
///   way back (`prefersGraphQL`).
///
/// Foundation only, so it is tested anywhere.
final class ForgeRateBudget: @unchecked Sendable {
    static let shared = ForgeRateBudget()

    /// One limit of one host as the last answer told it.
    struct Window: Equatable {
        var limit: Int
        var remaining: Int
        var reset: Date
    }

    private let lock = NSLock()
    private var windows: [String: Window] = [:]
    /// A wait the forge asked for without saying how much is left (GitHub's secondary limit sends only `Retry-After`).
    private var pauses: [String: Date] = [:]
    /// Refusals in a row without a time to wait: each one waits twice as long (`fallbackPause`).
    private var refusals: [String: Int] = [:]

    /// Below this share of a limit, background reads stop: the rest is kept for what you do yourself (as t3code's
    /// `GitHubQuota` reserve).
    static let reserve = 0.1

    init() {}

    /// The limit a request counts against: GitHub's GraphQL and search have their own, everything else is "core".
    static func resource(of url: URL) -> String {
        let path = url.path.lowercased()
        if path.hasSuffix("/graphql") { return "graphql" }
        if path.contains("/search/") { return "search" }
        return "core"
    }

    private static func key(host: String, resource: String) -> String { host.lowercased() + "|" + resource }

    private static func key(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        return key(host: host, resource: resource(of: url))
    }

    /// Notes what an answer said about its limit. Answers without limit headers (most services) change nothing.
    func record(_ response: HTTPURLResponse, now: Date = Date()) {
        guard let url = response.url, let host = url.host else { return }
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: "X-RateLimit-" + name) ?? response.value(forHTTPHeaderField: "RateLimit-" + name)
        }
        let resource = response.value(forHTTPHeaderField: "X-RateLimit-Resource") ?? Self.resource(of: url)
        let key = Self.key(host: host, resource: resource)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        lock.lock()
        defer { lock.unlock() }
        if let limit = header("Limit").flatMap(Int.init), let remaining = header("Remaining").flatMap(Int.init),
           let resetValue = header("Reset").flatMap(TimeInterval.init), limit > 0 {
            // GitHub and GitLab send the reset as a Unix time; some forges send seconds from now.
            let reset = resetValue > 1_000_000_000 ? Date(timeIntervalSince1970: resetValue) : now.addingTimeInterval(resetValue)
            windows[key] = Window(limit: limit, remaining: max(remaining, 0), reset: reset)
        }
        if response.statusCode == 429 || (response.statusCode == 403 && retryAfter != nil) {
            if let retryAfter, retryAfter > 0 {
                pauses[key] = now.addingTimeInterval(min(retryAfter, 3600))
            } else if windows[key].map({ $0.remaining > 0 || $0.reset <= now }) ?? true {
                // Refused without saying for how long: wait a while, longer after each refusal in a row.
                let attempt = (refusals[key] ?? 0) + 1
                refusals[key] = attempt
                pauses[key] = now.addingTimeInterval(Self.fallbackPause(attempt: attempt))
            }
        } else if (200..<400).contains(response.statusCode) {
            refusals[key] = nil
        }
    }

    /// 30 seconds after the first refusal without a time, twice as long after each next one, at most 15 minutes.
    static func fallbackPause(attempt: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(attempt - 1, 0))), 15 * 60)
    }

    /// The window of one limit while it is current; nil once its reset has passed (the forge has filled it again).
    func window(host: String = "api.github.com", resource: String = "core", now: Date = Date()) -> Window? {
        lock.lock()
        defer { lock.unlock() }
        guard let window = windows[Self.key(host: host, resource: resource)], window.reset > now else { return nil }
        return window
    }

    /// Until when a request must not go out: its limit is used up, or the forge asked Nook to wait. Nil to send it.
    func pausedUntil(_ url: URL, now: Date = Date()) -> Date? {
        guard let key = Self.key(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var until: Date?
        if let window = windows[key], window.remaining == 0, window.reset > now { until = window.reset }
        if let pause = pauses[key], pause > now { until = max(until ?? pause, pause) }
        return until
    }

    /// Whether a background read of this limit may go out: it is not paused and more than the reserve is left. What
    /// you do yourself (opening a page, merging) skips this and may use the reserve.
    func allowsBackground(host: String = "api.github.com", resource: String = "core", now: Date = Date()) -> Bool {
        let key = Self.key(host: host, resource: resource)
        lock.lock()
        defer { lock.unlock() }
        if let pause = pauses[key], pause > now { return false }
        guard let window = windows[key], window.reset > now else { return true }
        return Double(window.remaining) >= Double(window.limit) * Self.reserve
    }

    /// `allowsBackground` for the host a pull request or repository page lives on. `orGraphQL`: the read can also go
    /// through GraphQL (`prefersGraphQL`), so either limit having room is enough.
    func allowsBackground(forPage url: URL?, orGraphQL: Bool = false, now: Date = Date()) -> Bool {
        guard let host = Self.apiHost(forPage: url) else { return true }
        return allowsBackground(host: host, now: now) || (orGraphQL && allowsBackground(host: host, resource: "graphql", now: now))
    }

    /// The API host of a page: `api.github.com` for github.com, the host itself for GitHub Enterprise and other forges.
    static func apiHost(forPage url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return host == "github.com" || host == "www.github.com" ? "api.github.com" : host
    }

    /// How many times longer a background poll of this limit waits: 1 while at least half is left, then 2 and 4 as it
    /// runs out, so the hour's requests are spread instead of spent in its first minutes. Under the reserve background
    /// reads stop altogether (`allowsBackground`). Nothing known (or a reset that has passed) is 1.
    func slowdown(host: String = "api.github.com", resource: String = "core", now: Date = Date()) -> Double {
        guard let window = window(host: host, resource: resource, now: now) else { return 1 }
        return Self.slowdown(remaining: window.remaining, limit: window.limit)
    }

    static func slowdown(remaining: Int, limit: Int) -> Double {
        guard limit > 0 else { return 1 }
        let left = Double(remaining) / Double(limit)
        if left >= 0.5 { return 1 }
        if left >= 0.25 { return 2 }
        return 4
    }

    /// The slowdown of the host a pull request or repository link lives on: `api.github.com` for github.com, the host
    /// itself for GitHub Enterprise, GitLab and Gitea.
    func slowdown(forPage url: URL?, orGraphQL: Bool = false, now: Date = Date()) -> Double {
        guard let host = Self.apiHost(forPage: url) else { return 1 }
        let rest = slowdown(host: host, now: now)
        return orGraphQL ? min(rest, slowdown(host: host, resource: "graphql", now: now)) : rest
    }

    /// Whether a read that GraphQL can also answer (a pull request's status) should take it. GraphQL goes first, as
    /// t3code reads pull requests: batched, one request covers many (`GitHubSnapshotBatcher`), and it keeps the REST
    /// limit for what only REST can do (logs, Actions, the branch lookup). REST takes over while GraphQL is paused, or
    /// under a quarter and lower than REST.
    func prefersGraphQL(host: String = "api.github.com", now: Date = Date()) -> Bool {
        func left(_ resource: String) -> Double? {
            window(host: host, resource: resource, now: now).map { Double($0.remaining) / Double($0.limit) }
        }
        if let url = URL(string: "https://\(host)/graphql"), pausedUntil(url, now: now) != nil { return false }
        let restPaused = URL(string: "https://\(host)/").flatMap { pausedUntil($0, now: now) } != nil
        let rest = restPaused ? 0 : (left("core") ?? 1)
        let graph = left("graphql") ?? 1
        return graph >= 0.25 || graph > rest
    }

    /// Forgets everything (tests).
    func reset() {
        lock.lock()
        windows = [:]
        pauses = [:]
        refusals = [:]
        lock.unlock()
    }
}

/// Answers a request to a forge whose limit is used up, without sending it: the same 429 the forge would give, with the
/// reset time, so every caller shows "limit reached until …" as it already does, and Nook stops asking a forge that
/// would only say no. Installed in `ConnectorHTTP`'s sessions; every other request passes untouched.
final class ForgeRateGate: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return ForgeRateBudget.shared.pausedUntil(url) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, body) = Self.refusal(url, until: ForgeRateBudget.shared.pausedUntil(url) ?? Date().addingTimeInterval(60))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The answer the gate gives: 429 with GitHub's own limit headers and words, so `GitHubRateLimit` and
    /// `ConnectorErrorKind.isRateLimit` read it as the forge's.
    static func refusal(_ url: URL, until: Date) -> (HTTPURLResponse, Data) {
        let seconds = max(Int(until.timeIntervalSinceNow.rounded(.up)), 1)
        let headers = ["Content-Type": "application/json",
                       "X-RateLimit-Remaining": "0",
                       "X-RateLimit-Reset": String(Int(until.timeIntervalSince1970.rounded(.up))),
                       "X-RateLimit-Resource": ForgeRateBudget.resource(of: url),
                       "Retry-After": String(seconds)]
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
        let body = Data(#"{"message":"API rate limit exceeded for user (Nook waits until it resets)."}"#.utf8)
        return (response, body)
    }
}
