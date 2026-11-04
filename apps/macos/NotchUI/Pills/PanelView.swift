import SwiftUI

/// The expanded panel: Nook (home and chat in one), Agents, Chats, and Music while something plays.
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
    @Environment(\.lineBleed) private var lineBleed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The width of the Agents session list, which the footer takes on a tab without a list of its own.
    @AppStorage("nook.agents.listWidth") private var agentsListWidth = PanelLayout.agentsList
    /// Search everything is open over the tab (⌘K or ⇧⌘F, or the magnifying glass in the header).
    @State private var searching = false
    /// The header's rarer button (the window) shows while the pointer is on the header, so the toolbar keeps to what you
    /// use most. Search and talk always show.
    @State private var headerHover = false
    /// Split view: the tab beside this one (`PanelSplitChoice`), and how wide it is.
    @AppStorage(PanelSplitChoice.key) private var split = ""
    @AppStorage(PanelSplitChoice.widthKey) private var splitWidth = PanelLayout.split
    /// The width of the tab row, which the tab beside this one is fitted into. Measured all the time but kept in a box,
    /// so a resize of the window does not redraw the panel on every frame; `contentWidth` is written (and redraws it) only
    /// while that tab shows. Opening it redraws the panel anyway, which then reads the box.
    @State private var measuredWidth = MeasuredWidth()
    @State private var contentWidth: Double = 0
    /// You work in the tab beside this one: the tab bar lights that tab and outlines this one, so you see which of the
    /// two you are in. It follows the pointer, but not while you type: then it stays with the field you type in until
    /// you click somewhere (`followPointer`).
    @State private var splitHover = false
    /// The pointer is on the tab beside this one, whether or not the tab bar follows it now.
    @State private var pointerOnSide = false
    @State private var clickMonitor: Any?
    /// A tab draws the main window's sidebar (`PanelSidebarTop`): the header with the floating capsule stays out.
    @State private var sidebarShown = false

    /// The height of the header row (the floating capsule with the tabs, or a task's title), so Nook can be centered
    /// on it: a 30 pt button with the capsule's 4 pt padding above and below.
    static let headerHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sheet {
                NotchSheetView(sheet: sheet, headerInset: headerInset, close: closeSheet) {
                    closeSheet()
                    if !inWindow { viewModel.show(.idle) }
                }
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            } else {
              // Back brings the tab in as switching tabs does (a quick fade); the tab itself leaves at once under a task.
              VStack(alignment: .leading, spacing: 0) {
                if !usesSidebar { header }
                // A Double Tap Nook works on, or just finished: every step, and what it typed, to check.
                if !app.demoMode {
                    DoubleTapRunBar(doubleTap: DoubleTap.shared)
                        .padding(.leading, usesSidebar ? PanelSidebarMetrics.inset : headerInset)
                }
                HStack(alignment: .top, spacing: 0) {
                    // A tab without a list of its own (Music) still gets the sidebar in the main window.
                    if sidebar != nil && !footerUnderList { sidebarColumn }
                    // Switching tabs: the old tab goes at once and the new one fades in on its own, outside the spring that
                    // moves the tab capsule and resizes the panel. In that spring the old and the new tab were both on
                    // screen and laid out on every frame, and every change the new tab made as it appeared (its width, its
                    // lists) was animated too: that was the lag between Nook, Agents, Chats and Music.
                    content
                        .id(tab)
                        .transition(.asymmetric(insertion: .opacity.animation(NookTheme.tabFade), removal: .identity))
                        .transaction(value: tab) { $0.animation = nil }
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let side = splitTab {
                        // Swapping the two tabs: the same as switching tabs above, the old one goes at once and the new
                        // one fades in, instead of two whole tabs laid out on every frame of the spring.
                        PanelSplitPane(viewModel: viewModel, tab: side, inWindow: inWindow, swap: { swapSplit(side) })
                            // The sidebar is the main tab's: the tab beside it starts with its own list.
                            .environment(\.panelSidebar, nil)
                            .id(side)
                            .transition(.asymmetric(insertion: .opacity.animation(NookTheme.tabFade), removal: .identity))
                            .transaction(value: side) { $0.animation = nil }
                            .sidePanel(.trailing, width: $splitWidth, defaultWidth: PanelLayout.split,
                                       available: splitAvailable, rest: PanelLayout.minimumConversation + PanelSplit.handle)
                            .onHover { inside in
                                pointerOnSide = inside
                                followPointer(typing: NSApp.keyWindow?.firstResponder is NSText)
                            }
                            .onAppear {
                                // A click picks the pane it lands in, also the field you type in next.
                                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                                    DispatchQueue.main.async { followPointer(typing: false) }
                                    return event
                                }
                            }
                            .onDisappear {
                                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                                clickMonitor = nil
                                pointerOnSide = false
                                splitHover = false
                            }
                    }
                }
                // The second tab opens and closes at once, the main tab taking its new width in the same frame.
                .sidePanelsOpenAtOnce(splitTab)
                // In layout steps (`onLayoutWidthChange`), and as state only while a split tab shows: it is read only
                // by the split pane, and otherwise every step of a window resize ran this whole body again.
                .onLayoutWidthChange { width in
                    measuredWidth.value = width
                    if splitTab != nil, contentWidth != width { contentWidth = width }
                }
                .environment(\.panelSidebar, sidebar)
                .onPreferenceChange(PanelSidebarShown.self) { shown in
                    if sidebarShown != shown { sidebarShown = shown }
                }
                .padding(.top, usesSidebar ? 0 : headerInset > 0 ? PanelOrb.belowHeader : NookTheme.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Agents, the chat and Chats keep the footer under their list. A tab without one (Music) shows it at the
                // bottom as wide as the Agents list, so the refresh and update button stays where it is on Agents; in
                // the main window it is at the foot of the sidebar instead.
                if !footerUnderList && !app.demoMode && sidebar == nil {
                    PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() },
                                history: app.history)
                        .frame(width: agentsListWidth)
                        .padding(.top, NookTheme.Spacing.md)
                }
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .transition(.asymmetric(insertion: .opacity.animation(NookTheme.tabFade), removal: .identity))
            }
        }
        .animation(NookTheme.swap, value: sheet)
        .overlay(alignment: .top) {
            if searching, sheet == nil {
                ZStack(alignment: .top) {
                    // A click beside the search closes it, as Escape does.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { searching = false }
                        .accessibilityHidden(true)
                    SearchPanel(select: select) { searching = false }
                        .padding(.top, Self.headerHeight + NookTheme.Spacing.md)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .animation(NookTheme.reveal, value: searching)
        .onChange(of: searching) { _, open in if !inWindow { viewModel.panelSearchOpen = open } }
        .onDisappear { if !inWindow { viewModel.panelSearchOpen = false } }
        // Usage (limits, cost, tokens) as a modal over the panel, from the footer's usage button on any tab.
        .overlay {
            if app.usageModalOpen && !app.demoMode {
                UsageModal { app.usageModalOpen = false }
                    .transition(.opacity)
            }
        }
        .animation(NookTheme.reveal, value: app.usageModalOpen)
        .background {
            // Native shortcuts for ⌘K and ⇧⌘F: never flip the search unseen while a sheet covers the tab.
            Button("") { searching.toggle() }.keyboardShortcut("k", modifiers: [.command])
                .disabled(sheet != nil || app.demoMode)
                .opacity(0).accessibilityHidden(true)
            Button("") { searching.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(sheet != nil || app.demoMode)
                .opacity(0).accessibilityHidden(true)
        }
        // ⌘K (a rule, see `Keybindings`): search everything from every tab, and again to close it.
        .keyCommand("search.toggle", enabled: sheet == nil && !app.demoMode) { searching.toggle() }
        // F6 between the window's parts; ⌘W, ⌘D and ⇧⌘D in a terminal.
        .windowKeyCommands()
        // Short results from anywhere in Nook (saved, approved, failed) show over the panel's bottom edge, and above them
        // what waits for you there: a permission request, an agent's question, a short note.
        .nookToastHost {
            if sheet == nil {
                PanelApprovalBar(viewModel: viewModel, tab: tab, sheet: sheet, hub: app.hub, workspace: app.workspace)
            }
        }
    }

    /// What the main window's sidebar shows on top (`PanelSidebarContext`); nil in the notch and in demo mode, which
    /// keep the header's capsule.
    private var sidebar: PanelSidebarContext? {
        guard inWindow, !app.demoMode else { return nil }
        let side = splitTab
        let onSide = splitHover && side != nil
        let main = tabItems.first { PanelSplitChoice.same($0.value, tab) }?.value ?? tab
        return PanelSidebarContext(
            tabs: tabItems, selected: onSide ? side ?? main : main, beside: onSide ? main : side, current: tab,
            select: { value in if value == side { swapSplit(value) } else { select(value) } },
            search: { searching.toggle() },
            talk: { viewModel.startListening() })
    }

    /// The tab draws the sidebar now: no header of the panel's own.
    private var usesSidebar: Bool { sidebar != nil && sidebarShown }

    /// The sidebar of a tab without a list (Music): the head, the tabs, and the footer at the bottom, as wide as the
    /// Agents list.
    private var sidebarColumn: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PanelSidebarTop()
                Spacer(minLength: 0)
                PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() }, history: app.history)
            }
            .panelSidebarColumn()
            .padding(.trailing, PanelSidebarMetrics.inset)
            // Never narrower than its head, with the inset on both sides.
            .frame(width: max(agentsListWidth, Double(PanelSidebarMetrics.headWidth + PanelSidebarMetrics.inset * 2)))
            NookDivider(vertical: true)
                .bleedsVertically(lineBleed)
                .padding(.trailing, NookTheme.Spacing.xl)
        }
    }

    /// Agents, the chat and Chats show the footer under their own list instead of along the bottom.
    private var footerUnderList: Bool {
        switch tab {
        case .nook, .chat, .connect, .shelf, .agents, .inbox: return true
        case .music: return false
        }
    }

    /// Lights the tab of the pane under the pointer, unless you are typing: the pointer drifting over the other pane
    /// then does not take the lit tab from the field you type in.
    private func followPointer(typing: Bool) {
        guard !typing, splitHover != pointerOnSide else { return }
        withAnimation(NookTheme.hover) { splitHover = pointerOnSide }
    }

    /// The room for the tab beside this one: the latest measure. Reading `contentWidth` is what redraws the panel when
    /// the width changes while that tab shows.
    private var splitAvailable: Double {
        _ = contentWidth
        return measuredWidth.value
    }

    /// The tab split view shows beside this one, if any.
    private var splitTab: PanelTab? { app.demoMode ? nil : PanelSplitChoice.side(split, current: tab) }

    /// Makes the tab beside this one the main tab, and puts this one beside it.
    private func swapSplit(_ side: PanelTab) {
        let main = PanelSplitChoice.choices.first { PanelSplitChoice.same($0, tab) }
        withAnimation(NookTheme.reveal) { split = main?.rawValue ?? "" }
        select(side)
    }

    /// The task open over the tab: the notch's, or the main window's.
    private var sheet: NotchSheet? { inWindow ? viewModel.windowSheet : viewModel.sheet }

    private func closeSheet() {
        if inWindow { viewModel.windowSheet = nil } else { viewModel.sheet = nil }
    }

    /// Shows `tab`: in the pane beside this tab when it is the one split view shows there (`PanelSplitChoice.landing`).
    private func select(_ tab: PanelTab) {
        if inWindow {
            withAnimation(NookTheme.swap) {
                viewModel.windowSheet = nil
                viewModel.windowTab = PanelSplitChoice.landing(tab, current: self.tab)
            }
        } else {
            viewModel.show(.panel(PanelSplitChoice.landing(tab, current: self.tab)), inNotch: true)
        }
    }

    /// A footer page (pull requests, usage) from another tab: it opens on Agents.
    private func openOnAgents(_ page: String) {
        viewModel.selectedAgentID = page
        select(.agents)
    }

    /// The tabs, with what waits for you on them: an amber count on Agents. In the window, the tooltip names the tab's
    /// shortcut (⌘1, ⌘2, …). The tab split view shows beside this one stays in the bar, even Music while nothing plays.
    private var tabItems: [NookTabBar<PanelTab>.Item] {
        let tabs = PanelTab.visible(musicAvailable: app.nowPlaying.current != nil || tab == .music || splitTab == .music)
        let waiting = app.activeAgents.filter { $0.status == .waiting || $0.approvalID != nil }.count
        return tabs.enumerated().map { index, value in
            NookTabBar<PanelTab>.Item(value: value, title: value.title,
                                      count: value == .agents ? waiting : 0,
                                      help: inWindow ? "\(value.title) (⌘\(index + 1))" : nil)
        }
    }

    /// The tabs, search, talk, the bell and split view in one floating capsule centered over the content, so the header is not a
    /// bar of its own and needs no line under it. The rarer buttons (the window, close, the gear in demo mode) stay
    /// outside it at the trailing edge.
    private var header: some View {
        HStack(spacing: 0) {
            if inWindow {
                // Empty header space moves the window, as a title bar does. Its height is fixed: a clear color takes all
                // the height it is offered, and left free it stretched the header to half the window. A double-click
                // zooms the window to fill the screen, as a title bar does in every Mac app.
                WindowTitleBarArea()
                    .frame(minWidth: 8, maxWidth: .infinity)
                    .frame(height: Self.headerHeight)
            } else {
                Spacer()
            }
            // The gear sits in the footer instead, which every tab shows outside demo mode.
            let gear = app.demoMode
            HStack(spacing: NookTheme.Spacing.xxs) {
                if !inWindow, headerHover {
                    // Go on in the main window, on this tab, with more room.
                    NookIconButton(systemName: "macwindow", label: tr("menu.window"), size: 30) { app.openWindow(continuing: tab) }
                        .help(tr("menu.window"))
                        .transition(.opacity)
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
        // Centered on the header (after Nook's room on the left); the empty space around it still moves the window.
        .overlay { headerCapsule }
        .padding(.leading, headerInset)
        // Only the notch shows something on hover (the window button); in the window it would redraw the panel for nothing.
        .onHover { hovering in
            guard !inWindow else { return }
            withAnimation(NookTheme.hover) { headerHover = hovering }
        }
    }

    /// The tabs, a thin line, then search, talk and split view: one quiet `surface` capsule with a hairline edge, a tonal
    /// step above the canvas and no shadow, so the header belongs to the window instead of floating over it. The selected
    /// tab is on `smoke` with bright text, as everywhere else; the accent is kept for state.
    private var headerCapsule: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            // The tab beside this one is outlined, and a click on it swaps the two, as the swap button in its pane does.
            // With the pointer on that tab's pane, the two trade places in the bar: the tab you work in is the lit one.
            let main = tabItems.first { PanelSplitChoice.same($0.value, tab) }?.value ?? tab
            let side = splitTab
            let onSide = splitHover && side != nil
            NookTabBar(items: tabItems, selected: onSide ? side ?? tab : tab, onSelect: { value in
                if value == side { swapSplit(value) } else { select(value) }
            }, beside: onSide ? main : side)
            NookDivider(vertical: true)
                .frame(height: 18)
                .padding(.horizontal, NookTheme.Spacing.sm)
            if !app.demoMode {
                NookIconButton(systemName: "magnifyingglass", label: tr("search.button"), size: 30) { searching.toggle() }
                    .help(tr("search.button"))
            }
            NookIconButton(systemName: "mic", label: tr("button.talk"), size: 30) { viewModel.startListening() }
                .help(tr("button.talk"))
            // A second tab beside this one: the chats, the music or the Nook chat while you work here.
            if !app.demoMode { PanelSplitButton(current: tab) }
        }
        .padding(NookTheme.Spacing.xs)
        .background(
            Capsule().fill(NookTheme.surface)
                .overlay(Capsule().strokeBorder(NookTheme.line, lineWidth: 1))
        )
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nook, .chat, .connect, .shelf:
            if inWindow {
                NookChatView(viewModel: viewModel, chat: app.chat, compact: false, openOnAgents: openOnAgents)
            } else {
                NookChatTab(viewModel: viewModel, openOnAgents: openOnAgents)
            }
        case .agents: AgentsTab(viewModel: viewModel)
        case .inbox: ChatsTab(viewModel: viewModel, openOnAgents: openOnAgents, inWindow: inWindow)
        case .music: MusicTab()
        }
    }
}

