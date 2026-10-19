import XCTest

/// A turn stopped by a usage limit: when the limit resets, so the session can go on then.
final class UsageLimitTests: XCTestCase {
    func testClaudeRateLimitEvent() {
        let rejected = UsageLimits.claudeEvent(["status": "rejected", "rateLimitType": "seven_day", "resetsAt": 1_700_000_000])
        XCTAssertEqual(rejected, UsageLimits.ClaudeEvent(window: "seven_day", blocked: true, resetsAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(UsageLimits.claudeEvent(["status": "rejected", "overageStatus": "allowed"])?.blocked, false,
                       "extra usage takes over: the turn is not blocked")
        XCTAssertEqual(UsageLimits.claudeEvent(["status": "rejected", "isUsingOverage": true])?.blocked, false)
        XCTAssertEqual(UsageLimits.claudeEvent(["status": "allowed_warning"])?.blocked, false)
        XCTAssertNil(UsageLimits.claudeEvent([:]))
    }

    func testLatestReset() {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        let known: [String: Date?] = ["five_hour": early, "seven_day": late]
        let partly: [String: Date?] = ["five_hour": early, "seven_day": Date?.none]
        XCTAssertEqual(UsageLimits.latestReset(known), late, "every blocked window must have reset")
        XCTAssertNil(UsageLimits.latestReset(partly), "one unknown reset: unknown")
        XCTAssertNil(UsageLimits.latestReset([:]))
    }

    func testClaudeResultSaysLimit() {
        guard case .result(let result)? = ClaudeStreamParser.parse(#"{"type":"result","subtype":"success","is_error":true,"result":"limit","api_error_status":429,"terminal_reason":"blocking_limit"}"#).first
        else { return XCTFail("no result") }
        XCTAssertEqual(result.apiErrorStatus, 429)
        XCTAssertEqual(result.terminalReason, "blocking_limit")
    }

    func testCodexUsageLimit() {
        XCTAssertTrue(UsageLimits.isCodexUsageLimit("usageLimitExceeded"))
        XCTAssertTrue(UsageLimits.isCodexUsageLimit(["rateLimitExceeded": [:]]))
        XCTAssertFalse(UsageLimits.isCodexUsageLimit(["httpConnectionFailed": ["httpStatusCode": 502]]))
        XCTAssertFalse(UsageLimits.isCodexUsageLimit(nil))

        let completed = #"{"method":"turn/completed","params":{"turn":{"id":"t","status":"failed","error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}}"#
        guard let message = CodexRPC.parse(completed) else { return XCTFail("not parsed") }
        XCTAssertEqual(CodexAppServerMapper.events(message).first, .usageLimited)
    }

    func testCodexResetFromSnapshot() {
        let params: [String: Any] = ["rateLimits": ["limitId": "codex",
                                                    "primary": ["usedPercent": 100, "resetsAt": 1_700_000_000],
                                                    "secondary": ["usedPercent": 40, "resetsAt": 1_800_000_000]]]
        XCTAssertEqual(UsageLimits.codexReset(params), Date(timeIntervalSince1970: 1_700_000_000), "only the full window counts")
        XCTAssertNil(UsageLimits.codexReset(["rateLimits": ["primary": ["usedPercent": 100]]]), "full but no reset time: unknown")
        XCTAssertNil(UsageLimits.codexReset(["rateLimits": ["primary": ["usedPercent": 30, "resetsAt": 1]]]))
        XCTAssertNil(UsageLimits.codexReset(["rateLimits": ["limitId": "spark", "primary": ["usedPercent": 100, "resetsAt": 1]]]))
    }
}
