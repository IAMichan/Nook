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
        XCTAssertEqual(DelegationPolicy.prompt(task: "  Fix the login bug \n", role: .general),
                       "Fix the login bug\n\n" + DelegationPolicy.childNote)
        let review = DelegationPolicy.prompt(task: "Check the diff", role: .review)
        XCTAssertTrue(review.hasPrefix("Check the diff"))
        XCTAssertTrue(review.contains("Role: review"))
        XCTAssertTrue(review.hasSuffix(DelegationPolicy.childNote), "a child does the work itself and ends with a report")
    }

    // MARK: Main thread

    func testMainThreadNoteGoesOnceForEachChange() {
        XCTAssertNil(MainThread.pending(on: nil, told: nil))
        XCTAssertNil(MainThread.pending(on: false, told: nil), "off is what an agent assumes")
        XCTAssertEqual(MainThread.pending(on: true, told: nil), MainThread.note)
        XCTAssertNil(MainThread.pending(on: true, told: true))
        XCTAssertEqual(MainThread.pending(on: nil, told: true), MainThread.offNote)
    }

    func testMainThreadNoteStaysOutOfYourBubble() {
        let plain = MainThread.attach(MainThread.note, to: "Build the login page")
        XCTAssertEqual(ContextRefs.visible(plain), "Build the login page")
        XCTAssertTrue(plain.contains("delegate_task"))
        let withRefs = ContextRefs.project("Look at [Login.swift](nook-context://v1/file/Login.swift)")
        let both = MainThread.attach(MainThread.note, to: withRefs)
        XCTAssertEqual(both.components(separatedBy: "<nook_context>").count, 2, "one envelope")
        XCTAssertEqual(ContextRefs.visible(both), ContextRefs.visible(withRefs))
        XCTAssertTrue(both.contains("<mode id=\"main-thread\">"))
    }

    func testMainThreadIsKnownFromTheFirstMessageOnly() {
        var config = NewRunConfig()
        config.mainThread = true
        XCTAssertNil(MainThread.toldAtStart(config), "an idle start has no message yet")
        config.task = "Do it"
        XCTAssertEqual(MainThread.toldAtStart(config), true)
        config.mainThread = nil
        XCTAssertNil(MainThread.toldAtStart(config))
    }

    func testMainThreadOnlyForAgentsThatMayDelegate() {
        var access = BridgeAccess()
        XCTAssertTrue(MainThread.offered(provider: .codex, access: access))
        access.set(.delegation, on: false, agent: RunProvider.codex.rawValue)
        XCTAssertFalse(MainThread.offered(provider: .codex, access: access))
        XCTAssertTrue(MainThread.offered(provider: .claude, access: access))
    }

    func testSubThreadStripKeepsEndedTasksUntilYourNextMessage() {
        let since = Date(timeIntervalSince1970: 1_000)
        func child(_ status: RunStatus, updated: TimeInterval, created: TimeInterval) -> WorkspaceRun {
            var run = TestData.run(status: status)
            run.updatedAt = Date(timeIntervalSince1970: updated)
            run.createdAt = Date(timeIntervalSince1970: created)
            return run
        }
        let working = child(.running, updated: 10, created: 3)
        let endedBefore = child(.completed, updated: 900, created: 1)
        let endedAfter = child(.failed, updated: 1_100, created: 2)
        let asking = child(.completed, updated: 10, created: 4)
        let shown = DelegatedTask.shown([working, endedBefore, endedAfter, asking], asking: { $0 == asking.id }, since: since)
        XCTAssertEqual(shown.map(\.id), [endedAfter.id, working.id, asking.id], "in the order they started; seen ones go")
    }

    func testQuestionMessageNamesWhatToAnswerWith() {
        let snapshot = DelegatedTask.Snapshot(taskID: "abc", title: "Fix", state: .waiting, summary: nil,
                                              hasPendingQuestion: true, model: nil, provider: "Codex")
        let text = DelegatedTask.questionMessage(snapshot, questionID: "q1", question: "Which branch?")
        XCTAssertTrue(text.contains("Which branch?"))
        XCTAssertTrue(text.contains("session_questions"))
        XCTAssertTrue(text.contains("session_id abc"))
        XCTAssertTrue(text.contains("question_id q1"))
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

    func testATaskWithWorkInItsQueueIsNotDoneYet() {
        //: a follow-up waits for a run its child queued on its own thread.
        XCTAssertEqual(DelegatedTask.state(.completed, hasQueuedWork: true), .running)
        XCTAssertEqual(DelegatedTask.state(.stopped, hasQueuedWork: true), .running, "a restart goes out right after its stop")
        XCTAssertEqual(DelegatedTask.state(.running, hasPendingQuestion: true, hasQueuedWork: true), .waiting)
        XCTAssertFalse(DelegatedTask.mayDeliver(.completed, hasQueuedWork: true))
        XCTAssertTrue(DelegatedTask.mayDeliver(.completed, hasQueuedWork: false))
        XCTAssertTrue(DelegatedTask.mayDeliver(.failed, hasQueuedWork: false))
        XCTAssertFalse(DelegatedTask.mayDeliver(.running, hasQueuedWork: false))
        XCTAssertFalse(DelegatedTask.mayDeliver(.stopped, hasQueuedWork: false))
    }

    func testOnlyAnUnrelatedSessionLeavesTheParentOutOfAFollowUp() {
        let parent = UUID(), child = UUID(), other = UUID()
        // You, a client without a session of its own, and the task's own parent: the parent hears of the new turn.
        XCTAssertNil(DelegatedTask.origin(sender: nil, senderParent: nil, target: child, targetParent: parent))
        XCTAssertNil(DelegatedTask.origin(sender: parent, senderParent: nil, target: child, targetParent: parent))
        XCTAssertTrue(QueuedMessage.Origin.rearmsParent(nil))
        XCTAssertTrue(QueuedMessage.Origin.rearmsParent(.notice), "Nook's notice of the task's own work counts too")
        // Another agent's session does not.
        XCTAssertEqual(DelegatedTask.origin(sender: other, senderParent: nil, target: child, targetParent: parent), .agent)
        XCTAssertFalse(QueuedMessage.Origin.rearmsParent(.agent))
        // A task writing to the session that delegated it carries on that session's work.
        XCTAssertEqual(DelegatedTask.origin(sender: child, senderParent: parent, target: parent, targetParent: nil), .child)
        XCTAssertFalse(QueuedMessage.Origin.rearmsParent(.child))
        XCTAssertTrue(QueuedMessage.Origin.continuesWork(.child))
        XCTAssertTrue(QueuedMessage.Origin.continuesWork(.notice))
        XCTAssertFalse(QueuedMessage.Origin.continuesWork(.agent))
        XCTAssertFalse(QueuedMessage.Origin.continuesWork(nil))
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
        XCTAssertFalse(text.contains("task_status"), "the message has it all: no call to make")
        var branched = snapshot
        branched.branch = "nook/fix"
        XCTAssertTrue(DelegatedTask.wakeMessage(branched).contains("git merge nook/fix"))
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
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionRead, caller: caller(.plan)), .allow, "reading a session changes nothing")
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

    func testWaitingOnSeveralTasks() {
        func snap(_ id: String, _ state: DelegatedTask.State, question: Bool = false) -> DelegatedTask.Snapshot {
            DelegatedTask.Snapshot(taskID: id, title: id, state: state, summary: nil, hasPendingQuestion: question, model: nil, provider: "Codex")
        }
        let running = [snap("a", .running), snap("b", .queued)]
        XCTAssertFalse(DelegatedTask.waitIsOver(running, mode: .any))
        XCTAssertTrue(DelegatedTask.waitIsOver([snap("a", .running), snap("b", .completed)], mode: .any))
        XCTAssertFalse(DelegatedTask.waitIsOver([snap("a", .running), snap("b", .completed)], mode: .all))
        XCTAssertTrue(DelegatedTask.waitIsOver([snap("a", .running, question: true), snap("b", .failed)], mode: .all))
        let text = DelegatedTask.renderWait([snap("a", .completed), snap("b", .running)], waitTimedOut: true)
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(object?["settled"] as? [String], ["a"])
        XCTAssertEqual(object?["waitTimedOut"] as? Bool, true)
        XCTAssertEqual((object?["tasks"] as? [Any])?.count, 2)
        XCTAssertEqual(BridgeTool.named("mcp__nook__task_wait"), .taskWait)
        XCTAssertEqual(BridgeTool.taskWait.effect, .read)
        // session_wait: the same answer, named for sessions, with no branch to merge (you did not delegate them).
        var worktree = snap("c", .completed)
        worktree.worktree = "/wt"
        worktree.branch = "nook/c"
        let sessions = DelegatedTask.renderSessionWait([worktree, snap("d", .running)], waitTimedOut: false)
        let read = try? JSONSerialization.jsonObject(with: Data(sessions.utf8)) as? [String: Any]
        let first = (read?["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["sessionId"] as? String, "c")
        XCTAssertNil(first?["taskId"])
        XCTAssertNil(first?["merge"])
        XCTAssertEqual(first?["branch"] as? String, "nook/c")
        XCTAssertEqual(read?["settled"] as? [String], ["c"])
    }

    // MARK: Placement

    func testASecondWriterGetsAWorktreeOfItsOwn() {
        func place(_ requested: String?, _ mode: ExecutionMode = .agent, siblings: Int, repo: Bool = true)
            -> Result<DelegationPolicy.Placement, DelegationPolicy.PlacementDenial> {
            DelegationPolicy.placement(requested: requested, mode: mode, writingSiblingsInFolder: siblings, inRepository: repo)
        }
        XCTAssertEqual(place(nil, siblings: 0), .success(.shared), "the first task shares the folder, as before")
        XCTAssertEqual(place(nil, siblings: 1), .success(.worktree), "a second writer would overwrite the first")
        XCTAssertEqual(place(nil, .plan, siblings: 3), .success(.shared), "a task that only looks never needs one")
        XCTAssertEqual(place(nil, siblings: 2, repo: false), .success(.shared), "outside git there is no worktree to make")
        XCTAssertEqual(place("shared", siblings: 2), .success(.shared), "the parent's own choice counts")
        XCTAssertEqual(place("worktree", siblings: 0), .success(.worktree))
        XCTAssertEqual(place("Worktree", .plan, siblings: 0), .success(.shared))
        XCTAssertEqual(place("worktree", siblings: 0, repo: false), .failure(.notARepository))
        XCTAssertEqual(place("sandbox", siblings: 0), .failure(.unknown("sandbox")))
    }

    func testAWorktreeTaskTellsItsParentWhichBranchToMerge() throws {
        var snapshot = DelegatedTask.Snapshot(taskID: "t1", title: "Fix", state: .completed, summary: "Done",
                                              hasPendingQuestion: false, model: nil, provider: "Codex")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DelegatedTask.render(snapshot).utf8)) as? [String: Any])
        XCTAssertNil(object["branch"], "a shared task's changes are already in the parent's folder")
        snapshot.worktree = "/Users/x/.nook/worktrees/app/fix"
        snapshot.branch = "nook/fix"
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DelegatedTask.render(snapshot).utf8)) as? [String: Any])
        XCTAssertEqual(object["branch"] as? String, "nook/fix")
        XCTAssertEqual(object["worktree"] as? String, "/Users/x/.nook/worktrees/app/fix")
        XCTAssertTrue((object["merge"] as? String)?.contains("git merge nook/fix") == true)
    }

    // MARK: Busy through sub-threads

    func testWorkingSubThreadsCountEveryLevelAndNothingElse() {
        let parent = UUID(), child = UUID(), grandchild = UUID(), done = UUID(), stranger = UUID(), other = UUID()
        let parents = [child: parent, grandchild: child, done: parent, stranger: other]
        XCTAssertEqual(DelegatedTask.workingSubThreads(of: parent, parents: parents, active: [child, grandchild, stranger]), 2)
        // A sub-thread that finished still counts its own working sub-thread.
        XCTAssertEqual(DelegatedTask.workingSubThreads(of: parent, parents: parents, active: [grandchild]), 1)
        XCTAssertEqual(DelegatedTask.workingSubThreads(of: parent, parents: parents, active: []), 0)
        XCTAssertEqual(DelegatedTask.workingSubThreads(of: child, parents: parents, active: [child, grandchild]), 1)
    }

    func testWorkingSubThreadsSurviveALoop() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(DelegatedTask.workingSubThreads(of: a, parents: [a: b, b: a], active: [a, b]), 1)
    }

    func testIdleParentWithAWorkingSubThreadIsBusyAndQuietOnceTheyAreDone() {
        var input = AgentAttention.Input(status: .completed, unseen: true, subThreadsWorking: 2)
        XCTAssertEqual(AgentAttention.resolve(input), .working)
        input.subThreadsWorking = 0
        XCTAssertEqual(AgentAttention.resolve(input), .ready)
        input.unseen = false
        XCTAssertEqual(AgentAttention.resolve(input), .idle)
        // What waits for you, a failure and your own settle still win.
        XCTAssertEqual(AgentAttention.resolve(AgentAttention.Input(status: .completed, pendingApprovals: 1, subThreadsWorking: 1)), .approval)
        XCTAssertEqual(AgentAttention.resolve(AgentAttention.Input(status: .failed, subThreadsWorking: 1)), .failed)
        XCTAssertEqual(AgentAttention.resolve(AgentAttention.Input(status: .completed, settled: true, subThreadsWorking: 1)), .finished)
    }
}
