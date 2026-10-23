import XCTest

/// How an agent's own transcript reads, as a thread: finished turns fold to "Worked for …", steps in a row
/// become one line, and the turn that runs shows how long it has been working and what it does now.
final class TranscriptPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func message(_ id: String, _ kind: AgentChatMessage.Kind, _ text: String = "", steps: [AgentToolStep] = [],
                         at seconds: Double? = nil) -> AgentChatMessage {
        AgentChatMessage(id: id, kind: kind, text: text, steps: steps, date: seconds.map { start.addingTimeInterval($0) })
    }

    private func step(_ id: String, _ name: String, _ summary: String = "", _ state: AgentToolStep.State = .done) -> AgentToolStep {
        AgentToolStep(id: id, name: name, summary: summary, state: state)
    }

    private func finishedTurn() -> [AgentChatMessage] {
        [
            message("u1", .user, "Fix de test", at: 0),
            message("t1", .thinking, "**Kijken** naar de test", at: 2),
            message("s1", .tools, steps: [step("a", "Bash", "npm test"), step("b", "Edit", "App.swift")], at: 5),
            message("x1", .assistant, "Even kijken.", at: 30),
            message("s2", .tools, steps: [step("c", "Read", "App.swift")], at: 40),
            message("x2", .assistant, "Opgelost.", at: 63)
        ]
    }

    func testFinishedTurnFoldsEverythingBeforeItsAnswer() {
        let rows = TranscriptPresentation.rows(finishedTurn() + [message("u2", .user, "Nog iets", at: 100)], working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "fold:t1", "x2", "u2"])
        guard case .fold(_, let seconds, let inner) = rows[1], case .assistant(let answer, let isFinal) = rows[2] else {
            return XCTFail("\(rows)")
        }
        XCTAssertEqual(seconds, 63)
        XCTAssertEqual(inner.map(\.id), ["t1", "group:s1", "x1", "step:c"])
        XCTAssertEqual(answer.text, "Opgelost.")
        XCTAssertTrue(isFinal, "the answer of a turn carries its copy button and time")
    }

    func testFoldWithoutTimesHasNoDuration() {
        let rows = TranscriptPresentation.rows([
            message("u1", .user, "Hoi"),
            message("s1", .tools, steps: [step("a", "Read", "x.swift")]),
            message("x1", .assistant, "Hallo"),
            message("u2", .user, "Nog iets")
        ], working: false)
        guard case .fold(_, let seconds, _) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertNil(seconds)
    }

    func testLastTurnFoldsOnceFinished() {
        let rows = TranscriptPresentation.rows(finishedTurn(), working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "fold:t1", "x2"], "the finished turn reads as 'Worked for 1m 3s' over its answer")
        guard case .assistant(_, let isFinal) = rows[2] else { return XCTFail("\(rows)") }
        XCTAssertTrue(isFinal)
    }

    func testTurnWithoutWorkDoesNotFold() {
        let rows = TranscriptPresentation.rows([message("u1", .user, "Hoi"), message("x1", .assistant, "Hallo")], working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "x1"])
    }

    func testRunningTurnShowsWorkingAndTheLiveStep() {
        var messages = finishedTurn().dropLast()
        messages.append(message("s3", .tools, steps: [step("d", "Grep", "TODO"), step("e", "Bash", "swift test", .running)], at: 70))
        let rows = TranscriptPresentation.rows(Array(messages), working: true)
        XCTAssertEqual(rows.map(\.id), ["u1", "working", "t1", "group:s1", "x1", "group:s2", "live"])
        guard case .working(let since) = rows[1], case .group(_, let steps, _) = rows[5], case .live(let current) = rows[6] else {
            return XCTFail("\(rows)")
        }
        XCTAssertEqual(since, start)
        XCTAssertEqual(steps.map(\.id), ["c", "d"], "steps split by an answer stay apart, those split by nothing join")
        XCTAssertEqual(current?.id, "e", "the step that runs is the live line, not part of the group")
    }

    func testRunningTurnWithoutARunningStepThinks() {
        let rows = TranscriptPresentation.rows([message("u1", .user, "Hoi", at: 0)], working: true)
        XCTAssertEqual(rows.map(\.id), ["u1", "working", "live"])
        guard case .live(let current) = rows[2] else { return XCTFail("\(rows)") }
        XCTAssertNil(current)
    }

    func testOnlyTheLastTurnStaysOpen() {
        let rows = TranscriptPresentation.rows(finishedTurn() + [message("u2", .user, "Nog iets", at: 100)], working: true)
        XCTAssertEqual(rows.map(\.id), ["u1", "fold:t1", "x2", "u2", "working", "live"])
    }

    func testThinkingKeptToItselfIsLeftOut() {
        let rows = TranscriptPresentation.rows([
            message("u1", .user, "Hoi"),
            message("s1", .tools, steps: [step("a", "Read", "a.swift")]),
            message("t1", .thinking, ""),
            message("s2", .tools, steps: [step("b", "Read", "b.swift")])
        ], working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "group:s1"], "steps split only by silent thinking are one group")
    }

    func testThinkingBetweenStepsJoinsTheGroup() {
        let rows = TranscriptPresentation.rows([
            message("u1", .user, "Hoi"),
            message("t0", .thinking, "Eerst kijken."),
            message("s1", .tools, steps: [step("a", "Read", "a.swift")]),
            message("t1", .thinking, "Nu de tests."),
            message("s2", .tools, steps: [step("b", "Bash", "ls")]),
            message("t2", .thinking, "Klaar met werken.")
        ], working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "t0", "group:s1", "t2"],
                       "a thought before more steps joins their group; one that opens or ends the work stays")
    }

    func testTallyCountsEditedFilesOnce() {
        let tally = ToolTally(steps: [step("a", "Edit", "App.swift"), step("b", "MultiEdit", "App.swift"),
                                      step("c", "Bash", "ls"), step("d", "Shell", "pwd", .failed), step("e", "Read", "x")])
        XCTAssertEqual(tally.counts[.edit], 1)
        XCTAssertEqual(tally.counts[.command], 2)
        XCTAssertEqual(tally.counts[.read], 1)
        XCTAssertTrue(tally.failed)
    }

    func testTranscriptKeepsTimes() {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-19T10:00:00.000Z","message":{"role":"user","content":"Draai de tests"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-19T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-19T10:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-19T10:01:03Z","message":{"role":"assistant","content":[{"type":"text","text":"Groen."}]}}"#
        ]
        let messages = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(messages.map(\.kind), [.user, .tools, .assistant])
        XCTAssertEqual(messages[1].updated?.timeIntervalSince(messages[1].date ?? .distantPast), 55, "a step's result moves its end")
        XCTAssertEqual(TranscriptPresentation.seconds(messages), 63)
    }

    /// A message sent while the agent worked (from the CLI, the desktop app or Nook) is a queued command line, and starts
    /// a turn of its own; task notifications and other agents' messages in that shape stay out.
    func testMessageSentWhileWorkingShowsAsYourPrompt() {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-19T10:00:00Z","message":{"role":"user","content":"Fix the build"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-19T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}"#,
            #"{"type":"attachment","uuid":"q1","timestamp":"2026-10-19T10:00:09Z","attachment":{"type":"queued_command","prompt":"Also run the linter","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true}}"#,
            #"{"type":"attachment","uuid":"q2","attachment":{"type":"queued_command","prompt":"<task-notification>done</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}}}"#,
            #"{"type":"attachment","uuid":"q3","isMeta":true,"attachment":{"type":"queued_command","prompt":"report","commandMode":"prompt","origin":{"kind":"peer"}}}"#,
            #"{"type":"attachment","uuid":"q4","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Older build, no origin"}],"commandMode":"prompt"}}"#,
            #"{"type":"user","uuid":"c1","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Linted."}]}}"#
        ]
        let messages = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(messages.map(\.kind), [.user, .assistant, .user, .user, .assistant])
        XCTAssertEqual(messages.filter { $0.kind == .user }.map(\.text), ["Fix the build", "Also run the linter", "Older build, no origin"])
        XCTAssertEqual(messages[2].id, "q1")
    }

    func testTranscriptEditsCarryTheirLines() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-19T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/App.swift","old_string":"a\nb\nc","new_string":"a\nB\nc\nd"}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-19T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        ]
        let messages = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
        let steps = messages.flatMap(\.steps)
        XCTAssertEqual(steps.first?.lines, EditLines(added: 2, removed: 1))
        XCTAssertEqual(ToolTally(steps: steps).lines, EditLines(added: 2, removed: 1))
    }

    func testTranscriptStepsKeepTheFileTheyReadOrWrote() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-19T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/.claude/skills/update/SKILL.md"}},{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/p/App.swift","old_string":"a","new_string":"b"}},{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"ls"}}]}}"#
        ]
        let steps = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8)).flatMap(\.steps)
        XCTAssertEqual(steps.map(\.file), ["/p/.claude/skills/update/SKILL.md", "/p/App.swift", nil])
        // A file it only read is not one of its outputs.
        XCTAssertEqual(steps.map(\.path), [nil, "/p/App.swift", nil])
    }

    func testFailedStepKeepsWhyItFailed() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/p/A.swift"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"<tool_use_error>\nerror: no such module 'Foo'\nmore</tool_use_error>"},{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"fine"}]}]}}"#
        ]
        let steps = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8)).flatMap(\.steps)
        XCTAssertEqual(steps.map(\.state), [.failed, .done])
        XCTAssertEqual(steps.map(\.error), ["error: no such module 'Foo'", nil], "only a failed step carries a reason")
    }

    func testInterruptedTurnSaysSoAtItsEnd() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Fix the test"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"Stop, do this instead"}}"#
        ]
        let messages = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(messages.map(\.kind), [.user, .tools, .user], "the interruption is no prompt of yours")
        XCTAssertTrue(messages[1].interrupted)
        let rows = TranscriptPresentation.rows(messages, working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "step:t1", "interrupted:t1-steps", "u2"])
    }

    func testCodexCommandWithAnExitCodeFails() {
        XCTAssertEqual(AgentTranscript.codexExitCode(#"{"output":"boom","metadata":{"exit_code":2}}"#), 2)
        XCTAssertEqual(AgentTranscript.codexExitCode("Exit code: 1\nWall time: 0.2 seconds\nOutput:\n"), 1)
        XCTAssertNil(AgentTranscript.codexExitCode("plain output"))
    }

    func testEveryMessageYouSentGetsAMarkInOrderDownTheRail() {
        let rows = TranscriptPresentation.rows(finishedTurn() + [message("u2", .user, "Nog iets", at: 100)], working: false)
        let marks = TranscriptPresentation.promptMarks(rows)
        XCTAssertEqual(marks.map(\.id), ["u1", "u2"])
        XCTAssertEqual(marks.map(\.row), ["u1", "u2"], "a click scrolls to the message itself")
        XCTAssertEqual(marks.first?.position, 0, "the first message is at the top")
        XCTAssertTrue(marks[1].position > 0.5 && marks[1].position < 1, "the last message sits below its earlier turn")
    }

    func testALongAnswerPushesTheNextMarkFurtherDown() {
        let short = [message("u1", .user, "Hoi"), message("x1", .assistant, "Ja."), message("u2", .user, "En nu?")]
        let long = [message("u1", .user, "Hoi"), message("x1", .assistant, String(repeating: "Een lange regel tekst. ", count: 60)),
                    message("u2", .user, "En nu?")]
        let near = TranscriptPresentation.promptMarks(TranscriptPresentation.rows(short, working: false))[1].position
        let far = TranscriptPresentation.promptMarks(TranscriptPresentation.rows(long, working: false))[1].position
        XCTAssertGreaterThan(far, near)
    }

    func testAConversationWithoutYourMessagesHasNoMarks() {
        XCTAssertTrue(TranscriptPresentation.promptMarks([]).isEmpty)
        XCTAssertTrue(TranscriptPresentation.promptMarks(TranscriptPresentation.rows([message("x1", .assistant, "Hallo")], working: false)).isEmpty)
    }
}
