import XCTest

/// How a session's timeline reads in the notch: finished turns fold, tool calls group, and one live line while working.
final class TimelinePresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: RunEvent.Kind, _ text: String, tool: String? = nil, detail: String? = nil,
                       state: RunEvent.State? = nil, at seconds: Double = 0) -> RunEvent {
        RunEvent(kind: kind, text: text, tool: tool, detail: detail, state: state, date: start.addingTimeInterval(seconds))
    }

    private func finishedTurn() -> [RunEvent] {
        [
            event(.user, "Fix de test"),
            event(.thinking, "**Kijken** naar de test"),
            event(.tool, "Bash · npm test", tool: "Bash", state: .done, at: 5),
            event(.tool, "Edit · App.swift", tool: "Edit", detail: #"{"file_path":"/p/App.swift"}"#, state: .done, at: 20),
            event(.tool, "Edit · App.swift", tool: "Edit", detail: #"{"file_path":"/p/App.swift"}"#, state: .done, at: 30),
            event(.assistant, "Opgelost.", state: .done, at: 130),
            event(.result, "2m 13s", state: .done, at: 133)
        ]
    }

    func testFinishedTurnFoldsBetweenQuestionAndAnswer() throws {
        let blocks = TimelinePresentation.blocks(finishedTurn(), active: false)
        XCTAssertEqual(blocks.count, 4)
        guard case .event(let user) = blocks[0], case .fold(_, let seconds, let inner) = blocks[1],
              case .event(let answer) = blocks[2], case .event(let result) = blocks[3] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(user.text, "Fix de test")
        XCTAssertEqual(answer.text, "Opgelost.")
        XCTAssertEqual(result.kind, .result)
        XCTAssertEqual(seconds, 133)
        // Inside: the thinking, then the three tool calls as one group.
        XCTAssertEqual(inner.count, 2)
        guard case .tools(_, let tools, let tally) = inner[1] else { return XCTFail("\(inner)") }
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tally.parts.map(\.category), [.command, .edit])
        XCTAssertEqual(tally.counts[.edit], 1, "edits count files, not calls")
        XCTAssertFalse(tally.failed)
    }

    func testBlockIdsAreUnique() {
        let events = finishedTurn() + finishedTurn() + [event(.user, "Nog iets", at: 300), event(.tool, "Read · x", tool: "Read")]
        let ids = TimelinePresentation.blocks(events, active: true).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "SwiftUI needs every block in a list to have its own id")
    }

    func testRunningOrTroubledTurnsDoNotFold() {
        XCTAssertFalse(TimelinePresentation.blocks(finishedTurn(), active: true).contains { if case .fold = $0 { true } else { false } },
                       "the turn that is still running stays open")
        var failed = finishedTurn()
        failed.insert(event(.error, "Rate limit", at: 60), at: 5)
        XCTAssertFalse(TimelinePresentation.blocks(failed, active: false).contains { if case .fold = $0 { true } else { false } },
                       "a turn with an error stays open")
        let earlier = finishedTurn()
        let blocks = TimelinePresentation.blocks(earlier + [event(.user, "Nog iets", at: 200)], active: true)
        XCTAssertTrue(blocks.contains { if case .fold = $0 { true } else { false } }, "earlier finished turns fold while a new one runs")
    }

    func testGroupsKeepErrorsApartAndNeedTwoTools() {
        let blocks = TimelinePresentation.group([
            event(.tool, "Read · a", tool: "Read"),
            event(.error, "kapot"),
            event(.tool, "Grep · x", tool: "Grep"),
            event(.thinking, "hmm"),
            event(.tool, "run_shell_command · ls", tool: "run_shell_command", state: .failed),
            event(.thinking, "volgende stap")
        ])
        XCTAssertEqual(blocks.count, 6)
        guard case .event(let read) = blocks[0], case .event(let error) = blocks[1], case .event(let grep) = blocks[2],
              case .event(let hmm) = blocks[3], case .event(let shell) = blocks[4], case .event(let thought) = blocks[5]
        else { return XCTFail("\(blocks)") }
        XCTAssertEqual(read.text, "Read · a", "a single tool stands alone")
        XCTAssertEqual(error.kind, .error)
        XCTAssertEqual(grep.kind, .tool)
        XCTAssertEqual(hmm.text, "hmm", "thinking stays readable in the chat, never inside a group")
        XCTAssertEqual(shell.state, .failed)
        XCTAssertEqual(thought.text, "volgende stap")

        let grouped = TimelinePresentation.group([event(.tool, "Grep · x", tool: "Grep"),
                                                  event(.tool, "run_shell_command · ls", tool: "run_shell_command", state: .failed)])
        guard case .tools(_, let tools, let tally)? = grouped.first, grouped.count == 1 else { return XCTFail("\(grouped)") }
        XCTAssertEqual(tools.count, 2)
        XCTAssertTrue(tally.failed)
        XCTAssertEqual(tally.parts.map(\.category), [.command, .search])
    }

    func testLiveActivity() {
        let events = finishedTurn().dropLast(2) + [event(.tool, "Bash · pnpm build", tool: "Bash", state: .running, at: 140)]
        let live = TimelinePresentation.live(Array(events))
        XCTAssertEqual(live.tool, "Bash · pnpm build")
        XCTAssertEqual(live.thought, "Kijken")
    }

    func testOneLinePerCommand() {
        let command = "Bash · cd apps/macos && xcodegen generate"
        let running = finishedTurn().dropLast(2) + [
            event(.tool, command, tool: "Bash", state: .running, at: 140),
            event(.approval, command, tool: "Bash", state: .allowed, at: 141)
        ]
        let shown = TimelinePresentation.visible(Array(running), active: true)
        XCTAssertFalse(shown.contains { $0.text == command }, "the live line shows the running command; the approval is done")
        XCTAssertEqual(TimelinePresentation.live(Array(running)).tool, command)

        var done = Array(running)
        done[done.count - 2].state = .done
        let after = TimelinePresentation.visible(done, active: true)
        XCTAssertEqual(after.filter { $0.text == command }.map(\.kind), [.tool], "once done the command keeps one row")

        let waiting = finishedTurn().dropLast(2) + [
            event(.tool, command, tool: "Bash", state: .running, at: 140),
            event(.approval, command, tool: "Bash", state: .pending, at: 141)
        ]
        XCTAssertEqual(TimelinePresentation.visible(Array(waiting), active: true).filter { $0.text == command }.map(\.kind),
                       [.approval], "a question still open stays in view")
        let denied = finishedTurn().dropLast(2) + [
            event(.tool, command, tool: "Bash", state: .failed, at: 140),
            event(.approval, command, tool: "Bash", state: .denied, at: 141)
        ]
        XCTAssertEqual(TimelinePresentation.visible(Array(denied), active: false).filter { $0.text == command }.count, 2,
                       "a refusal says why the command failed")
    }

    func testHeadlines() {
        XCTAssertEqual(TimelinePresentation.headline("**Plan maken**\nEerst de tests."), "Plan maken")
        XCTAssertEqual(TimelinePresentation.headline("Ik bekijk eerst de tests. Daarna de code."), "Ik bekijk eerst de tests.")
        XCTAssertEqual(TimelinePresentation.headline("kort"), "kort")
    }

    func testCategories() {
        XCTAssertEqual(ToolCategory.of(tool: "mcp__nook__terminal_run"), .command)
        XCTAssertEqual(ToolCategory.of(tool: "mcp__nook__browser_read"), .other)
        XCTAssertEqual(ToolCategory.of(tool: "shell"), .command)
        XCTAssertEqual(ToolCategory.of(tool: "write_file"), .edit)
        XCTAssertEqual(ToolCategory.of(tool: "Glob"), .search)
        XCTAssertEqual(ToolCategory.of(tool: "TodoWrite"), .other)
        let tally = ToolTally([event(.fileChange, "a.swift", detail: "a.swift"), event(.fileChange, "b.swift", detail: "b.swift"),
                               event(.fileChange, "a.swift", detail: "a.swift")])
        XCTAssertEqual(tally.counts[.edit], 2)
    }

    func testEditLinesCountWhatChanged() {
        XCTAssertEqual(EditLines.between("a\nb\nc\n", "a\nB\nc\nd\n"), EditLines(added: 2, removed: 1))
        XCTAssertEqual(EditLines.of(tool: "Write", input: ["content": "one\ntwo\n"]), EditLines(added: 2, removed: 0))
        XCTAssertEqual(EditLines.of(tool: "MultiEdit", input: ["edits": [["old_string": "x", "new_string": "y"],
                                                                         ["old_string": "", "new_string": "z"]]]),
                       EditLines(added: 2, removed: 1))
        XCTAssertEqual(EditLines.of(patch: "*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n+more\n keep\n*** End Patch"),
                       EditLines(added: 2, removed: 1))
        XCTAssertEqual(EditLines.of(patch: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"), EditLines(added: 1, removed: 1),
                       "file headers are not lines")
        XCTAssertNil(EditLines.of(tool: "Edit", input: ["old_string": "same", "new_string": "same"]))
        XCTAssertNil(EditLines.of(tool: "Read", input: ["file_path": "a.swift"]))
    }

    func testTallySumsTheLinesOfItsEdits() {
        let tally = ToolTally([
            event(.tool, "Edit · a.swift", tool: "Edit",
                  detail: #"{"file_path":"/p/a.swift","old_string":"a\nb","new_string":"a\nc\nd"}"#, state: .done),
            event(.tool, "Write · b.swift", tool: "Write", detail: #"{"file_path":"/p/b.swift","content":"x\ny\nz"}"#, state: .done),
            event(.tool, "Edit · c.swift", tool: "Edit",
                  detail: #"{"file_path":"/p/c.swift","old_string":"q","new_string":"r"}"#, state: .failed),
            event(.tool, "Bash · ls", tool: "Bash", detail: #"{"command":"ls"}"#, state: .done)
        ])
        XCTAssertEqual(tally.lines, EditLines(added: 5, removed: 1), "a failed edit changed nothing")
        XCTAssertNil(ToolTally([event(.tool, "Bash · ls", tool: "Bash", state: .done)]).lines)
    }
}
