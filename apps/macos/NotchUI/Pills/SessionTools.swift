import Combine
import SwiftUI

/// What the side panel next to a session in the Agents tab shows: nothing (only the conversation), a terminal in its
/// folder (or worktree), Nook's browser, for instance on the dev server the agent started, the folder's changes, or
/// what the agent produced: its plans, task list and the files it wrote (`outputs`).
/// `picker` is the open side panel without a tool yet: it lists the tools to open.
enum SessionTool: String {
    case conversation, terminal, browser, changes, outputs, pullRequest, picker

    /// The tools the side panel can show, in the order its + menu and picker list them.
    static let panelTools: [SessionTool] = [.outputs, .terminal, .browser, .changes]
    /// What the side panel's + menu and list of tools offer: the tools, then a pull request to pick (it opens beside
    /// the session, never in the bottom panel).
    static let launchable: [SessionTool] = panelTools + [.pullRequest]
    /// Tabs beside a session: the tools, and a pull request opened from a link in it (the side panel only, never in the
    /// + menu, and not kept across launches).
    static let sideTabs: [SessionTool] = panelTools + [.pullRequest]

    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .changes: return "plus.forwardslash.minus"
        case .outputs: return "list.bullet.clipboard"
        case .pullRequest: return PullRequestIcon.generic
        case .picker: return "square.grid.2x2"
        }
    }

    /// Whether the tool works for a session in `directory`: without a folder there is only the browser and the outputs.
    func available(in directory: String) -> Bool {
        if self == .pullRequest || self == .outputs { return true }
        return directory.isEmpty ? self == .browser : Self.panelTools.contains(self)
    }

    /// The tab's name in the side panel.
    var title: String { tr("agents.tool.tab." + rawValue) }
    /// The key that opens it from the open side panel's list of tools.
    var key: Character {
        switch self {
        case .outputs: return "o"
        case .terminal: return "t"
        case .browser: return "b"
        case .changes: return "c"
        case .pullRequest: return "p"
        case .conversation, .picker: return " "
        }
    }
    /// What the icon in the session's header does.
    var help: String { tr("agents.tool." + rawValue) }
}

