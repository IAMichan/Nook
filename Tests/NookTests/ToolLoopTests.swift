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
}
