import XCTest

/// Writing in Slack from Nook, and reading what that changes: message ids back to Slack's `ts`, answers in a thread,
/// emoji by Slack's names, and the requests the write methods get.
final class SlackActionsTests: XCTestCase {
    private let direct = SlackData.Conversation(id: "D1", user: "U1", name: "", isGroup: false, updated: 0)

    func testMessageIDsTurnBackIntoSlackTimestamps() {
        let id = SlackData.messageID(conversation: "D1", ts: "1700000010.000100")
        XCTAssertEqual(id, "slack-D1-1700000010.000100")
        XCTAssertEqual(SlackData.ts(of: id, conversation: "D1"), "1700000010.000100")
        XCTAssertNil(SlackData.ts(of: id, conversation: "D2"), "a message of another conversation")
        XCTAssertNil(SlackData.ts(of: "telegram-42", conversation: "D1"))
        XCTAssertNil(SlackData.ts(of: "slack-D1-x", conversation: "D1"))
    }

    func testReactionsAreReadAsEmojiWithYoursMarked() {
        let history: [String: Any] = ["ok": true, "messages": [
            ["ts": "1700000010.000100", "user": "U1", "text": "hello", "reactions": [
                ["name": "joy", "count": 1, "users": ["U1"]],
                ["name": "+1", "count": 2, "users": ["U1", "U2"]],
                ["name": "+1::skin-tone-3", "count": 1, "users": ["U3"]],
                ["name": "partyparrot", "count": 4, "users": ["U1"]],
            ]],
            ["ts": "1700000020.000100", "user": "U2", "text": "plain"],
        ]]
        let messages = SlackData.messages(history, conversation: direct, users: [:], me: "U2")
        XCTAssertEqual(messages[0].reactions, [
            InboxReaction(emoji: "👍", count: 3, mine: true),
            InboxReaction(emoji: "😂", count: 1, mine: false),
        ], "a skin tone counts with its emoji, the most used first, a workspace's own emoji left out")
        XCTAssertEqual(messages[1].reactions, [], "none is said too, so one taken back in Slack goes in Nook")
    }

    func testAnswerInAThreadQuotesTheThreadsFirstMessage() {
        let history: [String: Any] = ["ok": true, "messages": [
            ["ts": "1700000030.000100", "thread_ts": "1700000010.000100", "subtype": "thread_broadcast", "user": "U2",
             "text": "sure", "root": ["ts": "1700000010.000100", "user": "U1", "text": "lunch?"]],
            ["ts": "1700000010.000100", "thread_ts": "1700000010.000100", "user": "U1", "text": "lunch?", "reply_count": 1],
        ]]
        let messages = SlackData.messages(history, conversation: direct, users: ["U1": "Anna"], me: "U2")
        XCTAssertEqual(messages.map(\.text), ["lunch?", "sure"])
        XCTAssertNil(messages[0].quote, "the thread's first message answers nothing")
        XCTAssertEqual(messages[1].quote, InboxQuote(id: "slack-D1-1700000010.000100", sender: "Anna", text: "lunch?", mine: false))
    }

    func testDeletedMessageWithAnswersIsLeftOut() {
        let history: [String: Any] = ["ok": true, "messages": [
            ["ts": "1700000010.000100", "subtype": "tombstone", "user": "USLACKBOT", "text": "This message was deleted."],
        ]]
        XCTAssertTrue(SlackData.messages(history, conversation: direct, users: [:], me: "U2").isEmpty)
    }

    func testEmojiByName() {
        XCTAssertEqual(SlackData.emoji(shortcode: "+1"), "👍")
        XCTAssertEqual(SlackData.emoji(shortcode: "thumbsup"), "👍")
        XCTAssertEqual(SlackData.emoji(shortcode: "heart"), "❤️")
        XCTAssertEqual(SlackData.emoji(shortcode: ":fire:"), "🔥")
        XCTAssertEqual(SlackData.emoji(shortcode: "wave::skin-tone-2"), "👋")
        XCTAssertNil(SlackData.emoji(shortcode: "partyparrot"))
    }

    func testEveryQuickReactionHasASlackName() {
        let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
        XCTAssertEqual(quick.compactMap { SlackData.shortcode(emoji: $0) }, ["+1", "heart", "joy", "open_mouth", "cry", "pray"])
        for emoji in quick {
            XCTAssertEqual(SlackData.shortcode(emoji: emoji).flatMap { SlackData.emoji(shortcode: $0) }, emoji, "\(emoji) reads back as itself")
        }
        XCTAssertEqual(SlackData.shortcode(emoji: "❤"), "heart", "without the variation selector too")
        XCTAssertEqual(SlackData.shortcode(emoji: "👍🏽"), "+1::skin-tone-4")
        XCTAssertNil(SlackData.shortcode(emoji: "🦑"), "an emoji Nook knows no Slack name of")
    }

