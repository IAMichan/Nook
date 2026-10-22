import SwiftUI

/// The expanded panel: Nook (home and chat in one), Agents, Workspace, and Music while something plays.
/// Everything you do happens here; tasks such as a new session or reviewing changes open inside the panel, never in
/// a separate window. Settings (the gear) is the one place for configuration. The main window shows this same panel
/// (`inWindow`), with the window's own tab and task and more room.
struct PanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    /// Room on the left of the header row for Nook, who sits there in the notch; the content below runs full width.
    var headerInset: CGFloat = 0
    /// In the main window: the window's tab and task (`windowTab`, `windowSheet`), the chat gets the wider layout, the
    /// header's empty space moves the window, and the traffic lights take the place of the close button.
    var inWindow = false
    @EnvironmentObject private var app: AppModel

    /// The height of the header row (tabs, or a task's title), so Nook can be centered on it.
    static let headerHeight: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sheet {
                NotchSheetView(sheet: sheet, headerInset: headerInset, close: closeSheet) {
                    closeSheet()
                    if !inWindow { viewModel.show(.idle) }
                }
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                header
                PanelApprovalBar(viewModel: viewModel, tab: tab, sheet: sheet, hub: app.hub, workspace: app.workspace)
                    .padding(.leading, headerInset)   // Clear of Nook's ring, under the tabs.
                content
                    .id(tab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .padding(.top, headerInset > 0 ? 20 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Agents keeps the footer under its session list.
                if tab != .agents && !app.demoMode {
                    PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() },
                                history: app.history)
                        .padding(.top, 8)
                }
            }
        }
        .animation(NookTheme.swap, value: sheet)
        // Short results from anywhere in Nook (saved, approved, failed) show over the panel's bottom edge.
        .nookToastHost()
    }

    /// The task open over the tab: the notch's, or the main window's.
    private var sheet: NotchSheet? { inWindow ? viewModel.windowSheet : viewModel.sheet }

    private func closeSheet() {
        if inWindow { viewModel.windowSheet = nil } else { viewModel.sheet = nil }
    }

    private func select(_ tab: PanelTab) {
        if inWindow {
            viewModel.windowSheet = nil
            viewModel.windowTab = tab
        } else {
            viewModel.show(.panel(tab), inNotch: true)
        }
    }

    /// A footer page (pull requests, usage) from another tab: it opens on Agents.
    private func openOnAgents(_ page: String) {
        viewModel.selectedAgentID = page
        select(.agents)
    }

    /// The tabs, with what waits for you on them: an amber count on Agents, a dot on Nook when an answer is unread. In
    /// the window, the tooltip names the tab's shortcut (⌘1, ⌘2, …).
    private var tabItems: [NookTabBar<PanelTab>.Item] {
        let tabs = PanelTab.visible(musicAvailable: app.nowPlaying.current != nil || tab == .music)
        let waiting = app.activeAgents.filter { $0.status == .waiting || $0.approvalID != nil }.count
        let unread = tab != .chat && app.chat.list(query: "", showArchived: false).contains { $0.status == .unread }
        return tabs.enumerated().map { index, value in
            NookTabBar<PanelTab>.Item(value: value, title: value.title,
                                      fresh: value == .chat && unread, count: value == .agents ? waiting : 0,
                                      help: inWindow ? "\(value.title) (⌘\(index + 1))" : nil)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            NookTabBar(items: tabItems, selected: tab) { select($0) }
            if inWindow {
                // Empty header space moves the window, as a title bar does. Its height is fixed: a clear color takes all
                // the height it is offered, and left free it stretched the header to half the window.
                Color.clear
                    .frame(minWidth: 8, maxWidth: .infinity)
                    .frame(height: Self.headerHeight)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            } else {
                Spacer()
            }
            // The gear sits in the footer instead, which every tab shows outside demo mode.
            let gear = app.demoMode
            HStack(spacing: 2) {
                talkButton
                if gear || !inWindow {
                    Rectangle()
                        .fill(NookTheme.textTertiary.opacity(0.35))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 6)
                }
                if !inWindow {
                    // Go on in the main window, on this tab, with more room.
                    NookIconButton(systemName: "macwindow", label: tr("menu.window"), size: 30) { app.openWindow(continuing: tab) }
                        .help(tr("menu.window"))
                }
                if gear {
                    NookIconButton(systemName: "gearshape", label: tr("button.settings"), size: 30) { app.openSettings() }
                        .help(tr("button.settings"))
                }
                if !inWindow {
                    NookIconButton(systemName: "xmark", label: tr("button.close"), size: 30) { viewModel.show(.idle) }
                        .help(tr("button.close"))
                }
            }
        }
        .frame(minHeight: Self.headerHeight)
        .padding(.leading, headerInset)
    }

    /// The one filled action in the header; the other buttons stay quiet until hovered.
    private var talkButton: some View {
        Button { viewModel.startListening() } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(NookTheme.font(12, .semibold))
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
        case .nook, .chat, .connect, .shelf:
            if inWindow { NookChatView(viewModel: viewModel, chat: app.chat, compact: false) } else { NookChatTab(viewModel: viewModel) }
        case .agents: AgentsTab(viewModel: viewModel)
        case .music: MusicTab()
        }
    }
}

