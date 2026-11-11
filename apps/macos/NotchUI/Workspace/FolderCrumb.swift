import SwiftUI

/// The folder in a conversation's "mindlinq / title" header. A click opens the new-session composer on that folder (the
/// main checkout, not the agent's worktree), as the pencil next to the project in the session list does. A folder that is
/// not on this Mac (a session on another machine, a folder that was removed) stays plain text.
struct FolderCrumb: View {
    @EnvironmentObject private var app: AppModel
    let name: String
    /// The folder the session works in; resolved to the folder a new session starts in only on a click (it reads disk).
    let directory: String
    /// False for a session on another machine: its folder is not one a session on this Mac can start in.
    var local = true
    @State private var hovering = false

    var body: some View {
        if local, !directory.isEmpty, !app.demoMode {
            Button(action: start) { label(hovering ? NookTheme.paper : NookTheme.textSecondary) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
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

    private func start() {
        let settings = app.workspace.settings
        let known = settings.favoriteProjects + settings.recentProjects + [settings.lastProject]
        let folder = WorktreeOrigin.newSessionFolder(project: (name as NSString).lastPathComponent, paths: [directory], known: known)
            ?? WorktreeOrigin.checkoutPath(of: directory)
        PromptLinkInbox.shared.requestProject(folder)
        app.viewModel.selectedAgentID = "new"
    }
}
