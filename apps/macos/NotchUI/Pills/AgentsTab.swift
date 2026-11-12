import SwiftUI
import AppKit

/// Your agents in the notch. On the left every session, from whichever agent, started here or in a terminal; on the
/// right the session you picked, or, after the new-session button, the place to start one. A row shows the folder and
/// how long the session has been going, its name, and its branch with the agent's logo; the badge on the logo says
/// whether it runs under a personal or a work account. Finished sessions wait folded away at the bottom.
/// The list is a side panel like the ones on the right (`SidePanel.swift`): drag its line to resize it, and beside a
/// session put it away with the button at the end of its title row or the left toggle in the session's header.
struct AgentsTab: View {
    @Environment(\.panelSidebar) private var sidebar
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared
    @State private var palette = false
    /// How wide the session list is: drag the line beside it, double-click it to reset. Remembered.
    @AppStorage("nook.agents.listWidth") private var listWidth = PanelLayout.agentsList
    /// The list is put away beside a session, for more room for the conversation. Remembered.
    @AppStorage(AgentsListVisibility.hiddenKey) private var listHidden = false
    @State private var totalWidth: Double = 0
    /// The folder picked for a new session: its terminal, browser and changes open beside the composer.
    @State private var newDirectory = ""
    /// What was open before the footer's pages (pull requests, Actions); empty picks what waits for you, as on a fresh start.
    @State private var beforeFooterPage = ""

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case pullRequests
        case actions
        case terminals
        case browser
        case worktrees
        case simulator
        case new
    }

    var body: some View {
        // Both come from merging every session list: worked out together, once per redraw.
        let lists: (transcripts: [String: PastSession], past: [PastSession]) = app.demoMode
            ? (transcripts: [:], past: []) : app.detectedTranscriptsAndPast()
        let transcripts = lists.transcripts
        // A process Nook only sees is shown when its conversation can be read; agents are linked in Settings › Agents.
        let live = app.agentSessions.filter { app.demoMode || !$0.isDetected || transcripts[$0.id] != nil }
        // Earlier sessions only of accounts that are still connected, so the list stays about what you actually use.
        // Each account is checked once, and the list stops at the sixty it shows instead of going through every earlier session.
        let connected = Set(app.profiles.all.filter(app.isConnected).map(\.id))
        let past = app.demoMode ? [] : Array(lists.past.lazy
            .filter { app.profile(for: $0).map { connected.contains($0.id) } ?? false }.prefix(60))
        let selection = resolve(live: live, past: past)
        // The running session that is open: remembered, so it stays open once its agent ends it.
        let openLive = live.first { $0.id == viewModel.selectedAgentID }
        // A session with its side panel open needs room for both: the list gives way first, so a narrow window keeps
        // the conversation and the panel side by side for as long as it can.
        let besideRoom = workbench(selection) && viewModel.sessionTool != .conversation
            ? PanelLayout.minimumPanel + PanelSplit.handle + NookTheme.Spacing.sm + 10 : 0
        // Only a session whose header has the toggle to bring the list back can do without it (`canHideList`). Too
        // narrow for both (split view, a small window): the list or what is open, one at a time over the whole width.
        let stacked = PanelLayout.stacks(totalWidth)
        let listShown = stacked ? !listHidden : !listHidden || !canHideList(selection)
        let entries = listEntries(live: live, past: past, transcripts: transcripts)
        // In the main window the list goes away altogether; `PanelSidebarToggle` brings it back.
        let collapsed = sidebar != nil && !listShown
        HStack(alignment: .top, spacing: 0) {
            if listShown {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    // In the main window the list is the sidebar: the tabs and Search on top of it.
                    PanelSidebarTop(history: AnyView(SessionHistoryButtons(
                        current: selectedID(selection),
                        back: { goBack(entries) }, forward: { goForward(entries) })), hasToggle: true)
                    // In the sidebar the search field and these buttons share one row.
                    if sidebar == nil { listHeader(selection) }
                    sessionList(entries, selection: selection)
                    if !app.demoMode {
                        PanelFooter(selected: selectedID(selection), open: { open($0) },
                                    openSettings: { app.openSettings() }, history: app.history,
                                    onBack: { viewModel.selectedAgentID = beforeFooterPage })
                    }
                }
                .panelSidebarColumn()
                .listPanel(stacked: stacked, width: $listWidth, defaultWidth: PanelLayout.agentsList, available: totalWidth,
                           rest: PanelLayout.minimumConversation + PanelSplit.handle + besideRoom)
            }

            if !stacked || !listShown {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    // A session's header has the toggle back to the list; a page without one gets a back button above it.
                    if stacked && !canHideList(selection) {
                        PanelBackButton { listHidden = false }
                    }
                    Group {
                        switch selection {
                        case .live(let session):
                            SessionWorkbench(viewModel: viewModel, directory: session.cwd, dockSessionPanel: true,
                                             agentWorking: session.status == .running || session.status == .waiting,
                                             usageProfileID: app.profile(for: session)?.id) { tools in
                                AgentSessionDetail(selection: .live(session), headerAccessory: tools)
                            }
                            .id(session.id)
                        case .past(let session):
                            SessionWorkbench(viewModel: viewModel, directory: session.cwd, dockSessionPanel: true,
                                             usageProfileID: app.profile(for: session)?.id) { tools in
                                // An earlier conversation Nook can run opens as a Nook session: the same panel, composer and
                                // pull request status as one started here. The read-only view is for the rest.
                                ImportedSession(session: session) {
                                    AgentSessionDetail(selection: .past(session), headerAccessory: tools)
                                }
                            }
                            .id("past:" + session.id)
                        case .run(let id):
                            let run = app.workspace.run(id)
                            SessionWorkbench(viewModel: viewModel, directory: run?.workingDirectory ?? "", runID: id,
                                         dockSessionPanel: run?.remote == nil, agentWorking: run?.status.isActive ?? false) { tools in
                                AgentRunPanel(workspace: app.workspace, timelines: app.workspace.timelineChanges(for: id), runID: id, headerAccessory: tools)
                            }
                            // Each session gets its own panel state: nothing (a pending "restore files" above all) carries over.
                            .id("run:" + id.uuidString)
                        case .pullRequests: PullRequestsPanel()
                        case .actions: ActionsPanel()
                        case .terminals: AgentsToolPage(title: tr("agents.footer.terminals")) { TerminalsView() }
                        case .browser: AgentsToolPage(title: tr("agents.footer.browser")) { BrowserView(store: .shared) }
                        case .worktrees: AgentsToolPage(title: tr("agents.footer.worktrees")) { WorktreesView() }
                        case .simulator: AgentsToolPage(title: tr("agents.footer.simulator")) { SimulatorView() }
                        case .new:
                            if app.demoMode {
                                nothingRunning
                            } else {
                                SessionWorkbench(viewModel: viewModel, directory: newDirectory) { tools in
                                    NewSessionComposer(headerAccessory: tools, onDirectory: { newDirectory = $0 }) { id in
                                        // A browser or terminal opened beside the new session stays open.
                                        viewModel.continueSession(as: "run:" + id.uuidString, from: "new")
                                    }
                                }
                            }
                        }
                    }
                }
                .environment(\.sessionHeaderInset, collapsed ? PanelSidebarMetrics.collapsedHeaderInset : 0)
                // A page without a session's header starts under the title bar's row, clear of the traffic lights.
                .padding(.top, collapsed && !workbench(selection) ? PanelSidebarMetrics.titleBand - PanelSidebarMetrics.contentTop : 0)
                .padding(.leading, listShown ? 10 : collapsed ? PanelSidebarMetrics.collapsedContentLeading : 0)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background {
            // The sidebar is away by choice: no rail, and no header with a capsule in its place.
            if collapsed { Color.clear.preference(key: PanelSidebarShown.self, value: true) }
        }
        .overlay(alignment: .topLeading) {
            if sidebar != nil {
                PanelSidebarToggle(open: listShown) {
                    withAnimation(NookTheme.reveal) { listHidden.toggle() }
                }
            }
        }
        // Switching sessions is a hard cut: the next one shows with its panels in place, nothing slides in. Inside the
        // list's own animation, so that one only plays when you put the list away or bring it back.
        .transaction(value: selectedID(selection)) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .animation(NookTheme.reveal, value: listShown)
        // Looking at a session counts as having seen what it finished, also with the list put away.
        // Leaving a session counts too: what finished while you watched it is not "new".
        // The agent works in a chat you had marked as finished: it is not finished after all, unless you marked it
        // during this very busy spell. Also while the list is put away.
        .onChange(of: entries.busyKeys) { _, keys in finishedMarks.reconcile(busy: keys) }
        .onAppear {
            finishedMarks.reconcile(busy: entries.busyKeys)
            if let openLive { viewModel.lastOpenLiveSession = openLive }
            if Self.isSession(selectedID(selection)) { SessionHistory.shared.opened(selectedID(selection)) }
        }
        .onChange(of: openLive) { _, session in
            if let session { viewModel.lastOpenLiveSession = session }
        }
        .onChange(of: selectedID(selection)) { _, new in
            if Self.isSession(new) { SessionHistory.shared.opened(new) }
            // The session you left is marked seen by `NotchViewModel.selectedAgentID`. The one you open, and the reads
            // of its neighbours, wait until its first frame is drawn: each visit redraws the whole tab.
            Task { @MainActor in
                await Task.yield()
                visits.visit(new)
                prefetchNeighbours(of: new, in: entries)
            }
        }
        // Exactly the width it is given, however wide a row inside wants to be: measuring a row that runs past the window
        // would hand the panels more room than there is and push everything off both sides.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .onLayoutWidthChange { totalWidth = $0 }
        // Where back on a footer page returns to: what was open before the first of them, so hopping between them keeps it.
        .onChange(of: viewModel.selectedAgentID) { previous, id in
            if AgentsPage.footerPages.contains(id), !AgentsPage.footerPages.contains(previous) { beforeFooterPage = previous }
        }
        .overlay(alignment: .top) {
            if palette {
                AgentCommandPalette(viewModel: viewModel, sessions: entries.running + entries.earlier,
                                    current: currentItem(entries, selection)) { palette = false }
                    .padding(.top, 40)
                    .transition(.opacity)
            }
        }
        .keyCommands(["commandPalette.toggle": { palette.toggle(); return true }], context: ["paletteOpen": palette])
        // ⌘⇧[ and ⌘⇧] go to the session above or below in the list, as they go through chats on Chats.
        .keyCommands(["session.previous": { step(-1, in: entries, current: selectedID(selection)) },
                      "session.next": { step(1, in: entries, current: selectedID(selection)) }],
                     enabled: !entries.running.isEmpty || !entries.earlier.isEmpty)
        // ⌘[ / ⌘] back and forward, ⌘B the list, and what the keys do to the open session (pin, settle, rename…).
        .keyCommands(sessionKeys(entries, selection: selection, stacked: stacked))
        // Keep sessions and usage up to date while the tab remains open. Without the loading state: a refresh in the
        // background that flips it redraws the whole window twice for a list that is already there.
        .task {
            // The first refresh waits until the switch to this tab has settled: what it publishes redraws the whole app,
            // and in the middle of the switch that made it stutter.
            try? await Task.sleep(for: NookTheme.tabSettle)
            guard !Task.isCancelled else { return }
            // Also the visit to the open session: Nook and his ring redraw for it.
            visits.visit(selectedID(selection))
            app.hub.refreshDetected()
            app.adoptAccounts()
            app.history.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                app.adoptAccounts()
                app.history.refresh(showsProgress: false)
            }
        }
    }

    // MARK: List header

    /// "Agents" with the button that starts a new session. The left toggle brings the list back and puts it away:
    /// beside the traffic lights in the main window, in the session's header in the notch.
    private func listHeader(_ selection: Selection) -> some View {
        let isNew: Bool = { if case .new = selection { return true }; return false }()
        return PanelListHeader(tr("tab.agents"), sidebarTitle: tr("sidebar.sessions")) { listActions(selection, isNew: isNew) }
            .padding(.bottom, NookTheme.Spacing.xs)
    }

    /// New session: beside the title in the notch, beside the search in the sidebar.
    @ViewBuilder
    private func listActions(_ selection: Selection, isNew: Bool) -> some View {
        if !app.demoMode {
            PanelNewButton(label: tr("agents.newSession"), active: isNew) { open("new") }
        }
    }

    // MARK: Selection

    /// Opens a session or a page; while the tab shows one column at a time, that takes the list's place.
    private func open(_ id: String) {
        viewModel.selectedAgentID = id
        if PanelLayout.stacks(totalWidth) { withAnimation(NookTheme.reveal) { listHidden = true } }
    }

    /// Opens the session `offset` rows from the open one in the list (the first or last one when none of them is open).
    /// False at either end, so the key goes on.
    private func step(_ offset: Int, in entries: ListEntries, current: String) -> Bool {
        let ids = (entries.running + entries.earlier).map(\.id)
        guard !ids.isEmpty else { return false }
        let next = ids.firstIndex(of: entries.rowID(current)).map { $0 + offset } ?? (offset > 0 ? 0 : ids.count - 1)
        guard ids.indices.contains(next) else { return false }
        open(ids[next])
        return true
    }

    // MARK: Keys for the open session

    /// A session of the list, not a page of the footer or the new-session composer: what back and forward step through.
    static func isSession(_ id: String) -> Bool {
        !id.isEmpty && id != "new" && !AgentsPage.footerPages.contains(id) && !AgentsPage.tools.contains(id)
    }

    /// The row of the session that is open, if it is in the list.
    private func currentItem(_ entries: ListEntries, _ selection: Selection) -> AgentListItem? {
        let id = selectedID(selection)
        return entries.running.first { $0.id == id } ?? entries.earlier.first { $0.id == id }
    }

    /// The keys that act on the list and the open session. Each lets the key go (false) when it has nothing to act on.
    /// Whether a session on the back and forward trail is still in the list.
    private func exists(_ id: String, in entries: ListEntries) -> Bool {
        entries.standIn[id] != nil || entries.running.contains { $0.id == id } || entries.earlier.contains { $0.id == id }
    }

    @discardableResult
    private func goBack(_ entries: ListEntries) -> Bool {
        guard let id = SessionHistory.shared.back(exists: { exists($0, in: entries) }) else { return false }
        open(id)
        return true
    }

    @discardableResult
    private func goForward(_ entries: ListEntries) -> Bool {
        guard let id = SessionHistory.shared.forward(exists: { exists($0, in: entries) }) else { return false }
        open(id)
        return true
    }

    private func sessionKeys(_ entries: ListEntries, selection: Selection, stacked: Bool) -> [String: () -> Bool] {
        let item = currentItem(entries, selection)
        let actions = item.map { OpenSessionActions(item: $0, app: app) }
        return [
            "sidebar.toggle": {
                guard stacked || canHideList(selection) else { return false }
                withAnimation(NookTheme.reveal) { listHidden.toggle() }
                return true
            },
            "session.back": { goBack(entries) },
            "session.forward": { goForward(entries) },
            "session.pin": { actions?.togglePin() ?? false },
            "session.settle": { actions?.toggleSettled() ?? false },
            "session.interrupt": { actions?.interrupt() ?? false },
            "session.openInEditor": { actions?.openInEditor() ?? false },
            "session.copyReference": { actions?.copyReference() ?? false },
            "session.rename": { actions?.rename() ?? false },
        ]
    }

    /// What is shown on the right. Without a choice (or when it is gone): whatever waits for you or works, otherwise the
    /// place to start a new session.
    /// The selections that open in a `SessionWorkbench`, with a side panel beside the conversation.
    private func workbench(_ selection: Selection) -> Bool {
        switch selection {
        case .live, .past, .run, .new: return true
        default: return false
        }
    }

    /// The list can be put away where something brings it back: anywhere in the main window (`PanelSidebarToggle`). In
    /// the notch only where the session's header shows the toggle: a session in a workbench on this Mac, not one on
    /// another machine (its header has no panel toggles) and not the sample data.
    private func canHideList(_ selection: Selection) -> Bool {
        guard !app.demoMode else { return false }
        if sidebar != nil { return true }
        guard workbench(selection) else { return false }
        if case .run(let id) = selection, app.workspace.run(id)?.remote != nil { return false }
        return true
    }

    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id == "new" { return .new }
        if id == AgentsPage.pullRequests && !app.demoMode { return .pullRequests }
        if id == AgentsPage.actions && !app.demoMode { return .actions }
        if id == AgentsPage.terminals && !app.demoMode { return .terminals }
        if id == AgentsPage.browser && !app.demoMode { return .browser }
        if id == AgentsPage.worktrees && !app.demoMode { return .worktrees }
        if id == AgentsPage.simulator && !app.demoMode { return .simulator }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) {
                // Nook already took this conversation over: its session opens in this very frame, with no takeover
                // (spinner, transcript read, second rebuild) in between. The key follows after this redraw, never inside
                // it; its own panels come back, as they do for any session you return to.
                if let taken = app.adoptedRun(for: session) {
                    let target = "run:" + taken.uuidString
                    DispatchQueue.main.async { [viewModel, app] in
                        guard viewModel.selectedAgentID == id else { return }
                        if app.workspace.run(taken)?.archived == true { app.workspace.setArchived(taken, false) }
                        app.workspace.selectedRunID = taken
                        viewModel.selectedAgentID = target
                    }
                    return .run(taken)
                }
                return .past(session)
            }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        // The session you have open ended (its agent closed it, its process quit): it stays open, as its transcript once that
        // is read, otherwise as it last read. Only a session you did not have open gives way to what waits or works.
        if let ended = viewModel.lastOpenLiveSession, ended.id == id {
            return transcript(of: ended).map { .past($0) } ?? .live(ended)
        }
        // A session that waits for you comes before a run that is only busy.
        if let first = live.first(where: { $0.status == .waiting || $0.approvalID != nil }) { return .live(first) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = live.first(where: { $0.status == .running }) { return .live(first) }
        if app.demoMode, let first = live.first { return .live(first) }
        return .new
    }

    /// The earlier session that holds this running session's conversation, once the history has read it.
    private func transcript(of session: AgentSession) -> PastSession? {
        guard let kind = AgentKind(agentName: session.name), let conversation = app.conversationID(for: session) else { return nil }
        return app.history.sessions.first { $0.agent == kind && ($0.sessionID == conversation || $0.earlierIDs.contains(conversation)) }
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .pullRequests: return AgentsPage.pullRequests
        case .actions: return AgentsPage.actions
        case .terminals: return AgentsPage.terminals
        case .browser: return AgentsPage.browser
        case .worktrees: return AgentsPage.worktrees
        case .simulator: return AgentsPage.simulator
        case .new: return "new"
        }
    }

    /// Reads the timelines of the sessions above and below the one that opened, off the main thread, so stepping
    /// through the list with the keyboard opens each without a hitch (the pointer resting on a row does the same).
    private func prefetchNeighbours(of id: String, in entries: ListEntries) {
        let ids = (entries.running + entries.earlier).map(\.id)
        guard !app.demoMode, let index = ids.firstIndex(of: id) else { return }
        for neighbour in [index - 1, index + 1] where ids.indices.contains(neighbour) {
            let next = ids[neighbour]
            if next.hasPrefix("run:"), let run = UUID(uuidString: String(next.dropFirst(4))) {
                app.workspace.prefetchTimeline(run)
            } else if next.hasPrefix("past:") {
                let key = String(next.dropFirst(5))
                guard let session = app.history.sessions.first(where: { $0.id == key }) else { continue }
                // One Nook took over opens as its session (see `resolve`): that timeline is what it shows.
                if let taken = app.adoptedRun(for: session) {
                    app.workspace.prefetchTimeline(taken)
                } else {
                    TranscriptPrefetch.warm(path: session.path)
                }
            } else if let session = app.agentSessions.first(where: { $0.id == next }) {
                TranscriptPrefetch.warm(path: session.transcriptPath.isEmpty ? (transcript(of: session)?.path ?? "") : session.transcriptPath)
            }
        }
    }

    // MARK: List

    /// The list's rows: what works or waits, the earlier sessions, and the conversations that are busy (which cannot
    /// stay marked as finished). Worked out in `body`, so the marks stay right while the list is put away.
    private struct ListEntries {
        let running: [AgentListItem]
        let earlier: [AgentListItem]
        let busyKeys: Set<String>
        /// The sub-threads that live inside their parent's view instead of as rows (`SubThreadListing`), each with the
        /// row that stands in for it while it is open.
        var standIn: [String: String] = [:]

        /// The row for `id`: its own, or for a sub-thread its nearest listed ancestor's.
        func rowID(_ id: String) -> String { standIn[id] ?? id }
    }

    private func listEntries(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession]) -> ListEntries {
        let runs = app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace)
        // How many models each first session of a comparison has: counted once, not once per run.
        var comparisons: [UUID: Int] = [:]
        for run in app.workspace.runs where run.lineage?.kind == .comparison {
            if let parent = run.lineage?.parentID { comparisons[parent, default: 0] += 1 }
        }
        let all = runs.map { item($0, comparisons: comparisons) } + live.map { item($0, transcript: transcripts[$0.id]) }
        let busyKeys = Set(all.filter(\.isBusy).map(\.finishKey))
        let (built, standIn) = Self.subThreadsUnderParents(all, runs: app.workspace.runs)
        let earlier = past.map { item($0) }.filter { !busyKeys.contains($0.finishKey) }
        return ListEntries(running: sorted(built), earlier: earlier, busyKeys: busyKeys, standIn: standIn)
    }

    /// The list stays flat. A delegated task or side chat has no row while its parent has one (the parent's
    /// Lineage control lists it); the parent's row stands in for it while it is open, and shows the approval it waits for,
    /// and for a side chat its question too. A fork or a comparison keeps a row of its own, at the same level.
    private static func subThreadsUnderParents(_ items: [AgentListItem], runs: [WorkspaceRun])
        -> (items: [AgentListItem], standIn: [String: String]) {
        var links: [String: SubThreadLink] = [:]
        for run in runs {
            guard let parent = run.parentRunID, let relation = run.subThreadRelation else { continue }
            links["run:" + run.id.uuidString] = SubThreadLink(parent: "run:" + parent.uuidString, relation: relation)
        }
        let hidden = SubThreadListing.hidden(links, listed: Set(items.map(\.id)))
        var open: [String: SubThreadRequest] = [:]
        for item in items where links[item.id] != nil {
            if item.status == .waiting { open[item.id] = .approval } else if item.status == .input { open[item.id] = .question }
        }
        let flagged = SubThreadListing.requests(links, open: open)
        let shown = items.filter { !hidden.contains($0.id) }.map { item -> AgentListItem in
            var item = item
            // Flat: no row sits under another one.
            item.parentID = nil
            switch flagged[item.id] {
            case .approval?: item.status = .waiting
            case .question? where item.status != .waiting: item.status = .input
            default: break
            }
            return item
        }
        var standIn: [String: String] = [:]
        for id in hidden { standIn[id] = SubThreadListing.rowID(for: id, links: links, hidden: hidden) }
        return (shown, standIn)
    }

    private func sessionList(_ entries: ListEntries, selection: Selection) -> some View {
        // An open sub-thread has no row: its parent's row is the one that shows as open.
        let current = entries.rowID(selectedID(selection))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TimelineView(.nookTicks(every: 30)) { context in
                AgentInboxList(items: entries.running, past: entries.earlier, current: current, now: context.date,
                               headerActions: sidebar == nil ? nil : AnyView(listActions(selection, isNew: current == "new"))) { open($0) }
            }
        }
    }

    /// Waiting for you first, then working, then the rest; newest first within each.
    private func sorted(_ items: [AgentListItem]) -> [AgentListItem] {
        func rank(_ status: AgentListItem.Status) -> Int {
            switch status {
            case .waiting: return 0
            case .input: return 1
            case .failed: return 2
            case .limited: return 3
            case .working: return 4
            case .idle: return 5
            case .finished: return 6
            }
        }
        return items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.status), rank(b.element.status))
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func account(_ profile: AgentProfile?) -> AccountTag? {
        AccountTag.badge(profile, app: app)
    }

    private func accountName(_ profile: AgentProfile?) -> String {
        guard !app.demoMode, let profile else { return "" }
        return AccountLabel.name(profile, app: app)
    }

    private func item(_ run: WorkspaceRun, comparisons: [UUID: Int]) -> AgentListItem {
        // One answer to "what does this need from you" (approval, question, limit, snooze), shared with the notch.
        let attention = app.workspace.attention(run, unseen: unseen("run:" + run.id.uuidString, run.updatedAt),
                                                includeSnooze: false)
        let status: AgentListItem.Status
        switch attention {
        case .approval: status = .waiting
        case .input: status = .input
        case .failed: status = .failed
        case .limited: status = .limited
        case .working: status = .working
        case .ready, .idle: status = .idle
        case .finished: status = .finished
        }
        return AgentListItem(
            id: "run:" + run.id.uuidString,
            folder: run.projectName,
            title: run.title,
            branch: run.branch ?? (run.isRemote ? nil : GitHead.branch(for: run.workingDirectory)),
            agent: run.provider.displayName,
            account: account(app.profile(for: run)),
            status: status,
            // Working also covers subagents that outlive their turn: the badge counts on from the turn that started them.
            started: attention == .working ? (run.turnStartedAt ?? run.createdAt) : run.updatedAt,
            path: run.workingDirectory,
            finishKey: FinishedSessions.key(run: run),
            unseen: attention == .ready,
            snoozedUntil: run.snoozedUntil,
            snoozedAt: run.snoozedAt,
            limitedAt: run.limitedAt,
            limitResetAt: run.limitResetAt,
            machine: run.remote?.name ?? MachineName.local,
            model: run.resolvedModel ?? run.model,
            accountName: accountName(app.profile(for: run)),
            // A session Nook delegated to or forked from another one, or a later model of a comparison.
            parentID: (run.delegation?.parentID ?? run.lineage?.parentID).map { "run:" + $0.uuidString },
            firstPrompt: run.task,
            comparison: comparisons[run.id] ?? 0,
            forked: run.lineage?.kind == .fork,
            worktree: run.isolation == .worktree || run.worktreePath != nil,
            linesAdded: run.changedLinesAdded ?? 0,
            linesRemoved: run.changedLinesRemoved ?? 0,
            changedFiles: run.changedFiles,
            // Its own turn ended while sub-threads it delegated still work: busy through them.
            subThreadsWorking: run.status == .completed && attention == .working ? app.workspace.workingSubThreads(of: run.id) : 0
        )
    }

    private func item(_ session: AgentSession, transcript: PastSession?) -> AgentListItem {
        let status: AgentListItem.Status
        if session.approvalID != nil || session.status == .waiting {
            status = .waiting
        } else {
            switch session.status {
            case .running: status = .working
            case .failed: status = .failed
            // Compacting between turns (your /compact): it works, though no turn runs.
            default: status = session.compactingSince != nil ? .working : .idle
            }
        }
        let conversation = app.conversationID(for: session)
        let known = transcript ?? conversation.flatMap { id in app.history.sessions.first { $0.isConversation(id) } }
        let named = AgentFormat.sessionTitle(session, known: known)
        let title = named.isEmpty ? session.project : named
        let branch = known.flatMap { $0.branch.isEmpty ? nil : $0.branch } ?? GitHead.branch(for: session.cwd)
        return AgentListItem(
            id: session.id,
            folder: session.project,
            title: title,
            branch: branch,
            agent: session.name,
            account: account(app.profile(for: session)),
            status: status,
            // Busy: how long this turn runs, not how long ago the session started.
            started: status == .idle ? (session.updated ?? session.started ?? known?.started)
                : (session.turnStarted ?? session.compactingSince ?? session.started ?? known?.started),
            path: session.cwd,
            finishKey: FinishedSessions.key(session: session),
            unseen: session.status == .done && unseen(session.id, session.updated),
            machine: MachineName.local,
            model: known?.model ?? "",
            accountName: accountName(app.profile(for: session)),
            firstPrompt: known?.firstPrompt ?? "",
            spawnedTasks: known?.spawnedTasks ?? [],
            worktree: GitHead.isWorktree(session.cwd),
            linesAdded: session.linesAdded,
            linesRemoved: session.linesRemoved
        )
    }

    private func item(_ session: PastSession) -> AgentListItem {
        AgentListItem(
            id: "past:" + session.id,
            folder: session.project,
            title: AgentFormat.title(session.title),
            branch: session.branch.isEmpty ? nil : session.branch,
            agent: session.agent.name,
            account: account(app.profile(for: session)),
            status: .finished,
            started: session.ended,
            path: session.cwd,
            finishKey: FinishedSessions.key(agent: session.agent.name, conversation: session.sessionID, fallback: "past:" + session.id),
            machine: MachineName.local,
            model: session.model,
            accountName: accountName(app.profile(for: session)),
            firstPrompt: session.firstPrompt,
            spawnedTasks: session.spawnedTasks,
            // No file is read for the history's many rows: the worktrees agents make sit in a "worktrees" folder.
            worktree: session.cwd.contains("/worktrees/")
        )
    }

    /// Finished after you last looked, and not the session you are looking at now.
    private func unseen(_ id: String, _ finished: Date?) -> Bool {
        guard !app.demoMode, let finished, id != viewModel.selectedAgentID else { return false }
        return visits.isUnseen(id, finished: finished)
    }

    /// Sample data only: nothing to start.
    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(tr("agents.noneWorkingNow"))
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.nothingRunningDetail"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Whether the session list on the left of the Agents tab is put away; shared by the tab and the toggle in a
/// session's header (`SessionToolSwitch`).
enum AgentsListVisibility {
    static let hiddenKey = "nook.agents.listHidden"
}

