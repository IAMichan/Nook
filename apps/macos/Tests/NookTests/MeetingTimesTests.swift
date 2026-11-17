import XCTest

final class MeetingTimesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    /// Monday 2026-11-16 at the given time, Amsterdam.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func busy(_ day: Int, _ from: Int, _ to: Int) -> MeetingTimes.Busy {
        MeetingTimes.Busy(start: at(day, from), end: at(day, to))
    }

    func testOneOptionPerDayFirst() {
        let request = MeetingTimes.Request(from: at(16, 0), to: at(19, 0), duration: 3600)
        let slots = MeetingTimes.find(request, busy: [busy(16, 9, 11)], now: at(16, 8), calendar: calendar)
        XCTAssertEqual(slots.map(\.start), [at(16, 11), at(17, 9), at(18, 9)])
        XCTAssertEqual(slots.first?.end, at(16, 12))
    }

    func testNothingStartsBeforeNowAndStartsSitOnTheQuarterHour() {
        let request = MeetingTimes.Request(from: at(16, 0), to: at(17, 0), duration: 1800, count: 1)
        let slots = MeetingTimes.find(request, busy: [], now: at(16, 13, 7), calendar: calendar)
        XCTAssertEqual(slots.map(\.start), [at(16, 13, 15)])
    }

    func testBufferKeepsTimeAroundOtherAppointments() {
        var request = MeetingTimes.Request(from: at(16, 0), to: at(17, 0), duration: 3600, count: 1)
        request.buffer = 30 * 60
        let slots = MeetingTimes.find(request, busy: [busy(16, 9, 10)], now: at(16, 0), calendar: calendar)
        XCTAssertEqual(slots.map(\.start), [at(16, 10, 30)])
    }

    func testSkipsWeekendsUnlessAsked() {
        // Saturday 21 and Sunday 22 November.
        var request = MeetingTimes.Request(from: at(21, 0), to: at(23, 0), duration: 3600, count: 2)
        XCTAssertTrue(MeetingTimes.find(request, busy: [], now: at(16, 0), calendar: calendar).isEmpty)
        request.weekends = true
        XCTAssertEqual(MeetingTimes.find(request, busy: [], now: at(16, 0), calendar: calendar).map(\.start), [at(21, 9), at(22, 9)])
    }

    func testPrefersThePartOfTheDayAsked() {
        var request = MeetingTimes.Request(from: at(16, 0), to: at(17, 0), duration: 3600, count: 1)
        request.preference = .afternoon
        XCTAssertEqual(MeetingTimes.find(request, busy: [], now: at(16, 0), calendar: calendar).map(\.start), [at(16, 12)])
        // A day without afternoon room still offers its morning.
        let full = MeetingTimes.find(request, busy: [busy(16, 12, 18)], now: at(16, 0), calendar: calendar)
        XCTAssertEqual(full.map(\.start), [at(16, 9)])
    }

    func testFillsUpTheSameDayWithoutOverlap() {
        let request = MeetingTimes.Request(from: at(16, 0), to: at(17, 0), duration: 3600, count: 3)
        let slots = MeetingTimes.find(request, busy: [busy(16, 10, 17)], now: at(16, 0), calendar: calendar)
        XCTAssertEqual(slots.map(\.start), [at(16, 9), at(16, 17)])
    }

    func testOverlappingBusyTimesMerge() {
        let merged = MeetingTimes.merge([busy(16, 9, 11), busy(16, 10, 12), busy(16, 14, 15)])
        XCTAssertEqual(merged, [busy(16, 9, 12), busy(16, 14, 15)])
    }

    func testReadsClockTimes() {
        XCTAssertEqual(MeetingTimes.minutes("09:30"), 570)
        XCTAssertEqual(MeetingTimes.minutes("18"), 1080)
        XCTAssertNil(MeetingTimes.minutes("late"))
        XCTAssertEqual(MeetingTimes.Preference(text: "Morning"), .morning)
        XCTAssertEqual(MeetingTimes.Preference(text: nil), .any)
    }
}
