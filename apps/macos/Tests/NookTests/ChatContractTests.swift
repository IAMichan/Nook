import XCTest

/// What every chat app promises in the Chats tab (`ChatContract.swift`): an action goes only where the chat's abilities
/// say it can, with the same checks for every app, logged under one name; a failing read waits longer each time; and
/// each app's own sign-in loss is told apart from a passing refusal.
final class ChatContractTests: XCTestCase {
    private let everything = ChatAbilities(send: true, sends: ChatOutgoing.Kind.everything, reply: true, react: true, edit: true,
                                           delete: true, markRead: true, pin: true, mute: true, archive: true, vote: true)

    func testAnActionGoesOnlyWhereTheAbilitiesSaySo() {
        let actions: [ChatAction] = [.send, .sendItem(.photo), .react, .edit, .delete, .markRead, .pin, .mute, .archive, .vote]
        for action in actions {
            XCTAssertTrue(everything.allows(action), "\(action)")
            XCTAssertEqual(action.refusal(ChatAbilities(), text: "hi"), .unsupported, "a chat Nook only reads takes nothing: \(action)")
        }
        let textOnly = ChatAbilities(send: true)
        XCTAssertNil(ChatAction.send.refusal(textOnly, text: "hi"))
        XCTAssertEqual(ChatAction.sendItem(.photo).refusal(textOnly), .unsupported, "Snapchat and Teams take text only")
        let noPolls = ChatAbilities(send: true, sends: ChatOutgoing.Kind.noPolls)
        XCTAssertNil(ChatAction.sendItem(.file).refusal(noPolls))
        XCTAssertEqual(ChatAction.sendItem(.poll).refusal(noPolls), .unsupported)
        XCTAssertEqual(ChatAction.sendItem(.photo).refusal(ChatAbilities(sends: [.photo])), .unsupported,
                       "nothing goes to a chat that takes no text either")
    }

    func testTextAndOwnershipAreCheckedTheSameForEveryApp() {
        XCTAssertEqual(ChatAction.send.refusal(everything, text: "  \n "), .empty)
        XCTAssertEqual(ChatAction.send.refusal(everything), .empty)
        XCTAssertEqual(ChatAction.edit.refusal(everything, text: "", fromMe: true), .empty)
        XCTAssertEqual(ChatAction.edit.refusal(everything, text: "fixed", fromMe: false), .notMine)
        XCTAssertEqual(ChatAction.delete.refusal(everything, fromMe: false), .notMine)
        XCTAssertNil(ChatAction.edit.refusal(everything, text: "fixed", fromMe: true))
        XCTAssertNil(ChatAction.delete.refusal(everything, fromMe: true))
        XCTAssertNil(ChatAction.react.refusal(everything, fromMe: false), "anyone's message takes your emoji")
        XCTAssertNil(ChatAction.vote.refusal(everything, fromMe: false), "anyone's poll takes your vote")
    }

    func testEveryAppLogsAnActionUnderOneName() {
        XCTAssertEqual(ChatAction.send.auditTool, "chat_send")
        XCTAssertEqual(ChatAction.sendItem(.voice).auditTool, "chat_send")
        XCTAssertEqual(ChatAction.react.auditTool, "chat_react")
        XCTAssertEqual(ChatAction.markRead.auditTool, "chat_mark_read")
        XCTAssertEqual(ChatAction.vote.auditTool, "chat_vote")
    }

    func testTheRefusalsAreTranslatedKeys() {
        XCTAssertEqual(ChatAction.Refusal.unsupported.rawValue, "chat.compose.unsupported")
        XCTAssertEqual(ChatAction.Refusal.empty.rawValue, "whatsapp.reply.empty")
        XCTAssertEqual(ChatAction.Refusal.notMine.rawValue, "chat.action.notMine")
    }

