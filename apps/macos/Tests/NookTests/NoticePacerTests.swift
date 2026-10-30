import XCTest

/// How notices keep their distance (`NoticePacer`): a gap between any two, one thing once in a while, a cap on a burst,
/// and what waits on you always through.
final class NoticePacerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTwoNoticesKeepAGap() {
        var pacer = NoticePacer()
        XCTAssertTrue(pacer.allow(key: "agent:a", now: start))
        XCTAssertFalse(pacer.allow(key: "agent:b", now: start.addingTimeInterval(5)))
        XCTAssertTrue(pacer.allow(key: "agent:b", now: start.addingTimeInterval(NoticePacer.gap)))
    }

    func testOneThingPopsUpOnceInAWhile() {
        var pacer = NoticePacer()
        XCTAssertTrue(pacer.allow(key: "chat:anna", now: start))
        XCTAssertFalse(pacer.allow(key: "chat:anna", now: start.addingTimeInterval(60)))
        XCTAssertTrue(pacer.allow(key: "chat:anna", now: start.addingTimeInterval(NoticePacer.sameKeyGap)))
    }

    func testABurstEndsInTheList() {
        var pacer = NoticePacer()
        for index in 0..<NoticePacer.burstLimit {
            XCTAssertTrue(pacer.allow(key: "agent:\(index)", now: start.addingTimeInterval(Double(index) * 30)))
        }
        let later = start.addingTimeInterval(Double(NoticePacer.burstLimit) * 30)
        XCTAssertFalse(pacer.allow(key: "agent:new", now: later))
        XCTAssertTrue(pacer.allow(key: "agent:new", now: start.addingTimeInterval(NoticePacer.burstWindow + 1)))
    }

    func testWhatWaitsOnYouAlwaysGetsThrough() {
        var pacer = NoticePacer()
        XCTAssertTrue(pacer.allow(key: "agent:a", now: start))
        XCTAssertTrue(pacer.allow(key: "agent:a", urgent: true, now: start.addingTimeInterval(1)))
    }

    func testASuggestionWaitsForACalmNotch() {
        var pacer = NoticePacer()
        XCTAssertTrue(pacer.allow(key: "agent:a", now: start))
        XCTAssertFalse(pacer.permits(key: "suggestion", calm: 300, now: start.addingTimeInterval(120)))
        XCTAssertTrue(pacer.permits(key: "suggestion", calm: 300, now: start.addingTimeInterval(300)))
    }

    func testAskingDoesNotCount() {
        var pacer = NoticePacer()
        XCTAssertTrue(pacer.permits(key: "agent:a", now: start))
        XCTAssertTrue(pacer.allow(key: "agent:a", now: start))
    }
}
