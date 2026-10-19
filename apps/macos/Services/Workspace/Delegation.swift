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

    private static func rank(_ policy: PermissionPolicy) -> Int {
        switch policy {
        case .ask: return 0
        case .acceptEdits: return 1
        case .bypass: return 2
        }
    }

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

    /// What the child is told: the task and its role, nothing from the parent's conversation.
    static func prompt(task: String, role: DelegationRole) -> String {
        let clean = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = role.instruction
        return note.isEmpty ? clean : clean + "\n\n" + note
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
    }

    static let summaryLimit = 4_000

    static func state(_ status: RunStatus, hasPendingQuestion: Bool = false) -> State {
        switch status {
        case .preparing: return .queued
        case .running: return hasPendingQuestion ? .waiting : .running
        case .waitingApproval: return .waiting
        case .completed: return .completed
        case .failed: return .failed
        case .stopped: return .cancelled
        }
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
        object["summary"] = snapshot.summary ?? NSNull()
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? snapshot.state.rawValue
    }

    /// The message that wakes the parent when a child it did not wait for has finished.
    static func wakeMessage(_ snapshot: Snapshot) -> String {
        var text = "Delegated task \"\(snapshot.title)\" (\(snapshot.taskID)) \(snapshot.state.rawValue)."
        if let summary = snapshot.summary, !summary.isEmpty { text += "\n\nResult:\n" + summary }
        text += "\n\nUse task_status with this task id for details."
        return text
    }
}
