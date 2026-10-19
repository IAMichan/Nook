import XCTest

/// Dates as the brain reads them: a reminder next year must not look like one coming up.
final class NookDatesTests: XCTestCase {
    private let now = NookDates.parse("2026-10-19T10:00:00")!

    func testDistanceCountsWholeDays() {
        XCTAssertEqual(NookDates.distance(NookDates.parse("2026-10-19T23:00:00")!, now: now), "today")
        XCTAssertEqual(NookDates.distance(NookDates.parse("2026-10-20T08:00:00")!, now: now), "tomorrow")
        XCTAssertEqual(NookDates.distance(NookDates.parse("2026-10-16T08:00:00")!, now: now), "3 days ago")
        XCTAssertEqual(NookDates.distance(NookDates.parse("2027-10-20T08:00:00")!, now: now), "in 366 days", "same day and month, next year")
    }

    func testShortShowsTheYearOnlyWhenItDiffers() {
        XCTAssertFalse(NookDates.short(NookDates.parse("2026-10-20T14:00:00")!, now: now).contains("2026"))
        XCTAssertTrue(NookDates.short(NookDates.parse("2027-10-20T14:00:00")!, now: now).contains("2027"))
    }
}
