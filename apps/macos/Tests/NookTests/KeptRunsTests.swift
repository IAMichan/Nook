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

/// After a crash a kept agent's output is read again from the progress Nook wrote while it ran, without losing a request
/// or the turn's end, and without showing anything twice.
final class KeptProgressTests: XCTestCase {
    private let then = Date(timeIntervalSince1970: 1_800_000_000)

    func testAfterACrashItGoesOnFromTheWrittenProgress() {
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: nil, progress: 250,
                                         spoolSize: 400), .attach(offset: 250))
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: 300, progress: 250,
                                         spoolSize: 400), .attach(offset: 300), "a clean quit's offset wins")
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: true, savedOffset: nil, progress: 900,
                                         spoolSize: 400), .attach(offset: 400), "never past the spool")
        XCTAssertEqual(KeptRuns.onLaunch(status: .running, hasKeeper: true, keeperAlive: false, savedOffset: nil, progress: 250,
                                         spoolSize: 400), .gone)
    }

    func testProgressStopsBeforeARequestThatWaits() {
        XCTAssertEqual(KeptRuns.durableOffset(handled: 500, hold: nil), 500)
        XCTAssertEqual(KeptRuns.durableOffset(handled: 500, hold: 320), 320, "the approval is read again after a crash")
        XCTAssertEqual(KeptRuns.durableOffset(handled: 200, hold: 320), 200)
    }

    func testProgressIsWrittenNowAndThen() {
        XCTAssertTrue(KeptRuns.shouldWriteProgress(now: then, lastWritten: nil, force: false))
        XCTAssertFalse(KeptRuns.shouldWriteProgress(now: then.addingTimeInterval(0.2), lastWritten: then, force: false))
        XCTAssertTrue(KeptRuns.shouldWriteProgress(now: then.addingTimeInterval(0.2), lastWritten: then, force: true))
        XCTAssertTrue(KeptRuns.shouldWriteProgress(now: then.addingTimeInterval(KeptRuns.progressInterval), lastWritten: then, force: false))
    }

    func testProgressRoundTripsThroughTheKeepersFolder() throws {
        let folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = KeptRuns.Progress(offset: 4_096, savedAt: then)
        KeptRuns.writeProgress(progress, folder: folder)
        XCTAssertEqual(KeptRuns.readProgress(folder: folder), progress)
        XCTAssertNil(KeptRuns.decode(Data("garbage".utf8)))
        let gone = folder.appendingPathComponent("ended")
        KeptRuns.writeProgress(progress, folder: gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "a keeper that ended removed its folder; it stays gone")
    }

    func testTheKeeperRemovesTheProgressWithItsFolder() {
        XCTAssertTrue(SessionKeeper.contents.contains("\"$folder/handled\""), "otherwise rmdir leaves the folder behind")
        XCTAssertEqual(KeptRuns.progressFile, "handled")
    }

    private func event(_ kind: RunEvent.Kind, _ text: String, call: String? = nil, at offset: TimeInterval = 10,
                       state: RunEvent.State? = nil) -> RunEvent {
        RunEvent(kind: kind, text: text, callID: call, state: state, date: then.addingTimeInterval(offset))
    }

    func testReplayedEventsTakeThePlaceOfWhatIsThere() {
        let before = event(.assistant, "Earlier answer", at: -60)
        let text = event(.assistant, "Let me check the build.")
        let tool = event(.tool, "Bash: make", call: "toolu_1", state: .failed)
        let approval = event(.approval, "Bash: rm -rf build", call: "req_1", state: .expired)
        let note = event(.system, "Worked on while Nook was closed.")
        var replay = KeptRuns.Replay(timeline: [before, text, note, tool, approval], since: then, until: 900)

        // Streamed: the first piece matches the start of the text already there.
        let first = event(.assistant, "Let me")
        XCTAssertEqual(replay.match(first), text.id)
        XCTAssertEqual(replay.resolve(first.id), text.id, "later pieces change the event already there")
        XCTAssertEqual(replay.match(event(.tool, "Bash: make", call: "toolu_1", state: .running)), tool.id)
        let again = event(.approval, "Bash: rm -rf build", call: "req_1", state: .pending)
        XCTAssertEqual(replay.match(again), approval.id, "the approval asked again revives the one that expired")
        XCTAssertTrue(replay.isDone)
        XCTAssertNil(replay.match(event(.assistant, "Something new")), "what comes after is new")
    }

    func testReplayMatchesInOrderAndOnlySinceTheProgress() {
        let old = event(.assistant, "Done.", at: -30)
        let recent = event(.assistant, "Done.")
        var replay = KeptRuns.Replay(timeline: [old, recent], since: then, until: 100)
        XCTAssertEqual(replay.match(event(.assistant, "Done.")), recent.id, "before the progress it was handled for sure")
        XCTAssertNil(replay.match(event(.assistant, "Done.")), "used up: a second one is new")

        let a = event(.tool, "Read a", call: "a")
        let b = event(.tool, "Read b", call: "b")
        var ordered = KeptRuns.Replay(timeline: [a, b], since: then, until: 100)
        XCTAssertEqual(ordered.match(event(.tool, "Read b", call: "b")), b.id)
        XCTAssertNil(ordered.match(event(.tool, "Read a", call: "a")), "matched in order: what was passed is not taken again")
    }

    func testYourMessagesAndNooksNotesAreNotReplayed() {
        let mine = event(.user, "Go on")
        var replay = KeptRuns.Replay(timeline: [mine], since: then, until: 100)
        XCTAssertTrue(replay.isDone)
        XCTAssertNil(replay.match(event(.user, "Go on")))
        XCTAssertNil(replay.match(event(.system, "Stopped.")))
    }
}
