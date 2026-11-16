import XCTest

final class InterruptionBudgetTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNoticesAreNeverCounted() {
        var budget = InterruptionBudget()
        for _ in 0..<20 { budget.spend(.notice, now: at(9), calendar: calendar) }
        XCTAssertTrue(budget.allows(.notice, now: at(9), calendar: calendar))
        XCTAssertTrue(budget.allows(.moment, now: at(9), calendar: calendar))
    }

    func testOffersAndMomentsShareOneDailyBudget() {
        var budget = InterruptionBudget()
        // Four offers and two moments, an hour apart: the day is spent.
        for hour in 8..<12 { budget.spend(.suggestion, now: at(hour), calendar: calendar) }
        for hour in 12..<14 { budget.spend(.moment, now: at(hour), calendar: calendar) }
        XCTAssertFalse(budget.allows(.moment, now: at(18), calendar: calendar))
        XCTAssertFalse(budget.allows(.suggestion, now: at(18), calendar: calendar))
        // Tomorrow it starts again.
        XCTAssertTrue(budget.allows(.moment, now: at(9, day: 15), calendar: calendar))
    }

    func testEachClassHasALimitOfItsOwn() {
        var budget = InterruptionBudget()
        for hour in 8..<12 { budget.spend(.suggestion, now: at(hour), calendar: calendar) }
        XCTAssertFalse(budget.allows(.suggestion, now: at(15), calendar: calendar))
        XCTAssertTrue(budget.allows(.moment, now: at(15), calendar: calendar))
    }

    func testGapsWithinAClassAndBetweenUnaskedOnes() {
        var budget = InterruptionBudget()
        budget.spend(.moment, now: at(9), calendar: calendar)
        // Another moment waits twenty minutes, an offer ten.
        XCTAssertFalse(budget.allows(.moment, now: at(9, 15), calendar: calendar))
        XCTAssertFalse(budget.allows(.suggestion, now: at(9, 5), calendar: calendar))
        XCTAssertTrue(budget.allows(.suggestion, now: at(9, 11), calendar: calendar))
        XCTAssertTrue(budget.allows(.moment, now: at(9, 21), calendar: calendar))
        // A caller's own longer gap and the feedback's factor stretch it.
        budget.spend(.suggestion, now: at(10), calendar: calendar)
        XCTAssertFalse(budget.allows(.suggestion, now: at(10, 20), extraGap: 30 * 60, calendar: calendar))
        XCTAssertFalse(budget.allows(.moment, now: at(10, 15), gapFactor: 2, calendar: calendar))
        XCTAssertTrue(budget.allows(.moment, now: at(10, 21), gapFactor: 2, calendar: calendar))
    }

    func testTheBudgetSurvivesALaunch() {
        var budget = InterruptionBudget()
        budget.spend(.moment, now: at(9), calendar: calendar)
        let again = InterruptionBudget(stored: budget.stored)
        XCTAssertEqual(again, budget)
        XCTAssertEqual(again.spent(.moment, now: at(12), calendar: calendar), 1)
        XCTAssertEqual(InterruptionBudget(stored: Data("junk".utf8)), InterruptionBudget())
    }

    func testThePacerAsksTheBudgetAndKeepsTheNoticesDistance() {
        var pacer = NoticePacer()
        pacer.record(key: "chat:1", now: at(9))
        // A moment ten seconds after a chat popped up waits for the notices' gap.
        XCTAssertFalse(pacer.permits(.moment, key: "moments", now: at(9).addingTimeInterval(10), calendar: calendar))
        XCTAssertTrue(pacer.permits(.moment, key: "moments", now: at(9, 1), calendar: calendar))
        pacer.record(.moment, key: "moments", now: at(9, 1), calendar: calendar)
        XCTAssertEqual(pacer.budget.spent(.moment, now: at(9, 2), calendar: calendar), 1)
        XCTAssertFalse(pacer.permits(.moment, key: "moments", now: at(9, 5), calendar: calendar))
    }

    func testOftenDismissedNoticesKeepALongerDistance() {
        var pacer = NoticePacer()
        let start = at(9)
        pacer.record(key: "chat:1", now: start)
        XCTAssertTrue(pacer.permits(key: "chat:2", now: start.addingTimeInterval(30)))
        XCTAssertFalse(pacer.permits(key: "chat:2", gapFactor: 2, now: start.addingTimeInterval(30)))
        XCTAssertEqual(pacer.nextPermitted(key: "chat:1", gapFactor: 2, now: start), start.addingTimeInterval(NoticePacer.sameKeyGap * 2))
        // Never shorter than usual.
        XCTAssertFalse(pacer.permits(key: "chat:2", gapFactor: 0.1, now: start.addingTimeInterval(10)))
    }
}

final class ThinkAlongBackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeclinesDoubleTheWaitUpToTwoHours() {
        var backoff = ThinkAlongBackoff()
        XCTAssertTrue(backoff.allows(now: now))
        backoff.offered(at: now)
        // An offer still unanswered counts as a no already.
        XCTAssertEqual(backoff.gap, 1800)
        XCTAssertFalse(backoff.allows(now: now.addingTimeInterval(1000)))
        backoff.declined()
        XCTAssertEqual(backoff.gap, 1800)
        for _ in 0..<6 { backoff.declined() }
        XCTAssertEqual(backoff.gap, ThinkAlongBackoff.maxGap)
        backoff.accepted()
        XCTAssertEqual(backoff.gap, ThinkAlongBackoff.baseGap)
    }

    func testAnOfferLeftUnansweredCountsOnTheNext() {
        var backoff = ThinkAlongBackoff()
        backoff.offered(at: now)
        backoff.offered(at: now.addingTimeInterval(3600))
        XCTAssertEqual(backoff.declines, 1)
    }

    func testItSurvivesARestart() {
        var backoff = ThinkAlongBackoff()
        backoff.offered(at: now)
        backoff.declined()
        let again = ThinkAlongBackoff(stored: backoff.stored)
        XCTAssertEqual(again, backoff)
        XCTAssertFalse(again.allows(now: now.addingTimeInterval(60)))
    }
}
