import Foundation

/// GitHub's event feed of one pull request: a subscription to the pull request's reviews, head,
/// state and merge conflicts, and a server-sent event stream that says *that* something changed, never what. A watch
/// reads the pull request again on each event and when a stream (re)connects, so it hears of a change in seconds; the
/// two-minute sweep stays as the fallback for when GitHub refuses the feed or the stream drops.
///
/// Only github.com: GitHub Enterprise has no event subscriptions (it is left to polling). Foundation only; the
/// HTTP comes in through `PullRequestEventTransport`, so the tests drive it with canned answers.
enum GitHubPullRequestEvents {
    /// Events only say that something changed; the watch reads the pull request for what.
    static let eventTypes = [
        "com.github.pull_request.review.submitted.v1",
        "com.github.pull_request.head.changed.v1",
        "com.github.pull_request.state.changed.v1",
        "com.github.pull_request.merge_conflict.v1",
    ]
    static let apiOrigin = "https://api.github.com"
    /// GitHub sends a keep-alive at least every 15 seconds while a stream is idle; this long without a byte is dead.
    static let silenceLimit: TimeInterval = 45
    /// A connection open this long was healthy, however it ended.
    static let healthyAfter: TimeInterval = 120
    /// GitHub enables event streams per account, so a refusal holds for a while.
    static let refusedPause: TimeInterval = 3600
    /// Another watch ending may free a slot under the per-account subscription limit.
    static let limitPause: TimeInterval = 600
    static let maxFailures = 6
    static let maxBackoff: TimeInterval = 60
    /// The frame GitHub ends a stream with; its data says whether to reconnect or subscribe again.
    static let endEvent = "github.stream.end"

    /// One pull request on github.com.
    struct Target: Hashable, Sendable {
        let repo: String
        let number: Int

        var resourceURL: String { "https://github.com/\(repo)/pull/\(number)" }

        /// "https://github.com/owner/repo/pull/12"; nil for any other host, GitHub Enterprise included.
        static func parse(_ url: URL) -> Target? {
            let host = (url.host ?? "").lowercased()
            guard url.scheme == "https", host == "github.com" || host == "www.github.com" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
            return Target(repo: parts[0] + "/" + parts[1], number: number)
        }
    }

    /// How a connection ended. `renew`: the subscription expired or lost access, so it is replaced. `nextAccount`: the
    /// stream refused this token where another connected account may still read it.
    enum Ending: Equatable, Sendable {
        case reconnect, renew, nextAccount, stop
    }

    enum Element: Equatable, Sendable {
        case changed
        case ended(Ending)
    }

    struct Subscription: Equatable, Sendable {
        let id: String
        let eventsURL: URL
    }

    static func subscribeBody(_ target: Target) -> [String: Any] {
        ["resource_url": target.resourceURL, "event_types": eventTypes]
    }

    /// The subscription GitHub made. The stream request carries the token, so its URL must stay on GitHub's API.
    static func subscription(_ data: Data) -> Subscription? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = subscriptionID(data),
              let link = object["events_url"] as? String, let url = URL(string: link), origin(url) == apiOrigin else { return nil }
        return Subscription(id: id, eventsURL: url)
    }

    /// The id of a subscription GitHub made, a string or a number.
    static func subscriptionID(_ data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let text = object?["id"] as? String, !text.isEmpty { return text }
        return (object?["id"] as? NSNumber)?.stringValue
    }

    /// "scheme://host[:port]", as a browser names an origin; a default port is left out.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    static func element(_ frame: SSEFrame) -> Element {
        frame.event == endEvent ? .ended(ending(endData: frame.data)) : .changed
    }

    /// `{"outcome": "subscription_ended"}` asks for a new subscription; any other end, or one that does not parse, a
    /// reconnect.
    static func ending(endData: String) -> Ending {
        let object = (try? JSONSerialization.jsonObject(with: Data(endData.utf8))) as? [String: Any]
        return (object?["outcome"] as? String) == "subscription_ended" ? .renew : .reconnect
    }

    /// The wait before reconnecting: doubling from a second up to a minute, with `jitter` (0...1) taking off up to half.
    static func backoff(failures: Int, jitter: Double) -> TimeInterval {
        min(maxBackoff, pow(2, Double(min(failures, 16)))) * (0.5 + max(0, min(1, jitter)) / 2)
    }

    /// Failures in a row after a connection. The first change is the opening; another event or a long life proves the
    /// connection worked, which starts the count over.
    static func failures(changes: Int, lifetime: TimeInterval, before: Int) -> Int {
        changes > 1 || lifetime >= healthyAfter ? 0 : before + 1
    }
}

