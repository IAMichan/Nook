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

    /// Built from the turns of the last layout, the blocks are the same as built from scratch, at every step of a session
    /// that streams, runs tools that need approval, finishes and starts a next turn.
    func testCachedBlocksMatchFreshOnesWhileASessionGoesOn() {
        var events: [RunEvent] = []
        var cache = TimelineBlockCache()
        func check(active: Bool, _ step: String) {
            XCTAssertEqual(TimelinePresentation.blocks(events, active: active, cache: &cache),
                           TimelinePresentation.blocks(events, active: active), step)
        }
        events = finishedTurn()
        check(active: false, "a finished turn")
        events.append(event(.user, "Nog iets", at: 200))
        check(active: true, "a new message")
        events.append(event(.approval, "Bash · swift build", tool: "Bash", state: .pending, at: 201))
        check(active: true, "an approval asked")
        events[events.count - 1].state = .allowed
        events.append(event(.tool, "Bash · swift build", tool: "Bash", state: .running, at: 202))
        check(active: true, "the approved call runs")
        events[events.count - 1].state = .done
        events.append(event(.tool, "Edit · App.swift", tool: "Edit", detail: #"{"file_path":"/p/App.swift"}"#, state: .done, at: 210))
        check(active: true, "the group grows")
        events.append(event(.assistant, "Klaar", at: 220))
        check(active: true, "the answer starts")
        events[events.count - 1].text += " met de build."
        check(active: true, "the answer streams")
        events.append(event(.result, "20s", state: .done, at: 222))
        check(active: false, "the turn is done")
        XCTAssertEqual(cache.turns.count, 2)
    }

    func testFinishedTurnFoldsBetweenQuestionAndAnswer() throws {
        let blocks = TimelinePresentation.blocks(finishedTurn() + [event(.user, "Nog iets", at: 200)], active: false)
        XCTAssertEqual(blocks.count, 5)
        guard case .event(let user) = blocks[0], case .fold(_, let seconds, let inner, let checks) = blocks[1],
              case .event(let answer) = blocks[2], case .event(let result) = blocks[3] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(user.text, "Fix de test")
        XCTAssertEqual(answer.text, "Opgelost.")
        XCTAssertEqual(result.kind, .result)
        XCTAssertEqual(seconds, 133)
        // The tests it ran stay on the fold's line, worked out with the blocks rather than on every redraw.
        XCTAssertEqual(checks.map(\.kind), [.tests])
        XCTAssertEqual(checks.first?.outcome, .passed)
        // Inside: the thinking, then the three tool calls as one group.
        XCTAssertEqual(inner.count, 2)
        guard case .tools(_, let tools, let tally) = inner[1] else { return XCTFail("\(inner)") }
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tally.parts.map(\.category), [.command, .edit])
        XCTAssertEqual(tally.counts[.edit], 1, "edits count files, not calls")
        XCTAssertFalse(tally.failed)
    }

    /// Files the agent handed you (SendUserFile) stay in sight next to the answer instead of folding into the work.
    /// News about a watched pull request after a finished turn starts a turn of its own: the answer to your message stays
    /// in sight next to the reply to the news, instead of folding under the work of one long turn.
    func testPullRequestNewsAfterAFinishedTurnStartsATurnOfItsOwn() throws {
        let news = event(.system, "Nieuws over de pull request:\nCodeRabbit commented", tool: "prwatch", at: 300)
        let events = finishedTurn() + [
            news,
            event(.tool, "Bash · gh pr view", tool: "Bash", state: .done, at: 305),
            event(.tool, "Bash · gh pr checks", tool: "Bash", state: .done, at: 310),
            event(.assistant, "Er hoeft niets aangepast te worden.", state: .done, at: 320),
            event(.result, "20s", state: .done, at: 321)
        ]
        XCTAssertEqual(TimelinePresentation.split(events).count, 2)
        XCTAssertEqual(TimelinePresentation.lastTurn(events).first?.id, news.id)
        let shown = TimelinePresentation.blocks(events, active: false).compactMap { block -> String? in
            if case .event(let event) = block, event.kind == .assistant { return event.text }
            return nil
        }
        XCTAssertEqual(shown, ["Opgelost.", "Er hoeft niets aangepast te worden."])

        // News that comes while the turn still runs stays in it.
        let running = Array(finishedTurn().dropLast(2)) + [news]
        XCTAssertEqual(TimelinePresentation.split(running).count, 1)
    }

    func testSharedFilesStayOutOfTheFold() throws {
        var turn = finishedTurn()
        let shared = event(.tool, "SendUserFile", tool: "SendUserFile",
                           detail: #"{"files":[".scratch/reel/reel.mp4",".scratch/reel/cover.jpg"],"caption":"The reel"}"#,
                           state: .done, at: 100)
        turn.insert(shared, at: 5)
        let blocks = TimelinePresentation.blocks(turn + [event(.user, "Nog iets", at: 200)], active: false)
        guard case .fold(_, _, let inner, _) = blocks[1], case .event(let files) = blocks[2], case .event(let answer) = blocks[3] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(files.id, shared.id)
        XCTAssertEqual(answer.text, "Opgelost.")
        XCTAssertFalse(TimelinePresentation.events(inner).contains { $0.id == shared.id })
        // In an open turn they are a row of their own, never counted away in a group of tool calls.
        let open = TimelinePresentation.group(Array(turn[1...5]))
        XCTAssertTrue(open.contains(.event(shared)))
        // The outputs panel keeps them, the video as a video.
        let outputs = SessionOutputs.collect([shared], tasks: nil, directory: "/p")
        XCTAssertEqual(outputs.map(\.path), ["/p/.scratch/reel/reel.mp4", "/p/.scratch/reel/cover.jpg"])
        XCTAssertEqual(outputs.first?.kind, .video)
        XCTAssertEqual(SharedFiles.caption(AgentActivity.input(shared.detail) ?? [:]), "The reel")
    }

    /// A page the agent showed (render_page) stays in sight next to the answer too.
    func testPagesStayOutOfTheFold() {
        var turn = finishedTurn()
        let page = RenderedPage.event(title: "Chart", file: "/x/pages/r/p.html", height: 300)
        turn.insert(page, at: 4)
        let blocks = TimelinePresentation.blocks(turn + [event(.user, "Nog iets", at: 200)], active: false)
        guard case .fold(_, _, let inner, _) = blocks[1], case .event(let shown) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(shown.id, page.id)
        XCTAssertFalse(TimelinePresentation.events(inner).contains { $0.id == page.id })
        XCTAssertTrue(TimelinePresentation.group(Array(turn[1...5])).contains(.event(page)), "never counted away in a group")
    }

    func testFailedOrEmptySharesAreOrdinarySteps() {
        let failed = event(.tool, "SendUserFile", tool: "SendUserFile", detail: #"{"files":["a.mp4"]}"#, state: .failed)
        let empty = event(.tool, "SendUserFile", tool: "SendUserFile", detail: #"{"files":[]}"#, state: .done)
        XCTAssertFalse(SharedFiles.isShare(failed))
        XCTAssertFalse(SharedFiles.isShare(empty))
        XCTAssertTrue(SharedFiles.isTool("mcp__files__SendUserFile"))
    }

    func testLastTurnFoldsOnceFinished() {
        let blocks = TimelinePresentation.blocks(finishedTurn(), active: false)
        XCTAssertTrue(blocks.contains { if case .fold = $0 { true } else { false } },
                      "a finished turn reads as 'Worked for …' over its answer")
        XCTAssertEqual(TimelinePresentation.events(blocks).map(\.text), finishedTurn().map(\.text), "folding hides nothing")
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
        XCTAssertFalse(TimelinePresentation.blocks(failed + [event(.user, "Nog iets", at: 200)], active: false).contains { if case .fold = $0 { true } else { false } },
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
        XCTAssertEqual(blocks.count, 4)
        guard case .event(let read) = blocks[0], case .event(let error) = blocks[1], case .tools(_, let inside, _) = blocks[2],
              case .event(let thought) = blocks[3]
        else { return XCTFail("\(blocks)") }
        XCTAssertEqual(read.text, "Read · a", "a single tool stands alone")
        XCTAssertEqual(error.kind, .error)
        XCTAssertEqual(inside.map(\.text), ["Grep · x", "hmm", "run_shell_command · ls"],
                       "thinking between tool calls opens with their group")
        XCTAssertEqual(thought.text, "volgende stap", "thinking after the last call stays readable")

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

    /// A subagent in the background keeps its row while the agent runs commands next to it: hiding it whenever nothing
    /// else ran made the row come and go with every command, and the timeline jump up and down.
    func testBackgroundWorkKeepsItsRowAndStaysOutOfTheLiveLine() {
        let launch = event(.tool, "Agent · Audit", tool: "Agent",
                           detail: #"{"description":"Audit","prompt":"Look","run_in_background":true}"#, state: .running, at: 140)
        let server = event(.tool, "Bash · npm run dev", tool: "Bash",
                           detail: #"{"command":"npm run dev","run_in_background":true}"#, state: .running, at: 141)
        var events = Array(finishedTurn().dropLast(2)) + [launch, server]
        func rows() -> [String] { TimelinePresentation.visible(events, active: true).map(\.text) }
        XCTAssertTrue(rows().contains(launch.text), "nothing else runs")
        XCTAssertTrue(rows().contains(server.text))
        XCTAssertNotEqual(TimelinePresentation.live(events).tool, launch.text)
        XCTAssertNotEqual(AgentActivity.current(events), AgentActivity.of(launch))

        events.append(event(.tool, "Bash · ls", tool: "Bash", state: .running, at: 150))
        XCTAssertTrue(rows().contains(launch.text), "a command runs")
        XCTAssertFalse(rows().contains("Bash · ls"), "the command that runs is the live line")
        XCTAssertEqual(TimelinePresentation.live(events).tool, "Bash · ls")
        events[events.count - 1].state = .done
        XCTAssertTrue(rows().contains(launch.text), "the command is done")

        // A subagent the turn waits on keeps its row too: its own steps run next to it.
        var foreground = launch
        foreground.detail = #"{"description":"Audit","prompt":"Look"}"#
        let waiting = Array(finishedTurn().dropLast(2)) + [foreground]
        XCTAssertTrue(TimelinePresentation.visible(waiting, active: true).contains { $0.id == foreground.id })
        XCTAssertEqual(TimelinePresentation.live(waiting).tool, foreground.text)
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
        XCTAssertEqual(TimelinePresentation.visible(Array(denied), active: false).count(where: { $0.text == command }), 2,
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

    func testBackgroundNoticesJoinTheCommands() {
        let notice = "task-148 has been launched in the background. I will wait for it to complete before proceeding."
        XCTAssertEqual(BackgroundWork.notice(notice), ["task-148"])
        XCTAssertEqual(BackgroundWork.notice("task-1 has been launched in the background.task-2 has been launched in the background."),
                       ["task-1", "task-2"])
        XCTAssertEqual(BackgroundWork.notice("task-1 has been launched in the background. Then I fixed the bug."), [],
                       "a message that says more is an answer")
        XCTAssertEqual(BackgroundWork.notice("Opgelost."), [])

        let events = [
            event(.user, "Fix CI"),
            event(.tool, "rg build", tool: "shell", state: .done, at: 1),
            event(.tool, "git status", tool: "shell", state: .done, at: 2),
            event(.assistant, notice, state: .done, at: 3),
            event(.tool, "rg test", tool: "shell", state: .done, at: 4),
            event(.tool, "git diff", tool: "shell", state: .done, at: 5)
        ]
        let blocks = TimelinePresentation.blocks(events, active: true)
        XCTAssertEqual(blocks.count, 2, "one group of commands with the notice inside, not two around a message")
        guard case .tools(_, let grouped, let tally) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(grouped.count, 5)
        XCTAssertEqual(tally.counts[.command], 4)

        let finished = events + [event(.assistant, "Klaar.", state: .done, at: 6), event(.result, "6s", state: .done, at: 7)]
        let folded = TimelinePresentation.blocks(finished + [event(.user, "Nog iets", at: 9)], active: false)
        guard case .event(let answer) = folded[2] else { return XCTFail("\(folded)") }
        XCTAssertEqual(answer.text, "Klaar.", "a notice is never the answer of a turn")
    }

    /// A tool call of a session Nook runs reads as a step of an agent's own transcript: the same tool, what it was about,
    /// its command and file, and why it failed.
    func testToolEventsBecomeTranscriptSteps() {
        let command = AgentToolStep(event: event(.tool, "Bash · npm test", tool: "Bash", detail: #"{"command":"npm test"}"#,
                                                 state: .done))
        XCTAssertEqual(command.name, "Bash")
        XCTAssertEqual(command.summary, "npm test")
        XCTAssertEqual(command.command, "npm test")
        XCTAssertEqual(command.state, .done)

        let edit = AgentToolStep(event: event(.tool, "↳ Edit · Login.swift", tool: "Edit",
                                              detail: #"{"file_path":"/repo/Login.swift"}"#, state: .running))
        XCTAssertEqual(edit.summary, "Login.swift", "a nested call loses its arrow")
        XCTAssertEqual(edit.file, "/repo/Login.swift")
        XCTAssertEqual(edit.state, .running)

        var failing = event(.tool, "Bash · make", tool: "Bash", detail: #"{"command":"make"}"#, state: .failed)
        failing.output = "make: *** No rule to make target\nmore"
        let failed = AgentToolStep(event: failing)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "make: *** No rule to make target")

        XCTAssertEqual(AgentToolStep(event: event(.tool, "TodoWrite", tool: "TodoWrite")).summary, "",
                       "a title that is only the tool's name says nothing more")
    }

    func testASteerFoldsTheWorkBeforeItAsASupersededAttempt() {
        let prompt = RunEvent(kind: .user, text: "Fix de build")
        let work = [RunEvent(kind: .tool, text: "Bash · swift build", tool: "Bash", state: .done),
                    RunEvent(kind: .assistant, text: "Ik kijk naar de fout")]
        var steer = RunEvent(kind: .user, text: "Maak er een PR voor")
        steer.steer = .steer
        let after = RunEvent(kind: .tool, text: "Bash · gh pr create", tool: "Bash", state: .running)
        let blocks = TimelinePresentation.blocks([prompt] + work + [steer, after], active: true)
        guard blocks.count >= 3, case .event(let first) = blocks[0], case .superseded(let id, let inner) = blocks[1],
              case .event(let steered) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(first.id, prompt.id)
        XCTAssertEqual(id, work[0].id)
        XCTAssertEqual(TimelinePresentation.events(inner).map(\.id), work.map(\.id))
        XCTAssertEqual(steered.steer, .steer)
        // A message sent after the turn ended is a turn of its own: nothing is superseded.
        let plain = TimelinePresentation.blocks([prompt] + work + [RunEvent(kind: .result, text: ""), RunEvent(kind: .user, text: "Dank")],
                                                active: false)
        XCTAssertFalse(plain.contains { if case .superseded = $0 { return true } else { return false } })
    }

    func testASupersededTurnIsMadeAgainOnceASteerFollowsIt() {
        var cache = TimelineBlockCache()
        let prompt = RunEvent(kind: .user, text: "Fix")
        let tool = RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash", state: .done)
        _ = TimelinePresentation.blocks([prompt, tool], active: true, cache: &cache)
        var steer = RunEvent(kind: .user, text: "Stop, doe iets anders")
        steer.steer = .promoted
        let blocks = TimelinePresentation.blocks([prompt, tool, steer], active: true, cache: &cache)
        XCTAssertTrue(blocks.contains { if case .superseded = $0 { return true } else { return false } })
    }

    func testModelSwitchSaysWhatChanged() {
        let sonnet = ModelSwitch.Endpoint(provider: "claude", agent: "Claude Code", model: "Sonnet 5.5", effort: "high")
        var opus = sonnet
        opus.model = "Opus 5.5"
        XCTAssertFalse(ModelSwitch(from: sonnet, to: opus).handoff)
        XCTAssertTrue(ModelSwitch(from: sonnet, to: opus).modelChanged)
        XCTAssertFalse(ModelSwitch(from: sonnet, to: opus).effortChanged)
        XCTAssertTrue(ModelSwitch(from: sonnet, to: sonnet).isNoChange)
        let codex = ModelSwitch.Endpoint(provider: "codex", agent: "Codex", model: "GPT-5", effort: nil)
        XCTAssertTrue(ModelSwitch(from: sonnet, to: codex).handoff)
        XCTAssertFalse(ModelSwitch(from: sonnet, to: codex).isNoChange)
        // Stored events keep their marks.
        var event = RunEvent(kind: .system, text: "x", tool: "switch")
        event.change = ModelSwitch(from: sonnet, to: codex)
        event.steer = .promoted
        let decoded = try? JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
        let old = try? JSONDecoder().decode(RunEvent.self, from: Data(#"{"id":"\#(UUID().uuidString)","date":0,"kind":"user","text":"hi"}"#.utf8))
        XCTAssertNil(old?.steer, "an event stored before these marks reads without them")
    }

    func testAccountSwitchNamesBothAccounts() {
        let work = ModelSwitch.Endpoint(provider: "claude", agent: "Claude Code", model: "Sonnet 5.5", effort: nil,
                                        profile: "claude-work", account: "Work")
        var personal = work
        personal.profile = "claude"
        personal.account = "Personal"
        // Same model, other account: still a switch worth marking, but no handoff while they share a conversation.
        let shared = ModelSwitch(from: work, to: personal)
        XCTAssertTrue(shared.accountChanged)
        XCTAssertFalse(shared.handoff)
        XCTAssertFalse(shared.isNoChange)
        XCTAssertEqual(ModelSwitchText.plain(shared), "Claude Code (Work) Sonnet 5.5 → Claude Code (Personal) Sonnet 5.5")
        var own = shared
        own.accountHandoff = true
        XCTAssertTrue(own.handoff, "an account with a conversation of its own gets the context handed over")
        // A switch saved before accounts were noted reads as before.
        let legacy = try? JSONDecoder().decode(ModelSwitch.self, from: Data(
            #"{"from":{"provider":"claude","agent":"Claude Code","model":"Sonnet 5.5"},"to":{"provider":"claude","agent":"Claude Code","model":"Opus 5.5"}}"#.utf8))
        XCTAssertNotNil(legacy)
        XCTAssertEqual(legacy?.accountChanged, false)
        XCTAssertEqual(legacy?.handoff, false)
    }
}
