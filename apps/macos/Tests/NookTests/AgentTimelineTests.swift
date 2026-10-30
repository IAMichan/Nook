import XCTest

/// The session's events, as the timeline writes them.
private final class Events: RunTimelineSink {
    var list: [RunEvent] = []

    func append(_ event: RunEvent) { list.append(event) }

    func mutate(_ eventID: UUID, _ change: (inout RunEvent) -> Void) {
        guard let index = list.lastIndex(where: { $0.id == eventID }) else { return }
        change(&list[index])
    }

    func eventID(callID: String) -> UUID? { list.last { $0.callID == callID && $0.kind == .tool }?.id }

    var running: [RunEvent.Kind] { list.filter { $0.state == .running }.map(\.kind) }
}

final class AgentTimelineTests: XCTestCase {
    private var events = Events()
    private var timeline = AgentTimeline()

    override func setUp() {
        events = Events()
        timeline = AgentTimeline()
    }

    @discardableResult
    private func feed(_ signals: AgentSignal...) -> [AgentTimelineEffect] {
        signals.flatMap { timeline.apply($0, to: events) }
    }

    private func shell(_ id: String, state: RunEvent.State = .running, output: String? = nil) -> AgentToolCall {
        AgentToolCall(id: id, name: "shell", title: "shell · npm test", detail: "npm test", output: output, state: state)
    }

    // MARK: Streams

    func testAnswerStreamsIntoOneBlockAndItsCopyReplacesIt() {
        feed(.textDelta("Hal"), .textDelta("lo"))
        XCTAssertEqual(events.list.map(\.text), ["Hallo"])
        XCTAssertEqual(events.running, [.assistant])
        feed(.text("Hallo!"))
        XCTAssertEqual(events.list.map(\.text), ["Hallo!"])
        XCTAssertEqual(events.running, [])
        XCTAssertEqual(timeline.lastTextID, events.list[0].id)
    }

    func testThinkingAndWritingNeverRunAtOnce() {
        feed(.textDelta("Eerst dit."), .thinkingDelta("Hm, de tests."))
        XCTAssertEqual(events.running, [.thinking], "a thought closes the answer being written")
        feed(.textDelta("Dan dat."))
        XCTAssertEqual(events.running, [.assistant], "and the answer closes the thought")
        XCTAssertEqual(events.list.map(\.kind), [.assistant, .thinking, .assistant])
    }

    func testAToolCallClosesWhatWasWritten() {
        feed(.thinkingDelta("Ik draai de tests."), .textDelta("Even testen."), .toolStarted(shell("c1")))
        XCTAssertEqual(events.running, [.tool], "only the command runs, so the live line names it")
    }

    func testItemsKeepCodexBlocksApart() {
        feed(.textDelta("a", item: "m1"), .textDelta("b", item: "m2"))
        XCTAssertEqual(events.list.map(\.text), ["a", "b"], "another message starts its own block")
        feed(.text("bb", item: "m2"))
        XCTAssertEqual(events.list.map(\.text), ["a", "bb"])
        feed(.thinkingDelta("x", item: "r1"), .thinking("xy", item: "r1"))
        XCTAssertEqual(events.list.last?.text, "xy")
        XCTAssertEqual(events.running, [])
    }

    func testAWholeAnswerWithoutStreamingIsAdded() {
        feed(.text("Klaar."), .thinking("Nagedacht."))
        XCTAssertEqual(events.list.map(\.kind), [.assistant, .thinking])
        XCTAssertEqual(events.list.map(\.state), [.done, .done])
        feed(.text("  "))
        XCTAssertEqual(events.list.count, 2, "an empty answer adds nothing")
    }

    func testClaudeThinkingBlockGetsItsCompleteCopy() {
        // Claude Code streams a block, closes it, and later sends the block whole.
        feed(.thinkingStarted, .thinkingDelta("Eerst kijk"), .thinkingEnded, .thinking("Eerst kijk ik naar main.swift."))
        XCTAssertEqual(events.list.map(\.text), ["Eerst kijk ik naar main.swift."])
        XCTAssertEqual(events.list.count, 1, "the copy is not a second thought")
        // A block that streamed no text keeps its place in line: its copy adds nothing.
        feed(.thinkingStarted, .thinkingEnded, .thinking(""))
        XCTAssertEqual(events.list.count, 1)
    }

    func testASteerForgetsTheCopyOfACutBlock() {
        feed(.thinkingStarted, .thinkingDelta("Half"), .pause)
        timeline.forgetPendingCopies()
        feed(.thinking("Een nieuwe gedachte."))
        XCTAssertEqual(events.list.map(\.text), ["Half", "Een nieuwe gedachte."])
    }

    func testPauseClosesEverything() {
        feed(.thinkingDelta("x"), .pause)
        XCTAssertEqual(events.running, [])
        XCTAssertFalse(timeline.isStreaming)
    }

    // MARK: Tool calls

