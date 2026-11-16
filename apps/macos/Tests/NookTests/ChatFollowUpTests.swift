import XCTest

/// Follow-ups, people and connector health: the same rules for every chat app and every connector.
final class ChatFollowUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func turn(_ chat: String, mine: Bool = false, hoursAgo: Double, text: String = "hi", kind: ChatKind = .person) -> ChatFollowUpTurn {
        ChatFollowUpTurn(chat: chat, app: "whatsapp", name: chat, kind: kind, date: now.addingTimeInterval(-hoursAgo * 3600),
                 lastIsMine: mine, lastText: text, unread: mine ? 0 : 1)
    }

    func testAChatOwesAnAnswerOnlyWhenTheirWordIsLastAndHasWaited() {
        let follow = ChatFollowUps()
        let owed = follow.owed([turn("fresh", hoursAgo: 0.1), turn("old", hoursAgo: 30), turn("mine", mine: true, hoursAgo: 30),
                                turn("group", hoursAgo: 30, kind: .group), turn("ancient", hoursAgo: 24 * 30)], now: now)
        XCTAssertEqual(owed.map(\.chat), ["old"])
    }

    func testQuestionsComeFirstThenTheOldest() {
        let owed = ChatFollowUps().owed([turn("a", hoursAgo: 50), turn("b", hoursAgo: 10, text: "Are you coming?"), turn("c", hoursAgo: 20)], now: now)
        XCTAssertEqual(owed.map(\.chat), ["b", "a", "c"])
    }

    func testSnoozedChatsLeaveAndComeBack() {
        var follow = ChatFollowUps()
        follow.snooze(chat: "old", until: now.addingTimeInterval(3600))
        XCTAssertTrue(follow.owed([turn("old", hoursAgo: 30)], now: now).isEmpty)
        XCTAssertEqual(follow.owed([turn("old", hoursAgo: 30)], now: now.addingTimeInterval(7200)).count, 1)
        XCTAssertTrue(follow.settle(with: [turn("old", hoursAgo: 30)], now: now.addingTimeInterval(7200)))
        XCTAssertNil(follow.snoozed["old"], "a snooze past its time is forgotten")
    }

    func testWaitingForAReplyRemindsOnceThenSettlesWhenTheyAnswer() {
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "anna", now: now)
        XCTAssertTrue(follow.dueReminders(now: now.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(follow.dueReminders(now: now.addingTimeInterval(25 * 3600)), ["anna"])
        follow.acknowledge(chat: "anna", now: now.addingTimeInterval(25 * 3600))
        XCTAssertTrue(follow.dueReminders(now: now.addingTimeInterval(26 * 3600)).isEmpty)
        let answered = ChatFollowUpTurn(chat: "anna", app: "telegram", name: "Anna", kind: .person, date: now.addingTimeInterval(60),
                                lastIsMine: false, lastText: "Sorry!", unread: 1)
        XCTAssertTrue(follow.answered(answered))
        XCTAssertTrue(follow.settle(with: [answered], now: now.addingTimeInterval(120)))
        XCTAssertFalse(follow.isWaiting("anna"))
    }

    func testYourOwnMessageDoesNotAnswerYourWait() {
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "anna", now: now)
        let mine = ChatFollowUpTurn(chat: "anna", app: "signal", name: "Anna", kind: .person, date: now.addingTimeInterval(60),
                            lastIsMine: true, lastText: "ping", unread: 0)
        XCTAssertFalse(follow.answered(mine))
        XCTAssertFalse(follow.settle(with: [mine], now: now.addingTimeInterval(120)))
    }

    func testAChatGoneFromTheListLosesItsWait() {
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "gone", now: now)
        XCTAssertTrue(follow.settle(with: [], now: now))
        XCTAssertTrue(follow.waiting.isEmpty)
    }

    func testScheduledSendsGoWhenDueAndCancel() {
        var follow = ChatFollowUps()
        let later = ChatScheduledSend(chat: "anna", text: "Happy birthday!", sendAt: now.addingTimeInterval(3600))
        let sooner = ChatScheduledSend(chat: "bob", text: "On my way", sendAt: now.addingTimeInterval(60))
        XCTAssertTrue(later.isValid(now: now))
        XCTAssertFalse(ChatScheduledSend(chat: "x", text: "  ", sendAt: now.addingTimeInterval(60)).isValid(now: now))
        XCTAssertFalse(ChatScheduledSend(chat: "x", text: "late", sendAt: now.addingTimeInterval(-60)).isValid(now: now))
        follow.schedule(later)
        follow.schedule(sooner)
        XCTAssertEqual(follow.scheduled.map(\.chat), ["bob", "anna"], "kept in the order they go")
        XCTAssertEqual(follow.dueSends(now: now.addingTimeInterval(120)).map(\.chat), ["bob"])
        follow.cancelScheduled(id: sooner.id)
        XCTAssertTrue(follow.dueSends(now: now.addingTimeInterval(120)).isEmpty)
        XCTAssertEqual(follow.scheduled(for: "anna").count, 1)
    }

    func testFollowUpsSurviveAnOlderSavedFile() throws {
        let old = try JSONDecoder().decode(ChatFollowUps.self, from: Data("{}".utf8))
        XCTAssertEqual(old, ChatFollowUps())
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "anna", now: now)
        follow.snooze(chat: "bob", until: now)
        let again = try JSONDecoder().decode(ChatFollowUps.self, from: try JSONEncoder().encode(follow))
        XCTAssertEqual(again, follow)
    }

    func testLaterOptionsLandInTheFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_800_000_000) // a Friday
        for option in ChatLaterOption.allCases { XCTAssertGreaterThan(option.date(from: morning, calendar: calendar), morning, "\(option)") }
        let evening = ChatLaterOption.thisEvening.date(from: morning, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: evening), 18)
        let tomorrow = ChatLaterOption.tomorrowMorning.date(from: morning, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 9)
        let week = ChatLaterOption.nextWeek.date(from: morning, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: week), 2, "Monday")
    }

    // MARK: Turn from a thread

    func testATurnReadsTheNewestRealMessageOfAnyApp() {
        let thread = InboxThread(id: "signal|anna", app: "signal", name: "Anna", messages: [
            InboxMessage(id: "1", text: "Dinner?", date: now.addingTimeInterval(-7200)),
            InboxMessage(id: "2", text: "Yes!", date: now.addingTimeInterval(-3600), fromMe: true),
        ], unread: 0)
        let turn = ChatFollowUpTurn(thread)
        XCTAssertTrue(turn.lastIsMine)
        XCTAssertEqual(turn.lastText, "Yes!")
        XCTAssertEqual(turn.kind, .person)
    }

    // MARK: People

    private func thread(_ app: String, _ name: String, handle: String? = nil, hoursAgo: Double, unread: Int = 0, group: Bool = false) -> InboxThread {
        var thread = InboxThread(id: app + "|" + name, app: app, name: name, messages: [
            InboxMessage(id: "m", text: "hello", date: now.addingTimeInterval(-hoursAgo * 3600)),
        ], unread: unread)
        thread.handle = handle
        thread.kind = group ? .group : .person
        return thread
    }

    func testOnePersonIsOneCardAcrossApps() {
        let people = ChatPeople.people([
            thread("whatsapp", "Anna de Vries", handle: "+31 6 1234 5678", hoursAgo: 5, unread: 1),
            thread("telegram", "Anna", handle: "0612345678", hoursAgo: 2, unread: 2),
            thread("messages", "anna de vries", hoursAgo: 9),
            thread("slack", "Team", hoursAgo: 1, group: true),
            thread("signal", "Bob", hoursAgo: 1),
        ])
        XCTAssertEqual(people.count, 3, "a group is no person; the number joins Anna's two chats, the name is its own key")
        let anna = people.first { $0.chats.count == 2 }
        XCTAssertEqual(anna?.apps, ["telegram", "whatsapp"], "the app written in last first")
        XCTAssertEqual(anna?.unread, 3)
    }

    func testPeopleAreSortedByLastWordAndSearchedWithoutAccents() {
        let people = ChatPeople.people([thread("whatsapp", "Zoë", hoursAgo: 1), thread("signal", "Bob", hoursAgo: 3)])
        XCTAssertEqual(people.map(\.name), ["Zoë", "Bob"])
        XCTAssertEqual(ChatPeople.search(people, "zoe").map(\.name), ["Zoë"])
        XCTAssertEqual(ChatPeople.search(people, "").count, 2)
    }

    func testNotesAndBirthdaysAreKeptPerPerson() {
        var notes = ChatPersonNotes()
        notes.setNote("Likes oat milk", for: "name:anna")
        notes.setBirthday(NookMonthDay(month: 3, day: 14), for: "name:anna")
        XCTAssertEqual(notes.note(for: "name:anna"), "Likes oat milk")
        XCTAssertEqual(notes.birthday(for: "name:anna")?.stored, "03-14")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12))!
        XCTAssertEqual(notes.birthdays(on: day, calendar: calendar), ["name:anna"])
        notes.setNote("", for: "name:anna")
        notes.setBirthday(nil, for: "name:anna")
        XCTAssertTrue(notes.entries.isEmpty, "an empty entry is not kept")
    }

    // MARK: Connector health

    func testHealthListsOnlyBrokenConnectorsAndPicksTheRightFix() {
        let entries = ConnectorHealth.entries([
            (id: "cal", title: "Calendar", kind: nil, detail: ""),
            (id: "stripe", title: "Stripe", kind: .network, detail: "offline"),
            (id: "github", title: "GitHub", kind: .auth, detail: "401"),
        ])
        XCTAssertEqual(entries.map(\.id), ["github", "stripe"], "what needs you comes first")
        XCTAssertEqual(entries.first?.fix, .reconnect)
        XCTAssertEqual(entries.last?.fix, .retry)
        XCTAssertEqual(entries.first?.reasonKey, "connectors.health.reason.auth")
        XCTAssertEqual(ConnectorHealth.fix(for: .config), .reconnect)
        XCTAssertEqual(ConnectorHealth.fix(for: .rateLimited), .retry)
    }

    func testGallerySearchIgnoresCaseAccentsAndWordOrder() {
        XCTAssertTrue(ConnectorGallerySearch.matches("", in: ["GitHub"]))
        XCTAssertTrue(ConnectorGallerySearch.matches("git hub", in: ["GitHub", "code"]), "every word is found, in any order")
        XCTAssertTrue(ConnectorGallerySearch.matches("code github", in: ["GitHub", "Code hosting"]))
        XCTAssertTrue(ConnectorGallerySearch.matches("calendario", in: ["Calendário"]))
        XCTAssertFalse(ConnectorGallerySearch.matches("stripe", in: ["GitHub"]))
    }
}
