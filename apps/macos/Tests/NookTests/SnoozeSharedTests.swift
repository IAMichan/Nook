import XCTest

/// Sessions and chats snooze to the same options (`SnoozeOption`).
final class SnoozeSharedTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ hour: Int, day: Int = 9) -> Date {
        // 9 November 2026 is a Monday.
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testAgentChoicesAreSnoozeOptions() {
        XCTAssertEqual(SnoozePolicy.Choice.hour.option, .duration(minutes: 60))
        XCTAssertEqual(SnoozePolicy.Choice.evening.end(from: date(19), calendar: calendar), date(18, day: 10))
        for choice in SnoozePolicy.Choice.allCases {
            XCTAssertTrue(SnoozeOption.defaults.contains(choice.option), choice.rawValue)
        }
    }

    func testChatLaterOptionsAreSnoozeOptions() {
        XCTAssertEqual(ChatLaterOption.thisEvening.date(from: date(10), calendar: calendar), date(18))
        XCTAssertEqual(ChatLaterOption.thisEvening.date(from: date(20), calendar: calendar), date(18, day: 10))
        XCTAssertEqual(ChatLaterOption.tomorrowMorning.date(from: date(23), calendar: calendar), date(9, day: 10))
        // Next week on a Monday is a week ahead, as the session menu says it.
        XCTAssertEqual(ChatLaterOption.nextWeek.date(from: date(8), calendar: calendar), date(9, day: 16))
        for option in ChatLaterOption.allCases {
            XCTAssertEqual(option.date(from: date(10), calendar: calendar), option.option.end(from: date(10), calendar: calendar))
        }
    }
}
