import SwiftUI

/// The expanded panel: Nook (home and chat in one), Agents, Workspace, and Music while something plays.
/// Everything you do happens here; tasks such as a new session or reviewing changes open inside the panel, never in
/// a separate window. Settings (the gear) is the one place for configuration.
struct PanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    @EnvironmentObject private var app: AppModel
    @Namespace private var underline
    @ObservedObject private var settings = AppSettings.shared
    private var large: Bool { settings.panelLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sheet = viewModel.sheet {
                NotchSheetView(viewModel: viewModel, sheet: sheet)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                header
                PanelApprovalBar(viewModel: viewModel, tab: tab, hub: app.hub, workspace: app.workspace)
                content
                    .id(tab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .animation(NookTheme.swap, value: viewModel.sheet)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(PanelTab.visible(musicAvailable: app.nowPlaying.current != nil || tab == .music)) { t in
                    Button {
                        viewModel.show(.panel(t))
                    } label: {
                        HStack(spacing: 6) {
                            Text(t.title)
                                .font(NookTheme.font(13.5, .medium))
                                .foregroundStyle(t == tab ? NookTheme.paper : NookTheme.textTertiary)
                            if let dot = dot(for: t) {
                                Circle().fill(dot).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if t == tab {
                                Rectangle()
                                    .fill(NookTheme.paper)
                                    .frame(height: 1.5)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(t == tab ? .isSelected : [])
                }
            }
            Spacer()
            HStack(spacing: 0) {
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 30) { viewModel.startListening() }
                    .help(tr("button.talk"))
                NookIconButton(
                    systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: tr(large ? "button.shrink" : "button.enlarge"),
                    size: 30
                ) {
                    AppSettings.shared.panelLarge.toggle()
                    viewModel.show(.panel(tab))
                }
                .help(tr(large ? "button.shrink" : "button.enlarge"))
                NookIconButton(systemName: "gearshape", label: tr("button.settings"), size: 30) { app.openSettings() }
                    .help(tr("button.settings"))
                NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30) { viewModel.show(.idle) }
                    .help(tr("button.close"))
            }
        }
    }

    /// A small, quiet dot next to a tab: amber when something there waits for you, white while it is working.
    private func dot(for tab: PanelTab) -> Color? {
        switch tab {
        case .chat, .nook:
            return app.chat.anyBusy ? NookTheme.iris : nil
        case .agents:
            let waiting = !app.hub.approvals.isEmpty || app.agentSessions.contains { $0.status == .waiting }
                || !app.workspace.approvals.isEmpty
            if waiting { return NookTheme.amber }
            return app.activeAgents.isEmpty && app.workspace.activeRuns.isEmpty ? nil : NookTheme.iris
        default:
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nook, .chat, .connect, .shelf: NookChatTab(viewModel: viewModel)
        case .agents: AgentsTab(viewModel: viewModel)
        case .music: MusicTab()
        }
    }
}

/// A permission request that comes in while the panel is open: one compact bar under the tabs instead of a card over
/// the whole notch. Hidden while the session that asks is on screen, which shows the whole request itself.
private struct PanelApprovalBar: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    @ObservedObject var hub: AgentHub
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let waiting = app.approvals.pending
        if let approval = waiting.first(where: { !onScreen($0) }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(approval.title)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(subtitle(approval, more: waiting.count - 1))
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                .help(approval.command)
                Spacer(minLength: 6)
                if let key = sessionKey(approval) {
                    NookGhostButton(title: tr("button.view")) {
                        viewModel.selectedAgentID = key
                        viewModel.show(.panel(.agents))
                    }
                }
                NookGhostButton(title: tr("button.deny")) { decide(approval, .deny) }
                NookPrimaryButton(title: tr("button.allow")) { decide(approval, .allow) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.line2, lineWidth: 1))
            .padding(.top, 10)
            .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }

    private func subtitle(_ approval: AgentApproval, more: Int) -> String {
        let line = approval.agentName + " · " + approval.project
        return more > 0 ? line + " · " + tr("ws.approval.more", more) : line
    }

    private func decide(_ approval: AgentApproval, _ decision: ApprovalDecision) {
        app.approvals.decide(approval, decision)
        // The card that waited in line for when the panel closes is answered too.
        viewModel.dismissCard(id: approval.cardToken)
    }

    /// The Agents entry of the session that asks ("run:<id>" for sessions Nook runs).
    private func sessionKey(_ approval: AgentApproval) -> String? {
        switch approval.origin {
        case .run(let runID, _):
            return "run:" + runID.uuidString
        case .bridge(let request):
            guard case .run(let runID) = bridge.pending.first(where: { $0.id == request })?.caller.kind else { return nil }
            return "run:" + runID.uuidString
        case .hook(let request):
            return hub.sessions.first { $0.approvalID == request }?.id
        }
    }

    /// The session's own view shows the whole request, with the same buttons.
    private func onScreen(_ approval: AgentApproval) -> Bool {
        guard tab == .agents, viewModel.sheet == nil, let key = sessionKey(approval) else { return false }
        return viewModel.selectedAgentID == key
    }
}

/// A task inside the notch: one clear title, Back to return, and the task itself. Escape also goes back.
private struct NotchSheetView: View {
    @ObservedObject var viewModel: NotchViewModel
    let sheet: NotchSheet
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    viewModel.sheet = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(tr("notch.back")).font(NookTheme.font(13, .medium))
                    }
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text(sheet.title)
                    .font(NookTheme.font(15, .semibold))
                    .foregroundStyle(NookTheme.paper)
                if let subtitle {
                    Text(subtitle)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30) {
                    viewModel.sheet = nil
                    viewModel.show(.idle)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The changed file a path points at; agents report absolute paths, Git relative ones.
    private func changedFile(_ id: UUID, path: String?) -> GitFileChange? {
        guard let path else { return nil }
        return app.workspace.git[id]?.status?.files.first { path == $0.path || path.hasSuffix("/" + $0.path) }
    }

    private var subtitle: String? {
        switch sheet {
        case .details(let id), .changes(let id, _), .commit(let id), .pullRequest(let id):
            return app.workspace.run(id)?.title
        case .folderChanges(let path):
            return AgentPathFormat.tilde(path)
        }
    }

    @ViewBuilder
    private var content: some View {
        let close = { viewModel.sheet = nil }
        switch sheet {
        case .details(let id):
            RunInspector(runID: id, embedded: true)
        case .changes(let id, let file):
            ChangesSheet(runID: id, initialFile: changedFile(id, path: file), onClose: close)
        case .commit(let id):
            CommitSheet(runID: id, onClose: close)
        case .pullRequest(let id):
            PullRequestSheet(runID: id, onClose: close)
        case .folderChanges(let path):
            FolderChangesSheet(directory: path).id(path)
        }
    }
}