/// One server-sent event: its type ("message" when the frame names none) and its data lines joined by newlines.
struct SSEFrame: Equatable, Sendable {
    var event: String
    var data: String
}

/// Server-sent events as the HTML standard reads them: fields per line, a blank line dispatches, a line starting with
/// ":" is a comment (GitHub's keep-alives), and a frame without data is dropped. Text may arrive in any chunks.
struct SSEParser: Sendable {
    private var line = String.UnicodeScalarView()
    /// The last chunk ended in "\r", whose "\n" may open the next one.
    private var afterReturn = false
    private var event = ""
    private var data: [String] = []
    private var hasData = false

    /// The frames `text` completes. A line cut off at the end waits for the next chunk. Lines end in "\n", "\r\n" or "\r".
    mutating func feed(_ text: String) -> [SSEFrame] {
        var frames: [SSEFrame] = []
        for scalar in text.unicodeScalars {
            if afterReturn {
                afterReturn = false
                if scalar == "\n" { continue }
            }
            guard scalar == "\n" || scalar == "\r" else {
                line.append(scalar)
                continue
            }
            afterReturn = scalar == "\r"
            if let frame = take(String(line)) { frames.append(frame) }
            line = String.UnicodeScalarView()
        }
        return frames
    }

    /// One whole line; a frame when it was the blank line ending one.
    mutating func take(_ line: String) -> SSEFrame? {
        if line.isEmpty {
            defer { event = ""; data = []; hasData = false }
            guard hasData else { return nil }
            return SSEFrame(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var after = line[line.index(after: colon)...]
            if after.first == " " { after = after.dropFirst() }
            value = after
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data":
            data.append(String(value))
            hasData = true
        default: break
        }
        return nil
    }
}

/// Feeds GitHub will not give for a while: per account host after a refusal (403) or the subscription limit (422), per
/// pull request when no account can see it (404).
struct PullRequestEventPauses: Sendable {
    private var until: [String: Date] = [:]

    func isPaused(host: String, resource: String, at now: Date) -> Bool {
        max(until[host] ?? .distantPast, until[resource] ?? .distantPast) > now
    }

