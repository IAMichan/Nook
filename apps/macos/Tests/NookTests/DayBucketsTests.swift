import XCTest

/// The Today / Yesterday / Previous 7 days / Older groups of the conversation list.
final class DayBucketsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wednesday 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_760_536_800)

    private func ago(days: Int, hours: Int = 0) -> Date {
        now.addingTimeInterval(-Double(days * 86_400 + hours * 3_600))
    }

    func testBucketsByCalendarDay() {
        XCTAssertEqual(DayBucket.bucket(for: now, now: now, calendar: calendar), .today)
        XCTAssertEqual(DayBucket.bucket(for: ago(days: 0, hours: 1), now: now, calendar: calendar), .today)
        XCTAssertEqual(DayBucket.bucket(for: ago(days: 1), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(DayBucket.bucket(for: ago(days: 2), now: now, calendar: calendar), .previousWeek)
        XCTAssertEqual(DayBucket.bucket(for: ago(days: 7), now: now, calendar: calendar), .previousWeek)
        XCTAssertEqual(DayBucket.bucket(for: ago(days: 30), now: now, calendar: calendar), .older)
    }

    func testFutureDateCountsAsToday() {
        XCTAssertEqual(DayBucket.bucket(for: now.addingTimeInterval(3_600), now: now, calendar: calendar), .today)
    }

    func testGroupKeepsOrderAndSkipsEmptyGroups() {
        let dates = [ago(days: 0, hours: 2), ago(days: 0, hours: 3), ago(days: 20), ago(days: 40)]
        let groups = DayBucket.group(dates, date: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.bucket), [.today, .older])
        XCTAssertEqual(groups[0].items, [dates[0], dates[1]])
        XCTAssertEqual(groups[1].items, [dates[2], dates[3]])
    }

    func testEveryGroupHasAName() {
        for bucket in DayBucket.allCases {
            XCTAssertFalse(tr(bucket.titleKey).isEmpty)
            XCTAssertNotEqual(tr(bucket.titleKey), bucket.titleKey, "\(bucket.titleKey) is not translated")
        }
    }
}