// MARK: Session row

/// One session in the list, the same for every kind of session.
struct AgentListItem: Identifiable, Equatable {
    enum Status { case working, waiting, input, failed, limited, idle, finished }

    /// The selection id: a hub session id, "run:<uuid>" or "past:<id>".
    let id: String
    let folder: String
    let title: String
    let branch: String?
    /// The agent's display name, for its logo.
    let agent: String
    let account: AccountTag?
    var status: Status
    /// Working or waiting: when it started. Otherwise: when it was last active.
    let started: Date?
    let path: String
    /// Identifies the conversation for "mark as finished", the same for a running and an earlier session of it.
    let finishKey: String
    /// Finished after you last looked at it: "done" in green until you open it.
    var unseen = false
    /// Snoozed by you: out of the way until the snooze ends or the session needs you.
    var snoozedUntil: Date? = nil
    var snoozedAt: Date? = nil
    /// Stopped by a usage limit since then, and when that limit resets (a session Nook runs).
    var limitedAt: Date? = nil
    var limitResetAt: Date? = nil
    /// For the hover card: the machine it runs on, the model, and the account's name.
    var machine = ""
    var model = ""
    var accountName = ""
    /// The session this one was started from: its list id ("run:<uuid>", a hub session id or "past:<id>").
    var parentID: String? = nil
    /// The first prompt and the tasks the session started for others, to find a spawned session's parent
    /// (`SpawnedSessions`).
    var firstPrompt = ""
    var spawnedTasks: [String] = []
    /// The first session of a model comparison: how many other models got the same prompt (they sit under it).
    var comparison = 0
    /// Forked from another session (/fork): a branch mark before its name.
    var forked = false
    /// Works in a linked git worktree rather than the repository's own folder: its branch shows a worktree mark.
    var worktree = false
    /// The lines it added and removed (counted by the hooks, or read from git for sessions Nook runs), and for sessions
    /// Nook runs the files it changed: the row shows the lines, the file count only when git counted no lines (binary).
    var linesAdded = 0
    var linesRemoved = 0
    var changedFiles: Int? = nil
    /// Its own turn ended, but this many sub-threads it delegated still work (`DelegatedTask.workingSubThreads`).
    var subThreadsWorking = 0

