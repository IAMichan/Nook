import XCTest

final class ScheduledTasksTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: String = "UTC") -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func parts(_ d: Date, zone: String = "UTC") -> DateComponents {
        calendar(zone).dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
    }

    // MARK: Interval

    func testIntervalCountsFromCompletion() {
        let finished = date(2026, 1, 1, 10, 0)
        let now = date(2026, 1, 1, 10, 7)
        let next = ScheduleTiming.nextRun(rule: .interval(seconds: 600), lastFinished: finished, now: now, calendar: calendar())
        XCTAssertEqual(next, date(2026, 1, 1, 10, 10))
        // A slow run drifts the schedule: the next one is 10 minutes after the late finish.
        let late = ScheduleTiming.nextRun(rule: .interval(seconds: 600), lastFinished: date(2026, 1, 1, 10, 25), now: date(2026, 1, 1, 10, 25), calendar: calendar())
        XCTAssertEqual(late, date(2026, 1, 1, 10, 35))
    }

    func testIntervalWithoutHistoryCountsFromNow() {
        let now = date(2026, 1, 1, 8, 0)
        XCTAssertEqual(ScheduleTiming.nextRun(rule: .interval(seconds: 3600), lastFinished: nil, now: now), now.addingTimeInterval(3600))
    }

    func testIntervalFloor() {
        let now = date(2026, 1, 1)
        XCTAssertEqual(ScheduleTiming.nextRun(rule: .interval(seconds: 5), lastFinished: nil, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: .interval(seconds: -3), lastFinished: nil, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(ScheduleRule.minimumIntervalSeconds, 60)
    }

    func testWebhookHasNoNextRun() {
        XCTAssertNil(ScheduleTiming.nextRun(rule: .webhook, lastFinished: nil, now: Date()))
    }

    // MARK: Fixed time

    func testFixedTimeTodayOrTomorrow() {
        let rule = ScheduleRule.fixedTime(hour: 9, minute: 30, weekdays: [])
        let c = calendar()
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 3, 3, 8, 0), calendar: c), date(2026, 3, 3, 9, 30))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 3, 3, 9, 30), calendar: c), date(2026, 3, 4, 9, 30), "exactly now is not 'next'")
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 3, 3, 23, 0), calendar: c), date(2026, 3, 4, 9, 30))
    }

    func testFixedTimeWeekdays() {
        // 2026-03-06 is a Friday. Weekdays Monday(2) and Wednesday(4).
        let rule = ScheduleRule.fixedTime(hour: 7, minute: 0, weekdays: [2, 4])
        let next = ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 3, 6, 12, 0), calendar: calendar())
        XCTAssertEqual(next, date(2026, 3, 9, 7, 0))
        XCTAssertEqual(parts(next!).weekday, 2)
        // Sunday only (1): from a Sunday after the time it is next week.
        let sunday = ScheduleRule.fixedTime(hour: 7, minute: 0, weekdays: [1])
        XCTAssertEqual(ScheduleTiming.nextRun(rule: sunday, lastFinished: nil, now: date(2026, 3, 8, 8, 0), calendar: calendar()), date(2026, 3, 15, 7, 0))
    }

    func testFixedTimeInvalidInputs() {
        let c = calendar()
        XCTAssertNil(ScheduleTiming.nextRun(rule: .fixedTime(hour: 24, minute: 0, weekdays: []), lastFinished: nil, now: Date(), calendar: c))
        XCTAssertNil(ScheduleTiming.nextRun(rule: .fixedTime(hour: 1, minute: 60, weekdays: []), lastFinished: nil, now: Date(), calendar: c))
        XCTAssertNil(ScheduleTiming.nextRun(rule: .fixedTime(hour: 1, minute: 0, weekdays: [0, 9]), lastFinished: nil, now: Date(), calendar: c))
    }

    func testMonthEndAndLeapDay() {
        let c = calendar()
        let rule = ScheduleRule.fixedTime(hour: 6, minute: 0, weekdays: [])
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 1, 31, 7, 0), calendar: c), date(2026, 2, 1, 6, 0))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 2, 28, 7, 0), calendar: c), date(2026, 3, 1, 6, 0))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2028, 2, 28, 7, 0), calendar: c), date(2028, 2, 29, 6, 0))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2028, 2, 29, 7, 0), calendar: c), date(2028, 3, 1, 6, 0))
        XCTAssertEqual(ScheduleTiming.nextRun(rule: rule, lastFinished: nil, now: date(2026, 12, 31, 7, 0), calendar: c), date(2027, 1, 1, 6, 0))
    }

    func testDSTSpringForwardAndFallBack() {
        let zone = "America/New_York"
        let c = calendar(zone)
        // 2026-03-08: 02:00 -> 03:00. A 02:30 task still runs that day, just after the gap.
        let gap = ScheduleTiming.nextRun(rule: .fixedTime(hour: 2, minute: 30, weekdays: []), lastFinished: nil,
                                         now: date(2026, 3, 7, 12, 0, zone: zone), calendar: c)!
        XCTAssertEqual(parts(gap, zone: zone).day, 8)
        XCTAssertEqual(parts(gap, zone: zone).hour, 3)
        // A 09:00 task keeps 09:00 wall-clock across the change (23 hours later).
        let nine = ScheduleRule.fixedTime(hour: 9, minute: 0, weekdays: [])
        let after = ScheduleTiming.nextRun(rule: nine, lastFinished: nil, now: date(2026, 3, 7, 10, 0, zone: zone), calendar: c)!
        XCTAssertEqual(after, date(2026, 3, 8, 9, 0, zone: zone))
        XCTAssertEqual(after.timeIntervalSince(date(2026, 3, 7, 9, 0, zone: zone)), 23 * 3600)
        // 2026-11-01: 01:30 happens twice; the first one is used, and the next run is the following day.
        let repeated = ScheduleRule.fixedTime(hour: 1, minute: 30, weekdays: [])
        let first = ScheduleTiming.nextRun(rule: repeated, lastFinished: nil, now: date(2026, 11, 1, 0, 0, zone: zone), calendar: c)!
        XCTAssertEqual(parts(first, zone: zone).hour, 1)
        XCTAssertEqual(parts(first, zone: zone).day, 1)
        let following = ScheduleTiming.nextRun(rule: repeated, lastFinished: nil, now: first, calendar: c)!
        XCTAssertEqual(parts(following, zone: zone).day, 2)
    }

    // MARK: Missed

    func testMissedAfterTenMinutes() {
        let due = date(2026, 1, 1, 9, 0)
        XCTAssertFalse(ScheduleTiming.isMissed(scheduledFor: due, now: date(2026, 1, 1, 9, 10)))
        XCTAssertTrue(ScheduleTiming.isMissed(scheduledFor: due, now: date(2026, 1, 1, 9, 11)))
        XCTAssertFalse(ScheduleTiming.isMissed(scheduledFor: due, now: date(2026, 1, 1, 8, 0)), "not due yet")
        XCTAssertTrue(ScheduleTiming.shouldSkip(rule: .fixedTime(hour: 9, minute: 0, weekdays: []), scheduledFor: due, now: date(2026, 1, 1, 12, 0)))
        XCTAssertFalse(ScheduleTiming.shouldSkip(rule: .interval(seconds: 600), scheduledFor: due, now: date(2026, 1, 1, 12, 0)), "an overdue interval runs once")
    }

    // MARK: Codable

    func testRuleRoundTripAndTolerance() throws {
        for rule in [ScheduleRule.interval(seconds: 900), .fixedTime(hour: 8, minute: 5, weekdays: [2, 3]), .webhook] {
            XCTAssertEqual(try JSONDecoder().decode(ScheduleRule.self, from: JSONEncoder().encode(rule)), rule)
        }
        func decode(_ s: String) throws -> ScheduleRule { try JSONDecoder().decode(ScheduleRule.self, from: Data(s.utf8)) }
        XCTAssertEqual(try decode(#"{"type":"interval"}"#), .interval(seconds: 60))
        XCTAssertEqual(try decode(#"{"type":"fixedTime","hour":7,"extra":1}"#), .fixedTime(hour: 7, minute: 0, weekdays: []))
        XCTAssertEqual(try decode(#"{"type":"cron","expr":"* * * * *"}"#), .webhook, "unknown never fires on its own")
        XCTAssertEqual(try decode("{}"), .webhook)
    }

    func testTaskDecodesWithMissingAndUnknownFields() throws {
        let json = #"{"title":"Nightly","prompt":"run tests","future":true,"rule":{"type":"interval","seconds":120}}"#
        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.title, "Nightly")
        XCTAssertEqual(task.rule, .interval(seconds: 120))
        XCTAssertFalse(task.enabled)
        XCTAssertNil(task.lastStatus)
    }

    func testTaskRoundTrip() throws {
        let session = UUID()
        for target in [ScheduledTaskTarget.newSession(projectPath: "/p", provider: "codex", profileID: "work"), .existingSession(id: session)] {
            let task = ScheduledTask(title: "t", prompt: "p", rule: .webhook, target: target, createdAt: Date(timeIntervalSince1970: 100))
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            XCTAssertEqual(try dec.decode(ScheduledTask.self, from: enc.encode(task)), task)
        }
    }

    func testUnknownStatusDoesNotBreakDecoding() throws {
        let json = #"{"title":"x","lastStatus":"exploded"}"#
        XCTAssertNil(try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8)).lastStatus)
    }

    // MARK: Fire key, ledger

    func testFireKeyIsStableAndDistinct() {
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1_700_000_000.4)
        let key = ScheduledTask.fireKey(taskID: id, scheduledFor: t, trigger: .schedule)
        XCTAssertEqual(key, "scheduled-task:\(id.uuidString):1700000000400:schedule")
        XCTAssertEqual(key, ScheduledTask.fireKey(taskID: id, scheduledFor: t, trigger: .schedule))
        XCTAssertNotEqual(key, ScheduledTask.fireKey(taskID: id, scheduledFor: t, trigger: .manual))
        XCTAssertNotEqual(key, ScheduledTask.fireKey(taskID: id, scheduledFor: t.addingTimeInterval(1), trigger: .schedule))
    }

    func testFireLedgerIsIdempotentAndBounded() {
        var ledger = FireLedger(capacity: 2)
        XCTAssertTrue(ledger.claim("a"))
        XCTAssertFalse(ledger.claim("a"))
        XCTAssertTrue(ledger.claim("b"))
        XCTAssertTrue(ledger.claim("c"))
        XCTAssertTrue(ledger.claim("a"), "evicted")
    }

    // MARK: Gate and queue

    func testRunGateNoOverlap() {
        var gate = RunGate()
        let a = UUID(), b = UUID()
        XCTAssertTrue(gate.begin(a))
        XCTAssertFalse(gate.begin(a))
        XCTAssertTrue(gate.begin(b), "other tasks are independent")
        XCTAssertTrue(gate.isRunning(a))
        gate.finish(a)
        XCTAssertFalse(gate.isRunning(a))
        XCTAssertTrue(gate.begin(a))
        gate.finish(UUID())
    }

    func testWebhookQueueRejectsAtTwentyAndRecovers() {
        var q = WebhookQueue()
        let id = UUID()
        for _ in 0..<20 { XCTAssertEqual(q.admit(id), .accepted) }
        XCTAssertEqual(q.admit(id), .queueFull, "rejects the new one; nothing queued is dropped")
        XCTAssertEqual(q.count(id), 20)
        XCTAssertEqual(q.admit(UUID()), .accepted, "per task")
        q.release(id)
        XCTAssertEqual(q.admit(id), .accepted)
        q.forget(id)
        XCTAssertEqual(q.count(id), 0)
        q.release(id)
        XCTAssertEqual(q.count(id), 0)
    }

    // MARK: Recovery

    func testRecoverInterruptedRunsAreFailedAndRescheduled() {
        let now = date(2026, 5, 1, 12, 0)
        let c = calendar()
        let running = ScheduledTask(title: "r", prompt: "p", rule: .interval(seconds: 600), target: .existingSession(id: UUID()),
                                    lastStatus: .running, createdAt: now)
        let done = ScheduledTask(title: "d", prompt: "p", rule: .interval(seconds: 600), target: .existingSession(id: UUID()),
                                 lastRun: now, lastStatus: .succeeded, nextRun: now.addingTimeInterval(5), createdAt: now)
        let disabled = ScheduledTask(title: "x", prompt: "p", rule: .interval(seconds: 600), target: .existingSession(id: UUID()),
                                     enabled: false, lastStatus: .running, createdAt: now)
        let hook = ScheduledTask(title: "h", prompt: "p", rule: .webhook, target: .existingSession(id: UUID()), lastStatus: .running, createdAt: now)
        let out = ScheduledTask.recoverInterrupted(tasks: [running, done, disabled, hook], now: now, calendar: c)
        XCTAssertEqual(out[0].lastStatus, .failed)
        XCTAssertEqual(out[0].lastError, ScheduledTask.interruptedReason)
        XCTAssertEqual(out[0].nextRun, now.addingTimeInterval(600))
        XCTAssertEqual(out[1], done)
        XCTAssertEqual(out[2].lastStatus, .failed)
        XCTAssertNil(out[2].nextRun, "a paused task stays unscheduled")
        XCTAssertNil(out[3].nextRun)
        XCTAssertEqual(ScheduledTask.interruptedReason, "interrupted by a restart")
    }

    func testFinishingSchedulesFromFinishTime() {
        let t0 = date(2026, 5, 1, 12, 0)
        let task = ScheduledTask(title: "t", prompt: "p", rule: .interval(seconds: 300), target: .existingSession(id: UUID()), lastStatus: .running, createdAt: t0)
        let done = task.finishing(status: .succeeded, at: t0.addingTimeInterval(90), calendar: calendar())
        XCTAssertEqual(done.lastStatus, .succeeded)
        XCTAssertEqual(done.nextRun, t0.addingTimeInterval(390))
        XCTAssertNil(done.lastError)
    }
}
