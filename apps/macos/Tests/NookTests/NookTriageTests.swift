import XCTest

final class NookTriageTests: XCTestCase {
    func testTheDraftFitsAPromptLinkAndKeepsToItsRules() {
        let text = NookTriage.prompt(build: "release v1.2.3, tag v1.2.3", supportFolder: "/Users/me/Library/Application Support/Nook")
        XCTAssertLessThanOrEqual(text.count, PromptLink.maxTextLength)
        XCTAssertTrue(text.contains("tag v1.2.3"))
        XCTAssertTrue(text.contains("Do not read its databases"))
        XCTAssertTrue(text.contains("Ask me first"))
        XCTAssertTrue(text.contains("template=agent_report.yml"))
        XCTAssertTrue(text.hasSuffix("What went wrong:"))
    }

    func testTheBuildNamesTheCodeAnAgentCanCheckOut() {
        XCTAssertEqual(NookTriage.build(info: ["NookReleaseVersion": "0.2.0-beta.3", "CFBundleShortVersionString": "0.2.0"]),
                       "release v0.2.0-beta.3, tag v0.2.0-beta.3")
        let commit = String(repeating: "ab", count: 20)
        XCTAssertEqual(NookTriage.build(info: ["NookSourceCommit": commit, "NookSourceRoot": "/Users/me/nook/apps/macos"]),
                       "built from source, commit abababababab")
        // An unexpanded build setting is no release.
        XCTAssertEqual(NookTriage.build(info: ["NookReleaseVersion": "$(NOOK_RELEASE_VERSION)", "CFBundleShortVersionString": "0.2.0"]),
                       "version 0.2.0")
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