    /// Busy or waiting for you: it cannot be marked as finished yet.
    var isBusy: Bool { status == .working || status == .waiting || status == .input }

    func markedFinished() -> AgentListItem {
        var finished = self
        finished.status = .finished
        finished.unseen = false
        finished.snoozedUntil = nil
        finished.snoozedAt = nil
        return finished
    }
}

/// The project a session row names: the name you gave it (else its folder's) and its badge (your icon, else its initials
/// on a tint picked from the name, `ProjectIcon.defaultIcon`).
struct RowProject: Equatable {
    var name: String
    var icon: ProjectIcon
    /// The project's folder on this Mac, for the row's Project menu; nil for a project of sessions elsewhere.
    var path: String?
}

/// A project's badge in a session row (the row names the project beside it).
struct ProjectBadge: View {
    let project: RowProject
    var size: CGFloat = 14

    var body: some View {
        ProjectIconView(icon: project.icon, size: size)
            .foregroundStyle(NookTheme.textSecondary)
    }
}

/// What a row can do on hover: the right slot swaps, without shifting the layout, between the
/// status and these buttons.
struct AgentRowActions {
    var pinned: Bool
    var onPin: () -> Void
    var settled: Bool
    var onSettle: () -> Void
    var onWake: (() -> Void)? = nil
    /// While a usage limit holds the session: when it resets, for "until the limit resets".
    var limitResetsAt: Date? = nil
    /// Snoozes until a moment (a snooze option's end, the limit's reset); snoozing and waking are for sessions Nook runs.
    var onSnoozeUntil: ((Date) -> Void)? = nil
    var onSnoozeCustom: (() -> Void)? = nil
    /// Settle (or Un-settle) and Wake pressed and dragged up or down: the same for every row swept (`SessionSweep`).
    var onSettleSweep: (([String]) -> Void)? = nil
    var onWakeSweep: (([String]) -> Void)? = nil
}

