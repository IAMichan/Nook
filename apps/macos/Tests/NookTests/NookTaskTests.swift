import XCTest

/// Nook scheduling work for itself from the chat (`schedule_nook_task`, `ScheduledTaskTarget.nook`): recognizing the
/// request, reading the schedule the model fills in, storing the target, and undoing it.
final class NookTaskTests: XCTestCase {
    private func parse(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    // MARK: Recognizing the request

    func testRecurringRequestsScheduleNook() {
        let asks = [
            "Kan jij elke morgen om 9:00 mij de updates geven over berichten die ik heb ontvangen in de tussentijd",
            "Geef me elke ochtend om 9:00 een update over mijn berichten",
            "Stuur me iedere vrijdag een weekoverzicht van mijn mail",
            "Vat dagelijks om 18:00 mijn ongelezen mail samen",
            "Every morning at 9, tell me what came in overnight",
            "Summarize my unread mail every weekday at 8",
            "Fasse mir jeden Abend meine Mails zusammen",
            "Fais-moi tous les matins le point sur mes messages",
            "Resume mis correos cada mañana a las 9"
        ]
        for text in asks {
            let intent = ChatIntent.detect(text)
            XCTAssertTrue(intent.kinds.contains(.schedule), text)
            XCTAssertEqual(intent.primaryAction, "schedule_nook_task", text)
            XCTAssertEqual(intent.tools.first, "schedule_nook_task", text)
        }
    }

    func testQuestionsAboutHabitsDoNotSchedule() {
        // About what happens every day, not a request to do something every day.
        let intent = ChatIntent.detect("Hoeveel mails krijg ik elke dag?")
        XCTAssertNil(intent.primaryAction)
        XCTAssertFalse(ChatIntent.recurs("Herinner me morgen om 9 uur aan de tandarts"))
        XCTAssertEqual(ChatIntent.detect("Herinner me morgen om 9 uur aan de tandarts").primaryAction, "create_reminder")
        XCTAssertFalse(ChatIntent.recurs("Wat heb ik vanochtend gemist?"))
    }

    // MARK: The schedule

    func testTimeOfDayWithDays() {
        XCTAssertEqual(NookTaskSchedule.rule(["time": "09:00"], parseDate: parse), .success(.fixedTime(hour: 9, minute: 0, weekdays: [])))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "7:30", "days": "weekdays"], parseDate: parse),
                       .success(.fixedTime(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6])))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "18", "days": "mon, wed and fri"], parseDate: parse),
                       .success(.fixedTime(hour: 18, minute: 0, weekdays: [2, 4, 6])))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "21.15", "days": "weekend"], parseDate: parse),
                       .success(.fixedTime(hour: 21, minute: 15, weekdays: [1, 7])))
        XCTAssertEqual(NookTaskSchedule.weekdays("maandag, vrijdag"), [2, 6])
        XCTAssertEqual(NookTaskSchedule.weekdays("every day"), [])
    }

    func testIntervalAndOnce() {
        let now = parse("2026-11-15T12:00:00Z")!
        XCTAssertEqual(NookTaskSchedule.rule(["every_minutes": 30], now: now, parseDate: parse), .success(.interval(seconds: 1800)))
        XCTAssertEqual(NookTaskSchedule.rule(["every_minutes": "90"], now: now, parseDate: parse), .success(.interval(seconds: 5400)))
        XCTAssertEqual(NookTaskSchedule.rule(["at": "2026-11-16T09:00:00Z"], now: now, parseDate: parse),
                       .success(.once(at: parse("2026-11-16T09:00:00Z")!)))
    }

    func testWhatIsWrongWithASchedule() {
        let now = parse("2026-11-15T12:00:00Z")!
        XCTAssertEqual(NookTaskSchedule.rule([:], now: now, parseDate: parse), .failure(.when))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "09:00", "every_minutes": 5], now: now, parseDate: parse), .failure(.when))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "25:00"], now: now, parseDate: parse), .failure(.time))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "morning"], now: now, parseDate: parse), .failure(.time))
        XCTAssertEqual(NookTaskSchedule.rule(["time": "09:00", "days": "someday"], now: now, parseDate: parse), .failure(.days))
        XCTAssertEqual(NookTaskSchedule.rule(["every_minutes": 0], now: now, parseDate: parse), .failure(.interval))
        XCTAssertEqual(NookTaskSchedule.rule(["at": "2026-11-14T09:00:00Z"], now: now, parseDate: parse), .failure(.moment))
        XCTAssertEqual(NookTaskSchedule.rule(["at": "tomorrow"], now: now, parseDate: parse), .failure(.moment))
    }

    // MARK: Storing and undoing

    func testNookTargetRoundTrips() throws {
        let task = ScheduledTask(title: "Ochtendupdate", prompt: "Wat kwam er binnen?", rule: .fixedTime(hour: 9, minute: 0, weekdays: []),
                                 target: .nook, createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(task)
        let back = try JSONDecoder().decode(ScheduledTask.self, from: data)
        XCTAssertEqual(back.target, .nook)
        XCTAssertTrue(back.target.isNook)
        XCTAssertNil(back.target.sessionID)
        // The other targets are not Nook.
        XCTAssertFalse(ScheduledTaskTarget.existingSession(id: UUID()).isNook)
    }

    func testNookRunNoteSaysNobodyIsWatching() {
        let task = ScheduledTask(title: "Ochtendupdate", prompt: "x", rule: .interval(seconds: 3600), target: .nook, createdAt: Date())
        let note = NookTaskSchedule.runNote(task)
        XCTAssertTrue(note.contains("Ochtendupdate"))
        XCTAssertTrue(note.contains("Do not ask questions back"))
        XCTAssertTrue(note.contains("approves"))
    }

    func testSchedulingCanBeUndone() {
        let id = UUID().uuidString
        let step = Undo.step(tool: "schedule_nook_task", input: ["title": "Ochtendupdate"], result: "Scheduled: Ochtendupdate · Every day at 09:00 (id \(id))")
        XCTAssertEqual(step, Undo.Step(tool: "delete_nook_task", input: ["id": id, "title": "Ochtendupdate"]))
    }
}
