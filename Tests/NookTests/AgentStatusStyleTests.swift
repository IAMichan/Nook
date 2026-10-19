import XCTest

final class AgentStatusStyleTests: XCTestCase {
    private let all = AgentDisplayState.allCases

    func testEveryAttentionCaseMaps() {
        XCTAssertEqual(AgentDisplayState(.approval), .approval)
        XCTAssertEqual(AgentDisplayState(.finished), .finished)
        XCTAssertEqual(AgentDisplayState(.limited), .limited)
        XCTAssertEqual(all.count, 10)
    }

    func testSymbolsAreDistinct() {
        let symbols = all.map(AgentStatusStyle.symbol)
        XCTAssertEqual(Set(symbols).count, all.count)
    }

    func testKeysAreDistinctAndListed() {
        let keys = AgentStatusStyle.keys
        XCTAssertEqual(Set(keys).count, all.count * 2)
        XCTAssertEqual(AgentStatusStyle.longKey(.approval), "agents.status.approval.long")
        XCTAssertEqual(AgentStatusStyle.shortKey(.woke), "agents.status.woke.short")
        for state in all {
            XCTAssertTrue(keys.contains(AgentStatusStyle.longKey(state)))
            XCTAssertTrue(keys.contains(AgentStatusStyle.shortKey(state)))
        }
    }

    func testOnlyWorkingPulses() {
        for state in all { XCTAssertEqual(AgentStatusStyle.pulses(state), state == .working) }
    }

    func testPrioritiesAreDistinctAndOrdered() {
        XCTAssertEqual(Set(all.map(AgentStatusStyle.priority)).count, all.count)
        let p = AgentStatusStyle.priority
        XCTAssertGreaterThan(p(.approval), p(.input))
        XCTAssertGreaterThan(p(.input), p(.failed))
        XCTAssertGreaterThan(p(.failed), p(.working))
        XCTAssertGreaterThan(p(.working), p(.ready))
        XCTAssertGreaterThan(p(.ready), p(.idle))
        XCTAssertGreaterThan(p(.idle), p(.finished))
    }

    func testTonesFollowThePlan() {
        XCTAssertEqual(AgentStatusStyle.tone(.approval), .amber)
        XCTAssertEqual(AgentStatusStyle.tone(.failed), .coral)
        XCTAssertEqual(AgentStatusStyle.tone(.ready), .mint)
        XCTAssertEqual(AgentStatusStyle.tone(.snoozed), .slate)
        XCTAssertEqual(AgentStatusStyle.tone(.finished), .muted)
    }

    func testRollupApprovalOutranksWorking() {
        XCTAssertEqual(ProjectRollup.highest([.working, .ready, .approval, .idle]), .approval)
        XCTAssertEqual(ProjectRollup.highest([.idle, .working]), .working)
    }

    func testRollupEmptyAndTies() {
        XCTAssertNil(ProjectRollup.highest([]))
        XCTAssertEqual(ProjectRollup.highest([.idle, .idle]), .idle)
        XCTAssertEqual(ProjectRollup.highest([.snoozed]), .snoozed)
        XCTAssertEqual(ProjectRollup.highest([.woke, .snoozed]), .woke)
    }

    func testStallBelowAndAtThreshold() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(59.9)))
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(60))?.severity, .quiet)
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(299.9))?.severity, .quiet)
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(300))?.severity, .long)
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(90))?.seconds, 90)
    }

    func testStallNilBackwardsAndReset() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(StallDetector.hint(lastActivity: nil, now: t0))
        XCTAssertNil(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(-500)))
        let now = t0.addingTimeInterval(400)
        XCTAssertNotNil(StallDetector.hint(lastActivity: t0, now: now))
        XCTAssertNil(StallDetector.hint(lastActivity: now.addingTimeInterval(-5), now: now))
    }

    func testStallCustomThreshold() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(10), thresholdSeconds: 10)?.severity, .quiet)
        XCTAssertEqual(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(50), thresholdSeconds: 10)?.severity, .long)
        XCTAssertNil(StallDetector.hint(lastActivity: t0, now: t0.addingTimeInterval(50), thresholdSeconds: 0))
    }

    func testDurationShort() {
        XCTAssertEqual(DurationText.short(0), "0s")
        XCTAssertEqual(DurationText.short(0.9), "0s")
        XCTAssertEqual(DurationText.short(-3), "0s")
        XCTAssertEqual(DurationText.short(.nan), "0s")
        XCTAssertEqual(DurationText.short(42), "42s")
        XCTAssertEqual(DurationText.short(59.9), "59s")
        XCTAssertEqual(DurationText.short(60), "1m 0s")
        XCTAssertEqual(DurationText.short(72), "1m 12s")
        XCTAssertEqual(DurationText.short(3599), "59m 59s")
        XCTAssertEqual(DurationText.short(3600), "1h 0m")
        XCTAssertEqual(DurationText.short(7500), "2h 5m")
    }

    func testDurationAgo() {
        XCTAssertEqual(DurationText.ago(12), "12s")
        XCTAssertEqual(DurationText.ago(59.9), "59s")
        XCTAssertEqual(DurationText.ago(60), "1m")
        XCTAssertEqual(DurationText.ago(180), "3m")
        XCTAssertEqual(DurationText.ago(3599), "59m")
        XCTAssertEqual(DurationText.ago(3600), "1h")
        XCTAssertEqual(DurationText.ago(7200), "2h")
        XCTAssertEqual(DurationText.ago(86_399), "23h")
        XCTAssertEqual(DurationText.ago(86_400), "1d")
        XCTAssertEqual(DurationText.ago(-1), "0s")
    }
}
