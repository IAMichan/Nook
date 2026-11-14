import SwiftUI

/// The folder in a conversation's "mindlinq / title" header. A click opens the new-session composer on that folder (the
/// main checkout, not the agent's worktree), as the pencil next to the project in the session list does. A folder that is
/// not on this Mac (a session on another machine, a folder that was removed) stays plain text. Its context menu also starts
/// a session in the session's own worktree.
struct FolderCrumb: View {
    @EnvironmentObject private var app: AppModel
    let name: String
    /// The folder the session works in; resolved to the folder a new session starts in only on a click (it reads disk).
    let directory: String
    /// Where the session actually works when that is not `directory` (a Nook session in a worktree of its own).
    var workingDirectory: String? = nil
    /// False for a session on another machine: its folder is not one a session on this Mac can start in.
    var local = true
    @State private var hovering = false

    var body: some View {
        if local, !directory.isEmpty, !app.demoMode {
            Button(action: start) { label(hovering ? NookTheme.paper : NookTheme.textSecondary) }
                .buttonStyle(.nookPlain)
                .onHover { hovering = $0 }
                // A session in a worktree: another session can carry on in that same worktree and branch.
                // Read from disk only when the menu opens.
                .contextMenu {
                    Button(tr("inbox.project.newSession", name), action: start)
                    if WorktreeOrigin.checkoutPath(of: worktree) != worktree {
                        Button(tr("ws.new.inThisWorktree"), action: startInWorktree)
                    }
                }
                .help(tr("inbox.project.newSession", name))
                .accessibilityLabel(tr("inbox.project.newSession", name))
        } else {
            label(NookTheme.textSecondary).help(AgentPathFormat.tilde(directory))
        }
    }

    private func label(_ color: Color) -> some View {
        Text(name)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var worktree: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return directory }
        return workingDirectory
    }

    /// The new-session composer on this session's own worktree, working in it as it is.
    private func startInWorktree() {
        PromptLinkInbox.shared.requestProject(worktree, isolation: .folder)
        app.viewModel.selectedAgentID = "new"
    }

    private func start() {
        let settings = app.workspace.settings
        let known = settings.favoriteProjects + settings.recentProjects + [settings.lastProject]
        let folder = WorktreeOrigin.newSessionFolder(project: (name as NSString).lastPathComponent, paths: [directory], known: known)
            ?? WorktreeOrigin.checkoutPath(of: directory)
        PromptLinkInbox.shared.requestProject(folder)
        app.viewModel.selectedAgentID = "new"
    }
}
