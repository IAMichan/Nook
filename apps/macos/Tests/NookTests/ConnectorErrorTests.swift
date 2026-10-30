import XCTest

/// The kind of failure decides which way out the UI offers: reconnect for credentials, retry for the network.
final class ConnectorErrorTests: XCTestCase {
    func testHTTPStatusesMapToKinds() {
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 401), .auth)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 403), .auth)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 404), .config)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 429), .rateLimited)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 500), .other)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 502), .network)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 504), .network)
    }

    func testRetryAsksAgainAfterAPassingFailure() async throws {
        var calls = 0
        let value = try await ConnectorRetry.run(delay: 0) { () async throws -> Int in
            calls += 1
            if calls < 3 { throw URLError(.timedOut) }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(calls, 3)
    }

    func testRetryGivesUpAfterTheLastAttempt() async {
        var calls = 0
        do {
            _ = try await ConnectorRetry.run(attempts: 2, delay: 0) { () async throws -> Int in
                calls += 1
                throw NookError("busy", kind: .network)
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(calls, 2)
        }
    }

    func testRetryDoesNotRepeatRejectedCredentials() async {
        var calls = 0
        do {
            _ = try await ConnectorRetry.run(delay: 0) { () async throws -> Int in
                calls += 1
                throw NookError("nope", kind: .auth)
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(calls, 1)
        }
        XCTAssertFalse(ConnectorRetry.isTransient(URLError(.cancelled)))
        XCTAssertFalse(ConnectorRetry.isTransient(CancellationError()))
        XCTAssertTrue(ConnectorRetry.isTransient(URLError(.networkConnectionLost)))
    }

    func testClassifyUsesTheKindOfANookError() {
        XCTAssertEqual(ConnectorErrorKind.classify(NookError("nope", kind: .auth)), .auth)
        XCTAssertEqual(ConnectorErrorKind.classify(NookError("plain")), .other)
        XCTAssertEqual(ConnectorErrorKind.classify(URLError(.notConnectedToInternet)), .network)
    }

    func testRecoveryActions() {
        XCTAssertTrue(ConnectorErrorKind.auth.needsReconnect)
        XCTAssertTrue(ConnectorErrorKind.config.needsReconnect)
        XCTAssertFalse(ConnectorErrorKind.network.needsReconnect)
        XCTAssertTrue(ConnectorErrorKind.network.canRetry)
        XCTAssertTrue(ConnectorErrorKind.rateLimited.canRetry)
        XCTAssertFalse(ConnectorErrorKind.auth.canRetry)
    }
}

/// GitHub answers a renamed repository's old name with a redirect; the credentials must follow it on the same host only.
final class RedirectCredentialsTests: XCTestCase {
    private func request(_ url: String, auth: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        return request
    }

    func testRenamedRepositoryKeepsItsToken() {
        let original = request("https://api.github.com/repos/owner/old/pulls?head=owner:topic", auth: "Bearer t")
        let kept = RedirectCredentials.follow(original, to: request("https://api.github.com/repositories/42/pulls?head=owner:topic"))
        XCTAssertEqual(kept.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testAnotherHostGetsNoToken() {
        let original = request("https://api.github.com/repos/owner/repo/zipball", auth: "Bearer t")
        let next = RedirectCredentials.follow(original, to: request("https://codeload.github.com/owner/repo/zip"))
        XCTAssertNil(next.value(forHTTPHeaderField: "Authorization"))
        let downgraded = RedirectCredentials.follow(original, to: request("http://api.github.com/repositories/42"))
        XCTAssertNil(downgraded.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestWithoutTokenStaysAsIs() {
        let next = RedirectCredentials.follow(request("https://api.github.com/a"), to: request("https://api.github.com/b"))
        XCTAssertNil(next.value(forHTTPHeaderField: "Authorization"))
    }
}
