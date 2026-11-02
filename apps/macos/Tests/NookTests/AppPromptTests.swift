import XCTest

/// The prompt the Claude app draws before its computer-use tools work on your screen: which tool calls ask it, what
/// the card says, and which button Nook presses for your answer.
final class AppPromptTests: XCTestCase {
    func testOnlyTheClaudeAppsAskingToolsGetAnAppPrompt() {
        let ask = "mcp__computer-use__request_access"
        XCTAssertEqual(AppPrompt.hostBundleIDs(agentID: "claude-desktop", hostBundleID: "", tool: ask),
                       ["com.anthropic.claudefordesktop"])
        XCTAssertEqual(AppPrompt.hostBundleIDs(agentID: "claude-desktop", hostBundleID: "com.anthropic.claudefordesktop",
                                               tool: "mcp__computer-use__request_full_control"),
                       ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(AppPrompt.hostBundleIDs(agentID: "claude-desktop", hostBundleID: "",
                                              tool: "mcp__computer-use__left_click").isEmpty, "a click asks nothing")
        XCTAssertTrue(AppPrompt.hostBundleIDs(agentID: "claude-code", hostBundleID: "com.apple.Terminal", tool: ask).isEmpty,
                      "a terminal asks in text, which its hook answers")
    }

    func testTheCardNamesTheAppsAndTheReason() {
        let input: [String: Any] = ["apps": ["Nook"], "reason": "Scroll the chat list while profiling it."]
        XCTAssertEqual(AppPrompt.summary(input: input), "Nook\nScroll the chat list while profiling it.")
        XCTAssertEqual(AppPrompt.appNames([["displayName": "Nook", "bundleId": "app.nook"], ["name": "Safari"]]), ["Nook", "Safari"])
        XCTAssertFalse(AppPrompt.title(tool: "mcp__computer-use__request_access", agent: "Claude").isEmpty)
    }

    func testPressesTheButtonOfTheAnswer() {
        let window = ["Settings", "Deny Esc", "Allow for this session ⌘ ↩", "Send"]
        XCTAssertEqual(AppPrompt.button(.allow, among: window), 2)
        XCTAssertEqual(AppPrompt.button(.deny, among: window), 1)
        let dutch = ["Weigeren", "Toestaan voor deze sessie"]
        XCTAssertEqual(AppPrompt.button(.allow, among: dutch), 1)
        XCTAssertEqual(AppPrompt.button(.deny, among: dutch), 0)
        XCTAssertEqual(AppPrompt.button(.deny, among: ["Niet toestaan", "Toestaan"]), 0, "deny words win over allow words")
    }

    func testNeverPressesAButtonItIsUnsureOf() {
        XCTAssertNil(AppPrompt.button(.allow, among: ["Allow for this session", "Send"]), "no deny beside it: not the prompt")
        XCTAssertNil(AppPrompt.button(.allow, among: ["Allow once", "Allow always", "Deny"]), "two allows, neither for the session")
        XCTAssertNil(AppPrompt.button(.allow, among: ["Allowed apps", "Deny"]), "a word that only starts like allow")
        XCTAssertNil(AppPrompt.button(.deny, among: []))
    }
}
