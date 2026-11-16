import XCTest

/// Going back to before a message (`RevertPlan`): never across a turn without a snapshot, and never over another
/// session's work in the same folder.
final class RevertPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func checkpoint(_ minutes: Double) -> RunCheckpoint {
        RunCheckpoint(ref: "refs/nook/checkpoints/x/\(Int(minutes))", date: start.addingTimeInterval(minutes * 60))
    }

    func testPicksTheLastSnapshotBeforeTheMessage() {
        let checkpoints = [checkpoint(0), checkpoint(10), checkpoint(20)]
        XCTAssertEqual(RevertPlan.checkpointIndex(checkpoints, missed: [], before: start.addingTimeInterval(15 * 60)), 1)
        XCTAssertEqual(RevertPlan.checkpointIndex(checkpoints, missed: [], before: .distantFuture), 2)
        XCTAssertNil(RevertPlan.checkpointIndex(checkpoints, missed: [], before: start.addingTimeInterval(-60)))
    }

    /// The snapshot of the turn that ended at minute 20 failed: going back to before a message at minute 25 would
    /// restore minute 10 and silently undo that turn too, so it is refused.
    func testRefusesToGoBackAcrossATurnWithoutASnapshot() {
        let checkpoints = [checkpoint(0), checkpoint(10)]
        let missed = [start.addingTimeInterval(20 * 60)]
        XCTAssertNil(RevertPlan.checkpointIndex(checkpoints, missed: missed, before: start.addingTimeInterval(25 * 60)))
        XCTAssertEqual(RevertPlan.checkpointIndex(checkpoints, missed: missed, before: start.addingTimeInterval(15 * 60)), 1,
                       "before the gap it still works")
    }

    func testFoldersOverlapWhenOneHoldsTheOther() {
        XCTAssertTrue(RevertPlan.overlaps("/w/tree", "/w/tree"))
        XCTAssertTrue(RevertPlan.overlaps("/w/tree", "/w/tree/app"))
        XCTAssertTrue(RevertPlan.overlaps("/w/tree/app", "/w/tree/"))
        XCTAssertFalse(RevertPlan.overlaps("/w/tree", "/w/tree-2"), "a sibling with a longer name is another folder")
        XCTAssertFalse(RevertPlan.overlaps("/w/a", "/w/b"))
        XCTAssertFalse(RevertPlan.overlaps("", "/w/a"))
    }

    func testAnotherSessionAtWorkOrWithNewerWorkBlocks() {
        let since = start.addingTimeInterval(10 * 60)
        var other = TestData.run(status: .running)
        XCTAssertTrue(RevertPlan.blocks(other, since: since), "files would change under a running agent")
        other.status = .completed
        other.checkpoints = [checkpoint(5)]
        XCTAssertFalse(RevertPlan.blocks(other, since: since), "its last turn is in the snapshot already")
        other.checkpoints = [checkpoint(5), checkpoint(12)]
        XCTAssertTrue(RevertPlan.blocks(other, since: since), "a fork's later turn would be thrown away")
        other.checkpoints = [checkpoint(5)]
        other.missedCheckpoints = [start.addingTimeInterval(12 * 60)]
        XCTAssertTrue(RevertPlan.blocks(other, since: since), "a later turn without a snapshot counts too")
        other.archived = true
        XCTAssertFalse(RevertPlan.blocks(other, since: since), "an archived session is done with")
    }

    func testMissedSnapshotsSurviveASaveAndAreOptional() throws {
        var run = TestData.run(status: .completed)
        run.missedCheckpoints = [start]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WorkspaceRun.self, from: encoder.encode(run)).missedCheckpoints, [start])
        run.missedCheckpoints = nil
        XCTAssertNil(try decoder.decode(WorkspaceRun.self, from: encoder.encode(run)).missedCheckpoints)
    }
}
