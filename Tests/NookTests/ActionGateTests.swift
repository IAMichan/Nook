import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

/// Suggestion verification and plan execution: validation, duplicate execution, partial failure.
/// Mock tools are used; nothing executes outside the test.
@MainActor
final class ActionGateTests: XCTestCase {
    private let eventSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Titel."],
            "start": ["type": "string", "description": "Begin, ISO 8601 met tijdzone."],
            "end": ["type": "string", "description": "Einde, ISO 8601 met tijdzone."]
        ],
        "required": ["title", "start"]
    ]

    private func parse(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    func testValidEvent() {
        let problems = ActionGate.problems(tool: "create_event", input: ["title": "Koffie", "start": "2026-10-16T14:00:00+02:00"],
                                          schema: eventSchema, parseDate: parse)
        XCTAssertEqual(problems, [])
    }

    func testMissingRequiredAndBadDate() {
        let problems = ActionGate.problems(tool: "create_event", input: ["start": "volgende week"], schema: eventSchema, parseDate: parse)
        XCTAssertTrue(problems.contains("De titel ontbreekt."))
        XCTAssertTrue(problems.contains { $0.contains("geen geldige datum") })
    }

    func testEndBeforeStart() {
        let problems = ActionGate.problems(
            tool: "create_event",
            input: ["title": "X", "start": "2026-10-16T14:00:00+02:00", "end": "2026-10-16T13:00:00+02:00"],
            schema: eventSchema, parseDate: parse
        )
        XCTAssertEqual(problems, ["Het einde ligt niet na het begin."])
    }

    func testUnknownFieldAndEnum() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["event": ["type": "string", "enum": ["APPROVE", "COMMENT"]], "repo": ["type": "string"], "number": ["type": "integer"]],
            "required": ["event", "repo", "number"]
        ]
        let problems = ActionGate.problems(tool: "github_review_pr",
                                           input: ["event": "MERGE_ALL", "repo": "../etc", "number": 3, "admin": true],
                                           schema: schema, parseDate: parse)
        XCTAssertTrue(problems.contains("Onbekend veld admin."))
        XCTAssertTrue(problems.contains { $0.hasPrefix("Het oordeel moet een van") }, "\(problems)")
        XCTAssertTrue(problems.contains("De repository moet eigenaar/naam zijn."))
    }

    func testOnlyHttpsLinks() {
        let schema: [String: Any] = ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
        XCTAssertEqual(ActionGate.problems(tool: "open_url", input: ["url": "file:///etc/passwd"], schema: schema, parseDate: parse),
                       ["Alleen https-links mogen."])
        XCTAssertEqual(ActionGate.problems(tool: "open_url", input: ["url": "https://nook.app"], schema: schema, parseDate: parse), [])
    }

    func testMailAddresses() {
        XCTAssertTrue(ActionGate.isMailAddress("lisa@example.nl"))
        XCTAssertTrue(ActionGate.isMailAddress("Lisa de Vries <lisa@example.nl>"))
        XCTAssertFalse(ActionGate.isMailAddress("lisa"))
        XCTAssertFalse(ActionGate.isMailAddress("lisa@example"))
    }

    func testNormalizedTrimsAndCoerces() {
        let schema: [String: Any] = ["type": "object", "properties": ["number": ["type": "integer"], "title": ["type": "string"]]]
        let result = ActionGate.normalized(["number": "12", "title": "  Hallo \n", "extra": "x"], schema: schema)
        XCTAssertNil(result["extra"], "Unknown fields are stripped")
        XCTAssertEqual(result["number"] as? Int, 12)
        XCTAssertEqual(result["title"] as? String, "Hallo")
    }

    func testFieldsShowFullContentInSchemaOrder() {
        let body = String(repeating: "Lange tekst. ", count: 20)
        let fields = ActionGate.fields(["start": "2026-10-16T14:00:00+02:00", "title": "Koffie", "end": body], schema: eventSchema)
        XCTAssertEqual(fields.map(\.key), ["title", "start", "end"])
        XCTAssertEqual(fields.last?.value, body, "Nothing truncated")
        XCTAssertTrue(fields.last?.multiline ?? false)
    }

    func testIdentityIsStableAndOrderIndependent() {
        let a = ActionGate.identity(tool: "create_event", input: ["title": "A", "start": "x"])
        let b = ActionGate.identity(tool: "create_event", input: ["start": "x", "title": "A"])
        let c = ActionGate.identity(tool: "create_event", input: ["title": "B", "start": "x"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: Plan Execution

    private func steps(_ count: Int) -> [PlanRunner.Step] {
        (0..<count).map { PlanRunner.Step(tool: "create_reminder", input: ["title": "Taak \($0)"]) }
    }

    func testPartialFailureStopsAndRetryDoesNotRepeatDoneSteps() async {
        var executed: [String] = []
        var failSecond = true
        var done: [String: Date] = [:]
        let runner = PlanRunner(
            check: { _ in [] },
            execute: { step in
                let title = step.input["title"] as! String
                if title == "Taak 1" && failSecond { throw TestError("Herinneringen gaf geen antwoord.") }
                executed.append(title)
                return "Herinnering gemaakt: \(title)"
            },
            executedBefore: { done[$0] },
            recordExecuted: { key, _, _ in done[key] = Date() }
        )
        let plan = steps(3)
        let first = await runner.run(plan, states: [], include: [true, true, true])
        XCTAssertEqual(first, [.done("Herinnering gemaakt: Taak 0"), .failed("Herinneringen gaf geen antwoord."), .notRun])
        XCTAssertEqual(executed, ["Taak 0"])

        failSecond = false
        let second = await runner.run(plan, states: first, include: [true, true, true])
        XCTAssertEqual(executed, ["Taak 0", "Taak 1", "Taak 2"], "Task 0 is not recreated")
        XCTAssertEqual(second.map(\.isFinished), [true, true, true])
    }

    func testDeselectedStepsAreSkipped() async {
        var executed = 0
        let runner = PlanRunner(check: { _ in [] }, execute: { _ in executed += 1; return "ok" },
                                executedBefore: { _ in nil }, recordExecuted: { _, _, _ in })
        let states = await runner.run(steps(2), states: [], include: [false, true])
        XCTAssertEqual(states, [.skipped, .done("ok")])
        XCTAssertEqual(executed, 1)
    }

    func testDuplicateIsNotExecutedUnlessForced() async {
        var executed = 0
        let earlier = Date(timeIntervalSince1970: 0)
        let runner = PlanRunner(check: { _ in [] }, execute: { _ in executed += 1; return "ok" },
                                executedBefore: { _ in earlier }, recordExecuted: { _, _, _ in })
        let first = await runner.run(steps(1), states: [], include: [true])
        guard case .duplicate = first[0] else { return XCTFail("Expected duplicate status") }
        XCTAssertEqual(executed, 0)
        let forced = await runner.run(steps(1), states: first, include: [true], force: [0])
        XCTAssertEqual(forced, [.done("ok")])
        XCTAssertEqual(executed, 1)
    }

    func testRepeatableToolsSkipDuplicateCheck() async {
        var executed = 0
        let runner = PlanRunner(check: { _ in [] }, execute: { _ in executed += 1; return "ok" },
                                executedBefore: { _ in Date() }, recordExecuted: { _, _, _ in })
        _ = await runner.run([PlanRunner.Step(tool: "media_control", input: ["action": "next"])], states: [], include: [true])
        XCTAssertEqual(executed, 1)
    }

    func testCheckAtExecutionTimeBlocksInvalidStep() async {
        var executed = 0
        let runner = PlanRunner(check: { $0.tool == "send_to_source" ? ["Deze bron staat uit voor dit gesprek."] : [] },
                                execute: { _ in executed += 1; return "ok" },
                                executedBefore: { _ in nil }, recordExecuted: { _, _, _ in })
        let states = await runner.run([PlanRunner.Step(tool: "send_to_source", input: [:]), PlanRunner.Step(tool: "create_reminder", input: [:])],
                                      states: [], include: [true, true])
        XCTAssertEqual(states, [.failed("Deze bron staat uit voor dit gesprek."), .notRun])
        XCTAssertEqual(executed, 0, "A model tool call is not blindly executed")
    }
}
