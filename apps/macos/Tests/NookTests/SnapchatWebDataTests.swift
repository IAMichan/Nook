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

    /// A picture in the open chat keeps where the page has it, to save it while the chat is open; that address is no
    /// part of the message (the website gives it a new one each load), so a new read still finds the messages it knew.
    func testAPictureIsSavedAndShowsAsAPhoto() {
        let answer: [String: Any] = ["status": "ok", "lines": [
            ["sender": "ANNA", "text": "", "media": true, "src": "blob:https://www.snapchat.com/1"],
            ["sender": "ANNA", "text": "hi", "src": "blob:https://www.snapchat.com/ignored"],
        ]]
        guard case .lines(let lines) = SnapchatWebData.readOutcome(answer) else { return XCTFail("no lines") }
        XCTAssertEqual(lines[0].source, "blob:https://www.snapchat.com/1")
        XCTAssertNil(lines[1].source, "only a picture has a source")
        var reloaded = lines[0]
        reloaded.source = "blob:https://www.snapchat.com/2"
        XCTAssertEqual(reloaded, lines[0], "the same picture after the page loaded again")

        let row = SnapchatWebData.Row(id: "c", name: "Anna", status: "New Chat", bold: false)
        let kept = SnapchatWebData.align([], with: lines, chat: "c", now: now)
        let saved = SnapchatWebData.chat(row, kept: kept, snapLabel: "Snap", pictures: [kept[0].id: "/tmp/photo.jpg"])
        XCTAssertEqual(saved.messages[0].media, ChatMedia(kind: .photo, name: "photo.jpg", path: "/tmp/photo.jpg"))
        XCTAssertEqual(saved.messages[0].text, "", "a saved picture shows as itself, not as the word for a snap")
        XCTAssertEqual(SnapchatWebData.chat(row, kept: kept, snapLabel: "Snap").messages[0].text, "Snap", "not saved: the word")

        XCTAssertEqual(SnapchatWebData.pictureData("data:image/jpeg;base64," + Data([1, 2, 3]).base64EncodedString()), Data([1, 2, 3]))
        XCTAssertNil(SnapchatWebData.pictureData("data:text/html;base64,PGI+"), "only a picture")
        XCTAssertNil(SnapchatWebData.pictureData("https://example.com/a.jpg"))
    }

    // MARK: Edits and deletions

    private func kept(_ texts: [String], sender: String = "Anna") -> [SnapchatWebData.Kept] {
        texts.enumerated().map { index, text in
            SnapchatWebData.Kept(id: "k\(index)", line: .init(sender: sender, text: text),
                                 date: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }
    }

    func testAMessageGoneBetweenTwoThatStayedWasDeletedAndTheOldestGoingSaysNothing() {
        let before = kept(["een", "twee", "drie", "vier"])
        let read = ["twee", "vier"].map { SnapchatWebData.Line(sender: "Anna", text: $0) }
        let changes = SnapchatWebData.changes(before, read: read)
        XCTAssertEqual(changes.deleted, ["k2"], "the oldest dropping off the top is Snapchat letting it go, not a deletion")
        XCTAssertTrue(changes.edited.isEmpty)

        let aligned = SnapchatWebData.align(before, with: read, chat: "c", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(aligned.map(\.id), ["k0", "k1", "k2", "k3"], "nothing new, nothing doubled")
        XCTAssertEqual(aligned.filter(\.deleted).map(\.id), ["k2"])
        let chat = SnapchatWebData.chat(SnapchatWebData.Row(id: "c", name: "Anna", status: "", bold: false), kept: aligned, snapLabel: "Snap")
        XCTAssertEqual(chat.messages.first { $0.id == "k2" }?.isDeleted, true)
        XCTAssertEqual(chat.messages.first { $0.id == "k2" }?.text, "drie", "someone else's keeps what it said")
    }

    func testOtherWordsInAMessagesPlaceAreAnEditUnderItsOwnID() {
        let before = kept(["een", "twee", "drie"])
        let read = ["een", "twee!", "drie", "nieuw"].map { SnapchatWebData.Line(sender: "Anna", text: $0) }
        let aligned = SnapchatWebData.align(before, with: read, chat: "c", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(aligned.count, 4, "the edited one is not taken for a new message")
        XCTAssertEqual(aligned[1].id, "k1")
        XCTAssertEqual(aligned[1].line.text, "twee!")
        XCTAssertTrue(aligned[1].edited)
        XCTAssertEqual(aligned.last?.line.text, "nieuw")
    }
}
