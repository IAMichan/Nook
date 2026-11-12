import XCTest

/// When `.nookTip` opens and closes: a short rest first, then instant swaps while the pointer moves on.
final class TooltipTimingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_536_800)

    func testColdEnterWaitsForTheOpenDelay() {
        var timing = TooltipTiming()
        XCTAssertEqual(timing.enter("a", now: start), .showAfter(.milliseconds(150)))
        XCTAssertTrue(timing.fire("a"))
        XCTAssertEqual(timing.shownID, AnyHashable("a"))
    }

    func testReenterWithinTheWarmWindowShowsAtOnce() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        XCTAssertTrue(timing.fire("a"))
        XCTAssertEqual(timing.exit("a", now: start.addingTimeInterval(1)), .hide)
        XCTAssertEqual(timing.enter("b", now: start.addingTimeInterval(1.3)), .showNow(animated: false))
        XCTAssertEqual(timing.shownID, AnyHashable("b"))
    }

    func testReenterAfterTheWarmWindowWaitsAgain() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        XCTAssertTrue(timing.fire("a"))
        XCTAssertEqual(timing.exit("a", now: start.addingTimeInterval(1)), .hide)
        XCTAssertEqual(timing.enter("b", now: start.addingTimeInterval(1.5)), .showAfter(TooltipTiming.openDelay))
    }

    func testEnteringAnotherViewWhileATipIsShownSwapsAtOnce() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        XCTAssertTrue(timing.fire("a"))
        // The pointer reaches the next view before the first one reports it left.
        XCTAssertEqual(timing.enter("b", now: start.addingTimeInterval(2)), .showNow(animated: false))
        XCTAssertEqual(timing.exit("a", now: start.addingTimeInterval(2)), .keep)
        XCTAssertEqual(timing.shownID, AnyHashable("b"))
    }

    func testLeavingBeforeTheDelayDropsThePendingOpen() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        XCTAssertEqual(timing.exit("a", now: start.addingTimeInterval(0.1)), .hide)
        XCTAssertFalse(timing.fire("a"))
        // Nothing was shown, so the next view is not warm.
        XCTAssertEqual(timing.enter("b", now: start.addingTimeInterval(0.2)), .showAfter(TooltipTiming.openDelay))
    }

    func testAPendingOpenReplacedByAnotherViewDoesNotFire() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        _ = timing.enter("b", now: start.addingTimeInterval(0.05))
        XCTAssertFalse(timing.fire("a"))
        XCTAssertTrue(timing.fire("b"))
    }

    func testCancelAllClearsPendingAndShownAndEndsTheWarmStreak() {
        var timing = TooltipTiming()
        _ = timing.enter("a", now: start)
        timing.cancelAll(now: start.addingTimeInterval(0.1))
        XCTAssertFalse(timing.fire("a"))
        XCTAssertFalse(timing.isActive)

        _ = timing.enter("b", now: start.addingTimeInterval(1))
        XCTAssertTrue(timing.fire("b"))
        timing.cancelAll(now: start.addingTimeInterval(1.2))
        XCTAssertNil(timing.shownID)
        XCTAssertEqual(timing.exit("b", now: start.addingTimeInterval(1.25)), .keep)
        XCTAssertEqual(timing.enter("c", now: start.addingTimeInterval(1.3)), .showAfter(TooltipTiming.openDelay))
    }
}
