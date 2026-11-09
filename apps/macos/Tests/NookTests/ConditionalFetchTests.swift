import XCTest

/// Answers with what each test lines up, and records what was asked.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [(status: Int, headers: [String: String], body: Data)] = []
    nonisolated(unsafe) static var asked: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.asked.append(request)
        let answer = Self.answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ConditionalFetchTests: XCTestCase {
    private var session: URLSession!
    private let url = URL(string: "https://api.github.com/repos/a/b/pulls/1")!

    override func setUp() {
        StubProtocol.answers = []
        StubProtocol.asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private func request(token: String = "one") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func status(_ response: URLResponse) -> Int? { (response as? HTTPURLResponse)?.statusCode }

    func testAnUnchangedAnswerComesBackWhole() async throws {
        let cache = ConditionalCache()
        StubProtocol.answers = [(200, ["ETag": "W/\"a\""], Data("first".utf8)), (304, [:], Data())]
        let first = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertNil(StubProtocol.asked[0].value(forHTTPHeaderField: "If-None-Match"))
        let second = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertEqual(StubProtocol.asked[1].value(forHTTPHeaderField: "If-None-Match"), "W/\"a\"")
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(status(second.1), 200, "callers see an ordinary answer")
    }

    func testAChangedAnswerReplacesTheKeptOne() async throws {
        let cache = ConditionalCache()
        StubProtocol.answers = [(200, ["ETag": "\"a\""], Data("old".utf8)), (200, ["ETag": "\"b\""], Data("new".utf8)), (304, [:], Data())]
        _ = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        let changed = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertEqual(changed.0, Data("new".utf8))
        let again = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertEqual(StubProtocol.asked[2].value(forHTTPHeaderField: "If-None-Match"), "\"b\"")
        XCTAssertEqual(again.0, Data("new".utf8))
    }

    func testAnAccountNeverGetsTheAnswerOfAnother() async throws {
        let cache = ConditionalCache()
        StubProtocol.answers = [(200, ["ETag": "\"a\""], Data("mine".utf8)), (200, [:], Data("theirs".utf8))]
        _ = try await ConditionalFetch.data(for: request(token: "one"), session: session, cache: cache)
        let other = try await ConditionalFetch.data(for: request(token: "two"), session: session, cache: cache)
        XCTAssertNil(StubProtocol.asked[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(other.0, Data("theirs".utf8))
    }

    func testARefusalIsPassedOnAndForgetsTheAnswer() async throws {
        let cache = ConditionalCache()
        StubProtocol.answers = [(200, ["ETag": "\"a\""], Data("x".utf8)), (403, [:], Data("no".utf8)), (200, [:], Data("y".utf8))]
        _ = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        let refused = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertEqual(status(refused.1), 403)
        _ = try await ConditionalFetch.data(for: request(), session: session, cache: cache)
        XCTAssertNil(StubProtocol.asked[2].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testOnlyReadsAreConditional() async throws {
        let cache = ConditionalCache()
        var post = request()
        post.httpMethod = "POST"
        StubProtocol.answers = [(200, ["ETag": "\"a\""], Data("x".utf8)), (200, [:], Data("y".utf8))]
        _ = try await ConditionalFetch.data(for: post, session: session, cache: cache)
        _ = try await ConditionalFetch.data(for: post, session: session, cache: cache)
        XCTAssertNil(StubProtocol.asked[1].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testTheCacheStaysWithinItsLimits() {
        let cache = ConditionalCache(byteLimit: 10, bodyLimit: 6)
        cache.store("a", etag: "1", body: Data(count: 6))
        cache.store("b", etag: "2", body: Data(count: 4))
        XCTAssertNotNil(cache.entry("a"), "used last, so it stays")
        cache.store("c", etag: "3", body: Data(count: 4))
        XCTAssertNil(cache.entry("b"))
        XCTAssertNotNil(cache.entry("a"))
        cache.store("d", etag: "4", body: Data(count: 7))
        XCTAssertNil(cache.entry("d"), "too large to keep")
        XCTAssertLessThanOrEqual(cache.size, 10)
    }

    func testMemoryPressureEmptiesTheCache() {
        let cache = ConditionalCache()
        cache.store("a", etag: "1", body: Data(count: 100))
        XCTAssertEqual(cache.size, 100)
        cache.removeAll()
        XCTAssertNil(cache.entry("a"))
        XCTAssertEqual(cache.size, 0)
    }
}
