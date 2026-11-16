import XCTest

final class WorktreeSetupProgressTests: XCTestCase {
    func testStepsTimeWhatTheyReallyTook() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = WorktreeSetupProgress(startedAt: start)
        XCTAssertNil(progress.current)
        progress.skip(.fetchBase)
        progress.begin(.checkOut, now: start)
        XCTAssertEqual(progress.current, .checkOut)
        progress.finish(.checkOut, now: start.addingTimeInterval(0.774))
        guard case .done(let took) = progress.state(.checkOut) else { return XCTFail("check out not done") }
        XCTAssertEqual(took, 0.774, accuracy: 0.0001)
        progress.skip(.runSetup)
        XCTAssertFalse(progress.isComplete)
        progress.begin(.startAgent, now: start)
        XCTAssertTrue(progress.isRunning(.startAgent))
        progress.finish(.startAgent, now: start.addingTimeInterval(2))
        XCTAssertTrue(progress.isComplete)
        XCTAssertNil(progress.failure)
    }

    func testAFailedStepSaysWhy() {
        var progress = WorktreeSetupProgress()
        progress.begin(.checkOut)
        progress.fail(.checkOut, "Branch 'x' already exists.")
        XCTAssertEqual(progress.failure?.step, .checkOut)
        XCTAssertEqual(progress.failure?.message, "Branch 'x' already exists.")
        XCTAssertFalse(progress.isComplete)
        XCTAssertNil(progress.current)
    }

    func testNotesKeepTheirOrderAndSkipEmptyText() {
        var progress = WorktreeSetupProgress()
        progress.note(.fetchBase, "fetched")
        progress.note(.checkOut, "")
        progress.note(.checkOut, "checked out")
        XCTAssertEqual(progress.notes.map(\.text), ["fetched", "checked out"])
        XCTAssertEqual(progress.notes.map(\.id), [0, 1])
    }

    func testDurationsReadLikeAnAgentsTranscript() {
        XCTAssertEqual(WorktreeSetupProgress.duration(0.774), "774ms")
        XCTAssertEqual(WorktreeSetupProgress.duration(1.43), "1.4s")
        XCTAssertEqual(WorktreeSetupProgress.duration(125), "2m 05s")
    }
}
