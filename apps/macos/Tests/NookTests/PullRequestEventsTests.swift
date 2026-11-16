import Foundation
import XCTest

final class PullRequestEventsTests: XCTestCase {
    private let target = GitHubPullRequestEvents.Target(repo: "octocat/hello-world", number: 15)

    private static func sse(_ frames: [(String, String)]) -> String {
        frames.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    }

    private static func subscription(_ id: Int, host: String = "api.github.com") -> Data {
        Data(#"{"id": \#(id), "events_url": "https://\#(host)/event-subscriptions/\#(id)/events"}"#.utf8)
    }

    // MARK: Parsing

    func testTheParserReadsFramesCommentsAndLineEndings() {
        var parser = SSEParser()
        let text = ": keep-alive\n\nevent: com.github.pull_request.head.changed.v1\ndata: {\"a\":1}\n\n"
            + "data: first\r\ndata:second\r\n\r\n" + "event: github.stream.end\rdata: {\"outcome\":\"reconnect\"}\r\r"
        XCTAssertEqual(parser.feed(text), [
            SSEFrame(event: "com.github.pull_request.head.changed.v1", data: #"{"a":1}"#),
            SSEFrame(event: "message", data: "first\nsecond"),
            SSEFrame(event: "github.stream.end", data: #"{"outcome":"reconnect"}"#),
        ], "a comment or a frame without data dispatches nothing")
    }

    func testTheParserWaitsForWholeLinesAcrossChunks() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("event: github.str"), [])
        XCTAssertEqual(parser.feed("eam.end\r"), [])
        XCTAssertEqual(parser.feed("\ndata: {}\r"), [])
        XCTAssertEqual(parser.feed("\n\r\n"), [SSEFrame(event: "github.stream.end", data: "{}")],
                       "a \\r\\n split over two chunks is one line break")
        XCTAssertEqual(parser.feed("event: x\n"), [])
        XCTAssertEqual(parser.feed("\n"), [], "a frame without data is dropped, and its type does not carry over")
        XCTAssertEqual(parser.feed("data: y\n\n"), [SSEFrame(event: "message", data: "y")])
    }

    func testFramesAreChangesUntilGitHubEndsTheStream() {
        XCTAssertEqual(GitHubPullRequestEvents.element(SSEFrame(event: "com.github.pull_request.review.submitted.v1", data: "{}")), .changed)
        XCTAssertEqual(GitHubPullRequestEvents.element(SSEFrame(event: "github.stream.end", data: #"{"outcome":"subscription_ended","reason":"expired"}"#)),
                       .ended(.renew))
        XCTAssertEqual(GitHubPullRequestEvents.element(SSEFrame(event: "github.stream.end", data: #"{"outcome":"reconnect"}"#)), .ended(.reconnect))
        XCTAssertEqual(GitHubPullRequestEvents.ending(endData: "not json"), .reconnect)
    }

    func testOnlyGitHubsAPIMayReceiveTheToken() {
        XCTAssertEqual(GitHubPullRequestEvents.subscription(Self.subscription(7)),
                       .init(id: "7", eventsURL: URL(string: "https://api.github.com/event-subscriptions/7/events")!))
        XCTAssertEqual(GitHubPullRequestEvents.subscription(Data(#"{"id":"abc","events_url":"https://api.github.com:443/s/abc"}"#.utf8))?.id, "abc")
        XCTAssertNil(GitHubPullRequestEvents.subscription(Self.subscription(7, host: "evil.example")))
        XCTAssertNil(GitHubPullRequestEvents.subscription(Self.subscription(7, host: "api.github.com.evil.example")))
        XCTAssertNil(GitHubPullRequestEvents.subscription(Data(#"{"id":7,"events_url":"http://api.github.com/s"}"#.utf8)))
        XCTAssertNil(GitHubPullRequestEvents.subscription(Data(#"{"id":7,"events_url":"https://api.github.com:8443/s"}"#.utf8)))
        XCTAssertNil(GitHubPullRequestEvents.subscription(Data(#"{"events_url":"https://api.github.com/s"}"#.utf8)))
    }

    func testOnlyPullRequestsOnGitHubDotComHaveAFeed() {
        XCTAssertEqual(GitHubPullRequestEvents.Target.parse(URL(string: "https://github.com/octocat/hello-world/pull/15")!), target)
        XCTAssertEqual(target.resourceURL, "https://github.com/octocat/hello-world/pull/15")
        XCTAssertNil(GitHubPullRequestEvents.Target.parse(URL(string: "https://ghe.example.com/a/b/pull/1")!), "GitHub Enterprise polls")
        XCTAssertNil(GitHubPullRequestEvents.Target.parse(URL(string: "https://gitlab.com/a/b/-/merge_requests/1")!))
        XCTAssertNil(GitHubPullRequestEvents.Target.parse(URL(string: "https://github.com/a/b/issues/1")!))
        let body = GitHubPullRequestEvents.subscribeBody(target)
        XCTAssertEqual(body["resource_url"] as? String, "https://github.com/octocat/hello-world/pull/15")
        XCTAssertEqual(body["event_types"] as? [String], [
            "com.github.pull_request.review.submitted.v1", "com.github.pull_request.head.changed.v1",
            "com.github.pull_request.state.changed.v1", "com.github.pull_request.merge_conflict.v1",
        ])
    }

    func testBackoffAndHealth() {
        XCTAssertEqual(GitHubPullRequestEvents.backoff(failures: 0, jitter: 1), 1)
        XCTAssertEqual(GitHubPullRequestEvents.backoff(failures: 3, jitter: 1), 8)
        XCTAssertEqual(GitHubPullRequestEvents.backoff(failures: 3, jitter: 0), 4)
        XCTAssertEqual(GitHubPullRequestEvents.backoff(failures: 30, jitter: 1), 60)
        XCTAssertEqual(GitHubPullRequestEvents.failures(changes: 1, lifetime: 5, before: 2), 3, "only the opening: a failure")
        XCTAssertEqual(GitHubPullRequestEvents.failures(changes: 2, lifetime: 5, before: 2), 0, "an event proves it worked")
        XCTAssertEqual(GitHubPullRequestEvents.failures(changes: 1, lifetime: 120, before: 2), 0, "so does a long life")
    }

    func testPausesFollowTheRefusal() {
        var pauses = PullRequestEventPauses()
        let now = Date(timeIntervalSince1970: 1000)
        let resource = target.resourceURL
        pauses.refused(status: 404, host: "github.com", resource: resource, at: now)
        XCTAssertTrue(pauses.isPaused(host: "github.com", resource: resource, at: now.addingTimeInterval(3599)))
        XCTAssertFalse(pauses.isPaused(host: "github.com", resource: resource + "6", at: now), "a 404 holds only that pull request")
        XCTAssertFalse(pauses.isPaused(host: "github.com", resource: resource, at: now.addingTimeInterval(3601)))
        pauses.refused(status: 422, host: "github.com", resource: resource, at: now)
        XCTAssertTrue(pauses.isPaused(host: "github.com", resource: "other", at: now.addingTimeInterval(599)))
        XCTAssertFalse(pauses.isPaused(host: "github.com", resource: "other", at: now.addingTimeInterval(601)))
        pauses.refused(status: 403, host: "github.com", resource: resource, at: now)
        XCTAssertTrue(pauses.isPaused(host: "github.com", resource: "other", at: now.addingTimeInterval(3599)))
        var other = PullRequestEventPauses()
        other.refused(status: 500, host: "github.com", resource: resource, at: now)
        XCTAssertFalse(other.isPaused(host: "github.com", resource: resource, at: now))
    }

    // MARK: Following

    func testAFeedMovesToAnotherAccountReconnectsAndRenews() async {
        let transport = FakeTransport(subscribe: { count, _ in (201, Self.subscription(count)) }, connections: [
            // The first account cannot read the stream; the second can.
            .status(404),
            .text(Self.sse([("com.github.pull_request.head.changed.v1", "{}"), ("github.stream.end", #"{"outcome":"reconnect","reason":"shutdown"}"#)])),
            .text(Self.sse([("github.stream.end", #"{"outcome":"subscription_ended","reason":"expired"}"#)])),
            .status(403),
            .status(403),
        ])
        let clock = FakeClock()
        let follower = PullRequestEventFollower(transport: transport, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        let changes = Counter()
        await follower.follow(target, tokens: ["a", "b"]) { changes.add() }

        XCTAssertEqual(changes.value, 3, "an opening per connection that answered, plus the head change")
        XCTAssertEqual(transport.connections, [
            "https://api.github.com/event-subscriptions/1/events a",
            "https://api.github.com/event-subscriptions/1/events b",
            "https://api.github.com/event-subscriptions/1/events b",
            "https://api.github.com/event-subscriptions/2/events a",
            "https://api.github.com/event-subscriptions/2/events b",
        ])
        XCTAssertEqual(transport.posts.count, 2)
        XCTAssertEqual(transport.posts.first?["resource_url"] as? String, "https://github.com/octocat/hello-world/pull/15")
        XCTAssertEqual(transport.deletes, ["1 a", "2 a"], "each subscription is deleted with the account that made it")
    }

    func testASilentStreamGivesUpAfterSixFailuresInARow() async {
        let transport = FakeTransport(subscribe: { count, _ in (201, Self.subscription(count)) },
                                      connections: Array(repeating: .silent, count: 10))
        let clock = FakeClock()
        let follower = PullRequestEventFollower(transport: transport, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        let changes = Counter()
        await follower.follow(target, tokens: ["a"]) { changes.add() }

        XCTAssertEqual(changes.value, 7, "one catch-up read per connection")
        XCTAssertEqual(transport.connections.count, 7)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(transport.deletes, ["1 a"])
        XCTAssertEqual(clock.slept, [2, 4, 8, 16, 32, 60])
    }

    func testRefusalsLeaveTheWatchToPolling() async {
        let refused = FakeTransport(subscribe: { _, _ in (403, Data()) }, connections: [])
        let clock = FakeClock()
        let follower = PullRequestEventFollower(transport: refused, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        await follower.follow(target, tokens: ["a"]) {}
        await follower.follow(GitHubPullRequestEvents.Target(repo: "octocat/hello-world", number: 16), tokens: ["a"]) {}
        XCTAssertEqual(refused.posts.count, 1, "a refused account is not asked again for an hour")
        clock.advance(61 * 60)
        await follower.follow(target, tokens: ["a"]) {}
        XCTAssertEqual(refused.posts.count, 2)
        XCTAssertTrue(refused.connections.isEmpty)

        let missing = FakeTransport(subscribe: { _, _ in (404, Data()) }, connections: [])
        let missingFollower = PullRequestEventFollower(transport: missing, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        await missingFollower.follow(target, tokens: ["a", "b"]) {}
        XCTAssertEqual(missing.posts.count, 2, "every account is asked before a pull request counts as unseen")
        await missingFollower.follow(target, tokens: ["a", "b"]) {}
        XCTAssertEqual(missing.posts.count, 2, "a pull request no account can see is not asked again")
        await missingFollower.follow(GitHubPullRequestEvents.Target(repo: "octocat/hello-world", number: 16), tokens: ["a"]) {}
        XCTAssertEqual(missing.posts.count, 3, "other pull requests on the host still subscribe")

        let full = FakeTransport(subscribe: { _, _ in (422, Data()) }, connections: [])
        let fullFollower = PullRequestEventFollower(transport: full, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        await fullFollower.follow(target, tokens: ["a"]) {}
        clock.advance(9 * 60)
        await fullFollower.follow(target, tokens: ["a"]) {}
        XCTAssertEqual(full.posts.count, 1, "at the subscription limit the host waits ten minutes")
        clock.advance(2 * 60)
        await fullFollower.follow(target, tokens: ["a"]) {}
        XCTAssertEqual(full.posts.count, 2)
    }

    func testAStreamElsewhereIsNeverOpenedButItsSubscriptionIsDeleted() async {
        let transport = FakeTransport(subscribe: { _, _ in (201, Self.subscription(9, host: "evil.example")) }, connections: [.status(200)])
        let clock = FakeClock()
        let follower = PullRequestEventFollower(transport: transport, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        await follower.follow(target, tokens: ["a"]) {}
        XCTAssertTrue(transport.connections.isEmpty)
        XCTAssertEqual(transport.deletes, ["9 a"])
    }

    func testStoppingAWatchDeletesItsSubscription() async throws {
        let transport = FakeTransport(subscribe: { count, _ in (201, Self.subscription(count)) }, connections: [.open])
        let clock = FakeClock()
        let follower = PullRequestEventFollower(transport: transport, now: clock.now, sleep: clock.sleep, jitter: { 1 })
        let changes = Counter()
        let task = Task { await follower.follow(target, tokens: ["a"]) { changes.add() } }
        for _ in 0..<200 where changes.value == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(changes.value, 1, "the opening")
        task.cancel()
        await task.value
        XCTAssertEqual(transport.deletes, ["1 a"])
        XCTAssertEqual(transport.connections.count, 1, "a cancelled feed does not reconnect")
    }
}

// MARK: Fakes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

/// Time that moves only when the follower sleeps or a test advances it.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var sleeps: [TimeInterval] = []

    var slept: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return sleeps }
    var now: @Sendable () -> Date { { [self] in lock.lock(); defer { lock.unlock() }; return current } }
    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            lock.lock()
            sleeps.append(seconds)
            current += seconds
            lock.unlock()
        }
    }

    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class FakeTransport: PullRequestEventTransport, @unchecked Sendable {
    enum Connection {
        case status(Int)
        /// A 200 whose whole stream is this text, then the connection closes.
        case text(String)
        /// A 200 that sends nothing until the silence limit ends it.
        case silent
        /// A 200 that stays open until the reader goes away.
        case open
    }

    private let lock = NSLock()
    private let answer: (Int, String) -> (Int, Data)
    private var queue: [Connection]
    private var postBodies: [[String: Any]] = []
    private var made: [String] = []
    private var deleted: [String] = []
    /// Open streams stay open while their continuation lives.
    private var held: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(subscribe: @escaping (Int, String) -> (Int, Data), connections: [Connection]) {
        answer = subscribe
        queue = connections
    }

    var posts: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return postBodies }
    var connections: [String] { lock.lock(); defer { lock.unlock() }; return made }
    var deletes: [String] { lock.lock(); defer { lock.unlock() }; return deleted }

    func subscribe(body: Data, token: String) async throws -> (status: Int, body: Data) {
        lock.lock()
        postBodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        let count = postBodies.count
        lock.unlock()
        return answer(count, token)
    }

    func unsubscribe(id: String, token: String) async {
        lock.lock()
        deleted.append(id + " " + token)
        lock.unlock()
    }

    func connect(_ url: URL, token: String) async throws -> (status: Int, text: AsyncThrowingStream<String, Error>) {
        lock.lock()
        made.append(url.absoluteString + " " + token)
        let next = queue.isEmpty ? Connection.status(403) : queue.removeFirst()
        lock.unlock()
        switch next {
        case .status(let status):
            return (status, AsyncThrowingStream { $0.finish() })
        case .text(let text):
            // In small pieces, as a network delivers it.
            let pieces = stride(from: 0, to: text.count, by: 7).map { start -> String in
                let from = text.index(text.startIndex, offsetBy: start)
                return String(text[from..<(text.index(from, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex)])
            }
            return (200, AsyncThrowingStream { continuation in
                for piece in pieces { continuation.yield(piece) }
                continuation.finish()
            })
        case .silent:
            return (200, AsyncThrowingStream { $0.finish(throwing: URLError(.timedOut)) })
        case .open:
            return (200, AsyncThrowingStream { continuation in
                lock.lock()
                held.append(continuation)
                lock.unlock()
            })
        }
    }
}
