import XCTest

final class PullRequestQuickMergeQueueTests: XCTestCase {
    func testMergesGoOneAtATimeInTheOrderGiven() {
        var queue = PullRequestQuickMergeQueue()
        XCTAssertTrue(queue.add("a#1"))
        XCTAssertTrue(queue.add("b#2"))
        XCTAssertEqual(queue.next(), "a#1")
        XCTAssertNil(queue.next(), "one at GitHub at a time")
        XCTAssertEqual(queue.phase("a#1"), .merging)
        XCTAssertEqual(queue.phase("b#2"), .waiting)
        XCTAssertNil(queue.drain(), "not done yet")
        queue.finish(success: true)
        XCTAssertEqual(queue.phase("a#1"), .merged)
        XCTAssertEqual(queue.next(), "b#2")
        queue.finish(success: false)
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.isIdle)
        let result = queue.drain()
        XCTAssertEqual(result?.merged, ["a#1"])
        XCTAssertEqual(result?.failed, 1)
        XCTAssertNil(queue.phase("a#1"))
        XCTAssertNil(queue.drain())
    }

    func testAPullRequestIsQueuedOnce() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1")
        XCTAssertFalse(queue.add("a#1"))
        _ = queue.next()
        XCTAssertFalse(queue.add("a#1"), "at GitHub")
        queue.finish(success: true)
        XCTAssertFalse(queue.add("a#1"), "just merged, until the list is read again")
        XCTAssertTrue(queue.waiting.isEmpty)
    }
}
