import Foundation

/// The user's agent sessions as text, for whoever asks about them: another agent through the bridge (`session_list`,
/// `session_read`) and Nook Chat (`list_agent_sessions`, `read_agent_session`). One description, so both see the same.
extension WorkspaceManager {
    /// One line per session that is not archived, most recent first: id, title, agent, status, folder and branch.
    func sessionLines(limit: Int) -> [String] {
        runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit)).map { run in
            "- \(run.id.uuidString) · \(run.title) · \(run.provider.displayName) · \(DelegatedTask.state(run.status).rawValue) · \(run.workingDirectory)"
                + (run.branch.map { " · \($0)" } ?? "")
        }
    }

    /// A summary of one session: what was asked, answered, run and changed, bounded, never the raw conversation (the same
    /// summary a handoff uses). Nil when there is no such session.
    func sessionSummary(_ id: UUID) -> String? {
        guard let run = run(id) else { return nil }
        loadTimeline(id)
        var lines = ["# Session: \(run.title)", "Id: \(run.id.uuidString)",
                     "Agent: \(run.provider.displayName) · status: \(DelegatedTask.state(run.status).rawValue)",
                     "Folder: \(run.workingDirectory)"]
        if let branch = run.branch { lines.append("Branch: \(branch)") }
        lines.append("")
        if let summary = ContextHandoff.render(events: timeline(id), source: run.provider.displayName) {
            lines.append(summary.text)
        } else {
            lines.append("Nothing has happened in this session yet.")
        }
        return lines.joined(separator: "\n")
    }
}
