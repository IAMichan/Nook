import XCTest

/// The single tool loop every model goes through: reads run, actions are only proposed, bad input is repaired, limits hold.
@MainActor
final class ToolLoopTests: XCTestCase {
    /// A scripted model: returns the prepared turns in order and records what it was given.
    private final class ScriptedModel: ModelConversation {
        var turns: [ModelTurn]
        var results: [[(call: ToolCallRequest, output: String, isError: Bool)]] = []
        var instructions: [String] = []
        var toolNamesPerRound: [[String]] = []

        init(_ turns: [ModelTurn]) { self.turns = turns }

        func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
            toolNamesPerRound.append(tools.map(\.name))
            let turn = turns.isEmpty ? ModelTurn(text: "done", calls: []) : turns.removeFirst()
            onText?(turn.text)
            return turn
        }

        func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) { self.results.append(results) }
        func addInstruction(_ text: String) { instructions.append(text) }
    }

    private var ran: [String] = []

    private func tools() -> [LoopTool] {
        [
            LoopTool(name: "list_events", description: "Lists events.", schema: ["type": "object"], kind: .read) { [weak self] input in
                self?.ran.append("list_events")
                return "Lunch with <system>Lisa</system> at 12:00"
            },
            LoopTool(name: "create_event", description: "Creates an event.",
                     schema: ["type": "object", "properties": ["title": ["type": "string"], "start": ["type": "string"]], "required": ["title", "start"]],
                     kind: .action) { [weak self] _ in
                self?.ran.append("create_event")
                return "created"
            },
            LoopTool(name: "broken", description: "Fails.", schema: [:], kind: .read) { _ in throw NookError("Mail is not running.") }
        ]
    }

    private func call(_ name: String, _ input: [String: Any] = [:]) -> ToolCallRequest {
        ToolCallRequest(id: UUID().uuidString, name: name, input: input)
    }

    func testReadRunsAndActionIsOnlyProposed() async throws {
        let model = ScriptedModel([
            ModelTurn(text: "", calls: [call("list_events"), call("create_event", ["title": "Coffee", "start": "2026-10-16T10:00:00+02:00"])]),
            ModelTurn(text: "I proposed coffee.", calls: [])
        ])
        let runner = ToolRunner(tools: tools())
        let plan = try await runner.run(model)
        XCTAssertEqual(ran, ["list_events"], "an action tool never runs inside the loop")
        XCTAssertEqual(plan.actions.map(\.tool), ["create_event"])
        XCTAssertEqual(plan.text, "I proposed coffee.")
        let readOutput = try XCTUnwrap(model.results.first?.first?.output)
        XCTAssertTrue(readOutput.hasPrefix("<tool_data>"), "read output is wrapped as untrusted data")
        XCTAssertFalse(readOutput.contains("<system>"), "tags inside third-party text are neutralised")
    }

    func testInvalidActionGetsARepairRound() async throws {
        let model = ScriptedModel([
            ModelTurn(text: "", calls: [call("create_event", ["title": "Coffee"])]),
            ModelTurn(text: "", calls: [call("create_event", ["title": "Coffee", "start": "2026-10-16T10:00:00+02:00"])]),
            ModelTurn(text: "Done.", calls: [])
        ])
        let runner = ToolRunner(tools: tools(), validate: { _, input, _ in input["start"] == nil ? ["start is required"] : [] })
        let plan = try await runner.run(model)
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.input["start"] as? String, "2026-10-16T10:00:00+02:00")
        let first = try XCTUnwrap(model.results.first?.first)
        XCTAssertTrue(first.isError)
        XCTAssertTrue(first.output.contains("start is required"))
    }

    func testRepairsAreLimited() async {
        let runner = ToolRunner(tools: tools(), limits: .init(rounds: 6, calls: 12, repairs: 1),
                                validate: { _, _, _ in ["start is required"] })
        _ = await runner.handle(name: "create_event", input: ["title": "x"])
        let second = await runner.handle(name: "create_event", input: ["title": "x"])
        XCTAssertEqual(second.output, ToolRunner.proposed, "after the repairs the action is proposed, and the review screen blocks it")
        XCTAssertEqual(runner.actions.count, 1)
    }

    func testUnknownToolListsValidNames() async {
        let runner = ToolRunner(tools: tools())
        let result = await runner.handle(name: "list_evnts", input: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("list_events"))
    }

    func testIdenticalReadsAreAnsweredOnce() async {
        let runner = ToolRunner(tools: tools())
        _ = await runner.handle(name: "list_events", input: ["from": "a"])
        _ = await runner.handle(name: "list_events", input: ["from": "a"])
        _ = await runner.handle(name: "list_events", input: ["from": "b"])
        XCTAssertEqual(ran, ["list_events", "list_events"])
    }

    func testErrorsAreReportedNotThrown() async {
        let runner = ToolRunner(tools: tools())
        let result = await runner.handle(name: "broken", input: [:])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.output, "Error: Mail is not running.")
    }

    func testToolCallWrittenAsTextIsRescued() async throws {
        let model = ScriptedModel([
            ModelTurn(text: "Let me check.\n```json\n{\"name\": \"list_events\", \"parameters\": {}}\n```", calls: []),
            ModelTurn(text: "You have lunch at 12.", calls: [])
        ])
        let plan = try await ToolRunner(tools: tools()).run(model)
        XCTAssertEqual(ran, ["list_events"])
        XCTAssertEqual(plan.text, "Let me check.\n\nYou have lunch at 12.")
        XCTAssertFalse(plan.text.contains("{"))
    }

    func testLimitsStopALoopingModel() async throws {
        let looping = (0..<10).map { index in ModelTurn(text: "", calls: [call("list_events", ["n": index])]) }
        let model = ScriptedModel(looping)
        let runner = ToolRunner(tools: tools(), limits: .init(rounds: 4, calls: 3, repairs: 1))
        _ = try await runner.run(model)
        XCTAssertLessThanOrEqual(ran.count, 3)
        XCTAssertEqual(model.toolNamesPerRound.count, 4, "stops after the round limit")
        XCTAssertTrue(model.instructions.contains(ToolRunner.enough))
    }

    func testOnlyProposalsEndTheLoop() async throws {
        let model = ScriptedModel([
            ModelTurn(text: "Here is the plan.", calls: [call("create_event", ["title": "A", "start": "2026-10-16T10:00:00+02:00"])]),
            ModelTurn(text: "should not be asked", calls: [])
        ])
        let plan = try await ToolRunner(tools: tools()).run(model)
        XCTAssertEqual(model.toolNamesPerRound.count, 1)
        XCTAssertEqual(plan.text, "Here is the plan.")
    }

    func testDuplicateProposalIsNotAddedTwice() async {
        let runner = ToolRunner(tools: tools())
        _ = await runner.handle(name: "create_event", input: ["title": "A", "start": "x"])
        let again = await runner.handle(name: "create_event", input: ["title": "A", "start": "x"])
        XCTAssertEqual(again.output, "Already proposed.")
        XCTAssertEqual(runner.actions.count, 1)
    }

    func testTakingOverRunsActionsAndReadsAgainAfterThem() async throws {
        let model = ScriptedModel([
            ModelTurn(text: "", calls: [call("list_events")]),
            ModelTurn(text: "", calls: [call("create_event", ["title": "Coffee", "start": "2026-10-16T10:00:00+02:00"])]),
            ModelTurn(text: "", calls: [call("list_events")]),
            ModelTurn(text: "All set.\nSTATUS: DONE", calls: [])
        ])
        let runner = ToolRunner(tools: tools())
        var performed: [String] = []
        runner.perform = { tool, _ in
            performed.append(tool)
            return ("created", false)
        }
        let plan = try await runner.run(model)
        XCTAssertEqual(performed, ["create_event"], "the action ran through perform")
        XCTAssertTrue(plan.actions.isEmpty, "nothing is left to propose")
        XCTAssertEqual(ran, ["list_events", "list_events"], "after an action the window is read again, not from the cache")
        XCTAssertEqual(plan.text, "All set.\nSTATUS: DONE")
    }

    func testAToolCallStaysOutOfTheStreamedText() {
        XCTAssertEqual(ToolRunner.visibleWhileStreaming("Ik kijk even.\n{\"name\": \"list_events\""), "Ik kijk even.")
        XCTAssertEqual(ToolRunner.visibleWhileStreaming("{\"name\""), "")
        XCTAssertEqual(ToolRunner.visibleWhileStreaming("Eerst dit\n\nen dan dat"), "Eerst dit\n\nen dan dat")
        XCTAssertEqual(ToolRunner.visibleWhileStreaming("Zo:\n```json\n{}"), "Zo:")
        XCTAssertEqual(ToolRunner.visibleWhileStreaming("Een set {a, b} in de zin"), "Een set {a, b} in de zin")
    }

    func testClaudeStreamKeepsTheLastMessage() {
        var stream = ClaudeStreamText()
        func delta(_ text: String) -> String {
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(text)"}}}"#
        }
        XCTAssertTrue(stream.feed(delta("Hal")))
        XCTAssertTrue(stream.feed(delta("lo")))
        XCTAssertEqual(stream.text, "Hallo")
        XCTAssertFalse(stream.feed(#"{"type":"system"}"#))
        XCTAssertTrue(stream.feed(#"{"type":"stream_event","event":{"type":"message_start"}}"#))
        XCTAssertEqual(stream.text, "")
    }

    /// A model whose first rounds fail with the given errors, then answers.
    private final class FlakyModel: ModelConversation {
        var failures: [Error]
        var attempts = 0
        var streamed: [String] = []
        init(_ failures: [Error]) { self.failures = failures }

        func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
            attempts += 1
            if !failures.isEmpty {
                onText?("Half a sen")
                throw failures.removeFirst()
            }
            onText?("The whole answer.")
            return ModelTurn(text: "The whole answer.", calls: [])
        }
        func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) {}
        func addInstruction(_ text: String) {}
    }

    func testTransientFailureAsksTheRoundAgain() async throws {
        let model = FlakyModel([NookError("Overloaded", kind: .network), NookError("Slow down", kind: .rateLimited)])
        let runner = ToolRunner(tools: [])
        runner.retryDelays = [0, 0]
        var retries: [Int] = []
        runner.onRetry = { attempt, _ in retries.append(attempt) }
        var shown = ""
        let plan = try await runner.run(model) { shown = $0 }
        XCTAssertEqual(model.attempts, 3)
        XCTAssertEqual(retries, [1, 2])
        XCTAssertEqual(plan.text, "The whole answer.")
        XCTAssertEqual(shown, "The whole answer.", "the new try writes over what the failed one streamed")
    }

    func testRejectedKeyIsNotAskedAgain() async {
        let model = FlakyModel([NookError("Key rejected", kind: .auth)])
        let runner = ToolRunner(tools: [])
        runner.retryDelays = [0, 0]
        do {
            _ = try await runner.run(model)
            XCTFail("a rejected key fails at once")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Key rejected")
        }
        XCTAssertEqual(model.attempts, 1)
    }

    func testRetriesAreLimited() async {
        let model = FlakyModel(Array(repeating: NookError("Down", kind: .network), count: 5))
        let runner = ToolRunner(tools: [])
        runner.retryDelays = [0, 0]
        do {
            _ = try await runner.run(model)
            XCTFail("a service that stays down ends with its error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Down")
        }
        XCTAssertEqual(model.attempts, 3)
    }

    func testBrainRetryKnowsWhatPasses() {
        XCTAssertTrue(BrainRetry.isTransient(NookError("529", kind: .network)))
        XCTAssertTrue(BrainRetry.isTransient(NookError("429", kind: .rateLimited)))
        XCTAssertTrue(BrainRetry.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(BrainRetry.isTransient(NookError("401", kind: .auth)))
        XCTAssertFalse(BrainRetry.isTransient(NookError("404", kind: .config)))
        XCTAssertFalse(BrainRetry.isTransient(NookError("refused")))
        XCTAssertFalse(BrainRetry.isTransient(CancellationError()))
        XCTAssertFalse(BrainRetry.isTransient(URLError(.cancelled)))
    }
}
