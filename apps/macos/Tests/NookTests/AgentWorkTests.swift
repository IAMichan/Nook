import XCTest

/// The Agents tab's work features: the agent's task list from each protocol and its subagents.
final class AgentWorkTests: XCTestCase {
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
    // MARK: Remote machines

    func testRemoteCommandRunsTheAgentInTheFolderThere() {
        let command = RemoteLaunch.command(executable: "/opt/homebrew/bin/claude", arguments: ["-p", "--model", "opus 4"],
                                           directory: "~/code/my app")
        let inner = "cd ~/'code/my app' && exec claude -p --model 'opus 4'"
        XCTAssertEqual(command, #"exec "${SHELL:-/bin/sh}" -lc "# + CustomAgents.quote(inner))
    }

    func testRemoteQuoting() {
        XCTAssertEqual(RemoteLaunch.quotedDirectory("~"), "~")
        XCTAssertEqual(RemoteLaunch.quotedDirectory("~/code/app"), "~/code/app")
        XCTAssertEqual(RemoteLaunch.quotedDirectory("/srv/my app"), "'/srv/my app'")
        // An ACP agent's own line runs as it is, with its variables exported first.
        let acp = RemoteLaunch.command(executable: "/bin/zsh", arguments: ["-ilc", "exec npx -y @k/acp@1.0.0"],
                                       directory: "/srv/app", environment: ["K_MODE": "acp", "bad key": "x"])
        XCTAssertEqual(acp, #"exec "${SHELL:-/bin/sh}" -lc 'export K_MODE=acp; cd /srv/app && exec npx -y @k/acp@1.0.0'"#)
    }

    func testRemoteWrapGoesThroughSSH() {
        let machine = RemoteMachine(id: "m1", name: "buildbox", host: "me@buildbox", port: 2222)
        let spec = LaunchSpec(executable: "/usr/local/bin/codex", arguments: ["app-server"],
                              extraEnvironment: ["CODEX_HOME": "/Users/me/.codex-work"],
                              workingDirectory: "/srv/app", initialInput: ["hello"], keepsInputOpen: true)
        let wrapped = RemoteLaunch.wrap(spec, target: RemoteTarget(machine: machine, directory: "/srv/app"))
        XCTAssertEqual(wrapped.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(wrapped.arguments.prefix(7)),
                       ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4"])
        XCTAssertEqual(Array(wrapped.arguments.dropFirst(7).prefix(4)), ["-p", "2222", "--", "me@buildbox"])
        XCTAssertTrue(wrapped.arguments.last?.contains("cd /srv/app && exec codex app-server") == true)
        // A local account folder means nothing over there.
        XCTAssertEqual(wrapped.extraEnvironment, [:])
        XCTAssertEqual(wrapped.initialInput, ["hello"])
        XCTAssertTrue(wrapped.keepsInputOpen)
    }

    func testRemoteValidation() {
        XCTAssertTrue(RemoteMachines.isValidHost("me@buildbox.local"))
        XCTAssertTrue(RemoteMachines.isValidHost("buildbox"))
        XCTAssertFalse(RemoteMachines.isValidHost("-oProxyCommand=evil"))
        XCTAssertFalse(RemoteMachines.isValidHost("host; rm -rf ~"))
        XCTAssertTrue(RemoteMachines.isValidDirectory("~/code"))
        XCTAssertTrue(RemoteMachines.isValidDirectory("/srv/app"))
        XCTAssertFalse(RemoteMachines.isValidDirectory("code/app"))
        var config = NewRunConfig()
        config.task = "Fix it"
        let machine = RemoteMachine(name: "box", host: "box")
        config.remote = RemoteTarget(machine: machine, directory: "~/app")
        XCTAssertNil(config.problem, "a remote session needs no local folder")
        config.isolation = .worktree
        // A worktree there needs a branch name (filled in from the task when starting).
        XCTAssertEqual(config.problem, .invalidBranchName)
        config.isolation = .folder
        config.remote?.directory = "relative"
        XCTAssertEqual(config.problem, .invalidRemote)
        var run = TestData.run(status: .completed, project: "/srv/app")
        run.remote = RemoteTarget(machine: machine, directory: "/srv/app")
        XCTAssertEqual(run.projectName, "box:app")
        XCTAssertTrue(run.isRemote)
    }

    // MARK: Codex subagents

    func testCodexSpawnAgent() {
        let spawn = #"{"method":"item/started","params":{"item":{"type":"collabAgentToolCall","id":"c1","tool":"spawnAgent","status":"inProgress","prompt":"Find the login code","model":"gpt-5","senderThreadId":"t0","receiverThreadIds":["t1"],"agentsStates":{}}}}"#
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(spawn)!),
                       [.subagentSpawned(id: "c1", prompt: "Find the login code", model: "gpt-5", threads: ["t1"], failed: false)])
        let wait = #"{"method":"item/completed","params":{"item":{"type":"collabAgentToolCall","id":"c2","tool":"wait","status":"completed","senderThreadId":"t0","receiverThreadIds":["t1"],"agentsStates":{"t1":{"status":"completed","message":"Found it in Auth.swift"}}}}}"#
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(wait)!),
                       [.subagentStates(["t1": CodexAgentState(status: "completed", message: "Found it in Auth.swift")])])
        XCTAssertTrue(CodexAgentState(status: "errored").isFailure)
        XCTAssertFalse(CodexAgentState(status: "running").isFinished)
    }
    // MARK: GitLab merge request watch

    func testGitLabMergeRequestLink() throws {
        let url = URL(string: "https://gitlab.com/group/sub/app/-/merge_requests/12#note_5")!
        let parsed = try XCTUnwrap(GitLabAPI.mergeRequest(url))
        XCTAssertEqual(parsed.iid, 12)
        XCTAssertEqual(parsed.repo.path, "group/sub/app")
        XCTAssertEqual(GitLabAPI.mergeRequestURL(parsed.repo, iid: 12, suffix: "/notes", query: "per_page=100")?.absoluteString,
                       "https://gitlab.com/api/v4/projects/group%2Fsub%2Fapp/merge_requests/12/notes?per_page=100")
        XCTAssertNil(GitLabAPI.mergeRequest(URL(string: "https://github.com/o/r/pull/1")!))
        XCTAssertTrue(PullRequestWatch.canWatch(url))
        XCTAssertTrue(PullRequestWatch.canWatch(URL(string: "https://github.com/o/r/pull/7")!))
        XCTAssertFalse(PullRequestWatch.canWatch(URL(string: "https://bitbucket.org/o/r/pull-requests/3")!))
    }

    func testGitLabSnapshot() {
        let snapshot = GitLabAPI.snapshot(
            mergeRequest: ["state": "opened", "head_pipeline": ["id": 9, "status": "failed"]],
            notes: [["system": true, "body": "added 1 commit", "author": ["username": "bot"]],
                    ["system": false, "body": "Rename this", "author": ["username": "ann"], "position": ["new_path": "App.swift"]]],
            approvals: ["approved_by": [["user": ["username": "bob"]]]],
            failedJobs: [["name": "test"]])
        XCTAssertEqual(snapshot.state, "open")
        XCTAssertEqual(snapshot.checks, "failure")
        XCTAssertEqual(snapshot.failedChecks, ["test"])
        XCTAssertEqual(snapshot.reviews, [PullRequestSnapshot.Note(author: "bob", verdict: "APPROVED", text: "")])
        XCTAssertEqual(snapshot.comments, [PullRequestSnapshot.Note(author: "ann", verdict: "", text: "App.swift: Rename this")])
        XCTAssertEqual(GitLabAPI.snapshot(mergeRequest: ["state": "merged"], notes: [], approvals: nil, failedJobs: []).state, "merged")
    }

    func testTurnChangesFilesPerTurn() {
        let start = Date(timeIntervalSince1970: 100)
        let user = RunEvent(kind: .user, text: "fix it", date: start)
        let edit = RunEvent(kind: .tool, text: "Edit · App.swift", tool: "Edit",
                            detail: #"{"file_path":"/repo/App.swift","old_string":"a","new_string":"b"}"#, state: .done)
        let again = RunEvent(kind: .tool, text: "Write · App.swift", tool: "Write", detail: #"{"file_path":"/repo/App.swift"}"#, state: .done)
        let read = RunEvent(kind: .tool, text: "Read · Other.swift", tool: "Read", detail: #"{"file_path":"/repo/Other.swift"}"#, state: .done)
        let change = RunEvent(kind: .fileChange, text: "New.swift", tool: "add", detail: "/repo/New.swift")
        let end = RunEvent(kind: .result, text: "done", date: Date(timeIntervalSince1970: 160))
        let quiet = [RunEvent(kind: .user, text: "thanks"), RunEvent(kind: .assistant, text: "ok"), RunEvent(kind: .result, text: "done")]
        let turns = TurnChanges.byTurnEnd([user, edit, again, read, change, end] + quiet)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[end.id], TurnChanges.Turn(start: start, end: end.date, files: ["/repo/App.swift", "/repo/New.swift"]))
        // A turn still running has no result yet: nothing to show.
        XCTAssertTrue(TurnChanges.byTurnEnd([user, edit]).isEmpty)
    }

    func testTurnChangesCheckpoints() {
        let first = RunCheckpoint(ref: "c0", date: Date(timeIntervalSince1970: 10))
        let second = RunCheckpoint(ref: "c1", date: Date(timeIntervalSince1970: 50))
        let third = RunCheckpoint(ref: "c2", date: Date(timeIntervalSince1970: 90))
        let all = [first, second, third]
        let middle = TurnChanges.checkpoints(all, start: Date(timeIntervalSince1970: 60), end: Date(timeIntervalSince1970: 85))
        XCTAssertEqual(middle?.before, second)
        XCTAssertEqual(middle?.after, third)
        let last = TurnChanges.checkpoints(all, start: Date(timeIntervalSince1970: 95), end: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(last?.before, third)
        XCTAssertNil(last?.after)
        XCTAssertNil(TurnChanges.checkpoints(all, start: Date(timeIntervalSince1970: 5), end: Date(timeIntervalSince1970: 8)))
    }

    func testBackgroundWakeStartsATurn() {
        let user = RunEvent(kind: .user, text: "run the tests in the background")
        let end = RunEvent(kind: .result, text: "started")
        let wake = RunEvent(kind: .system, text: "woke", tool: "wake")
        let answer = RunEvent(kind: .assistant, text: "Tests passed")
        let turns = TimelinePresentation.split([user, end, wake, answer, RunEvent(kind: .result, text: "done")])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].first, wake)
        XCTAssertTrue(ClaudeStreamEvent.isWork(.text("hi")))
        XCTAssertFalse(ClaudeStreamEvent.isWork(.notice("compacting")))
    }

    func testAcpRegistryBinaryDownload() {
        let sha = String(repeating: "ab", count: 32)
        let raw: [String: Any] = [
            "id": "kiro", "name": "Kiro", "version": "1.2.3",
            "distribution": ["binary": [AcpRegistry.platform: [
                "archive": "https://example.com/kiro-1.2.3.tar.gz", "sha256": sha.uppercased(), "cmd": "./bin/kiro", "args": ["acp"]]]]]
        let entry = AcpRegistry.entry(raw)
        XCTAssertNil(entry?.command)
        XCTAssertEqual(entry?.binary?.sha256, sha)
        XCTAssertEqual(entry?.binary?.kind, .tar)
        XCTAssertTrue(entry?.isSupported == true)
        let agent = entry.flatMap { AcpRegistry.agent(from: $0, installedIn: "/apps/kiro/1.2.3", profileID: "acp-kiro") }
        XCTAssertEqual(agent?.command, "/apps/kiro/1.2.3/bin/kiro")
        XCTAssertEqual(agent?.arguments, ["acp"])
        XCTAssertEqual(agent?.installedAt, "/apps/kiro/1.2.3")
        // No checksum, plain HTTP or a way out of the folder: not installable.
        XCTAssertNil(AcpRegistry.binary(["archive": "https://example.com/a.zip", "cmd": "a"]))
        XCTAssertNil(AcpRegistry.binary(["archive": "http://example.com/a.zip", "sha256": sha, "cmd": "a"]))
        XCTAssertNil(AcpRegistry.binary(["archive": "https://example.com/a.zip", "sha256": sha, "cmd": "../../bin/sh"]))
        XCTAssertNil(AcpRegistry.binary(["archive": "https://example.com/a.zip", "sha256": sha, "cmd": "/bin/sh"]))
        XCTAssertEqual(AcpRegistry.binary(["archive": "https://example.com/agent", "sha256": sha, "cmd": "agent"])?.kind, .raw)
    }

    func testRemoteGitCommand() {
        let machine = RemoteMachine(name: "box", host: "me@box", port: 2222)
        let target = RemoteTarget(machine: machine, directory: "~/code/app")
        let arguments = RemoteLaunch.git(["-C", "~/code/my app", "commit", "-m", "it's done"], target: target, directory: "~/code/my app")
        XCTAssertEqual(Array(arguments.suffix(3)).first, "--")
        XCTAssertEqual(arguments[arguments.count - 2], "me@box")
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        let line = arguments.last ?? ""
        XCTAssertTrue(line.hasPrefix(#"exec "${SHELL:-/bin/sh}" -lc '"#))
        // The folder is a cd (tilde left to the remote shell); "-C" is not passed on; the message stays one argument.
        XCTAssertTrue(line.contains("cd ~/"))
        XCTAssertFalse(line.contains(" -C "))
        XCTAssertTrue(line.contains("exec git commit -m"))
        let plain = RemoteLaunch.git(["status"], target: target, directory: nil).last ?? ""
        XCTAssertFalse(plain.contains("cd "))
        XCTAssertTrue(GitService(executable: "git", remote: target).remote != nil)
    }

    func testBrowserSearchEngine() {
        XCTAssertEqual(BrowserSearchEngine.address("example.com", engine: .google)?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserSearchEngine.address("localhost:3000", engine: .google)?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserSearchEngine.address("swift actors", engine: .google)?.absoluteString,
                       "https://www.google.com/search?q=swift%20actors")
        XCTAssertEqual(BrowserSearchEngine.address("swift actors", engine: .duckDuckGo)?.host, "duckduckgo.com")
        XCTAssertNil(BrowserSearchEngine.address("   ", engine: .bing))
        XCTAssertNil(BrowserSearchEngine.address("file:///etc/passwd", engine: .bing).flatMap { $0.isFileURL ? $0 : nil })
        let defaults = UserDefaults(suiteName: "browser-search-\(UUID().uuidString)")!
        XCTAssertEqual(BrowserSearchEngine.current(defaults: defaults), .duckDuckGo)
        defaults.set("kagi", forKey: BrowserSearchEngine.defaultsKey)
        XCTAssertEqual(BrowserSearchEngine.current(defaults: defaults), .kagi)
    }

    func testMcpUIResource() {
        let html = "<html><body>```not the end```<button>Go</button></body></html>"
        let block: [String: Any] = ["type": "resource", "resource": ["uri": "ui://chart/1", "mimeType": "text/html", "text": html]]
        let output = ClaudeStreamParser.resultText([["type": "text", "text": "Here is the chart"], block])
        XCTAssertEqual(McpUI.resource(in: output), McpUI.Resource(uri: "ui://chart/1", html: html, link: nil))
        XCTAssertEqual(McpUI.stripped(output), "Here is the chart")
        let link: [String: Any] = ["type": "resource", "resource": ["uri": "ui://dash", "mimeType": "text/uri-list",
                                                                   "text": "# comment\nhttps://example.com/dash"]]
        XCTAssertEqual(McpUI.resource(in: McpUI.encode(link)), McpUI.Resource(uri: "ui://dash", html: nil, link: URL(string: "https://example.com/dash")))
        let blob: [String: Any] = ["type": "resource", "resource": ["uri": "ui://b", "mimeType": "text/html",
                                                                   "blob": Data("<p>hi</p>".utf8).base64EncodedString()]]
        XCTAssertEqual(McpUI.resource(in: McpUI.encode(blob))?.html, "<p>hi</p>")
        // Not a UI resource, or a page that was clipped: nothing to show.
        XCTAssertNil(McpUI.encode(["type": "resource", "resource": ["uri": "file:///a", "mimeType": "text/html", "text": "x"]]))
        XCTAssertNil(McpUI.resource(in: "```mcp-ui ui://x\n<html>…"))
        XCTAssertEqual(RunEvent.clip(String(repeating: "a", count: 20_000)).count, RunEvent.outputLimit + 2)
        XCTAssertEqual(RunEvent.clip(McpUI.fence + String(repeating: "a", count: 20_000)).count, 20_000 + McpUI.fence.count)
    }

    func testSimulatorParsing() {
        let json = #"""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
          {"udid":"B","name":"iPhone 16","state":"Booted"},{"udid":"C","name":"iPad","state":"Shutdown"}],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"A","name":"Apple Watch","state":"Booted"}]}}
        """#
        let devices = Simulators.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.udid), ["A", "B"])
        XCTAssertEqual(devices.last?.runtime, "iOS 18.2")
        XCTAssertEqual(Simulators.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"), "xrOS 2.0")
        XCTAssertTrue(Simulators.parse(Data("nope".utf8)).isEmpty)
    }

    func testBackgroundWorkPendingAndMessage() {
        let user = RunEvent(kind: .user, text: "run the server")
        let background = RunEvent(kind: .tool, text: "Bash · npm run dev", tool: "Bash",
                                  detail: #"{"command":"npm run dev","run_in_background":true}"#, state: .done)
        let end = RunEvent(kind: .result, text: "ok")
        XCTAssertTrue(BackgroundWork.pending(after: [user, background, end], before: false))
        // A later turn of yours keeps what was known; the turn the agent woke up for ends it.
        let next = [user, background, end, RunEvent(kind: .user, text: "thanks"), RunEvent(kind: .result, text: "ok")]
        XCTAssertTrue(BackgroundWork.pending(after: next, before: true))
        XCTAssertFalse(BackgroundWork.pending(after: next, before: false))
        let woke = next + [RunEvent(kind: .system, text: "woke", tool: "wake"), RunEvent(kind: .result, text: "done")]
        XCTAssertFalse(BackgroundWork.pending(after: woke, before: true))
        let running = [user, RunEvent(kind: .tool, text: "shell · sleep 60", tool: "shell", state: .running)]
        XCTAssertTrue(BackgroundWork.pending(after: running, before: false))

        let message = BackgroundWork.codexMessage(command: "npm test", exitCode: 1,
                                                  output: (1...100).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(message.hasPrefix("Background command completed (exit 1): npm test\n\nOutput tail:\nline 61"))
        XCTAssertTrue(message.hasSuffix("line 100"))
        XCTAssertEqual(BackgroundWork.codexMessage(command: "x", exitCode: nil, output: ""), "Background command completed (exit unknown): x")
    }

    func testAcpWakeEvidence() {
        XCTAssertTrue(AcpEvent.messageChunk("Done: tests pass").isWakeEvidence)
        XCTAssertFalse(AcpEvent.messageChunk("  \n").isWakeEvidence)
        XCTAssertFalse(AcpEvent.usage(used: 1, size: 2, costUSD: nil).isWakeEvidence)
        let call = AcpToolCall(id: "1", title: "Run", kind: "execute", status: "completed", input: nil, output: "", paths: [])
        XCTAssertTrue(AcpEvent.toolCallUpdate(call).isWakeEvidence)
        var running = call
        running.status = "in_progress"
        XCTAssertFalse(AcpEvent.toolCallUpdate(running).isWakeEvidence)
    }

    func testRemoteWorktreesAndSnapshots() {
        let machine = RemoteMachine(name: "box", host: "box")
        var config = NewRunConfig()
        config.task = "Fix it"
        config.permission = config.provider.capabilities.policies.first ?? config.permission
        config.remote = RemoteTarget(machine: machine, directory: "~/code/app")
        config.isolation = .worktree
        config.branchName = "nook/fix-it"
        XCTAssertNil(config.problem, "a worktree on another machine starts from the branch there when none is named")
        config.branchName = "bad name"
        XCTAssertEqual(config.problem, .invalidBranchName)
        XCTAssertEqual(RemoteShell.worktreeRoot(home: "/home/me"), "/home/me/.nook/worktrees")

        // Snapshot commands carry their variables (the temporary index) to the other machine.
        let target = RemoteTarget(machine: machine, directory: "/srv/app")
        let line = RemoteLaunch.git(["-C", "/srv/app", "write-tree"], target: target, directory: "/srv/app",
                                    environment: ["GIT_INDEX_FILE": "/tmp/nook-index-1"]).last ?? ""
        XCTAssertTrue(line.contains("GIT_INDEX_FILE=/tmp/nook-index-1"))
        XCTAssertTrue(line.contains("exec git write-tree"))
        let remove = RemoteLaunch.run("rm", ["-f", "--", "a b.txt"], target: target, directory: "/srv/app").last ?? ""
        XCTAssertTrue(remove.contains("exec rm -f -- '\\''a b.txt'\\''") || remove.contains("a b.txt"))
    }

    func testMcpAppDocumentAndPolicy() {
        let html = "<!doctype html><html><body>App</body></html>"
        let contents: [Any] = [
            ["uri": "ui://other", "mimeType": McpApp.mimeType, "text": "<p>no</p>"],
            ["uri": "ui://chart", "mimeType": "text/html; profile=mcp-app", "text": html,
             "_meta": ["ui": ["csp": ["connectDomains": ["https://api.example.com", "javascript:alert(1)"], "resourceDomains": ["https://*.cdn.dev"]],
                              "permissions": ["clipboardWrite": [String: Any](), "camera": true], "prefersBorder": false]]],
        ]
        let document = McpApp.document(contents: contents, uri: "ui://chart")
        XCTAssertEqual(document?.html, html)
        XCTAssertEqual(document?.csp?.connectDomains, ["https://api.example.com"])
        XCTAssertEqual(document?.permissions, ["clipboardWrite"])
        XCTAssertEqual(document?.prefersBorder, false)
        XCTAssertNil(McpApp.document(contents: [["uri": "ui://chart", "mimeType": "text/html", "text": html]], uri: "ui://chart"))

        let policy = McpApp.contentSecurityPolicy(document?.csp)
        XCTAssertTrue(policy.hasPrefix("default-src 'none'; script-src 'unsafe-inline' https://*.cdn.dev"))
        XCTAssertTrue(policy.contains("connect-src https://api.example.com"))
        XCTAssertTrue(policy.contains("frame-src 'none'"))
        let prepared = McpApp.prepared(html, csp: document?.csp)
        XCTAssertTrue(prepared.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(McpApp.prepared("<p>x</p>", csp: nil).hasPrefix("<!doctype html><meta"))
        XCTAssertEqual(McpApp.allowAttribute(["camera", "clipboardWrite"]), "camera; clipboard-write")
        XCTAssertEqual(McpApp.clampHeight(10), 80)
        XCTAssertEqual(McpApp.clampHeight(5000), 2000)
        XCTAssertEqual(McpApp.downloadName(uri: "ui://x/report.csv", name: nil), "report.csv")
        XCTAssertEqual(McpApp.downloadName(uri: nil, name: "../a:b"), "..-a-b")
        XCTAssertTrue(McpApp.callableByApp(meta: nil))
        XCTAssertFalse(McpApp.callableByApp(meta: ["ui": ["visibility": ["model"]]]))
        XCTAssertEqual(McpApp.resourceUri(codexItem: ["mcpAppUi": ["resourceUri": "ui://a"]]), "ui://a")
        XCTAssertEqual(McpApp.resourceUri(meta: ["ui/resourceUri": "ui://b"]), "ui://b")
        XCTAssertEqual(McpApp.modelContext(content: [["type": "text", "text": "Selected: 3 rows"]], structured: nil), .some("Selected: 3 rows"))
        XCTAssertEqual(McpApp.modelContext(content: [], structured: nil), .some(nil))
        XCTAssertNil(McpApp.modelContext(content: [["type": "image"]], structured: nil))
        XCTAssertTrue(McpApp.contextPreamble([(key: "mcp_app_1", text: "hi")]).contains("trust=\"untrusted\""))

        let reference = McpApp.Reference(file: "/tmp/a.html", server: "charts", tool: "plot", resourceUri: "ui://chart")
        let output = McpUI.encode(app: reference, resultText: "Plotted")
        XCTAssertEqual(McpUI.resource(in: output)?.app, reference)
        XCTAssertEqual(McpUI.stripped(output), "Plotted")
    }

    func testMcpAppHostProtocol() {
        var posted: [[String: Any]] = []
        var sent: [String] = []
        var context: String??
        var actions = McpAppHost.Actions(
            post: { posted.append($0) },
            hostContext: { ["theme": "dark", "displayMode": "inline", "availableDisplayModes": ["inline", "fullscreen"]] },
            callTool: { name, _, done in done(.success(["content": [["type": "text", "text": name]], "_meta": NSNull()])) },
            readResource: { _, done in done(.success(["contents": []])) },
            openLink: { _, done in done(.success(())) },
            sendMessage: { text, done in sent.append(text); done(.success(())) },
            updateModelContext: { text, done in context = .some(text); done(.success(())) },
            requestDisplayMode: { mode, done in done(mode) },
            downloadFiles: { _, done in done(.success(())) },
            onSizeChanged: { _, _ in },
            onRequestTeardown: {})
        actions.onSizeChanged = { _, _ in }
        let reference = McpApp.Reference(file: nil, server: "charts", tool: "plot", resourceUri: "ui://chart",
                                         arguments: #"{"x":1}"#, result: #"{"content":[{"type":"text","text":"ok"}],"structuredContent":null}"#)
        let host = McpAppHost(reference: reference, hostVersion: "1.0", actions: actions)

        host.receive(["jsonrpc": "2.0", "id": 1, "method": "ui/initialize", "params": ["protocolVersion": "2026-01-26"]])
        let initialize = posted.last?["result"] as? [String: Any]
        XCTAssertEqual(initialize?["protocolVersion"] as? String, McpApp.protocolVersion)
        XCTAssertEqual((initialize?["hostInfo"] as? [String: Any])?["name"] as? String, "nook")
        XCTAssertNotNil((initialize?["hostCapabilities"] as? [String: Any])?["serverTools"])

        host.receive(["jsonrpc": "2.0", "method": "ui/notifications/initialized"])
        let methods = posted.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["ui/notifications/tool-input", "ui/notifications/tool-result"])
        let toolResult = posted.last?["params"] as? [String: Any]
        XCTAssertNil(toolResult?["structuredContent"], "null fields are dropped")

        host.receive(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "refresh", "arguments": [String: Any]()]])
        XCTAssertNil(((posted.last?["result"] as? [String: Any])?["_meta"]))
        host.receive(["jsonrpc": "2.0", "id": 3, "method": "ui/message", "params": ["role": "user", "content": [["type": "text", "text": "Explain this"]]]])
        XCTAssertEqual(sent, ["Explain this"])
        host.receive(["jsonrpc": "2.0", "id": 4, "method": "ui/open-link", "params": ["url": "file:///etc/passwd"]])
        XCTAssertEqual((posted.last?["error"] as? [String: Any])?["code"] as? Int, -32602)
        host.receive(["jsonrpc": "2.0", "id": 5, "method": "ui/update-model-context", "params": ["content": [["type": "text", "text": "row 3"]]]])
        XCTAssertEqual(context, .some("row 3"))
        host.receive(["jsonrpc": "2.0", "id": 6, "method": "ui/request-display-mode", "params": ["mode": "fullscreen"]])
        XCTAssertEqual((posted.last?["result"] as? [String: Any])?["mode"] as? String, "fullscreen")
        host.receive(["jsonrpc": "2.0", "id": 7, "method": "nope"])
        XCTAssertEqual((posted.last?["error"] as? [String: Any])?["code"] as? Int, -32601)
        host.receive(["jsonrpc": "2.0", "id": 8, "method": "ping", "params": ["pad": String(repeating: "x", count: McpApp.maxMessageBytes)]])
        XCTAssertEqual((posted.last?["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(McpAppHost.downloads([["type": "resource", "resource": ["uri": "ui://r/a.txt", "text": "hi"]]]),
                       [.embedded(name: "a.txt", mimeType: "application/octet-stream", data: Data("hi".utf8))])
        XCTAssertNil(McpAppHost.downloads([["type": "image"]]))
    }

    func testDeviceHubFramesAndCoordinates() {
        let touch = DeviceHub.touchFrame(.begin, x: 1.4, y: 0.25)
        XCTAssertEqual(touch.first, 0x03)
        XCTAssertEqual(String(decoding: touch.dropFirst(), as: UTF8.self), #"{"type":"begin","x":1,"y":0.25}"#)
        XCTAssertEqual(DeviceHub.buttonFrame(.appSwitcher).first, 0x04)
        XCTAssertEqual(String(decoding: DeviceHub.keyFrame(down: true, usage: 4).dropFirst(), as: UTF8.self), #"{"type":"down","usage":4}"#)
        XCTAssertEqual(String(decoding: DeviceHub.orientationFrame(.landscapeLeft).dropFirst(), as: UTF8.self), #"{"orientation":"landscape_left"}"#)

        var config = Data([0x82])
        config.append(Data(#"{"width":1179,"height":2556,"orientation":"landscape_left"}"#.utf8))
        guard case .config(let screen) = DeviceHub.serverMessage(config) else { return XCTFail("config") }
        XCTAssertEqual(screen.orientation, .landscapeLeft)
        XCTAssertEqual(DeviceHub.serverMessage(Data([0x83])), .admitted)
        XCTAssertGreaterThan(screen.aspect, 1)
        let point = DeviceHub.devicePoint(x: 0.2, y: 0.7, config: screen)
        XCTAssertEqual(point.x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.8, accuracy: 0.0001)
        var upside = screen
        upside.orientation = .portraitUpsideDown
        XCTAssertEqual(DeviceHub.devicePoint(x: 0.2, y: 0.7, config: upside).x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(DeviceHub.Orientation.landscapeRight.next, .portrait)

        XCTAssertEqual(DeviceHub.hidUsage[0x00], 0x04, "A")
        XCTAssertEqual(DeviceHub.hidUsage[0x1D], 0x27, "0")
        XCTAssertEqual(DeviceHub.hidUsage[0x24], 0x28, "Return")
        XCTAssertTrue(DeviceHub.forwardsKey(keyCode: 0x0F, command: true), "⌘R reloads")
        XCTAssertFalse(DeviceHub.forwardsKey(keyCode: 0x08, command: true), "⌘C stays with the Mac")
        XCTAssertFalse(DeviceHub.forwardsKey(keyCode: 0x7A, command: false), "F1 is not sent")

        let devices = DeviceHub.devices(Data(#"{"simulators":[{"id":"U1","name":"iPhone 16","version":"18.2","platform":"ios","booted":true,"physical":false}],"emulators":[],"errors":[{"message":"one"},{"message":"two"}]}"#.utf8))
        XCTAssertEqual(devices.devices, [DeviceHub.Device(id: "U1", name: "iPhone 16", version: "18.2", booted: true)])
        XCTAssertEqual(devices.problem, "one\ntwo")
        XCTAssertEqual(DeviceHub.bootFailure("No space left on device"), .diskSpace)
        XCTAssertEqual(DeviceHub.bootFailure("Operation timed out"), .timeout)
        XCTAssertEqual(DeviceHub.restartDelay(previous: 0, upFor: 5), 1)
        XCTAssertEqual(DeviceHub.restartDelay(previous: 16, upFor: 5), 30)
        XCTAssertEqual(DeviceHub.restartDelay(previous: 16, upFor: 120), 1)
        XCTAssertEqual(DeviceHub.hubArguments(entry: "/e.mjs", port: 4000), ["/e.mjs", "--port", "4000", "--host", "127.0.0.1", "--hide-sidebar", "--hide-boot-device"])
        XCTAssertEqual(DeviceHub.mjpegPath(udid: "AB-12"), "/vendor/serve-sim/helper/AB-12/stream.mjpeg")
        XCTAssertEqual(DeviceHub.daemon(Data(#"{"httpPort":5123,"token":"t"}"#.utf8))?.port, 5123)
        XCTAssertTrue(DeviceHub.quickStart(device: "iPhone 16", version: "18.2", command: "/x/agent-device", targetArgs: ["--udid", "U 1"]).contains("'U 1'"))
        XCTAssertTrue(DeviceHub.launcherScript(node: "/n", entry: "/e").contains("Call device_open first"))
        XCTAssertEqual(DeviceHub.stableID("local"), DeviceHub.stableID("local"))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png.append(contentsOf: [0, 0, 4, 0x9B, 0, 0, 9, 0xFC])
        XCTAssertEqual(DeviceHub.pngSize(png)?.width, 1179)
        XCTAssertEqual(DeviceHub.pngSize(png)?.height, 2556)
    }

    func testMjpegParserAndSimulatorActions() {
        var parser = MjpegParser()
        let first = Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 3, 0xFF, 0xD9])
        var stream = Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + first + Data("\r\n--frame\r\n\r\n".utf8) + second
        let split = stream.count - 3
        XCTAssertEqual(parser.feed(stream.prefix(split)), [first])
        XCTAssertEqual(parser.feed(stream.suffix(from: split)), [second])
        stream = Data()
        XCTAssertEqual(parser.feed(Data([0xFF])), [])
        XCTAssertEqual(parser.feed(Data([0xD8, 9, 0xFF, 0xD9])), [Data([0xFF, 0xD8, 9, 0xFF, 0xD9])])

        XCTAssertEqual(SimulatorAction.appearance(dark: true).arguments(udid: "U"), ["ui", "U", "appearance", "dark"])
        XCTAssertEqual(SimulatorAction.textSize(.standard).arguments(udid: "U"), ["ui", "U", "content_size", "large"])
        XCTAssertEqual(SimulatorAction.location(latitude: 52.5, longitude: 4.5).arguments(udid: "U"), ["location", "U", "set", "52.5,4.5"])
        XCTAssertEqual(SimulatorAction.permission(.photos, decision: .grant, bundleID: "com.a").arguments(udid: "U"), ["privacy", "U", "grant", "photos", "com.a"])
        XCTAssertTrue(SimulatorAction.isValidBundleID("com.example.app"))
        XCTAssertFalse(SimulatorAction.isValidBundleID("--help"))
        XCTAssertTrue(SimulatorAction.isValidPushPayload(#"{"aps":{"alert":"hi"}}"#))
        XCTAssertFalse(SimulatorAction.isValidPushPayload(#"{"alert":"hi"}"#))
        let all = Simulators.parseAll(Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-2":[{"udid":"A","name":"iPhone","state":"Shutdown","isAvailable":true},{"udid":"B","name":"iPad","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"W","name":"Watch","state":"Booted"}]}}"#.utf8))
        XCTAssertEqual(all.map(\.udid), ["B", "A"])
    }

    func testAvccDemuxerAndConfiguration() {
        func chunk(_ tag: UInt8, _ payload: [UInt8]) -> Data {
            let length = UInt32(payload.count + 1)
            return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), tag] + payload)
        }
        // avcC: version 1, profile 0x64, compat 0, level 0x1f, 4-byte lengths, one SPS, one PPS.
        let record: [UInt8] = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0, 3, 0x67, 0x64, 0x1F, 1, 0, 2, 0x68, 0xEE]
        let stream = chunk(1, record) + chunk(4, [0xFF, 0xD8]) + chunk(9, [1]) + chunk(2, [0, 0, 0, 1, 0x65]) + chunk(3, [0, 0, 0, 1, 0x41])
        var demuxer = AvccDemuxer()
        let first = demuxer.push(stream.prefix(10))
        let rest = demuxer.push(stream.dropFirst(10))
        let kinds = (first + rest).map(\.kind)
        XCTAssertEqual(kinds, [.description, .seed, .keyframe, .delta], "an unknown tag is skipped")
        XCTAssertEqual((first + rest).first?.payload, Data(record))

        let configuration = AvcConfiguration(Data(record))
        XCTAssertEqual(configuration?.sps, [Data([0x67, 0x64, 0x1F])])
        XCTAssertEqual(configuration?.pps, [Data([0x68, 0xEE])])
        XCTAssertEqual(configuration?.nalLengthSize, 4)
        XCTAssertNil(AvcConfiguration(Data([0, 1, 2, 3, 4, 5, 6])))
        XCTAssertNil(AvcConfiguration(Data([1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 9, 0x67])), "a set longer than the record")
        XCTAssertEqual(AvcConfiguration.codecString(Data(record)), "avc1.64001f")
        XCTAssertEqual(DeviceHub.avccPath(udid: "U-1"), "/vendor/serve-sim/helper/U-1/stream.avcc")
    }
}
