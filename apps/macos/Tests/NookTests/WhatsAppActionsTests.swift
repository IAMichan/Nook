import XCTest

/// Editing, deleting, pinning and archiving in WhatsApp: the requests each gateway gets, and how the chat in Nook
/// follows once the gateway took them.
final class WhatsAppActionsTests: XCTestCase {
    private func message(_ id: String, chat: String, text: String = "hoi", at: Double = 0, fromMe: Bool = true) -> WAMessage {
        WAMessage(id: id, chat: chat, sender: chat, senderName: "Lisa", text: text,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + at), fromMe: fromMe)
    }

    func testGOWARequests() {
        let edit = WAAction.gowaEdit("3EB0ABC", chat: "31612345678@s.whatsapp.net", text: "Fixed")
        XCTAssertEqual(edit.path, "/message/3EB0ABC/update")
        XCTAssertEqual(edit.json?["phone"] as? String, "31612345678@s.whatsapp.net")
        XCTAssertEqual(edit.json?["message"] as? String, "Fixed")

        let delete = WAAction.gowaDelete("3EB0ABC", chat: "120363000000000001@g.us")
        XCTAssertEqual(delete.path, "/message/3EB0ABC/revoke")
        XCTAssertEqual(delete.json?["phone"] as? String, "120363000000000001@g.us")
        XCTAssertEqual(delete.json?.count, 1)

        let pin = WAAction.gowaPin(true, chat: "120363000000000001@g.us")
        XCTAssertEqual(pin.path, "/chat/120363000000000001@g.us/pin")
        XCTAssertEqual(pin.json?["pinned"] as? Bool, true)
        XCTAssertEqual(WAAction.gowaPin(false, chat: "x@g.us").json?["pinned"] as? Bool, false)

        let archive = WAAction.gowaArchive("31612345678@s.whatsapp.net")
        XCTAssertEqual(archive.path, "/chat/31612345678@s.whatsapp.net/archive")
        XCTAssertEqual(archive.json?["archived"] as? Bool, true)
    }

    func testAnIdIsOnePathSegment() {
        XCTAssertEqual(WAAction.gowaEdit("a/b?c", chat: "x", text: "t").path, "/message/a%2Fb%3Fc/update",
                       "a message id can never reach another route")
    }

    func testOpenWARequests() {
        let edit = WAAction.openwaEdit("true_31612345678@c.us_3EB0", chatId: "31612345678@c.us", text: "Fixed")
        XCTAssertEqual(edit.path, "/messages/edit")
        XCTAssertEqual(edit.json?["chatId"] as? String, "31612345678@c.us")
        XCTAssertEqual(edit.json?["messageId"] as? String, "true_31612345678@c.us_3EB0")
        XCTAssertEqual(edit.json?["body"] as? String, "Fixed")

        let delete = WAAction.openwaDelete("M1", chatId: "x@g.us")
        XCTAssertEqual(delete.path, "/messages/delete")
        XCTAssertEqual(delete.json?["forEveryone"] as? Bool, true)

        let pin = WAAction.openwaPin(false, chatId: "x@g.us")
        XCTAssertEqual(pin.path, "/chats/pin")
        XCTAssertEqual(pin.json?["pin"] as? Bool, false)

        let mute = WAAction.openwaMute(true, chatId: "x@g.us")
        XCTAssertEqual(mute.path, "/chats/mute")
        XCTAssertEqual(mute.json?["muteUntil"] as? Int64, 253_402_300_799_000, "muted for good, never 0")
        let unmute = WAAction.openwaMute(false, chatId: "x@g.us")
        let body = String(data: try! JSONSerialization.data(withJSONObject: unmute.json ?? [:], options: .sortedKeys), encoding: .utf8)
        XCTAssertEqual(body, #"{"chatId":"x@g.us","muteUntil":null}"#, "OpenWA unmutes with null")

        let archive = WAAction.openwaArchive("x@g.us")
        XCTAssertEqual(archive.path, "/chats/archive")
        XCTAssertEqual(archive.json?["archive"] as? Bool, true)
    }

    func testOpenWAsSuccessFalseIsNoSuccess() {
        XCTAssertTrue(WAAction.openwaSucceeded(Data(#"{"success":true}"#.utf8)))
        XCTAssertFalse(WAAction.openwaSucceeded(Data(#"{"success":false}"#.utf8)), "a fourth pinned chat")
        XCTAssertTrue(WAAction.openwaSucceeded(Data(#"{"messageId":"M1","timestamp":1760000000}"#.utf8)),
                      "an edit answers without the field")
    }

    func testOpenWAsChatListSaysWhichArePinned() {
        let data = Data(#"[{"id":"1@c.us","name":"A","pinned":true},{"id":"2@g.us","name":"B","pinned":false},{"id":"3@c.us"}]"#.utf8)
        XCTAssertEqual(WAOpenWA.pinned(data), ["1@c.us": true, "2@g.us": false])
        let muted = Data(#"[{"id":"1@c.us","muted":true,"muteExpiration":0},{"id":"2@g.us","muted":false},{"id":"3@c.us"}]"#.utf8)
        XCTAssertEqual(WAOpenWA.muted(muted), ["1@c.us": true, "2@g.us": false])
    }

    func testAnEditChangesTheTextInTheChat() {
        var inbox = WAInbox()
        let chat = "31600000001@s.whatsapp.net"
        inbox.add(message("1", chat: chat, text: "helo"), filters: WAFilters())
        XCTAssertEqual(inbox.applyEdit("hello", message: "1", chat: chat), chat)
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.text, "hello")
        XCTAssertNil(inbox.applyEdit("hello", message: "1", chat: chat), "the same text changes nothing")
        XCTAssertNil(inbox.applyEdit("x", message: "unknown", chat: chat))
    }

    func testADeletedMessageLeavesAndStaysGone() {
        var inbox = WAInbox()
        let chat = "31600000001@s.whatsapp.net"
        inbox.add(message("1", chat: chat), filters: WAFilters())
        inbox.add(message("2", chat: chat, at: 5), filters: WAFilters())
        XCTAssertEqual(inbox.applyDelete(message: "1", chat: chat), chat)
        XCTAssertEqual(inbox.conversations[chat]?.messages.map(\.id), ["2"])
        XCTAssertTrue(inbox.wasDeleted("1"))
        XCTAssertEqual(inbox.add(message("1", chat: chat), filters: WAFilters(), history: true), .ignored,
                       "the gateway's history does not bring it back")
        XCTAssertEqual(inbox.conversations[chat]?.messages.map(\.id), ["2"])
        inbox.clear()
        XCTAssertFalse(inbox.wasDeleted("1"))
    }
}