/// The sweep of the Agents list (`RowSweep`): Settle, Un-settle or Wake on one row, dragged over the rows of its section.
@MainActor
enum SessionSweep {
    static let rows = RowSweep<String>()
}

/// A session row: its folder with the status or how long ago, its name, and a line of what it did
/// (branch, changes, pull request) with the agent's logo. A row that asks nothing of you recedes (lighter text, normal
/// weight, working rows dimmed) so what needs you is the only loud thing.
struct AgentListRow: View, Equatable {
    let item: AgentListItem
    let now: Date
    let selected: Bool
    var receded = false
    var pinned = false
    var woke = false
    /// One line, for the snoozed and settled shelves.
    var slim = false
    /// Under its project's header, which already names the folder: the agent's logo, the name and the status, and under
    /// it the branch, changes and pull request when there are any.
    var grouped = false
    /// When a snoozed row wakes, as text ("tot 9:00").
    var wakeLabel: String? = nil
    /// The project it belongs to, by the name and badge you gave it: on the first line in place of the folder, and before
    /// the name on a shelf row. Nil for a session without a project.
    var project: RowProject? = nil
    var actions: AgentRowActions? = nil
    /// The session's pull requests, of its branch now and of the ones it worked on before: "#12" (or "#12 +1") on the row,
    /// and each of them in the card it shows on hover.
    var pullRequests = SessionPullRequests(current: [])
    /// While ⌘ is held: the number that opens this row (⌘1–⌘9), shown in the right slot.
    var jumpHint: Int? = nil
    /// The keyboard is on this row in the list (↑/↓ after F6): lit as under the pointer.
    var keyFocused = false
    /// A sweep started on this row's button: its buttons stay while the pointer is elsewhere.
    var sweepOrigin = false
    /// Opens the session with a pull request beside it, from the card of the row's badge.
    var openPullRequest: (URL) -> Void = { _ in }
    /// Opens the session on a file's change (its path relative to the session's folder), from the card of the row's changes.
    var openChange: (String) -> Void = { _ in }
    let action: () -> Void

