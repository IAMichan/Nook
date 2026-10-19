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

    func testABareListIsReadToo() {
        let list = parse(#"[{"id": "session_1", "title": "Bare", "session_status": "SESSION_STATUS_RUNNING"}]"#)
        XCTAssertEqual(list.map(\.title), ["Bare"])
        XCTAssertEqual(list.first?.status, .running)
    }

    func testOrganizationFromTheProfile() {
        let profile = #"{"account": {"uuid": "a1"}, "organization": {"uuid": "org-1", "name": "Mine"}}"#
        XCTAssertEqual(ClaudeCloudSessions.organization(fromProfile: Data(profile.utf8)), "org-1")
        XCTAssertNil(ClaudeCloudSessions.organization(fromProfile: Data(#"{"account": {}}"#.utf8)))
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

    // MARK: Conversation

    func testTheConversationIsReadFromStreamEvents() throws {
        let page = try XCTUnwrap(ClaudeCloudSessions.eventPage(Data(#"""
        {"data": [
          {"type": "user", "uuid": "u1", "timestamp": "2026-10-19T08:00:00Z",
           "message": {"role": "user", "content": "Kan je deze niet ook weergeven?"}},
          {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-19T08:00:05Z",
           "message": {"role": "assistant", "content": [
             {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
             {"type": "text", "text": "Ja, dat kan."}]}},
          {"type": "assistant", "uuid": "a2", "parent_tool_use_id": "t9", "timestamp": "2026-10-19T08:00:06Z",
           "message": {"role": "assistant", "content": [{"type": "text", "text": "subagent"}]}},
          {"type": "result", "uuid": "r1"}
        ], "has_more": true, "last_id": "r1"}
        """#.utf8)))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.lastID, "r1")
        let messages = ClaudeCloudSessions.conversation(page.events)
        XCTAssertEqual(messages.first?.kind, .user)
        XCTAssertEqual(messages.first?.text, "Kan je deze niet ook weergeven?")
        XCTAssertEqual(messages.last?.kind, .assistant)
        XCTAssertEqual(messages.last?.text, "Ja, dat kan.")
        XCTAssertTrue(messages.contains { $0.kind == .tools })
        XCTAssertFalse(messages.contains { $0.text == "subagent" })
    }

    func testWrappedEventsAreReadOldestFirstAndOnlyOnce() throws {
        let page = try XCTUnwrap(ClaudeCloudSessions.eventPage(Data(#"""
        {"data": [
          {"created_at": "2026-10-19T08:00:05Z", "assistant": {"uuid": "a1", "internal_anthropic_catchall": {
            "timestamp": "2026-10-19T08:00:05Z",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "Klaar."}]}}}},
          {"created_at": "2026-10-19T08:00:00Z", "user": {"uuid": "u1", "internal_anthropic_catchall": {
            "message": {"role": "user", "content": "Maak het af"}}}},
          {"created_at": "2026-10-19T08:00:00Z", "user": {"uuid": "u1", "internal_anthropic_catchall": {
            "message": {"role": "user", "content": "Maak het af"}}}}
        ], "has_more": false}
        """#.utf8)))
        let messages = ClaudeCloudSessions.conversation(page.events)
        XCTAssertEqual(messages.map(\.text), ["Maak het af", "Klaar."])
    }

    func testTheEventsEndpointPagesOn() {
        XCTAssertEqual(ClaudeCloudSessions.eventsEndpoint("session_1").absoluteString,
                       "https://api.anthropic.com/v1/sessions/session_1/events?limit=1000")
        XCTAssertEqual(ClaudeCloudSessions.eventsEndpoint("session_1", after: "e9").absoluteString,
                       "https://api.anthropic.com/v1/sessions/session_1/events?limit=1000&after_id=e9")
    }
}
