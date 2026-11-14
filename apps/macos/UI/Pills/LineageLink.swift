import SwiftUI

/// "Forked from Fix the login" in a session's header: where a fork (or a later model of a comparison) came from, as a
/// link that opens that session. A parent that was deleted says so and leads nowhere.
struct LineageLink: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    let lineage: RunLineage
    @State private var hovering = false

    var body: some View {
        let parent = workspace.run(lineage.parentID)
        Button {
            guard let parent else { return }
            // An archived parent comes back into the list, so the link always lands on a row.
            if parent.archived { workspace.setArchived(parent.id, false) }
            app.viewModel.selectedAgentID = "run:" + parent.id.uuidString
        } label: {
            Label(tr(lineage.labelKey, parent?.title ?? tr("lineage.deleted")), icon: lineage.symbol)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(parent != nil && hovering ? NookTheme.blue : NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.nookPlain)
        .disabled(parent == nil)
        .onHover { hovering = $0 }
        .help(parent == nil ? tr("lineage.deleted") : tr("lineage.open"))
    }
}

/// "Started by an agent in Fix the login" in a session's header: the session that launched this one from its shell
/// (`LaunchedSessions`), as a link that opens it. Without it an agent's test run reads as a chat you never started.
struct LauncherLink: View {
    @EnvironmentObject private var app: AppModel
    let launcher: SessionLauncher
    @State private var hovering = false

    var body: some View {
        Button {
            // An archived launcher comes back into the list, so the link always lands on a row.
            if launcher.target.hasPrefix("run:"), let id = UUID(uuidString: String(launcher.target.dropFirst(4))),
               app.workspace.run(id)?.archived == true {
                app.workspace.setArchived(id, false)
            }
            app.viewModel.selectedAgentID = launcher.target
        } label: {
            Label(tr("launched.by", launcher.title), icon: "terminal")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(hovering ? NookTheme.blue : NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(tr("launched.help"))
    }
}
