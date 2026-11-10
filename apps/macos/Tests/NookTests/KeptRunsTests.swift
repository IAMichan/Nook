import XCTest

/// The state machine of sessions kept running while Nook is closed: quitting, launching again, and the quit confirmation.
final class KeptRunsTests: XCTestCase {
    private func candidate(_ status: RunStatus, keeper: Bool = true, running: Bool = true, waits: Bool = false) -> KeptRuns.Candidate {
        KeptRuns.Candidate(id: UUID(), status: status, hasKeeper: keeper, keeperRunning: running, waitsForYou: waits)
    }

    func testOffKeepsNothing() {
        // The default path: with the setting off every working session stops, as before keepers existed.
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running), enabled: false), .stop)
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running, keeper: false), enabled: false), .stop)
    }

    func testAWorkingSessionWithItsKeeperStays() {
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running), enabled: true), .keep)
    }

    func testASessionWaitingForYouStops() {
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running, waits: true), enabled: true), .stop)
        XCTAssertEqual(KeptRuns.onQuit(candidate(.waitingApproval), enabled: true), .stop)
    }

    func testWithoutALiveKeeperItStops() {
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running, keeper: false), enabled: true), .stop)
        XCTAssertEqual(KeptRuns.onQuit(candidate(.running, running: false), enabled: true), .stop)
    }

    func testAnIdleSessionIsLeftAlone() {
        XCTAssertEqual(KeptRuns.onQuit(candidate(.completed), enabled: true), .idle)
        XCTAssertEqual(KeptRuns.onQuit(candidate(.stopped, keeper: false), enabled: false), .idle)
    }

    func testLaunchWithoutKeeperIsUntouched() {
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: false, keeperAlive: false, savedOffset: nil, spoolSize: nil), .none)
    }

    func testLaunchAttachesWhereNookStopped() {
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: 120, spoolSize: 400),
                       .attach(offset: 120))
    }

    func testAfterACrashItGoesOnFromTheEnd() {
        // Nook did not save how far it read: replaying the spool would show everything twice.
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: nil, spoolSize: 400),
                       .attach(offset: 400))
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: nil, spoolSize: nil),
                       .attach(offset: 0))
    }

    func testAGoneKeeperCountsAsInterrupted() {
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: false, savedOffset: 5, spoolSize: 5), .gone)
        XCTAssertEqual(KeptRuns.onLaunch(status: .completed, hasKeeper: true, keeperAlive: true, savedOffset: 5, spoolSize: 5), .gone)
    }

    func testQuitSummaryCountsWhatGoesOnAndWhatStops() {
        let runs = [candidate(.running), candidate(.running), candidate(.running, waits: true), candidate(.completed)]
        XCTAssertEqual(KeptRuns.quitSummary(runs, enabled: true), .init(keep: 2, stop: 1))
        XCTAssertEqual(KeptRuns.quitSummary(runs, enabled: false), .init(keep: 0, stop: 3))
        XCTAssertTrue(KeptRuns.quitSummary([candidate(.completed)], enabled: true).isEmpty)
    }

    func testOrphansAreTheUnclaimedFolders() {
        XCTAssertEqual(KeptRuns.orphans(folders: ["b", "a", "c"], claimed: ["c"]), ["a", "b"])
    }
}
