import SwiftUI

/// Settings rows for sessions that keep running while Nook is closed (`SessionKeeper`): the switch, how many agents run in the
/// background now, and stopping the ones no session claims. The count is read when the rows appear and after a stop, never
/// polled, so an open Settings window costs nothing.
struct KeptSessionsSettingsRows: View {
    @ObservedObject var ws: WorkspaceSettings
    let workspace: WorkspaceManager
    @State private var live: [String] = []
    @State private var orphans = 0

    var body: some View {
        Group { rows }.onAppear { refresh() }
    }

    @ViewBuilder private var rows: some View {
        SettingToggle(tr("settings.ws.keepRunning"), detail: tr("settings.ws.keepRunning.help"), isOn: $ws.keepSessionsRunning)
        if ws.keepSessionsRunning || !live.isEmpty {
            LabeledContent {
                if orphans > 0 {
                    Button(tr("keep.stopOrphans", orphans)) {
                        workspace.stopOrphanKeepers()
                        // The keepers wind down in their own time (interrupt, terminate, kill); read again after that.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            refresh()
                        }
                    }
                    .controlSize(.small)
                    .help(tr("keep.stopOrphans.help"))
                }
            } label: {
                SettingLabel(tr("keep.status"), detail: statusText)
            }
        }
    }

    private var statusText: String {
        switch live.count {
        case 0: return tr("keep.status.none")
        case 1: return tr("keep.status.one")
        default: return tr("keep.status.many", live.count)
        }
    }

    private func refresh() {
        live = workspace.liveKeepers()
        let claimed = Set(workspace.runs.compactMap(\.kept?.folder))
        orphans = KeptRuns.orphans(folders: live, claimed: claimed).count
    }
}
