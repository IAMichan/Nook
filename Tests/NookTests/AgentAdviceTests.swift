import XCTest

final class AgentAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    private func st(_ p: RunProvider, _ id: String, _ u: Double?, reset: Date? = nil) -> LimitState {
        LimitState(provider: p, profileID: id, usedFraction: u, resetAt: reset)
    }

    func testSuggestsSameAgentOtherAccountFirst() {
        let s = LimitAdvisor.suggest(states: [st(.claude, "a", 0.95, reset: now.addingTimeInterval(600)), st(.codex, "c", 0.1),
                                              st(.claude, "b", 0.5)], current: (.claude, "a"), now: now)
        XCTAssertEqual(s, LimitSuggestion(provider: .claude, profileID: "b", sameAgent: true, resumeIn: 600))
    }

    func testOtherAgentWhenNoSameAgentAndThresholds() {
        let states = [st(.claude, "a", 0.9), st(.claude, "b", 0.7), st(.codex, "c", 0.69)]
        XCTAssertEqual(LimitAdvisor.suggest(states: states, current: (.claude, "a"), now: now)?.provider, .codex)
        XCTAssertNil(LimitAdvisor.suggest(states: [st(.claude, "a", 0.89), st(.codex, "c", 0.1)], current: (.claude, "a"), now: now))
    }

    func testUnknownOnlyAsLastResortAndAllLimited() {
        let states = [st(.claude, "a", 0.95), st(.codex, "c", nil), st(.claude, "b", 0.8)]
        XCTAssertEqual(LimitAdvisor.suggest(states: states, current: (.claude, "a"), now: now)?.profileID, "c")
        let known = states + [st(.codex, "d", 0.2)]
        XCTAssertEqual(LimitAdvisor.suggest(states: known, current: (.claude, "a"), now: now)?.profileID, "d")
        XCTAssertNil(LimitAdvisor.suggest(states: [st(.claude, "a", 0.95), st(.claude, "b", 0.99)], current: (.claude, "a"), now: now))
        XCTAssertNil(LimitAdvisor.suggest(states: [st(.claude, "a", nil), st(.codex, "c", 0.1)], current: (.claude, "a"), now: now))
        XCTAssertNil(LimitAdvisor.suggest(states: [], current: (.claude, "a"), now: now))
    }

    private func input(_ status: RunStatus, last: TimeInterval? = nil, pending: TimeInterval? = nil, idle: TimeInterval = 0,
                       limited: TimeInterval? = nil) -> StuckInput {
        StuckInput(status: status, lastActivity: last.map { now.addingTimeInterval(-$0) },
                   pendingRequestSince: pending.map { now.addingTimeInterval(-$0) }, userIdleSeconds: idle,
                   limitedSince: limited.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testWaitingOnYou() {
        XCTAssertEqual(StuckDetector.detect(input(.waitingApproval, pending: 360, idle: 400)), .waitingOnYou(minutes: 6))
        XCTAssertNil(StuckDetector.detect(input(.waitingApproval, pending: 360, idle: 10)), "user is here")
        XCTAssertNil(StuckDetector.detect(input(.waitingApproval, pending: 240, idle: 400)))
    }

    func testNoProgressAndLimited() {
        XCTAssertEqual(StuckDetector.detect(input(.running, last: 700)), .noProgress(minutes: 11))
        XCTAssertNil(StuckDetector.detect(input(.running, last: 500)))
        XCTAssertNil(StuckDetector.detect(input(.completed, last: 5000)))
        XCTAssertNil(StuckDetector.detect(input(.running, last: 5000, pending: 10)), "waiting on a request is not no progress")
        XCTAssertEqual(StuckDetector.detect(input(.failed, limited: 3600)), .limitedForLong(minutes: 60))
        XCTAssertNil(StuckDetector.detect(input(.failed, limited: 60)))
    }
}
