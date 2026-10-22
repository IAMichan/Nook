import XCTest

final class SessionFocusTests: XCTestCase {
    private let terminal = "com.apple.Terminal"
    private let claude = "com.anthropic.claudefordesktop"

    private func session(_ id: String, _ host: String, _ project: String) -> SessionFocus.Session {
        SessionFocus.Session(id: id, hostBundleID: host, project: project)
    }

    private func front(_ bundleID: String, title: String? = nil, idle: TimeInterval = 2) -> SessionFocus.Front {
        SessionFocus.Front(bundleID: bundleID, windowTitle: title, idle: idle)
    }

    func testTheOnlySessionInTheFrontAppIsWatched() {
        let sessions = [session("a", claude, "nook")]
        XCTAssertTrue(SessionFocus.isWatching("a", sessions: sessions, front: front(claude)))
        XCTAssertTrue(SessionFocus.isWatching("a", sessions: sessions, front: front("COM.ANTHROPIC.claudefordesktop")))
    }

    func testAnotherAppInFrontIsNotWatching() {
        let sessions = [session("a", terminal, "nook")]
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front("com.apple.Safari")))
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: nil))
    }

    func testAwayFromTheMacIsNotWatching() {
        let sessions = [session("a", terminal, "nook")]
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal, idle: SessionFocus.presence + 1)))
    }

    func testUnknownHostOrSessionIsNotWatching() {
        let sessions = [session("a", "", "nook")]
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal)))
        XCTAssertFalse(SessionFocus.isWatching("b", sessions: sessions, front: front(terminal)))
    }

    func testSessionsInOtherAppsDoNotMatter() {
        let sessions = [session("a", terminal, "nook"), session("b", claude, "site")]
        XCTAssertTrue(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal)))
    }

    func testSeveralSessionsInOneAppNeedTheWindowTitle() {
        let sessions = [session("a", terminal, "nook"), session("b", terminal, "site")]
        // Without a title Nook cannot tell which one is in front: both still notify.
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal)))
        XCTAssertTrue(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal, title: "Nook — claude — 80×24")))
        XCTAssertFalse(SessionFocus.isWatching("b", sessions: sessions, front: front(terminal, title: "Nook — claude — 80×24")))
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal, title: "~ — zsh")))
    }

    func testTheLongestProjectNameInTheTitleWins() {
        let sessions = [session("a", terminal, "nook"), session("b", terminal, "nook-ios")]
        XCTAssertTrue(SessionFocus.isWatching("b", sessions: sessions, front: front(terminal, title: "nook-ios — claude")))
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal, title: "nook-ios — claude")))
    }

    func testTwoSessionsInTheSameProjectCannotBeTold() {
        let sessions = [session("a", terminal, "nook"), session("b", terminal, "nook")]
        XCTAssertFalse(SessionFocus.isWatching("a", sessions: sessions, front: front(terminal, title: "nook — claude")))
    }
}
