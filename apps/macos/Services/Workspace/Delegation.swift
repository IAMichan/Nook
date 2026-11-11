import Foundation

// Agents that start agents: a session hands a task to a child session through the workspace
// bridge, and gets the result back. The rules here keep that safe: a child never has more rights than its parent, the
// child sees only the task (not the parent's conversation), and the chain is bounded.
// Foundation only, so tests can use it independently.

/// What a delegated task is for. It only changes the instruction the child gets.
enum DelegationRole: String, Codable, CaseIterable, Sendable {
    case implementation, research, review, design, test, general

    /// A short instruction for the child, after the task itself.
    var instruction: String {
        switch self {
        case .implementation: return "Role: implementation. Make the change the task describes and keep it focused."
        case .research: return "Role: research. Investigate and report what you find; do not change files."
        case .review: return "Role: review. Read the work critically and list concrete problems; do not change files."
        case .design: return "Role: design. Propose an approach with its trade-offs; do not change files."
        case .test: return "Role: test. Write or run tests for the described behaviour and report the outcome."
        case .general: return ""
        }
    }

    /// Roles that only look: the child runs in Plan mode unless you say otherwise.
    var readOnly: Bool { self == .research || self == .review || self == .design }
}

/// The link from a child session to the session that delegated to it. Stored with the child.
struct DelegationLink: Codable, Equatable, Sendable {
    var parentID: UUID
    /// Makes a repeated call (same `client_request_id`) return the same child instead of starting a second one.
    var key: String
    /// 1 for a child of a session you started, 2 for its child, and so on.
    var depth: Int
    var role: DelegationRole
    /// Tell the parent when the child finishes (it did not wait for the result).
    var wake: Bool
    /// The parent has been told.
    var delivered = false
    /// The questions of the child its parent was told about (`deliverDelegatedQuestion`), each once.
    var toldQuestions: [String]? = nil
}

enum DelegationPolicy {
    /// How deep the chain may go: you → child → grandchild.
    static let maxDepth = 2
    /// Children running at the same time for one parent.
    static let maxActiveChildren = 4

    enum Denial: Error, Equatable, Sendable {
        /// The child asked for more than its parent has: "mode", "rights".
        case escalation(String)
        /// The target agent does not offer the rights that were asked for.
        case unsupported(PermissionPolicy)
        case tooDeep
        case tooManyChildren
        case notARun

        var message: String {
            switch self {
            case .escalation(let what):
                return "A delegated task cannot have broader \(what) than the session that delegates it."
            case .unsupported(let policy):
                return "That agent does not offer the rights \"\(policy.rawValue)\" without asking. Choose other rights or another agent."
            case .tooDeep:
                return "Delegated tasks can go \(DelegationPolicy.maxDepth) levels deep at most. Do this part yourself."
            case .tooManyChildren:
                return "Already \(DelegationPolicy.maxActiveChildren) delegated tasks are running. Wait for one to finish (task_status) before delegating more."
            case .notARun:
                return "Delegating works from a session that Nook runs. Start the work from Nook's Agents tab."
            }
        }
    }

    struct Rights: Equatable, Sendable {
        var mode: ExecutionMode
        var permission: PermissionPolicy
    }

    private static func rank(_ mode: ExecutionMode) -> Int { mode == .plan ? 0 : 1 }

    private static func rank(_ policy: PermissionPolicy) -> Int { policy.rank }

    /// The mode and rights of the child. Omitted values are inherited; asking for more than the parent has is refused; an
    /// inherited right the target agent does not offer steps down to the broadest one it does.
    /// A read-only role makes the child plan when the caller did not choose.
    static func resolve(parentMode: ExecutionMode, parentPermission: PermissionPolicy,
                        mode requestedMode: ExecutionMode?, permission requestedPermission: PermissionPolicy?,
                        role: DelegationRole, offered: [PermissionPolicy]) -> Result<Rights, Denial> {
        var mode = requestedMode ?? (role.readOnly ? .plan : parentMode)
        if rank(mode) > rank(parentMode) { return .failure(.escalation("mode")) }
        if parentMode == .plan { mode = .plan }

        var permission = requestedPermission ?? parentPermission
        if rank(permission) > rank(parentPermission) { return .failure(.escalation("rights")) }
        if !offered.contains(permission) {
            if requestedPermission != nil { return .failure(.unsupported(permission)) }
            let stepDown = offered.filter { rank($0) <= rank(permission) }.max { rank($0) < rank($1) }
            guard let stepDown else { return .failure(.unsupported(permission)) }
            permission = stepDown
        }
        return .success(Rights(mode: mode, permission: permission))
    }

