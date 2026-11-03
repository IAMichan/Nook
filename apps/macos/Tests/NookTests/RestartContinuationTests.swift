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
        let decoded = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
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
