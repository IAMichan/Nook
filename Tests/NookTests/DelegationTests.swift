import XCTest

final class DelegationTests: XCTestCase {
    private let all: [PermissionPolicy] = [.ask, .acceptEdits, .bypass]

    private func resolve(_ parentMode: ExecutionMode = .agent, _ parentPermission: PermissionPolicy = .acceptEdits,
                         mode: ExecutionMode? = nil, permission: PermissionPolicy? = nil, role: DelegationRole = .implementation,
                         offered: [PermissionPolicy]? = nil) -> Result<DelegationPolicy.Rights, DelegationPolicy.Denial> {
        DelegationPolicy.resolve(parentMode: parentMode, parentPermission: parentPermission, mode: mode, permission: permission,
                                 role: role, offered: offered ?? all)
    }

    // MARK: Rights

    func testChildInheritsWhatItIsNotGiven() throws {
        let child = try resolve(.agent, .acceptEdits).get()
        XCTAssertEqual(child.mode, .agent)
        XCTAssertEqual(child.permission, .acceptEdits)
    }

    func testChildMayHaveLessButNeverMore() throws {
        XCTAssertEqual(try resolve(.agent, .bypass, permission: .ask).get().permission, .ask)
        XCTAssertEqual(resolve(.agent, .acceptEdits, permission: .bypass), .failure(.escalation("rights")))
        XCTAssertEqual(try resolve(.agent, .acceptEdits, mode: .plan).get().mode, .plan)
    }

    func testPlanParentCannotHandOutAgentMode() {
        XCTAssertEqual(resolve(.plan, .acceptEdits, mode: .agent), .failure(.escalation("mode")))
        XCTAssertEqual(try? resolve(.plan, .bypass).get().mode, .plan, "inherited: stays plan")
        XCTAssertEqual(try? resolve(.plan, .bypass, role: .implementation).get().mode, .plan)
    }

    func testReadOnlyRolesRunInPlanModeUnlessChosen() throws {
        for role in [DelegationRole.research, .review, .design] {
            XCTAssertEqual(try resolve(.agent, .acceptEdits, role: role).get().mode, .plan, role.rawValue)
        }
        XCTAssertEqual(try resolve(.agent, .acceptEdits, mode: .agent, role: .research).get().mode, .agent,
                       "an explicit choice within the parent's rights is honoured")
        XCTAssertEqual(try resolve(.agent, .acceptEdits, role: .test).get().mode, .agent)
    }

    func testInheritedRightsStepDownToWhatTheAgentOffers() throws {
        XCTAssertEqual(try resolve(.agent, .bypass, offered: [.ask, .acceptEdits]).get().permission, .acceptEdits)
        XCTAssertEqual(try resolve(.agent, .acceptEdits, offered: [.ask]).get().permission, .ask)
        XCTAssertEqual(resolve(.agent, .acceptEdits, offered: []), .failure(.unsupported(.acceptEdits)))
    }

    func testAnExplicitRightTheAgentLacksIsRefused() {
        XCTAssertEqual(resolve(.agent, .bypass, permission: .bypass, offered: [.ask]), .failure(.unsupported(.bypass)))
    }

    // MARK: Bounds

    func testChainAndFanOutAreBounded() {
        XCTAssertNil(DelegationPolicy.admit(parentDepth: 0, activeChildren: 0))
        XCTAssertNil(DelegationPolicy.admit(parentDepth: DelegationPolicy.maxDepth - 1, activeChildren: DelegationPolicy.maxActiveChildren - 1))
        XCTAssertEqual(DelegationPolicy.admit(parentDepth: DelegationPolicy.maxDepth, activeChildren: 0), .tooDeep)
        XCTAssertEqual(DelegationPolicy.admit(parentDepth: 0, activeChildren: DelegationPolicy.maxActiveChildren), .tooManyChildren)
        for denial in [DelegationPolicy.Denial.escalation("mode"), .unsupported(.bypass), .tooDeep, .tooManyChildren, .notARun] {
            XCTAssertFalse(denial.message.isEmpty)
        }
    }

    func testChildOnlySeesTheTaskAndItsRole() {
        XCTAssertEqual(DelegationPolicy.prompt(task: "  Fix the login bug \n", role: .general), "Fix the login bug")
        let review = DelegationPolicy.prompt(task: "Check the diff", role: .review)
        XCTAssertTrue(review.hasPrefix("Check the diff"))
        XCTAssertTrue(review.contains("Role: review"))
    }

    // MARK: Task state and result

    func testStateOfATask() {
        XCTAssertEqual(DelegatedTask.state(.preparing), .queued)
        XCTAssertEqual(DelegatedTask.state(.running), .running)
        XCTAssertEqual(DelegatedTask.state(.running, hasPendingQuestion: true), .waiting)
        XCTAssertEqual(DelegatedTask.state(.waitingApproval), .waiting)
        XCTAssertEqual(DelegatedTask.state(.completed), .completed)
        XCTAssertEqual(DelegatedTask.state(.failed), .failed)
        XCTAssertEqual(DelegatedTask.state(.stopped), .cancelled)
        XCTAssertTrue(DelegatedTask.State.cancelled.isTerminal)
        XCTAssertFalse(DelegatedTask.State.waiting.isTerminal)
    }

    func testSummaryIsTheLastThingTheChildSaid() {
        let events = [RunEvent(kind: .assistant, text: "First"), RunEvent(kind: .tool, text: "Bash"),
                      RunEvent(kind: .assistant, text: "  Done: 3 files changed.  "), RunEvent(kind: .result, text: "ok")]
        XCTAssertEqual(DelegatedTask.summary(status: .completed, statusDetail: nil, events: events), "Done: 3 files changed.")
        XCTAssertNil(DelegatedTask.summary(status: .completed, statusDetail: nil, events: []))
    }

