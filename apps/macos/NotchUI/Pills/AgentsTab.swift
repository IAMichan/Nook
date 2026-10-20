import SwiftUI
import AppKit

/// Your agents in the notch. On the left every session, from whichever agent, started here or in a terminal; on the
/// right the session you picked, or, after the new-session button, the place to start one. A row shows the folder and
/// how long the session has been going, its name, and its branch with the agent's logo; the badge on the logo says
/// whether it runs under a personal or a work account. Finished sessions wait folded away at the bottom.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared
    @State private var palette = false
    /// How wide the session list is: drag the line beside it, double-click it to reset. Remembered.
    @AppStorage("nook.agents.listWidth") private var listWidth = PanelLayout.agentsList
    @State private var totalWidth: Double = 0

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case pullRequests
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
        let past = app.demoMode ? [] : Array(lists.past
            .filter { app.profile(for: $0).map(app.isConnected) ?? false }.prefix(60))
        let selection = resolve(live: live, past: past)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                listHeader(selection)
                sessionList(live: live, past: past, transcripts: transcripts, selection: selection)
                if !app.demoMode {
                    PanelFooter(selected: selectedID(selection), open: { viewModel.selectedAgentID = $0 },
                                openSettings: { app.openSettings() })
                }
            }
            .padding(.trailing, 4)
            .resizablePanel(width: $listWidth, defaultWidth: PanelLayout.agentsList, minimum: PanelLayout.minimumList,
                            available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                            edge: .trailing, divider: true)

            Group {
                switch selection {
                case .live(let session):
                    SessionWorkbench(viewModel: viewModel, directory: session.cwd) { tools in
                        AgentSessionDetail(selection: .live(session), headerAccessory: tools)
                    }
                    .id(session.id)
                case .past(let session):
                    SessionWorkbench(viewModel: viewModel, directory: session.cwd) { tools in
                        AgentSessionDetail(selection: .past(session), headerAccessory: tools)
                    }
                    .id("past:" + session.id)
                case .run(let id):
                    let run = app.workspace.run(id)
                    SessionWorkbench(viewModel: viewModel, directory: run?.workingDirectory ?? "", runID: id) { tools in
                        AgentRunPanel(workspace: app.workspace, runID: id, headerAccessory: tools)
                    }
                    // Each session gets its own panel state: nothing (a pending "restore files" above all) carries over.
                    .id("run:" + id.uuidString)
                case .pullRequests: PullRequestsPanel()
                case .usage: AgentsUsagePanel()
                case .terminals: AgentsToolPage(title: tr("agents.footer.terminals")) { TerminalsView() }
                case .browser: AgentsToolPage(title: tr("agents.footer.browser")) { BrowserView() }
                case .worktrees: AgentsToolPage(title: tr("agents.footer.worktrees")) { WorktreesView() }
                case .simulator: AgentsToolPage(title: tr("agents.footer.simulator")) { SimulatorView() }
                case .new:
                    if app.demoMode {
                        nothingRunning
                    } else {
                        NewSessionComposer { id in viewModel.selectedAgentID = "run:" + id.uuidString }
                    }
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .overlay(alignment: .top) {
            if palette {
                AgentCommandPalette(viewModel: viewModel) { palette = false }
                    .padding(.top, 40)
                    .transition(.opacity)
            }
        }
        .background {
            Button("") { palette.toggle() }.keyboardShortcut("k", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .onAppear {
            app.hub.refreshDetected()
            app.adoptAccounts()
            app.history.refresh()
        }
        // Keep sessions and usage up to date while the tab remains open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                app.adoptAccounts()
                app.history.refresh()
            }
        }
    }

    // MARK: List header

    /// "Agents" with the button that starts a new session.
    private func listHeader(_ selection: Selection) -> some View {
        let isNew: Bool = { if case .new = selection { return true }; return false }()
        return HStack(spacing: 8) {
            Text(tr("tab.agents"))
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: 4)
            if !app.demoMode {
                Button {
                    viewModel.selectedAgentID = "new"
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isNew ? NookTheme.paper : NookTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isNew ? NookTheme.smoke : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("agents.newSession"))
                .accessibilityLabel(tr("agents.newSession"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }

    // MARK: Selection

    /// What is shown on the right. Without a choice (or when it is gone): whatever waits for you or works, otherwise the
    /// place to start a new session.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id == "new" { return .new }
        if id == AgentsPage.pullRequests && !app.demoMode { return .pullRequests }
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
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = live.first(where: { $0.status == .waiting || $0.approvalID != nil || $0.status == .running }) { return .live(first) }
        if app.demoMode, let first = live.first { return .live(first) }
        return .new
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .pullRequests: return AgentsPage.pullRequests
        case .usage: return AgentsPage.usage
        case .terminals: return AgentsPage.terminals
        case .browser: return AgentsPage.browser
        case .worktrees: return AgentsPage.worktrees
        case .simulator: return AgentsPage.simulator
        case .new: return "new"
        }
    }

    // MARK: List

    private func sessionList(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession],
                             selection: Selection) -> some View {
        let current = selectedID(selection)
        let runs = app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace)
        // A cloud session that works or waits for you (Claude app, claude.ai/code) is listed with the running ones.
        let cloudActive = past.filter { $0.cloud?.isActive == true }
        let running = sorted(runs.map { item($0) } + live.map { item($0, transcript: transcripts[$0.id]) } + cloudActive.map { item($0) })
        let busyKeys = Set(running.filter(\.isBusy).map(\.finishKey))
        let earlier = past.filter { $0.cloud?.isActive != true }

        return VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                AgentInboxList(items: running, past: earlier.map { item($0) }.filter { !busyKeys.contains($0.finishKey) },
                               current: current, now: context.date) { viewModel.selectedAgentID = $0 }
            }
            if let note = cloudNote {
                Text(note)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The agent works in a chat you had marked as finished: it is not finished after all,
        // unless you marked it during this very busy spell.
        .onChange(of: busyKeys) { _, keys in finishedMarks.reconcile(busy: keys) }
        .onAppear {
            finishedMarks.reconcile(busy: busyKeys)
            visits.visit(current)
        }
        // Looking at a session counts as having seen what it finished.
        // Leaving a session counts too: what finished while you watched it is not "new".
        .onChange(of: current) { old, new in
            visits.visit(old)
            visits.visit(new)
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
            accountName: accountName(app.profile(for: run))
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
        var title = session.project
        if !session.summary.isEmpty { title = AgentFormat.title(session.summary) }
        else if let known, !known.title.isEmpty { title = AgentFormat.title(known.title) }
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
            finishKey: FinishedSessions.key(agent: session.name, conversation: conversation, fallback: session.id),
            unseen: session.status == .done && unseen(session.id, session.updated),
            machine: MachineName.local,
            model: known?.model ?? "",
            accountName: accountName(app.profile(for: session))
        )
    }

    private func item(_ session: PastSession) -> AgentListItem {
        var status = AgentListItem.Status.finished
        switch session.cloud?.status {
        case .running?: status = .working
        case .needsYou?: status = .waiting
        case .failed?: status = .failed
        default: break
        }
        return AgentListItem(
            id: "past:" + session.id,
            folder: session.project,
            title: AgentFormat.title(session.title),
            branch: session.branch.isEmpty ? nil : session.branch,
            agent: session.cloud == nil ? session.agent.name : AppModel.cloudAgentName,
            account: account(app.profile(for: session)),
            status: status,
            started: session.cloud?.isActive == true ? session.started : session.ended,
            path: session.cwd,
            finishKey: FinishedSessions.key(agent: session.agent.name, conversation: session.sessionID, fallback: "past:" + session.id),
            machine: session.cloud == nil ? MachineName.local : tr("agents.hover.cloud"),
            model: session.cloud?.model ?? session.model,
            accountName: accountName(app.profile(for: session))
        )
    }

    /// Finished after you last looked, and not the session you are looking at now.
    private func unseen(_ id: String, _ finished: Date?) -> Bool {
        guard !app.demoMode, let finished, id != viewModel.selectedAgentID else { return false }
        return visits.isUnseen(id, finished: finished)
    }

    /// Why the sessions in the Claude app's cloud are missing, for a connected Claude account whose list could not be read.
    /// Being offline is not worth a line: the list is simply read again later.
    private var cloudNote: String? {
        guard !app.demoMode else { return nil }
        let problems = app.profiles.all
            .filter { $0.kind == .claude && !$0.usesAPIKey && app.isConnected($0) }
            .compactMap { app.history.cloudProblems[$0.id] }
        for problem in problems {
            switch problem {
            case .loginExpired: return tr("agents.cloud.loginExpired")
            case .notSignedIn: return tr("agents.cloud.notSignedIn")
            case .refused(let status): return String(format: tr("agents.cloud.refused"), String(status))
            case .unreachable: continue
            }
        }
        return nil
    }

    /// Sample data only: nothing to start.
    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("agents.noneWorkingNow"))
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.nothingRunningDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
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

    /// Busy or waiting for you: it cannot be marked as finished yet.
    var isBusy: Bool { status == .working || status == .waiting || status == .input }

    func markedFinished() -> AgentListItem {
        AgentListItem(id: id, folder: folder, title: title, branch: branch, agent: agent, account: account, status: .finished,
                      started: started, path: path, finishKey: finishKey,
                      machine: machine, model: model, accountName: accountName)
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

/// The folder and the time on top, the name of the session, and its branch with the agent's logo underneath. A row that
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

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering) }
    private var dimmed: Bool { item.status == .finished || slim }
    private var restOpacity: Double { receded && item.status == .working && !hovering && !selected ? 0.7 : 1 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.plain)
            if let actions {
                hoverActions(actions)
                    .padding(.top, slim ? 8 : 9)
                    .padding(.trailing, 10)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .onHover { hovering = $0 }
        .hoverCard { AgentHoverCard(item: item) }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        Group {
            if slim { slimBody } else { fullBody }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, slim ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .contentShape(Rectangle())
        .opacity(restOpacity)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.folder)
                    .lineLimit(1)
                    .help(AgentPathFormat.tilde(item.path))
                if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(NookTheme.textTertiary) }
                Spacer(minLength: 6)
                slot.opacity(hovering && actions != nil ? 0 : 1)
            }
            .font(NookTheme.font(12))
            .foregroundStyle(receded ? NookTheme.textTertiary : NookTheme.textSecondary)

            Text(item.title)
                .font(NookTheme.font(14.5, receded ? .regular : .medium))
                .foregroundStyle(dimmed || receded ? NookTheme.textSecondary : NookTheme.paper)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium))
                Text(item.branch ?? tr("agents.noBranch")).lineLimit(1).truncationMode(.middle)
                if let pullRequest { PullRequestPill(badge: pullRequest) }
                Spacer(minLength: 6)
                AgentMark(agent: item.agent, account: item.account, size: 15, dimmed: dimmed, ring: background)
                    .padding(.trailing, item.account == nil ? 0 : 3)
            }
            .font(NookTheme.font(12))
            .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private var slimBody: some View {
        HStack(spacing: 8) {
            AgentMark(agent: item.agent, account: item.account, size: 13, dimmed: true, ring: background)
            Text(item.title)
                .font(NookTheme.font(13))
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
        HStack(spacing: 2) {
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(NookTheme.textSecondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .help(label)
            .accessibilityLabel(label)
    }

    private func rowButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { rowIcon(symbol, label) }.buttonStyle(.plain)
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
                    .font(NookTheme.font(11.5))
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
                HoverCardRow(symbol: item.agent == AppModel.cloudAgentName ? "cloud" : "laptopcomputer", text: item.machine)
            }
            HoverCardRow(symbol: "arrow.triangle.branch", text: item.branch ?? tr("agents.noBranch"))
            HStack(spacing: 8) {
                AgentMark(agent: item.agent, account: item.account, size: 14, ring: DropdownStyle.panel)
                    .frame(width: 16)
                Text(modelLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(NookTheme.font(12.5))
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
    /// The outputs panel next to the conversation; its button sits in the header above.
    var outputsOpen: Binding<Bool> = .constant(false)
    /// Sends an answer to the agent when an option of its last question is tapped; nil when the session cannot be written to.
    var onReply: ((String) -> Void)? = nil

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
                               directory: session.cwd, outputsOpen: outputsOpen)
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
