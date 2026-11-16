import XCTest

/// One table of every agent's tool names (`CanonicalTool`), and the helpers every view reads a call through
/// (`ToolInput`, `EditPatch.change`, `SessionProjects.changedFiles`).
final class CanonicalToolTests: XCTestCase {
    func testEveryAgentsShellIsACommand() {
        for tool in ["Bash", "shell", "exec_command", "shell_command", "container.exec", "run_shell_command", "powershell",
                     "run_command", "run_in_terminal", "run_terminal_cmd", "SHELL", "local_shell_call"] {
            XCTAssertEqual(CanonicalTool.kind(tool), .shell, tool)
            XCTAssertEqual(ToolCategory.of(tool: tool), .command, tool)
        }
        XCTAssertEqual(CanonicalTool.of("Bash").name, "Bash", "Claude Code's own tool keeps its name")
        XCTAssertEqual(CanonicalTool.of("exec_command").name, "Shell")
        XCTAssertEqual(CanonicalTool.of("run_shell_command").name, "Shell")
    }

    func testEditsWritesAndPatchesChangeFiles() {
        for tool in ["Edit", "edit", "MultiEdit", "replace", "str_replace", "str_replace_editor", "NotebookEdit"] {
            XCTAssertEqual(CanonicalTool.kind(tool), .edit, tool)
        }
        for tool in ["Write", "write_file", "create", "WRITE"] { XCTAssertEqual(CanonicalTool.kind(tool), .write, tool) }
        XCTAssertEqual(CanonicalTool.kind("delete_file"), .delete)
        XCTAssertEqual(CanonicalTool.kind("apply_patch"), .patch)
        for tool in ["edit", "create", "delete_file", "apply_patch"] {
            XCTAssertTrue(CanonicalTool.of(tool).changesFiles, tool)
            XCTAssertEqual(ToolCategory.of(tool: tool), .edit, tool)
        }
    }

    func testReadsListsAndSearches() {
        XCTAssertEqual(ToolCategory.of(tool: "list"), .read, "OpenCode's list")
        XCTAssertEqual(CanonicalTool.kind("list_directory"), .list)
        XCTAssertEqual(CanonicalTool.of("read_file").name, "Read")
        XCTAssertEqual(CanonicalTool.of("search_file_content").name, "Grep")
        XCTAssertEqual(CanonicalTool.of("google_web_search").name, "WebSearch")
        XCTAssertEqual(CanonicalTool.of("web_fetch").kind, .webFetch)
        XCTAssertEqual(CanonicalTool.of("view_image").name, "view_image", "Codex's picture step keeps its name")
    }

    func testSubagentsOfEveryAgent() {
        for tool in ["Task", "Agent", "task"] { XCTAssertTrue(Subagents.isTool(tool), tool) }
        XCTAssertFalse(Subagents.isTool("TodoWrite"))
        XCTAssertEqual(CanonicalTool.subagentName, "Agent")
    }

    func testUnknownToolsKeepTheirName() {
        XCTAssertEqual(CanonicalTool.of("mcp__github__create_issue").name, "mcp__github__create_issue")
        XCTAssertEqual(CanonicalTool.of("mcp__github__create_issue").kind, .other)
        XCTAssertEqual(CanonicalTool.of("").name, "Tool")
    }

