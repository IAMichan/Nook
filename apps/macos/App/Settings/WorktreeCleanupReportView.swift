import SwiftUI

/// The latest worktree cleanup in Settings › Workspace: when it ran and what it did with each worktree a rule applied to
/// (removed, kept and why, or failed), the folders in Nook's worktree folder no session uses (only listed, never
/// removed), and "Clean up now".
struct WorktreeCleanupReportView: View {
    @ObservedObject var workspace: WorkspaceManager

    var body: some View {
        let report = workspace.worktreeCleanupReport
        LabeledContent {
            Button(tr("settings.ws.cleanupNow")) { workspace.cleanUpWorktreesNow() }
                .controlSize(.small)
                .disabled(workspace.worktreeCleanupRunning)
        } label: {
            SettingLabel(tr("settings.ws.cleanupReport"), detail: summary(report))
        }
        if let report {
            ForEach(report.entries) { entry in
                StatusRow(title: entry.title ?? AgentPathFormat.tilde(entry.path), detail: detail(entry), state: state(entry.outcome)) {
                    EmptyView()
                }
                .help(AgentPathFormat.tilde(entry.path))
            }
            if !report.orphans.isEmpty {
                SettingLabel(tr("settings.ws.cleanupReport.orphans"), hint: tr("settings.ws.cleanupReport.orphans.help"))
                ForEach(report.orphans) { orphan in
                    StatusRow(title: AgentPathFormat.tilde(orphan.path), detail: orphan.bytes.map(DiskUsage.format) ?? "",
                              state: .todo) {
                        Button(tr("shelf.showInFinder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: orphan.path)])
                        }
                    }
                }
            }
        }
    }

    private func summary(_ report: WorktreeCleanupReport?) -> String {
        guard let report else { return tr("settings.ws.cleanupReport.never") }
        var parts = [report.finishedAt.formatted(.relative(presentation: .named))]
        if report.entries.isEmpty {
            parts.append(tr("settings.ws.cleanupReport.empty"))
        } else {
            parts.append(tr("settings.ws.cleanupReport.summary", report.count(.removed), report.count(.kept), report.count(.failed)))
        }
        if report.bytesFreed > 0 { parts.append(tr("settings.ws.cleanupReport.freed", DiskUsage.format(report.bytesFreed))) }
        return parts.joined(separator: " · ")
    }

    private func detail(_ entry: WorktreeCleanupReport.Entry) -> String {
        // A failure carries git's own words; the others a reason Nook names.
        let reason = entry.outcome == .failed ? entry.reason : tr("ws.cleanup.reason." + entry.reason)
        var parts = [tr("ws.cleanup.outcome." + entry.outcome.rawValue), reason]
        if entry.outcome == .removed, let bytes = entry.bytes { parts.append(DiskUsage.format(bytes)) }
        return parts.joined(separator: " · ")
    }

    private func state(_ outcome: WorktreeCleanupReport.Outcome) -> StatusState {
        switch outcome {
        case .removed: return .done
        case .kept: return .todo
        case .failed: return .error
        }
    }
}
