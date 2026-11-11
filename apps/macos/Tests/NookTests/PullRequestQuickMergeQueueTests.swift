import XCTest

final class PullRequestQuickMergeQueueTests: XCTestCase {
    func testTheFirstMergeOfAHoldAsksAndTheRestGoOnOneClick() {
        var queue = PullRequestQuickMergeQueue()
        XCTAssertFalse(queue.add("a#1", confirmed: false), "the first click only arms the button")
        XCTAssertNil(queue.phase("a#1"))
        XCTAssertTrue(queue.add("a#1", confirmed: true))
        XCTAssertTrue(queue.unlocked)
        XCTAssertTrue(queue.add("a#2", confirmed: false), "one click while Shift is still held")
        XCTAssertTrue(queue.add("b#3", confirmed: false))
        XCTAssertEqual(queue.waiting, ["a#1", "a#2", "b#3"])
    }

    func testLettingGoOfShiftAsksAgainButKeepsTheQueue() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1", confirmed: true)
        queue.add("a#2", confirmed: false)
        queue.shiftReleased()
        XCTAssertFalse(queue.add("a#3", confirmed: false))
        XCTAssertEqual(queue.waiting, ["a#1", "a#2"])
    }

    func testMergesGoOneAtATimeInClickOrder() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1", confirmed: true)
        queue.add("a#2", confirmed: false)
        XCTAssertEqual(queue.next(), "a#1")
        XCTAssertNil(queue.next(), "one at GitHub at a time")
        XCTAssertEqual(queue.phase("a#1"), .merging)
        XCTAssertEqual(queue.phase("a#2"), .waiting)
        XCTAssertNil(queue.drain(), "not done yet")
        queue.finish(success: true)
        XCTAssertEqual(queue.phase("a#1"), .merged)
        XCTAssertEqual(queue.next(), "a#2")
        queue.finish(success: false)
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.isIdle)
        let result = queue.drain()
        XCTAssertEqual(result?.merged, ["a#1"])
        XCTAssertEqual(result?.failed, 1)
        XCTAssertNil(queue.phase("a#1"))
        XCTAssertNil(queue.drain())
    }

    func testAClickOnAQueuedOrMergedRowAddsNothing() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1", confirmed: true)
        XCTAssertFalse(queue.add("a#1", confirmed: false))
        _ = queue.next()
        queue.finish(success: true)
        XCTAssertFalse(queue.add("a#1", confirmed: false))
        XCTAssertTrue(queue.waiting.isEmpty)
    }
}
