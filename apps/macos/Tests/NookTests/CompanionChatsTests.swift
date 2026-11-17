import XCTest

/// The Chats tab on the phone as on the Mac (`CompanionChats.swift`, `CompanionFeature.chatActions`).
final class CompanionChatsTests: XCTestCase {
    private func line(_ id: String) -> InboxLine {
        InboxLine(id: id, text: id, date: 0, sender: "", fromMe: false, reactions: [])
    }

    // MARK: Paging

    func testNewestMessagesKeepWhatWasPagedBack() {
        let kept = ["a", "b", "c", "d", "e"].map(line)
        let latest = ["d", "e", "f"].map(line)
        XCTAssertEqual(InboxPaging.merge(latest: latest, into: kept).map(\.id), ["a", "b", "c", "d", "e", "f"])
    }

    func testNewestMessagesWithoutOverlapReplaceTheChat() {
        let kept = ["a", "b"].map(line)
        XCTAssertEqual(InboxPaging.merge(latest: ["x", "y"].map(line), into: kept).map(\.id), ["x", "y"])
        XCTAssertEqual(InboxPaging.merge(latest: [], into: kept).map(\.id), [])
    }

    func testTheSameNewestMessagesChangeNothing() {
        let kept = ["a", "b", "c"].map(line)
        XCTAssertEqual(InboxPaging.merge(latest: kept, into: kept), kept)
    }

    func testAnOlderPageGoesBeforeTheMessageItWasAskedFor() {
        let kept = ["c", "d"].map(line)
        XCTAssertEqual(InboxPaging.prepend(["a", "b"].map(line), before: "c", to: kept).map(\.id), ["a", "b", "c", "d"])
        // A page for a message the phone no longer has changes nothing; one that repeats a message keeps it once.
        XCTAssertEqual(InboxPaging.prepend(["a"].map(line), before: "z", to: kept).map(\.id), ["c", "d"])
        XCTAssertEqual(InboxPaging.prepend(["b", "c"].map(line), before: "c", to: kept).map(\.id), ["b", "c", "d"])
    }

    // MARK: Actions

    func testAnActionCarriesWhatItNeeds() {
        XCTAssertTrue(InboxAction(kind: .react, message: "m", emoji: "👍").isComplete)
        XCTAssertFalse(InboxAction(kind: .react, message: "m").isComplete)
        XCTAssertFalse(InboxAction(kind: .react, message: "m", emoji: String(repeating: "x", count: 20)).isComplete)
        XCTAssertTrue(InboxAction(kind: .edit, message: "m", text: "fixed").isComplete)
        XCTAssertFalse(InboxAction(kind: .edit, message: "m", text: "  ").isComplete)
        XCTAssertFalse(InboxAction(kind: .delete).isComplete)
        XCTAssertTrue(InboxAction(kind: .vote, message: "m", choices: []).isComplete)
        XCTAssertFalse(InboxAction(kind: .forward, message: "m", targets: []).isComplete)
        XCTAssertFalse(InboxAction(kind: .forward, message: "m", targets: (0...InboxAction.maxTargets).map(String.init)).isComplete)
        XCTAssertTrue(InboxAction(kind: .forward, message: "m", targets: ["a"]).isComplete)
        XCTAssertFalse(InboxAction(kind: .pin).isComplete)
        XCTAssertTrue(InboxAction(kind: .muteInApp, value: true).isComplete)
        XCTAssertTrue(InboxAction(kind: .markReadInNook).isComplete)
    }

    /// What only the chat's app can do needs its ability; what Nook does itself (its own pin, removing, read in Nook,
    /// deleting for you) never does.
    func testWhatTheChatsAppHasToTake() {
        XCTAssertEqual(InboxAction(kind: .react).needs, .react)
        XCTAssertEqual(InboxAction(kind: .pinInApp).needs, .pinInApp)
        XCTAssertEqual(InboxAction(kind: .deleteChat).needs, .deleteChat)
        for kind: InboxAction.Kind in [.pin, .remove, .markReadInNook, .markUnread, .deleteForMe, .forward] {
            XCTAssertNil(InboxAction(kind: kind).needs, "\(kind)")
        }
    }

    func testAbilitiesFromANewerMacAreIgnored() {
        XCTAssertEqual(InboxAbility.parse(["react", "teleport", "pinInApp"]), [.react, .pinInApp])
        XCTAssertEqual(InboxAbility.parse(nil), [])
        XCTAssertEqual(InboxAbility.parse(InboxAbility.names([.vote, .reply])), [.vote, .reply])
    }

    func testAnActionTravelsAsJSON() throws {
        var request = CompanionRequest(op: .inboxAct, item: "whatsapp|anna")
        request.chatAction = InboxAction(kind: .forward, message: "m1", targets: ["a", "b"])
        let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        // A request from an older phone has no action.
        let old = try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"1","sent":0,"op":"inbox"}"#.utf8))
        XCTAssertNil(old.chatAction)
    }

    // MARK: Polls

    func testAPollOfOneAnswerReplacesTheChoice() {
        let poll = InboxPoll(question: "Lunch?", options: [.init(text: "Pizza", votes: 2, chosen: true), .init(text: "Sushi", votes: 1, chosen: false)],
                             multiple: false, counted: true)
        XCTAssertEqual(poll.choice(afterTapping: "Sushi"), ["Sushi"])
        XCTAssertEqual(poll.choice(afterTapping: "Pizza"), [])
        let voted = poll.voting(["Sushi"])
        XCTAssertEqual(voted.options.map(\.votes), [1, 2])
        XCTAssertEqual(voted.chosen, ["Sushi"])
    }

    func testAPollOfMoreAnswersAddsAndTakesOff() {
        let poll = InboxPoll(question: "When?", options: [.init(text: "Mon", votes: 1, chosen: true), .init(text: "Tue", votes: 0, chosen: false)],
                             multiple: true, counted: true)
        XCTAssertEqual(poll.choice(afterTapping: "Tue"), ["Mon", "Tue"])
        XCTAssertEqual(poll.choice(afterTapping: "Mon"), [])
    }

    // MARK: Scopes and receipts

    func testTheNewOpsBelongToTheChatsScope() {
        for op in [CompanionOp.inboxAct, .inboxOlder, .inboxMedia, .inboxInfo, .inboxSearch] {
            XCTAssertTrue(CompanionScopes.allows(op, granted: [.chats]), "\(op)")
            XCTAssertFalse(CompanionScopes.allows(op, granted: Set(CompanionScope.allCases).subtracting([.chats])), "\(op)")
        }
        XCTAssertEqual(CompanionScopes.featureScopes[CompanionFeature.chatActions], .chats)
    }

    func testAPhoneWithoutChatsSeesNothingOfThem() {
        var response = CompanionResponse(id: "1", ok: true)
        response.inboxInfo = InboxChatInfo(chat: "c", about: "x", members: [], admins: [], adminsOnly: false, details: [],
                                           blocked: false, bot: false, verified: false)
        response.inboxFound = []
        response.inboxMedia = []
        let redacted = CompanionScopes.redact(response, granted: [.read])
        XCTAssertNil(redacted.inboxInfo)
        XCTAssertNil(redacted.inboxFound)
        XCTAssertNil(redacted.inboxMedia)
    }

    /// An action is done once, however often the phone sends it again; reading is answered afresh.
    func testActionsAreKeptReadsAreNot() {
        XCTAssertTrue(CommandReceipts.keeps(.inboxAct))
        for op in [CompanionOp.inboxOlder, .inboxMedia, .inboxInfo, .inboxSearch] { XCTAssertFalse(CommandReceipts.keeps(op), "\(op)") }
    }
}
