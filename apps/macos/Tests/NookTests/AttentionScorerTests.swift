import XCTest

final class AttentionScorerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ need: AttentionItem.NeedsYou, source: String = "agents", app: String = "",
                      deadline: Date? = nil, since: Date? = nil, actionable: Bool = true) -> AttentionItem {
        AttentionItem(source: source, id: id, app: app, subject: id, needsYou: need, deadline: deadline, since: since,
                      actionable: actionable)
    }

    func testWhatItAsksComesFirst() {
        let scorer = AttentionScorer(now: now)
        let ranked = scorer.rank([item("info", .info), item("reply", .reply), item("approval", .approval),
                                  item("failure", .failure), item("question", .question), item("review", .review)])
        XCTAssertEqual(ranked.map(\.id), ["approval", "question", "failure", "reply", "review", "info"])
    }

    func testAMeetingSoonRisesAboveOtherInfo() {
        let scorer = AttentionScorer(now: now)
        let loop = item("loop", .info, source: "loops", since: now.addingTimeInterval(-3 * 86_400))
        let meeting = item("meeting", .info, source: "calendar", deadline: now.addingTimeInterval(1800))
        let tomorrow = item("tomorrow", .info, source: "calendar", deadline: now.addingTimeInterval(20 * 3600))
        XCTAssertEqual(scorer.rank([loop, tomorrow, meeting]).map(\.id), ["meeting", "loop", "tomorrow"])
    }

    func testWaitingLongerClimbsWithinItsKind() {
        let scorer = AttentionScorer(now: now)
        let fresh = item("fresh", .reply, source: "chats", since: now.addingTimeInterval(-3600))
        let old = item("old", .reply, source: "chats", since: now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(scorer.rank([fresh, old]).map(\.id), ["old", "fresh"])
        // Never above the next kind up.
        XCTAssertGreaterThan(scorer.score(item("q", .question)), scorer.score(old))
    }

    func testFeedbackMovesItWithinLimits() {
        var feedback = AttentionFeedback()
        for _ in 0..<8 { feedback.record(.dismissed, source: "chats", app: "slack", at: now) }
        let scorer = AttentionScorer(feedback: feedback, now: now)
        let slack = item("slack", .reply, source: "chats", app: "slack")
        let mail = item("mail", .reply, source: "chats", app: "mail")
        XCTAssertEqual(scorer.rank([slack, mail]).map(\.id), ["mail", "slack"])
        XCTAssertGreaterThan(scorer.score(slack), AttentionScorer.base(.reply) - 10)
    }

    func testEqualScoresKeepTheirOrder() {
        let scorer = AttentionScorer(now: now)
        XCTAssertEqual(scorer.rank([item("a", .info), item("b", .info), item("c", .info)]).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(scorer.rank(["x", "y"], by: { self.item($0, .info) }), ["x", "y"])
    }

    func testTopNeedSkipsInfo() {
        let scorer = AttentionScorer(now: now)
        XCTAssertNil(scorer.topNeed([item("info", .info)]))
        XCTAssertEqual(scorer.topNeed([item("info", .info, deadline: now), item("reply", .reply)])?.id, "reply")
    }

    func testAgentItemsFollowTheAgentsList() {
        XCTAssertEqual(AttentionItem.agent(id: "1", app: "codex", attention: .approval)?.needsYou, .approval)
        XCTAssertEqual(AttentionItem.agent(id: "1", app: "codex", attention: .input)?.needsYou, .question)
        XCTAssertEqual(AttentionItem.agent(id: "1", app: "codex", attention: .limited)?.needsYou, .failure)
        XCTAssertNil(AttentionItem.agent(id: "1", app: "codex", attention: .working))
        XCTAssertNil(AttentionItem.agent(id: "1", app: "codex", attention: .ready))
    }

    func testOwedChatsAndBirthdaysAreItems() {
        let turn = ChatFollowUpTurn(chat: "wa:1", app: "whatsapp", name: "Lisa", kind: .person,
                                    date: now.addingTimeInterval(-5 * 3600), lastIsMine: false, lastText: "Kom je?", unread: 1)
        let owed = AttentionItem.owed(turn)
        XCTAssertEqual(owed.needsYou, .reply)
        XCTAssertEqual(owed.person, "Lisa")
        XCTAssertEqual(owed.since, turn.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let birthday = AttentionItem.birthday(person: "name:lisa", name: "Lisa", on: now, calendar: calendar)
        XCTAssertEqual(birthday.needsYou, .info)
        XCTAssertEqual(birthday.deadline, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
    }
}