    /// What the row draws, so `.equatable()` skips redrawing a row whose inputs did not change. The closures are left
    /// out: they act on the same state whichever copy of them the row holds.
    static func == (lhs: AgentListRow, rhs: AgentListRow) -> Bool {
        lhs.item == rhs.item && lhs.now == rhs.now && lhs.selected == rhs.selected && lhs.receded == rhs.receded
            && lhs.jumpHint == rhs.jumpHint && lhs.keyFocused == rhs.keyFocused && lhs.sweepOrigin == rhs.sweepOrigin
            && lhs.pinned == rhs.pinned && lhs.woke == rhs.woke && lhs.slim == rhs.slim && lhs.grouped == rhs.grouped
            && lhs.wakeLabel == rhs.wakeLabel && lhs.pullRequests == rhs.pullRequests && lhs.project == rhs.project
            && lhs.actions?.pinned == rhs.actions?.pinned && lhs.actions?.settled == rhs.actions?.settled
            && (lhs.actions?.onSnoozeUntil != nil) == (rhs.actions?.onSnoozeUntil != nil)
            && (lhs.actions?.onWake != nil) == (rhs.actions?.onWake != nil)
            && (lhs.actions != nil) == (rhs.actions != nil)
    }

    @State private var hovering = false
    /// The hover buttons were built: on the row's first hover, and kept from then on (see `body`).
    @State private var actionsBuilt = false
    /// The pointer is on the hover buttons.
    @State private var onActions = false
    /// The pointer is on the changes or the pull request, which show their own card instead of the row's.
    @State private var onDetail = false
    /// Too narrow for the status's word beside the name (a narrow sidebar): the status is only its mark.
    @State private var narrow = false
    /// Below this width a one-line row keeps the name readable by showing the status as its mark only.
    static let narrowWidth: CGFloat = 200
    /// A row of one line, and the first line of a row under its project's header.
    static let lineHeight: CGFloat = 36
    /// Where the name starts under a project's header: past the folder's mark, so it lines up with the project's name.
    static let groupedIndent: CGFloat = 36

