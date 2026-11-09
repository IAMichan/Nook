import XCTest

/// Sessions working at once: past the limit a new turn waits, and waiting turns start oldest first as places free up.
final class SessionCapacityTests: XCTestCase {
    func testNoLimitNeverWaits() {
        XCTAssertFalse(SessionCapacity.mustWait(limit: 0, othersWorking: 50))
        XCTAssertEqual(SessionCapacity.startable(limit: 0, working: 50, waiting: 3), 3)
    }

    func testATurnWaitsOnceTheLimitIsReached() {
        XCTAssertFalse(SessionCapacity.mustWait(limit: 3, othersWorking: 2))
        XCTAssertTrue(SessionCapacity.mustWait(limit: 3, othersWorking: 3))
        XCTAssertTrue(SessionCapacity.mustWait(limit: 3, othersWorking: 5), "a lower limit set while more work lets none in")
    }

    func testWaitingTurnsStartAsPlacesFreeUp() {
        XCTAssertEqual(SessionCapacity.startable(limit: 3, working: 3, waiting: 2), 0)
        XCTAssertEqual(SessionCapacity.startable(limit: 3, working: 2, waiting: 2), 1)
        XCTAssertEqual(SessionCapacity.startable(limit: 4, working: 0, waiting: 2), 2)
        XCTAssertEqual(SessionCapacity.startable(limit: 2, working: 5, waiting: 2), 0)
        XCTAssertEqual(SessionCapacity.startable(limit: 2, working: 0, waiting: 0), 0)
        XCTAssertEqual(SessionCapacity.choices.first, 0, "no limit is the default choice")
    }
}
