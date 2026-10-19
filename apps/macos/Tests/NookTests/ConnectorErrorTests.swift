import XCTest

/// The kind of failure decides which way out the UI offers: reconnect for credentials, retry for the network.
final class ConnectorErrorTests: XCTestCase {
    func testHTTPStatusesMapToKinds() {
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 401), .auth)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 403), .auth)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 404), .config)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 429), .rateLimited)
        XCTAssertEqual(ConnectorErrorKind.forHTTP(status: 500), .other)
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
