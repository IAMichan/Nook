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

    func testClaudePlanReading() {
        let reading = UsageLimits.planReading(["rateLimitType": "seven_day", "utilization": 0.25, "resetsAt": 1_700_000_000])
        XCTAssertEqual(reading, UsageLimits.PlanReading(window: "seven_day", usedPercent: 25, resetsAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertNil(UsageLimits.planReading(["rateLimitType": "seven_day_opus", "utilization": 0.25, "resetsAt": 1]),
                     "only the windows the status line shows")
        XCTAssertNil(UsageLimits.planReading(["status": "allowed", "resetsAt": 1]), "no utilization: nothing to show")
    }

    func testClaudeUsageReply() {
        let reply: [String: Any] = [
            "subscription_type": "max",
            "rate_limits_available": true,
            "rate_limits": [
                "five_hour": ["utilization": 34.0, "resets_at": "2026-10-20T15:00:00.123+00:00"] as [String: Any],
                "seven_day": ["utilization": 12, "resets_at": "2026-10-24T09:00:00Z"] as [String: Any],
                "seven_day_opus": ["utilization": 80, "resets_at": "2026-10-24T09:00:00Z"] as [String: Any]
            ] as [String: Any]
        ]
        let readings = UsageLimits.claudeUsageReply(reply)
        XCTAssertEqual(readings?.map(\.window), ["five_hour", "seven_day"], "only the windows the status line shows")
        XCTAssertEqual(readings?.first?.usedPercent, 34, "utilization is already a percentage")
        XCTAssertEqual(readings?.first?.resetsAt.timeIntervalSince1970 ?? 0, 1_792_508_400.123, accuracy: 0.01)
        XCTAssertEqual(readings?.last?.resetsAt, Date(timeIntervalSince1970: 1_792_832_400))

        let week: [String: Any] = ["utilization": 5, "resets_at": "2026-10-24T09:00:00Z"]
        let idle = UsageLimits.claudeUsageReply(["rate_limits": ["five_hour": NSNull(), "seven_day": week] as [String: Any]])
        XCTAssertEqual(idle?.map(\.window), ["seven_day"], "a window that has not started is left out")
        XCTAssertNil(UsageLimits.claudeUsageReply(["rate_limits_available": false, "rate_limits": NSNull()]), "API key: no plan limits")
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
