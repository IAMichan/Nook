import XCTest

final class AgentAttentionTests: XCTestCase {
    private func input(_ status: RunStatus, approvals: Int = 0, questions: Int = 0, limited: Date? = nil,
                       unseen: Bool = false, settled: Bool = false) -> AgentAttention.Input {
        AgentAttention.Input(status: status, pendingApprovals: approvals, pendingQuestions: questions,
                             limitedAt: limited, unseen: unseen, settled: settled)
    }

    // MARK: Priority

    func testApprovalBeatsQuestionBeatsWorking() {
        XCTAssertEqual(AgentAttention.resolve(input(.running, approvals: 1, questions: 1)), .approval)
        XCTAssertEqual(AgentAttention.resolve(input(.waitingApproval)), .approval)
        XCTAssertEqual(AgentAttention.resolve(input(.running, questions: 1)), .input)
        XCTAssertEqual(AgentAttention.resolve(input(.running)), .working)
        XCTAssertEqual(AgentAttention.resolve(input(.preparing)), .working)
    }

    func testOrderPutsWhatNeedsYouFirst() {
        let sorted: [AgentAttention] = [.idle, .working, .limited, .failed, .input, .approval, .finished, .ready].sorted()
        XCTAssertEqual(sorted, [.approval, .input, .failed, .limited, .working, .ready, .idle, .finished])
        XCTAssertTrue(AgentAttention.approval.needsYou)
        XCTAssertTrue(AgentAttention.input.needsYou)
        XCTAssertFalse(AgentAttention.working.needsYou)
    }

    func testQuestionOfAStoppedSessionDoesNotCount() {
        // Without a process the question can no longer be answered.
        XCTAssertEqual(AgentAttention.resolve(input(.stopped, questions: 1)), .finished)
    }

    func testFailedBecomesLimitedWithALimit() {
        XCTAssertEqual(AgentAttention.resolve(input(.failed)), .failed)
        XCTAssertEqual(AgentAttention.resolve(input(.failed, limited: Date())), .limited)
    }

    func testCompletedIsReadyUntilSeen() {
        XCTAssertEqual(AgentAttention.resolve(input(.completed, unseen: true)), .ready)
        XCTAssertEqual(AgentAttention.resolve(input(.completed)), .idle)
    }

    func testSettledHidesIdleButNeverWhatWaitsForYou() {
        XCTAssertEqual(AgentAttention.resolve(input(.completed, settled: true)), .finished)
        XCTAssertEqual(AgentAttention.resolve(input(.running, approvals: 1, settled: true)), .approval)
        XCTAssertEqual(AgentAttention.resolve(input(.running, settled: true)), .working, "an active session is not hidden")
    }

    // MARK: Notifications

    func testLedgerFiresOncePerState() {
        var ledger = AttentionLedger()
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .approval))
        XCTAssertFalse(ledger.shouldNotify(id: "a", state: .approval), "the same state again is not news")
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .input), "another state is")
        XCTAssertFalse(ledger.shouldNotify(id: "a", state: .working))
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .input), "leaving and entering a state fires again")
    }

    func testLedgerKeepsSessionsApartAndKnowsTurns() {
        var ledger = AttentionLedger()
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .ready, turn: 1))
        XCTAssertTrue(ledger.shouldNotify(id: "b", state: .ready, turn: 1))
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .ready, turn: 2), "a new turn that finishes is new")
        ledger.forget("a")
        XCTAssertTrue(ledger.shouldNotify(id: "a", state: .ready, turn: 2))
    }

    // MARK: Snooze

    func testSnoozeEndsAtItsTime() {
        let since = Date(timeIntervalSince1970: 1_000)
        let until = since.addingTimeInterval(3600)
        XCTAssertTrue(SnoozePolicy.isSnoozed(until: until, since: since, attention: .idle, finishedAt: since, now: since.addingTimeInterval(10)))
        XCTAssertFalse(SnoozePolicy.isSnoozed(until: until, since: since, attention: .idle, finishedAt: since, now: until))
        XCTAssertFalse(SnoozePolicy.isSnoozed(until: nil, since: nil, attention: .idle, finishedAt: nil))
    }

    func testSnoozeWakesWhenSomethingNeedsYou() {
        let since = Date(timeIntervalSince1970: 1_000)
        let until = since.addingTimeInterval(3600)
        let now = since.addingTimeInterval(60)
        for attention in [AgentAttention.approval, .input, .failed, .limited] {
            XCTAssertFalse(SnoozePolicy.isSnoozed(until: until, since: since, attention: attention, finishedAt: nil, now: now), "\(attention)")
        }
        XCTAssertFalse(SnoozePolicy.isSnoozed(until: until, since: since, attention: .ready, finishedAt: since.addingTimeInterval(30), now: now),
                       "finished something after the snooze began")
        XCTAssertTrue(SnoozePolicy.isSnoozed(until: until, since: since, attention: .working, finishedAt: nil, now: now))
    }

    func testSnoozeChoices() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ hour: Int, day: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour))!
        }
        XCTAssertEqual(SnoozePolicy.Choice.hour.end(from: date(10), calendar: calendar), date(11))
        XCTAssertEqual(SnoozePolicy.Choice.evening.end(from: date(10), calendar: calendar), date(18))
        XCTAssertEqual(SnoozePolicy.Choice.evening.end(from: date(19), calendar: calendar), date(18, day: 11),
                       "after six it means tomorrow evening")
        XCTAssertEqual(SnoozePolicy.Choice.tomorrow.end(from: date(23), calendar: calendar), date(9, day: 11))
    }

    // MARK: Restart continuation

    func testContinuesOnlyASessionCutOffJustNow() {
        let now = Date()
        var run = TestData.run(status: .stopped)
        run.statusDetail = "interrupted"
        run.updatedAt = now.addingTimeInterval(-60)
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: false, now: now), "off by default")
        run.updatedAt = now.addingTimeInterval(-3 * 3600)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "an old interruption is yours to pick up")
    }

    func testDoesNotContinueWhatYouStoppedOrWhatWaitsOnYou() {
        let now = Date()
        var run = TestData.run(status: .stopped)
        run.updatedAt = now
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "stopped by you, not interrupted")
        run.statusDetail = "interrupted"
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, hasPendingQuestion: true, now: now))
        run.archived = true
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        run.archived = false
        run.limitedAt = now
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a usage limit has its own resume")
    }

    func testChainIsCapped() {
        let now = Date()
        var run = TestData.run(status: .stopped)
        run.statusDetail = "interrupted"
        run.updatedAt = now
        run.continuations = RestartContinuation.limit - 1
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        run.continuations = RestartContinuation.limit
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a session that keeps crashing does not loop")
    }

    func testNewFieldsSurviveAnOldFile() throws {
        // A file written before these fields existed still decodes.
        let run = TestData.run(status: .completed)
        let data = try JSONEncoder().encode(run)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["continuations"] = nil
        object["snoozedUntil"] = nil
        object["snoozedAt"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkspaceRun.self, from: old)
        XCTAssertNil(decoded.continuations)
        XCTAssertNil(decoded.snoozedUntil)
    }
}
