import XCTest

final class NookTriageTests: XCTestCase {
    func testTheDraftFitsAPromptLinkAndKeepsToItsRules() {
        let text = NookTriage.prompt(version: "1.2.3", supportFolder: "/Users/me/Library/Application Support/Nook")
        XCTAssertLessThanOrEqual(text.count, PromptLink.maxTextLength)
        XCTAssertTrue(text.contains("1.2.3"))
        XCTAssertTrue(text.contains("Do not read its databases"))
        XCTAssertTrue(text.contains("Ask me first"))
        XCTAssertTrue(text.hasSuffix("What went wrong:"))
    }
}

final class NookCommandLineTests: XCTestCase {
    func testTheScriptSpeaksAsTheOutsideCaller() {
        XCTAssertTrue(NookCommandLine.contents.contains("agent => '\(NookCommandLine.agentID)'"))
        XCTAssertTrue(NookCommandLine.contents.hasPrefix("#!/usr/bin/perl"))
    }

    func testStartingASessionAsksUnlessTheCallerHasFullRights() {
        let tool = BridgeTool.sessionStart
        XCTAssertEqual(tool.effect, .local)
        XCTAssertTrue(tool.approvalReadsAsProse)
    }
}
