import XCTest

/// How the open Nook conversation travels to the phone after the first answer to `watchConversation`
/// (`ConversationDelta`): Nook's new words while it writes, else only what changed, and a phone that missed an update
/// asks again instead of showing something wrong.
final class ConversationDeltaTests: XCTestCase {
    private func line(_ id: String, _ text: String, nook: Bool = true, streaming: Bool = false, status: String = "") -> ChatLine {
        ChatLine(id: id, fromNook: nook, text: text, date: 100, streaming: streaming, status: status, failed: false, onMac: false)
    }

    private var question: ChatLine { line("q", "Wat staat er vandaag?", nook: false) }

    func testWhileNookWritesOnlyItsNewWordsGo() throws {
        let old = [question, line("a", "Je hebt om 10:00", streaming: true)]
        let new = [question, line("a", "Je hebt om 10:00 een call 👋🏽 met Lisa", streaming: true)]
        guard case .append(let words) = ConversationDelta.change(from: old, to: new) else { return XCTFail("not an append") }
        XCTAssertEqual(words.text, " een call 👋🏽 met Lisa")
        XCTAssertEqual(words.at, old[1].text.unicodeScalars.count)
        XCTAssertEqual(ConversationDelta.apply(lines: nil, after: nil, append: words, to: old), new)
        // A few bytes instead of the whole conversation.
        let delta = try JSONEncoder().encode(words).count
        let whole = try JSONEncoder().encode(new).count
        XCTAssertLessThan(delta, whole / 2)
    }

    func testTheAnswerFinishingIsAnAppendToo() {
        let old = [question, line("a", "Klaar", streaming: true, status: "")]
        let new = [question, line("a", "Klaar.", streaming: false)]
        guard case .append(let words) = ConversationDelta.change(from: old, to: new) else { return XCTFail("not an append") }
        XCTAssertFalse(words.streaming)
        XCTAssertEqual(ConversationDelta.apply(lines: nil, after: nil, append: words, to: old), new)
    }

    func testAMessageAddedSendsOnlyTheTail() {
        let old = [question, line("a", "Antwoord")]
        let new = old + [line("q2", "En morgen?", nook: false), line("a2", "", streaming: true, status: "Thinking…")]
        guard case .tail(let after, let lines) = ConversationDelta.change(from: old, to: new) else { return XCTFail("not a tail") }
        XCTAssertEqual(after, "a")
        XCTAssertEqual(lines.map(\.id), ["q2", "a2"])
        XCTAssertEqual(ConversationDelta.apply(lines: lines, after: after, append: nil, to: old), new)
    }

    func testRewrittenTextIsNotAnAppend() {
        let old = [question, line("a", "Eerste versie", streaming: true)]
        let new = [question, line("a", "Andere versie", streaming: true)]
        guard case .tail(let after, let lines) = ConversationDelta.change(from: old, to: new) else { return XCTFail("not a tail") }
        XCTAssertEqual(after, "q")
        XCTAssertEqual(ConversationDelta.apply(lines: lines, after: after, append: nil, to: old), new)
    }

    func testNothingNewIsSameAndAFirstLookIsWhole() {
        let lines = [question, line("a", "Antwoord")]
        XCTAssertEqual(ConversationDelta.change(from: lines, to: lines), .same)
        XCTAssertEqual(ConversationDelta.change(from: nil, to: lines), .tail(after: nil, lines: lines))
        XCTAssertEqual(ConversationDelta.apply(lines: lines, after: nil, append: nil, to: nil), lines)
    }

    /// A lost or doubled update never shows wrong text: the phone notices and asks for the conversation again.
    func testAnUpdateThatDoesNotBuildOnWhatThePhoneHasIsRefused() {
        let old = [question, line("a", "Je hebt", streaming: true)]
        let skipped = ChatAppend(id: "a", at: 20, text: " later", streaming: true, status: "")
        XCTAssertNil(ConversationDelta.apply(lines: nil, after: nil, append: skipped, to: old), "an update was missed")
        let other = ChatAppend(id: "b", at: 7, text: " x", streaming: true, status: "")
        XCTAssertNil(ConversationDelta.apply(lines: nil, after: nil, append: other, to: old))
        XCTAssertNil(ConversationDelta.apply(lines: nil, after: nil, append: skipped, to: nil))
        XCTAssertNil(ConversationDelta.apply(lines: [line("z", "")], after: "unknown", append: nil, to: old))
    }

    func testAfterAReconnectOnlyWhatCameAfterTheLastFinishedMessageGoes() {
        let mac = [question, line("a", "Antwoord"), line("q2", "En morgen?", nook: false), line("a2", "Morgen", streaming: true)]
        let phone = Array(mac.prefix(2)) + [line("a2-old", "", streaming: true)]
        XCTAssertEqual(ConversationDelta.resumePoint(phone), "a", "the phone names its last finished message")
        let resumed = ConversationDelta.resume(mac, from: ConversationDelta.resumePoint(phone))
        XCTAssertEqual(resumed?.after, "a")
        XCTAssertEqual(resumed?.lines.map(\.id), ["q2", "a2"])
        XCTAssertEqual(ConversationDelta.apply(lines: resumed?.lines, after: resumed?.after, append: nil, to: phone), mac)

        XCTAssertNil(ConversationDelta.resume(mac, from: "a2"), "a message still being written is not a point to resume from")
        XCTAssertNil(ConversationDelta.resume(mac, from: "gone"))
        XCTAssertNil(ConversationDelta.resume(mac, from: nil))
    }

    /// Updates sent one after another, as a streaming answer makes them, always add up to what the Mac has.
    func testAStreamOfUpdatesAddsUpToTheMacsConversation() {
        var mac = [question]
        var phone = ConversationDelta.apply(lines: mac, after: nil, append: nil, to: nil)
        var sent = mac
        // First Nook's status with no text yet, then its words, then the end of the answer.
        let words = ["", "Je", " hebt", " om 10:00", " een call", ".", ""]
        mac.append(line("a", "", streaming: true, status: "Looking in your calendar…"))
        for (index, word) in words.enumerated() {
            if index > 0 {
                mac[1].text += word
                mac[1].status = ""
                mac[1].streaming = index < words.count - 1
            }
            switch ConversationDelta.change(from: sent, to: mac) {
            case .same: break
            case .append(let added): phone = ConversationDelta.apply(lines: nil, after: nil, append: added, to: phone)
            case .tail(let after, let lines): phone = ConversationDelta.apply(lines: lines, after: after, append: nil, to: phone)
            }
            sent = mac
            XCTAssertEqual(phone, mac)
        }
        XCTAssertEqual(phone?.last?.text, "Je hebt om 10:00 een call.")
        XCTAssertEqual(phone?.last?.streaming, false)
    }

    func testAPhoneWithoutTheNookChatScopeGetsNoneOfIt() {
        var response = CompanionResponse(id: "r", ok: true)
        response.messageAppend = ChatAppend(id: "a", at: 0, text: "x", streaming: true, status: "")
        response.messagesAfter = "q"
        let redacted = CompanionScopes.redact(response, granted: [.read, .chats])
        XCTAssertNil(redacted.messageAppend)
        XCTAssertNil(redacted.messagesAfter)
    }
}
