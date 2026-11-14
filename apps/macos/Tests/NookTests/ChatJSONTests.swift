import XCTest

/// What every chat bridge reads from a JSON answer, the same way: numbers however they are written, dates in seconds or
/// milliseconds that never fall back to 1970, ISO 8601 with or without a fraction, and the shared notice lines.
final class ChatJSONTests: XCTestCase {
    func testNumbersHoweverTheyAreWritten() throws {
        XCTAssertEqual(ChatJSON.number(3.5), 3.5)
        XCTAssertEqual(ChatJSON.number(3), 3)
        XCTAssertEqual(ChatJSON.number(Int64(7)), 7)
        XCTAssertEqual(ChatJSON.number(" 42 "), 42)
        XCTAssertEqual(ChatJSON.number(NSNumber(value: 9)), 9)
        XCTAssertNil(ChatJSON.number("abc"))
        XCTAssertNil(ChatJSON.number(nil))
        XCTAssertEqual(ChatJSON.int64("123456789012"), 123_456_789_012)
        XCTAssertEqual(ChatJSON.int64(12.9), 12)
        XCTAssertNil(ChatJSON.int64(Double.infinity))
        XCTAssertEqual(TelegramData.int64("5"), 5, "Telegram reads ids the shared way")
        XCTAssertEqual(AppData.number("2"), 2, "so do the apps' databases")
        // As JSONSerialization hands them over.
        let json = try XCTUnwrap(ChatJSON.object(Data(#"{"a": 1, "b": 2.5, "c": "3"}"#.utf8)))
        XCTAssertEqual(ChatJSON.number(json["a"]), 1)
        XCTAssertEqual(ChatJSON.number(json["b"]), 2.5)
        XCTAssertEqual(ChatJSON.int64(json["c"]), 3)
    }

    func testAMissingDateNeverBecomes1970() {
        XCTAssertEqual(ChatJSON.epoch(seconds: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(ChatJSON.epoch(seconds: "1800000000"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(ChatJSON.epoch(millis: "1800000000000"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(ChatJSON.epoch(seconds: 0))
        XCTAssertNil(ChatJSON.epoch(seconds: nil))
        XCTAssertNil(ChatJSON.epoch(millis: "nope"))
        XCTAssertEqual(ChatJSON.date("2026-10-22T09:14:56.123Z")?.timeIntervalSince1970 ?? 0, 1_792_660_496.123, accuracy: 0.001)
        XCTAssertEqual(ChatJSON.date("2026-10-22T09:14:56Z"), Date(timeIntervalSince1970: 1_792_660_496))
        XCTAssertEqual(ChatJSON.iso(Date(timeIntervalSince1970: 1_792_660_496)), "2026-10-22T09:14:56Z")
        // A Telegram message without a date (a scheduled one) is left out instead of standing at 1970.
        let chat = TelegramData.Chat(id: 1, title: "Anna", isGroup: false, unread: 0, order: 1)
        let undated: [String: Any] = ["@type": "message", "id": 5, "content": ["@type": "messageText", "text": ["text": "hi"]]]
        XCTAssertNil(TelegramData.message(undated, chat: chat, users: [:]))
        var dated = undated
        dated["date"] = 1_800_000_000
        XCTAssertEqual(TelegramData.message(dated, chat: chat, users: [:])?.date, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testNoticeLinesAreTheSameInEveryApp() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let added = InboxMessage.notice(id: "x", date: date, membership: ChatMembership(.added, by: ChatMembership.me, people: ["Anna"]))
        XCTAssertTrue(added.isMine)
        XCTAssertTrue(added.isNotice)
        XCTAssertEqual(added.text, "")
        let renamed = InboxMessage.notice(id: "y", date: date, groupChange: ChatGroupChange(.renamed, by: "Anna", text: "Team"))
        XCTAssertFalse(renamed.isMine)
        XCTAssertEqual(renamed.groupChange?.text, "Team")
        XCTAssertTrue(InboxMessage.notice(id: "z", date: date, groupChange: ChatGroupChange(.pinned), fromMe: true).isMine)
    }

    func testTeamsGraphAndWebsiteAgreeWhenCaughtUp() {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(TeamsData.caughtUp(newest: last.addingTimeInterval(-0.5), last: last), "a rounding apart is the same message")
        XCTAssertFalse(TeamsData.caughtUp(newest: last.addingTimeInterval(-5), last: last))
        XCTAssertFalse(TeamsData.caughtUp(newest: nil, last: last))
        XCTAssertTrue(TeamsData.caughtUp(newest: nil, last: nil))
        let web: [String: Any] = ["messages": [["composetime": "2026-10-22T09:14:56Z"]]]
        let graph: [String: Any] = ["value": [["createdDateTime": "2026-10-22T09:14:56Z"]]]
        let announced = ChatJSON.date("2026-10-22T09:14:56.400Z")
        XCTAssertEqual(TeamsWebData.caughtUp(web, last: announced), TeamsData.caughtUp(graph, last: announced))
    }
}
