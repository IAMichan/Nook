import XCTest

final class FailureClassifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func classify(_ e: FailureEvidence) -> FailureClass { FailureClassifier.classify(e) }

    func testAbortedTerminalReasonIsInterruptedEvenWhenSuccess() {
        for reason in ["aborted_tools", "aborted_streaming"] {
            let e = FailureEvidence(resultSubtype: "success", terminalReason: reason, now: now)
            XCTAssertEqual(classify(e), .interrupted)
            XCTAssertFalse(FailureClassifier.isFailure(e))
        }
    }

    func testTerminalReasonBeatsStatus() {
        let e = FailureEvidence(terminalReason: "aborted_tools", apiErrorStatus: 429, isError: true)
        XCTAssertEqual(classify(e), .interrupted)
    }

    func testBlockingLimitUsesStreamedReset() {
        let r1 = now.addingTimeInterval(100), r2 = now.addingTimeInterval(500)
        let e = FailureEvidence(terminalReason: "blocking_limit", rateLimitResets: ["five_hour": r1, "seven_day": r2], now: now)
        XCTAssertEqual(classify(e), .usageLimit(resetAt: r2))
    }

    func testStatus429IsUsageLimitWith529AsNetworkAnd401403() {
        XCTAssertEqual(classify(FailureEvidence(apiErrorStatus: 429, isError: true)), .usageLimit(resetAt: nil))
        XCTAssertEqual(classify(FailureEvidence(apiErrorStatus: 529, isError: true)), .network)
        XCTAssertEqual(classify(FailureEvidence(apiErrorStatus: 401, isError: true)), .authentication)
        XCTAssertEqual(classify(FailureEvidence(apiErrorStatus: 403, isError: true, messageText: "Forbidden")), .forbidden)
    }

    func testRejectedRateLimitResetIsLatestOnlyWhenAllKnown() {
        let r1 = now.addingTimeInterval(100), r2 = now.addingTimeInterval(500)
        var e = FailureEvidence(isError: true, rateLimitRejected: true, rateLimitResets: ["a": r1, "b": r2], now: now)
        XCTAssertEqual(classify(e), .usageLimit(resetAt: r2))
        e.rateLimitResets = ["a": r1, "b": Date?.none]
        XCTAssertEqual(classify(e), .usageLimit(resetAt: nil))
        e.rateLimitResets = [:]
        XCTAssertEqual(classify(e), .usageLimit(resetAt: nil))
    }

    func testGatewayTextParsesResetAfter() {
        let text = #"API Error: 503 [req] [429]: {"type":"error","error":{"type":"rate_limit_error","message":"x"}} (reset after 1h2m3s)"#
        let e = FailureEvidence(terminalReason: "api_error", apiErrorStatus: 503, isError: true, messageText: text, now: now)
        XCTAssertEqual(classify(e), .usageLimit(resetAt: now.addingTimeInterval(3723)))
        XCTAssertEqual(FailureClassifier.gatewayResetSeconds("(reset after 45s)"), 45)
        XCTAssertEqual(FailureClassifier.gatewayResetSeconds("(reset after 2m)"), 120)
        XCTAssertNil(FailureClassifier.gatewayResetSeconds("no hint"))
        let zero = FailureEvidence(isError: true, messageText: "[429] rate_limit_error (reset after )", now: now)
        XCTAssertEqual(classify(zero), .usageLimit(resetAt: nil))
    }

    func testTextRules() {
        func c(_ t: String) -> FailureClass { classify(FailureEvidence(isError: true, messageText: t, now: now)) }
        XCTAssertEqual(c("API Error [429] rate_limit_error"), .usageLimit(resetAt: nil))
        XCTAssertEqual(c("Invalid API key. Please run /login"), .authentication)
        XCTAssertEqual(c("authentication_failed"), .authentication)
        XCTAssertEqual(c("fetch failed: ENOTFOUND"), .network)
        XCTAssertEqual(c("something odd"), .generic)
    }

    func testAssistantTextAboutNetworkIsNotAFailure() {
        let e = FailureEvidence(resultSubtype: "success", messageText: "fix the network error handling", now: now)
        XCTAssertEqual(classify(e), .generic)
        XCTAssertFalse(FailureClassifier.isFailure(e))
    }

    func testIsFailure() {
        XCTAssertTrue(FailureClassifier.isFailure(FailureEvidence(isError: true)))
        XCTAssertTrue(FailureClassifier.isFailure(FailureEvidence(resultSubtype: "error_during_execution")))
        XCTAssertTrue(FailureClassifier.isFailure(FailureEvidence(resultSubtype: "success", apiErrorStatus: 429)))
        XCTAssertFalse(FailureClassifier.isFailure(FailureEvidence(resultSubtype: "success")))
    }

    func testCompactionStoppedByLimitStillFails() {
        let e = FailureEvidence(resultSubtype: "success", rateLimitRejected: true, isCompaction: true)
        XCTAssertTrue(FailureClassifier.isFailure(e))
        let plain = FailureEvidence(resultSubtype: "success", messageText: "compacted", isCompaction: true)
        XCTAssertTrue(FailureClassifier.isFailure(plain))
    }
}
