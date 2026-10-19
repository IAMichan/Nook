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

    // MARK: ACP agents

    func testParseCommandLikeAShell() {
        XCTAssertEqual(CustomAgents.parseCommand("npx -y @kiro/acp@1.2.3")?.command, "npx")
        XCTAssertEqual(CustomAgents.parseCommand("npx -y @kiro/acp@1.2.3")?.arguments, ["-y", "@kiro/acp@1.2.3"])
        XCTAssertEqual(CustomAgents.parseCommand(#"  my-agent --name "Two Words" 'it''s' x\ y "#)?.arguments,
                       ["--name", "Two Words", "its", "x y"])
        XCTAssertNil(CustomAgents.parseCommand("agent \"open"))
        XCTAssertNil(CustomAgents.parseCommand("   "))
    }

    func testShellLineQuotesEveryPart() {
        let agent = CustomAgent(profileID: "acp-x", name: "X", command: "npx", arguments: ["-y", "@a/b@1.0.0", "it's; rm -rf ~"])
        XCTAssertEqual(agent.shellLine, #"exec npx -y @a/b@1.0.0 'it'\''s; rm -rf ~'"#)
    }

    func testRegistryEntries() {
        let json = #"""
        {"version":"1.0.0","agents":[
          {"id":"kiro","name":"Kiro","version":"1.2.3","description":"An agent","website":"https://kiro.dev",
           "distribution":{"npx":{"package":"@kiro/acp@1.2.3","args":["--acp"],"env":{"KIRO_MODE":"acp","bad key":"x"}}}},
          {"id":"pyagent","name":"Py","version":"0.4.0","description":"",
           "distribution":{"uvx":{"package":"py-agent==0.4.0"}}},
          {"id":"bin","name":"Binary","version":"2.0.0","description":"",
           "distribution":{"binary":{"darwin-aarch64":{"archive":"https://x.dev/a.tgz","cmd":"./a"}}}},
          {"id":"loose","name":"Loose","version":"1.0.0","description":"","distribution":{"npx":{"package":"loose-agent"}}},
          {"id":"Bad Id","name":"Bad","version":"1","description":"","distribution":{}}
        ]}
        """#
        let entries = AcpRegistry.parse(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), ["kiro", "pyagent", "bin", "loose"])
        XCTAssertEqual(entries[0].command, "npx")
        XCTAssertEqual(entries[0].arguments, ["-y", "@kiro/acp@1.2.3", "--acp"])
        XCTAssertEqual(entries[0].environment, ["KIRO_MODE": "acp"])
        XCTAssertEqual(entries[0].website, "https://kiro.dev")
        XCTAssertEqual(entries[1].command, "uvx")
        XCTAssertEqual(entries[1].arguments, ["py-agent==0.4.0"])
        // Only a download, or a package without an exact version: listed, but not started.
        XCTAssertFalse(entries[2].isSupported)
        XCTAssertFalse(entries[3].isSupported)
        let agent = AcpRegistry.agent(from: entries[0], profileID: "acp-kiro")
        XCTAssertEqual(agent?.registryID, "kiro")
        XCTAssertEqual(agent?.version, "1.2.3")
        XCTAssertNil(AcpRegistry.agent(from: entries[2], profileID: "acp-bin"))
        XCTAssertEqual(AcpRegistry.parse(Data("not json".utf8)), [])
    }

    func testCustomAgentStore() {
        let defaults = UserDefaults(suiteName: "nook.tests.acp." + UUID().uuidString)!
        XCTAssertEqual(CustomAgents.load(defaults: defaults), [])
        let first = CustomAgent(profileID: "acp-a", name: "A", command: "a")
        CustomAgents.upsert(first, defaults: defaults)
        CustomAgents.upsert(CustomAgent(profileID: "acp-b", name: "B", command: "b"), defaults: defaults)
        var changed = first
        changed.arguments = ["--acp"]
        CustomAgents.upsert(changed, defaults: defaults)
        XCTAssertEqual(CustomAgents.load(defaults: defaults).count, 2)
        XCTAssertEqual(CustomAgents.agent(for: "acp-a", defaults: defaults)?.arguments, ["--acp"])
        CustomAgents.remove(profileID: "acp-a", defaults: defaults)
        XCTAssertNil(CustomAgents.agent(for: "acp-a", defaults: defaults))
    }

    func testAcpAgentStartsThroughTheLoginShell() {
        var input = AgentCommand.Input(provider: .acp, executable: "/bin/zsh", prompt: "", model: "", mode: .agent,
                                       permission: .acceptEdits, instructions: "", workingDirectory: "/w", resumeSessionID: nil,
                                       accountEnvironment: [:], runID: UUID())
        input.customAgent = CustomAgent(profileID: "acp-k", name: "K", command: "npx", arguments: ["-y", "@k/acp@1.0.0"],
                                        environment: ["K_MODE": "acp"])
        let spec = AgentCommand.acpSpec(input)
        XCTAssertEqual(spec.executable, "/bin/zsh")
        XCTAssertEqual(spec.arguments, ["-ilc", "exec npx -y @k/acp@1.0.0"])
        XCTAssertEqual(spec.extraEnvironment["K_MODE"], "acp")
        XCTAssertTrue(spec.keepsInputOpen)
        XCTAssertTrue(RunProvider.acp.usesACP)
    }
}
