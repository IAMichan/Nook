import XCTest

final class AttentionContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPresenceBandsAreDefinedOnce() {
        XCTAssertEqual(AttentionContext.presence(idle: 10, locked: false), .focused)
        XCTAssertEqual(AttentionContext.presence(idle: 90, locked: false), .present)
        XCTAssertEqual(AttentionContext.presence(idle: 150, locked: false), .nearby)
        XCTAssertEqual(AttentionContext.presence(idle: 200, locked: false), .stepping)
        XCTAssertEqual(AttentionContext.presence(idle: 300, locked: false), .away)
        XCTAssertEqual(AttentionContext.presence(idle: 1, locked: true), .away)
        // The thresholds the rest of Nook reads are these.
        XCTAssertEqual(SessionFocus.presence, AttentionContext.focusedWithin)
        XCTAssertEqual(EnergySignals.awayAfter, AttentionContext.awayAfter)
        XCTAssertEqual(BuddyActivity.awayAfter, AttentionContext.awayAfter)
    }

    func testDerivedDecisions() {
        var context = AttentionContext(at: now, idle: 130)
        XCTAssertFalse(context.isPresent)
        XCTAssertTrue(context.awayFromMac)
        XCTAssertTrue(context.readsScreen)
        XCTAssertFalse(context.isAway)
        context = context.refreshed(idle: 5, locked: false, at: now)
        XCTAssertTrue(context.isPresent)
        XCTAssertFalse(context.awayFromMac)
    }

    func testMeetingFromAnySign() {
        var context = AttentionContext(at: now)
        XCTAssertFalse(context.inMeeting)
        context.frontApp = "us.zoom.xos"
        XCTAssertTrue(context.inMeeting)
        context.frontApp = "com.apple.Safari"
        context.inEvent = true
        XCTAssertTrue(context.inMeeting)
        XCTAssertTrue(context.keepsNiceToHaveQuiet)
        context.inEvent = false
        context.quietHours = true
        XCTAssertFalse(context.inMeeting)
        XCTAssertTrue(context.keepsNiceToHaveQuiet)
    }

    func testRefreshKeepsTheRest() {
        var context = AttentionContext(at: now)
        context.sharing = true
        let fresh = context.refreshed(idle: 400, locked: false, frontApp: "com.apple.mail", at: now)
        XCTAssertTrue(fresh.sharing)
        XCTAssertEqual(fresh.frontApp, "com.apple.mail")
        XCTAssertTrue(fresh.isAway)
    }

    func testTheSharedContextIsACopy() {
        let box = AttentionNow()
        box.update { $0.meeting = true }
        XCTAssertTrue(box.context.meeting)
    }

    func testCalendarEventsAreReadOnce() {
        let event = QuietPolicy.Event(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        let allDay = QuietPolicy.Event(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(23 * 3600))
        XCTAssertTrue(QuietPolicy.inEvent([event], now: now))
        XCTAssertFalse(QuietPolicy.inEvent([allDay], now: now))
    }
}