    func testPostFieldsAnswerInTheThreadAndTheConversation() {
        XCTAssertEqual(SlackData.postFields(channel: "D1", text: "a < b & c", thread: nil),
                       ["channel": "D1", "text": "a &lt; b &amp; c"])
        XCTAssertEqual(SlackData.postFields(channel: "D1", text: "yes", thread: "1700000010.000100"),
                       ["channel": "D1", "text": "yes", "thread_ts": "1700000010.000100", "reply_broadcast": "true"])
    }

    func testFormIsEscaped() {
        let body = String(decoding: SlackData.form(["text": "hi & bye=1", "channel": "D1"]), as: UTF8.self)
        XCTAssertEqual(body, "channel=D1&text=hi%20%26%20bye%3D1")
    }

    func testUploadSteps() {
        let target = SlackData.uploadTarget(["ok": true, "upload_url": "https://files.slack.com/upload/v1/abc", "file_id": "F1"])
        XCTAssertEqual(target?.url.absoluteString, "https://files.slack.com/upload/v1/abc")
        XCTAssertEqual(target?.file, "F1")
        XCTAssertNil(SlackData.uploadTarget(["ok": true, "upload_url": "https://example.com/upload", "file_id": "F1"]),
                     "the token only goes to Slack's own addresses")
        let fields = SlackData.completeFields(channel: "D1", file: "F1", title: "plan.pdf", caption: " the plan ", thread: "1700000010.000100")
        XCTAssertEqual(fields["channel_id"], "D1")
        XCTAssertEqual(fields["initial_comment"], "the plan")
        XCTAssertEqual(fields["thread_ts"], "1700000010.000100")
        XCTAssertEqual(fields["files"], #"[{"id":"F1","title":"plan.pdf"}]"#)
        XCTAssertNil(SlackData.completeFields(channel: "D1", file: "F1", title: "a", caption: "", thread: nil)["initial_comment"])
    }

    func testNewestTimestampAndMissingScope() {
        XCTAssertEqual(SlackData.newestTS(["messages": [["ts": "1700000002.000100"], ["ts": "1700000010.000100"]]]), "1700000010.000100")
        XCTAssertNil(SlackData.newestTS(["messages": []]))
        XCTAssertEqual(SlackData.error(["ok": false, "error": "missing_scope", "needed": "chat:write"]), "missing_scope (chat:write)")
    }

    /// A huddle shows as a call once it ended, or as missed; one still going says nothing yet.
    func testAHuddleIsACall() {
        let ended: [String: Any] = ["subtype": "huddle_thread", "room": ["date_start": 1_700_000_000, "date_end": 1_700_000_125, "has_ended": true]]
        XCTAssertEqual(SlackData.huddle(ended)?.seconds, 125)
        XCTAssertEqual(SlackData.huddle(ended).flatMap { ChatFormat.call($0.line) }?.seconds, 125, "reads back as a call")
        let missed: [String: Any] = ["subtype": "huddle_thread", "room": ["date_start": 1_700_000_000, "was_missed": true]]
        XCTAssertEqual(SlackData.huddle(missed)?.missed, true)
        XCTAssertNotNil(SlackData.huddle(missed).flatMap { ChatFormat.call($0.line) })
        let going: [String: Any] = ["subtype": "huddle_thread", "room": ["date_start": 1_700_000_000, "has_ended": false]]
        XCTAssertNil(SlackData.huddle(going))
        XCTAssertNil(SlackData.huddle(["text": "hi"]))
    }

    /// Slack's own read position counts what is unread in Slack itself.
    func testReadMarksCountUnread() {
        let json: [String: Any] = ["ok": true, "ims": [["id": "D1", "last_read": "1700000010.000100"]],
                                   "mpims": [["id": "G1", "last_read": "0000000000.000000"]], "channels": [["id": "C1", "last_read": "1"]]]
        XCTAssertEqual(SlackData.readMarks(json), ["D1": "1700000010.000100", "G1": "0000000000.000000"])
        let read = Date(timeIntervalSince1970: 1_700_000_010.000100).timeIntervalSince1970
        let messages = [(ts: read, mine: false), (ts: 1_700_000_020.0, mine: false), (ts: 1_700_000_030.0, mine: true)]
        XCTAssertEqual(SlackData.unread(messages, lastRead: "1700000010.000100"), 1, "the read one and yours are not unread")
        XCTAssertEqual(SlackData.unread(messages, lastRead: "1700000030.000000"), 0)
    }
}
