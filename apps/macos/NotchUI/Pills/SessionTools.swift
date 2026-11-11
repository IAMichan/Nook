import AppKit
import Combine
import SwiftUI

/// What the side panel next to a session in the Agents tab shows: nothing (only the conversation), a terminal in its
/// folder (or worktree), Nook's browser, for instance on the dev server the agent started, the folder's changes, or
/// what the agent produced: its plans, task list and the files it wrote (`outputs`), or the subagents it started, with
/// what each thought, did and answered (`subagents`).
/// `picker` is the open side panel without a tool yet: it lists the tools to open.
enum SessionTool: String {
    case conversation, terminal, browser, changes, outputs, subagents, pullRequest, artifact, file, picker

    /// The tools the side panel can show, in the order its + menu and picker list them.
    static let panelTools: [SessionTool] = [.outputs, .subagents, .terminal, .browser, .changes]
    /// What the side panel's + menu and list of tools offer: the tools, then a pull request to pick and a file to read
    /// or edit (both open beside the session, never in the bottom panel).
    static let launchable: [SessionTool] = panelTools + [.pullRequest, .file]
    /// Tabs beside a session: the tools, and a pull request opened from a link in it (the side panel only, never in the
    /// + menu, and not kept across launches). An artifact (a Claude artifact, a ChatGPT canvas) clicked in the conversation
    /// opens the same way, in the signed-in web version of the app that made it, and a file link in Nook's own viewer.
    static let sideTabs: [SessionTool] = panelTools + [.pullRequest, .artifact, .file]

    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .changes: return "plus.forwardslash.minus"
        case .outputs: return "list.bullet.clipboard"
        case .subagents: return "person.2"
        case .pullRequest: return PullRequestIcon.generic
        case .artifact: return "square.on.square"
        case .file: return "doc.text"
        case .picker: return "square.grid.2x2"
        }
    }

    /// Whether the tool works for a session in `directory`: without a folder there is only the browser, the outputs and
    /// the subagents.
    func available(in directory: String) -> Bool {
        if self == .pullRequest || self == .outputs || self == .subagents || self == .artifact || self == .file { return true }
        return directory.isEmpty ? self == .browser : Self.panelTools.contains(self)
    }

    /// The tab's name in the side panel.
    var title: String { tr("agents.tool.tab." + rawValue) }
    /// The key that opens it from the open side panel's list of tools.
    var key: Character {
        switch self {
        case .outputs: return "o"
        case .subagents: return "s"
        case .terminal: return "t"
        case .browser: return "b"
        case .changes: return "c"
        case .pullRequest: return "p"
        case .file: return "f"
        case .conversation, .artifact, .picker: return " "
        }
    }
    /// What the icon in the session's header does.
    var help: String { tr("agents.tool." + rawValue) }
}