final class QuietHoursTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour))!
    }

    func testHoursAcrossMidnight() {
        let hours = QuietHours(from: 22, to: 7)
        XCTAssertTrue(hours.contains(at(23), calendar: calendar))
        XCTAssertTrue(hours.contains(at(3), calendar: calendar))
        XCTAssertFalse(hours.contains(at(7), calendar: calendar))
        XCTAssertFalse(hours.contains(at(12), calendar: calendar))
        XCTAssertFalse(QuietHours(from: 9, to: 9).contains(at(9), calendar: calendar))
    }

    func testUrgentComesThroughWhenAllowed() {
        var hours = QuietHours(from: 22, to: 7)
        XCTAssertTrue(hours.silences(urgent: false, at: at(23), calendar: calendar))
        XCTAssertFalse(hours.silences(urgent: true, at: at(23), calendar: calendar))
        hours.allowsUrgent = false
        XCTAssertTrue(hours.silences(urgent: true, at: at(23), calendar: calendar))
    }

    func testPushSettingsShareTheType() {
        var push = PushSettings()
        XCTAssertNil(push.quietHours)
        push.quietHours = QuietHours(from: 21, to: 6, allowsUrgent: false)
        XCTAssertEqual(push.quietFrom, 21)
        XCTAssertEqual(push.quietTo, 6)
        XCTAssertFalse(push.quietAllowsUrgent)
        XCTAssertEqual(push.quietHours, QuietHours(from: 21, to: 6, allowsUrgent: false))
    }

    func testThePhoneFollowsTheMacsQuietHours() {
        var push = PushSettings()
        push.enabled = true
        push.onlyWhenAway = false
        let finished = PushEvent(kind: .finished, session: "s", item: nil, agent: "Codex", title: "")
        let approval = PushEvent(kind: .approval, session: "s", item: "a", agent: "Codex", title: "")
        let mac = QuietHours(from: 22, to: 7)
        XCTAssertEqual(PushPolicy.skipReason(finished, settings: push, away: true, now: at(23), calendar: calendar, quietHours: .some(mac)), .quietHours)
        XCTAssertNil(PushPolicy.skipReason(approval, settings: push, away: true, now: at(23), calendar: calendar, quietHours: .some(mac)))
        // The Mac has none: the phone's old fields no longer count.
        push.quietHours = QuietHours(from: 22, to: 7)
        XCTAssertNil(PushPolicy.skipReason(finished, settings: push, away: true, now: at(23), calendar: calendar, quietHours: .some(nil)))
        // Left out: the settings' own, as before.
        XCTAssertEqual(PushPolicy.skipReason(finished, settings: push, away: true, now: at(23), calendar: calendar), .quietHours)
    }

    func testMacNoticesKeepQuietInTheHours() {
        var rules = NoticeRules()
        XCTAssertEqual(rules.decide(.chats, app: "", now: at(23)), .show(.card))
        rules.quietHours = QuietHours(from: 22, to: 7)
        // `decide` reads the hour in the current time zone: pick a moment inside the hours there.
        let night = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        XCTAssertEqual(rules.decide(.chats, now: night), .historyOnly)
        XCTAssertEqual(rules.decide(.agents, urgent: true, now: night), .show(.card))
        rules.quietHours?.allowsUrgent = false
        XCTAssertEqual(rules.decide(.agents, urgent: true, now: night), .historyOnly)
    }

    func testRulesSavedBeforeQuietHoursReadBack() throws {
        let data = Data(#"{"styles":{},"apps":{}}"#.utf8)
        let rules = try JSONDecoder().decode(NoticeRules.self, from: data)
        XCTAssertNil(rules.quietHours)
    }

    func testPhoneQuietHoursAreAdoptedOnce() {
        var rules = NoticeRules()
        XCTAssertTrue(rules.adoptingQuietHours(QuietHours(from: 23, to: 6), adopted: false))
        XCTAssertEqual(rules.quietHours, QuietHours(from: 23, to: 6))
        var later = NoticeRules()
        XCTAssertFalse(later.adoptingQuietHours(QuietHours(from: 23, to: 6), adopted: true))
        XCTAssertNil(later.quietHours)
    }

    func testAgentPushesFollowTheMacsRules() {
        var rules = NoticeRules()
        XCTAssertTrue(rules.allowsAgentPush(.finished, app: "Codex", snoozed: false, settled: false))
        XCTAssertFalse(rules.allowsAgentPush(.finished, app: "Codex", snoozed: true, settled: false))
        XCTAssertFalse(rules.allowsAgentPush(.failed, app: "Codex", snoozed: false, settled: true))
        rules.set(.agents, app: "Codex", on: false)
        XCTAssertFalse(rules.allowsAgentPush(.finished, app: "Codex", snoozed: false, settled: false))
        // What waits on you always goes.
        XCTAssertTrue(rules.allowsAgentPush(.approval, app: "Codex", snoozed: true, settled: true))
        XCTAssertTrue(rules.allowsAgentPush(.question, app: "Codex", snoozed: false, settled: false))
    }
}
