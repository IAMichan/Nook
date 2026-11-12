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

    func testAHeldBackPullRequestGetsAutoMerge() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1")
        queue.add("b#2")
        _ = queue.next()
        queue.finishAutoMerge()
        XCTAssertEqual(queue.phase("a#1"), .autoMerge)
        XCTAssertTrue(queue.changed, "the list is read again")
        _ = queue.next()
        queue.finish(success: true)
        let result = queue.drain()
        XCTAssertEqual(result?.merged, ["b#2"])
        XCTAssertEqual(result?.autoMerged, ["a#1"])
        XCTAssertEqual(result?.failed, 0)
        XCTAssertNil(queue.phase("a#1"))
    }

    func testAWaitingMergeComesOutOfTheQueue() {
        var queue = PullRequestQuickMergeQueue()
        queue.add("a#1")
        queue.add("b#2")
        queue.add("c#3")
        XCTAssertEqual(queue.next(), "a#1")
        XCTAssertFalse(queue.remove("a#1"), "one at GitHub goes on")
        XCTAssertTrue(queue.remove("b#2"))
        XCTAssertNil(queue.phase("b#2"))
        queue.finish(success: true)
        XCTAssertEqual(queue.next(), "c#3", "the next one skips the removed one")
        XCTAssertFalse(queue.remove("x#9"))
        XCTAssertTrue(queue.add("b#2"), "and can be queued again")
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

    func testTheListSaysWhichPullRequestsWillNotMerge() {
        func item(draft: Bool = false, state: PullRequestItem.State = .open) -> PullRequestItem {
            PullRequestItem(repo: "acme/app", number: 1, title: "T", url: nil, draft: draft, updated: nil, author: "ada", state: state)
        }
        XCTAssertNil(PullRequestQuickAction.mergeBlocker(item()))
        XCTAssertEqual(PullRequestQuickAction.mergeBlocker(item(draft: true)), "agents.pulls.quick.blocked.draft")
        XCTAssertEqual(PullRequestQuickAction.mergeBlocker(item(state: .merged)), "agents.pulls.quick.blocked.merged")
        XCTAssertEqual(PullRequestQuickAction.mergeBlocker(item(state: .closed)), "agents.pulls.quick.blocked.closed")
        var conflicted = item()
        conflicted.conflict = true
        XCTAssertEqual(PullRequestQuickAction.mergeBlocker(conflicted), "agents.pulls.quick.blocked.conflict")
        var failing = item()
        failing.ci = .failing
        XCTAssertNil(PullRequestQuickAction.mergeBlocker(failing), "Failing checks are GitHub's call: an admin may merge past them")
    }
}
