import XCTest

final class SessionPanelsTests: XCTestCase {
    func testSidePanelReopensOnTheTabItShowed() {
        XCTAssertEqual(PanelReopening.tab(hidden: "browser", tabs: ["terminal", "browser"]), "browser")
    }

    func testSidePanelReopensOnItsFirstTabWhenThatTabIsGone() {
        XCTAssertEqual(PanelReopening.tab(hidden: "browser", tabs: ["terminal", "changes"]), "terminal")
        XCTAssertEqual(PanelReopening.tab(hidden: nil, tabs: ["outputs"]), "outputs")
    }

    func testSidePanelWithoutTabsHasNothingToReopen() {
        XCTAssertNil(PanelReopening.tab(hidden: "browser", tabs: [String]()))
    }

    func testContextRingStaysQuietUntilHalfUsed() {
        XCTAssertFalse(ContextMeter.worthShowing(0.49))
        XCTAssertTrue(ContextMeter.worthShowing(0.5))
    }

    func testSessionPanelShortcutLeavesTheTerminalAlone() {
        let rule = Keybindings.defaults.first { $0.command == "sessionPanel.toggle" }
        XCTAssertEqual(rule?.key, "mod+shift+b")
        XCTAssertEqual(rule?.when, "!terminalFocus")
        XCTAssertTrue(Keybindings.commandIDs.contains("sessionPanel.toggle"))
    }
}
