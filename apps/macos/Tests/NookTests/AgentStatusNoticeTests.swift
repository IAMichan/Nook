import XCTest

/// What an agent's notice says (`AgentStatusNotice`), the same for every agent: what the session is about as the title, the
/// last reply under it, and the headline when there is neither.
final class AgentStatusNoticeTests: XCTestCase {
    func testTheTopicIsTheTitleAndTheReplyGoesUnderIt() {
        let notice = AgentStatusNotice(agent: "Codex", project: "nook", topic: "Fix the login bug",
                                 summary: "Fixed it and added a test.", state: .done, session: "1")
        XCTAssertEqual(notice.title, "Fix the login bug")
        XCTAssertEqual(notice.detail, "Fixed it and added a test.")
        XCTAssertEqual(notice.context, "Codex · nook")
    }

    func testWithoutATopicTheReplyIsTheTitle() {
        let notice = AgentStatusNotice(agent: "Gemini CLI", summary: "All tests pass.", state: .done, session: "2")
        XCTAssertEqual(notice.title, "All tests pass.")
        XCTAssertNil(notice.detail)
        XCTAssertEqual(notice.context, "Gemini CLI")
    }

    func testWithNothingToSayTheHeadlineIsTheTitle() {
        let notice = AgentStatusNotice(agent: "Claude Code", state: .failed, session: "3")
        XCTAssertEqual(notice.title, notice.headline)
        XCTAssertNil(notice.detail)
    }

    func testALongFirstPromptIsCutAtAWord() {
        let prompt = String(repeating: "word ", count: 40) + "\nsecond line"
        let short = AgentStatusNotice.short(prompt)
        XCTAssertLessThanOrEqual(short.count, AgentStatusNotice.topicLimit)
        XCTAssertTrue(short.hasSuffix("word…"))
        XCTAssertEqual(AgentStatusNotice.short("Only the first line\nnot this"), "Only the first line")
    }

    func testTheStripAndTheHistoryNameTheSession() {
        let notice = AgentStatusNotice(agent: "Codex", project: "nook", topic: "Fix the login bug",
                                       summary: "Done.", state: .done, session: "run:1")
        XCTAssertEqual(notice.stripLine, notice.headline + " · Fix the login bug")
        XCTAssertEqual(notice.historyDetail, "Fix the login bug · Done.")
        XCTAssertEqual(notice.cardID, "agentstatus-run:1")

        let untitled = AgentStatusNotice(agent: "Codex", project: "nook", state: .done, session: "2")
        XCTAssertEqual(untitled.stripLine, untitled.headline + " · nook")
        XCTAssertEqual(untitled.historyDetail, "")
    }

    func testAFailureKeepsTheSessionsCardButPacesApart() {
        let done = AgentStatusNotice(agent: "Codex", state: .done, session: "run:7")
        let failed = AgentStatusNotice(agent: "Codex", state: .failed, session: "run:7")
        XCTAssertEqual(done.cardID, failed.cardID)
        XCTAssertNotEqual(done.pace, failed.pace)
    }

    func testATopicWithoutSpacesStaysWithinTheLimit() {
        let short = AgentStatusNotice.short(String(repeating: "x", count: 200))
        XCTAssertEqual(short.count, AgentStatusNotice.topicLimit)
        XCTAssertTrue(short.hasSuffix("…"))
    }

    func testChangedLinesShowOnlyWhenThereAreAny() {
        XCTAssertFalse(AgentStatusNotice(agent: "Cursor", state: .done, session: "a").hasChanges)
        XCTAssertTrue(AgentStatusNotice(agent: "Cursor", state: .done, added: 3, session: "a").hasChanges)
    }
}
