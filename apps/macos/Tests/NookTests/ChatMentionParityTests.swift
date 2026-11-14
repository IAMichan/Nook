import XCTest

/// A group that stays quiet still tells you when someone tags you, in every chat app that says who a message tags: each
/// app's parser reads its own tags into `InboxMessage.mentionsMe` through `ChatMentions.mentionsMe`, as WhatsApp's did.
final class ChatMentionParityTests: XCTestCase {
    func testSharedRuleNeedsYourOwnID() {
        XCTAssertTrue(ChatMentions.mentionsMe(["U1", "U2"], me: "U2"))
        XCTAssertFalse(ChatMentions.mentionsMe(["U1"], me: "U2"))
        XCTAssertFalse(ChatMentions.mentionsMe(["U1"], me: nil), "without knowing who you are, nobody tags you")
        XCTAssertFalse(ChatMentions.mentionsMe([""], me: ""))
    }

    func testSlackTagOfYouInAGroup() {
        let group = SlackData.Conversation(id: "G1", user: nil, name: "launch", isGroup: true, updated: 0)
        let history: [String: Any] = ["ok": true, "messages": [
            ["ts": "1700000010.000100", "user": "U1", "text": "<@U2|you> can you check?"],
            ["ts": "1700000011.000100", "user": "U1", "text": "<!here> standup"],
            ["ts": "1700000012.000100", "user": "U1", "text": "ping <@U3>"],
        ]]
        let messages = SlackData.messages(history, conversation: group, users: ["U1": "Anna", "U2": "Me"], me: "U2")
        XCTAssertEqual(messages.map(\.mentionsMe), [true, false, false], "only a tag of you counts, not @here")
        XCTAssertEqual(messages[0].text, "@you can you check?", "the text still shows the name")
        XCTAssertEqual(SlackData.mentionedIDs("<@U1> and <@U2|Jan> <#C1|general> <!channel>"), ["U1", "U2"])
    }

    func testTeamsGraphMention() {
        let chat = TeamsData.Chat(id: "19:g", name: "Launch", isGroup: true, last: nil, readUntil: nil)
        let history: [String: Any] = ["value": [
            ["id": "m1", "messageType": "message", "createdDateTime": "2026-10-22T09:00:00Z",
             "from": ["user": ["id": "u1", "displayName": "Anna"]],
             "body": ["contentType": "html", "content": "<p><at id=\"0\">Me</at> look</p>"],
             "mentions": [["id": 0, "mentionText": "Me", "mentioned": ["user": ["id": "me", "displayName": "Me"]]]]],
            ["id": "m2", "messageType": "message", "createdDateTime": "2026-10-22T09:01:00Z",
             "from": ["user": ["id": "u1", "displayName": "Anna"]],
             "body": ["contentType": "text", "content": "Jan look"],
             "mentions": [["id": 0, "mentioned": ["user": ["id": "u2"]]]]],
        ]]
        let messages = TeamsData.messages(history, chat: chat, me: "me")
        XCTAssertEqual(messages.map(\.mentionsMe), [true, false])
    }

    func testTeamsGraphImportanceIsKept() {
        let chat = TeamsData.Chat(id: "19:g", name: "Launch", isGroup: true, last: nil, readUntil: nil)
        func message(_ id: String, _ importance: String?) -> [String: Any] {
            var message: [String: Any] = ["id": id, "messageType": "message", "createdDateTime": "2026-10-22T09:00:0\(id)Z",
                                          "from": ["user": ["id": "u1", "displayName": "Anna"]],
                                          "body": ["contentType": "text", "content": "Look"]]
            message["importance"] = importance
            return message
        }
        let history: [String: Any] = ["value": [message("1", "normal"), message("2", "high"), message("3", "URGENT"), message("4", nil)]]
        XCTAssertEqual(TeamsData.messages(history, chat: chat, me: "me").map(\.importance), [nil, .high, .urgent, nil])
        var urgent = InboxMessage(id: "x", text: "Now", date: Date())
        urgent.importance = .urgent
        XCTAssertNil(urgent.withdrawn().importance, "a deleted message is no longer urgent")
    }

