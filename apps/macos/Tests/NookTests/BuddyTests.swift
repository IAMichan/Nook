import XCTest

/// Nook as a buddy: when he shares a moment (`BuddyPlanner`, `BuddyActivity`, `BuddyLedger`). All of it pure, so the
/// clock, the calendar and the signals come from the test.
final class BuddyTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Birthday

    func testABirthdayOnLeapDayIsCelebratedOnTheTwentyEighth() {
        let leap = NookMonthDay(month: 2, day: 29)!
        XCTAssertTrue(leap.matches(date(2027, 2, 28, 12), calendar: calendar))
        XCTAssertFalse(leap.matches(date(2028, 2, 28, 12), calendar: calendar))
        XCTAssertTrue(leap.matches(date(2028, 2, 29, 12), calendar: calendar))
        XCTAssertEqual(NookMonthDay(stored: "06-12"), NookMonthDay(month: 6, day: 12))
        XCTAssertNil(NookMonthDay(stored: "00-12"))
        XCTAssertNil(NookMonthDay(stored: ""))
    }

    // MARK: Activity

    func testComingBackAfterALongBreakIsNoticedAndStartsANewStretch() {
        var activity = BuddyActivity()
        let start = date(2026, 5, 6, 9)
        // Half an hour of work, sampled every half minute.
        for step in 0...60 {
            activity.note(idle: 0, at: start.addingTimeInterval(Double(step) * 30), calendar: calendar)
        }
        XCTAssertEqual(activity.stretch(at: start.addingTimeInterval(30 * 60)), 30 * 60, accuracy: 1)
        // Away for an hour: samples with a long idle time do not count.
        activity.note(idle: 20 * 60, at: start.addingTimeInterval(50 * 60), calendar: calendar)
        let back = start.addingTimeInterval(90 * 60)
        activity.note(idle: 0, at: back, calendar: calendar)
        XCTAssertEqual(activity.justReturned(at: back) ?? 0, 60 * 60, accuracy: 1)
        XCTAssertEqual(activity.stretch(at: back), 0, accuracy: 1)
        XCTAssertNil(activity.justReturned(at: back.addingTimeInterval(20 * 60)))
    }

    func testTheFirstActivityOfTheDayIsNoticedOnce() {
        var activity = BuddyActivity()
        activity.note(idle: 0, at: date(2026, 5, 6, 22), calendar: calendar)
        let morning = date(2026, 5, 7, 8, 10)
        activity.note(idle: 0, at: morning, calendar: calendar)
        XCTAssertTrue(activity.justStartedDay(at: morning, calendar: calendar))
        XCTAssertFalse(activity.justStartedDay(at: morning.addingTimeInterval(40 * 60), calendar: calendar))
    }

    // MARK: Moments

    private func signals(_ now: Date) -> BuddyPlanner.Signals {
        var signals = BuddyPlanner.Signals(now: now)
        signals.calendar = calendar
        return signals
    }

    func testGoodMorningWithTheDaysEvents() {
        var morning = signals(date(2026, 5, 6, 8, 30))
        morning.firstOfDay = true
        morning.eventsToday = 3
        let moment = BuddyPlanner.next(morning, ledger: BuddyLedger())
        XCTAssertEqual(moment?.kind, .morning)
        XCTAssertEqual(moment?.count, 3)
        XCTAssertEqual(moment.map { BuddyPlanner.lineKey($0, tone: .warm) }, "buddy.morning.many.warm")
        // Not in the afternoon.
        var afternoon = signals(date(2026, 5, 6, 14))
        afternoon.firstOfDay = true
        XCTAssertNil(BuddyPlanner.next(afternoon, ledger: BuddyLedger()))
    }

    func testQuietDuringAMeetingWhenTheNotchIsBusyOrWhenYouAreAway() {
        var morning = signals(date(2026, 5, 6, 8, 30))
        morning.firstOfDay = true
        for change in [{ (s: inout BuddyPlanner.Signals) in s.inEvent = true },
                       { (s: inout BuddyPlanner.Signals) in s.notchFree = false },
                       { (s: inout BuddyPlanner.Signals) in s.active = false }] {
            var quiet = morning
            change(&quiet)
            XCTAssertNil(BuddyPlanner.next(quiet, ledger: BuddyLedger()))
        }
    }

    func testEachMomentOnlyOnceAndNeverTwoCloseTogether() {
        let now = date(2026, 5, 6, 8, 30)
        var morning = signals(now)
        morning.firstOfDay = true
        var ledger = BuddyLedger()
        ledger.roll(to: BuddyActivity.dayKey(now, calendar: calendar))
        let moment = BuddyPlanner.next(morning, ledger: ledger)!
        ledger.record(moment, at: now)
        // A minute later: too soon for anything.
        var soon = signals(now.addingTimeInterval(60))
        soon.returnedAfter = 3600
        XCTAssertNil(BuddyPlanner.next(soon, ledger: ledger))
        // Half an hour later: the morning greeting is not repeated, but the welcome back may come.
        var later = signals(now.addingTimeInterval(30 * 60))
        later.firstOfDay = true
        XCTAssertNil(BuddyPlanner.next(later, ledger: ledger))
        later.firstOfDay = false
        later.returnedAfter = 3600
        later.finishedWhileAway = 2
        let welcome = BuddyPlanner.next(later, ledger: ledger)
        XCTAssertEqual(welcome?.kind, .welcomeBack)
        XCTAssertEqual(welcome.map { BuddyPlanner.lineKey($0, tone: .playful) }, "buddy.welcomeBack.many.playful")
    }

    func testNoMoreThanTheDailyBudget() {
        let now = date(2026, 5, 6, 15)
        var ledger = BuddyLedger()
        ledger.roll(to: BuddyActivity.dayKey(now, calendar: calendar))
        ledger.shownToday = ["morning@x", "welcomeBack@x#0", "breakTime@x#0", "welcomeBack@x#1"]
        var tired = signals(now)
        tired.stretch = 3 * 3600
        XCTAssertNil(BuddyPlanner.next(tired, ledger: ledger))
        // A new day brings a new budget.
        var tomorrow = signals(now.addingTimeInterval(24 * 3600))
        tomorrow.stretch = 3 * 3600
        XCTAssertEqual(BuddyPlanner.next(tomorrow, ledger: ledger)?.kind, .breakTime)
    }

    func testABreakAfterAnHourAndAHalfDuringTheDay() {
        var working = signals(date(2026, 5, 6, 15))
        working.stretch = 95 * 60
        let moment = BuddyPlanner.next(working, ledger: BuddyLedger())
        XCTAssertEqual(moment?.kind, .breakTime)
        XCTAssertEqual(moment?.minutes, 95)
        working.stretch = 60 * 60
        XCTAssertNil(BuddyPlanner.next(working, ledger: BuddyLedger()))
    }

    func testLateNightOncePerNightAcrossMidnight() {
        let evening = date(2026, 5, 6, 23, 20)
        var ledger = BuddyLedger()
        let moment = BuddyPlanner.next(signals(evening), ledger: ledger)
        XCTAssertEqual(moment?.kind, .lateNight)
        ledger.roll(to: BuddyActivity.dayKey(evening, calendar: calendar))
        ledger.record(moment!, at: evening)
        // After midnight it is a new day, but the same night.
        XCTAssertNil(BuddyPlanner.next(signals(date(2026, 5, 7, 0, 50)), ledger: ledger))
    }

    func testMilestonesAreCelebratedOnceAndOnlyWhenFresh() {
        var finishing = signals(date(2026, 5, 6, 11))
        finishing.finishedTotal = 10
        var ledger = BuddyLedger()
        let moment = BuddyPlanner.next(finishing, ledger: ledger)
        XCTAssertEqual(moment?.kind, .milestone)
        XCTAssertEqual(moment?.count, 10)
        ledger.record(moment!, at: finishing.now.addingTimeInterval(-3600))
        finishing.finishedTotal = 11
        XCTAssertNil(BuddyPlanner.next(finishing, ledger: ledger))
        // Far past a milestone that was never seen (counting started later): not worth a party any more.
        finishing.finishedTotal = 31
        XCTAssertNotEqual(BuddyPlanner.next(finishing, ledger: BuddyLedger())?.kind, .milestone)
    }

    func testABirthdayComesFirst() {
        var birthday = signals(date(2026, 6, 12, 8, 30))
        birthday.birthday = NookMonthDay(month: 6, day: 12)
        birthday.firstOfDay = true
        XCTAssertEqual(BuddyPlanner.next(birthday, ledger: BuddyLedger())?.kind, .birthday)
    }

    func testTheLedgerSurvivesStorage() {
        var ledger = BuddyLedger()
        ledger.roll(to: "2026-05-06")
        ledger.record(BuddyMoment(kind: .milestone, id: "milestone@10", count: 10), at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(BuddyLedger(stored: ledger.stored), ledger)
        XCTAssertEqual(BuddyLedger(stored: Data("nonsense".utf8)), BuddyLedger())
    }
}
