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
            Label(tr(lineage.labelKey, parent?.title ?? tr("lineage.deleted")), systemImage: lineage.symbol)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(parent != nil && hovering ? NookTheme.blue : NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .disabled(parent == nil)
        .onHover { hovering = $0 }
        .help(parent == nil ? tr("lineage.deleted") : tr("lineage.open"))
    }
}
