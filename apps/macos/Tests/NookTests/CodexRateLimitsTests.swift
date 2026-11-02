import XCTest

/// Codex's limits as its app-server reports them: a read with reset credits, a session's partial update, and the outcome
/// of using a reset.
final class CodexRateLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadCarriesWindowsAndResetCredits() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "planType": "pro",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_003_600],
                "secondary": ["usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1_800_300_000],
            ],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [
                    ["status": "available", "expiresAt": 1_800_900_000],
                    ["status": "available", "expiresAt": 1_800_500_000],
                    ["status": "redeemed", "expiresAt": 1_800_100_000],
                ],
            ],
        ]
        let snapshot = try XCTUnwrap(CodexRateLimits.snapshot(read: result, at: now))
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 18)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.resetCredits?.available, 2)
        // The first of the available ones; a redeemed credit does not count.
        XCTAssertEqual(snapshot.resetCredits?.nextExpiresAt, Date(timeIntervalSince1970: 1_800_500_000))
    }

    func testReadWithoutResetCreditsLeavesThemUnknown() throws {
        let result: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 5]]]
        let snapshot = try XCTUnwrap(CodexRateLimits.snapshot(read: result, at: now))
        XCTAssertNil(snapshot.resetCredits)
        // Without a length, primary is the 5-hour window.
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 5)
    }

    func testPushedUpdateKeepsTheOtherWindowAndCredits() throws {
        let read: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 300],
                "secondary": ["usedPercent": 30, "windowDurationMins": 10080],
            ],
            "rateLimitResetCredits": ["availableCount": 1],
        ]
        let before = try XCTUnwrap(CodexRateLimits.snapshot(read: read, at: now))
        let pushed: [String: Any] = ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 64, "windowDurationMins": 300]]]
        let after = try XCTUnwrap(CodexRateLimits.merge(pushed: pushed, into: before, at: now.addingTimeInterval(60)))
        XCTAssertEqual(after.fiveHour?.usedPercent, 64)
        XCTAssertEqual(after.weekly?.usedPercent, 30)
        XCTAssertEqual(after.resetCredits?.available, 1)
        XCTAssertEqual(after.updatedAt, now.addingTimeInterval(60))
    }

    func testModelAllowanceDoesNotOverwriteTheAccount() {
        let pushed: [String: Any] = ["rateLimits": ["limitId": "codex_bengalfox", "primary": ["usedPercent": 99]]]
        XCTAssertNil(CodexRateLimits.merge(pushed: pushed, into: nil, at: now))
    }

    func testResetOutcome() {
        XCTAssertEqual(CodexRateLimits.resetOutcome(["outcome": "reset"]), .reset)
        XCTAssertEqual(CodexRateLimits.resetOutcome(["outcome": "nothingToReset"]), .nothingToReset)
        XCTAssertEqual(CodexRateLimits.resetOutcome(["outcome": "noCredit"]), .noCredit)
        XCTAssertEqual(CodexRateLimits.resetOutcome(["outcome": "alreadyRedeemed"]), .alreadyRedeemed)
        XCTAssertEqual(CodexRateLimits.resetOutcome([:]), .failed)
    }
}
