import XCTest

final class SpawnedSessionsTests: XCTestCase {
    func testTaskKeysComeFromSpawnTaskCalls() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Done."],
            ["type": "tool_use", "name": "mcp__ccd_session__spawn_task", "input": ["title": "Link Telegram", "prompt": "Link  Telegram\nthrough the helper."]],
            ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
        ]
        XCTAssertEqual(SpawnedSessions.taskKeys(in: content), ["Link Telegram through the helper."])
    }

    func testChildFindsTheSessionThatSpawnedIt() {
        let parents = SpawnedSessions.parents(
            firstPrompts: ["parent": "Make chats work", "child": "Link Telegram through the helper.", "other": "Fix the build"],
            tasks: ["parent": ["Link Telegram through the helper."]])
        XCTAssertEqual(parents, ["child": "parent"])
    }

    func testAPromptTheAppAddedToStillMatches() {
        let parents = SpawnedSessions.parents(
            firstPrompts: ["child": "Context from the earlier session. Link Telegram through the helper."],
            tasks: ["parent": ["Link Telegram through the helper."]])
        XCTAssertEqual(parents["child"], "parent")
    }

    // MARK: Launched from a shell

    func testOnlyCommandsThatRunAnAgentAreKept() {
        XCTAssertNotNil(LaunchedSessions.launch(#"claude -p "Fix the login page please""#))
        XCTAssertNotNil(LaunchedSessions.launch("cd x && /opt/homebrew/bin/codex exec 'Fix the login page please'"))
        XCTAssertNotNil(LaunchedSessions.launch("printf '%s' '{}' | timeout 60 claude -p --input-format stream-json"))
        XCTAssertNil(LaunchedSessions.launch("ls ~/.claude/projects"))
        XCTAssertNil(LaunchedSessions.launch("grep -rn claude-code apps"))
        XCTAssertNil(LaunchedSessions.launch("swift test"))
    }

    func testRecordKeepsEachCommandOnceAndOnlyTheLatest() {
        var commands: [String] = []
        LaunchedSessions.record("claude -p one", into: &commands)
        LaunchedSessions.record("claude  -p one", into: &commands)
        LaunchedSessions.record("ls", into: &commands)
        XCTAssertEqual(commands, ["claude -p one"])
        for index in 0..<30 { LaunchedSessions.record("claude -p task \(index)", into: &commands) }
        XCTAssertEqual(commands.count, LaunchedSessions.maxCommands)
        XCTAssertEqual(commands.last, "claude -p task 29")
    }

    func testAPromptIsMatchedUpToItsFirstQuote() {
        XCTAssertEqual(LaunchedSessions.key("Show a python  function add(a,b).\nDo not write files."),
                       "Show a python function add(a,b). Do not write files.")
        XCTAssertEqual(LaunchedSessions.key("Explain the build failure in 'main' please"), "Explain the build failure in")
        XCTAssertNil(LaunchedSessions.key("fix it"))
    }

    /// The case that showed up as a chat nobody started: an agent testing prompt suggestions piped stream-json into
    /// `claude -p` from its shell.
    func testAShellLaunchedSessionFindsItsParent() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let command = #"( printf '%s\n' '{"type":"user","message":{"role":"user","content":"Show a python function add(a,b). Do not write files."}}'; sleep 15 ) | timeout 60 claude -p --input-format stream-json --model haiku"#
        var commands: [String] = []
        LaunchedSessions.record(command, into: &commands)
        let parents = LaunchedSessions.parents(
            children: [
                .init(id: "child", prompt: "Show a python function add(a,b). Do not write files.", started: start.addingTimeInterval(65)),
                .init(id: "unrelated", prompt: "Show the release notes for this week", started: start.addingTimeInterval(70)),
            ],
            launchers: [
                .init(id: "parent", commands: commands, started: start, ended: start.addingTimeInterval(300)),
                .init(id: "quiet", commands: [], started: start, ended: start.addingTimeInterval(300)),
            ])
        XCTAssertEqual(parents, ["child": "parent"])
    }

    func testAParentMustRunWhenTheChildStarts() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let launcher = LaunchedSessions.Launcher(id: "parent", commands: [#"claude -p "Summarize the open pull requests""#],
                                                 started: start, ended: start.addingTimeInterval(600))
        let late = LaunchedSessions.Child(id: "late", prompt: "Summarize the open pull requests", started: start.addingTimeInterval(3_600))
        let during = LaunchedSessions.Child(id: "during", prompt: "Summarize the open pull requests", started: start.addingTimeInterval(30))
        XCTAssertEqual(LaunchedSessions.parents(children: [late, during], launchers: [launcher]), ["during": "parent"])
    }

    func testASessionIsNotItsOwnParent() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let parents = LaunchedSessions.parents(
            children: [.init(id: "same", prompt: "Summarize the open pull requests", started: start)],
            launchers: [.init(id: "same", commands: [#"claude -p "Summarize the open pull requests""#], started: start, ended: start)])
        XCTAssertTrue(parents.isEmpty)
    }

    func testTheLatestParentWins() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let command = #"claude -p "Summarize the open pull requests""#
        let parents = LaunchedSessions.parents(
            children: [.init(id: "child", prompt: "Summarize the open pull requests", started: start.addingTimeInterval(100))],
            launchers: [
                .init(id: "older", commands: [command], started: start, ended: start.addingTimeInterval(200)),
                .init(id: "newer", commands: [command], started: start.addingTimeInterval(50), ended: start.addingTimeInterval(200)),
            ])
        XCTAssertEqual(parents["child"], "newer")
    }

    func testCodexToolCallsGiveTheirCommand() {
        XCTAssertEqual(LaunchedSessions.codexCommand(["arguments": #"{"cmd":"codex exec 'hi there'","workdir":"/x"}"#]),
                       "codex exec 'hi there'")
        XCTAssertEqual(LaunchedSessions.codexCommand(["arguments": #"{"command":["bash","-lc","claude -p hi"]}"#]),
                       "bash -lc claude -p hi")
    }
}