    /// May this parent delegate another task right now?
    static func admit(parentDepth: Int, activeChildren: Int) -> Denial? {
        if parentDepth >= maxDepth { return .tooDeep }
        if activeChildren >= maxActiveChildren { return .tooManyChildren }
        return nil
    }

    /// Where a child works when the parent asks for `isolation` (`shared`, `worktree`) or leaves it to Nook.
    enum Placement: Equatable, Sendable {
        /// In the parent's folder, seeing (and changing) the same files.
        case shared
        /// In a worktree of its own, on a branch from the parent's branch: the parent merges it when it is done.
        case worktree
    }

    enum PlacementDenial: Error, Equatable, Sendable {
        case notARepository
        case unknown(String)

        var message: String {
            switch self {
            case .notARepository: return "A task gets a worktree of its own only in a git repository; this folder is not one. Use isolation: shared."
            case .unknown(let value): return "isolation must be shared or worktree, not \"\(value)\"."
            }
        }
    }

    /// Two agents that change the same files at once overwrite each other's work. A task that only looks (Plan mode)
    /// always shares the folder. One that may change files gets a worktree of its own when another such task of the same
    /// parent is already working in that folder, unless the parent chose; outside a git repository it can only share.
    static func placement(requested: String?, mode: ExecutionMode, writingSiblingsInFolder: Int,
                          inRepository: Bool) -> Result<Placement, PlacementDenial> {
        let choice = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch choice {
        case "shared":
            return .success(.shared)
        case "worktree":
            guard inRepository else { return .failure(.notARepository) }
            return .success(mode == .plan ? .shared : .worktree)
        case "":
            guard mode == .agent, inRepository, writingSiblingsInFolder > 0 else { return .success(.shared) }
            return .success(.worktree)
        default:
            return .failure(.unknown(choice))
        }
    }

    /// What every child is told after its brief: do the work itself (: "If you are a subagent or child, do the work
    /// yourself"), so a chain of sessions does not grow by itself, and end with the report its parent reads.
    static let childNote = "You are a task delegated from another session in Nook. Do the work yourself; start no subtasks unless this brief asks for them. End with a short report of what you did and found: it is all the other session sees."

