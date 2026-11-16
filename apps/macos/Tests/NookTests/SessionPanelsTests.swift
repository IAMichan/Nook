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

    func testChatColumnIsCenteredInTheRoomBesideThePanels() {
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1000), 132)
        // A panel that opens takes room from the right: the column moves to the middle of what is left.
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1600 - 308), 278)
    }

    func testChatColumnThatFillsItsRoomStartsAtItsEdge() {
        XCTAssertEqual(PanelSplit.columnStart(column: 644, room: 644), 0)
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 600), 0)
    }

    func testContextRingShowsFromTheFirstToken() {
        XCTAssertFalse(ContextMeter.worthShowing(used: 0, window: 1_000_000))
        XCTAssertFalse(ContextMeter.worthShowing(used: 1_000, window: 0))
        XCTAssertTrue(ContextMeter.worthShowing(used: 30_000, window: 1_000_000))
    }

    func testContextPressureCountsTowardTheAutoCompactPoint() {
        // A 1M window compacted at 350k: 300k is time to summarize, though only 30 % of the window.
        XCTAssertTrue(ContextMeter.suggestsCompact(ContextMeter.pressure(used: 300_000, window: 1_000_000, autoCompactAt: 350_000)))
        XCTAssertFalse(ContextMeter.suggestsCompact(ContextMeter.pressure(used: 300_000, window: 1_000_000, autoCompactAt: nil)))
        // A point past the window, or none at all, falls back to the window.
        XCTAssertEqual(ContextMeter.pressure(used: 100_000, window: 200_000, autoCompactAt: 500_000), 0.5)
        XCTAssertEqual(ContextMeter.pressure(used: 100_000, window: 200_000, autoCompactAt: 0), 0.5)
    }

    func testSessionPanelShortcutLeavesTheTerminalAlone() {
        let rule = Keybindings.defaults.first { $0.command == "sessionPanel.toggle" }
        XCTAssertEqual(rule?.key, "mod+shift+b")
        XCTAssertEqual(rule?.when, "!terminalFocus")
        XCTAssertTrue(Keybindings.commandIDs.contains("sessionPanel.toggle"))
    }
}