    func testACallStartsStreamsAndSettlesInOneRow() {
        XCTAssertEqual(feed(.toolStarted(shell("c1"))), [.toolStarted(name: "shell")])
        feed(.toolUpdated(id: "c1", output: "ok 1\n", appending: true), .toolUpdated(id: "c1", output: "ok 2\n", appending: true))
        XCTAssertEqual(events.list.last?.output, "ok 1\nok 2\n")
        XCTAssertEqual(timeline.runningCalls, [events.list[0].id])
        let effects = feed(.toolUpdated(id: "c1", state: .done))
        XCTAssertEqual(effects, [.toolSucceeded(name: "shell", input: nil, paths: [])])
        XCTAssertEqual(events.list.count, 1)
        XCTAssertEqual(events.list[0].state, .done)
        XCTAssertEqual(timeline.runningCalls, [])
        XCTAssertEqual(feed(.toolUpdated(id: "c1", state: .done)), [], "a call says it finished well once")
    }

    func testACallReportedTwiceKeepsOneRow() {
        // ACP agents send a call again with more to say.
        feed(.toolStarted(AgentToolCall(id: "t1", name: "edit", title: "", state: .running)))
        let effects = feed(.toolStarted(AgentToolCall(id: "t1", name: "edit", title: "Edit main.swift", state: .done, paths: ["/p/main.swift"])))
        XCTAssertEqual(events.list.count, 1)
        XCTAssertEqual(events.list[0].text, "Edit main.swift")
        XCTAssertEqual(effects, [.toolSucceeded(name: "edit", input: nil, paths: ["/p/main.swift"])])
    }

    func testACallOnlyReportedWhenDoneIsAddedDone() {
        let effects = feed(.toolFinished(shell("c9", state: .failed, output: "boom")))
        XCTAssertEqual(events.list.map(\.state), [.failed])
        XCTAssertEqual(events.list[0].output, "boom")
        XCTAssertEqual(effects, [.toolStarted(name: "shell")], "a failed call changed nothing")
    }

    func testAFinishedCallOfAnEarlierTurnUpdatesItsRow() {
        feed(.toolStarted(shell("bg")))
        // The next turn starts with a fresh timeline; the command it left running reports back.
        timeline = AgentTimeline()
        let effects = feed(.toolFinished(shell("bg", state: .done, output: "klaar")))
        XCTAssertEqual(events.list.count, 1, "no second row for the same command")
        XCTAssertEqual(events.list[0].state, .done)
        XCTAssertEqual(events.list[0].output, "klaar")
        XCTAssertEqual(effects, [])
        XCTAssertEqual(feed(.toolUpdated(id: "unknown", state: .done)), [], "news about a call nobody knows is left alone")
        XCTAssertEqual(events.list.count, 1)
    }

    func testANestedCallIsMarked() {
        feed(.toolStarted(AgentToolCall(id: "n1", name: "Read", title: "Read · main.swift", nested: true)))
        XCTAssertEqual(events.list[0].text, "↳ Read · main.swift")
    }

    func testAnEditThatSucceededSaysWhatItChanged() {
        let input = JSONBox(["file_path": "/p/a.swift", "old_string": "a", "new_string": "b"])
        feed(.toolStarted(AgentToolCall(id: "e1", name: "Edit", title: "Edit · a.swift", input: input)))
        XCTAssertEqual(feed(.toolUpdated(id: "e1", output: "ok", state: .done)),
                       [.toolSucceeded(name: "Edit", input: input, paths: [])])
        XCTAssertEqual(ToolSummary.fileChanges(tool: "Edit", input: input.dictionary).map(\.path), ["/p/a.swift"])
    }

    // MARK: Every agent alike

    /// The same work, as each provider reports it, gives the same timeline.
    func testEveryAgentWritesTheSameTimeline() {
        func shape(_ signals: [AgentSignal]) -> [String] {
            let sink = Events()
            var timeline = AgentTimeline()
            for signal in signals { timeline.apply(signal, to: sink) }
            timeline.apply(.pause, to: sink)
            return sink.list.map { "\($0.kind.rawValue):\($0.state?.rawValue ?? "-")" }
        }
        let claude: [AgentSignal] = [.thinkingStarted, .thinkingDelta("Kijken"), .thinkingEnded, .textDelta("Ik test."),
                                     .text("Ik test."), .toolStarted(shell("1")), .toolUpdated(id: "1", output: "ok", state: .done),
                                     .thinking("Kijken."), .textDelta("Groen.")]
        let codex: [AgentSignal] = [.thinkingDelta("Kijken", item: "r"), .thinking("Kijken.", item: "r"), .textDelta("Ik test.", item: "m"),
                                    .toolStarted(shell("1")), .toolUpdated(id: "1", output: "ok", appending: true),
                                    .toolFinished(shell("1", state: .done)), .textDelta("Groen.", item: "m2")]
        let acp: [AgentSignal] = [.thinkingDelta("Kijken"), .textDelta("Ik test."), .toolStarted(shell("1")),
                                  .toolUpdated(id: "1", output: "ok", state: .done), .textDelta("Groen.")]
        let gemini: [AgentSignal] = [.thinking("Kijken"), .text("Ik test."), .toolStarted(shell("1")),
                                     .toolUpdated(id: "1", output: "ok", state: .done), .textDelta("Groen.")]
        let expected = ["thinking:done", "assistant:done", "tool:done", "assistant:done"]
        XCTAssertEqual(shape(claude), expected)
        XCTAssertEqual(shape(codex), expected)
        XCTAssertEqual(shape(acp), expected)
        XCTAssertEqual(shape(gemini), expected)
    }
}