    /// What the child is told: the task and its role, nothing from the parent's conversation.
    static func prompt(task: String, role: DelegationRole) -> String {
        let clean = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return [clean, role.instruction, childNote].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A delegated task as the parent sees it.
enum DelegatedTask {
    enum State: String, Equatable, Sendable {
        case queued, running, waiting, completed, failed, cancelled

        var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }

    struct Snapshot: Equatable, Sendable {
        var taskID: String
        var title: String
        var state: State
        var summary: String?
        var hasPendingQuestion: Bool
        var model: String?
        var provider: String
        /// For a task in a worktree of its own: where it works and on which branch, so the parent can merge it.
        var worktree: String? = nil
        var branch: String? = nil
    }

    static let summaryLimit = 4_000

    /// `hasQueuedWork`: a message still waits to go out to the task (not held after a failure or a stop). The task is not
    /// done until it went (: a follow-up waits for a run its child queued on its own thread).
    static func state(_ status: RunStatus, hasPendingQuestion: Bool = false, hasQueuedWork: Bool = false) -> State {
        if hasQueuedWork, !status.isActive { return .running }
        switch status {
        case .preparing: return .queued
        case .running: return hasPendingQuestion ? .waiting : .running
        case .waitingApproval: return .waiting
        case .completed: return .completed
        case .failed: return .failed
        case .stopped: return .cancelled
        }
    }

    /// Whether the parent hears of a finished task now: it ended (well or not) and nothing it still has to do waits in its
    /// queue. A task with work queued reports after that work, so its parent never reads a result that is not the last.
    static func mayDeliver(_ status: RunStatus, hasQueuedWork: Bool) -> Bool {
        (status == .completed || status == .failed) && !hasQueuedWork
    }

    /// Where a message to a session comes from, by the session that sent it (`session_send`); nil for you, Nook, or a
    /// client without a session of its own (the command line, an MCP client). A task's own parent counts as you. As
    /// does, only a message from an unrelated session leaves the parent out of the turn it starts, and a message
    /// from a task this session delegated carries on the session's own work.
    static func origin(sender: UUID?, senderParent: UUID?, target: UUID, targetParent: UUID?) -> QueuedMessage.Origin? {
        guard let sender, sender != targetParent else { return nil }
        return senderParent == target ? .child : .agent
    }

    /// The result of a task: what the child said last, or why it failed (the error before any progress text).
    static func summary(status: RunStatus, statusDetail: String?, events: [RunEvent]) -> String? {
        if status == .failed {
            let error = events.last { $0.kind == .error }?.text ?? statusDetail
            if let error, !error.isEmpty { return RunEvent.clip(error, summaryLimit) }
        }
        guard let last = events.last(where: { $0.kind == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return RunEvent.clip(last.text.trimmingCharacters(in: .whitespacesAndNewlines), summaryLimit)
    }

    /// The tool result: plain JSON the agent can read.
    static func render(_ snapshot: Snapshot, waitTimedOut: Bool = false) -> String {
        var object: [String: Any] = [
            "taskId": snapshot.taskID,
            "title": snapshot.title,
            "status": snapshot.state.rawValue,
            "agent": snapshot.provider,
            "hasPendingQuestion": snapshot.hasPendingQuestion,
            "waitTimedOut": waitTimedOut
        ]
        if let model = snapshot.model, !model.isEmpty { object["model"] = model }
        if let worktree = snapshot.worktree, !worktree.isEmpty {
            object["worktree"] = worktree
            if let branch = snapshot.branch, !branch.isEmpty {
                object["branch"] = branch
                object["merge"] = "Its changes are on branch \(branch), not in your folder: review them, then merge that branch (git merge \(branch)) once it has committed."
            }
        }
        object["summary"] = snapshot.summary ?? NSNull()
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? snapshot.state.rawValue
    }

    /// How `task_wait` waits on several tasks: until one of them, or all of them, can go no further without the
    /// parent (finished, or asking a question).
    enum WaitMode: String, CaseIterable, Sendable { case any, all }

    static func isSettled(_ snapshot: Snapshot) -> Bool { snapshot.state.isTerminal || snapshot.hasPendingQuestion }

    static func waitIsOver(_ snapshots: [Snapshot], mode: WaitMode) -> Bool {
        guard !snapshots.isEmpty else { return true }
        switch mode {
        case .any: return snapshots.contains(where: isSettled)
        case .all: return snapshots.allSatisfy(isSettled)
        }
    }

    /// The `task_wait` result: every task's state, and whether the wait ran out first.
    static func renderWait(_ snapshots: [Snapshot], waitTimedOut: Bool) -> String {
        let tasks: [Any] = snapshots.compactMap { snapshot in
            (try? JSONSerialization.jsonObject(with: Data(render(snapshot).utf8))).map { object -> Any in
                var task = object as? [String: Any] ?? [:]
                task["waitTimedOut"] = nil
                return task
            }
        }
        let object: [String: Any] = ["tasks": tasks, "waitTimedOut": waitTimedOut,
                                     "settled": snapshots.filter(isSettled).map(\.taskID)]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The `session_wait` result: the same as `task_wait`'s, named for sessions (`sessionId`, `sessions`).
    static func renderSessionWait(_ snapshots: [Snapshot], waitTimedOut: Bool) -> String {
        let sessions: [Any] = snapshots.compactMap { snapshot in
            (try? JSONSerialization.jsonObject(with: Data(render(snapshot).utf8))).map { object -> Any in
                var session = object as? [String: Any] ?? [:]
                session["waitTimedOut"] = nil
                session["sessionId"] = session.removeValue(forKey: "taskId")
                // A session you did not delegate: its branch is not yours to merge.
                session["merge"] = nil
                return session
            }
        }
        let object: [String: Any] = ["sessions": sessions, "waitTimedOut": waitTimedOut,
                                     "settled": snapshots.filter(isSettled).map(\.taskID)]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The message that wakes the parent when a child it did not wait for has finished.
    /// How many sub-threads still work for a session, at every level (a sub-thread's own sub-threads count too): while
    /// any does, the session reads as busy everywhere, also after its own turn ended (`AgentAttention.Input`).
    /// `parents` maps a session to the one that delegated it; `active` holds the sessions whose turn runs.
    static func workingSubThreads(of parent: UUID, parents: [UUID: UUID], active: Set<UUID>) -> Int {
        var children: [UUID: [UUID]] = [:]
        for (child, of) in parents where child != of { children[of, default: []].append(child) }
        var seen: Set<UUID> = [parent]
        var queue = children[parent] ?? []
        var working = 0
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            if active.contains(next) { working += 1 }
            queue += children[next] ?? []
        }
        return working
    }

    /// The same, read from the sessions themselves: the delegation link of each and whether its turn runs.
    static func workingSubThreads(of parent: UUID, in runs: [WorkspaceRun]) -> Int {
        var parents: [UUID: UUID] = [:]
        var active: Set<UUID> = []
        for run in runs where !run.archived {
            guard let link = run.delegation else { continue }
            parents[run.id] = link.parentID
            if run.status.isActive { active.insert(run.id) }
        }
        guard parents.values.contains(parent) else { return 0 }
        return workingSubThreads(of: parent, parents: parents, active: active)
    }

    /// Which of a session's tasks its sub-thread strip shows (`SubThreadStrip`): every one at work or asking, and the ones
    /// that ended after `since` (your last message there). Oldest first, the order you started them in.
    static func shown(_ children: [WorkspaceRun], asking: (UUID) -> Bool, since: Date) -> [WorkspaceRun] {
        children.filter { $0.status.isActive || asking($0.id) || $0.updatedAt > since }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Everything the parent needs is in it, so it has no reason to call `task_status` again.
    static func wakeMessage(_ snapshot: Snapshot) -> String {
        var text = "Delegated task \"\(snapshot.title)\" (\(snapshot.taskID)) \(snapshot.state.rawValue)."
        if let summary = snapshot.summary, !summary.isEmpty { text += "\n\nResult:\n" + summary }
        if let branch = snapshot.branch, !branch.isEmpty {
            text += "\n\nIts changes are on branch \(branch), not in your folder: review them, then merge that branch (git merge \(branch)) once it has committed."
        }
        return text
    }

    /// The message that tells a parent that did not wait that its task asks something (routes a child's question to
    /// its parent, because nobody watches a child): the parent answers it or asks the user.
    static func questionMessage(_ snapshot: Snapshot, questionID: String, question: String) -> String {
        var text = "Delegated task \"\(snapshot.title)\" (\(snapshot.taskID)) asks a question and waits for the answer."
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { text += "\n\nQuestion:\n" + RunEvent.clip(clean, 1_000) }
        text += "\n\nAnswer it with session_questions (action answer, session_id \(snapshot.taskID), question_id \(questionID)) when you can, or ask the user. If it is no longer open, carry on."
        return text
    }
}

/// "Main thread": a session that hands its work to delegated tasks (sub-threads) and keeps its own context small, the
/// way orchestrator thread works with `delegate_task`. You switch it on in the composer; the agent learns of it
/// with your next message, in the hidden part (`<nook_context>`) so your bubble stays yours. Its system prompt does not
/// change, so the prompt cache stays warm.
enum MainThread {
    static let note = "Nook: this session is the main thread. Keep your own context small: hand each self-contained piece of work (research, an implementation step, a review, tests) to delegate_task with a complete brief, start independent tasks together, and do only small edits and the final check yourself. Do not poll: each result comes back to you as a message when its task ends (task_wait only when you need results before you can go on). Answer questions your tasks ask, then combine their reports into one answer for the user."
    static let offNote = "Nook: this session is no longer the main thread. Do the work yourself again; delegate only when it clearly helps."

    /// The note for your next message: nil when the agent already knows the current state.
    static func pending(on: Bool?, told: Bool?) -> String? {
        let on = on ?? false
        guard on != (told ?? false) else { return nil }
        return on ? note : offNote
    }

    /// What a new session's agent knows from its first message: the note goes with the task, and an idle start has none.
    static func toldAtStart(_ config: NewRunConfig) -> Bool? {
        config.mainThread == true && !config.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? true : nil
    }

    /// The note added to the hidden part of a message, after its references (`ContextRefs.project`).
    static func attach(_ note: String, to text: String) -> String {
        let record = "<mode id=\"main-thread\">\n" + ContextRefs.escape(note) + "\n</mode>"
        let open = "\n\n<nook_context>\n", close = "\n</nook_context>"
        if let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
            var result = text
            result.insert(contentsOf: "\n" + record, at: end.lowerBound)
            return result
        }
        return text + open + record + close
    }

    /// Only for an agent that may delegate (Settings › Automation › Tools per agent).
    static func offered(provider: RunProvider, access: BridgeAccess) -> Bool {
        access.isOn(.delegation, agent: provider.rawValue)
    }
}