    mutating func refused(status: Int, host: String, resource: String, at now: Date) {
        switch status {
        case 404: until[resource] = now.addingTimeInterval(GitHubPullRequestEvents.refusedPause)
        case 403: until[host] = now.addingTimeInterval(GitHubPullRequestEvents.refusedPause)
        case 422: until[host] = now.addingTimeInterval(GitHubPullRequestEvents.limitPause)
        default: break
        }
    }
}

/// The HTTP of the event feed. The app's sends it with URLSession; the tests answer with canned text.
protocol PullRequestEventTransport: Sendable {
    /// POST /event-subscriptions with `body`: the status and the answer.
    func subscribe(body: Data, token: String) async throws -> (status: Int, body: Data)
    /// DELETE /event-subscriptions/{id}; failures are ignored.
    func unsubscribe(id: String, token: String) async
    /// Opens the stream: its status and its text as it arrives. The stream throws after `silenceLimit` without a byte.
    func connect(_ url: URL, token: String) async throws -> (status: Int, text: AsyncThrowingStream<String, Error>)
}

/// Follows the event feeds of pull requests, sharing what GitHub refused among them.
actor PullRequestEventFollower {
    private let transport: PullRequestEventTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let jitter: @Sendable () -> Double
    private var pauses = PullRequestEventPauses()
    static let host = "github.com"

    init(transport: PullRequestEventTransport, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Calls `changed` when a stream opens (so the reader catches up on what it missed) and on each event, until GitHub
    /// refuses the feed, the stream keeps failing, or the task is cancelled. Each subscription is deleted once its stream
    /// closed, also on cancellation. `tokens` are the connected accounts, primary first.
    func follow(_ target: GitHubPullRequestEvents.Target, tokens: [String], changed: @escaping @Sendable () async -> Void) async {
        guard !tokens.isEmpty else { return }
        while !Task.isCancelled {
            guard let (subscription, index) = await subscribe(target, tokens: tokens) else { return }
            let renew = await stream(subscription, tokens: tokens, from: index, changed: changed)
            // Detached, so a cancelled watch still removes its subscription.
            let transport = transport, token = tokens[index]
            await Task.detached { await transport.unsubscribe(id: subscription.id, token: token) }.value
            guard renew, !Task.isCancelled else { return }
            await sleep(GitHubPullRequestEvents.backoff(failures: 0, jitter: jitter()))
        }
    }

    /// A subscription with the first account GitHub lets see the pull request, and that account's index.
    private func subscribe(_ target: GitHubPullRequestEvents.Target, tokens: [String]) async -> (GitHubPullRequestEvents.Subscription, Int)? {
        let resource = target.resourceURL
        guard !pauses.isPaused(host: Self.host, resource: resource, at: now()) else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: GitHubPullRequestEvents.subscribeBody(target)) else { return nil }
        for (index, token) in tokens.enumerated() {
            guard let answer = try? await transport.subscribe(body: body, token: token) else { return nil }
            if (200..<300).contains(answer.status) {
                if let subscription = GitHubPullRequestEvents.subscription(answer.body) { return (subscription, index) }
                // A stream elsewhere is never opened with the token, but the subscription it made is not left behind.
                if let id = GitHubPullRequestEvents.subscriptionID(answer.body) { await transport.unsubscribe(id: id, token: token) }
                return nil
            }
            // Another account may see a repository this one cannot.
            if answer.status == 404 && index + 1 < tokens.count { continue }
            pauses.refused(status: answer.status, host: Self.host, resource: resource, at: now())
            return nil
        }
        return nil
    }

    /// Connections to one subscription until it ends. True when it needs replacing.
    private func stream(_ subscription: GitHubPullRequestEvents.Subscription, tokens: [String], from first: Int,
                        changed: @escaping @Sendable () async -> Void) async -> Bool {
        var index = first
        var failures = 0
        while !Task.isCancelled {
            let opened = now()
            var changes = 0
            var ending = GitHubPullRequestEvents.Ending.reconnect
            do {
                let (status, text) = try await transport.connect(subscription.eventsURL, token: tokens[index])
                if status == 403 || status == 404 {
                    ending = index + 1 < tokens.count ? .nextAccount : .stop
                } else if status == 200 {
                    changes += 1
                    await changed()
                    var parser = SSEParser()
                    reading: for try await chunk in text {
                        for frame in parser.feed(chunk) {
                            switch GitHubPullRequestEvents.element(frame) {
                            case .changed:
                                changes += 1
                                await changed()
                            case .ended(let end):
                                ending = end
                                break reading
                            }
                        }
                    }
                }
                // A close without GitHub's end frame is reconnected like one with it.
            } catch {
                ending = .reconnect
            }
            if Task.isCancelled { return false }
            switch ending {
            case .stop:
                return false
            case .renew:
                return true
            case .nextAccount:
                index += 1
            case .reconnect:
                failures = GitHubPullRequestEvents.failures(changes: changes, lifetime: now().timeIntervalSince(opened), before: failures)
                if failures > GitHubPullRequestEvents.maxFailures { return false }
                await sleep(GitHubPullRequestEvents.backoff(failures: failures, jitter: jitter()))
            }
        }
        return false
    }
}