    func testApprovalTitlesReadEverySpelling() {
        // An ACP agent's lowercase "edit" asks as an edit, as Claude Code's Edit does.
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "EDIT", input: [:]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "delete_file", input: [:]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "exec_command", input: ["command": "rm -rf build"]))
        XCTAssertFalse(PreToolGate.wouldAsk(tool: "read_file", input: ["path": "a.txt"]))
    }

    // MARK: Input

    func testOneCommandAndPathReader() {
        XCTAssertEqual(ToolInput.command(["command": ["bash", "-lc", "npm test"]]), "npm test")
        XCTAssertEqual(ToolInput.command(["cmd": "ls -la"]), "ls -la")
        XCTAssertEqual(ToolInput.path(["target_file": "/a/b.swift"]), "/a/b.swift")
        XCTAssertEqual(ToolInput.path(["filePath": "/a/c.swift"]), "/a/c.swift")
        XCTAssertEqual(ToolSummary.path(["file_path": "/x", "path": "/y"]), "/x")
    }

    func testOneSubjectForEveryView() {
        XCTAssertEqual(ToolInput.subject(tool: "Bash", input: ["command": "npm test", "description": "Run the tests"]), "npm test")
        XCTAssertEqual(ToolInput.subject(tool: "Bash", input: ["command": "npm test", "description": "Run the tests"],
                                         describedCommand: true), "Run the tests")
        XCTAssertEqual(ToolInput.subject(tool: "read_many_files", input: ["paths": ["a.md", "b.md"]]), "a.md +1")
        XCTAssertEqual(ToolInput.subject(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: src/a.swift\n@@\n-x\n+y\n*** End Patch"]),
                       "a.swift")
        XCTAssertEqual(ToolInput.subject(tool: "task", input: ["description": "Review", "prompt": "Review the diff"]), "Review")
        // A transcript's step and the timeline's line say the same.
        XCTAssertEqual(AgentTranscript.stepSummary("grep", ["pattern": "TODO"]), "TODO")
        XCTAssertEqual(ToolSummary.describe(tool: "grep", input: ["pattern": "TODO"]), "grep · TODO")
    }

    // MARK: File changes

    func testFileChangesOfEveryAgent() {
        XCTAssertEqual(ToolSummary.fileChanges(tool: "edit", input: ["file_path": "/a.swift"]).map(\.kind), ["modified"])
        XCTAssertEqual(ToolSummary.fileChanges(tool: "create", input: ["path": "/b.swift", "file_text": "x"]).map(\.kind), ["written"])
        XCTAssertEqual(ToolSummary.fileChanges(tool: "str_replace", input: ["path": "/c.swift", "old_str": "a", "new_str": "b"]).map(\.path),
                       ["/c.swift"])
        XCTAssertEqual(ToolSummary.fileChanges(tool: "delete_file", input: ["path": "/d.swift"]).map(\.kind), ["deleted"])
        let patch = "*** Begin Patch\n*** Add File: new.txt\n+hi\n*** Update File: old.txt\n@@\n-a\n+b\n*** Delete File: gone.txt\n*** End Patch"
        let changes = ToolSummary.fileChanges(tool: "apply_patch", input: ["input": patch])
        XCTAssertEqual(changes.map(\.path), ["new.txt", "old.txt", "gone.txt"])
        XCTAssertEqual(changes.map(\.kind), ["written", "modified", "deleted"])
        XCTAssertEqual(SessionProjects.absolute("old.txt", cwd: "/repo"), "/repo/old.txt")
    }

    func testEditLinesAndPatchForStrReplaceAndCreate() {
        XCTAssertEqual(EditLines.of(tool: "str_replace", input: ["old_str": "a\nb", "new_str": "a\nc"]), EditLines(added: 1, removed: 1))
        XCTAssertEqual(EditLines.of(tool: "create", input: ["file_text": "1\n2\n3\n"]), EditLines(added: 3, removed: 0))
        XCTAssertEqual(EditLines.of(tool: "EDIT", input: ["old_string": "x", "new_string": "y"]), EditLines(added: 1, removed: 1))
        XCTAssertNotNil(EditPatch.make(tool: "str_replace", input: ["old_str": "a", "new_str": "b"]))
        XCTAssertNil(EditPatch.make(tool: "read", input: ["path": "a"]))
    }

    func testApprovalDiffOfACodexPatch() throws {
        let patch = "*** Begin Patch\n*** Update File: a.txt\n@@\n keep\n-old\n+new\n+more\n*** End Patch"
        let ops = try XCTUnwrap(EditPatch.lineOps(tool: "apply_patch", input: ["input": patch]))
        XCTAssertEqual(ops, [.same("keep"), .remove("old"), .add("new"), .add("more")])
        XCTAssertEqual(LineDiff.counts(ops).added, 2)
        XCTAssertNotNil(EditPatch.lineOps(tool: "Edit", input: ["old_string": "a", "new_string": "b"]))
        XCTAssertNil(EditPatch.lineOps(tool: "Bash", input: ["command": "ls"]))
    }

    // MARK: OpenCode

    func testOpenCodeTaskIsASubagent() {
        // OpenCode's task tool takes Claude Code's Task input: description, prompt, subagent_type.
        XCTAssertEqual(OpenCodeTools.name("task"), "Task")
        let event = RunEvent(kind: .tool, text: "task · Review", tool: OpenCodeTools.name("task"),
                             detail: #"{"description":"Review","prompt":"Review the diff","subagent_type":"general"}"#)
        XCTAssertTrue(Subagents.isLaunch(event))
        XCTAssertEqual(OpenCodeTools.name("list"), "LS")
        XCTAssertEqual(OpenCodeTools.name("todowrite"), "TodoWrite")
    }

    // MARK: Text

    func testTitlesCutAtAWord() {
        XCTAssertEqual(TextClip.title("Fix the login bug in the settings page", 20), "Fix the login bug in…")
        XCTAssertEqual(TextClip.title("Short", 20), "Short")
        XCTAssertEqual(TextClip.title("Supercalifragilisticexpialidocious", 10), "Supercalif…")
        XCTAssertEqual(TextClip.title("Fix this, then\nthat", 12), "Fix this…")
        XCTAssertEqual(TextClip.firstLine("one\ntwo", 160), "one")
        XCTAssertEqual(TextClip.parts([["text": "a"], ["text": "b"]]), "a\nb")
        XCTAssertEqual(TextClip.blocks([["type": "text", "text": "a"], ["type": "image"]]), "a")
    }
}
