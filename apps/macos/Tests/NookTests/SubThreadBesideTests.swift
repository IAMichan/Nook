import XCTest

final class SubThreadBesideTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()

    func testRowOpensItsSubThreadBesideTheMainThread() {
        XCTAssertEqual(SubThreadBeside.action(for: a, shown: nil, hasRoom: true, here: false), .beside(a))
    }

    func testAnotherRowSwapsTheSubThreadBeside() {
        XCTAssertEqual(SubThreadBeside.action(for: b, shown: a, hasRoom: true, here: false), .beside(b))
    }

    func testTheOpenRowClosesItAgain() {
        XCTAssertEqual(SubThreadBeside.action(for: a, shown: a, hasRoom: true, here: false), .close)
    }

    func testCommandClickOpensItInPlaceOfTheMainThread() {
        XCTAssertEqual(SubThreadBeside.action(for: a, shown: nil, hasRoom: true, here: true), .here(a))
        XCTAssertEqual(SubThreadBeside.action(for: a, shown: a, hasRoom: true, here: true), .here(a))
    }

    func testWithoutRoomBesideItOpensInPlaceOfTheMainThread() {
        XCTAssertEqual(SubThreadBeside.action(for: a, shown: nil, hasRoom: false, here: false), .here(a))
    }

    func testTabBelongsOnlyToTheSessionThatDelegatedIt() {
        let parent = UUID()
        XCTAssertTrue(SubThreadBeside.belongs(a, to: parent, children: [b, a]))
        XCTAssertFalse(SubThreadBeside.belongs(a, to: parent, children: [b]))
        XCTAssertFalse(SubThreadBeside.belongs(a, to: nil, children: [a]))
        XCTAssertFalse(SubThreadBeside.belongs(nil, to: parent, children: [a]))
    }
}

final class SubThreadStatsTests: XCTestCase {
    func testDurationCountsUpWhileItWorks() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SubThreadStats.worked(started: start, lastStep: start.addingTimeInterval(5), active: true,
                                             now: start.addingTimeInterval(252)), 252)
    }

    func testEndedSubThreadShowsItsTotalUpToItsLastStep() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SubThreadStats.worked(started: start, lastStep: start.addingTimeInterval(90), active: false,
                                             now: start.addingTimeInterval(9999)), 90)
        XCTAssertEqual(SubThreadStats.worked(started: start, lastStep: nil, active: false, now: start.addingTimeInterval(50)), 0)
    }

    func testClockShowsSecondsThenMinutesThenHours() {
        XCTAssertEqual(SubThreadStats.clock(42).key, "ws.subthread.clock.seconds")
        XCTAssertEqual(SubThreadStats.clock(42).values, [42])
        XCTAssertEqual(SubThreadStats.clock(252).key, "ws.subthread.clock.minutes")
        XCTAssertEqual(SubThreadStats.clock(252).values, [4, 12])
        XCTAssertEqual(SubThreadStats.clock(3900).key, "ws.subthread.clock.hours")
        XCTAssertEqual(SubThreadStats.clock(3900).values, [1, 5])
        XCTAssertEqual(SubThreadStats.clock(-3).values, [0])
    }
}
