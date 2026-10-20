import XCTest

/// What the live line says the agent does, which commands count as checks of its work, the task list in the
/// timeline, and what a session's outputs panel holds.
final class AgentProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: RunEvent.Kind, _ text: String, tool: String? = nil, detail: String? = nil,
                       state: RunEvent.State? = nil, at seconds: Double = 0) -> RunEvent {
        RunEvent(kind: kind, text: text, tool: tool, detail: detail, state: state, date: start.addingTimeInterval(seconds))
    }

    private func bash(_ command: String, _ state: RunEvent.State, description: String? = nil, at seconds: Double = 0) -> RunEvent {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        let json = String(data: try! JSONSerialization.data(withJSONObject: input), encoding: .utf8)
        return event(.tool, "Bash · " + command, tool: "Bash", detail: json, state: state, at: seconds)
    }

    // MARK: Verification

    func testRecognizesChecksOfTheWork() {
        let cases: [(String, VerificationCheck.Kind?)] = [
            ("npm test", .tests), ("npm run test:unit", .tests), ("pnpm vitest run", .tests), ("swift test --filter X", .tests),
            ("cd apps/macos && xcodebuild -project Nook.xcodeproj -scheme Nook test", .tests), ("go test ./...", .tests),
            ("python -m pytest -q", .tests), ("pytest tests/", .tests), ("CI=1 cargo test", .tests),
            ("./scripts/core-tests.sh", .tests), ("bash scripts/run_tests.sh", .tests), ("./gradlew test", .tests),
            ("npx tsc --noEmit", .typecheck), ("cargo check", .typecheck), ("mypy src", .typecheck),
            ("swiftlint", .lint), ("npm run lint", .lint), ("go vet ./...", .lint),
            ("swift build", .build), ("npm run build && npm test", .tests), ("xcodebuild -scheme Nook build", .build),
            ("ls tests/", nil), ("cat test.txt", nil), ("git status", nil), ("npm install test-utils", nil),
            ("prettier --write .", nil), ("python script.py test", nil), ("rg build", nil)
        ]
        for (command, kind) in cases {
            XCTAssertEqual(Verification.kind(command: command), kind, command)
        }
    }

    func testCheckOutcomeFollowsTheCommand() {
        XCTAssertEqual(Verification.check(bash("npm test", .running))?.outcome, .running)
        XCTAssertEqual(Verification.check(bash("npm test", .done))?.outcome, .passed)
        XCTAssertEqual(Verification.check(bash("npm test", .failed))?.outcome, .failed)
        XCTAssertNil(Verification.check(bash("ls", .done)))
        XCTAssertNil(Verification.check(event(.tool, "Read · test.swift", tool: "Read", state: .done)), "only commands are checks")
    }

    func testLatestOutcomePerKindWins() {
        let events = [bash("npm test", .failed, at: 1), bash("npm run build", .done, at: 2), bash("npm test", .done, at: 3)]
        let checks = Verification.checks(events)
        XCTAssertEqual(checks.map(\.kind), [.tests, .build], "most important first")
        XCTAssertEqual(checks.first?.outcome, .passed, "tests that failed and then passed passed")
        XCTAssertEqual(ToolTally(events).checks, checks, "a group of calls carries its checks")
    }

    // MARK: Activity

    func testRunningToolSaysWhatItDoes() {
        let user = event(.user, "Fix it")
        XCTAssertEqual(AgentActivity.current([user]), .starting)
        XCTAssertEqual(AgentActivity.current([user, bash("swift test", .running, at: 1)]), .verifying(.tests))
        XCTAssertEqual(AgentActivity.current([user, bash("git diff", .running, description: "Show the changes", at: 1)]),
                       .running("Show the changes"), "the agent's own description reads better than the command")
        let read = event(.tool, "Read · index.html", tool: "Read", detail: #"{"file_path":"/p/site/index.html"}"#, state: .running, at: 1)
        XCTAssertEqual(AgentActivity.current([user, read]), .reading("index.html"))
        let edit = event(.tool, "Edit · App.swift", tool: "Edit", detail: #"{"file_path":"/p/App.swift"}"#, state: .running, at: 1)
        XCTAssertEqual(AgentActivity.current([user, edit]), .editing("App.swift"))
        let grep = event(.tool, "Grep · TODO", tool: "Grep", detail: #"{"pattern":"TODO"}"#, state: .running, at: 1)
        XCTAssertEqual(AgentActivity.current([user, grep]), .searching("TODO"))
        let todo = event(.tool, "TodoWrite · 3", tool: "TodoWrite", detail: #"{"todos":[]}"#, state: .running, at: 1)
        XCTAssertEqual(AgentActivity.current([user, todo]), .planning)
        let mcp = event(.tool, "mcp__github__search_issues", tool: "mcp__github__search_issues", state: .running, at: 1)
        XCTAssertEqual(AgentActivity.current([user, mcp]), .using("Search issues"))
    }

    func testBetweenToolsSaysWhatCameLast() {
        let user = event(.user, "Fix it")
        XCTAssertEqual(AgentActivity.current([user, bash("ls", .done, at: 1)]), .reviewing)
        XCTAssertEqual(AgentActivity.current([user, bash("ls", .failed, at: 1)]), .recovering)
        XCTAssertEqual(AgentActivity.current([user, event(.assistant, "Now the tests.", at: 1)]), .writing)
        XCTAssertEqual(AgentActivity.current([user, event(.thinking, "**Checking the tests** first", at: 1)]),
                       .thinking("Checking the tests"))
        XCTAssertEqual(AgentActivity.current([user, event(.error, "boom", at: 1)]), .recovering)
        let earlier = [event(.user, "Before"), bash("ls", .done, at: 1), event(.result, "", at: 2), event(.user, "Again", at: 3)]
        XCTAssertEqual(AgentActivity.current(earlier), .starting, "only the turn that runs counts")
    }

    // MARK: Task list

    func testChecklistShowsInlineOnlyWhileWorking() {
        let steps = [RunTaskStep(text: "Read", status: .done), RunTaskStep(text: "Writing", status: .active),
                     RunTaskStep(text: "Check", status: .pending)]
        XCTAssertTrue(TaskChecklist.showsInline(steps, active: true))
        XCTAssertFalse(TaskChecklist.showsInline(steps, active: false), "an unfinished list waits above the composer")
        XCTAssertFalse(TaskChecklist.showsInline([], active: true))
        XCTAssertFalse(TaskChecklist.showsInline(nil, active: true))
        XCTAssertEqual(TaskChecklist.activeStep(steps), "Writing")
        XCTAssertNil(TaskChecklist.activeStep([RunTaskStep(text: "Check", status: .pending)]))
    }

    // MARK: Transcripts

    private func message(_ id: String, _ kind: AgentChatMessage.Kind, _ text: String = "", steps: [AgentToolStep] = [],
                         at seconds: Double? = nil) -> AgentChatMessage {
        AgentChatMessage(id: id, kind: kind, text: text, steps: steps, date: seconds.map { start.addingTimeInterval($0) })
    }

    func testTranscriptActivityAndChecks() {
        let running = AgentToolStep(id: "a", name: "Bash", summary: "Run the tests", state: .running, command: "swift test")
        let rows = [message("u", .user, "Go", at: 0), message("s", .tools, steps: [running], at: 1)]
        XCTAssertEqual(AgentActivity.of(running), .verifying(.tests))
        XCTAssertEqual(Verification.check(running)?.outcome, .running)
        XCTAssertEqual(TranscriptPresentation.activity(Array(rows.prefix(1))), .starting)
        var done = running
        done.state = .failed
        XCTAssertEqual(TranscriptPresentation.activity([rows[0], message("s", .tools, steps: [done], at: 1)]), .recovering)
        XCTAssertEqual(TranscriptPresentation.activity([rows[0], message("t", .thinking, "**Looking** around", at: 1)]),
                       .thinking("Looking"))
        XCTAssertEqual(ToolTally(steps: [done]).checks.first?.outcome, .failed)
        let read = AgentToolStep(id: "b", name: "Read", summary: "index.html", state: .running)
        XCTAssertEqual(AgentActivity.of(read), .reading("index.html"))
    }

    func testTranscriptTaskListOfTheTurnThatRuns() {
        let open = [RunTaskStep(text: "One", status: .active)]
        let finished = [RunTaskStep(text: "One", status: .done)]
        func plan(_ id: String, _ steps: [RunTaskStep]) -> AgentChatMessage {
            message(id, .tools, steps: [AgentToolStep(id: id, name: "update_plan", summary: "", tasks: steps)])
        }
        XCTAssertEqual(TranscriptPresentation.tasks([message("u", .user, "Go"), plan("p", open)]), open)
        XCTAssertEqual(TranscriptPresentation.tasks([message("u", .user, "Go"), plan("p", finished)]), finished,
                       "the turn that finished its list still shows it")
        let later = [message("u", .user, "Go"), plan("p", finished), message("u2", .user, "Next")]
        XCTAssertNil(TranscriptPresentation.tasks(later), "a list an earlier turn finished is done with")
        XCTAssertEqual(TranscriptPresentation.tasks(later, includeFinished: true), finished)
        XCTAssertNil(TranscriptPresentation.tasks([message("u", .user, "Go")]))
    }

    func testTranscriptReadsTaskListsFromClaudeAndCodex() throws {
        let claude = """
        {"type":"user","uuid":"u1","timestamp":"2026-10-19T10:00:00Z","message":{"content":"Rewrite the texts"}}
        {"type":"assistant","uuid":"a1","timestamp":"2026-10-19T10:00:05Z","message":{"content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Review the sites","status":"completed","activeForm":"Reviewing the sites"},{"content":"Rewrite Emmi","status":"in_progress","activeForm":"Rewriting Emmi"},{"content":"Check in the browser","status":"pending","activeForm":"Checking"}]}},{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/p/site/index.html","content":"<p>"}}]}}
        """
        let messages = AgentTranscript.jsonl(Data(claude.utf8))
        let tasks = try XCTUnwrap(TranscriptPresentation.tasks(messages))
        XCTAssertEqual(tasks.map(\.text), ["Review the sites", "Rewriting Emmi", "Check in the browser"])
        XCTAssertEqual(tasks.map(\.status), [.done, .active, .pending])
        let outputs = SessionOutputs.collect(messages, directory: "/p")
        XCTAssertEqual(Set(outputs.map(\.id)), ["tasks", "file:/p/site/index.html"])
        XCTAssertEqual(outputs.first { $0.id.hasPrefix("file:") }?.kind, .design)

        XCTAssertEqual(SessionOutputs.taskList(tool: "update_plan", input: ["plan": [["step": "Measure", "status": "in_progress"]]]),
                       [RunTaskStep(text: "Measure", status: .active)])
        XCTAssertEqual(SessionOutputs.taskList(tool: "mcp__codex__update_plan", input: ["plan": [["step": "A", "status": "pending"]]])?.count, 1)
        XCTAssertNil(SessionOutputs.taskList(tool: "Write", input: ["todos": []]))
    }

    // MARK: Outputs

    func testOutputsOfASession() {
        let plan = event(.assistant, "# Plan: new header\n\n1. Do it", tool: "plan", at: 1)
        let page = event(.tool, "Write · index.html", tool: "Write", detail: #"{"file_path":"/p/index.html"}"#, state: .done, at: 2)
        let code = event(.tool, "Edit · App.swift", tool: "Edit", detail: #"{"file_path":"/p/App.swift"}"#, state: .done, at: 3)
        let doc = event(.fileChange, "docs/notes.md", tool: "added", detail: "docs/notes.md", at: 4)
        let again = event(.tool, "Edit · index.html", tool: "Edit", detail: #"{"file_path":"/p/index.html"}"#, state: .done, at: 5)
        let failed = event(.tool, "Write · logo.png", tool: "Write", detail: #"{"file_path":"/p/logo.png"}"#, state: .failed, at: 6)
        let todo = event(.tool, "TodoWrite · 1", tool: "TodoWrite",
                         detail: #"{"todos":[{"content":"Build it","status":"pending","activeForm":"Building"}]}"#, state: .done, at: 7)
        let outputs = SessionOutputs.collect([event(.user, "Go"), plan, page, code, doc, again, failed, todo], tasks: nil, directory: "/p")
        XCTAssertEqual(outputs.map(\.id), ["tasks", "file:/p/index.html", "file:/p/docs/notes.md", "plan:" + plan.id.uuidString],
                       "newest first; code and failed writes are not outputs, a page written twice shows once")
        XCTAssertEqual(outputs[1].date, again.date)
        XCTAssertEqual(outputs[2].kind, .document)
        XCTAssertEqual(outputs[0].kind, .tasks([RunTaskStep(text: "Build it", status: .pending)]))

        let kept = [RunTaskStep(text: "Now", status: .active)]
        XCTAssertEqual(SessionOutputs.collect([todo], tasks: kept, directory: "/p").first?.kind, .tasks(kept),
                       "the list the session keeps wins over the one in its timeline")
    }

    func testNewOutputs() {
        let page = SessionOutput(id: "file:/p/a.html", kind: .design, title: "a.html", path: "/p/a.html", date: start)
        let seen = Set([SessionOutputs.signature(page)])
        XCTAssertFalse(SessionOutputs.hasNew([page], seen: seen))
        var rewritten = page
        rewritten.date = start.addingTimeInterval(5)
        XCTAssertTrue(SessionOutputs.hasNew([rewritten], seen: seen), "written again is new")
        XCTAssertEqual(SessionOutputs.kind(path: "/a/b.SVG"), .design)
        XCTAssertNil(SessionOutputs.kind(path: "/a/b.swift"))
        XCTAssertEqual(SessionOutputs.resolve("docs/a.md", in: "/p"), "/p/docs/a.md")
        XCTAssertEqual(SessionOutputs.resolve("/abs/a.md", in: "/p"), "/abs/a.md")
    }
}
