import XCTest

/// Messages' tapbacks and sending, the parts that are plain Foundation (`AppData.Tapback`, `AppData.MessagesSend`):
/// which emoji a tapback row puts on which message, and the AppleScript that sends to a chat.
final class MessagesBridgeDataTests: XCTestCase {
    // MARK: Tapbacks

    func testTapbackTypesAreTheirEmoji() {
        XCTAssertEqual(AppData.Tapback.emoji(type: 2000), "❤️")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2001), "👍")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2002), "👎")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2003), "😂")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2004), "‼️")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2005), "❓")
        XCTAssertEqual(AppData.Tapback.emoji(type: 3001), "👍", "taking one back names the same emoji")
        XCTAssertEqual(AppData.Tapback.emoji(type: 2006, custom: " 🎉 "), "🎉")
        XCTAssertNil(AppData.Tapback.emoji(type: 2006, custom: ""))
        XCTAssertNil(AppData.Tapback.emoji(type: 2007), "a sticker put on a message is no emoji")
        XCTAssertNil(AppData.Tapback.emoji(type: 0))
        XCTAssertNil(AppData.Tapback.emoji(type: 1000))
    }

    func testTapbackPointsAtTheMessageGuid() {
        XCTAssertEqual(AppData.Tapback.target("p:0/ABC-123"), "ABC-123")
        XCTAssertEqual(AppData.Tapback.target("p:2/ABC-123"), "ABC-123")
        XCTAssertEqual(AppData.Tapback.target("bp:ABC-123"), "ABC-123")
        XCTAssertEqual(AppData.Tapback.target("ABC-123"), "ABC-123")
        XCTAssertNil(AppData.Tapback.target(""))
        XCTAssertNil(AppData.Tapback.target("bp:"))
        let pointers = AppData.Tapback.pointers(to: "G", parts: 2)
        XCTAssertEqual(pointers, ["p:0/G", "p:1/G", "bp:G"])
    }

    func testRowsThatAreNoTapbackAreLeftOut() {
        XCTAssertNil(AppData.Tapback(associated: "p:0/G", type: 2007, sender: "1", mine: false))
        XCTAssertNil(AppData.Tapback(associated: "", type: 2000, sender: "1", mine: false))
        XCTAssertNil(AppData.Tapback(associated: "p:0/G", type: 2006, emoji: nil, sender: "1", mine: false))
        let removal = AppData.Tapback(associated: "p:0/G", type: 3006, emoji: nil, sender: "1", mine: false)
        XCTAssertEqual(removal?.adds, false, "taking back an emoji of one's own choice may not say which")
        XCTAssertEqual(removal?.emoji, "")
    }

    func testTapbacksFoldIntoReactionsMostUsedFirst() {
        let rows = [
            AppData.Tapback(associated: "p:0/A", type: 2003, sender: "7", mine: false)!,
            AppData.Tapback(associated: "p:0/A", type: 2000, sender: "8", mine: false)!,
            AppData.Tapback(associated: "p:0/A", type: 2000, sender: "me", mine: true)!,
            AppData.Tapback(associated: "bp:B", type: 2001, sender: "7", mine: false)!,
        ]
        let reactions = AppData.Tapback.reactions(rows)
        XCTAssertEqual(reactions["A"], [InboxReaction(emoji: "❤️", count: 2, mine: true), InboxReaction(emoji: "😂", count: 1, mine: false)])
        XCTAssertEqual(reactions["B"], [InboxReaction(emoji: "👍", count: 1, mine: false)])
    }

    func testANewerTapbackReplacesAndTakingBackClears() {
        let rows = [
            AppData.Tapback(associated: "p:0/A", type: 2000, sender: "7", mine: false)!,
            AppData.Tapback(associated: "p:0/A", type: 2001, sender: "7", mine: false)!,
            AppData.Tapback(associated: "p:0/A", type: 2003, sender: "me", mine: true)!,
            AppData.Tapback(associated: "p:0/A", type: 3003, sender: "me", mine: true)!,
            // Taking back an emoji that is not yours there changes nothing.
            AppData.Tapback(associated: "p:0/A", type: 3000, sender: "7", mine: false)!,
        ]
        XCTAssertEqual(AppData.Tapback.reactions(rows)["A"], [InboxReaction(emoji: "👍", count: 1, mine: false)])

        let gone = [
            AppData.Tapback(associated: "p:0/C", type: 2006, emoji: "🎉", sender: "7", mine: false)!,
            AppData.Tapback(associated: "p:0/C", type: 3006, emoji: nil, sender: "7", mine: false)!,
        ]
        XCTAssertEqual(AppData.Tapback.reactions(gone)["C"], [], "a message whose emoji were all taken back shows none")
        let onlyRemoval = [AppData.Tapback(associated: "p:0/D", type: 3001, sender: "7", mine: false)!]
        XCTAssertEqual(AppData.Tapback.reactions(onlyRemoval)["D"], [])
    }

    // MARK: Sending

    func testChatIdsAndTheirOtherNames() {
        XCTAssertEqual(AppData.MessagesSend.variants("iMessage;-;+31612345678"), ["iMessage;-;+31612345678", "any;-;+31612345678"])
        XCTAssertEqual(AppData.MessagesSend.variants("SMS;-;+31612345678"), ["SMS;-;+31612345678", "any;-;+31612345678"])
        XCTAssertEqual(AppData.MessagesSend.variants("any;-;a@b.nl"), ["any;-;a@b.nl", "iMessage;-;a@b.nl", "SMS;-;a@b.nl"])
        XCTAssertEqual(AppData.MessagesSend.variants("iMessage;+;chat123"), ["iMessage;+;chat123", "any;+;chat123"])
        XCTAssertEqual(AppData.MessagesSend.variants(""), [])
    }

    func testOneToOneChatsHaveAPersonGroupsDoNot() {
        XCTAssertEqual(AppData.MessagesSend.person("iMessage;-;+31612345678")?.handle, "+31612345678")
        XCTAssertEqual(AppData.MessagesSend.person("iMessage;-;+31612345678")?.service, "iMessage")
        XCTAssertEqual(AppData.MessagesSend.person("SMS;-;+31612345678")?.service, "SMS")
        XCTAssertNil(AppData.MessagesSend.person("iMessage;+;chat123"))
        XCTAssertNil(AppData.MessagesSend.person("iMessage;-;"))
    }

    func testScriptTriesEveryChatThenThePersonAndSendsInOrder() {
        let script = AppData.MessagesSend.script([.file("/Users/me/Library/Messages/Attachments/Nook/x/foto.jpg"), .text("Hoi")],
                                                 chats: ["iMessage;-;+31612345678", "SMS;-;+31612345678"])
        let lines = script.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "set theFile1 to POSIX file \"/Users/me/Library/Messages/Attachments/Nook/x/foto.jpg\"")
        XCTAssertTrue(script.contains("tell application \"Messages\""))
        let chatID = script.range(of: "chat id \"iMessage;-;+31612345678\"")
        let any = script.range(of: "chat id \"any;-;+31612345678\"")
        let sms = script.range(of: "chat id \"SMS;-;+31612345678\"")
        let person = script.range(of: "participant \"+31612345678\" of (1st account whose service type = iMessage)")
        XCTAssertNotNil(chatID)
        XCTAssertNotNil(any)
        XCTAssertNotNil(sms)
        XCTAssertNotNil(person)
        XCTAssertLessThan(chatID!.lowerBound, sms!.lowerBound, "the chat to prefer is tried first")
        XCTAssertLessThan(sms!.lowerBound, person!.lowerBound, "the person comes after every chat id")
        XCTAssertEqual(script.components(separatedBy: "chat id \"any;-;+31612345678\"").count, 2, "each id is tried once")
        let file = script.range(of: "\tsend theFile1 to theChat")
        let text = script.range(of: "\tsend \"Hoi\" to theChat")
        XCTAssertNotNil(file)
        XCTAssertNotNil(text)
        XCTAssertLessThan(file!.lowerBound, text!.lowerBound, "the caption follows its file")
        XCTAssertTrue(script.contains("if theChat is missing value then error number -1728"))
        XCTAssertEqual(lines.last, "return \"\(AppData.MessagesSend.done)\"")
    }

    func testTextCannotEndItsStringEarly() {
        let script = AppData.MessagesSend.script([.text("say \"hi\" \\ then\nend tell\ndo shell script \"rm\"")], chats: ["iMessage;+;chat1"])
        XCTAssertTrue(script.contains("send \"say \\\"hi\\\" \\\\ then\nend tell\ndo shell script \\\"rm\\\"\" to theChat"), script)
    }
}