    func testTeamsWebMentionReadsWhatNookWrites() {
        let me = "8:orgid:me"
        let chat = TeamsData.Chat(id: "19:x@thread.v2", name: "Launch", isGroup: true, last: nil, readUntil: nil)
        let tagged = TeamsWebData.mentionsProperty([ChatTagPerson(name: "Me", id: me)])
        XCTAssertEqual(TeamsWebData.mentionedIDs(tagged), [me], "reads back what Nook sends")
        let history: [String: Any] = ["messages": [
            ["id": "5", "messagetype": "RichText/Html", "content": "<p>Me look</p>", "from": "https://x/contacts/8:orgid:jan",
             "composetime": "2026-10-26T14:21:00.000Z", "properties": ["mentions": tagged as Any]],
            ["id": "6", "messagetype": "RichText/Html", "content": "<p>nothing</p>", "from": "https://x/contacts/8:orgid:jan",
             "composetime": "2026-10-26T14:22:00.000Z"],
        ]]
        let messages = TeamsWebData.messages(history, chat: chat, me: me)
        XCTAssertEqual(messages.map(\.mentionsMe), [true, false])
    }

    func testTelegramMentionByEntityOrUnreadFlag() {
        let chat = TelegramData.Chat(id: -5, title: "Family", isGroup: true, unread: 0, order: 0)
        func message(_ id: Int, entities: [[String: Any]] = [], unreadMention: Bool = false) -> [String: Any] {
            ["@type": "message", "id": id, "date": 1_700_000_000, "is_outgoing": false,
             "contains_unread_mention": unreadMention,
             "sender_id": ["@type": "messageSenderUser", "user_id": 3],
             "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": "Me dinner?", "entities": entities]]]
        }
        let byName: [[String: Any]] = [["@type": "textEntity", "offset": 0, "length": 2,
                                        "type": ["@type": "textEntityTypeMentionName", "user_id": 42]]]
        XCTAssertEqual(TelegramData.message(message(1, entities: byName), chat: chat, users: [3: "Jan"], me: 42)?.mentionsMe, true)
        XCTAssertEqual(TelegramData.message(message(2, unreadMention: true), chat: chat, users: [3: "Jan"], me: 42)?.mentionsMe, true)
        XCTAssertEqual(TelegramData.message(message(3), chat: chat, users: [3: "Jan"], me: 42)?.mentionsMe, false)
        XCTAssertEqual(TelegramData.mentionedIDs(["@type": "messageText", "text": ["entities": byName]]), ["42"])
    }

    func testChatHelperMentionFromMatrixMentions() {
        let chat = ChatServiceData.Chat(id: "!room:nook.local", app: "signal", title: "Family", isGroup: true, unread: 0,
                                        last: nil, me: "@me:nook.local")
        let json: [String: Any] = ["items": [
            ["id": "$1", "timestamp": "2026-10-22T09:00:00Z", "senderID": "@signal_1:nook.local", "senderName": "Jan",
             "text": "Me dinner?", "mentions": ["@me:nook.local"]],
            ["id": "$2", "timestamp": "2026-10-22T09:01:00Z", "senderID": "@signal_1:nook.local", "senderName": "Jan",
             "text": "Anna dinner?", "mentions": ["@signal_2:nook.local"]],
            ["id": "$3", "timestamp": "2026-10-22T09:02:00Z", "senderID": "@signal_1:nook.local", "senderName": "Jan",
             "text": "no tags"],
        ]]
        XCTAssertEqual(ChatServiceData.messages(json, chat: chat).map(\.mentionsMe), [true, false, false])
        var person = chat
        person.isGroup = false
        XCTAssertEqual(ChatServiceData.messages(json, chat: person).map(\.mentionsMe), [nil, nil, nil],
                       "a private chat is about you anyway")
    }

    /// The same rule as WhatsApp's: a group kept quiet by its kind still tells you when a message tags you.
    func testQuietGroupStillTellsAMention() {
        var rules = ChatNoticeRules()
        rules.setQuiet(true, kind: .group, app: "slack")
        XCTAssertTrue(rules.isQuiet(chat: "slack-G1", app: "slack", kind: .group))
        XCTAssertFalse(rules.isQuiet(chat: "slack-G1", app: "slack", kind: .group, mentionsMe: true))
    }
}
