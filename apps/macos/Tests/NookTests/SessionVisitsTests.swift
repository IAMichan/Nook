// Counts publishes through Combine, which Linux (scripts/core-tests.sh) does not have.
#if canImport(Combine)
import XCTest
import Combine

@MainActor
final class SessionVisitsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "session-visits-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func publishes(_ visits: SessionVisits, during body: () -> Void) -> Int {
        var count = 0
        let sink = visits.objectWillChange.sink { count += 1 }
        body()
        sink.cancel()
        return count
    }

    /// Opening the same session twice in a row (the list and the view model both record it) publishes once.
    func testRepeatVisitWithinASecondPublishesOnce() {
        let visits = SessionVisits(defaults: defaults)
        let now = Date()
        let count = publishes(visits) {
            visits.visit("run:a", at: now)
            visits.visit("run:a", at: now.addingTimeInterval(0.5))
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(publishes(visits) { visits.visit("run:a", at: now.addingTimeInterval(2)) }, 1, "a later visit counts")
    }

    func testBatchVisitPublishesOnce() {
        let visits = SessionVisits(defaults: defaults)
        let finished = Date()
        let count = publishes(visits) { visits.visit(["a", "b", "c", ""], at: finished.addingTimeInterval(10)) }
        XCTAssertEqual(count, 1)
        for id in ["a", "b", "c"] { XCTAssertFalse(visits.isUnseen(id, finished: finished)) }
    }

    /// A visit is written after a short wait (or on flush); "mark as unread" is written at once.
    func testVisitWriteWaitsAndUnreadWritesAtOnce() {
        let visits = SessionVisits(defaults: defaults)
        visits.visit("a")
        XCTAssertNil(defaults.dictionary(forKey: "agents.visits")?["a"], "not written yet")
        visits.flush()
        XCTAssertNotNil(defaults.dictionary(forKey: "agents.visits")?["a"])

        visits.markUnread("b")
        XCTAssertEqual(defaults.dictionary(forKey: "agents.visits")?["b"] as? Double, 0)
    }
}
#endif
