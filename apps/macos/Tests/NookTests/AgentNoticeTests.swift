import XCTest

/// What an agent's notice says (`AgentNotice`), the same for every agent: what the session is about as the title, the
/// last reply under it, and the headline when there is neither.
final class AgentNoticeTests: XCTestCase {
    func testTheTopicIsTheTitleAndTheReplyGoesUnderIt() {
        let notice = AgentNotice(agent: "Codex", project: "nook", topic: "Fix the login bug",
                                 summary: "Fixed it and added a test.", state: .done, pace: "agent:1")
        XCTAssertEqual(notice.title, "Fix the login bug")
        XCTAssertEqual(notice.detail, "Fixed it and added a test.")
        XCTAssertEqual(notice.context, "Codex · nook")
    }

    func testWithoutATopicTheReplyIsTheTitle() {
        let notice = AgentNotice(agent: "Gemini CLI", summary: "All tests pass.", state: .done, pace: "agent:2")
        XCTAssertEqual(notice.title, "All tests pass.")
        XCTAssertNil(notice.detail)
        XCTAssertEqual(notice.context, "Gemini CLI")
    }

    func testWithNothingToSayTheHeadlineIsTheTitle() {
        let notice = AgentNotice(agent: "Claude Code", state: .failed, pace: "agent:3")
        XCTAssertEqual(notice.title, notice.headline)
        XCTAssertNil(notice.detail)
    }

    func testALongFirstPromptIsCutAtAWord() {
        let prompt = String(repeating: "word ", count: 40) + "\nsecond line"
        let short = AgentNotice.short(prompt)
        XCTAssertLessThanOrEqual(short.count, AgentNotice.topicLimit + 1)
        XCTAssertTrue(short.hasSuffix("word…"))
        XCTAssertEqual(AgentNotice.short("Only the first line\nnot this"), "Only the first line")
    }

    func testChangedLinesShowOnlyWhenThereAreAny() {
        XCTAssertFalse(AgentNotice(agent: "Cursor", state: .done, pace: "a").hasChanges)
        XCTAssertTrue(AgentNotice(agent: "Cursor", state: .done, added: 3, pace: "a").hasChanges)
    }
}
