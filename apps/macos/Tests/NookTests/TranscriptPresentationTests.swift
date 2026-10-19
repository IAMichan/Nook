import XCTest

/// How an agent's own transcript reads, as Code shows a thread: finished turns fold to "Worked for …", steps in a row
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
        let rows = TranscriptPresentation.rows(finishedTurn(), working: false)
        XCTAssertEqual(rows.map(\.id), ["u1", "fold:t1", "x2"])
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
            message("x1", .assistant, "Hallo")
        ], working: false)
        guard case .fold(_, let seconds, _) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertNil(seconds)
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
        guard case .working(let since) = rows[1], case .group(_, let steps) = rows[5], case .live(let current) = rows[6] else {
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
}