    func testOnlyTelegramDeletesForYouInTheAppItself() {
        XCTAssertFalse(ChatAbilities().deleteForMe, "elsewhere \"delete for me\" hides the message in Nook only")
        XCTAssertTrue(ChatAbilities(deleteForMe: true).deleteForMe)
    }

    func testEveryLinkedAccountStandsByOneRule() {
        XCTAssertEqual(ChatAccountHealth.of(collecting: true, shown: true, problem: nil, signedOut: false), .working)
        XCTAssertEqual(ChatAccountHealth.of(collecting: false, shown: true, problem: nil, signedOut: false), .off)
        XCTAssertEqual(ChatAccountHealth.of(collecting: true, shown: false, problem: nil, signedOut: false), .off)
        XCTAssertEqual(ChatAccountHealth.of(collecting: true, shown: true, problem: "HTTP 503", signedOut: false), .failing("HTTP 503"))
        XCTAssertEqual(ChatAccountHealth.of(collecting: false, shown: true, problem: "Sign in again", signedOut: true),
                       .signedOut("Sign in again"), "a problem shows also while the app is off")
        XCTAssertEqual(ChatAccountHealth.working.detail(working: "Reads", off: "Off"), "Reads")
        XCTAssertEqual(ChatAccountHealth.off.detail(working: "Reads", off: "Off"), "Off")
        XCTAssertEqual(ChatAccountHealth.failing("busy").detail(working: "Reads", off: "Off"), "busy")
        XCTAssertTrue(ChatAccountHealth.signedOut("x").isProblem)
        XCTAssertFalse(ChatAccountHealth.off.isProblem)
    }

    func testAFailingReadWaitsLongerEachTimeUpToAQuarterOfAnHour() {
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 1), 60, "a quick bridge waits a minute at first")
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 2), 120)
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 3), 240)
        XCTAssertEqual(ChatBackoff.delay(interval: 60, failures: 4), 480, "Slack and Teams back off too, not only wait their interval")
        XCTAssertEqual(ChatBackoff.delay(interval: 60, failures: 5), 900)
        XCTAssertEqual(ChatBackoff.delay(interval: 60, failures: 50), 900)
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 0), 60)
        XCTAssertEqual(ChatBackoff.delay(interval: 3600, failures: 3), 3600, "never shorter than the bridge's own interval")
    }

    func testADatabaseOnThisMacTriesAgainWithinSeconds() {
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 1, local: true), 5, "a locked database is read again soon")
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 2, local: true), 10)
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 3, local: true), 20)
        XCTAssertEqual(ChatBackoff.delay(interval: 2, failures: 30, local: true), 900, "one that keeps failing still waits up to a quarter of an hour")
        XCTAssertEqual(ChatBackoff.delay(interval: 10, failures: 1, local: true), 10, "never shorter than the bridge's own interval")
    }

    func testSlackTellsALostSignInFromOtherRefusals() {
        for reason in ["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"] {
            XCTAssertTrue(SlackData.signedOut(["ok": false, "error": reason]), reason)
        }
        XCTAssertFalse(SlackData.signedOut(["ok": false, "error": "missing_scope", "needed": "chat:write"]))
        XCTAssertFalse(SlackData.signedOut(["ok": false, "error": "ratelimited"]))
        XCTAssertFalse(SlackData.signedOut(["ok": true, "error": "invalid_auth"]))
    }

    func testTeamsKeepsItsSignInAfterAPassingRefusal() {
        XCTAssertTrue(TeamsData.signInGone(["error": "invalid_grant", "error_description": "AADSTS70008: expired"]))
        XCTAssertTrue(TeamsData.signInGone(["error": "interaction_required"]))
        XCTAssertFalse(TeamsData.signInGone(["error": "temporarily_unavailable"]), "Microsoft busy: ask again later")
        XCTAssertFalse(TeamsData.signInGone(["error": "server_error"]))
        XCTAssertFalse(TeamsData.signInGone([:]), "no reason at all is not a revoked sign-in")
    }
}
