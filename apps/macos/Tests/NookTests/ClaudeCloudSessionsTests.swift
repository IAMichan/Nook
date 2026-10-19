import XCTest

/// Sessions in Anthropic's cloud (Claude app, claude.ai/code) read from the account's session list.
final class ClaudeCloudSessionsTests: XCTestCase {
    private func parse(_ json: String) -> [CloudSession] {
        ClaudeCloudSessions.parse(Data(json.utf8))
    }

    func testASessionFromTheDesktopAppIsRead() {
        let sessions = parse(#"""
        {"data": [{
          "id": "session_01Abc", "title": "Nook Claude Desktop sessies",
          "session_status": "SESSION_STATUS_RUNNING", "origin": "desktop_app",
          "created_at": "2026-10-19T07:52:52.760531Z", "updated_at": "2026-10-19T07:54:06.699499Z",
          "session_context": {
            "sources": [{"git_repository": {"url": "https://github.com/IAMichan/nook"}}],
            "outcomes": [{"git_repository": {"git_info": {"repo": "IAMichan/nook", "branches": ["claude/tender-curie"]}}}],
            "model": "claude-opus-5-5"
          }
        }]}
        """#)
        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.id, "session_01Abc")
        XCTAssertEqual(session.title, "Nook Claude Desktop sessies")
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.origin, "desktop_app")
        XCTAssertEqual(session.repository, "IAMichan/nook")
        XCTAssertEqual(session.branch, "claude/tender-curie")
        XCTAssertEqual(session.model, "claude-opus-5-5")
        XCTAssertEqual(session.url, "https://claude.ai/code/session_01Abc")
        XCTAssertTrue(session.isActive)
        XCTAssertGreaterThan(session.updated, session.created)
    }

    func testTheShortStatusAndTypedSourceAreRead() {
        let sessions = parse(#"""
        {"data": [{"id": "s1", "title": "", "session_status": "requires_action", "updated_at": "2026-10-19T08:00:00Z",
                   "session_context": {"sources": [{"type": "git_repository", "url": "https://github.com/a/b.git"}]}}]}
        """#)
        XCTAssertEqual(sessions.first?.status, .needsYou)
        XCTAssertEqual(sessions.first?.repository, "a/b")
    }

    func testArchivedSessionsAreLeftOutAndTheNewestComesFirst() {
        let sessions = parse(#"""
        {"data": [
          {"id": "old", "session_status": "idle", "updated_at": "2026-10-18T08:00:00Z"},
          {"id": "gone", "session_status": "archived", "updated_at": "2026-10-19T09:00:00Z"},
          {"id": "new", "session_status": "idle", "updated_at": "2026-10-19T08:00:00Z"}
        ]}
        """#)
        XCTAssertEqual(sessions.map(\.id), ["new", "old"])
    }

    func testStatuses() {
        XCTAssertEqual(ClaudeCloudSessions.status("SESSION_STATUS_IDLE"), .idle)
        XCTAssertEqual(ClaudeCloudSessions.status("running"), .running)
        XCTAssertEqual(ClaudeCloudSessions.status("SESSION_STATUS_REQUIRES_ACTION"), .needsYou)
        XCTAssertEqual(ClaudeCloudSessions.status("failed"), .failed)
        XCTAssertEqual(ClaudeCloudSessions.status("something new"), .idle)
    }

    func testSomethingElseThanAListGivesNothing() {
        XCTAssertEqual(parse(#"{"error": {"type": "authentication_error"}}"#), [])
        XCTAssertEqual(parse("not json"), [])
    }

    func testARunningCloudSessionIsActiveAndAnIdleOneIsEarlier() {
        func record(_ phase: AgentSessionRecord.Phase) -> AgentSessionRecord {
            AgentSessionRecord(id: "c", sources: [.cloud], agent: "Claude (cloud)", accountHome: "", conversationID: "session_1",
                               pid: nil, cwd: "", title: "t", phase: phase, updated: Date())
        }
        XCTAssertEqual(record(.working).section, .active)
        XCTAssertEqual(record(.needsYou).section, .needsYou)
        XCTAssertEqual(record(.finished).section, .earlier)
        XCTAssertFalse(record(.finished).isLive)
    }
}