/// The panels' quiet icons in a session's header: buttons that open (or close) the bottom panel and the side panel.
/// The terminal and the browser open from the panels themselves (their tabs, + and the list of tools). The bottom panel
/// opens on what it showed last, the terminal by default; the side panel on what it showed last, or on the list of
/// tools when no tab is open. When the agent started a process or opened a page that you have not looked at yet, the
/// side panel's icon carries a small dot. The same goes for a plan or another output the agent made.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The session's folder; empty means no terminal and no changes, only the browser.
    let directory: String
    /// The agent made a plan or another output you have not seen yet.
    var outputsFresh = false
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            bottomToggle
            panelToggle
        }
        .toolbarGroup()
    }

    /// The agent started a process, opened a page or made a plan you have not seen: a tool with news that neither
    /// panel shows.
    private var fresh: Bool {
        outputsFresh || SessionTool.panelTools.contains { tool in
            tool.available(in: directory) && viewModel.sessionTool != tool && viewModel.bottomTool != tool
                && bridge.hasUnseen(directory, tool.rawValue)
        }
    }

    /// Opens the bottom panel on the tool it showed last (the terminal at first), or closes it.
    private var bottomToggle: some View {
        let open = viewModel.bottomTool != .conversation
        let help = open ? tr("agents.tool.closeBottom") : tr("agents.tool.bottom")
        return Button {
            if open {
                viewModel.bottomTool = .conversation
            } else {
                let tabs = viewModel.bottomTabs.filter { $0.available(in: directory) }
                let last = SessionTool(rawValue: lastBottomTool) ?? .terminal
                if tabs.contains(last) {
                    viewModel.bottomTool = last
                } else if let first = tabs.first {
                    viewModel.bottomTool = first
                } else {
                    viewModel.bottomTool = SessionTool.terminal.available(in: directory) ? .terminal : .picker
                }
            }
        } label: {
            SessionToolIcon(symbol: "rectangle.bottomthird.inset.filled", active: open, fresh: false)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    /// Opens the side panel on the tool it showed last, or closes it.
    private var panelToggle: some View {
        let open = viewModel.sessionTool != .conversation
        let base = open ? tr("agents.tool.close") : tr("agents.tool.panel")
        let help = fresh ? base + " · " + tr("bridge.tool.unseen") : base
        return Button {
            if open {
                viewModel.sessionTool = .conversation
            } else {
                let tabs = viewModel.sessionTabs.filter { $0.available(in: directory) }
                let last = SessionTool(rawValue: lastTool) ?? .browser
                viewModel.sessionTool = tabs.contains(last) ? last : tabs.first ?? .picker
            }
        } label: {
            SessionToolIcon(symbol: "sidebar.right", active: open, fresh: fresh)
        }
        .buttonStyle(.plain)
        .animation(NookTheme.reveal, value: fresh)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// One of the header's tool icons: highlighted while its tool is open, with a dot when there is something new.
private struct SessionToolIcon: View {
    let symbol: String
    let active: Bool
    let fresh: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: ToolbarGroup.itemHeight)
            .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius, style: .continuous).fill(active ? NookTheme.smoke : Color.clear))
            .overlay(alignment: .topTrailing) {
                if fresh {
                    Circle().fill(NookTheme.iris).frame(width: 5, height: 5).padding(NookTheme.Spacing.xs)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
    }
}

/// The header's buttons sit in a few quiet groups (outputs, the side panel's tools, the branch) instead of loose
/// icons: each group on one dark, softly outlined surface with its buttons inside.
enum ToolbarGroup {
    static let itemHeight: CGFloat = 22
    static let itemRadius: CGFloat = 6
    static let padding: CGFloat = 2
}

extension View {
    /// Plain icons with a fill only under the pointer: the group needs no box of its own.
    func toolbarGroup() -> some View {
        padding(ToolbarGroup.padding)
    }
}

/// The thin line between buttons inside one group.
struct ToolbarGroupDivider: View {
    var body: some View {
        Color.clear.frame(width: NookTheme.Spacing.xs, height: 12)
    }
}

/// A tab closed in a session's side or bottom panel, with what it showed, so ⇧⌘T can bring it back where it was.
struct ClosedSessionTab {
    let tool: SessionTool
    /// It was in the bottom panel, not the side panel.
    let bottom: Bool
    /// The pull request a Pull request tab showed.
    let pullRequest: PullRequestOpenRequest?
}

/// What a session's conversation found the agent produced, handed up to the workbench around it for the outputs tab.
/// `fresh`: something came in that you have not seen yet (a dot on the tab and on the side panel's button).
struct SessionOutputsReport: PreferenceKey, Equatable {
    var outputs: [SessionOutput] = []
    var fresh = false

    static let defaultValue = SessionOutputsReport()
    static func reduce(value: inout SessionOutputsReport, nextValue: () -> SessionOutputsReport) {
        let next = nextValue()
        if !next.outputs.isEmpty || next.fresh { value = next }
    }
}

/// From the workbench to the conversation inside it: whether the outputs tab is in view (what it shows counts as seen),
/// and how to open it on a new output; false when it stayed closed because you have another tool open.
struct SessionOutputsLink {
    var shown = false
    var open: (String) -> Bool = { _ in false }
}

extension EnvironmentValues {
    @Entry var sessionOutputs = SessionOutputsLink()
}

/// Where a tool panel sits next to the conversation: what it shows and which tabs it has open in the view model.
private struct SessionPanelSlot {
    let tool: ReferenceWritableKeyPath<NotchViewModel, SessionTool>
    let tabs: ReferenceWritableKeyPath<NotchViewModel, [SessionTool]>
    let closeHelp: String
    /// The close button's mark: the panel it puts away.
    let closeSymbol: String

    @MainActor static let side = SessionPanelSlot(tool: \.sessionTool, tabs: \.sessionTabs, closeHelp: "agents.tool.close",
                                                  closeSymbol: "sidebar.right")
    @MainActor static let bottom = SessionPanelSlot(tool: \.bottomTool, tabs: \.bottomTabs, closeHelp: "agents.tool.closeBottom",
                                                    closeSymbol: "rectangle.bottomthird.inset.filled")
}

/// A session in the Agents tab together with the tools it works with. The conversation stays in view; a terminal, the
/// browser or the changes open in a side panel on its right or a bottom panel under it, each in a tab you open with +
/// and close with its cross. A tool is open in one of the two at a time. With no tab open a panel lists the tools.
/// Drag the line beside (or above) a panel to make it wider (or taller).
struct SessionWorkbench<Conversation: View>: View {
    @ObservedObject var viewModel: NotchViewModel
    let directory: String
    /// A session Nook runs: its changes open in its own review, with comments for the agent.
    var runID: UUID? = nil
    /// Whether the session panel docks on the right when the window has room; the session views that have a branch button.
    var dockSessionPanel = false
    var agentWorking = false
    @ViewBuilder var conversation: (AnyView) -> Conversation
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue
    @AppStorage("nook.agents.toolWidth") private var toolWidth = PanelLayout.tool
    @AppStorage("nook.agents.bottomHeight") private var bottomHeight = BottomPanelLayout.standard
    @State private var totalWidth: Double = 0
    @State private var totalHeight: Double = 0
    @State private var dragStart: Double?
    /// What the conversation found the agent produced (`SessionOutputsReport`), and the output the outputs tab shows.
    @State private var outputs = SessionOutputsReport()
    @State private var outputSelection: String?

    /// What a panel shows: nothing (closed), the list of tools, or one this session can use.
    private func shown(_ slot: SessionPanelSlot) -> SessionTool {
        let selected = viewModel[keyPath: slot.tool]
        if selected == .conversation { return .conversation }
        return selected.available(in: directory) ? selected : .picker
    }

    /// The open tabs this session can show in a panel.
    private func tabs(_ slot: SessionPanelSlot) -> [SessionTool] {
        viewModel[keyPath: slot.tabs].filter { $0.available(in: directory) }
    }

    var body: some View {
        let side = shown(.side)
        let bottom = shown(.bottom)
        let outputsShown = side == .outputs || bottom == .outputs
        let docked = dockSessionPanel && !directory.isEmpty
            && totalWidth - (side != .conversation ? toolWidth + PanelSplit.handle : 0) >= PanelLayout.sessionPanelRoom
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Docked, the switch sits above the session panel instead of in the conversation's header.
                conversation(docked ? AnyView(EmptyView()) : AnyView(SessionToolSwitch(viewModel: viewModel, directory: directory,
                                                       outputsFresh: outputs.fresh && !outputsShown)))
                    // A pull request link in the conversation opens in the side panel.
                    .environment(\.pullRequestLinksBeside, true)
                    // The conversation hands up what the agent produced, and opens a new plan in the outputs tab.
                    .environment(\.sessionOutputs, SessionOutputsLink(shown: outputsShown, open: openOutput))
                    .environment(\.sessionPanelDocked, docked)
                    .onPreferenceChange(SessionOutputsReport.self) { outputs = $0 }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if bottom != .conversation {
                    VStack(spacing: 0) {
                        BottomSplitHandle(onDrag: dragBottom, onEnd: { dragStart = nil },
                                          onReset: { bottomHeight = BottomPanelLayout.standard })
                        panel(.bottom, tool: bottom)
                    }
                    .frame(height: CGFloat(BottomPanelLayout.height(bottomHeight, available: totalHeight)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { totalHeight = $0 }
            if docked {
                // The switch takes the height of the conversation's header, so the card starts where the conversation does.
                VStack(alignment: .trailing, spacing: 0) {
                    SessionToolSwitch(viewModel: viewModel, directory: directory, outputsFresh: outputs.fresh && !outputsShown)
                        .frame(height: 30)
                        .padding(.trailing, NookTheme.Spacing.xs)
                    DockedSessionPanel(directory: directory, runID: runID, agentWorking: agentWorking) {
                        if let runID { workspace.markReviewed(runID) }
                        viewModel.sessionTool = .changes
                    }
                    .id(directory)
                }
                .frame(width: PanelLayout.sessionPanel)
                .padding(.leading, NookTheme.Spacing.sm)
            }
            if side != .conversation {
                panel(.side, tool: side)
                    .padding(.leading, NookTheme.Spacing.sm)
                    .resizablePanel(width: $toolWidth, defaultWidth: PanelLayout.tool, minimum: PanelLayout.minimumPanel,
                                    available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                    edge: .leading, divider: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .animation(NookTheme.reveal, value: side == .conversation)
        .animation(NookTheme.reveal, value: bottom == .conversation)
        .onChange(of: side) { _, next in
            if SessionTool.panelTools.contains(next) { lastTool = next.rawValue }
        }
        .onChange(of: bottom) { _, next in
            if SessionTool.panelTools.contains(next) { lastBottomTool = next.rawValue }
        }
        // ⇧⌘T: the tab closed last comes back, in the panel it was in; the key goes on when there is none.
        .keyCommands(["panel.reopenClosed": reopenClosed])
    }

    /// Opens the most recently closed tab again (with its pull request), skipping tools that are open again or that
    /// this session cannot use.
    private func reopenClosed() -> Bool {
        let open = tabs(.side) + tabs(.bottom)
        guard let tab = viewModel.closedSessionTabs.reopen(skipping: { open.contains($0.tool) || !$0.tool.available(in: directory) })
        else { return false }
        withAnimation(NookTheme.swap) {
            if tab.tool == .pullRequest { viewModel.openSidePullRequest(tab.pullRequest) }
            viewModel[keyPath: (tab.bottom ? SessionPanelSlot.bottom : SessionPanelSlot.side).tool] = tab.tool
        }
        return true
    }

    /// Shows a new output in the outputs tab: in the bottom panel when it is open there, otherwise beside the
    /// conversation. A terminal, page or diff you have open beside it stays; then only the tab's dot says so (false).
    private func openOutput(_ id: String) -> Bool {
        let side = viewModel.sessionTool
        guard viewModel.bottomTool == .outputs || side == .outputs || side == .conversation || side == .picker else { return false }
        outputSelection = id
        if viewModel.bottomTool != .outputs, side != .outputs {
            withAnimation(NookTheme.reveal) { viewModel.sessionTool = .outputs }
        }
        return true
    }

    /// Dragging the line above the bottom panel up makes it taller.
    private func dragBottom(_ offset: Double) {
        let start = dragStart ?? BottomPanelLayout.height(bottomHeight, available: totalHeight)
        dragStart = start
        bottomHeight = BottomPanelLayout.height(start - offset, available: totalHeight)
    }

    private func panel(_ slot: SessionPanelSlot, tool: SessionTool) -> some View {
        SessionToolPanel(directory: directory, runID: runID, tool: tool, tabs: tabs(slot), pullRequest: viewModel.sidePullRequest,
                         pullRequestTabs: viewModel.sidePullRequestTabs, activePullRequest: viewModel.activeSidePullRequest,
                         outputs: outputs.outputs, outputSelection: $outputSelection, outputsFresh: outputs.fresh,
                         closeHelp: tr(slot.closeHelp), closeSymbol: slot.closeSymbol,
                         show: { item in withAnimation(NookTheme.swap) { viewModel[keyPath: slot.tool] = item } },
                         selectPullRequest: { id in
                             withAnimation(NookTheme.swap) { viewModel.activeSidePullRequest = id; viewModel.sessionTool = .pullRequest }
                         },
                         openPullRequest: { request in withAnimation(NookTheme.swap) { viewModel.openSidePullRequest(request) } },
                         updatePullRequest: { viewModel.updateSidePullRequest($0) },
                         showPullRequestList: { withAnimation(NookTheme.swap) { viewModel.showSidePullRequestList() } },
                         closeTab: { closeSessionTab($0, in: slot) },
                         close: { viewModel[keyPath: slot.tool] = .conversation })
    }

    /// Closes a tab. One of several Pull request tabs goes by itself, and the one next to it comes into view.
    private func closeSessionTab(_ tab: SessionTab, in slot: SessionPanelSlot) {
        switch tab {
        case .tool(let item): closeTab(item, in: slot)
        case .pullRequest(let id):
            if viewModel.sidePullRequestTabs.count > 1 {
                let request = viewModel.sidePullRequestTabs.first { $0.id == id }?.request
                viewModel.closedSessionTabs.push(ClosedSessionTab(tool: .pullRequest, bottom: false, pullRequest: request))
                withAnimation(NookTheme.swap) { viewModel.closeSidePullRequest(id) }
            } else {
                closeTab(.pullRequest, in: slot)
            }
        }
    }

    /// Closes a tab; when it was the one in view, the tab next to it takes its place, or the list of tools.
    private func closeTab(_ item: SessionTool, in slot: SessionPanelSlot) {
        let visible = tabs(slot)
        guard let index = visible.firstIndex(of: item) else { return }
        let rest = visible.filter { $0 != item }
        viewModel.closedSessionTabs.push(ClosedSessionTab(tool: item, bottom: slot.tool == \NotchViewModel.bottomTool,
                                                          pullRequest: item == .pullRequest ? viewModel.sidePullRequest : nil))
        withAnimation(NookTheme.swap) {
            viewModel[keyPath: slot.tabs].removeAll { $0 == item }
            if item == .pullRequest {
                viewModel.sidePullRequestTabs = []
                viewModel.activeSidePullRequest = nil
            }
            if viewModel[keyPath: slot.tool] == item {
                viewModel[keyPath: slot.tool] = rest.isEmpty ? .picker : rest[min(index, rest.count - 1)]
            }
        }
    }
}

/// How tall the bottom panel under a conversation is: what you dragged it to, leaving the conversation room.
enum BottomPanelLayout {
    static let standard: Double = 240
    static let minimum: Double = 120
    /// Room the conversation (its header and composer) keeps above the bottom panel.
    static let conversation: Double = 200

    static func height(_ wanted: Double, available: Double) -> Double {
        let most = max(minimum, available - conversation)
        return min(max(wanted, minimum), most)
    }
}

/// The line above the bottom panel: drag it to make the panel taller or shorter, double-click for its usual height.
private struct BottomSplitHandle: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            NookDivider()
            Capsule()
                .fill(hovering || dragging ? NookTheme.textSecondary : NookTheme.line2)
                .frame(width: 36, height: 4)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else if !dragging { NSCursor.pop() }
        }
        .gesture(
            // Global coordinates: the line itself moves while you drag it.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onDrag(Double(value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.pop() }
                    onEnd()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .help(tr("panel.resize"))
        .accessibilityLabel(tr("panel.resize"))
    }
}

/// One tab of a tool panel: a tool, or one of the Pull request tabs (there can be several).
private enum SessionTab: Hashable {
    case tool(SessionTool)
    case pullRequest(UUID)
}

/// A tool panel beside or under a session: its open tools as tabs, + to open another, the button that closes it, and
/// the tool in view (or the list of tools while none is open). It sits flat on the notch, not as a card.
private struct SessionToolPanel: View {
    let directory: String
    let runID: UUID?
    let tool: SessionTool
    let tabs: [SessionTool]
    let pullRequest: PullRequestOpenRequest?
    let pullRequestTabs: [SidePullRequestTab]
    let activePullRequest: UUID?
    let outputs: [SessionOutput]
    @Binding var outputSelection: String?
    let outputsFresh: Bool
    let closeHelp: String
    let closeSymbol: String
    let show: (SessionTool) -> Void
    let selectPullRequest: (UUID) -> Void
    /// Opens a Pull request tab beside the session, on this pull request or (nil) on the list to pick one.
    let openPullRequest: (PullRequestOpenRequest?) -> Void
    /// The active tab's pull request was read again.
    let updatePullRequest: (PullRequestOpenRequest) -> Void
    /// The active tab goes back to the list to pick another.
    let showPullRequestList: () -> Void
    let closeTab: (SessionTab) -> Void
    let close: () -> Void
    @ObservedObject private var bridge = WorkspaceBridge.shared
    /// The open page's title for the browser's tab, once the browser was started (it is not started for it).
    @State private var browserTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tool == .terminal { subheader { terminalBar } }
            if tool == .browser, !directory.isEmpty { DevServerStrip(directory: directory).padding(.bottom, NookTheme.Spacing.sm) }
            Group {
                switch tool {
                case .picker:
                    SessionToolPicker(directory: directory) { launch($0) }
                case .terminal: SessionTerminalsView(directory: directory).id(directory)
                case .outputs: SessionOutputsPanel(outputs: outputs, selection: $outputSelection)
                case .changes:
                    if let runID {
                        ChangesSheet(runID: runID, initialFile: nil, onClose: close, stacked: true).id(runID)
                    } else {
                        FolderChangesSheet(directory: directory, stacked: true).id(directory)
                    }
                case .pullRequest:
                    if let pullRequest {
                        // Back to the list to pick another, as the + of the tab does.
                        subheader {
                            HStack(spacing: NookTheme.Spacing.xs) {
                                ToolbarIconButton("chevron.left", tr("agents.pr.back"), showPullRequestList)
                                Text(tr("agents.pr.back")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, NookTheme.Spacing.sm)
                        }
                        PullRequestDetailView(accountID: pullRequest.account, item: pullRequest.item, onUpdate: { updated in
                            updatePullRequest(PullRequestOpenRequest(account: pullRequest.account, item: updated))
                        })
                            .id(pullRequest.account + " " + pullRequest.item.id)
                    } else {
                        SidePanelPullRequestPicker(directory: directory) { openPullRequest($0) }
                    }
                default: BrowserView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What the agent opened here is in view now, also when it opens more while you look.
        .onAppear { bridge.markSeen(directory, tool.rawValue) }
        .onChange(of: tool) { _, next in bridge.markSeen(directory, next.rawValue) }
        .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
        .onReceive(BrowserStore.existing?.$title.eraseToAnyPublisher() ?? Empty<String, Never>().eraseToAnyPublisher()) { browserTitle = $0 }
    }

    /// The open tabs, + right after them, and the button that closes the panel, as t3code's right panel has them. The
    /// tabs scroll sideways when they do not fit, so the close button always stays in view.
    private var header: some View {
        SidePanelTabBar(items: tabs.flatMap(tabItems), selected: selectedTab, onSelect: selectTab, onClose: closeTab) {
            addMenu
        } trailing: {
            ToolbarIconButton(closeSymbol, closeHelp, height: 24, width: 24, close)
        }
    }

    /// The tab in view: a Pull request tab by its own id, as there can be several.
    private var selectedTab: SessionTab {
        if tool == .pullRequest, let active = activePullRequest ?? pullRequestTabs.first?.id { return .pullRequest(active) }
        return .tool(tool)
    }

    private func selectTab(_ tab: SessionTab) {
        switch tab {
        case .tool(let item): show(item)
        case .pullRequest(let id): selectPullRequest(id)
        }
    }

    /// The tabs of a tool: one, or for the Pull request tool one for each pull request (or list) open.
    private func tabItems(_ item: SessionTool) -> [SidePanelTabItem<SessionTab>] {
        guard item == .pullRequest, !pullRequestTabs.isEmpty else { return [tabItem(item)] }
        return pullRequestTabs.map { tab in
            let request = tab.request
            let title = request.map { "#\($0.item.number) " + ($0.item.title.isEmpty ? $0.item.repo : $0.item.title) } ?? item.title
            let fresh = item != tool && bridge.hasUnseen(directory, item.rawValue)
            return SidePanelTabItem(value: .pullRequest(tab.id), title: title, icon: AnyView(SidePanelPullRequestIcon(item: request?.item)),
                                    fresh: fresh, help: request.map { $0.item.repo + " #\($0.item.number)" } ?? item.help)
        }
    }

    /// A tab with what it shows: the page's title in the browser, the name of a tool.
    private func tabItem(_ item: SessionTool) -> SidePanelTabItem<SessionTab> {
        let fresh = item != tool && (item == .outputs ? outputsFresh : bridge.hasUnseen(directory, item.rawValue))
        switch item {
        case .browser:
            return SidePanelTabItem(value: .tool(item), title: browserTitle.isEmpty ? item.title : browserTitle,
                                    icon: AnyView(SidePanelSymbol(symbol: "globe")), fresh: fresh,
                                    help: browserTitle.isEmpty ? item.help : browserTitle)
        case .pullRequest:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelPullRequestIcon(item: nil)),
                                    fresh: fresh, help: item.help)
        default:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelSymbol(symbol: item.symbol)),
                                    fresh: fresh, help: item.help)
        }
    }

    /// A tool's own bar under the tabs (the terminal's folder and actions), ruled off from what it shows.
    private func subheader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .frame(height: 32)
            NookDivider()
        }
    }

    /// Under the tabs, so they keep the panel's full width: the terminal's folder and its actions.
    private var terminalBar: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text(AgentPathFormat.tilde(directory))
                .font(NookTheme.mono(11))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directory)
            Spacer(minLength: 8)
            SessionTerminalActions(directory: directory).id(directory)
        }
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    /// + : the tools to open, each in its own tab (or the tab it already has), in Nook's own dropdown panel.
    /// The tool in view is faintly filled; one the session cannot use says why.
    private var addMenu: some View {
        ComposerDropdown(width: 220) {
            Image(systemName: "plus")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        } content: {
            DropdownHeader(title: tr("agents.tool.add"))
            ForEach(SessionTool.launchable, id: \.self) { item in
                DropdownRow(symbol: item.symbol, title: item.title, chosen: item == tool,
                            disabledReason: item.available(in: directory) ? nil : tr("agents.tool.needsFolder")) {
                    launch(item)
                }
            }
        }
        .help(tr("agents.tool.add"))
        .accessibilityLabel(tr("agents.tool.add"))
    }

    /// Opens a tool from the + menu or the list of tools; a pull request opens beside the session, on the list to pick.
    private func launch(_ item: SessionTool) {
        if item == .pullRequest { openPullRequest(nil) } else { show(item) }
    }
}

