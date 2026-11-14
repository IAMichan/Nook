import XCTest

/// Automations Nook Chat runs by itself (`ScheduledTaskTarget.nook`, `NookSchedule`), the mail pieces they lean on
/// (message ids in the inbox list, threaded replies) and the planner's time limit.
final class NookAutomationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Target

    func testNookTargetRoundTripsAndKeepsOtherTargets() throws {
        let data = try JSONEncoder().encode(ScheduledTaskTarget.nook)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"type":"nook"}"#)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTaskTarget.self, from: data), .nook)
        XCTAssertTrue(ScheduledTaskTarget.nook.isNook)
        XCTAssertNil(ScheduledTaskTarget.nook.sessionID)
        // Rows from before keep their own targets.
        let old = Data(#"{"type":"newSession","projectPath":"/p","provider":"codex"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTaskTarget.self, from: old),
                       .newSession(projectPath: "/p", provider: "codex", profileID: nil))
        XCTAssertFalse(ScheduledTaskTarget.newSession(projectPath: "/p", provider: "codex", profileID: nil).isNook)
    }

    func testAMissedMorningOverviewStillRuns() {
        let rule = ScheduleRule.fixedTime(hour: 8, minute: 0, weekdays: [])
        let late = now.addingTimeInterval(3 * 3600)
        XCTAssertTrue(ScheduleTiming.shouldSkip(rule: rule, scheduledFor: now, now: late), "an agent task skips a missed time")
        XCTAssertFalse(ScheduleTiming.shouldSkip(rule: rule, scheduledFor: now, now: late, catchesUp: true),
                       "Nook's overview runs once when the Mac wakes")
    }

    // MARK: Parsing the chat's request

    func testDailyTask() throws {
        let parsed = NookSchedule.parse(["title": "Ochtendmail", "prompt": "Check mijn mail", "schedule": "daily", "time": "08:00"],
                                        now: now, calendar: calendar)
        XCTAssertEqual(parsed.problems, [])
        let draft = try XCTUnwrap(parsed.draft)
        XCTAssertEqual(draft.rule, .fixedTime(hour: 8, minute: 0, weekdays: []))
        XCTAssertEqual(draft.title, "Ochtendmail")
        XCTAssertEqual(NookSchedule.summary(draft), "Scheduled task “Ochtendmail”: every day at 08:00")
    }

    func testWeekdaysAndWeeklyInSeveralLanguages() {
        let weekdays = NookSchedule.parse(["prompt": "p", "schedule": "weekdays", "time": "7.30"], now: now, calendar: calendar)
        XCTAssertEqual(weekdays.draft?.rule, .fixedTime(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6]))
        XCTAssertEqual(weekdays.draft.map { NookSchedule.describe($0.rule) }, "every weekday at 07:30")
        let weekly = NookSchedule.parse(["prompt": "p", "schedule": "weekly", "time": "9u", "days": ["maandag", "Friday", "mié"]],
                                        now: now, calendar: calendar)
        XCTAssertEqual(weekly.draft?.rule, .fixedTime(hour: 9, minute: 0, weekdays: [2, 4, 6]))
        XCTAssertEqual(weekly.draft.map { NookSchedule.describe($0.rule) }, "every Monday, Wednesday, Friday at 09:00")
        let text = NookSchedule.parse(["prompt": "p", "schedule": "weekly", "time": "18:00", "days": "zo, sat"], now: now, calendar: calendar)
        XCTAssertEqual(text.draft?.rule, .fixedTime(hour: 18, minute: 0, weekdays: [1, 7]))
    }

    func testTitleFallsBackToThePrompt() {
        let parsed = NookSchedule.parse(["prompt": "Vat elke ochtend mijn agenda samen\nen meer", "schedule": "daily", "time": "8"],
                                        now: now, calendar: calendar)
        XCTAssertEqual(parsed.draft?.title, "Vat elke ochtend mijn agenda samen")
    }

    func testProblemsAreNamed() {
        XCTAssertFalse(NookSchedule.parse(["schedule": "daily", "time": "08:00"], now: now).problems.isEmpty, "no prompt")
        XCTAssertFalse(NookSchedule.parse(["prompt": "p", "schedule": "hourly"], now: now).problems.isEmpty, "unknown schedule")
        XCTAssertFalse(NookSchedule.parse(["prompt": "p", "schedule": "daily", "time": "25:00"], now: now).problems.isEmpty)
        XCTAssertFalse(NookSchedule.parse(["prompt": "p", "schedule": "weekly", "time": "08:00"], now: now).problems.isEmpty, "no days")
        XCTAssertFalse(NookSchedule.parse(["prompt": "p", "schedule": "interval", "every_minutes": 5], now: now).problems.isEmpty,
                       "too often for a brain")
        XCTAssertEqual(NookSchedule.parse(["prompt": "p", "schedule": "interval", "every_minutes": 60], now: now).draft?.rule,
                       .interval(seconds: 3600))
    }

    func testOnceNeedsAMomentToCome() {
        let past = NookSchedule.parse(["prompt": "p", "schedule": "once", "at": "2020-01-01T09:00"], now: now, calendar: calendar)
        XCTAssertNil(past.draft)
        let future = NookSchedule.parse(["prompt": "p", "schedule": "once", "at": "2027-03-01T09:00"], now: now, calendar: calendar)
        let expected = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9))!
        XCTAssertEqual(future.draft?.rule, .once(at: expected))
        let zoned = NookSchedule.parse(["prompt": "p", "schedule": "once", "at": "2027-03-01T08:00:00Z"], now: now, calendar: calendar)
        XCTAssertEqual(zoned.draft?.rule, .once(at: expected))
    }

    func testTimesAndWeekdays() {
        XCTAssertEqual(NookSchedule.time("08:05").map { [$0.hour, $0.minute] }, [8, 5])
        XCTAssertEqual(NookSchedule.time("8h").map { [$0.hour, $0.minute] }, [8, 0])
        XCTAssertNil(NookSchedule.time("8:7"))
        XCTAssertNil(NookSchedule.time("acht uur"))
        XCTAssertEqual(NookSchedule.weekday("Zondag"), 1)
        XCTAssertEqual(NookSchedule.weekday("sábado"), 7)
        XCTAssertNil(NookSchedule.weekday("someday"))
    }

    func testTheGateChecksTheSchedule() {
        let schema: [String: Any] = ["type": "object", "properties": ["prompt": ["type": "string"], "schedule": ["type": "string"],
                                                                      "time": ["type": "string"]],
                                     "required": ["prompt", "schedule"]]
        let bad = ActionGate.problems(tool: "schedule_task", input: ["prompt": "p", "schedule": "daily"], schema: schema, parseDate: { _ in nil })
        XCTAssertFalse(bad.isEmpty, "a daily task without a time is not proposed as ready")
        let good = ActionGate.problems(tool: "schedule_task", input: ["prompt": "p", "schedule": "daily", "time": "08:00"], schema: schema,
                                       parseDate: { _ in nil })
        XCTAssertEqual(good, [])
    }

    func testRunNoteAsksForReadyReplies() {
        let note = NookSchedule.runNote(title: "Ochtendmail")
        XCTAssertTrue(note.contains("\"Ochtendmail\""))
        XCTAssertTrue(note.contains("reply_to"))
        XCTAssertTrue(note.contains("without asking questions first"))
    }

    func testTheRunWorksAsASecretaryAcrossEverySource() {
        let note = NookSchedule.runNote(title: "Middagcheck", since: now, quiet: true)
        for part in ["personal secretary", "chats in every chat app", "calendar", "pull requests", "coding agents",
                     "whatsapp_send or chat_send", "approve it or say what to change", "The previous run was at", NookSchedule.nothingNew] {
            XCTAssertTrue(note.contains(part), part)
        }
        let open = NookSchedule.runNote(title: "Ochtend")
        XCTAssertFalse(open.contains(NookSchedule.nothingNew), "an overview always answers")
        XCTAssertFalse(open.contains("previous run"))
    }

    func testNothingNewIsRecognizedAlone() {
        XCTAssertTrue(NookSchedule.isNothingNew("NOTHING_NEW"))
        XCTAssertTrue(NookSchedule.isNothingNew("**nothing new.**\n"))
        XCTAssertFalse(NookSchedule.isNothingNew("NOTHING_NEW, but Lisa wrote about the invoice"))
    }

    func testChecksThroughTheDayAreQuietByDefault() {
        XCTAssertEqual(NookSchedule.parse(["prompt": "p", "schedule": "interval", "every_minutes": 60], now: now).draft?.quiet, true)
        XCTAssertEqual(NookSchedule.parse(["prompt": "p", "schedule": "daily", "time": "08:00"], now: now).draft?.quiet, false)
        XCTAssertEqual(NookSchedule.parse(["prompt": "p", "schedule": "daily", "time": "08:00", "quiet": true], now: now).draft?.quiet, true)
    }

    func testTheSecretaryCoversTheDayWithoutNightRuns() {
        let tasks = NookSchedule.secretary()
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks.map(\.rule), [.fixedTime(hour: 8, minute: 0, weekdays: []),
                                           .fixedTime(hour: 13, minute: 0, weekdays: [2, 3, 4, 5, 6]),
                                           .fixedTime(hour: 17, minute: 30, weekdays: [2, 3, 4, 5, 6])])
        XCTAssertEqual(tasks.map(\.quiet), [false, true, false], "only the midday check stays silent when nothing is new")
        // The texts are the user's own language (tr); every task has a name and a request of its own.
        XCTAssertEqual(Set(tasks.map(\.title)).count, 3)
        XCTAssertTrue(tasks.allSatisfy { !$0.prompt.isEmpty && $0.prompt != $0.title })
    }

    // MARK: Intent

    func testAskingForASecretaryOffersIt() {
        for text in ["wees mijn persoonlijke secretaris", "I want a secretary that keeps track of everything"] {
            XCTAssertTrue(ChatIntent.detect(text).tools.contains("set_up_secretary"), text)
        }
    }

    func testRecurringRequestsOfferTheSchedulingTools() {
        for text in ["Check elke ochtend om 8 mijn mail en zet antwoorden klaar", "every weekday summarize my inbox",
                     "maak een automatisering voor mijn mail", "schick mir täglich um 7 eine Übersicht"] {
            let intent = ChatIntent.detect(text)
            XCTAssertTrue(intent.kinds.contains(.schedule), text)
            XCTAssertTrue(intent.tools.contains("schedule_task"), text)
        }
        XCTAssertFalse(ChatIntent.detect("wat staat er morgen in mijn agenda?").kinds.contains(.schedule))
        // A recurring meeting stays a calendar event first.
        let meeting = ChatIntent.detect("plan elke maandag een overleg met Tom")
        XCTAssertEqual(meeting.kinds.first, .event)
    }

    func testWritingAMailAlsoOffersTheInbox() {
        XCTAssertTrue(ChatIntent.detect("beantwoord de mail van Lisa").tools.contains("inbox_mail"))
    }

    // MARK: Mail

    func testInboxRowsCarryTheirMessageID() {
        let raw = "TOTAL|||1\nROW|||Werk|||INBOX|||1|||Vraag|||Lisa <lisa@example.com>|||2026-10-14T09:00:00|||false|||false|||<abc@x.nl>\n"
            + "ROW|||Werk|||INBOX|||2|||Oud|||Bram <b@x.nl>|||2026-10-13T09:00:00|||true|||false\n"
        let rows = MailStats.recent(raw, calendar: calendar).rows
        XCTAssertEqual(rows.map(\.messageID), ["abc@x.nl", ""], "old output without the id still reads")
        XCTAssertEqual(MailStats.describe([rows[0]], date: { _ in "14 okt" }),
                       "### Vraag | van Lisa <lisa@example.com> | 14 okt | ongelezen | Werk | id: abc@x.nl")
        XCTAssertTrue(MailStats.recentScript(account: "Werk").contains("message id of messages lo thru hi of box"))
    }

    func testUnreadOnly() {
        let raw = "TOTAL|||1\nROW|||Werk|||INBOX|||1|||Nieuw|||Lisa <lisa@example.com>|||2026-10-14T09:00:00|||false|||false|||a@x\n"
            + "ROW|||Werk|||INBOX|||2|||Gelezen|||Bram <b@x.nl>|||2026-10-14T08:00:00|||true|||false|||b@x\n"
        let rows = MailStats.recent(raw, calendar: calendar).rows
        let later = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        XCTAssertEqual(MailStats.select(rows, now: later, days: 1, unansweredOnly: false, unreadOnly: true).map(\.subject), ["Nieuw"])
        XCTAssertEqual(MailStats.select(rows, now: later, days: 1, unansweredOnly: false).count, 2)
    }

    func testReplyScriptAnswersTheMessageItself() {
        let script = MailActions.replyScript(id: "abc@x.nl", body: "Hoi Lisa,\n\"Prima\"", to: ["lisa@example.com"], cc: [], openWindow: false)
        XCTAssertTrue(script.contains("whose message id is \"abc@x.nl\""))
        XCTAssertTrue(script.contains("set m to reply original without opening window"))
        XCTAssertTrue(script.contains("set content of m to \"Hoi Lisa,\n\\\"Prima\\\"\""))
        XCTAssertTrue(script.contains("delete every to recipient of m"))
        XCTAssertTrue(script.contains("{address:\"lisa@example.com\"}"))
        let opened = MailActions.replyScript(id: "abc@x.nl", body: "b", to: [], cc: [], openWindow: true)
        XCTAssertTrue(opened.contains("with opening window"))
        XCTAssertFalse(opened.contains("delete every to recipient"), "no recipients given: Mail's own stay")
    }

    // MARK: Planner

    func testPlannerWaitsLessForAnAPIBrain() {
        XCTAssertEqual(QueryPlanner.timeout(small: false, agent: false), 5)
        XCTAssertEqual(QueryPlanner.timeout(small: false, agent: true), 8)
        XCTAssertEqual(QueryPlanner.timeout(small: true, agent: false), 12)
    }
}
