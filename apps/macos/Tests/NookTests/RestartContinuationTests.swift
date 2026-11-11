import XCTest

/// Going on after a restart (restart continuation): which sessions qualify, and the cap on a chain.
final class RestartContinuationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func interrupted() -> WorkspaceRun {
        var run = TestData.run(status: .stopped)
        run.statusDetail = "interrupted"
        run.updatedAt = now.addingTimeInterval(-30)
        return run
    }

    func testSkipsSettledSnoozedAndWaitingSessions() {
        var run = interrupted()
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, settled: true, now: now), "you settled it")
        run.snoozedUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "snoozed")
        run.snoozedUntil = now.addingTimeInterval(-60)
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a snooze that already woke does not block")
        run.interruptedWhileWaiting = true
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "it waited for an approval the restart cut off")
    }

    func testASessionYourQuitStoppedGoesOnHoweverLongNookWasClosed() {
        var run = interrupted()
        run.updatedAt = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a crash two days ago is yours to pick up")
        run.stoppedByQuit = true
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now), "you quit Nook and opened it again")
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: false, now: now), "only with the setting on")
        run.interruptedWhileWaiting = true
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "it still waits on you")
    }

    func testAWaitCutByAQuitLongAgoContinues() {
        var run = TestData.run(status: .completed)
        run.cutBackgroundWork = CutBackgroundWork(labels: ["Audit chats"], at: now.addingTimeInterval(-24 * 3600))
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now))
        run.stoppedByQuit = true
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now))
    }

    func testChainCountsOnlyWithinTheLoopWindow() {
        var run = interrupted()
        run.continuations = RestartContinuation.limit
        run.lastContinuedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(RestartContinuation.chainLength(run, now: now), RestartContinuation.limit)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "three in five minutes: it keeps crashing")
        run.lastContinuedAt = now.addingTimeInterval(-RestartContinuation.loopWindow - 1)
        XCTAssertEqual(RestartContinuation.chainLength(run, now: now), 0)
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now), "an old chain no longer counts")
        // A count from before the time was recorded stays counted.
        run.lastContinuedAt = nil
        XCTAssertEqual(RestartContinuation.chainLength(run, now: now), RestartContinuation.limit)
    }

    func testOldFilesDecode() throws {
        let data = try JSONEncoder().encode(TestData.run(status: .stopped))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["lastContinuedAt"] = nil
        object["interruptedWhileWaiting"] = nil
        object["stoppedByQuit"] = nil
        let decoded = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.stoppedByQuit)
        XCTAssertNil(decoded.lastContinuedAt)
        XCTAssertNil(decoded.interruptedWhileWaiting)
    }

    func testRelaunchRemembersAWaitingApproval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RunStore(directory: folder)
        var waiting = TestData.run(status: .waitingApproval)
        waiting.id = UUID()
        let running = TestData.run(status: .running)
        try store.saveRuns([waiting, running])
        let loaded = RunStore(directory: folder).loadRuns()
        XCTAssertEqual(loaded.first { $0.id == waiting.id }?.interruptedWhileWaiting, true)
        XCTAssertNil(loaded.first { $0.id == running.id }?.interruptedWhileWaiting)
    }
}

/// A session whose turn ended while it waited on a subagent, when Nook quit: it is woken with a note.
final class RestartBackgroundWaitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func waiting() -> WorkspaceRun {
        var run = TestData.run(status: .completed)
        run.updatedAt = now.addingTimeInterval(-3 * 3600)
        run.cutBackgroundWork = CutBackgroundWork(labels: ["Audit chats"], at: now.addingTimeInterval(-60))
        return run
    }

    func testAWaitCutByTheRestartContinues() {
        var run = waiting()
        XCTAssertTrue(RestartContinuation.shouldContinue(run, enabled: true, now: now), "the quit is what counts, not the turn's end")
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: false, now: now))
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, hasPendingQuestion: true, now: now))
        run.continuations = RestartContinuation.limit
        run.lastContinuedAt = now.addingTimeInterval(-30)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "the loop cap holds")
        run = waiting()
        run.cutBackgroundWork?.at = now.addingTimeInterval(-RestartContinuation.maxAge - 1)
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a quit long ago is yours to pick up")
        run = waiting()
        run.cutBackgroundWork = nil
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: now), "a finished session waited on nothing")
    }

    func testTheMessageNamesWhatStopped() {
        let message = RestartContinuation.message(for: waiting())
        XCTAssertTrue(message.hasPrefix("Note: Nook restarted"))
        XCTAssertTrue(message.contains("- subagent: Audit chats"))
        XCTAssertTrue(message.hasSuffix(RestartContinuation.message))
        XCTAssertEqual(RestartContinuation.message(for: TestData.run(status: .stopped)), RestartContinuation.message)
        let many = RestartContinuation.note((1...12).map { "Task \($0)" })
        XCTAssertTrue(many.contains("- and 2 more"))
        XCTAssertFalse(many.contains("Task 11"))
    }

    func testOnlySubagentsStillAtWorkAreWaitedOn() {
        let running = RunEvent(kind: .tool, text: "Agent · Audit", tool: "Agent", detail: #"{"description":"Audit chats"}"#, state: .running)
        let done = RunEvent(kind: .tool, text: "Agent · Fix", tool: "Agent", detail: #"{"description":"Fix"}"#, state: .done)
        var server = RunEvent(kind: .tool, text: "Bash · npm run dev", tool: "Bash", state: .running)
        server.background = true
        XCTAssertEqual(RestartContinuation.waitedOn([running, done, server]), ["Audit chats"])
    }
}