    /// No fill at rest: the rows read as one list, and only the one under the pointer or the selected one lifts.
    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering || keyFocused, rest: .clear) }
    /// A tighter row: a shelf row, or a row under its project's header.
    private var compact: Bool { slim || grouped }
    private var dimmed: Bool { item.status == .finished || slim }
    private var restOpacity: Double { receded && item.status == .working && !hovering && !selected ? 0.7 : 1 }
    /// The hover buttons show: under the pointer, or while a sweep that started on this row runs.
    private var actionsShown: Bool { hovering || sweepOrigin }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.nookPlain)
            // Built on the row's first hover, then kept and only faded: a menu and two or three buttons in every row of a
            // long list were AppKit views, hover regions and accessibility nodes for buttons nobody saw, so a row nobody
            // pointed at still has none; but building them again on every hover cost each hover a frame.
            if let actions, actionsBuilt || sweepOrigin {
                hoverActions(actions)
                    // Only the buttons themselves hold the card back: with the backdrop's fade and the padding counted, a
                    // one-line row in a narrow list was "on the buttons" nearly everywhere and never showed its card.
                    .onHover { onActions = $0 }
                    .rowActionsBackdrop(background)
                    // Level with the first line, where the status they replace sits.
                    .padding(.top, compact ? (Self.lineHeight - 22) / 2 : NookTheme.Spacing.md)
                    .padding(.trailing, NookTheme.Spacing.md)
                    // Only their fade is animated; the row's fill behind them follows the pointer at once.
                    .animation(NookTheme.hover) { $0.opacity(actionsShown ? 1 : 0) }
                    .allowsHitTesting(actionsShown)
                    .accessibilityHidden(!actionsShown)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside, !actionsBuilt { actionsBuilt = true }
        }
        // The buttons go with the pointer, and may not get to say it left them.
        .onChange(of: hovering) { _, now in if !now { onActions = false } }
        // Closed over the buttons, so their first click is not spent closing the card. Warm: moving down the list with a
        // card open opens the next row's at once (`HoverCardWarmth`).
        .hoverCard(suppressed: onActions || onDetail, warm: true) { AgentHoverCard(item: item) }
        .accessibilityElement(children: .combine)
        // The hover buttons are merged away above, so VoiceOver gets them as the row's actions.
        .accessibilityActions {
            if let actions {
                Button(actions.pinned ? tr("inbox.unpin") : tr("inbox.pin"), action: actions.onPin)
                Button(actions.settled ? tr("inbox.reopen") : tr("inbox.settle"), action: actions.onSettle)
                if let onWake = actions.onWake {
                    Button(tr("agents.snooze.cancel"), action: onWake)
                }
                if let onSnooze = actions.onSnoozeUntil {
                    SnoozeMenuItems(now: now, limitResetsAt: actions.limitResetsAt, onUntil: onSnooze,
                                    onCustom: actions.onSnoozeCustom)
                }
            }
        }
    }

    private var content: some View {
        Group {
            if slim { slimBody } else if grouped { groupedBody } else { fullBody }
        }
        .padding(.leading, grouped ? Self.groupedIndent : NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .padding(.trailing, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .padding(.vertical, compact ? NookTheme.Spacing.sm : NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: compact ? Self.lineHeight : nil, alignment: .leading)
        // The fill is never animated: it lifts in the frame the pointer arrives, as a list should.
        .background {
            NookTheme.shape(NookTheme.Radius.chip).fill(background)
                .transaction { $0.animation = nil }
        }
        // Only whether it is narrow is kept, so resizing the list redraws a row only when that flips.
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowWidth } action: { narrow = $0 }
        .contentShape(Rectangle())
        .animation(NookTheme.hover) { $0.opacity(restOpacity) }
    }

    /// The right slot, faded out under the hover buttons that take its place.
    private var fadingSlot: some View {
        slot.animation(NookTheme.hover) { $0.opacity(hovering && actions != nil ? 0 : 1) }
    }

    /// Three lines: the folder with the status or how long ago on the right; the session's
    /// name; and the branch, its changes, the pull request and the agent's logo. Without any of those the logo moves up
    /// beside the name and the row keeps two lines. The hover card has the rest.
    private var fullBody: some View {
        AgentRowLayout(folder: project?.name ?? item.folder, folderHelp: AgentPathFormat.tilde(item.path), hasMeta: hasMeta) {
            fadingSlot
        } title: {
            marks
            title
        } logo: {
            logo(size: 14)
        } meta: {
            metaLine
        } mark: {
            project.map { AnyView(ProjectBadge(project: $0, size: 14)) }
        }
    }

    private var title: some View {
        AgentRowTitle(title: item.title, receded: receded, dimmed: dimmed)
    }

    private func logo(size: CGFloat) -> some View {
        // Grey at rest, its brand color under the pointer or when selected. The 3 pt for the account badge is kept on
        // every row, so logos with and without a badge stand in one column.
        AgentMark(agent: item.agent, account: item.account, size: size, dimmed: dimmed, ring: background,
                  quiet: !hovering && !selected)
            .padding(.trailing, 3)
    }

    private var shownBranch: String? {
        guard let branch = item.branch, !branch.isEmpty, branch != item.folder else { return nil }
        return branch
    }

    private var hasChanges: Bool { item.linesAdded + item.linesRemoved > 0 || (item.changedFiles ?? 0) > 0 }

    /// Anything for the line under the name: a branch, changes, or a pull request.
    private var hasMeta: Bool { shownBranch != nil || hasChanges || !pullRequests.isEmpty }

    /// "feature/calm-ui  +120 −8  [#12]": the branch, cut in the middle when it is long, then what the session changed
    /// and the pull request last, so its mark keeps one column at the right edge whether or not a row has changes.
    private var metaLine: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let branch = shownBranch {
                AgentRowBranch(branch: branch, worktree: item.worktree)
            }
            Spacer(minLength: 0)
            changes
            pullRequestPill
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textTertiary)
    }

    /// The pull request badge; on hover a card with its title, state, branches, size and checks.
    @ViewBuilder
    private var pullRequestPill: some View {
        if let badge = pullRequests.badge {
            PullRequestPill(badge: badge, compact: true, tooltip: false)
                .detailCard(onDetail: $onDetail) { RowPullRequestCard(pullRequests: pullRequests, onOpen: openPullRequest) }
        }
    }

    /// The changes of a session on this Mac open the list of changed files on hover; a remote one has no folder here.
    private var showsChangesCard: Bool { !item.path.isEmpty && item.machine == MachineName.local }

    /// "+120 −8" for every session with changed lines; the number of changed files only when no lines were counted
    /// (binary files only). On hover a card lists the files with their lines.
    private var changes: some View {
        changeCount
            .detailCard(enabled: showsChangesCard, onDetail: $onDetail) {
                RowChangesCard(directory: item.path, countedAdded: item.linesAdded, countedRemoved: item.linesRemoved, onOpen: openChange)
            }
    }

    @ViewBuilder
    private var changeCount: some View {
        if item.linesAdded + item.linesRemoved > 0 {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text("+\(item.linesAdded)").foregroundStyle(dimmed ? NookTheme.textTertiary : NookTheme.diffAdded)
                Text("−\(item.linesRemoved)").foregroundStyle(dimmed ? NookTheme.textTertiary : NookTheme.diffRemoved)
            }
            .font(NookTheme.mono(10.5))
            .fixedSize()
        } else if let files = item.changedFiles, files > 0 {
            HStack(spacing: 3) {
                NookSymbol("doc", size: 10).font(NookTheme.font(9.5, .semibold))
                Text("\(files)").monospacedDigit()
            }
            .fixedSize()
            .nookTip(tr("agents.git.changes", files), enabled: !showsChangesCard)
            .accessibilityLabel(tr("agents.git.changes", files))
        }
    }

    /// Under the project's header, lined up with its name: the name with the marks before it and the status or how long
    /// ago on the right; under it the branch, pull request and changes, ending in the agent's logo. Without those the
    /// row is one line and the logo stands beside the status.
    private var groupedBody: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                marks
                title
                Spacer(minLength: NookTheme.Spacing.xs)
                if !hasMeta { logo(size: 13) }
                fadingSlot
            }
            .frame(minHeight: Self.lineHeight - NookTheme.Spacing.lg)
            if hasMeta {
                HStack(spacing: NookTheme.Spacing.sm) {
                    metaLine
                    logo(size: 13)
                }
                .frame(height: 16)
            }
        }
    }

    /// Pinned, forked, or the first of a model comparison: a quiet mark before the name.
    @ViewBuilder
    private var marks: some View {
        if pinned {
            Image(icon: "pin.fill").font(NookTheme.font(9)).foregroundStyle(NookTheme.textTertiary)
        }
        if item.forked {
            Image(icon: "arrow.triangle.branch")
                .font(NookTheme.font(10))
                .foregroundStyle(NookTheme.textTertiary)
                .nookTip(tr("lineage.forked"))
                .accessibilityLabel(tr("lineage.forked"))
        }
        if item.comparison > 0 {
            Image(icon: "square.stack.3d.up")
                .font(NookTheme.font(10))
                .foregroundStyle(NookTheme.textTertiary)
                .nookTip(tr("compare.group", item.comparison + 1))
                .accessibilityLabel(tr("compare.group", item.comparison + 1))
        }
    }

    private var slimBody: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            // The project's badge says where it belongs; the agent's logo is in the hover card.
            if let project {
                ProjectBadge(project: project, size: 16).opacity(0.8)
            } else {
                AgentMark(agent: item.agent, account: item.account, size: 16, dimmed: true, ring: background)
            }
            Text(item.title)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: NookTheme.Spacing.xs)
            pullRequestPill
            fadingSlot
        }
    }

    /// A one-line row in a narrow list shows its status as a mark only.
    private var compactStatus: Bool { compact && narrow }

    /// The right slot: the wake time of a snoozed row, "Wakker" for one that woke, otherwise the status or how long ago.
    @ViewBuilder
    private var slot: some View {
        if let jumpHint {
            NookKeyHint(text: "⌘\(jumpHint)")
        } else if let wakeLabel {
            AgentStatusBadge(state: .snoozed, detail: wakeLabel, markOnly: compactStatus)
        } else if woke {
            AgentStatusBadge(state: .woke, markOnly: compactStatus)
        } else {
            time
        }
    }

    @ViewBuilder
    private func hoverActions(_ actions: AgentRowActions) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            // A narrow one-line row keeps one button, so its hover card shows over nearly the whole row: snooze and pin
            // are in its right-click menu.
            if let onSnooze = actions.onSnoozeUntil, !compactStatus {
                Menu {
                    SnoozeMenuItems(now: now, limitResetsAt: actions.limitResetsAt, onUntil: onSnooze,
                                    onCustom: actions.onSnoozeCustom)
                } label: {
                    rowIcon("clock", tr("agents.snooze.menu"))
                }
                .composerMenu()
                .nookTip(tr("agents.snooze.menu"))
            }
            if let onWake = actions.onWake {
                // Dragged up or down, Wake takes the snoozed rows in between along; its one tip says so.
                RowActionButton(symbol: "alarm", label: tr("agents.snooze.cancel"),
                                tip: actions.onWakeSweep != nil ? tr("inbox.sweep.help.wake") : tr("agents.snooze.cancel"),
                                action: onWake)
                    .sweeps(SessionSweep.rows, from: item.id, enabled: actions.onWakeSweep != nil) { actions.onWakeSweep?($0) }
            }
            if !compactStatus {
                let label = actions.pinned ? tr("inbox.unpin") : tr("inbox.pin")
                RowActionButton(symbol: actions.pinned ? "pin.slash" : "pin", label: label, tip: label, action: actions.onPin)
            }
            // Dragged up or down, Settle (or Un-settle) takes the rows of the section in between along; its one tip says so.
            let settleLabel = actions.settled ? tr("inbox.reopen") : tr("inbox.settle")
            RowActionButton(symbol: actions.settled ? "arrow.uturn.backward" : "checkmark", label: settleLabel,
                            tip: actions.onSettleSweep != nil
                                ? tr(actions.settled ? "inbox.sweep.help.unsettle" : "inbox.sweep.help.settle") : settleLabel,
                            action: actions.onSettle)
                .sweeps(SessionSweep.rows, from: item.id, enabled: actions.onSettleSweep != nil) { actions.onSettleSweep?($0) }
        }
    }

    private func rowIcon(_ symbol: String, _ label: String) -> some View {
        Image(icon: symbol)
            .font(NookTheme.font(11, .medium))
            .foregroundStyle(NookTheme.textSecondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .accessibilityLabel(label)
    }

    /// A hover button of the row: `ToolbarIconButton`'s look, with one tip of its own (`nookTip`). A button that also
    /// sweeps says so in that one tip, instead of the button's label and the sweep's text both claiming the pointer.
    private struct RowActionButton: View {
        let symbol: String
        let label: String
        let tip: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(icon: symbol)
                    .font(NookTheme.font(11, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .roundedBackground(hovering ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .nookTip(tip)
            .accessibilityLabel(label)
        }
    }

    /// The status as a badge ("Bezig 3m", "Goedkeuring", "Klaar"), otherwise how long ago. One source: `AgentStatusStyle`.
    @ViewBuilder
    private var time: some View {
        switch item.status {
        case .working where item.subThreadsWorking > 0:
            // Busy through its sub-threads: how many, instead of how long its own (ended) turn ran.
            let count = item.subThreadsWorking
            AgentStatusBadge(state: .working, detail: count == 1 ? tr("inbox.thread.one") : tr("inbox.thread.many", count),
                             markOnly: compactStatus)
                // A mark-only badge has its own tip (the status and the count); one tip per view.
                .nookTip(count == 1 ? tr("inbox.thread.busyOne") : tr("inbox.thread.busyMany", count), enabled: !compactStatus)
        case .working:
            AgentStatusBadge(state: .working, detail: item.started.map { AgentFormat.short(now.timeIntervalSince($0)) }, markOnly: compactStatus)
        case .waiting:
            AgentStatusBadge(state: .approval, markOnly: compactStatus)
        case .input:
            AgentStatusBadge(state: .input, markOnly: compactStatus)
        case .failed:
            AgentStatusBadge(state: .failed, markOnly: compactStatus)
        case .limited:
            AgentStatusBadge(state: .limited, markOnly: compactStatus)
        case .idle where item.unseen:
            AgentStatusBadge(state: .ready, markOnly: compactStatus)
        case .idle, .finished:
            if let started = item.started {
                Text(AgentFormat.short(now.timeIntervalSince(started)))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// What a row shows on hover, as in the Claude app: the session's name, then its project, the machine it runs on, its
/// branch, and the model with the account it runs on. Once it is done, also the git step its branch needs.
struct AgentHoverCard: View {
    let item: AgentListItem

    var body: some View {
        HoverCard(title: item.title) {
            HoverCardRow(symbol: "folder", text: item.folder, help: item.path.isEmpty ? nil : AgentPathFormat.tilde(item.path))
            if !item.machine.isEmpty {
                HoverCardRow(symbol: "laptopcomputer", text: item.machine)
            }
            HoverCardRow(symbol: "arrow.triangle.branch", text: item.branch ?? tr("agents.noBranch"))
            HStack(spacing: NookTheme.Spacing.md) {
                AgentMark(agent: item.agent, account: item.account, size: 14, ring: DropdownStyle.panel)
                    .frame(width: 16)
                Text(modelLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.textTertiary)
            if !item.firstPrompt.isEmpty && item.firstPrompt != item.title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("agents.card.task"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(item.firstPrompt)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Done: the git step its branch needs, right here, as in the session panel's commit row.
            if !item.isBusy, !item.path.isEmpty {
                HoverCardGitAction(runID: runID, directory: item.path)
            }
        }
    }

    /// The session Nook runs behind a "run:<uuid>" row; nil for one it only sees.
    private var runID: UUID? {
        item.id.hasPrefix("run:") ? UUID(uuidString: String(item.id.dropFirst(4))) : nil
    }

    /// "Claude Sonnet 5.5 · Personal"; the agent's name when the model is not known.
    private var modelLine: String {
        let model = AgentFormat.model(item.model)
        let first = model.isEmpty ? item.agent : model
        return item.accountName.isEmpty ? first : "\(first) · \(item.accountName)"
    }
}

/// The conversation of a running session: what you asked and what the agent answered, newest at the bottom.
struct AgentConversation: View {
    let session: AgentSession
    /// Sends an answer to the agent when an option of its last question is tapped; nil when the session cannot be written to.
    var onReply: ((String) -> Void)? = nil
    /// The composer under the conversation, which scrolls on behind it.
    var bottomBar: AnyView? = nil

    /// Without a transcript: the last prompt and reply the hooks reported.
    private var fallback: [AgentChatMessage] {
        var messages: [AgentChatMessage] = []
        if !session.lastPrompt.isEmpty { messages.append(AgentChatMessage(id: "p", fromUser: true, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { messages.append(AgentChatMessage(id: "r", fromUser: false, text: session.lastReply)) }
        return messages
    }

    var body: some View {
        TranscriptConversation(path: session.transcriptPath, author: session.name,
                               accent: AgentKind(agentName: session.name)?.color ?? NookTheme.iris,
                               working: session.status == .running, compactingSince: session.compactingSince,
                               fallback: fallback, onReply: onReply,
                               bottomBar: bottomBar, directory: session.cwd,
                               waitingOn: session.status == .waiting ? (session.approvalID != nil ? .approval : .question) : nil)
            .id(session.id)
    }
}

/// Sessions Nook runs itself (started here, taken over, or from the workspace), newest first. One you have not settled
/// stays however long ago it last ran, so a quiet chat never drops out of its folder; a settled one as long as earlier
/// sessions from transcripts (`AgentHistory.listDays`), so the "Settled" count grows with every session you settle. The
/// list pages through them (`InboxLayout.settledPage`). Selecting one shows it on the right, where you control it completely.
@MainActor
enum WorkspaceRunsSection {
    /// How long a settled session stays in the list after its last activity.
    static let settledLifetime = TimeInterval(AgentHistory.listDays) * 86_400

    static func recent(_ workspace: WorkspaceManager, finished: FinishedSessions? = nil, now: Date = Date()) -> [WorkspaceRun] {
        let finished = finished ?? .shared
        // Sorted by position, and each session copied once into the result: the notch and the Agents list ask for this on
        // every redraw, and sorting and filtering the sessions themselves copied every one (a large struct) several times.
        let runs = workspace.runs
        let order = runs.indices.filter { !runs[$0].archived }.sorted { a, b in
            let (x, y) = (runs[a], runs[b])
            return (x.status.isActive ? 0 : 1, y.updatedAt) < (y.status.isActive ? 0 : 1, x.updatedAt)
        }
        var open: [WorkspaceRun] = []
        var settled: [WorkspaceRun] = []
        for index in order {
            let run = runs[index]
            if run.status.isActive || !finished.isSettled(FinishedSessions.key(run: run), lastActive: run.updatedAt) {
                open.append(run)
            } else if now.timeIntervalSince(run.updatedAt) < settledLifetime {
                settled.append(run)
            }
        }
        // A side chat is listed with its parent only (nested under it), never as a session of its own.
        return SideChat.listed(open + settled)
    }
}

/// Takes over an earlier conversation as a Nook session the moment it opens, so it works and looks like a session
/// started in Nook. While that runs, or when it cannot (`fallback`), the read-only view shows.
struct ImportedSession<Fallback: View>: View {
    @EnvironmentObject private var app: AppModel
    let session: PastSession
    @ViewBuilder let fallback: () -> Fallback
    @State private var failed = false

    var body: some View {
        if failed || !app.canContinueInNook(session) {
            fallback()
        } else if let taken = app.adoptedRun(for: session) {
            // Already taken over: straight on to its session, without reading anything.
            Color.clear
                .onAppear {
                    app.viewModel.continueSession(as: "run:" + taken.uuidString, from: app.viewModel.selectedAgentID)
                }
        } else {
            // The conversation as last read (kept in `TranscriptCache`) while the takeover runs, so the switch to the
            // session is from one conversation to the same one, not from a spinner. Not to be used meanwhile: what
            // you typed or sent there would go to the read-only session.
            fallback()
                .allowsHitTesting(false)
                .task(id: session.id) {
                    do { _ = try await app.continueInNook(session) } catch { failed = true }
                }
        }
    }
}