/// The panels' quiet icons in a session's header, one per side as in an editor: the bottom panel, the session panel and
/// the side panel on the right (`SidePanelToggle`), each with the mark of its side, and in the notch the session list on
/// the left (the main window has `PanelSidebarToggle` for it). The terminal and the browser open from the panels themselves (their tabs, + and the list of tools). The bottom panel
/// opens on what it showed last, the terminal by default; so does the side panel, or on the list of tools with no tab open.
/// When the agent started a process or opened a page that you have not looked at yet, the side panel's icon carries a
/// small dot. The same goes for a plan or another output the agent made.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The session's folder; empty means no terminal and no changes, only the browser.
    let directory: String
    /// The agent made a plan or another output you have not seen yet.
    var outputsFresh = false
    /// The session panel beside the conversation, while the window has room for it: whether it is open. Without room
    /// (nil) the branch button in the header opens it instead, so there is no toggle.
    var sessionPanelOpen: Bool? = nil
    var toggleSessionPanel: () -> Void = {}
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue
    /// The session list on the left of the Agents tab is put away (`AgentsTab`).
    @AppStorage(AgentsListVisibility.hiddenKey) private var listHidden = false
    @Environment(\.panelSidebar) private var sidebar

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if sidebar == nil { listToggle }
            bottomToggle
            // In the order of the panels on screen: the session panel sits left of the side panel.
            if let sessionPanelOpen {
                SidePanelToggle(edge: .trailing, symbol: "list.bullet.rectangle", open: sessionPanelOpen,
                                help: tr(sessionPanelOpen ? "agents.sessionPanel.hide" : "agents.sessionPanel.show"),
                                action: toggleSessionPanel)
            }
            panelToggle
        }
        .toolbarGroup()
    }

    /// Shows or puts away the session list, for more room for the conversation.
    private var listToggle: some View {
        SidePanelToggle(edge: .leading, open: !listHidden, help: tr(listHidden ? "agents.list.show" : "agents.list.hide")) {
            withAnimation(NookTheme.reveal) { listHidden.toggle() }
        }
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
        return SidePanelToggle(edge: .bottom, open: open, help: open ? tr("agents.tool.closeBottom") : tr("agents.tool.bottom")) {
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
        }
    }

    /// Puts the side panel away with its tabs, or opens it again on what it showed.
    private var panelToggle: some View {
        let open = viewModel.sessionTool != .conversation
        let base = open ? tr("agents.tool.close") : tr("agents.tool.panel")
        let help = fresh ? base + " · " + tr("bridge.tool.unseen") : base
        return SidePanelToggle(edge: .trailing, open: open, fresh: fresh, help: help) {
            viewModel.toggleSidePanel()
        }
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

/// What a session's conversation found the agent produced, handed up to the workbench around it for the outputs tab
/// and the turn diff panel. `fresh`: something came in that you have not seen yet (a dot on the tab and on the side
/// panel's button).
struct SessionOutputsReport: PreferenceKey, Equatable {
    var outputs: [SessionOutput] = []
    /// Every subagent the agent started, for the Subagents tab; `subagentsFresh`: one started, ended or did something
    /// you have not seen.
    var subagents: [SubagentInfo] = []
    /// The commands it left running in the background, shown in the same tab (`BackgroundCommands`).
    var commands: [BackgroundCommandInfo] = []
    var subagentsFresh = false
    var turns: [TurnDiff] = []
    /// The last pull request the conversation links, for the session panel to look up at once (`sessionPullRequest`).
    var pullRequest: URL?
    var fresh = false

    static let defaultValue = SessionOutputsReport()
    static func reduce(value: inout SessionOutputsReport, nextValue: () -> SessionOutputsReport) {
        let next = nextValue()
        if !next.outputs.isEmpty || !next.subagents.isEmpty || !next.commands.isEmpty || !next.turns.isEmpty || next.pullRequest != nil || next.fresh {
            value = next
        }
    }
}

/// From the workbench to the conversation inside it: whether the outputs tab is in view (what it shows counts as seen),
/// and how to open it on a new output; false when it stayed closed because you have another tool open. The same for the
/// Subagents tab.
struct SessionOutputsLink: Equatable {
    var shown = false
    var open: (String) -> Bool = { _ in false }
    var subagentsShown = false
    var openSubagents: () -> Bool = { false }

    /// By what it says, not its actions: the workbench makes new closures on every redraw (which reach the same state), and
    /// an environment value that is never equal redrew every view of the conversation that reads it on each streamed token.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.shown == rhs.shown && lhs.subagentsShown == rhs.subagentsShown }
}

extension EnvironmentValues {
    @Entry var sessionOutputs = SessionOutputsLink()
    /// The last pull request the session's conversation links: a new one makes the session panel ask the forge at once,
    /// instead of waiting for git to change (an agent that pushed and then ran `gh pr create` changes nothing in git).
    @Entry var sessionPullRequest: URL?
}

/// The size the last session workbench measured (`SessionWorkbench` is generic, so it cannot hold it itself).
@MainActor
private enum SessionWorkbenchSize {
    static var width: Double = 0
    static var height: Double = 0
}

/// Where a tool panel sits next to the conversation: what it shows and which tabs it has open in the view model.
private struct SessionPanelSlot {
    let tool: ReferenceWritableKeyPath<NotchViewModel, SessionTool>
    let tabs: ReferenceWritableKeyPath<NotchViewModel, [SessionTool]>
    let closeHelp: String

    @MainActor static let side = SessionPanelSlot(tool: \.sessionTool, tabs: \.sessionTabs, closeHelp: "agents.tool.close")
    @MainActor static let bottom = SessionPanelSlot(tool: \.bottomTool, tabs: \.bottomTabs, closeHelp: "agents.tool.closeBottom")
}

/// A session in the Agents tab together with the tools it works with. The conversation stays in view; a terminal, the
/// browser or the changes open in a side panel on its right or a bottom panel under it, each in a tab you open with +
/// and close with its cross. A tool is open in one of the two at a time. With no tab open a panel lists the tools.
/// Drag the line beside (or above) a panel to make it wider (or taller). A turn's diff opens in the Changes tab and a
/// file in the File tab (`SessionSideLink`). With room to spare the session panel is a card
/// on the right of the conversation until you close it, with the tool panel to its right.
struct SessionWorkbench<Conversation: View>: View {
    @ObservedObject var viewModel: NotchViewModel
    let directory: String
    /// A session Nook runs: its changes open in its own review, with comments for the agent.
    var runID: UUID? = nil
    /// Whether the session panel docks on the right when the window has room; the session views that have a branch button.
    var dockSessionPanel = false
    var agentWorking = false
    @ViewBuilder var conversation: (AnyView) -> Conversation
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @ObservedObject private var fileViewer = FileViewerStore.shared
    @Environment(\.sessionHeaderInset) private var headerInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue
    @AppStorage("nook.agents.toolWidth") private var toolWidth = PanelLayout.tool
    @AppStorage("nook.agents.bottomHeight") private var bottomHeight = BottomPanelLayout.standard
    /// You closed the session panel: it stays closed, in every session, until you open it again.
    @AppStorage("nook.agents.sessionPanelClosed") private var sessionPanelClosed = false
    /// Starts at the size the last session measured: each session gets its own workbench, and starting from zero docked
    /// the session panel only after the first layout, sliding it in on every switch.
    @State private var totalWidth: Double = SessionWorkbenchSize.width
    @State private var totalHeight: Double = SessionWorkbenchSize.height
    @State private var dragStart: Double?
    /// The side panel takes the whole workbench, for a long diff or a page: until you restore it or it closes.
    @State private var panelMaximized = false
    /// The bottom panel's height while its line is dragged (`PanelDrag`).
    @State private var liveBottomHeight: Double?
    /// What the conversation found the agent produced (`SessionOutputsReport`), and the output the outputs tab shows.
    @State private var outputs = SessionOutputsReport()
    @State private var outputSelection: String?
    /// What the Changes tab shows, picked in a turn's card; nil for what the branch changed.
    @State private var diffSelection: TurnDiffSelection?
    /// The command the agent runs that the Terminal tab shows (its event's id), opened from the conversation's live
    /// line; nil while the tab shows your own shells.
    @State private var consoleEventID: UUID?
    /// Whether the session panel was docked: it docks again only with some room to spare (`PanelLayout.dockHysteresis`),
    /// so dragging a panel near the edge of the room does not make the column come and go.
    @State private var wasDocked = true
    /// How far the conversation's column still has to go after the session panel opened or closed (`chatColumnSlide`), so
    /// it glides to the middle of its new room instead of jumping there.
    @State private var chatSlide: CGFloat = 0
    /// Whether a panel's tool may take the keyboard: not while the session opens with a panel already open, so you type
    /// in the composer right away; once you open or switch a tool in a panel, it may (`sidePanelTakesFocus`).
    @State private var panelTakesFocus = false

    /// What a panel shows: nothing (closed), the list of tools, or one this session can use.
    private func shown(_ slot: SessionPanelSlot) -> SessionTool {
        let selected = viewModel[keyPath: slot.tool]
        if selected == .conversation { return .conversation }
        return usable(selected) ? selected : .picker
    }

    /// Whether this session can show a tool. Without a folder the agent's turns still have a diff.
    private func usable(_ tool: SessionTool) -> Bool {
        tool.available(in: directory) || (tool == .changes && !outputs.turns.isEmpty)
    }

    /// The open tabs this session can show in a panel.
    private func tabs(_ slot: SessionPanelSlot) -> [SessionTool] {
        viewModel[keyPath: slot.tabs].filter(usable)
    }

    /// The file in view in the File tab: a step in the conversation marks it.
    private var shownFile: String? {
        shown(.side) == .file ? fileViewer.target?.path : nil
    }

    /// The room a conversation needs to stay beside the side panel.
    private var conversationRoom: Double { PanelLayout.minimumConversation + PanelSplit.handle }

    /// Too narrow for the conversation beside the side panel: the panel covers the conversation until you close it,
    /// instead of both squeezing until neither reads.
    private var tooNarrow: Bool {
        !PanelSplit.fits(minimum: PanelLayout.minimumPanel + NookTheme.Spacing.sm, available: totalWidth, rest: conversationRoom)
    }

    private var covering: Bool {
        shown(.side) != .conversation && (tooNarrow || panelMaximized)
    }

    /// The width the right panel actually takes (not the one it was dragged to).
    private var rightRoom: Double {
        shown(.side) != .conversation && !covering
            ? SidePanelRoom.of(PanelSplit.width(toolWidth, minimum: PanelLayout.minimumPanel, available: totalWidth,
                                                rest: conversationRoom))
            : 0
    }

    var body: some View {
        let side = shown(.side)
        let bottom = shown(.bottom)
        let outputsShown = side == .outputs || bottom == .outputs
        let subagentsShown = side == .subagents || bottom == .subagents
        let toolsFresh = (outputs.fresh && !outputsShown) || (outputs.subagentsFresh && !subagentsShown)
        let sideOpen = side != .conversation
        // The room of the conversation's own panels, so a window that gets narrower gives up the docked column first;
        // under that room it is the branch button's popover again.
        let needed = PanelLayout.sessionPanelRoom + (wasDocked || sessionPanelClosed ? 0 : PanelLayout.dockHysteresis)
        let canDock = dockSessionPanel && !directory.isEmpty && totalWidth - rightRoom >= needed
        let docked = canDock && !sessionPanelClosed
        let tools = SessionToolSwitch(viewModel: viewModel, directory: directory, outputsFresh: toolsFresh,
                                      sessionPanelOpen: canDock ? docked : nil, toggleSessionPanel: toggleSessionPanel)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // The toggles end the header's row: in the conversation's header, or above the docked session panel,
                    // which ends at the same spot. So they stay where they are when that panel opens or closes.
                    conversation(docked ? AnyView(EmptyView()) : AnyView(tools))
                        .environment(\.chatColumnSlide, chatSlide)
                        // A pull request link in the conversation opens in the side panel.
                        .environment(\.pullRequestLinksBeside, true)
                        // The conversation hands up what the agent produced, and opens a new plan in the outputs tab.
                        .environment(\.sessionOutputs, SessionOutputsLink(shown: outputsShown, open: openOutput,
                                                                          subagentsShown: subagentsShown, openSubagents: openSubagents))
                        .environment(\.sessionPanelDocked, docked)
                        // A diff or file the conversation opens is a tab of the side panel.
                        .environment(\.sessionSide, SessionSideLink(shownFile: shownFile, panelOpen: sideOpen, hasPanel: true, showFile: showFile, openDiff: openDiff,
                                                                     toggleConsole: toggleConsole))
                        .onPreferenceChange(SessionOutputsReport.self) { outputs = $0 }
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // Where the page this session's agent opened rests: the conversation above its composer. The card
                        // itself floats over the whole row (below), so it can be moved over the panels on the right too.
                        .overlayPreferenceValue(SessionComposerBounds.self) { composer in
                            GeometryReader { proxy in
                                Color.clear
                                    .anchorPreference(key: SessionBrowserRest.self, value: .bounds) { $0 }
                                    .padding(.bottom, composer.map { max(0, proxy.size.height - proxy[$0].minY) } ?? 0)
                            }
                        }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Under the covering panel the conversation keeps its place (and what you typed) but takes no clicks.
                .allowsHitTesting(!covering)
                .accessibilityHidden(covering)
                .focusArea(.conversation)
                if docked {
                    // Always the leftmost side panel on the right side, right next to the conversation, with any tool, diff
                    // or file panel to its right. It starts level with the conversation, under the header's line.
                    VStack(alignment: .trailing, spacing: 0) {
                        tools.frame(height: 30)
                        DockedSessionPanel(directory: directory, runID: runID, agentWorking: agentWorking) {
                            if let runID { workspace.markReviewed(runID) }
                            viewModel.sessionTool = .changes
                        }
                        .id(directory)
                    }
                    .fixedSidePanel(width: PanelLayout.sessionPanel)
                }
                if sideOpen && !covering {
                    panel(.side, tool: side, maximized: $panelMaximized)
                        .sidePanel(.trailing, width: $toolWidth, defaultWidth: PanelLayout.tool, available: totalWidth,
                                   rest: conversationRoom)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A page this session's agent opened: small in the chat's bottom right corner, above the composer, and in no
            // other chat. It floats over this row, not the conversation alone, so no panel beside the chat stops or hides it.
            .overlayPreferenceValue(SessionBrowserRest.self) { rest in
                GeometryReader { proxy in
                    let conversation = rest.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size)
                    let above = max(0, proxy.size.height - conversation.maxY)
                    SessionBrowserCorner(runID: runID, directory: directory, hidden: side == .browser || bottom == .browser,
                                        room: CGSize(width: max(0, conversation.width - SessionBrowserCard.size.width - NookTheme.Spacing.lg * 2),
                                                     height: max(0, conversation.height - SessionBrowserCard.size.height - NookTheme.Spacing.md)),
                                        below: above, right: max(0, proxy.size.width - conversation.maxX)) {
                        withAnimation(NookTheme.reveal) { viewModel.sessionTool = .browser }
                    }
                    // In a narrow conversation the page covers part of it, not all of it.
                    .frame(maxWidth: max(240, conversation.width * 0.7), alignment: .trailing)
                    .padding(.trailing, proxy.size.width - conversation.maxX + NookTheme.Spacing.lg)
                    .padding(.bottom, above + NookTheme.Spacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .overlay {
                if covering {
                    panel(.side, tool: side, maximized: tooNarrow ? nil : $panelMaximized)
                        // With the list away, its tabs stay clear of the traffic lights and the list's toggle.
                        .padding(.leading, headerInset)
                        .background(NookTheme.canvas)
                }
            }
            // The panels on the right, and the docked session panel that steps aside for them, open and close at once.
            .sidePanelsOpenAtOnce(RightPanels(side: sideOpen, covering: covering, docked: docked))
            // Over a bottom panel the columns' lines end at its line instead of running on to the window's bottom.
            .transformEnvironment(\.lineBleed) { if bottom != .conversation { $0.bottom = 0 } }
            // The bottom panel runs the full width of the workbench, under the docked session panel and the side panel too.
            if bottom != .conversation {
                VStack(spacing: 0) {
                    BottomSplitHandle(onDrag: dragBottom,
                                      onEnd: {
                                          dragStart = nil
                                          PanelDrag.commit($liveBottomHeight, to: $bottomHeight)
                                      },
                                      onReset: { PanelDrag.still { bottomHeight = BottomPanelLayout.standard } })
                    panel(.bottom, tool: bottom)
                }
                .frame(height: CGFloat(BottomPanelLayout.height(liveBottomHeight ?? bottomHeight, available: totalHeight)))
                // Its own columns' lines start at its line, not above it.
                .transformEnvironment(\.lineBleed) { $0.top = 0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onLayoutHeightChange {
            totalHeight = $0
            SessionWorkbenchSize.height = $0
        }
        .onLayoutWidthChange { width in
            SessionWorkbenchSize.width = width
            // The first measurement of a session that just opened lays it out as it is: the panels are there at once,
            // they do not slide in.
            var transaction = Transaction()
            transaction.disablesAnimations = totalWidth == 0
            withTransaction(transaction) { totalWidth = width }
        }
        // The branch button in the conversation's header and the docked session panel both read it.
        .environment(\.sessionPullRequest, outputs.pullRequest)
        // What the side panel hands over lands in this session's composer.
        .environment(\.sessionContextTarget, directory.isEmpty && runID == nil ? nil : SessionContextTarget(run: runID, directory: directory))
        // The pull request the conversation links last is the one you are likely to open: read it ahead, once the
        // session has settled in, so its link opens on the page at once.
        .task(id: outputs.pullRequest) {
            guard let url = outputs.pullRequest else { return }
            try? await Task.sleep(for: NookTheme.tabSettle)
            if !Task.isCancelled { app.prefetchPullRequestLink(url) }
        }
        .onChange(of: docked) { _, now in wasDocked = now }
        // After the frame with the new widths, so it starts from where the column stood.
        .onChange(of: chatSlide) { _, now in
            if now != 0 { withAnimation(NookTheme.reveal) { chatSlide = 0 } }
        }
        // Links, scripts and pages you open go to the browser of the session on screen.
        .onAppear { SessionBrowsers.shared.appeared(browserSession) }
        .onDisappear { SessionBrowsers.shared.disappeared(browserSession) }
        .onChange(of: browserSession) { old, new in
            SessionBrowsers.shared.disappeared(old)
            SessionBrowsers.shared.appeared(new)
        }
        .onChange(of: runID) { _, _ in
            diffSelection = nil
            consoleEventID = nil
        }
        // A task, not onChange: it also runs for the workbench a row's card just opened, after the change above.
        .task(id: viewModel.sessionDiffToOpen) {
            guard let selection = viewModel.sessionDiffToOpen else { return }
            viewModel.sessionDiffToOpen = nil
            openDiff(selection)
        }
        .animation(NookTheme.reveal, value: bottom == .conversation)
        .onChange(of: bottom) { _, next in
            if SessionTool.panelTools.contains(next) { lastBottomTool = next.rawValue }
            panelTakesFocus = true
        }
        .onChange(of: side) { _, next in
            panelTakesFocus = true
            if next == .conversation { panelMaximized = false }
        }
        // The Changes tab put away: it opens on the branch again, not on the turn it last came from.
        .onChange(of: changesShown) { _, shown in
            if !shown { diffSelection = nil }
        }
        // The Terminal tab put away: the next time it opens it shows your own shells again.
        .onChange(of: consoleShown) { _, shown in
            if !shown { consoleEventID = nil }
        }
        // ⌘D: the Changes tab on the latest turn, or on the branch before there are turns; again to close it.
        .keyCommand("diff.toggle", enabled: usable(.changes)) {
            withAnimation(NookTheme.reveal) {
                if changesShown {
                    putAway(.changes, in: viewModel.bottomTool == .changes ? .bottom : .side)
                } else {
                    openDiff(TurnDiffSelection(turn: outputs.turns.last?.id ?? TurnDiffSelection.branch))
                }
            }
        }
        // ⇧⌘T: the tab closed last comes back, in the panel it was in; the key goes on when there is none.
        .keyCommands(["panel.reopenClosed": reopenClosed])
        // ⌘J the terminal under the conversation, ⌥⌘B the side panel, ⌘W the tab of the panel with the keyboard.
        .keyCommands(["terminal.toggle": toggleTerminal,
                      // ⇧⌘B the session panel; without room for it the key goes on.
                      "sessionPanel.toggle": {
                          guard canDock else { return false }
                          toggleSessionPanel()
                          return true
                      },
                      "sidePanel.toggle": { viewModel.toggleSidePanel(); return true },
                      "tab.close": { closeFocusedTab() }])
    }

    /// ⌘J: the terminal in the bottom panel, and again to put it away (also from the side panel it may be in).
    private func toggleTerminal() -> Bool {
        guard SessionTool.terminal.available(in: directory) else { return false }
        withAnimation(NookTheme.reveal) {
            if viewModel.bottomTool == .terminal {
                viewModel.bottomTool = .conversation
            } else if viewModel.sessionTool == .terminal {
                closeTab(.terminal, in: .side)
            } else {
                viewModel.bottomTool = .terminal
            }
        }
        return true
    }

    /// This session's browser, if it was started.
    private var browser: BrowserStore? { SessionBrowsers.shared.existing(browserSession) }
    private var browserSession: BrowserSession { BrowserSession(run: runID, directory: directory) }

    /// ⌘W while the keyboard is in a side or bottom panel: closes the tab in view there. A terminal is left to
    /// `WindowKeys`, which closes just that terminal; anywhere else
    /// the key goes on and closes the window.
    private func closeFocusedTab() -> Bool {
        guard let window = NSApp.keyWindow, KeyCommandCenter.focusedTerminal(window.firstResponder) == nil,
              let area = FocusAreas.shared.area(of: window.firstResponder, in: window), area.isPanel else { return false }
        let slot: SessionPanelSlot = area == .bottomPanel ? .bottom : .side
        withAnimation(NookTheme.reveal) {
            let tool = viewModel[keyPath: slot.tool]
            switch tool {
            case .conversation, .picker:
                if area == .bottomPanel { viewModel.bottomTool = .conversation } else { viewModel.toggleSidePanel() }
            case .browser:
                if let page = browser?.page.id { closeSessionTab(.browser(page), in: slot) } else { closeTab(.browser, in: slot) }
            case .pullRequest:
                if let id = viewModel.activeSidePullRequest { closeSessionTab(.pullRequest(id), in: slot) } else { closeTab(.pullRequest, in: slot) }
            default:
                closeTab(tool, in: slot)
            }
        }
        return true
    }

    /// Which panels show on the right of the conversation, for `sidePanelsOpenAtOnce`.
    private struct RightPanels: Equatable {
        let side: Bool
        let covering: Bool
        let docked: Bool
    }

    /// Opens or closes the session panel. It opens with the room it needs to stay, not the extra room to dock again:
    /// from the toggle's own width it would otherwise not open, and take its toggle with it.
    /// The conversation takes its new width at once. Its column glides to the middle of that width instead of jumping.
    private func toggleSessionPanel() {
        let opening = sessionPanelClosed
        if opening { wasDocked = true }
        sessionPanelClosed.toggle()
        guard !reduceMotion else { return }
        let closedRoom = CGFloat(totalWidth - rightRoom)
        let openRoom = closedRoom - CGFloat(SidePanelRoom.of(Double(PanelLayout.sessionPanel)))
        let start = { (room: CGFloat) in
            let column = min(PanelLayout.chatColumn, room)
            return PanelSplit.columnStart(column: column, room: room)
        }
        chatSlide = opening ? start(closedRoom) - start(openRoom) : start(openRoom) - start(closedRoom)
    }

    /// Closes a tab opened from the conversation, and the panel with it when that was its only tab, so opening and closing
    /// it again leaves the conversation as it was instead of the list of tools.
    private func putAway(_ tool: SessionTool, in slot: SessionPanelSlot) {
        guard tabs(slot) == [tool] else {
            closeTab(tool, in: slot)
            return
        }
        if slot.tool == \NotchViewModel.bottomTool { viewModel.bottomTool = .conversation } else { viewModel.toggleSidePanel() }
    }

    /// Whether a panel shows the Changes tab.
    private var changesShown: Bool {
        shown(.side) == .changes || shown(.bottom) == .changes
    }

    /// Whether a panel shows the Terminal tab, where a command the agent runs opens.
    private var consoleShown: Bool {
        shown(.side) == .terminal || shown(.bottom) == .terminal
    }

    /// Opens a command the agent runs in the Terminal tab: in the bottom panel when the tab is open there, otherwise in
    /// the side panel on the right. The command the tab shows already goes away again, back to your own shells.
    private func toggleConsole(_ id: UUID) {
        withAnimation(NookTheme.reveal) {
            if consoleShown && consoleEventID == id {
                consoleEventID = nil
                return
            }
            consoleEventID = id
            if viewModel.bottomTool != .terminal { viewModel.sessionTool = .terminal }
        }
    }

    /// Opens a file in the File tab; the file in view there already closes the tab again.
    private func showFile(_ file: String) {
        withAnimation(NookTheme.reveal) {
            if shownFile == file {
                putAway(.file, in: .side)
            } else {
                fileViewer.open(FileTarget(path: file))
                viewModel.sessionTool = .file
            }
        }
    }

    /// Opens the Changes tab on a turn (and a file): where it is open already, otherwise in the side panel.
    private func openDiff(_ selection: TurnDiffSelection) {
        withAnimation(NookTheme.reveal) {
            diffSelection = selection
            if viewModel.bottomTool != .changes { viewModel.sessionTool = .changes }
        }
    }

    /// The real diff of these files in this turn (or in all turns), from the session's git snapshots.
    private func gitDiff(_ id: UUID, turn: TurnDiff, files: [TurnDiff.File], options: DiffReadOptions) async throws -> String {
        guard let start = turn.start, let end = turn.end else { return "" }
        var parts: [String] = []
        for file in files {
            parts.append(try await workspace.turnDiff(id, path: file.path, start: start, end: end, options: options))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Opens the most recently closed tab again (with its pull request), skipping tools that are open again or that
    /// this session cannot use.
    private func reopenClosed() -> Bool {
        let open = tabs(.side) + tabs(.bottom)
        guard let tab = viewModel.closedSessionTabs.reopen(skipping: { open.contains($0.tool) || $0.tool == .artifact || !$0.tool.available(in: directory) })
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
        let sideFree = side == .conversation || side == .picker
        guard viewModel.bottomTool == .outputs || side == .outputs || sideFree else { return false }
        outputSelection = id
        if viewModel.bottomTool != .outputs, side != .outputs {
            withAnimation(NookTheme.reveal) { viewModel.sessionTool = .outputs }
        }
        return true
    }

    /// Shows the Subagents tab: in the bottom panel when it is open there, otherwise beside the conversation. A terminal,
    /// page or diff you have open beside it stays (false).
    private func openSubagents() -> Bool {
        let side = viewModel.sessionTool
        if viewModel.bottomTool == .subagents || side == .subagents { return true }
        guard side == .conversation || side == .picker else { return false }
        withAnimation(NookTheme.reveal) { viewModel.sessionTool = .subagents }
        return true
    }

    /// Dragging the line above the bottom panel up makes it taller.
    private func dragBottom(_ offset: Double) {
        let start = dragStart ?? BottomPanelLayout.height(bottomHeight, available: totalHeight)
        dragStart = start
        PanelDrag.step($liveBottomHeight, to: BottomPanelLayout.height(start - offset, available: totalHeight))
    }

    private func panel(_ slot: SessionPanelSlot, tool: SessionTool, maximized: Binding<Bool>? = nil) -> some View {
        SessionToolPanel(directory: directory, runID: runID, tool: tool, maximized: maximized, tabs: tabs(slot), pullRequest: viewModel.sidePullRequest,
                         pullRequestTabs: viewModel.sidePullRequestTabs, activePullRequest: viewModel.activeSidePullRequest,
                         outputs: outputs.outputs, outputSelection: $outputSelection, outputsFresh: outputs.fresh,
                         subagents: outputs.subagents, commands: outputs.commands, subagentsFresh: outputs.subagentsFresh,
                         turns: outputs.turns,
                         diffSelection: Binding(get: { diffSelection ?? TurnDiffSelection(turn: TurnDiffSelection.branch) },
                                                set: { diffSelection = $0 }),
                         loadDiff: runID.flatMap { id in
                             workspace.run(id)?.isRemote == false ? { turn, files, options in
                                 try await gitDiff(id, turn: turn, files: files, options: options)
                             } : nil
                         },
                         closeHelp: tr(slot.closeHelp),
                         show: { item in withAnimation(NookTheme.swap) { viewModel[keyPath: slot.tool] = item } },
                         selectPullRequest: { id in
                             withAnimation(NookTheme.swap) { viewModel.activeSidePullRequest = id; viewModel.sessionTool = .pullRequest }
                         },
                         openPullRequest: { request in withAnimation(NookTheme.swap) { viewModel.openSidePullRequest(request) } },
                         updatePullRequest: { viewModel.updateSidePullRequest($0) },
                         showPullRequestList: { withAnimation(NookTheme.swap) { viewModel.showSidePullRequestList() } },
                         closeTab: { closeSessionTab($0, in: slot) },
                         close: {
                             if slot.tool == \NotchViewModel.sessionTool { viewModel.toggleSidePanel() } else { viewModel.bottomTool = .conversation }
                         },
                         console: runID.flatMap { run in consoleEventID.map { CommandConsoleRef(run: run, event: $0) } },
                         showConsole: { id in withAnimation(NookTheme.reveal) { consoleEventID = id } },
                         closeConsole: { withAnimation(NookTheme.reveal) { consoleEventID = nil } },
                         pinned: viewModel.pinnedTabs,
                         moveTab: { moved, onto in
                             viewModel[keyPath: slot.tabs] = SidePanelTabOrder.moving(viewModel[keyPath: slot.tabs], moved: moved, onto: onto,
                                                                                     pinned: viewModel.pinnedTabs)
                         },
                         togglePin: { tool in
                             let next = SidePanelTabOrder.toggling(tool, in: viewModel[keyPath: slot.tabs], pinned: viewModel.pinnedTabs)
                             withAnimation(NookTheme.swap) {
                                 viewModel[keyPath: slot.tabs] = next.tabs
                                 viewModel.pinnedTabs = next.pinned
                             }
                         })
            .environment(\.sidePanelTakesFocus, panelTakesFocus)
            .focusArea(slot.tool == \NotchViewModel.bottomTool ? .bottomPanel : .sidePanel)
    }

    /// Closes a tab. One of several Pull request tabs goes by itself, and the one next to it comes into view.
    private func closeSessionTab(_ tab: SessionTab, in slot: SessionPanelSlot) {
        switch tab {
        case .tool(let item): closeTab(item, in: slot)
        case .pullRequest(let id):
            if viewModel.sidePullRequestTabs.count > 1 {
                let request = viewModel.sidePullRequestTabs.first { $0.id == id }?.request
                viewModel.closedSessionTabs.push(ClosedSessionTab(tool: .pullRequest, bottom: false, pullRequest: request))
                _ = withAnimation(NookTheme.swap) { viewModel.closeSidePullRequest(id) }
            } else {
                closeTab(.pullRequest, in: slot)
            }
        case .browser(let id):
            // One of several browser tabs goes by itself; the last one closes the browser like any tool.
            if let browser, browser.pages.count > 1 {
                withAnimation(NookTheme.swap) { browser.close(id) }
            } else {
                closeTab(.browser, in: slot)
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
            if item == .artifact { EmbeddedAppStore.shared.closeArtifact() }
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
    @Environment(\.lineBleed) private var bleed

    var body: some View {
        ZStack {
            NookDivider().bleedsHorizontally(bleed)
            Capsule()
                .fill(hovering || dragging ? NookTheme.textSecondary : NookTheme.line2)
                .frame(width: 36, height: 4)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .contentShape(Rectangle())
        // The system's resize cursor, which also stays while the pointer runs ahead of the line during a drag.
        .pointerStyle(.rowResize)
        .onHover { hovering = $0 }
        .gesture(
            // Global coordinates: the line itself moves while you drag it.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { dragging = true }
                    onDrag(Double(value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .help(tr("panel.resize"))
        .accessibilityLabel(tr("panel.resize"))
    }
}

/// One tab of a tool panel: a tool, or one of the Pull request or browser tabs (there can be several of each).
private enum SessionTab: Hashable {
    case tool(SessionTool)
    case pullRequest(UUID)
    case browser(UUID)
}

/// A tool panel beside or under a session: its open tools as tabs, + to open another, the button that closes it, and
/// the tool in view (or the list of tools while none is open). It sits flat on the notch, not as a card.
private struct SessionToolPanel: View {
    let directory: String
    let runID: UUID?
    let tool: SessionTool
    /// Whether it takes the whole workbench; nil for the bottom panel, and while it must cover the conversation anyway.
    var maximized: Binding<Bool>? = nil
    let tabs: [SessionTool]
    let pullRequest: PullRequestOpenRequest?
    let pullRequestTabs: [SidePullRequestTab]
    let activePullRequest: UUID?
    let outputs: [SessionOutput]
    @Binding var outputSelection: String?
    let outputsFresh: Bool
    let subagents: [SubagentInfo]
    let commands: [BackgroundCommandInfo]
    let subagentsFresh: Bool
    /// The agent's turns and what the Changes tab shows of them or of git.
    let turns: [TurnDiff]
    @Binding var diffSelection: TurnDiffSelection
    let loadDiff: ((TurnDiff, [TurnDiff.File], DiffReadOptions) async throws -> String)?
    let closeHelp: String
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
    /// A command the agent runs, opened from the conversation: the Terminal tab shows it in place of your shells.
    var console: CommandConsoleRef? = nil
    /// Shows another command of the agent in the Terminal tab: the one it runs now, when you ask for it.
    var showConsole: (UUID) -> Void = { _ in }
    var closeConsole: () -> Void = {}
    /// The tools pinned to the front of the tab row, what dragging one tab onto another does, and the pin in a tab's menu.
    var pinned: Set<SessionTool> = []
    var moveTab: (_ moved: SessionTool, _ onto: SessionTool) -> Void = { _, _ in }
    var togglePin: (SessionTool) -> Void = { _ in }
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @ObservedObject private var files = FileViewerStore.shared
    /// Says when this session's browser was started.
    @ObservedObject private var browsers = SessionBrowsers.shared
    /// The browser's tabs with their titles, and the one in view, once the browser was started (it is not started for it).
    @State private var browserTabs: [BrowserStore.Tab] = []
    @State private var browserActive: UUID?
    /// The panel still slides in: a pull request page it opens on waits with its full page until it is in place.
    @State private var opening = true

    private var browserSession: BrowserSession { BrowserSession(run: runID, directory: directory) }
    /// This session's browser, if it was started.
    private var startedBrowser: BrowserStore? { browsers.existing(browserSession) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tool == .terminal, console == nil { SidePanelToolbar { SessionTerminalBar(directory: directory) } }
            if tool == .browser, !directory.isEmpty {
                let browser = browsers.store(browserSession)
                DevServerStrip(directory: directory, browser: browser).id(ObjectIdentifier(browser))
            }
            Group {
                switch tool {
                case .picker:
                    SessionToolPicker(directory: directory) { launch($0) }
                case .terminal:
                    if let console {
                        LiveCommandConsole(timelines: workspace.timelineChanges(for: console.run), workspace: workspace, console: console,
                                           show: showConsole, close: closeConsole)
                    } else {
                        SessionTerminalsView(directory: directory).id(directory)
                    }
                case .outputs: SessionOutputsPanel(outputs: outputs, selection: $outputSelection)
                case .subagents: SessionSubagentsPanel(agents: subagents, commands: commands)
                case .changes:
                    // A session on another machine: git is there, and only its own review reads it (over ssh).
                    if let runID, workspace.run(runID)?.isRemote == true, diffSelection.source.isGit {
                        ChangesSheet(runID: runID, initialFile: nil, onClose: close).id(runID)
                    } else {
                        TurnDiffPanel(turns: turns, selection: $diffSelection, directory: directory.isEmpty ? nil : directory,
                                      runID: runID, load: loadDiff)
                            .id(directory)
                    }
                case .pullRequest:
                    if let pullRequest {
                        // The page's own top bar starts with the arrow back to the list to pick another, so there is no
                        // extra row above it.
                        let listed = PullRequestStore.shared.accounts.first { $0.id == pullRequest.account }
                            .map { $0.reviews + $0.mine + $0.watched } ?? []
                        PullRequestDetailView(accountID: pullRequest.account, item: pullRequest.item,
                                              stack: PullRequestStack.stack(of: pullRequest.item, in: listed) ?? [],
                                              stackHistory: PullRequestStack.history(of: pullRequest.item, in: listed) ?? [],
                                              onOpenPullRequest: { openPullRequest(PullRequestOpenRequest(account: pullRequest.account, item: $0)) },
                                              onUpdate: { updated in
                            updatePullRequest(PullRequestOpenRequest(account: pullRequest.account, item: updated))
                        }, onBack: showPullRequestList, waitsForPanel: opening, focus: pullRequest.focus)
                            .id(pullRequest.account + " " + pullRequest.item.id)
                    } else {
                        SidePanelPullRequestPicker(directory: directory, runID: runID) { openPullRequest($0) }
                    }
                case .artifact:
                    SessionArtifactPanel()
                case .file:
                    SessionFilePanel(directory: directory)
                default:
                    let browser = browsers.store(browserSession)
                    // Its own view for each browser: it counts itself as showing that browser.
                    BrowserView(store: browser).id(ObjectIdentifier(browser))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What the agent opened here is in view now, also when it opens more while you look.
        .onAppear { bridge.markSeen(directory, tool.rawValue) }
        .task {
            try? await Task.sleep(for: NookTheme.tabSettle)
            opening = false
        }
        .onChange(of: tool) { _, next in bridge.markSeen(directory, next.rawValue) }
        .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
        // Another session without a browser shows none of the last one's tabs.
        .onChange(of: startedBrowser.map(ObjectIdentifier.init)) { _, started in
            if started == nil {
                browserTabs = []
                browserActive = nil
            }
        }
        .onReceive(startedBrowser?.$tabs.eraseToAnyPublisher() ?? Empty<[BrowserStore.Tab], Never>().eraseToAnyPublisher()) {
            browserTabs = $0
        }
        .onReceive(startedBrowser?.$page.map(\.id).eraseToAnyPublisher() ?? Empty<UUID, Never>().eraseToAnyPublisher()) {
            browserActive = $0
        }
    }

    /// The open tabs, + right after them, and the button that closes the panel. The
    /// tabs scroll sideways when they do not fit, so the close button always stays in view.
    private var header: some View {
        SidePanelTabBar(items: tabs.flatMap(tabItems).map(pinnedMark), selected: selectedTab, onSelect: selectTab, onClose: closeTab,
                        onMove: { moved, onto in moveTab(tool(of: moved), tool(of: onto)) },
                        onTogglePin: { togglePin(tool(of: $0)) }) {
            addMenu
        } trailing: {
            if let maximized {
                ToolbarIconButton(maximized.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tr(maximized.wrappedValue ? "agents.tool.restore" : "agents.tool.maximize")) {
                    maximized.wrappedValue.toggle()
                }
            }
            SidePanelCloseButton(help: closeHelp, action: close)
        }
    }

    /// The tool a tab belongs to: a pull request or a browser tab is one of its tool's tabs, and pins and moves with it.
    private func tool(of tab: SessionTab) -> SessionTool {
        switch tab {
        case .tool(let item): return item
        case .pullRequest: return .pullRequest
        case .browser: return .browser
        }
    }

    private func pinnedMark(_ item: SidePanelTabItem<SessionTab>) -> SidePanelTabItem<SessionTab> {
        var marked = item
        marked.pinned = pinned.contains(tool(of: item.value))
        return marked
    }

    /// The tab in view: a Pull request tab by its own id, as there can be several.
    private var selectedTab: SessionTab {
        if tool == .pullRequest, let active = activePullRequest ?? pullRequestTabs.first?.id { return .pullRequest(active) }
        if tool == .browser, let active = browserActive, browserTabs.contains(where: { $0.id == active }) { return .browser(active) }
        return .tool(tool)
    }

    private func selectTab(_ tab: SessionTab) {
        switch tab {
        case .tool(let item): show(item)
        case .pullRequest(let id): selectPullRequest(id)
        case .browser(let id):
            browsers.store(browserSession).select(id)
            show(.browser)
        }
    }

    /// The tabs of a tool: one, or for the Pull request tool one for each pull request (or list) open, and for the
    /// browser one for each of its tabs, followed by + for another.
    private func tabItems(_ item: SessionTool) -> [SidePanelTabItem<SessionTab>] {
        if item == .browser { return browserTabItems }
        guard item == .pullRequest, !pullRequestTabs.isEmpty else { return [tabItem(item)] }
        return pullRequestTabs.map { tab in
            let request = tab.request
            let title = request.map { "#\($0.item.number) " + ($0.item.title.isEmpty ? $0.item.repo : $0.item.title) } ?? item.title
            let fresh = item != tool && bridge.hasUnseen(directory, item.rawValue)
            return SidePanelTabItem(value: .pullRequest(tab.id), title: title, icon: AnyView(SidePanelPullRequestIcon(item: request?.item)),
                                    fresh: fresh, help: request.map { $0.item.repo + " #\($0.item.number)" } ?? item.help)
        }
    }

    /// The browser's tabs, each with its page's title; the last one has + right after it for a new browser tab.
    private var browserTabItems: [SidePanelTabItem<SessionTab>] {
        let item = SessionTool.browser
        let fresh = item != tool && bridge.hasUnseen(directory, item.rawValue)
        let add = AnyView(ToolbarIconButton("plus", tr("browser.newTab"), width: 20) {
            browsers.store(browserSession).newTab()
            show(.browser)
        })
        guard !browserTabs.isEmpty else {
            return [SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelSymbol(symbol: "globe")),
                                     fresh: fresh, help: item.help, after: add)]
        }
        return browserTabs.enumerated().map { index, tab in
            SidePanelTabItem(value: .browser(tab.id), title: tab.title.isEmpty ? item.title : tab.title,
                             icon: AnyView(SidePanelSymbol(symbol: "globe")), fresh: fresh && tab.id == browserActive,
                             help: tab.title.isEmpty ? item.help : tab.title,
                             after: index == browserTabs.count - 1 ? add : nil)
        }
    }

    /// A tab with what it shows: the file's name, the name of a tool.
    private func tabItem(_ item: SessionTool) -> SidePanelTabItem<SessionTab> {
        let fresh = item != tool && (item == .outputs ? outputsFresh
            : item == .subagents ? subagentsFresh : bridge.hasUnseen(directory, item.rawValue))
        switch item {
        case .pullRequest:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelPullRequestIcon(item: nil)),
                                    fresh: fresh, help: item.help)
        case .file:
            let path = files.target?.path
            return SidePanelTabItem(value: .tool(item), title: path.map { ($0 as NSString).lastPathComponent } ?? item.title,
                                    icon: AnyView(SidePanelSymbol(symbol: item.symbol)), fresh: fresh,
                                    help: path.map(AgentPathFormat.tilde) ?? item.help)
        default:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelSymbol(symbol: item.symbol)),
                                    fresh: fresh, help: item.help)
        }
    }

    /// + : the tools to open, each in its own tab (or the tab it already has), in Nook's own dropdown panel.
    /// The tool in view is faintly filled; one the session cannot use says why.
    private var addMenu: some View {
        ComposerDropdown(width: 220) {
            Image(icon: "plus")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        } content: {
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

/// An open panel before any tab: the tools, one row each with the key that opens it.
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
            .roundedBackground(NookTheme.field, radius: NookTheme.Radius.panel)
            .roundedClip(NookTheme.Radius.panel)
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

/// The local servers this session's folder runs, as small buttons in a bar above the browser (`SidePanelToolbar`):
/// one tap opens it. Checked every few seconds while the browser is open; without any there is no bar.
struct DevServerStrip: View {
    let directory: String
    @ObservedObject var browser: BrowserStore
    @State private var servers: [DevServer] = []
    /// Why a server has no Stop: shown under the bar after a tap on its stop button.
    @State private var note: String?
    /// Bumped after a stop, so the scan looks again at once.
    @State private var rescan = 0

    var body: some View {
        // A VStack, not a Group: it exists while still empty, so the scan below starts.
        VStack(alignment: .leading, spacing: 0) {
            if !servers.isEmpty {
                SidePanelToolbar {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Image(icon: "dot.radiowaves.left.and.right")
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
                                        .background(NookTheme.shape(NookTheme.Radius.control).fill(open ? NookTheme.smoke : NookTheme.field))
                                }
                                .buttonStyle(.plain)
                                .help(server.url.absoluteString)
                                if server.pid > 0 { stopButton(server) }
                            }
                        }
                    }
                }
                if let note {
                    Text(note)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NookTheme.Spacing.md)
                        .padding(.bottom, NookTheme.Spacing.sm)
                        .transition(.opacity)
                }
            }
        }
        .task(id: ScanKey(directory: directory, rescan: rescan)) {
            let folder = WorkspacePathPolicy.normalize(directory)
            // Each scan starts `lsof` twice (100–500 ms of work). Every 3 seconds right after something changed, so a
            // server that just started shows up at once; up to every 15 seconds while the list stays the same.
            var wait: UInt64 = 3
            while !Task.isCancelled {
                let shells = TerminalStore.shared.sessions.map(\.shellPID)
                let found = await Task.detached(priority: .utility) { () async -> [DevServer] in
                    // Only listeners that serve a page: not the folder's database or debugger.
                    var servers = await DevServerProbe.pages(DevServerScanner.scan(folder: folder))
                    servers = DevServerOwnership.mark(servers, roots: .current(shells: shells))
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

    private struct ScanKey: Equatable {
        var directory: String
        var rescan: Int
    }

    /// Stops a server Nook started; for any other server it says why not, since stopping something you run elsewhere
    /// would take it away behind your back.
    private func stopButton(_ server: DevServer) -> some View {
        Button {
            guard server.startedByNook else {
                withAnimation(NookTheme.reveal) {
                    note = note == nil ? tr("automation.server.notOurs", server.command, String(server.port)) : nil
                }
                return
            }
            let shells = TerminalStore.shared.sessions.map(\.shellPID)
            Task {
                let stopped = await Task.detached(priority: .userInitiated) {
                    DevServerOwnership.stop(server, roots: .current(shells: shells))
                }.value
                withAnimation(NookTheme.reveal) {
                    note = stopped ? nil : tr("automation.server.notOurs", server.command, String(server.port))
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                rescan += 1
            }
        } label: {
            Image(icon: "stop.fill")
                .font(NookTheme.font(8, .semibold))
                .foregroundStyle(server.startedByNook ? NookTheme.textSecondary : NookTheme.textTertiary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(server.startedByNook ? tr("automation.server.stop", String(server.port)) : tr("automation.server.stopUnavailable"))
        .accessibilityLabel(tr("automation.server.stop", String(server.port)))
    }
}
