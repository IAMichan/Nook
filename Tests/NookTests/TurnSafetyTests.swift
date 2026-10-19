import XCTest

final class TurnSafetyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func ev(_ kind: RunEvent.Kind, _ state: RunEvent.State?) -> RunEvent {
        RunEvent(kind: kind, text: "x", state: state)
    }

    // MARK: OpenWork

    private func open() -> [RunEvent] {
        [ev(.tool, .running), ev(.fileChange, .running), ev(.assistant, .running), ev(.thinking, .running),
         ev(.approval, .pending), ev(.tool, .done), ev(.tool, .failed), ev(.approval, .allowed), ev(.user, nil),
         ev(.approval, .denied)]
    }

    func testCompletedClosesToolsAsDone() {
        let s = OpenWork.settle(events: open(), reason: .completed)
        XCTAssertEqual(s.map(\.state), [.done, .done, .done, .done, .expired])
    }

    func testEveryAbnormalPathFailsToolsAndExpiresApprovals() {
        for reason in [SettleReason.stopped, .failed, .processExited] {
            let s = OpenWork.settle(events: open(), reason: reason)
            XCTAssertEqual(s.map(\.state), [.failed, .failed, .done, .done, .expired], "\(reason)")
        }
    }

    func testSettleIsIdempotentAndNeverTouchesFinished() {
        var events = open()
        let first = OpenWork.settle(events: events, reason: .stopped)
        OpenWork.apply(first, to: &events)
        XCTAssertTrue(OpenWork.settle(events: events, reason: .processExited).isEmpty)
        XCTAssertEqual(events[5].state, .done)
        XCTAssertEqual(events[6].state, .failed)
        XCTAssertEqual(events[7].state, .allowed)
        XCTAssertEqual(events[0].state, .failed)
    }

    func testUnresolvedRequests() {
        XCTAssertEqual(OpenWork.unresolvedRequests(events: open()).count, 1)
        var events = open()
        OpenWork.apply(OpenWork.settle(events: events, reason: .completed), to: &events)
        XCTAssertTrue(OpenWork.unresolvedRequests(events: events).isEmpty)
    }

    // MARK: StopCoordinator

    func testStopSequenceOverTime() {
        var c = StopCoordinator()
        XCTAssertEqual(c.actions(now: t0), [])           // not begun
        c.begin(now: t0)
        XCTAssertEqual(c.actions(now: t0), [.sendInterrupt])
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(c.nextCheck(now: t0.addingTimeInterval(1)), t0.addingTimeInterval(2.5))
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(2.5)), [.closeInput])
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(3)), [])
        XCTAssertEqual(c.nextCheck(now: t0.addingTimeInterval(3)), t0.addingTimeInterval(10))
        XCTAssertFalse(c.isFinished)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(10)), [.forceFinalize])
        XCTAssertTrue(c.isFinished)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(20)), [])
        XCTAssertNil(c.nextCheck(now: t0.addingTimeInterval(20)))
    }

    func testLateFirstCheckEmitsEverythingOnceInOrder() {
        var c = StopCoordinator()
        c.begin(now: t0)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(60)), [.sendInterrupt, .closeInput, .forceFinalize])
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(61)), [])
    }

    func testEarlyTimeBeforeBeginDoesNothing() {
        var c = StopCoordinator()
        c.begin(now: t0)
        _ = c.actions(now: t0)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(-5)), [])
    }

    func testProcessExitFinishesImmediately() {
        var c = StopCoordinator()
        c.begin(now: t0)
        _ = c.actions(now: t0)
        c.processExited(now: t0.addingTimeInterval(1))
        XCTAssertTrue(c.isFinished)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(11)), [])
        XCTAssertNil(c.nextCheck(now: t0))
    }

    func testSecondBeginDoesNotRestartTheClock() {
        var c = StopCoordinator()
        c.begin(now: t0)
        c.begin(now: t0.addingTimeInterval(5))
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(10)), [.sendInterrupt, .closeInput, .forceFinalize])
    }

    func testStopBeforeTurnStartedCancelsPendingThenInterrupts() {
        var c = StopCoordinator(turnStarted: false)
        c.begin(now: t0)
        XCTAssertEqual(c.actions(now: t0), [.cancelPending])
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(1)), [])
        c.markTurnStarted()
        XCTAssertEqual(c.nextCheck(now: t0.addingTimeInterval(1)), t0.addingTimeInterval(1))
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(1)), [.sendInterrupt])
    }

    func testStopBeforeTurnStartedStillFinishes() {
        var c = StopCoordinator(turnStarted: false)
        c.begin(now: t0)
        XCTAssertEqual(c.actions(now: t0.addingTimeInterval(11)), [.cancelPending, .closeInput, .forceFinalize])
        XCTAssertTrue(c.isFinished)
    }

    // MARK: SessionApprovals

    func testGrantAndReset() {
        var a = SessionApprovals()
        XCTAssertFalse(a.isGranted(kind: .command, mode: .ask))
        a.grant(kind: .command, mode: .ask)
        a.grant(kind: .other("mcp"), mode: .ask)
        XCTAssertTrue(a.isGranted(kind: .command, mode: .ask))
        XCTAssertTrue(a.isGranted(kind: .other("mcp"), mode: .ask))
        XCTAssertFalse(a.isGranted(kind: .other("x"), mode: .ask))
        XCTAssertFalse(a.isGranted(kind: .fileChange, mode: .ask))
        XCTAssertFalse(a.isGranted(kind: .command, mode: .bypass))
        a.reset()
        XCTAssertFalse(a.isGranted(kind: .command, mode: .ask))
    }

    func testModeChangeDropsGrants() {
        var a = SessionApprovals()
        a.grant(kind: .command, mode: .ask)
        a.modeChanged(to: .ask)
        XCTAssertTrue(a.isGranted(kind: .command, mode: .ask))
        a.modeChanged(to: .acceptEdits)
        XCTAssertFalse(a.isGranted(kind: .command, mode: .acceptEdits))
        a.modeChanged(to: .ask)
        XCTAssertFalse(a.isGranted(kind: .command, mode: .ask))
        a.grant(kind: .permission, mode: .bypass)
        XCTAssertEqual(a.kinds, [.permission])
    }

    // MARK: BackgroundRoster

    func testRosterTracksPendingWork() {
        var r = BackgroundRoster()
        XCTAssertFalse(r.hasPending)
        r.start("a", kind: .subagent)
        r.start("a", kind: .subagent)
        r.start("m", kind: .monitor)
        XCTAssertEqual(r.pendingCount, 2)
        XCTAssertEqual(r.pendingCount(of: .monitor), 1)
        r.finish("a")
        r.finish("a")
        XCTAssertEqual(r.pendingCount, 1)
        XCTAssertTrue(r.hasPending)
        r.finish("m")
        XCTAssertFalse(r.hasPending)
    }

    func testForegroundCommandsDoNotCount() {
        var r = BackgroundRoster()
        r.start("c", kind: .command, background: false)
        XCTAssertFalse(r.hasPending)
        r.start("c", kind: .command)
        XCTAssertTrue(r.hasPending)
    }

    func testCancelAllReturnsIdsInOrder() {
        var r = BackgroundRoster()
        XCTAssertEqual(r.cancelAll(reason: .stopped), [])
        r.start("b", kind: .other)
        r.start("a", kind: .command)
        XCTAssertEqual(r.cancelAll(reason: .stopped), ["b", "a"])
        XCTAssertFalse(r.hasPending)
        XCTAssertEqual(r.lastCancelReason, .stopped)
        XCTAssertEqual(r.cancelAll(reason: .processExited), [])
    }
}