/// An open panel before any tab, like t3code's "Open a surface": the tools, one row each with the key that opens it.
/// A tool the session cannot use (a terminal or changes without a folder) is dimmed and says why.
private struct SessionToolPicker: View {
    let directory: String
    let onOpen: (SessionTool) -> Void

    var body: some View {
        SidePanelLauncher(title: tr("agents.tool.pick"), items: SessionTool.launchable.map { tool in
            SidePanelLaunch(id: tool.rawValue, symbol: tool.symbol, title: tool.title, key: tool.key,
                            disabledReason: tool.available(in: directory) ? nil : tr("agents.tool.needsFolder")) { onOpen(tool) }
        })
    }
}

/// A tool's mark in its tab.
private struct SidePanelSymbol: View {
    let symbol: String

    var body: some View {
        NookSymbol(symbol, size: 12).font(NookTheme.font(10.5, .medium))
    }
}

/// A pull request's state mark in its tab, in the state's color.
private struct SidePanelPullRequestIcon: View {
    let item: PullRequestItem?

    var body: some View {
        PullRequestStateIcon(glyph: item?.stateGlyph ?? .open)
    }
}

/// The rounded, slightly lifted surface a terminal, the browser or the worktrees sit on inside the notch.
struct ToolSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.field))
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
    }
}

