import SwiftUI
import AppKit

/// Your agents in the notch. On the left every session, from whichever agent, started here or in a terminal; on the
/// right the session you picked, or, after the new-session button, the place to start one. A row shows the folder and
/// how long the session has been going, its name, and its branch with the agent's logo; the badge on the logo says
/// whether it runs under a personal or a work account. Finished sessions wait folded away at the bottom.
/// The list is a side panel like the ones on the right (`SidePanel.swift`): drag its line to resize it, and beside a
/// session put it away with the button at the end of its title row or the left toggle in the session's header.
struct AgentsTab: View {
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
    /// What was open before the pull requests page; empty picks what waits for you, as on a fresh start.
    @State private var beforePullRequests = ""

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case pullRequests
        case actions
        case usage
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
        // A session with its side panel open needs room for both: the list gives way first, so a narrow window keeps
        // the conversation and the panel side by side for as long as it can.
        let besideRoom = workbench(selection) && viewModel.sessionTool != .conversation
            ? PanelLayout.minimumPanel + PanelSplit.handle + NookTheme.Spacing.sm + 10 : 0
        // Only a session whose header has the toggle to bring the list back can do without it (`canHideList`). Too
        // narrow for both (split view, a small window): the list or what is open, one at a time over the whole width.
        let stacked = PanelLayout.stacks(totalWidth)
        let listShown = stacked ? !listHidden : !listHidden || !canHideList(selection)
        let entries = listEntries(live: live, past: past, transcripts: transcripts)
        HStack(alignment: .top, spacing: 0) {
            if listShown {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    listHeader(selection)
                    sessionList(entries, selection: selection)
                    if !app.demoMode {
                        PanelFooter(selected: selectedID(selection), open: { open($0) },
                                    openSettings: { app.openSettings() }, history: app.history,
                                    onBack: { viewModel.selectedAgentID = beforePullRequests })
                    }
                }
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
                                             agentWorking: session.status == .running || session.status == .waiting) { tools in
                                AgentSessionDetail(selection: .live(session), headerAccessory: tools)
                            }
                            .id(session.id)
                        case .past(let session):
                            SessionWorkbench(viewModel: viewModel, directory: session.cwd, dockSessionPanel: true) { tools in
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
                                AgentRunPanel(workspace: app.workspace, runID: id, headerAccessory: tools)
                            }
                            // Each session gets its own panel state: nothing (a pending "restore files" above all) carries over.
                            .id("run:" + id.uuidString)
                        case .pullRequests: PullRequestsPanel()
                        case .actions: ActionsPanel()
                        case .usage: AgentsUsagePanel()
                        case .terminals: AgentsToolPage(title: tr("agents.footer.terminals")) { TerminalsView() }
                        case .browser: AgentsToolPage(title: tr("agents.footer.browser")) { BrowserView() }
                        case .worktrees: AgentsToolPage(title: tr("agents.footer.worktrees")) { WorktreesView() }
                        case .simulator: AgentsToolPage(title: tr("agents.footer.simulator")) { SimulatorView() }
                        case .new:
                            if app.demoMode {
                                nothingRunning
                            } else {
                                SessionWorkbench(viewModel: viewModel, directory: newDirectory) { tools in
                                    NewSessionComposer(headerAccessory: tools, onDirectory: { newDirectory = $0 }) { id in
                                        viewModel.selectedAgentID = "run:" + id.uuidString
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, listShown ? 10 : 0)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            visits.visit(selectedID(selection))
        }
        .onChange(of: selectedID(selection)) { old, new in
            visits.visit(old)
            visits.visit(new)
            prefetchNeighbours(of: new, in: entries)
        }
        // Exactly the width it is given, however wide a row inside wants to be: measuring a row that runs past the window
        // would hand the panels more room than there is and push everything off both sides.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        // Where back on the pull requests page returns to.
        .onChange(of: viewModel.selectedAgentID) { previous, id in
            if id == AgentsPage.pullRequests, previous != AgentsPage.pullRequests { beforePullRequests = previous }
        }
        .overlay(alignment: .top) {
            if palette {
                AgentCommandPalette(viewModel: viewModel) { palette = false }
                    .padding(.top, 40)
                    .transition(.opacity)
            }
        }
        .keyCommands(["commandPalette.toggle": { palette.toggle(); return true }], context: ["paletteOpen": palette])
        // Keep sessions and usage up to date while the tab remains open. Without the loading state: a refresh in the
        // background that flips it redraws the whole window twice for a list that is already there.
        .task {
            // The first refresh waits until the switch to this tab has settled: what it publishes redraws the whole app,
            // and in the middle of the switch that made it stutter.
            try? await Task.sleep(for: NookTheme.tabSettle)
            guard !Task.isCancelled else { return }
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

    /// "Agents" with the button that starts a new session, and beside a session the cross that puts the list away
    /// (the same close button every side panel ends with); the left toggle in the session's header brings it back.
    private func listHeader(_ selection: Selection) -> some View {
        let isNew: Bool = { if case .new = selection { return true }; return false }()
        return PanelListHeader(tr("tab.agents")) {
            if !app.demoMode {
                PanelNewButton(label: tr("agents.newSession"), active: isNew) { open("new") }
            }
            if canHideList(selection) {
                SidePanelCloseButton(help: tr("agents.list.hide")) {
                    withAnimation(NookTheme.reveal) { listHidden = true }
                }
            }
        }
        .padding(.bottom, NookTheme.Spacing.xs)
    }

    // MARK: Selection

    /// Opens a session or a page; while the tab shows one column at a time, that takes the list's place.
    private func open(_ id: String) {
        viewModel.selectedAgentID = id
        if PanelLayout.stacks(totalWidth) { withAnimation(NookTheme.reveal) { listHidden = true } }
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

    /// The list can be put away only where the session's header shows the toggle that brings it back: a session in a
    /// workbench on this Mac, not one on another machine (its header has no panel toggles) and not the sample data.
    private func canHideList(_ selection: Selection) -> Bool {
        guard !app.demoMode, workbench(selection) else { return false }
        if case .run(let id) = selection, app.workspace.run(id)?.remote != nil { return false }
        return true
    }

    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id == "new" { return .new }
        if id == AgentsPage.pullRequests && !app.demoMode { return .pullRequests }
        if id == AgentsPage.actions && !app.demoMode { return .actions }
        if id == AgentsPage.usage && !app.demoMode { return .usage }
        if id == AgentsPage.terminals && !app.demoMode { return .terminals }
        if id == AgentsPage.browser && !app.demoMode { return .browser }
        if id == AgentsPage.worktrees && !app.demoMode { return .worktrees }
        if id == AgentsPage.simulator && !app.demoMode { return .simulator }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        // A session that waits for you comes before a run that is only busy.
        if let first = live.first(where: { $0.status == .waiting || $0.approvalID != nil }) { return .live(first) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = live.first(where: { $0.status == .running }) { return .live(first) }
        if app.demoMode, let first = live.first { return .live(first) }
        return .new
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .pullRequests: return AgentsPage.pullRequests
        case .actions: return AgentsPage.actions
        case .usage: return AgentsPage.usage
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
    }

    private func listEntries(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession]) -> ListEntries {
        let runs = app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace)
        let built = sorted(runs.map { item($0) } + live.map { item($0, transcript: transcripts[$0.id]) })
        let busyKeys = Set(built.filter(\.isBusy).map(\.finishKey))
        let (running, earlier) = Self.linkSpawned(running: built,
                                                  past: past.map { item($0) }.filter { !busyKeys.contains($0.finishKey) })
        return ListEntries(running: running, earlier: earlier, busyKeys: busyKeys)
    }

    private func sessionList(_ entries: ListEntries, selection: Selection) -> some View {
        let current = selectedID(selection)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                AgentInboxList(items: entries.running, past: entries.earlier,
                               current: current, now: context.date) { open($0) }
            }
        }
    }

    /// Gives a session another one spawned (Claude desktop's suggested tasks) that one as its parent, so the list shows it
    /// underneath. A parent Nook already knows (delegated, forked) stays.
    private static func linkSpawned(running: [AgentListItem], past: [AgentListItem]) -> ([AgentListItem], [AgentListItem]) {
        let all = running + past
        guard all.contains(where: { !$0.spawnedTasks.isEmpty }) else { return (running, past) }
        let parents = SpawnedSessions.parents(
            firstPrompts: Dictionary(all.map { ($0.id, $0.firstPrompt) }, uniquingKeysWith: { first, _ in first }),
            tasks: Dictionary(all.filter { !$0.spawnedTasks.isEmpty }.map { ($0.id, $0.spawnedTasks) }, uniquingKeysWith: { first, _ in first }))
        func linked(_ items: [AgentListItem]) -> [AgentListItem] {
            items.map { item in
                var item = item
                if item.parentID == nil { item.parentID = parents[item.id] }
                return item
            }
        }
        return (linked(running), linked(past))
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

    private func account(_ profile: AgentProfile?) -> AccountKind? {
        guard !app.demoMode, let profile else { return nil }
        return AccountKind.of(profile, app: app)
    }

    private func accountName(_ profile: AgentProfile?) -> String {
        guard !app.demoMode, let profile else { return "" }
        return AccountLabel.name(profile, app: app)
    }

    private func item(_ run: WorkspaceRun) -> AgentListItem {
        // One answer to "what does this need from you" (approval, question, limit, snooze), shared with the notch.
        let attention = app.workspace.attention(run, unseen: run.status == .completed && unseen("run:" + run.id.uuidString, run.updatedAt),
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
            started: run.status.isActive ? (run.turnStartedAt ?? run.createdAt) : run.updatedAt,
            path: run.workingDirectory,
            finishKey: FinishedSessions.key(run: run),
            unseen: attention == .ready,
            snoozedUntil: run.snoozedUntil,
            snoozedAt: run.snoozedAt,
            machine: run.remote?.name ?? MachineName.local,
            model: run.resolvedModel ?? run.model,
            accountName: accountName(app.profile(for: run)),
            // A session Nook delegated to or forked from another one, or a later model of a comparison.
            parentID: (run.delegation?.parentID ?? run.lineage?.parentID).map { "run:" + $0.uuidString },
            comparison: app.workspace.runs.filter { $0.lineage?.kind == .comparison && $0.lineage?.parentID == run.id }.count,
            forked: run.lineage?.kind == .fork
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
            default: status = .idle
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
                : (session.turnStarted ?? session.started ?? known?.started),
            path: session.cwd,
            finishKey: FinishedSessions.key(session: session),
            unseen: session.status == .done && unseen(session.id, session.updated),
            machine: MachineName.local,
            model: known?.model ?? "",
            accountName: accountName(app.profile(for: session)),
            firstPrompt: known?.firstPrompt ?? "",
            spawnedTasks: known?.spawnedTasks ?? []
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
            spawnedTasks: session.spawnedTasks
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
struct AgentListItem: Identifiable {
    enum Status { case working, waiting, input, failed, limited, idle, finished }

    /// The selection id: a hub session id, "run:<uuid>" or "past:<id>".
    let id: String
    let folder: String
    let title: String
    let branch: String?
    /// The agent's display name, for its logo.
    let agent: String
    let account: AccountKind?
    let status: Status
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

    /// Busy or waiting for you: it cannot be marked as finished yet.
    var isBusy: Bool { status == .working || status == .waiting || status == .input }

    func markedFinished() -> AgentListItem {
        AgentListItem(id: id, folder: folder, title: title, branch: branch, agent: agent, account: account, status: .finished,
                      started: started, path: path, finishKey: finishKey,
                      machine: machine, model: model, accountName: accountName,
                      parentID: parentID, firstPrompt: firstPrompt, spawnedTasks: spawnedTasks, comparison: comparison,
                      forked: forked)
    }
}

/// What a row can do on hover: the right slot swaps, without shifting the layout, between the
/// status and these buttons.
struct AgentRowActions {
    var pinned: Bool
    var onPin: () -> Void
    var settled: Bool
    var onSettle: () -> Void
    /// Snoozing and waking are for sessions Nook runs.
    var onSnooze: ((SnoozePolicy.Choice) -> Void)? = nil
    var onWake: (() -> Void)? = nil
}

/// The name of the session with its status, and where it works with the agent's logo underneath. A row that
/// asks nothing of you recedes (lighter text, normal weight, working rows dimmed) so what needs you is the only loud thing.
struct AgentListRow: View {
    let item: AgentListItem
    let now: Date
    let selected: Bool
    var receded = false
    var pinned = false
    var woke = false
    /// One line, for the snoozed and settled shelves.
    var slim = false
    /// When a snoozed row wakes, as text ("tot 9:00").
    var wakeLabel: String? = nil
    var actions: AgentRowActions? = nil
    /// "#12" of the session's pull request.
    var pullRequest: PullRequestBadge? = nil
    let action: () -> Void
    @State private var hovering = false
    /// The pointer is on the hover buttons.
    @State private var onActions = false

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering) }
    private var dimmed: Bool { item.status == .finished || slim }
    private var restOpacity: Double { receded && item.status == .working && !hovering && !selected ? 0.7 : 1 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.plain)
            if let actions {
                hoverActions(actions)
                    .rowActionsBackdrop(background)
                    .padding(.top, slim ? NookTheme.Spacing.sm : NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                    .padding(.trailing, NookTheme.Spacing.md)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .onHover { onActions = $0 }
            }
        }
        .onHover { hovering = $0 }
        // Closed over the buttons, so their first click is not spent closing the card.
        .hoverCard(suppressed: onActions) { AgentHoverCard(item: item) }
        .accessibilityElement(children: .combine)
        // The hover buttons are merged away above, so VoiceOver gets them as the row's actions.
        .accessibilityActions {
            if let actions {
                Button(actions.pinned ? tr("inbox.unpin") : tr("inbox.pin"), action: actions.onPin)
                Button(actions.settled ? tr("inbox.reopen") : tr("inbox.settle"), action: actions.onSettle)
                if let onWake = actions.onWake {
                    Button(tr("agents.snooze.cancel"), action: onWake)
                }
                if let onSnooze = actions.onSnooze {
                    ForEach(SnoozePolicy.Choice.allCases, id: \.self) { choice in
                        Button(tr("agents.snooze." + choice.rawValue)) { onSnooze(choice) }
                    }
                }
            }
        }
    }

    private var content: some View {
        Group {
            if slim { slimBody } else { fullBody }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, slim ? NookTheme.Spacing.md : NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(background))
        .selectionMark(selected)
        .contentShape(Rectangle())
        .opacity(restOpacity)
    }

    /// Two lines: the session's name with its status on the right, and where it works (folder and branch) with the
    /// agent's logo underneath. One quiet line of context is enough to tell sessions apart; the hover card has the rest.
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if pinned {
                    Image(systemName: "pin.fill").font(NookTheme.font(9)).foregroundStyle(NookTheme.textTertiary)
                }
                if item.forked {
                    Image(systemName: "arrow.triangle.branch")
                        .font(NookTheme.font(10))
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(tr("lineage.forked"))
                        .accessibilityLabel(tr("lineage.forked"))
                }
                if item.comparison > 0 {
                    Image(systemName: "square.stack.3d.up")
                        .font(NookTheme.font(10))
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(tr("compare.group", item.comparison + 1))
                        .accessibilityLabel(tr("compare.group", item.comparison + 1))
                }
                Text(item.title)
                    .font(receded ? NookTheme.TextStyle.body : NookTheme.TextStyle.strong)
                    .foregroundStyle(dimmed || receded ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                slot.opacity(hovering && actions != nil ? 0 : 1)
            }

            HStack(spacing: NookTheme.Spacing.sm) {
                contextLine
                if let pullRequest { PullRequestPill(badge: pullRequest, compact: true) }
                Spacer(minLength: NookTheme.Spacing.sm)
                AgentMark(agent: item.agent, account: item.account, size: 14, dimmed: dimmed, ring: background,
                          quiet: !hovering && !selected)
                    .padding(.trailing, item.account == nil ? 0 : 3)
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
        }
    }

    /// "[folder] nook  [branch] feature/calm-ui": the folder, and the branch when there is one. The folder stays whole
    /// and goes first: a long branch gives way, cut in the middle.
    private var contextLine: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            NookSymbol("folder", size: 10).font(NookTheme.font(9.5, .semibold))
            Text(item.folder)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let branch = item.branch, !branch.isEmpty, branch != item.folder {
                NookSymbol("arrow.triangle.branch", size: 10).font(NookTheme.font(9.5, .semibold))
                    .padding(.leading, NookTheme.Spacing.xs)
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(AgentPathFormat.tilde(item.path))
        .accessibilityElement(children: .combine)
    }

    private var slimBody: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            AgentMark(agent: item.agent, account: item.account, size: 13, dimmed: true, ring: background)
            Text(item.title)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let pullRequest { PullRequestPill(badge: pullRequest, compact: true) }
            slot.opacity(hovering && actions != nil ? 0 : 1)
        }
    }

    /// The right slot: the wake time of a snoozed row, "Wakker" for one that woke, otherwise the status or how long ago.
    @ViewBuilder
    private var slot: some View {
        if let wakeLabel {
            AgentStatusBadge(state: .snoozed, detail: wakeLabel)
        } else if woke {
            AgentStatusBadge(state: .woke)
        } else {
            time
        }
    }

    @ViewBuilder
    private func hoverActions(_ actions: AgentRowActions) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if let onSnooze = actions.onSnooze {
                Menu {
                    ForEach(SnoozePolicy.Choice.allCases, id: \.self) { choice in
                        Button(tr("agents.snooze." + choice.rawValue)) { onSnooze(choice) }
                    }
                } label: {
                    rowIcon("clock", tr("agents.snooze.menu"))
                }
                .composerMenu()
            }
            if let onWake = actions.onWake {
                rowButton("alarm", tr("agents.snooze.cancel"), onWake)
            }
            rowButton(actions.pinned ? "pin.slash" : "pin", actions.pinned ? tr("inbox.unpin") : tr("inbox.pin"), actions.onPin)
            rowButton(actions.settled ? "arrow.uturn.backward" : "checkmark",
                      actions.settled ? tr("inbox.reopen") : tr("inbox.settle"), actions.onSettle)
        }
    }

    private func rowIcon(_ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(NookTheme.font(11, .medium))
            .foregroundStyle(NookTheme.textSecondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .help(label)
            .accessibilityLabel(label)
    }

    private func rowButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, label, height: 22, width: 22, action)
            .pointerStyle(.link)
    }

    /// The status as a badge ("Bezig 3m", "Goedkeuring", "Klaar"), otherwise how long ago. One source: `AgentStatusStyle`.
    @ViewBuilder
    private var time: some View {
        switch item.status {
        case .working:
            AgentStatusBadge(state: .working, detail: item.started.map { AgentFormat.short(now.timeIntervalSince($0)) })
        case .waiting:
            AgentStatusBadge(state: .approval)
        case .input:
            AgentStatusBadge(state: .input)
        case .failed:
            AgentStatusBadge(state: .failed)
        case .limited:
            AgentStatusBadge(state: .limited)
        case .idle where item.unseen:
            AgentStatusBadge(state: .ready)
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
/// branch, and the model with the account it runs on.
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
        }
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
                               working: session.status == .running, fallback: fallback, onReply: onReply,
                               bottomBar: bottomBar, directory: session.cwd)
            .id(session.id)
    }
}

/// Sessions Nook runs itself (started here, taken over, or from the workspace): working, waiting, or finished in the
/// last day, newest first. Selecting one shows it on the right, where you control it completely.
@MainActor
enum WorkspaceRunsSection {
    static func recent(_ workspace: WorkspaceManager) -> [WorkspaceRun] {
        let list = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 24 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
        return Array(list.prefix(12))
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
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: session.id) {
                    do { _ = try await app.continueInNook(session) } catch { failed = true }
                }
        }
    }
}
