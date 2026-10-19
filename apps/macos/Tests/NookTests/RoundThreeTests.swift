import XCTest

/// What the Agents tab took in its third round: the agent's task list from each protocol and its subagents.
final class RoundThreeTests: XCTestCase {
    // MARK: Tasks

    func testClaudeTodoWrite() {
        let steps = RunTasks.claude(["todos": [
            ["content": "Read the code", "status": "completed", "activeForm": "Reading the code"],
            ["content": "Run the tests", "status": "in_progress", "activeForm": "Running the tests"],
            ["content": "Fix", "status": "pending", "activeForm": "Fixing"]
        ]])
        XCTAssertEqual(steps, [RunTaskStep(text: "Read the code", status: .done),
                               RunTaskStep(text: "Running the tests", status: .active),
                               RunTaskStep(text: "Fix", status: .pending)])
        XCTAssertNil(RunTasks.claude(["command": "ls"]))
    }

    func testCodexPlanUpdated() {
        let line = #"{"method":"turn/plan/updated","params":{"threadId":"t","turnId":"u","explanation":null,"plan":[{"step":"Tests","status":"completed"},{"step":" ","status":"inProgress"}]}}"#
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(line)!),
                       [.tasks([RunTaskStep(text: "Tests", status: .done), RunTaskStep(text: "Step 2", status: .active)])])
    }

    func testProgress() {
        let steps = [RunTaskStep(text: "A", status: .done), RunTaskStep(text: "B", status: .pending), RunTaskStep(text: "C", status: .pending)]
        let progress = RunTasks.progress(steps)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.current, "B")
        XCTAssertFalse(RunTasks.isFinished(steps))
        let done = steps.map { RunTaskStep(text: $0.text, status: .done) }
        XCTAssertTrue(RunTasks.isFinished(done))
        XCTAssertEqual(RunTasks.progress(done).current, "C")
    }

    func testOldSessionsDecodeWithoutTasks() throws {
        let run = TestData.run(status: .completed)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as! [String: Any]
        object.removeValue(forKey: "tasks")
        let decoded = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.tasks)
    }

    // MARK: Subagents

    func testSubagentsFromTaskCalls() {
        let user = RunEvent(kind: .user, text: "go")
        let task = RunEvent(kind: .tool, text: "Task · Find auth", tool: "Task",
                            detail: #"{"description":"Find auth","prompt":"Look for login code","subagent_type":"Explore"}"#, state: .running)
        let nested = RunEvent(kind: .tool, text: "↳ Grep · login", tool: "Grep", state: .done)
        let other = RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash", state: .done)
        let agents = Subagents.latest([user, task, nested, other])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.kind, "Explore")
        XCTAssertEqual(agents.first?.title, "Find auth")
        XCTAssertEqual(agents.first?.prompt, "Look for login code")
        XCTAssertEqual(agents.first?.isRunning, true)
        // Only the latest turn counts.
        XCTAssertEqual(Subagents.latest([user, task, RunEvent(kind: .user, text: "next")]), [])
    }
}