/// A width read during layout without redrawing the view that holds it (see `PanelView.measuredWidth`).
private final class MeasuredWidth {
    var value: Double = 0
}

/// A permission request or multiple-choice question that comes in while the panel (or the main window) is open: one
/// compact notice floating over the panel's bottom edge, where toasts show, instead of a card over the whole notch. Hidden while the session that asks is on screen,
/// which shows the whole request itself.
struct PanelApprovalBar: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    /// The task open over the tab, if any: the session behind it is not on screen.
    let sheet: NotchSheet?
    @ObservedObject var hub: AgentHub
    /// Not observed: it changes with every streamed token, and `AppModel` already redraws when a session it runs asks
    /// for an approval or has a question.
    let workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the bar shows now, so a request coming or going rises and fades like a toast instead of popping in.
    private var shownID: String? {
        if let approval = app.approvals.pending.first(where: { !onScreen($0) }) { return "approval-\(approval.id)" }
        if !app.demoMode, let question = hub.questions.first(where: { !onScreen($0) }) { return "question-\(question.id)" }
        return viewModel.panelNotice.map { "notice-\($0.id)" }
    }

    var body: some View {
        bar
            .animation(NookTheme.reveal, value: shownID)
    }

    @ViewBuilder
    private var bar: some View {
        let waiting = app.approvals.pending
        if let approval = waiting.first(where: { !onScreen($0) }) {
            PanelNoticeBar(title: approval.title, detail: subtitle(approval, more: waiting.count - 1),
                           symbol: approval.danger ? "exclamationmark.triangle.fill" : "hand.raised.fill",
                           tone: approval.danger ? NookTheme.coral : NookTheme.amber, help: approval.command,
                           floating: true) {
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
            .transition(.nookFloating(reduceMotion: reduceMotion))
        } else if !app.demoMode, let question = hub.questions.first(where: { !onScreen($0) }) {
            questionBar(question, more: hub.questions.count - 1)
        } else if let notice = viewModel.panelNotice {
            noticeBar(notice)
        }
    }

    /// A short notice (a session Nook runs asks something, a note is ready), with its one action.
    private func noticeBar(_ notice: PanelNotice) -> some View {
        let actions: [NookNoticeAction] = notice.action.map { action in
            [NookNoticeAction(notice.button) {
                viewModel.dismissPanelNotice()
                action()
            }]
        } ?? []
        return PanelNoticeBar(title: notice.message, actions: actions, countdown: notice.seconds,
                              paused: viewModel.panelNoticeHeld, onOK: { viewModel.dismissPanelNotice() }, floating: true) {
            EmptyView()
        }
        .id(notice.id)
        .transition(.nookFloating(reduceMotion: reduceMotion))
        .onHover { viewModel.holdPanelNotice($0) }
    }

    /// The agent's question, with View to answer it in the session itself (one question at a time, as on the card).
    private func questionBar(_ request: AgentQuestionRequest, more: Int) -> some View {
        PanelNoticeBar(title: request.items.first?.question ?? "", detail: subtitle(request, more: more),
                       symbol: "questionmark.bubble.fill", tone: NookTheme.amber, floating: true) {
            NookNoticeActions(
                primary: NookNoticeAction(tr("button.view")) {
                    viewModel.selectedAgentID = request.sessionKey
                    viewModel.show(.panel(.agents))
                },
                secondary: NookNoticeAction(tr("approval.inTerminal")) { answerInTerminal(request) }
            )
            .fixedSize()
        }
        .transition(.nookFloating(reduceMotion: reduceMotion))
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
        VStack(alignment: .leading, spacing: headerInset > 0 ? PanelOrb.belowHeader : NookTheme.Spacing.lg) {
            // Back, a thin line, then what this task is about: the title, and in quieter text whose it is.
            HStack(spacing: NookTheme.Spacing.md) {
                SheetBackButton(action: close)
                NookDivider(vertical: true).frame(height: 14)
                Text(sheet.title)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle {
                    Text(subtitle)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
                Spacer(minLength: NookTheme.Spacing.md)
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
        case .folderChanges(let path), .folderCommit(let path), .folderPullRequest(let path):
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
        case .folderCommit(let path):
            CommitSheet(folder: path, onClose: close).id(path)
        case .folderPullRequest(let path):
            PullRequestSheet(folder: path, onClose: close).id(path)
        }
    }
}

/// "‹ Back" at the start of a task's title row: quiet until the pointer is on it. Escape does the same.
private struct SheetBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: "chevron.left").font(NookTheme.font(11, .semibold))
                Text(tr("notch.back")).font(NookTheme.TextStyle.label)
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .padding(.leading, -NookTheme.Spacing.md)
    }
}
