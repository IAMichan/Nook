import XCTest

/// A session Nook runs whose conversation went on in the agent's own app: the turns written there show up in it.
final class TranscriptFollowTests: XCTestCase {
    private func transcript(_ lines: [String]) -> [AgentChatMessage] {
        AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
    }

    /// Nook's own turn, then one in the Claude app: your prompt, a thought, a command and its result, the answer.
    private let lines = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-10-30T16:00:00Z","message":{"role":"user","content":"Look at the code"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-30T16:00:05Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/a.swift"}}]}}"#,
        #"{"type":"user","uuid":"r1","timestamp":"2026-10-30T16:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"import Foundation"}]}}"#,
        #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-30T16:00:10Z","message":{"role":"assistant","content":[{"type":"text","text":"The code reads fine."}]}}"#,
        #"{"type":"user","uuid":"u2","timestamp":"2026-10-30T16:05:00Z","message":{"role":"user","content":"Now fix it all"}}"#,
        #"{"type":"assistant","uuid":"a3","timestamp":"2026-10-30T16:05:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"**Planning the fix**"}]}}"#,
        #"{"type":"assistant","uuid":"a4","timestamp":"2026-10-30T16:05:03Z","message":{"role":"assistant","content":[{"type":"text","text":"I read the rest first."},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test","description":"Run tests"}}]}}"#,
    ]

    private func ownTurn() -> [RunEvent] {
        [RunEvent(kind: .user, text: "Look at the code"),
         RunEvent(kind: .tool, text: "Read · a.swift", tool: "Read", callID: "t1", state: .done),
         RunEvent(kind: .assistant, text: "The code reads fine.", state: .done),
         RunEvent(kind: .result, text: "10s", state: .done)]
    }

    private func appended(_ changes: [TranscriptFollow.Change]) -> [RunEvent] {
        changes.compactMap { if case .append(let event) = $0 { return event } else { return nil } }
    }

    private func apply(_ changes: [TranscriptFollow.Change], to events: inout [RunEvent]) {
        for change in changes {
            switch change {
            case .append(let event): events.append(event)
            case .update(let id, let event):
                guard let index = events.firstIndex(where: { $0.id == id }) else { continue }
                events[index].text = event.text
                events[index].state = event.state
                events[index].output = event.output
            }
        }
    }

    func testTurnsWrittenOutsideNookAreTakenOverWithTheirWork() {
        let changes = TranscriptFollow.changes(events: ownTurn(), messages: transcript(lines), finished: false)
        let added = appended(changes)
        XCTAssertEqual(added.map(\.kind), [.user, .thinking, .assistant, .tool])
        XCTAssertEqual(added[0].text, "Now fix it all")
        XCTAssertEqual(added[2].text, "I read the rest first.")
        XCTAssertEqual(added[3].callID, "t2")
        XCTAssertEqual(added[3].tool, "Bash")
        XCTAssertEqual(added[3].state, .running)
        XCTAssertEqual(added[3].text, "Bash · swift test")
        // The step keeps its input, so the session shows it as a step of its own turns.
        XCTAssertTrue(added[3].detail?.contains("swift test") ?? false)
        XCTAssertTrue(added.allSatisfy { $0.source != nil })
        // Still working outside Nook: the turn is not over.
        XCTAssertFalse(added.contains { $0.kind == .result })
    }

    func testReadingAgainUpdatesStepsAndEndsTheTurnOnce() {
        var events = ownTurn()
        apply(TranscriptFollow.changes(events: events, messages: transcript(lines), finished: false), to: &events)
        let more = lines + [
            #"{"type":"user","uuid":"r2","timestamp":"2026-10-30T16:05:20Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Executed 3 tests, with 0 failures"}]}}"#,
            #"{"type":"assistant","uuid":"a5","timestamp":"2026-10-30T16:05:30Z","message":{"role":"assistant","content":[{"type":"text","text":"All fixed."}]}}"#,
        ]
        let changes = TranscriptFollow.changes(events: events, messages: transcript(more), finished: true)
        apply(changes, to: &events)
        let step = events.first { $0.callID == "t2" }
        XCTAssertEqual(step?.state, .done)
        XCTAssertEqual(step?.output, "Executed 3 tests, with 0 failures")
        XCTAssertEqual(events.filter { $0.callID == "t2" }.count, 1)
        XCTAssertEqual(events.last?.kind, .result)
        XCTAssertEqual(events.dropLast().last?.text, "All fixed.")
        // Nothing new: nothing changes, and the turn does not end twice.
        XCTAssertEqual(TranscriptFollow.changes(events: events, messages: transcript(more), finished: true), [])
        // It folds into "Worked for 30s" like a turn in Nook.
        let turn = TimelinePresentation.split(events).last ?? []
        XCTAssertEqual(turn.first?.text, "Now fix it all")
        XCTAssertEqual(turn.last?.date.timeIntervalSince(turn.first?.date ?? .distantPast), 30)
    }

    func testATurnEndsWhenTheNextOneStarts() {
        let more = lines + [
            #"{"type":"user","uuid":"u3","timestamp":"2026-10-30T16:10:00Z","message":{"role":"user","content":"And the docs"}}"#,
        ]
        let added = appended(TranscriptFollow.changes(events: ownTurn(), messages: transcript(more), finished: false))
        XCTAssertEqual(added.map(\.kind), [.user, .thinking, .assistant, .tool, .result, .user])
    }

    func testNothingWhenTheTranscriptIsAnotherConversation() {
        let events = [RunEvent(kind: .user, text: "Something else entirely"), RunEvent(kind: .assistant, text: "Done that.")]
        XCTAssertEqual(TranscriptFollow.changes(events: events, messages: transcript(lines), finished: true), [])
    }

    func testNookOwnAnswerBlocksAreNotTakenAgain() {
        // Nook wrote two answer blocks as two events; the transcript joins them into one message.
        let joined = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-30T16:00:00Z","message":{"role":"user","content":"Look at the code"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-30T16:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"First part of the answer."},{"type":"text","text":"Second part of it."}]}}"#,
        ]
        let events = [RunEvent(kind: .user, text: "Look at the code"),
                      RunEvent(kind: .assistant, text: "First part of the answer.", state: .done),
                      RunEvent(kind: .assistant, text: "Second part of it.", state: .done),
                      RunEvent(kind: .result, text: "", state: .done)]
        XCTAssertEqual(TranscriptFollow.changes(events: events, messages: transcript(joined), finished: true), [])
    }

    func testEveryAgentTranscriptKeepsTheStepInput() {
        let codex = AgentTranscript.jsonl(Data(#"""
        {"type":"response_item","timestamp":"2026-10-30T16:00:00Z","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"command\":[\"swift\",\"test\"]}"}}
        """#.utf8))
        XCTAssertNotNil(codex.first?.steps.first?.input)
        XCTAssertNotNil(transcript(lines).last?.steps.first?.input)
        let long = AgentTranscript.inputJSON(["content": String(repeating: "x", count: 10_000)]) ?? ""
        XCTAssertLessThan(long.count, 5_000)
    }
}
