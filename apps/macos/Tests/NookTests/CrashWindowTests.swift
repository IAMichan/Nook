import XCTest

/// What a crash in the moment before the next save must not lose (`RunDurability`, `stopRequestedAt`,
/// `RestartRequests.queues`): the conversation id, the keeper, a turn's end, a stop you asked for, and a message you sent
/// "now".
final class CrashWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testChangesARestartDependsOnAreSavedAtOnce() {
        let old = TestData.run(status: .running)
        var new = old
        new.providerSessionID = "thread-1"
        XCTAssertTrue(RunDurability.savesAtOnce(old, new), "the conversation id: else it cannot be resumed")
        new = old
        new.status = .completed
        XCTAssertTrue(RunDurability.savesAtOnce(old, new), "the end of a turn: else it reads as cut off")
        new = old
        new.stopRequestedAt = now
        XCTAssertTrue(RunDurability.savesAtOnce(old, new))
        new = old
        new.continuations = 1
        XCTAssertTrue(RunDurability.savesAtOnce(old, new), "the restart loop counter")
        new = old
        new.missedCheckpoints = [now]
        XCTAssertTrue(RunDurability.savesAtOnce(old, new))
        new = old
        new.status = .waitingApproval
        XCTAssertFalse(RunDurability.savesAtOnce(old, new), "still at work: the usual save")
        new = old
        new.usage.reportedCostUSD = 0.5
        new.lastChangeAt = now
        XCTAssertFalse(RunDurability.savesAtOnce(old, new), "what streaming changes waits for the usual save")
    }

    func testAStopYouAskedForIsNotContinuedAfterARestart() {
        var run = TestData.run(status: .stopped)
        run.statusDetail = "interrupted"
        run.updatedAt = now.addingTimeInterval(-30)
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        run.stopRequestedAt = now.addingTimeInterval(-31)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "the turn was meant to end")
        run.stoppedByQuit = true
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "also when Nook quit right after")
    }

    func testTheNextTurnClearsAStopRequest() {
        var run = TestData.run(status: .stopped)
        run.stopRequestedAt = now
        XCTAssertTrue(run.move(to: .running, now: now))
        XCTAssertNil(run.stopRequestedAt)
        run.stopRequestedAt = now
        XCTAssertTrue(run.move(to: .waitingApproval, now: now))
        XCTAssertNotNil(run.stopRequestedAt, "a turn that goes on is not a new one")
    }

    func testAMessageSentNowIsSavedInFrontOfItsQueue() {
        let id = UUID(), other = UUID()
        var queue = MessageQueue()
        queue.enqueue("later")
        let saved = RestartRequests.queues([id: queue], sendingNow: [id: "now", other: "fresh start"], fresh: [other])
        XCTAssertEqual(saved[id]?.messages.map(\.text), ["now", "later"])
        XCTAssertEqual(saved[other]?.messages.map(\.text), ["fresh start"])
        XCTAssertEqual(saved[other]?.messages.first?.fresh, true)
        XCTAssertEqual(RestartRequests.queues([id: queue], sendingNow: [:], fresh: []), [id: queue])
    }

    /// A fallback to the simpler channel lasts a while, not until Nook restarts.
    func testAFallbackMarkExpires() {
        var marks = FallbackMarks()
        marks.modified = { _ in Date(timeIntervalSince1970: 1) }
        let start = Date(timeIntervalSince1970: 1_000)
        marks.insert("/bin/codex", now: start)
        XCTAssertTrue(marks.contains("/bin/codex", now: start.addingTimeInterval(60)))
        XCTAssertFalse(marks.contains("/bin/other", now: start))
        XCTAssertFalse(marks.contains("/bin/codex", now: start.addingTimeInterval(FallbackMarks.lifetime + 1)))
    }

    /// An agent updated on disk gets its richer channel back at once.
    func testAFallbackMarkEndsWhenTheExecutableChanges() {
        var marks = FallbackMarks()
        var stamp = Date(timeIntervalSince1970: 1)
        marks.modified = { _ in stamp }
        let start = Date(timeIntervalSince1970: 1_000)
        marks.insert("/bin/gemini", now: start)
        XCTAssertTrue(marks.contains("/bin/gemini", now: start))
        stamp = Date(timeIntervalSince1970: 2)
        XCTAssertFalse(marks.contains("/bin/gemini", now: start))
    }
}