    func testAFailedTaskShowsItsErrorFirst() {
        let events = [RunEvent(kind: .assistant, text: "Working on it"), RunEvent(kind: .error, text: "Usage limit reached")]
        XCTAssertEqual(DelegatedTask.summary(status: .failed, statusDetail: "x", events: events), "Usage limit reached")
        XCTAssertEqual(DelegatedTask.summary(status: .failed, statusDetail: "boom", events: [RunEvent(kind: .assistant, text: "hi")]), "boom")
    }

    func testLongSummaryIsClipped() {
        let long = String(repeating: "a", count: DelegatedTask.summaryLimit + 500)
        let summary = DelegatedTask.summary(status: .completed, statusDetail: nil, events: [RunEvent(kind: .assistant, text: long)])
        XCTAssertLessThanOrEqual(summary?.count ?? 0, DelegatedTask.summaryLimit + 2)
    }

    func testRenderedResultIsJSONTheAgentCanRead() throws {
        let snapshot = DelegatedTask.Snapshot(taskID: "abc", title: "Fix", state: .completed, summary: "Done",
                                              hasPendingQuestion: false, model: "opus", provider: "Claude Code")
        let text = DelegatedTask.render(snapshot, waitTimedOut: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["taskId"] as? String, "abc")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["waitTimedOut"] as? Bool, true)
        XCTAssertEqual(object["summary"] as? String, "Done")
        var pending = snapshot
        pending.summary = nil
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DelegatedTask.render(pending).utf8)) as? [String: Any])
        XCTAssertTrue(none["summary"] is NSNull)
    }

    func testWakeMessageCarriesTheResult() {
        let snapshot = DelegatedTask.Snapshot(taskID: "abc", title: "Fix", state: .failed, summary: "Boom",
                                              hasPendingQuestion: false, model: nil, provider: "Codex")
        let text = DelegatedTask.wakeMessage(snapshot)
        XCTAssertTrue(text.contains("\"Fix\""))
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("Boom"))
        XCTAssertTrue(text.contains("task_status"))
    }

    func testLinkSurvivesAnOldFileAndRoundTrips() throws {
        var link = DelegationLink(parentID: UUID(), key: "k", depth: 1, role: .review, wake: true)
        link.delivered = true
        let data = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(DelegationLink.self, from: data), link)
        var run = TestData.run(status: .completed)
        run.delegation = link
        let copy = try JSONDecoder().decode(WorkspaceRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(copy.delegation, link)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TestData.run(status: .completed))) as? [String: Any])
        object["delegation"] = nil
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object)).delegation)
    }

    // MARK: Bridge tools

    private func caller(_ mode: ExecutionMode = .agent, _ permission: PermissionPolicy = .acceptEdits) -> BridgeCaller {
        BridgeCaller(kind: .run(UUID()), agent: "Claude Code", title: "T", directory: "/Users/x/app", mode: mode, permission: permission)
    }

    func testDelegatingAsksUnlessTheSessionHasFullRights() {
        XCTAssertEqual(BridgePolicy.verdict(tool: .delegateTask, caller: caller(.agent, .acceptEdits)), .ask(.delegation))
        XCTAssertEqual(BridgePolicy.verdict(tool: .delegateTask, caller: caller(.agent, .ask)), .ask(.delegation))
        XCTAssertEqual(BridgePolicy.verdict(tool: .delegateTask, caller: caller(.agent, .bypass)), .allow)
    }

    func testPlanModeCannotDelegateOrCancelButCanRead() {
        XCTAssertEqual(BridgePolicy.verdict(tool: .delegateTask, caller: caller(.plan, .bypass)), .refuse(.planMode))
        XCTAssertEqual(BridgePolicy.verdict(tool: .taskCancel, caller: caller(.plan, .bypass)), .refuse(.planMode))
        XCTAssertEqual(BridgePolicy.verdict(tool: .taskStatus, caller: caller(.plan)), .allow)
        XCTAssertEqual(BridgePolicy.verdict(tool: .orchestratorCapabilities, caller: caller(.plan)), .allow)
    }

    func testSwitchedOffBridgeRefusesDelegation() {
        XCTAssertEqual(BridgePolicy.verdict(tool: .delegateTask, caller: caller(), enabled: false), .refuse(.disabled))
    }

    func testToolsAreFoundByTheirPrefixedNames() {
        XCTAssertEqual(BridgeTool.named("mcp__nook__delegate_task"), .delegateTask)
        XCTAssertEqual(BridgeTool.named("task_status"), .taskStatus)
        XCTAssertEqual(BridgeTool.named("nook.task_cancel"), .taskCancel)
        XCTAssertEqual(BridgeTool.named("mcp__nook__orchestrator_capabilities"), .orchestratorCapabilities)
    }

    func testDelegateSchemaDescribesRolesAndRights() throws {
        let schema = try XCTUnwrap(BridgeTool.delegateTask.definition["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let role = try XCTUnwrap(properties["role"] as? [String: Any])
        XCTAssertEqual(role["enum"] as? [String], DelegationRole.allCases.map(\.rawValue))
        let rights = try XCTUnwrap(properties["rights"] as? [String: Any])
        XCTAssertEqual(rights["enum"] as? [String], PermissionPolicy.allCases.map(\.rawValue))
        XCTAssertEqual(schema["required"] as? [String], ["task"])
    }

    func testTimelineLabelsDelegation() {
        XCTAssertEqual(ToolSummary.describe(tool: "mcp__nook__delegate_task", input: ["task": "Review the diff"]),
                       "Delegate task · Review the diff")
    }
}
