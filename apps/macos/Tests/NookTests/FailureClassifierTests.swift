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

    func testEveryAgentsWayOfSayingItHitALimit() {
        let limited = [
            "[API Error: got status: 429 Too Many Requests. RESOURCE_EXHAUSTED]",
            "Quota exceeded for quota metric 'Generate Content API requests per minute'",
            "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM.",
            "Error: status 429",
            "429",
            "Rate limit exceeded, please retry later",
        ]
        for text in limited {
            guard case .usageLimit = FailureClassifier.classify(FailureEvidence(isError: true, messageText: text)) else {
                return XCTFail("not seen as a limit: \(text)")
            }
        }
        for text in ["Read 4290 lines", "Error: ENOENT /tmp/1429x", "Version 1.429.0 is required"] {
            if case .usageLimit = FailureClassifier.classify(FailureEvidence(isError: true, messageText: text)) {
                XCTFail("a number that only contains 429 is not a limit: \(text)")
            }
        }
        if case .usageLimit = FailureClassifier.classify(FailureEvidence(isError: false, messageText: "You hit your usage limit")) {
            XCTFail("assistant text is never read as a failure")
        }
    }

    func testAntigravityLimitReplyIsALimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reply = "Usage Limit Reached\n\nYou have reached your current quota for this period. Your limit will reset in 4 hours, 23 minutes."
        let limit = FailureClassifier.limitReply(reply, now: now)
        XCTAssertEqual(limit?.resetAt, now.addingTimeInterval(4 * 3_600 + 23 * 60))
        XCTAssertNil(FailureClassifier.limitReply("Done. I fixed the usage limit card.", now: now))
        let long = String(repeating: "The usage limit reached code path now works. ", count: 20)
        XCTAssertNil(FailureClassifier.limitReply(long, now: now), "a long answer that mentions a limit is an answer")
        XCTAssertNil(FailureClassifier.limitReply("", now: now))
    }

    func testSavedTurnThatEndedOnALimitReplyIsALimit() {
        let ended = Date(timeIntervalSince1970: 1_800_000_000)
        let notice = "Usage Limit Reached\n\nYou have reached your current quota for this period. Your limit will reset in 3 hours, 56 minutes."
        let turn = [
            RunEvent(kind: .user, text: "Continue where you left off.", date: ended.addingTimeInterval(-6)),
            RunEvent(kind: .assistant, text: "Let me look at the icons first."),
            RunEvent(kind: .tool, text: "Running view_file", state: .failed),
            RunEvent(kind: .assistant, text: notice, state: .done),
            RunEvent(kind: .result, text: "6s", state: .done, date: ended),
        ]
        let found = FailureClassifier.endedOnLimitReply(turn)
        XCTAssertEqual(found?.at, ended)
        XCTAssertEqual(found?.reply.resetAt, ended.addingTimeInterval(3 * 3_600 + 56 * 60), "the reset counts from the turn's end")

        // Already noted as a limit, a failed turn, a turn still open, or another answer: nothing to do.
        var noted = turn
        noted.insert(RunEvent(kind: .system, text: "Waits for the limit", tool: "limit"), at: 4)
        XCTAssertNil(FailureClassifier.endedOnLimitReply(noted))
        var failed = turn
        failed[4].state = .failed
        XCTAssertNil(FailureClassifier.endedOnLimitReply(failed))
        XCTAssertNil(FailureClassifier.endedOnLimitReply(turn + [RunEvent(kind: .user, text: "And now?")]))
        var answered = turn
        answered[3].text = "Done: the icons are fixed."
        XCTAssertNil(FailureClassifier.endedOnLimitReply(answered))
        // Only the words after the last tool call count: an earlier limit notice in the turn is not the reply.
        let earlier = [turn[0], RunEvent(kind: .assistant, text: notice), RunEvent(kind: .tool, text: "Running view_file"),
                       RunEvent(kind: .assistant, text: "All done."), turn[4]]
        XCTAssertNil(FailureClassifier.endedOnLimitReply(earlier))
        XCTAssertNil(FailureClassifier.endedOnLimitReply([]))
    }
}