/// A permission request or multiple-choice question that comes in while the panel (or the main window) is open: one
/// compact bar under the tabs instead of a card over the whole notch. Hidden while the session that asks is on screen,
/// which shows the whole request itself.
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
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                .help(approval.command)
                Spacer(minLength: 6)
                NookNoticeActions(
                    primary: NookNoticeAction(tr("button.allow")) { decide(approval, .allow) },
                    secondary: NookNoticeAction(tr("button.deny")) { decide(approval, .deny) },
                    extra: sessionKey(approval).map { key in
                        [NookNoticeAction(tr("button.view")) {
                            viewModel.selectedAgentID = key
                            viewModel.show(.panel(.agents))
                        }]
                    } ?? []
                )
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .cardBackground(NookTheme.field, stroke: approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.line2, radius: NookTheme.Radius.card)
            .padding(.top, 10)
            .transition(.opacity.combined(with: .offset(y: -4)))
        } else if !app.demoMode, let question = hub.questions.first(where: { !onScreen($0) }) {
            questionBar(question, more: hub.questions.count - 1)
        } else if let notice = viewModel.panelNotice {
            noticeBar(notice)
        }
    }

    /// A short notice (a session Nook runs asks something, a note is ready), with its one action.
    private func noticeBar(_ notice: PanelNotice) -> some View {
        HStack(spacing: 8) {
            Text(notice.message)
                .font(NookTheme.font(12.5, .medium))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .help(notice.message)
            Spacer(minLength: 6)
            if let action = notice.action {
                NookNoticeActions(primary: NookNoticeAction(notice.button) {
                    viewModel.dismissPanelNotice()
                    action()
                })
                .fixedSize()
            }
            NookIconButton(systemName: "xmark", label: tr("button.close"), size: 24) { viewModel.dismissPanelNotice() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
        .padding(.top, 10)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    /// The agent's question, with View to answer it in the session itself (one question at a time, as on the card).
    private func questionBar(_ request: AgentQuestionRequest, more: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.items.first?.question ?? "")
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(subtitle(request, more: more))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            .help(request.items.first?.question ?? "")
            Spacer(minLength: 6)
            NookNoticeActions(
                primary: NookNoticeAction(tr("button.view")) {
                    viewModel.selectedAgentID = request.sessionKey
                    viewModel.show(.panel(.agents))
                },
                secondary: NookNoticeAction(tr("approval.inTerminal")) { answerInTerminal(request) }
            )
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
        .padding(.top, 10)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func subtitle(_ request: AgentQuestionRequest, more: Int) -> String {
        let line = tr("agents.question.asks", request.agentName) + " · " + request.project
        return more > 0 ? line + " · " + tr("ws.approval.more", more) : line
    }

    private func answerInTerminal(_ request: AgentQuestionRequest) {
        let host = hub.sessions.first { $0.id == request.sessionKey }?.hostBundleID
        hub.answerQuestionInTerminal(request.id)
        TerminalLauncher.activate(sessionBundleID: host)
    }

    /// The session's own view shows the whole question, with its options.
    private func onScreen(_ request: AgentQuestionRequest) -> Bool {
        tab == .agents && sheet == nil && viewModel.selectedAgentID == request.sessionKey
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
    /// Room on the left of the title row, as in the panel header.
    var headerInset: CGFloat = 0
    /// Back: returns to the tab.
    let close: () -> Void
    /// The close button: closes the task and whatever holds it.
    let dismiss: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: headerInset > 0 ? 20 : 14) {
            HStack(spacing: 10) {
                Button(action: close) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(NookTheme.font(11, .semibold))
                        Text(tr("notch.back")).font(NookTheme.font(13, .medium))
                    }
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text(sheet.title)
                    .font(NookTheme.TextStyle.title)
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
            .frame(minHeight: PanelView.headerHeight)
            .padding(.leading, headerInset)
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
