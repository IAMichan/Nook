import SwiftUI

/// The expanded panel: Nook (home and chat in one), Agents, Workspace, and Music while something plays.
/// Everything you do happens here; tasks such as a new session or reviewing changes open inside the panel, never in
/// a separate window. Settings (the gear) is the one place for configuration.
struct PanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    @EnvironmentObject private var app: AppModel
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sheet = viewModel.sheet {
                NotchSheetView(sheet: sheet, close: { viewModel.sheet = nil }) {
                    viewModel.sheet = nil
                    viewModel.show(.idle)
                }
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                header
                PanelApprovalBar(viewModel: viewModel, tab: tab, sheet: viewModel.sheet, hub: app.hub, workspace: app.workspace)
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
            HStack(spacing: 2) {
                ForEach(PanelTab.visible(musicAvailable: app.nowPlaying.current != nil || tab == .music)) { t in
                    Button {
                        viewModel.show(.panel(t), inNotch: true)
                    } label: {
                        Text(t.title)
                            .font(NookTheme.font(13, .medium))
                            .foregroundStyle(t == tab ? NookTheme.paper : NookTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background {
                                if t == tab {
                                    Capsule()
                                        .fill(NookTheme.smoke)
                                        .matchedGeometryEffect(id: "selection", in: selection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(t == tab ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            Spacer()
            HStack(spacing: 2) {
                talkButton
                Rectangle()
                    .fill(NookTheme.textTertiary.opacity(0.35))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)
                NookIconButton(systemName: "gearshape", label: tr("button.settings"), size: 30) { app.openSettings() }
                    .help(tr("button.settings"))
                NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30) { viewModel.show(.idle) }
                    .help(tr("button.close"))
            }
        }
    }

    /// The one filled action in the header; the other buttons stay quiet until hovered.
    private var talkButton: some View {
        Button { viewModel.startListening() } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 12, weight: .semibold))
                Text(tr("button.talkShort")).font(NookTheme.font(12.5, .medium))
            }
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(NookTheme.smoke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("button.talk"))
        .help(tr("button.talk"))
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

/// A permission request that comes in while the panel (or the main window) is open: one compact bar under the tabs
/// instead of a card over the whole notch. Hidden while the session that asks is on screen, which shows the whole
/// request itself.
struct PanelApprovalBar: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    /// The task open over the tab, if any: the session behind it is not on screen.
    let sheet: NotchSheet?
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
        guard tab == .agents, sheet == nil, let key = sessionKey(approval) else { return false }
        return viewModel.selectedAgentID == key
    }
}

/// A task inside the notch or the main window: one clear title, Back to return, and the task itself. Escape also goes
/// back.
struct NotchSheetView: View {
    let sheet: NotchSheet
    /// Back: returns to the tab.
    let close: () -> Void
    /// The close button: closes the task and whatever holds it.
    let dismiss: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: close) {
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
                NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30, action: dismiss)
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