/// A footer page that is one of the tools on its own: every terminal, the browser, or every worktree.
struct AgentsToolPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            PanelListHeader(title)
            ToolSurface(content: content)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The local servers this session's folder runs, as small buttons
/// above the browser: one tap opens it. Checked every few seconds while the browser is open.
struct DevServerStrip: View {
    let directory: String
    @State private var servers: [DevServer] = []
    @ObservedObject private var browser = BrowserStore.shared

    var body: some View {
        // A VStack, not a Group: it exists while still empty, so the scan below starts.
        VStack(alignment: .leading, spacing: 0) {
            if !servers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .help(tr("agents.servers.help"))
                        ForEach(servers) { server in
                            // `address` is published, unlike the web view's own URL.
                            let open = URL(string: browser.address)?.port == server.port
                            Button {
                                browser.go(server.url.absoluteString)
                            } label: {
                                Text("\(server.command) — :\(server.port)")
                                    .font(NookTheme.TextStyle.label)
                                    .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(Capsule().fill(open ? NookTheme.smoke : NookTheme.field))
                            }
                            .buttonStyle(.plain)
                            .help(server.url.absoluteString)
                        }
                    }
                }
            }
        }
        .task(id: directory) {
            let folder = WorkspacePathPolicy.normalize(directory)
            // Each scan starts `lsof` twice (100–500 ms of work). Every 3 seconds right after something changed, so a
            // server that just started shows up at once; up to every 15 seconds while the list stays the same.
            var wait: UInt64 = 3
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { () async -> [DevServer] in
                    // Only listeners that serve a page: not the folder's database or debugger.
                    var servers = await DevServerProbe.pages(DevServerScanner.scan(folder: folder))
                    // Pages the project names (nook.json previewUrl) on localhost, when they are not already found.
                    for script in ProjectScripts.load(folder: folder) {
                        guard let url = script.previewURL, let port = url.port, BridgeURLPolicy.isLoopback(url.host ?? ""),
                              !servers.contains(where: { $0.port == port }) else { continue }
                        servers.append(DevServer(pid: 0, command: script.name, port: port))
                    }
                    return servers.sorted { $0.port < $1.port }
                }.value
                if found != servers {
                    withAnimation(NookTheme.reveal) { servers = found }
                    wait = 3
                } else {
                    wait = min(wait + 3, 15)
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }
}
