import XCTest

final class InjectedPromptTests: XCTestCase {
    func testTaskNotificationIsNotAPrompt() {
        let text = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"
        XCTAssertTrue(InjectedPrompt.isInjected(text))
        XCTAssertEqual(InjectedPrompt.title(text), "")
    }

    func testKnownPrefixesAndWrappedTagsAreInjected() {
        XCTAssertTrue(InjectedPrompt.isInjected("<command-name>/clear</command-name>"))
        XCTAssertTrue(InjectedPrompt.isInjected("  <system-reminder>x</system-reminder>"))
        XCTAssertTrue(InjectedPrompt.isInjected("<environment_context>cwd</environment_context>"))
        XCTAssertTrue(InjectedPrompt.isInjected("<teammate-message from=\"a\">hi</teammate-message>"))
        XCTAssertTrue(InjectedPrompt.isInjected("[Request interrupted by user]"))
    }

    func testOwnWordsStayAPrompt() {
        XCTAssertFalse(InjectedPrompt.isInjected("Fix the login bug"))
        XCTAssertFalse(InjectedPrompt.isInjected("<div>center this</div>"))
        XCTAssertFalse(InjectedPrompt.isInjected(""))
    }

    func testTitleKeepsYourWordsWithoutTheAgentsBlocks() {
        XCTAssertEqual(InjectedPrompt.title("<system-reminder>ignore</system-reminder>\nFix   the login bug\nmore"), "Fix the login bug")
        XCTAssertEqual(InjectedPrompt.title("Make <b>this</b> bold"), "Make this bold")
        XCTAssertEqual(InjectedPrompt.title("<task-notification"), "")
        XCTAssertEqual(InjectedPrompt.title("Plain title"), "Plain title")
    }

    func testWorktreeTitleSkipsTags() {
        XCTAssertEqual(WorktreeNaming.title(from: "<task-notification>\n<task-id>1</task-id>\n</task-notification>\nRefactor the parser"),
                       "Refactor the parser")
    }

    func testClaudeControlRequestsForLiveSettings() throws {
        let mode = ClaudeStreamParser.setPermissionModeRequest(id: "m1", mode: "acceptEdits")
        let modeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mode.utf8)) as? [String: Any])
        XCTAssertEqual(modeObject["type"] as? String, "control_request")
        let request = try XCTUnwrap(modeObject["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "set_permission_mode")
        XCTAssertEqual(request["mode"] as? String, "acceptEdits")
        XCTAssertTrue(mode.hasSuffix("\n"))

        let model = ClaudeStreamParser.setModelRequest(id: "m2", model: "")
        let modelObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.utf8)) as? [String: Any])
        let modelRequest = try XCTUnwrap(modelObject["request"] as? [String: Any])
        XCTAssertEqual(modelRequest["subtype"] as? String, "set_model")
        XCTAssertNil(modelRequest["model"])
    }
}
