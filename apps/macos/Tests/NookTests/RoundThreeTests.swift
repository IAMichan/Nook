import XCTest

/// What the Agents tab took in its third round: the agent's task list from each protocol and its subagents.
final class RoundThreeTests: XCTestCase {
    // MARK: Tasks

    func testClaudeTodoWrite() {
        let steps = RunTasks.claude(["todos": [
            ["content": "Read the code", "status": "completed", "activeForm": "Reading the code"],
            ["content": "Run the tests", "status": "in_progress", "activeForm": "Running the tests"],
            ["content": "Fix", "status": "pending", "activeForm": "Fixing"]
        ]])
        XCTAssertEqual(steps, [RunTaskStep(text: "Read the code", status: .done),
                               RunTaskStep(text: "Running the tests", status: .active),
                               RunTaskStep(text: "Fix", status: .pending)])
        XCTAssertNil(RunTasks.claude(["command": "ls"]))
    }

    func testCodexPlanUpdated() {
        let line = #"{"method":"turn/plan/updated","params":{"threadId":"t","turnId":"u","explanation":null,"plan":[{"step":"Tests","status":"completed"},{"step":" ","status":"inProgress"}]}}"#
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(line)!),
                       [.tasks([RunTaskStep(text: "Tests", status: .done), RunTaskStep(text: "Step 2", status: .active)])])
    }

    func testProgress() {
        let steps = [RunTaskStep(text: "A", status: .done), RunTaskStep(text: "B", status: .pending), RunTaskStep(text: "C", status: .pending)]
        let progress = RunTasks.progress(steps)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.current, "B")
        XCTAssertFalse(RunTasks.isFinished(steps))
        let done = steps.map { RunTaskStep(text: $0.text, status: .done) }
        XCTAssertTrue(RunTasks.isFinished(done))
        XCTAssertEqual(RunTasks.progress(done).current, "C")
    }

    func testOldSessionsDecodeWithoutTasks() throws {
        let run = TestData.run(status: .completed)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as! [String: Any]
        object.removeValue(forKey: "tasks")
        let decoded = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.tasks)
    }

    // MARK: Subagents

    func testSubagentsFromTaskCalls() {
        let user = RunEvent(kind: .user, text: "go")
        let task = RunEvent(kind: .tool, text: "Task · Find auth", tool: "Task",
                            detail: #"{"description":"Find auth","prompt":"Look for login code","subagent_type":"Explore"}"#, state: .running)
        let nested = RunEvent(kind: .tool, text: "↳ Grep · login", tool: "Grep", state: .done)
        let other = RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash", state: .done)
        let agents = Subagents.latest([user, task, nested, other])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.kind, "Explore")
        XCTAssertEqual(agents.first?.title, "Find auth")
        XCTAssertEqual(agents.first?.prompt, "Look for login code")
        XCTAssertEqual(agents.first?.isRunning, true)
        // Only the latest turn counts.
        XCTAssertEqual(Subagents.latest([user, task, RunEvent(kind: .user, text: "next")]), [])
    }

    // MARK: Pull request watch

    func testPullRequestNews() {
        let old = PullRequestWatch(url: "https://github.com/o/r/pull/1", state: "open", checks: "pending", reviewCount: 1,
                                   commentCount: 0, checkedAt: Date())
        let review = PullRequestSnapshot.Note(author: "ann", verdict: "CHANGES_REQUESTED", text: "Rename this")
        let new = PullRequestSnapshot(state: "open", checks: "failure", failedChecks: ["build"],
                                      reviews: [PullRequestSnapshot.Note(author: "bob", verdict: "COMMENTED", text: ""), review],
                                      comments: [PullRequestSnapshot.Note(author: "cy", verdict: "", text: "App.swift: typo")])
        XCTAssertEqual(PullRequestNews.lines(old: old, new: new),
                       ["CI failed: build.", "Review from @ann (changes requested): Rename this", "Comment from @cy: App.swift: typo"])
        XCTAssertTrue(PullRequestNews.needsAgent(old: old, new: new))
        XCTAssertTrue(PullRequestNews.message(url: old.url, lines: ["CI failed."]).contains("- CI failed."))
        let seen = PullRequestNews.updated(old, with: new, at: Date())
        XCTAssertEqual(PullRequestNews.lines(old: seen, new: new), [])
        var merged = new
        merged.state = "merged"
        XCTAssertEqual(PullRequestNews.lines(old: seen, new: merged), ["The pull request was merged."])
        XCTAssertFalse(PullRequestNews.needsAgent(old: seen, new: merged))
    }

    // MARK: Review comments

    func testNewLineNumbers() {
        let diff = ["diff --git a/x b/x", "--- a/x", "+++ b/x", "@@ -10,3 +12,4 @@ func", " keep", "-gone", "+new", "+newer", " end"]
        XCTAssertEqual(ReviewComments.newLineNumbers(diff), [nil, nil, nil, nil, 12, nil, 13, 14, 15])
        XCTAssertEqual(ReviewComments.hunkStart("@@ -1 +7 @@"), 7)
    }

    func testReviewMessageAndQuote() {
        let message = ReviewComments.message([ReviewComment(path: "App.swift", line: 12, code: "+let x = 1", text: " Use a constant ")])
        XCTAssertTrue(message.contains("<review_comment file=\"App.swift\" line=\"12\">\n> +let x = 1\nUse a constant\n</review_comment>"))
        XCTAssertEqual(ReviewComments.quote("one\ntwo", into: "why?"), "> one\n> two\n\nwhy?")
    }

    // MARK: Export

    func testMarkdownExport() {
        var run = TestData.run(status: .completed)
        run.title = "Fix login"
        let events = [RunEvent(kind: .user, text: "Fix the login"), RunEvent(kind: .thinking, text: "secret thoughts"),
                      RunEvent(kind: .tool, text: "Bash · npm `test`"), RunEvent(kind: .tool, text: "Edit · Login.swift"),
                      RunEvent(kind: .assistant, text: "Done."), RunEvent(kind: .result, text: "ok")]
        let markdown = SessionExport.markdown(run, events: events)
        XCTAssertTrue(markdown.hasPrefix("# Fix login\n"))
        XCTAssertTrue(markdown.contains("## You\n\nFix the login"))
        XCTAssertTrue(markdown.contains("<details><summary>2 steps</summary>"))
        XCTAssertTrue(markdown.contains("- `Bash · npm 'test'`"))
        XCTAssertTrue(markdown.contains("## Claude Code\n\nDone."))
        XCTAssertFalse(markdown.contains("secret thoughts"))
        XCTAssertEqual(SessionExport.fileName(run), "fix-login.md")
    }
}
