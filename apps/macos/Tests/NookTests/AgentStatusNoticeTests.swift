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

/// A macOS notification says the gist: the first sentence in plain words, short links, within two banner lines.
final class BannerTextTests: XCTestCase {
    func testALongReplyBecomesItsFirstSentence() {
        let reply = "The branch is pushed and PR #1394 is now at d3f92455. CI has started again; the run takes about "
            + "10 minutes because chatd builds first."
        XCTAssertEqual(BannerText.gist(reply), "The branch is pushed and PR #1394 is now at d3f92455.")
    }

    func testLinksAndMarkdownAreShortened() {
        XCTAssertEqual(BannerText.gist("PR 6 is klaar: https://github.com/InfarisHQ/monorepo/pull/3885 (verdwaalde rondingen)."),
                       "PR 6 is klaar: #3885 (verdwaalde rondingen).")
        XCTAssertEqual(BannerText.gist("See [the docs](https://example.com/a/b) and https://www.apple.com/mac for more."),
                       "See the docs and apple.com for more.")
        XCTAssertEqual(BannerText.gist("## Summary\n\n- **Fixed** the `login` bug"), "Summary")
        XCTAssertEqual(BannerText.plain("- **Fixed** the `login` bug"), "Fixed the login bug")
    }

    func testAShortFirstSentenceTakesTheNextAlong() {
        XCTAssertEqual(BannerText.gist("Done. All 42 tests pass now. Nothing else."), "Done. All 42 tests pass now.")
    }

    func testTheGistStaysWithinTheLimit() {
        let gist = BannerText.gist(String(repeating: "word ", count: 60))
        XCTAssertLessThanOrEqual(gist.count, BannerText.limit)
        XCTAssertTrue(gist.hasSuffix("…"))
    }

    func testTheSubtitleNamesFolderAndSession() {
        XCTAssertEqual(BannerText.subtitle(project: "nook", topic: "Fix the login bug"), "nook · Fix the login bug")
        XCTAssertEqual(BannerText.subtitle(project: "nook", topic: ""), "nook")
        XCTAssertLessThanOrEqual(BannerText.subtitle(project: "", topic: String(repeating: "a ", count: 80)).count,
                                 BannerText.subtitleLimit)
    }

    func testAnApprovalsContextDropsTheAgentTheTitleNames() {
        XCTAssertEqual(BannerText.context("Claude Code · Fix guard", title: "Claude Code wants to open a pull request"),
                       "Fix guard")
        XCTAssertEqual(BannerText.context("Codex · nook", title: "Run a command"), "Codex · nook")
    }

    func testAnAgentNoticesBannerIsShort() {
        let notice = AgentStatusNotice(agent: "Claude Code", project: "Nook", topic: "Push the branch",
                                       summary: "Pushed. CI runs again and takes about ten minutes.", state: .done, session: "1")
        XCTAssertEqual(notice.bannerSubtitle, "Nook · Push the branch")
        XCTAssertEqual(notice.bannerBody, "Pushed. CI runs again and takes about ten minutes.")
    }
}
