import XCTest

final class SnapchatWebDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ sender: String, _ text: String) -> SnapchatWebData.Line {
        SnapchatWebData.Line(sender: sender, text: text)
    }

    func testOnlyTheChatPageCounts() {
        XCTAssertTrue(SnapchatWebData.isChatPage(URL(string: "https://www.snapchat.com/web")))
        XCTAssertTrue(SnapchatWebData.isChatPage(URL(string: "https://www.snapchat.com/web/6f1c2a7e-1111-2222-3333-444455556666")))
        XCTAssertTrue(SnapchatWebData.isChatPage(URL(string: "https://web.snapchat.com/")))
        XCTAssertFalse(SnapchatWebData.isChatPage(URL(string: "https://accounts.snapchat.com/accounts/v2/login")))
        XCTAssertFalse(SnapchatWebData.isChatPage(URL(string: "https://www.snapchat.com/download")))
        XCTAssertFalse(SnapchatWebData.isChatPage(nil))
    }

    func testTheListBecomesRows() {
        let answer: [String: Any] = ["status": "ok", "chats": [
            ["id": "6f1c2a7e-1111-2222-3333-444455556666", "name": "Anna", "status": "New Chat · 3m", "bold": false],
            ["id": "", "name": "Team trip", "status": "Received · 2h", "bold": true],
            ["id": "6f1c2a7e-1111-2222-3333-444455556666", "name": "Anna", "status": "again", "bold": false],
            ["id": "x", "name": "  ", "status": ""],
        ]]
        guard case .chats(let rows) = SnapchatWebData.listOutcome(answer) else { return XCTFail("no rows") }
        XCTAssertEqual(rows.map(\.name), ["Anna", "Team trip"], "a chat counts once, a nameless one not at all")
        XCTAssertEqual(rows[1].id, "Team trip", "without an address the name is the id")
        XCTAssertTrue(rows[0].isUnread, "Snapchat's \"New Chat\"")
        XCTAssertTrue(rows[1].isUnread, "shown in bold")
        XCTAssertFalse(SnapchatWebData.Row(id: "a", name: "A", status: "Opened · 1d", bold: false).isUnread)
        XCTAssertTrue(SnapchatWebData.Row(id: "a", name: "A", status: "Nieuwe chat", bold: false).isUnread)

        XCTAssertEqual(SnapchatWebData.listOutcome(["status": "signedOut"]), .signedOut)
        XCTAssertEqual(SnapchatWebData.listOutcome(["status": "loading"]), .waiting)
        XCTAssertEqual(SnapchatWebData.listOutcome(["status": "ok", "chats": [Any]()] as [String: Any]), .waiting)
        XCTAssertEqual(SnapchatWebData.listOutcome(["status": "failed", "step": "list"]), .failed("list"))
        XCTAssertEqual(SnapchatWebData.listOutcome(nil), .failed("answer"))
    }

    func testTheOpenChatBecomesLines() {
        let answer: [String: Any] = ["status": "ok", "lines": [
            ["sender": "ANNA", "text": "Hey!"],
            ["sender": "ME", "text": " Hi "],
            ["sender": "Me", "text": "", "media": true],
            ["sender": "ANNA", "text": ""],
        ]]
        guard case .lines(let lines) = SnapchatWebData.readOutcome(answer) else { return XCTFail("no lines") }
        XCTAssertEqual(lines.map(\.text), ["Hey!", "Hi", ""], "an empty line without a snap is left out")
        XCTAssertEqual(lines.map(\.isMine), [false, true, true])
        XCTAssertTrue(lines[2].media)
        XCTAssertTrue(SnapchatWebData.Line(sender: "Ik", text: "x").isMine, "Snapchat in Dutch")
        XCTAssertEqual(SnapchatWebData.readOutcome(["status": "noChat"]), .noChat)
        XCTAssertEqual(SnapchatWebData.readOutcome(["status": "signedOut"]), .signedOut)
    }

    func testSendOutcomes() {
        XCTAssertEqual(SnapchatWebData.sendOutcome(["status": "sent"]), .sent)
        XCTAssertEqual(SnapchatWebData.sendOutcome(["status": "draft"]), .draft)
        XCTAssertEqual(SnapchatWebData.sendOutcome(["status": "notSent"]), .notSent)
        XCTAssertEqual(SnapchatWebData.sendOutcome(["status": "failed", "step": "type"]), .failed("type"))
        XCTAssertEqual(SnapchatWebData.sendOutcome(42), .failed("answer"))
    }

    func testTheFirstReadKeepsTheOrderBeforeNow() {
        let kept = SnapchatWebData.align([], with: [line("ANNA", "a"), line("ME", "b")], chat: "c", now: now)
        XCTAssertEqual(kept.map(\.line.text), ["a", "b"])
        XCTAssertTrue(kept[0].date < kept[1].date)
        XCTAssertTrue(kept.allSatisfy { $0.date < now })
        XCTAssertEqual(Set(kept.map(\.id)).count, 2)
    }

    func testANewReadAddsOnlyWhatCameAfter() {
        let first = SnapchatWebData.align([], with: [line("ANNA", "hi"), line("ME", "hey"), line("ANNA", "ok")], chat: "c", now: now)
        // Snapchat deleted the first message after it was seen; two new ones came in, one with the same text as before.
        let later = now.addingTimeInterval(60)
        let read = [line("ME", "hey"), line("ANNA", "ok"), line("ME", "so?"), line("ANNA", "ok")]
        let second = SnapchatWebData.align(first, with: read, chat: "c", now: later)
        XCTAssertEqual(second.map(\.line.text), ["hi", "hey", "ok", "so?", "ok"], "what Snapchat deleted stays in Nook")
        XCTAssertEqual(Array(second.prefix(3).map(\.id)), first.map(\.id), "known messages keep their ids")
        XCTAssertTrue(second[3].date >= later && second[4].date > second[3].date)
        XCTAssertEqual(SnapchatWebData.align(second, with: read, chat: "c", now: later.addingTimeInterval(60)), second,
                       "reading the same again changes nothing")
        XCTAssertEqual(SnapchatWebData.align(second, with: [], chat: "c", now: later), second)
    }

    func testAPrivateChatAndAGroup() {
        let row = SnapchatWebData.Row(id: "c", name: "Anna", status: "New Chat", bold: false)
        let single = SnapchatWebData.align([], with: [line("ANNA", "hi"), line("ME", "yo")], chat: "c", now: now)
        let chat = SnapchatWebData.chat(row, kept: single, snapLabel: "Snap")
        XCTAssertEqual(chat.app, "snapchat")
        XCTAssertEqual(chat.name, "Anna")
        XCTAssertEqual(chat.unread, 1)
        XCTAssertTrue(chat.listed)
        XCTAssertNil(chat.members)
        XCTAssertEqual(chat.messages.map(\.sender), ["", ""], "a private chat's name already says who")
        XCTAssertEqual(chat.messages.map(\.isMine), [false, true])

        var snap = SnapchatWebData.Line(sender: "BOB", text: "")
        snap.media = true
        let group = SnapchatWebData.align([], with: [line("ANNA", "hi"), snap, line("ME", "hey")], chat: "g", now: now)
        let trip = SnapchatWebData.chat(SnapchatWebData.Row(id: "g", name: "Trip", status: "Opened", bold: false), kept: group,
                                        snapLabel: "Snap")
        XCTAssertEqual(trip.members, ["ANNA", "BOB"])
        XCTAssertEqual(trip.messages.map(\.sender), ["ANNA", "BOB", ""])
        XCTAssertEqual(trip.messages[1].text, "Snap")
        XCTAssertEqual(trip.unread, 0)
    }
}
