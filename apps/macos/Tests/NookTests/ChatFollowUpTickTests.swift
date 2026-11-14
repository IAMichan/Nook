import XCTest

final class ChatFollowUpTickTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingToDoCostsNothing() {
        XCTAssertFalse(ChatFollowUpTick.hasWork(ChatFollowUps()))
        var follow = ChatFollowUps()
        follow.snooze(chat: "a", until: now.addingTimeInterval(60))
        XCTAssertTrue(ChatFollowUpTick.hasWork(follow))
        XCTAssertTrue(ChatFollowUpTick.plan(ChatFollowUps(), chats: ["a"], now: now).isEmpty)
    }

    func testDueRemindersForChatsThatAreStillThere() {
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "lisa", now: now.addingTimeInterval(-2 * 86_400), after: 3600)
        follow.markWaiting(chat: "gone", now: now.addingTimeInterval(-2 * 86_400), after: 3600)
        follow.markWaiting(chat: "later", now: now, after: 3600)
        let plan = ChatFollowUpTick.plan(follow, chats: ["lisa", "later"], now: now)
        XCTAssertEqual(plan.reminders, ["lisa"])
        // Acknowledged, it waits another day.
        follow.acknowledge(chat: "lisa", now: now)
        XCTAssertTrue(ChatFollowUpTick.plan(follow, chats: ["lisa"], now: now.addingTimeInterval(3600)).reminders.isEmpty)
    }

    func testASnoozedChatIsNotReminded() {
        var follow = ChatFollowUps()
        follow.markWaiting(chat: "lisa", now: now.addingTimeInterval(-2 * 86_400), after: 3600)
        follow.snooze(chat: "lisa", until: now.addingTimeInterval(600))
        XCTAssertTrue(ChatFollowUpTick.plan(follow, chats: ["lisa"], now: now).reminders.isEmpty)
    }

    func testScheduledMessagesGoOnTimeAndAskWhenLate() {
        var follow = ChatFollowUps()
        let onTime = ChatScheduledSend(chat: "lisa", text: "Good morning", sendAt: now.addingTimeInterval(-30))
        let late = ChatScheduledSend(chat: "lisa", text: "See you", sendAt: now.addingTimeInterval(-ChatFollowUpTick.lateLimit - 60))
        let gone = ChatScheduledSend(chat: "gone", text: "Hi", sendAt: now.addingTimeInterval(-30))
        let future = ChatScheduledSend(chat: "lisa", text: "Later", sendAt: now.addingTimeInterval(600))
        [onTime, late, gone, future].forEach { follow.schedule($0) }
        let plan = ChatFollowUpTick.plan(follow, chats: ["lisa"], now: now)
        XCTAssertEqual(plan.sends, [onTime])
        XCTAssertEqual(Set(plan.confirm.map(\.id)), [late.id, gone.id])
    }
}

final class ChatNoticePriorityTests: XCTestCase {
    func testAQuestionInAPrivateChat() {
        XCTAssertTrue(ChatNoticePriority.raises(kind: .person, mentionsMe: false, asksQuestion: true, quietByKind: false, mode: .automatic))
        XCTAssertFalse(ChatNoticePriority.raises(kind: .person, mentionsMe: false, asksQuestion: false, quietByKind: false, mode: .automatic))
    }

    func testAMentionInAQuietGroupOnly() {
        XCTAssertTrue(ChatNoticePriority.raises(kind: .group, mentionsMe: true, asksQuestion: false, quietByKind: true, mode: .automatic))
        // A group that tells you everything anyway gets no priority for a mention, nor for a question.
        XCTAssertFalse(ChatNoticePriority.raises(kind: .group, mentionsMe: true, asksQuestion: true, quietByKind: false, mode: .automatic))
        XCTAssertFalse(ChatNoticePriority.raises(kind: .group, mentionsMe: false, asksQuestion: true, quietByKind: true, mode: .automatic))
    }

    func testMutedChatsAndChannelsNever() {
        XCTAssertFalse(ChatNoticePriority.raises(kind: .person, mentionsMe: true, asksQuestion: true, quietByKind: false, mode: .muted))
        XCTAssertFalse(ChatNoticePriority.raises(kind: .channel, mentionsMe: true, asksQuestion: true, quietByKind: true, mode: .loud))
    }

    func testPriorityPassesABurstButKeepsTheGaps() {
        var pacer = NoticePacer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<NoticePacer.burstLimit {
            pacer.record(key: "chat:\(index)", now: start.addingTimeInterval(Double(index) * 30))
        }
        let later = start.addingTimeInterval(Double(NoticePacer.burstLimit) * 30)
        XCTAssertFalse(pacer.permits(key: "chat:new", now: later))
        XCTAssertTrue(pacer.permits(key: "chat:new", priority: true, now: later))
        // The gap after the last pop-up still holds, and the one-per-chat gap too.
        XCTAssertFalse(pacer.permits(key: "chat:new", priority: true, now: later.addingTimeInterval(-25)))
        XCTAssertFalse(pacer.permits(key: "chat:0", priority: true, now: start.addingTimeInterval(100)))
        // It never bypasses the rules: priority is not urgency.
        var rules = NoticeRules()
        rules.set(.chats, app: "slack", on: false)
        XCTAssertEqual(rules.decide(.chats, app: "slack"), .historyOnly)
    }
}
