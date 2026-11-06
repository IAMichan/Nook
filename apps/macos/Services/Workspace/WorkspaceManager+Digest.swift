import Foundation

/// The user's agent sessions as text, for whoever asks about them: another agent through the bridge (`session_list`,
/// `session_read`) and Nook Chat (`list_agent_sessions`, `read_agent_session`). One description, so both see the same.
extension WorkspaceManager {
    /// One line per session that is not archived, most recent first: id, title, agent, status, folder and branch.
    func sessionLines(limit: Int) -> [String] {
        runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit)).map { "- " + sessionLine($0) }
    }

    /// One session in a line: id, title, agent, status, folder and branch (`session_list`, `session_search`).
    func sessionLine(_ run: WorkspaceRun) -> String {
        "\(run.id.uuidString) · \(run.title) · \(run.provider.displayName) · \(DelegatedTask.state(run.status).rawValue) · \(run.workingDirectory)"
            + (run.branch.map { " · \($0)" } ?? "") + (run.archived ? " · archived" : "")
    }

    /// A summary of one session: what was asked, answered, run and changed, bounded, never the raw conversation (the same
    /// summary a handoff uses). Nil when there is no such session.
    func sessionSummary(_ id: UUID, beforeEvent: Int? = nil) -> String? {
        guard let run = run(id) else { return nil }
        loadTimeline(id)
        var lines = ["# Session: \(run.title)", "Id: \(run.id.uuidString)",
                     "Agent: \(run.provider.displayName) · status: \(DelegatedTask.state(run.status).rawValue)",
                     "Folder: \(run.workingDirectory)"]
        if let branch = run.branch { lines.append("Branch: \(branch)") }
        lines.append("")
        let all = timeline(id)
        // Paging back: one window of older events, for what a handoff left out.
        let end = min(beforeEvent ?? all.count, all.count)
        let start = beforeEvent == nil ? 0 : max(0, end - ContextHandoff.pageEvents)
        if let summary = ContextHandoff.render(events: Array(all[start..<max(start, end)]), source: run.provider.displayName) {
            lines.append(summary.text)
            if beforeEvent != nil, start > 0 { lines.append("Older events: session_read with before_event \(start).") }
        } else {
            lines.append("Nothing has happened in this session yet.")
        }
        return lines.joined(separator: "\n")
    }
}
