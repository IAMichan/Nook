import XCTest

/// What every app says of a chat reaches the shared notice rules: a private chat with a bot stays quiet like a channel,
/// and a chat muted in its own app stays quiet like one muted in Nook, while its choice here is automatic.
final class ChatNoticeParityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(_ app: String, bot: Bool = false, mutedInApp: Bool? = nil, kind: ChatKind = .person) -> InboxThread {
        var thread = InboxThread(id: app + "|helper", app: app, name: "Helper", messages: [
            InboxMessage(id: "1", text: "Your code is 1234", date: now),
        ], unread: 1)
        thread.kind = kind
        if bot { thread.profile = ChatProfile(bot: true) }
        thread.mutedInApp = mutedInApp
        return thread
    }

    func testABotsPrivateChatIsQuietByDefaultInEveryAppThatSaysIt() {
        var rules = ChatNoticeRules()
        for app in ["slack", "telegram", "signal", "instagram", "messenger"] {
            let bot = thread(app, bot: true)
            XCTAssertTrue(bot.isAutomated, app)
            XCTAssertTrue(rules.isQuiet(bot), app)
            XCTAssertFalse(rules.isVisible(bot), "\(app): a bot does not count in the badge")
            XCTAssertFalse(rules.isQuiet(thread(app)), "\(app): a person still reaches you")
        }
        XCTAssertFalse(thread("telegram", bot: true, kind: .group).isAutomated, "a group is no bot's chat")
        let bot = thread("telegram", bot: true)
        rules.setMode(.loud, for: bot.id)
        XCTAssertFalse(rules.isQuiet(bot), "always lets a bot reach you")
        XCTAssertTrue(ChatPeople.people([bot]).isEmpty, "a bot is no person")
    }

    func testAChatMutedInItsAppIsQuietWhileAutomatic() {
        var rules = ChatNoticeRules()
        for app in ["telegram", "whatsapp", "signal", "instagram"] {
            let muted = thread(app, mutedInApp: true)
            XCTAssertTrue(rules.isQuiet(muted), app)
            XCTAssertTrue(rules.automaticIsQuiet(muted), app)
            XCTAssertFalse(rules.isVisible(muted), app)
            XCTAssertFalse(rules.isQuiet(thread(app, mutedInApp: false)), app)
        }
        var group = thread("telegram", mutedInApp: true, kind: .group)
        group.messages[0].mentionsMe = true
        XCTAssertTrue(rules.isQuiet(group, mentionsMe: true), "muted in the app is muted, also for a mention")
        let muted = thread("telegram", mutedInApp: true)
        rules.setMode(.loud, for: muted.id)
        XCTAssertFalse(rules.isQuiet(muted), "always in Nook wins over the app's mute")
    }

    func testTheAppsMuteReachesTheInboxAndStays() {
        var inbox = ChatInbox()
        var chat = BridgedChat(app: "telegram", name: "Anna", messages: [InboxMessage(id: "1", text: "hi", date: now)], unread: 1)
        chat.mutedInApp = true
        inbox.merge([chat], now: now)
        let id = ChatInbox.key(app: "telegram", chat: "Anna")
        XCTAssertEqual(inbox.threads[id]?.mutedInApp, true)
        var silent = BridgedChat(app: "telegram", name: "Anna", messages: [], unread: nil)
        XCTAssertFalse(inbox.merge([silent], now: now), "a read that does not say keeps what Nook knew")
        XCTAssertEqual(inbox.threads[id]?.mutedInApp, true)
        silent.mutedInApp = false
        XCTAssertTrue(inbox.merge([silent], now: now), "unmuted in the app: a change on its own")
        XCTAssertEqual(inbox.threads[id]?.mutedInApp, false)
    }

    func testSlackbotIsABot() {
        let people = SlackData.people(["members": [["id": "USLACKBOT", "name": "slackbot"], ["id": "U1", "name": "anna"]]])
        XCTAssertEqual(people["USLACKBOT"]?.bot, true)
        XCTAssertNil(people["U1"]?.bot)
    }
}
