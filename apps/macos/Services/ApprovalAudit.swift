import Foundation

/// Where a decision on an approval was made, for the action log.
enum ApprovalSource: String, Sendable {
    /// In Nook: the notch card, the session view or the Agents list.
    case app
    /// The buttons of a macOS notification.
    case notification
    /// The iPhone companion.
    case phone
}

/// The action log's entries for approvals (`audit` in `nook.sqlite`): who asked, for what, what was decided and where.
/// Every agent's requests are logged the same way, whichever way they reached Nook.
enum ApprovalAudit {
    static let tool = "agent_approval"
    /// What the log keeps of the request itself.
    static let limit = 400

    static func entry(agent: String, project: String, tool requested: String, asked: String, decision: String,
                      source: ApprovalSource?, danger: Bool) -> (tool: String, args: String, result: String) {
        let shown = asked.count > limit ? String(asked.prefix(limit)) + "…" : asked
        let args = [agent, project, requested, shown].filter { !$0.isEmpty }.joined(separator: " · ")
        let result = [decision, source?.rawValue ?? "", danger ? "danger" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return (tool, args, result)
    }

    /// A request nobody decided in time: the agent was refused.
    static func expired(agent: String, project: String, tool requested: String, asked: String) -> (tool: String, args: String, result: String) {
        entry(agent: agent, project: project, tool: requested, asked: asked, decision: "expired", source: nil, danger: false)
    }
}
