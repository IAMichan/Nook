import XCTest

/// The light ticks while an answer streams in on the phone (`apps/ios/Core/StreamCadence.swift`).
final class StreamCadenceTests: XCTestCase {
    func testTicksAtMostEveryIntervalWhileItWorks() {
        let opened = Date(timeIntervalSince1970: 0)
        var cadence = StreamCadence(openedAt: opened)
        XCTAssertTrue(cadence.tick(working: true, now: opened.addingTimeInterval(2)))
        XCTAssertFalse(cadence.tick(working: true, now: opened.addingTimeInterval(2.1)), "too soon after the last")
        XCTAssertTrue(cadence.tick(working: true, now: opened.addingTimeInterval(2 + StreamCadence.interval)))
    }

    func testStaysQuietRightAfterOpeningAndWhileNothingWorks() {
        let opened = Date(timeIntervalSince1970: 0)
        var cadence = StreamCadence(openedAt: opened)
        XCTAssertFalse(cadence.tick(working: true, now: opened.addingTimeInterval(0.5)), "opening a session that streams")
        XCTAssertFalse(cadence.tick(working: false, now: opened.addingTimeInterval(5)))
    }
}
