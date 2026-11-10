import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// A session that Nook runs itself, inside the Agents tab: the whole conversation, approvals, stop, follow-up
/// messages, and the settings for the next turn (mode, permissions, model). Everything you would otherwise do in a
/// terminal happens here.
struct AgentRunPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    /// The timeline changes as the agent streams (`WorkspaceManager.timelines`); only this panel redraws for it.
    @ObservedObject var timelines: TimelineChanges
    let runID: UUID
    /// The terminal and browser icons, next to the branch button.
    var headerAccessory: AnyView? = nil
    /// What you are writing: held, not observed, so a keystroke redraws the composer (`Observing` around it) and not the
    /// conversation above it. Read and written through `draft`, `images`, `quotes` and `editingQueued` below.
    @State private var composerState = RunComposerState()
    @State private var expanded: Set<UUID> = []
    /// Opened groups and folded turns ("group:<id>", "fold:<id>").
    @State private var openBlocks: Set<String> = []
    /// "Back to before this message": the message, and why it could not, if it could not.
    @State private var revertTarget: RunEvent?
    @State private var revertError: String?
    /// "Edit from here": the message to go back to before and write again, why it could not, and whether it runs.
    @State private var editTarget: RunEvent?
    @State private var editError: String?
    @State private var editWorking = false
    /// Bumped when the session's machine was unlocked with its password, so the field goes away.
    @State private var unlockedAt: Date?
    @State private var reverting = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    /// The older branches of a session that worked on many, shown in the tray above the composer.
    @State private var showsOlderBranches = false
    /// The `#` list needs the repository ("owner/repo") of the session's folder.
    @State private var repository: String?
    /// The agent's skills for `$`, read from its skill folders.
    @State private var skills: [Skill] = []
    @State private var scroll = ScrollModel()
    /// Quote and Ask about this, for every answer's text view: the same two closures on every redraw, so a streamed token
    /// does not hand each answer a new environment.
    @State private var selectionActions = StableSelectionActions()
    /// Held, not observed: its height changes as streamed rows are laid out, and only `TurnPinSpacer` draws it.
    @State private var pinRoom = TurnPinRoom()
    @State private var atEnd = true
    /// Read only by the handlers: as state, each start and stop of a scroll drew every block of the run again.
    @State private var scrollPhase = Unobserved(ScrollPhase.idle)
    /// Counts the messages you sent from the composer (also those that steer or wait in line): each brings the
    /// conversation down to its end, wherever you had scrolled.
    @State private var sentCount = 0
    /// The timeline is taller than the view: only then the rail with your messages shows.
    @State private var overflows = false
    /// Where you left this session's conversation last time (TimelineVisitStore), read as it opens.
    @State private var visit: TimelineVisit?
    /// The block the "New since your last visit" line sits above; decided as the session opens.
    @State private var newSince: UUID?
    /// The session opened before its timeline was read from disk (`requestTimeline`): it lands once that is here.
    @State private var landsOnLoad = false
    /// The first turn drawn (`HistoryWindow`): a long session opens with its latest turns, "Show earlier messages" and
    /// any jump to an earlier event widen it. Nil until the session has landed.
    @State private var historyStart: Int?
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findIndex: Int?
    /// A background command is one thing in two places: its call in the conversation and its row in the bar above the
    /// composer. `barFocus` opens its row in the bar (from the conversation), `conversationFocus` scrolls to its call (from
    /// the bar), and `flashed` lights the call up for a moment once there.
    @State private var barFocus: UUID?
    @State private var conversationFocus: UUID?
    @State private var flashed: UUID?
    /// Held, not observed: only its suggestion list watches it (`ComposerSuggestionSlot`), so a key that changes the
    /// list does not redraw this whole panel.
    @State private var composerModel = ComposerModel()
    @FocusState private var focused: Bool
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared
    /// For how much of the work the timeline shows (`TimelineDetail`), when the session follows Settings.
    @ObservedObject private var workspaceSettings = WorkspaceSettings.shared
    /// The pull requests of the session's branches, for the tray above the box.
    @ObservedObject private var pullRequestSync = PullRequestSync.shared
    /// The outputs tab of the side panel around this session (`SessionWorkbench`), which shows what the agent produced.
    @Environment(\.sessionOutputs) private var outputsLink
    @Environment(\.sessionSide) private var sideLink
    @Environment(\.sessionHeaderInset) private var headerInset
    /// The outputs (by signature) you have seen, for the dot on the outputs tab; nil until the session shows.
    @State private var seenOutputs: Set<String>?
    /// The subagents (`Subagents.signature`) you have seen, for the dot on the Subagents tab; nil until the session shows.
    @State private var seenSubagents: String?
    /// The lines git counted per turn (by the turn's id), in place of those read from the agent's edits.
    @State private var countedLines: [String: TurnLines] = [:]
    /// The timeline's blocks, turns and outputs, made again only when the events change (not on every keystroke).
    @State private var derived = RunTimelineDerived()

    private var draft: String {
        get { composerState.draft }
        nonmutating set { composerState.draft = newValue }
    }
    private var images: [ImageAttachment] {
        get { composerState.images }
        nonmutating set { composerState.images = newValue }
    }
    private var quotes: ComposerQuotes {
        get { composerState.quotes }
        nonmutating set { composerState.quotes = newValue }
    }
    private var editingQueued: UUID? {
        get { composerState.editingQueued }
        nonmutating set { composerState.editingQueued = newValue }
    }

    var body: some View {
        if let run = workspace.run(runID) {
            let _ = derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run))
            let outputs = derived.outputs
            let signatures = derived.outputSignatures
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                header(run)
                // After Nook restarted, a session on a machine with a password waits for it before the next turn.
                if let machine = lockedMachine(run) {
                    RemotePasswordField(machine: machine) { _ in unlockedAt = Date() }
                }
                timeline(run)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A file the agent links to (`src/app.swift:12`) opens in your editor at that line.
            .environment(\.fileLinkBase, run.isRemote ? nil : run.workingDirectory)
            // Selected words of an answer go with the reply as a chip above the composer (right-click › Quote in your
            // message, or Ask about this, which also puts the keyboard in the box; the same with ⇧⌘L and ⌘L).
            .environment(\.quoteSelection, selectionActions.bind { addQuote($0, ask: $1) }.quote)
            .environment(\.askAboutSelection, selectionActions.ask)
            .keyCommands(["selection.quote": { quoteSelected(ask: false) }, "selection.ask": { quoteSelected(ask: true) }])
            // What the agent produced goes to the outputs tab of the side panel, with a dot while something is new.
            .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(
                outputs: outputs,
                subagents: derived.allSubagents,
                commands: derived.allCommands,
                subagentsFresh: !outputsLink.subagentsShown && seenSubagents.map { $0 != derived.subagentsSignature } == true,
                turns: turnDiffs(run),
                pullRequest: derived.createdPullRequest,
                fresh: !outputsLink.shown && seenOutputs.map { seen in signatures.contains { !seen.contains($0) } } == true))
            // What the outputs tab shows is seen.
            .onChange(of: outputsLink.shown) { _, isShown in
                if isShown { seenOutputs = Set(signatures) }
            }
            // What the Subagents tab shows is seen, also while it streams in.
            .onChange(of: outputsLink.subagentsShown) { _, isShown in
                if isShown { seenSubagents = derived.subagentsSignature }
            }
            // A subagent the agent starts while it works opens the tab, as a new plan opens the outputs tab; what a
            // session that just opened already had is not news.
            .onChange(of: derived.allSubagents.count) { before, after in
                if run.status.isActive, seenSubagents != nil, after > before, outputsLink.openSubagents() {
                    seenSubagents = derived.subagentsSignature
                }
            }
            .onChange(of: derived.subagentsSignature) { _, next in
                if outputsLink.subagentsShown || seenSubagents == nil { seenSubagents = next }
            }
            .onChange(of: signatures) { _, _ in
                noticeOutputs(outputs, working: run.status.isActive, turnStart: run.turnStartedAt)
            }
            .onAppear {
                workspace.requestTimeline(runID)
                landsOnLoad = !workspace.isTimelineLoaded(runID)
                visit = TimelineVisitStore.shared.visit(for: Self.visitKey(runID))
                if let visit { openBlocks = visit.open }
                // Quiet: the branch shown so far stays up while it is read again, and only a change redraws (a spinner
                // first would redraw every view that follows the workspace twice as the session opens).
                if run.repoRoot != nil { workspace.refreshGit(runID, quiet: true) }
                // The agent's connection opens now, so your first message goes straight in.
                workspace.prewarm(runID)
                focused = true
                // What was there before you opened the session is not news.
                seenOutputs = Set(signatures)
                seenSubagents = derived.subagentsSignature
                Task { repository = await workspace.githubRepository(runID) }
                loadComposerState(run)
            }
            .onDisappear { rememberVisit(runID) }
            .onAppear { workspace.timelineShown(runID) }
            .onDisappear { workspace.timelineHidden(runID) }
            // What the side panel hands to this session lands in the draft, to read before sending; also when it
            // arrived while this composer was not on screen.
            .onReceive(ComposerInbox.shared.$delivery.compactMap { $0 }) { _ in takeFromSidePanel() }
            .onAppear { takeFromSidePanel() }
            // F2 or the command palette's Rename: the name field in the header, with the keyboard in it.
            .onReceive(SessionRenameRequest.shared.$pending.removeDuplicates()) { id in
                guard id == runID, let title = workspace.run(runID)?.title else { return }
                SessionRenameRequest.shared.take(runID)
                titleDraft = title
                renaming = true
            }
            .onChange(of: runID) { previous, current in
                workspace.timelineHidden(previous)
                workspace.timelineShown(current)
                rememberVisit(previous)
                workspace.requestTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID, quiet: true) }
                workspace.prewarm(runID)
                // A queued message you were editing in the session you left goes back to its queue as it was, and the
                // draft that waited behind it becomes that session's draft again.
                if composerState.editingQueued != nil {
                    let restored = workspace.endEditQueued(previous, save: false)
                    ComposerDraftStore.shared.save(sessionID: previous.uuidString, text: restored ?? "")
                    composerState.editingQueued = nil
                }
                // The draft of the session you left stays saved, and the one of this session comes back.
                composerState.show(session: runID.uuidString)
                if let fresh = workspace.run(runID) { loadComposerState(fresh) }
                renaming = false
                confirmDelete = false
                // Nothing of the previous session carries over: above all not a pending "restore files".
                revertTarget = nil
                revertError = nil
                reverting = false
                editTarget = nil
                editError = nil
                editWorking = false
                openBlocks = []
                expanded = []
                countedLines = [:]
                quotes.removeAll()
                seenOutputs = nil
                seenSubagents = nil
                // Folds you had open in this session last time come back (the timeline lands on its own, below).
                visit = TimelineVisitStore.shared.visit(for: Self.visitKey(runID))
                openBlocks = visit?.open ?? []
            }
        } else {
            Text(tr("agents.run.gone"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Header

    /// While the agent works, a plan, design, document or image that is new opens the outputs tab on it, and anything
    /// new while that tab is out of view puts a dot on it. What a session that does not work shows (its timeline loading
    /// as you open it) is not news.
    private func noticeOutputs(_ outputs: [SessionOutput], working: Bool, turnStart: Date?) {
        guard working, let seen = seenOutputs else {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
            return
        }
        let fresh = outputs.filter { !seen.contains(SessionOutputs.signature($0)) }
        // Only what this turn made opens the tab by itself, not earlier work that comes in as the timeline loads.
        if let shown = fresh.first(where: { output in
            if case .tasks = output.kind { return false }
            return output.date >= (turnStart ?? .distantFuture)
        }), outputsLink.open(shown.id) {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
        } else if outputsLink.shown {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
        }
    }

    /// "nook / Agents-pagina rustiger maken" (double-click the name to rename it) with the branch button on the right.
    private func header(_ run: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            // The folder keeps its name before the title gives way, but truncates too in a narrow conversation instead
            // of pushing the header past it (under a wide side panel).
            Text(run.projectName)
                .fontWeight(.medium)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(AgentPathFormat.tilde(run.workingDirectory))
            Text("/").foregroundStyle(NookTheme.textTertiary)
            if renaming {
                TextField(tr("ws.title.placeholder"), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .onSubmit {
                        workspace.rename(runID, to: titleDraft)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
                    .focused($titleFocused)
                    .focusOnAppear($titleFocused)
            } else {
                Text(run.title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        titleDraft = run.title
                        renaming = true
                    }
                    .help(tr("ws.title.renameHelp"))
                // Nook's own dropdown panel, not a system menu: a system submenu (Connectors) closed under the pointer
                // whenever the running session redrew the header.
                ComposerDropdown(width: 248) {
                    Image(icon: "chevron.down")
                        .font(NookTheme.font(9, .bold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                } content: {
                    sessionActions(run)
                }
                .help(tr("chat.more"))
                .accessibilityLabel(tr("chat.more"))
            }
            if let lineage = run.lineage { LineageLink(workspace: workspace, lineage: lineage) }
            Spacer(minLength: 8)
            ResourceUsageBadge(workspace: workspace, runID: runID)
            if let remote = run.remote {
                // On another machine: its name, and a terminal there over SSH instead of this Mac's git and tools.
                Button { openRemoteTerminal(remote) } label: {
                    Label(remote.name, systemImage: "server.rack")
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("ws.remote.terminal", remote.host))
            } else {
                FolderGitButton(directory: run.workingDirectory, runID: runID, agentWorking: run.status.isActive, showChanges: {
                    workspace.markReviewed(runID)
                    // Next to the conversation when it has the side panel, otherwise as a task of its own.
                    if headerAccessory != nil {
                        app.viewModel.sessionTool = .changes
                    } else {
                        app.viewModel.open(.changes(runID, file: nil))
                    }
                }, onChange: {
                    workspace.refreshGit(runID)
                })
                .id(run.workingDirectory)
                if let headerAccessory { headerAccessory }
            }
        }
        .font(NookTheme.TextStyle.body)
        .frame(height: 30)
        .padding(.leading, headerInset)
        .conversationHeaderBackground()
    }

    /// What goes into the message: a file, the stash, the terminal's last lines. The session's own actions are in the
    /// menu beside its title (`sessionActions`).
    private func actionsMenu(_ run: WorkspaceRun) -> some View {
        ComposerPlusMenu(attach: { attachFile(run) }) {
            Button(tr("compose.stash.set")) {
                if let text = composerModel.stashKey(composerText: draft) { draft = text; ComposerDraftStore.shared.setStash(composerModel.stash) }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composerModel.stash.entries.isEmpty)
            // Terminal context: the last lines of this session's terminal go with your message.
            Button(tr("ws.context.terminal")) { addTerminalOutput(run) }
                .disabled(TerminalStore.shared.sessions(in: run.workingDirectory).isEmpty)
        }
    }

    /// How much of the work the timeline shows: the session's choice or the one in Settings, and everything while the
    /// find bar is open, so a match is never hidden.
    private func timelineDetail(_ run: WorkspaceRun) -> TimelineDetail {
        finding ? .everything : TimelineDetail.resolve(session: run.timelineDetail, global: workspaceSettings.timelineDetail)
    }

    /// Everything you can do with this session itself: retry, rename, fork, export, archive, delete. Rows that do not
    /// apply to this session are left out; the ones that wait for the agent to stop say so.
    @ViewBuilder
    private func sessionActions(_ run: WorkspaceRun) -> some View {
        let busy = run.status.isActive ? tr("ws.session.stopFirst") : nil
        let finishKey = FinishedSessions.key(run: run)
        let isFinished = finishedMarks.contains(finishKey)
        DropdownRow(symbol: "info.circle", title: tr("agents.run.details")) { app.viewModel.open(.details(runID)) }
        if run.status.isActive {
            DropdownRow(symbol: "stop.circle", title: tr("ws.action.stop")) { workspace.stop(runID) }
        } else if run.status == .failed || run.status == .stopped {
            DropdownRow(symbol: "arrow.clockwise", title: tr("ws.action.retry")) { workspace.retry(runID) }
        }
        DropdownRow(symbol: isFinished ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    title: isFinished ? tr("agents.finish.reopen") : tr("agents.finish.mark"), disabledReason: busy) {
            if isFinished { finishedMarks.reopenByUser(finishKey) } else { finishedMarks.mark(finishKey) }
        }
        DropdownDivider()
        DropdownRow(symbol: "pencil", title: tr("agents.run.rename")) {
            titleDraft = run.title
            renaming = true
        }
        // A new written title from the first message and the latest ones, with your title rules.
        DropdownRow(symbol: "sparkles", title: tr("ws.title.regenerate")) { workspace.regenerateTitle(runID) }
        // Pasted into another session's composer it becomes this session's chip (`SessionLink`).
        if let link = SessionLink.build(id: runID.uuidString, title: run.title) {
            DropdownRow(symbol: "link", title: tr("sessionLink.copy")) {
                Pasteboard.copy(link.absoluteString)
                ToastCenter.shared.success(tr("sessionLink.copied"))
            }
        }
        // A fork starts from this session; switching moves it to another agent with a summary of what happened.
        if workspace.canTransfer(runID) {
            DropdownRow(symbol: "arrow.triangle.branch", title: tr("agents.fork")) {
                if let id = workspace.fork(runID) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            }
        }
        if workspace.canOpenSideChat(runID) {
            DropdownRow(symbol: "bubble.left.and.text.bubble.right", title: tr("ws.side.new")) {
                if let id = workspace.openSideChat(runID, question: "") { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            }
        }
        if let lineage = run.lineage, lineage.bringsBack, workspace.canTransfer(runID) {
            DropdownRow(symbol: "arrow.uturn.left", title: tr(lineage.kind == .side ? "ws.side.bringBack" : "agents.mergeBack")) {
                if workspace.mergeBack(runID), let parent = run.lineage?.parentID {
                    app.viewModel.selectedAgentID = "run:" + parent.uuidString
                }
            }
        }
        // Ends the agent's process; the next message resumes the conversation with new skills, plugins and MCP servers.
        if workspace.canRestartAgent(runID) {
            DropdownRow(symbol: "arrow.triangle.2.circlepath", title: tr("agents.restartAgent")) { workspace.restartAgent(runID) }
        }
        // A guest link: someone follows this session in a browser; what they write waits for you (GuestShares).
        if GuestShares.shared.shared[runID] != nil {
            DropdownRow(symbol: "person.crop.circle.badge.xmark", title: tr("guest.stop")) { GuestShares.shared.stop(runID) }
        } else if GuestShares.shared.canShare, !run.archived {
            DropdownRow(symbol: "person.crop.circle.badge.plus", title: tr("guest.share"), detail: tr("guest.share.help")) {
                if let link = GuestShares.shared.share(runID) {
                    Pasteboard.copy(link)
                    ToastCenter.shared.success(tr("guest.shared"), detail: tr("guest.shared.detail"))
                }
            }
        }
        // PR watch: CI, reviews and comments on the session's pull request wake the agent.
        if run.prWatch != nil {
            DropdownRow(symbol: "eye.slash", title: tr("ws.prwatch.stop")) { workspace.watchPullRequest(runID, url: nil) }
        } else if let watchable = watchablePullRequest() {
            DropdownRow(symbol: "eye", title: tr("ws.prwatch.start")) { workspace.watchPullRequest(runID, url: watchable) }
        }
        // Connectors the agent cannot use until you sign in, also the ones you hid above the composer: a group of
        // their own in the panel, so there is no submenu to lose under the pointer.
        if let connectors = workspace.connectorSignIns[runID], !connectors.isEmpty {
            DropdownDivider()
            DropdownHeader(title: tr("ws.connector.menu"))
            ForEach(connectors) { connector in
                DropdownRow(symbol: connector.waiting ? "hourglass" : "person.badge.key",
                            title: connector.waiting ? tr("ws.connector.waiting", connector.title) : tr("ws.connector.signInTo", connector.title),
                            disabledReason: connector.waiting ? tr("ws.connector.waitingHelp") : nil) {
                    workspace.signInConnector(runID, name: connector.name)
                }
            }
        }
        DropdownDivider()
        // How much of the agent's work the timeline shows, for this session only (Settings has the default).
        DropdownHeader(title: tr("ws.detail.menu"))
        let shown = TimelineDetail.resolve(session: run.timelineDetail, global: workspaceSettings.timelineDetail)
        ForEach(TimelineDetail.allCases) { detail in
            DropdownRow(symbol: detail.symbol, title: tr(detail.titleKey), chosen: detail == shown) {
                workspace.setTimelineDetail(runID, detail == workspaceSettings.timelineDetail ? nil : detail)
            }
        }
        DropdownDivider()
        // Kept local: copy it, or save it where you want.
        DropdownRow(symbol: "doc.on.doc", title: tr("ws.export.copy")) {
            Pasteboard.copy(SessionExport.markdown(run, events: workspace.timeline(runID)))
        }
        DropdownRow(symbol: "square.and.arrow.down", title: tr("ws.export.save")) { saveMarkdown(run) }
        if !run.isRemote {
            DropdownRow(symbol: "folder", title: tr("button.openFolder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: run.workingDirectory, isDirectory: true))
            }
        }
        if run.repoRoot != nil {
            DropdownRow(symbol: "plusminus", title: tr("agents.run.changes")) {
                if headerAccessory != nil { app.viewModel.sessionTool = .changes } else { app.viewModel.open(.changes(runID, file: nil)) }
            }
        }
        DropdownDivider()
        DropdownRow(symbol: "archivebox", title: tr("agents.run.archive"), disabledReason: busy) {
            workspace.setArchived(runID, true)
            app.viewModel.selectedAgentID = ""
        }
        DropdownRow(symbol: "trash", title: tr("agents.run.delete"), tint: NookTheme.coral, disabledReason: busy) {
            confirmDelete = true
        }
    }

    /// The session's machine when it logs in with a password that was not typed in this run of Nook yet.
    private func lockedMachine(_ run: WorkspaceRun) -> RemoteMachine? {
        _ = unlockedAt
        guard let remote = run.remote,
              let machine = RemoteMachines.load().first(where: { $0.id == remote.machineID }),
              !RemotePasswords.shared.isUnlocked(machine) else { return nil }
        return machine
    }

    /// A terminal on the session's machine, in its folder (ssh -t, then your login shell there).
    private func openRemoteTerminal(_ remote: RemoteTarget) {
        var parts = ["ssh", "-t"]
        parts += RemoteLaunch.destination(port: remote.port, identityFile: remote.identityFile)
        let inner = "cd " + RemoteLaunch.quotedDirectory(remote.directory) + #" && exec "${SHELL:-/bin/sh}" -l"#
        parts += ["--", remote.host, inner]
        let command = parts.map(CustomAgents.quote).joined(separator: " ")
        _ = TerminalStore.shared.open(in: NSHomeDirectory(), command: command, title: remote.name)
        app.viewModel.selectedAgentID = AgentsPage.terminals
    }

    private func saveMarkdown(_ run: WorkspaceRun) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SessionExport.fileName(run)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        try? SessionExport.markdown(run, events: workspace.timeline(runID)).write(to: url, atomically: true, encoding: .utf8)
    }

    private func takeFromSidePanel() {
        guard let delivery = ComposerInbox.shared.take(run: runID, directory: workspace.run(runID)?.workingDirectory ?? "") else { return }
        draft = delivery.merged(into: draft)
        composerState.images += delivery.images
        focused = true
    }

    private func addTerminalOutput(_ run: WorkspaceRun) {
        guard let terminal = TerminalStore.shared.sessions(in: run.workingDirectory).last else { return }
        let output = terminal.output(lines: 80).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        draft = "<terminal_context title=\"\(terminal.title)\">\n\(output)\n</terminal_context>\n\n" + draft
        focused = true
    }

    /// The session's open GitHub pull request or GitLab merge request, from the git button or the pull request list.
    private func watchablePullRequest() -> URL? {
        if let url = workspace.openPullRequests[runID], PullRequestWatch.canWatch(url) { return url }
        if let synced = PullRequestSync.shared.links[runID]?
            .first(where: { ($0.state == .open || $0.state == .draft) && ($0.host == .github || $0.host == .gitlab) })
            .flatMap({ URL(string: $0.url) }) { return synced }
        // The one the agent just made, before the sync has found it.
        return derived.createdPullRequest.flatMap { PullRequestWatch.canWatch($0) ? $0 : nil }
    }

    private func saveQueuedEdit() {
        guard editingQueued != nil else { return }
        let restored = workspace.endEditQueued(runID, save: true, text: draft)
        editingQueued = nil
        draft = restored ?? ""
    }

    private func cancelQueuedEdit() {
        guard editingQueued != nil else { return }
        let restored = workspace.endEditQueued(runID, save: false)
        editingQueued = nil
        draft = restored ?? ""
    }

    /// A file you add to the message: a tile above the box and a reference the agent reads itself.
    private func attachFile(_ run: WorkspaceRun) {
        guard let ref = ComposerFilePicker.pick(startingIn: run.workingDirectory) else { return }
        draft = ComposerAttachments.appending(ref, to: draft)
        focused = true
    }

    /// What this composer offers beyond typing: the commands, files and sessions to point at. The box keeps Nook's own
    /// quiet tint for every agent: an agent's color stays in its logo.
    private func composerConfig(_ run: WorkspaceRun) -> ComposerConfig {
        var config = ComposerConfig()
        config.fileRoot = run.workingDirectory
        config.repository = repository
        config.sessions = { [workspace, runID] in
            workspace.runs.filter { $0.id != runID && !$0.archived }.map { ($0.id.uuidString.lowercased(), $0.title) }
        }
        // `@opus`: a model of any connected agent, named for a subagent or a delegated task (`ModelMention`).
        config.models = { [workspace, app] in
            ModelMention.candidates(app.connectedProviders) { provider in
                workspace.modelMenu(for: provider).choices.filter { !$0.isLegacy && $0.requiredVersion == nil }
                    .map { (id: $0.id, name: $0.name) }
            }
        }
        // Only the commands this agent really has (see AgentCommands).
        config.commands = AgentCommands.commands(for: run.provider, hasProject: true, surface: .agent,
                                                 offered: workspace.acpCommands[runID] ?? [])
        config.skills = skills
        config.pullRequests = { repo in await GitHubPullRequests.openPullRequests(repo: repo) }
        config.keepsBigPastes = true
        // A pasted secret goes to this session's private files; a session on another machine could not read them.
        config.secretScope = run.remote == nil ? run.id.uuidString : nil
        config.onCommand = { [workspace, app, runID] command in
            switch command.action {
            case .plan: workspace.configure(runID, mode: .plan)
            case .fork:
                if let id = workspace.fork(runID) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            //: the next message starts the new conversation, also while a turn runs; the strip above the
            // box takes it back.
            case .clear: workspace.armFreshConversation(runID)
            case .insert, .compact, .new: break
            }
        }
        return config
    }

    /// A file dropped on the session's row: a reference in the draft, relative to the session's folder when it is inside it.
    private func attachDropped(_ url: URL, root: String) {
        let path = url.standardizedFileURL.path
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let id = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        draft = ComposerAttachments.appending(ContextRef(kind: .file, id: id, label: url.lastPathComponent), to: draft)
    }

    /// The draft you left in this session, the drafts set aside, and the agent's skills.
    private func loadComposerState(_ run: WorkspaceRun) {
        let store = ComposerDraftStore.shared
        if composerState.session != runID.uuidString { composerState.show(session: runID.uuidString) }
        composerModel.stash = store.stash
        // ArrowUp walks through what you sent this session, also after a relaunch.
        composerModel.history.seed(workspace.timeline(runID).filter { $0.kind == .user }.map { ContextRefs.visible($0.text) })
        composerModel.onStashChanged = { [composerModel] in store.setStash(composerModel.stash) }
        let (working, project) = (run.workingDirectory, run.projectPath)
        Task {
            skills = await Task.detached(priority: .utility) {
                let folder = SkillIndex.projectFolder(workingDirectory: working, projectPath: project)
                return SkillIndex.scan(roots: SkillIndex.defaultRoots(home: FileManager.default.homeDirectoryForCurrentUser, project: folder))
            }.value
        }
    }

    /// The reasoning effort for the next turns, only for agents that have it. ⇧⌘E opens it (`effortPicker.toggle`).
    @ViewBuilder
    private func effortMenu(_ run: WorkspaceRun) -> some View {
        let levels = workspace.effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        if let family = app.modelFamily(run.model, for: run.provider, profileID: run.profileID) {
            // An agent that lists one model per thinking level: the level picks the model of that family.
            let familyLevels = family.members.map(\.level)
            ComposerDivider()
            ComposerDropdown(width: 220, command: "effortPicker.toggle") {
                let current = family.members.first { $0.id == run.model }?.level ?? ""
                ComposerPill(symbol: "gauge.with.dots.needle.33percent", text: tr(EffortLevels.label(variant: current)))
            } content: {
                DropdownHeader(title: tr("compose.effort"))
                ForEach(family.members, id: \.self) { member in
                    DropdownRow(symbol: member.level.isEmpty ? "circle.dashed" : EffortSymbol.symbol(member.level, in: familyLevels),
                                title: tr(EffortLevels.label(variant: member.level)), chosen: member.id == run.model) {
                        _ = workspace.applySelection(runID, provider: run.provider, profileID: run.profileID, model: member.id)
                    }
                }
            }
            .help(tr("compose.effort.help"))
        } else if !levels.isEmpty {
            ComposerDivider()
            ComposerDropdown(width: 220, command: "effortPicker.toggle") {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent",
                             text: workspace.effortTitle(run.effort, for: run.provider, profileID: run.profileID))
            } content: {
                DropdownHeader(title: tr("compose.effort"))
                DropdownRow(symbol: "circle.dashed", title: tr(EffortLevels.label(nil)), chosen: run.effort == nil) {
                    workspace.setEffort(runID, nil)
                }
                ForEach(levels, id: \.self) { level in
                    DropdownRow(symbol: EffortSymbol.symbol(level, in: levels),
                                title: workspace.effortTitle(level, for: run.provider, profileID: run.profileID),
                                chosen: run.effort == level) {
                        workspace.setEffort(runID, level)
                    }
                }
            }
            .help(tr("compose.effort.help"))
        }
    }

    /// `effort.increase` / `effort.decrease`: one level up or down without opening the picker (`EffortStep`); for an
    /// agent that lists one model per level, the next model of that family. False when the agent has no levels.
    private func stepEffort(_ direction: EffortStep.Direction) -> Bool {
        guard let run = workspace.run(runID) else { return false }
        if let family = app.modelFamily(run.model, for: run.provider, profileID: run.profileID) {
            let ids = family.members.map(\.id)
            guard let index = ids.firstIndex(of: run.model) else { return false }
            let next = direction == .up ? min(index + 1, ids.count - 1) : max(index - 1, 0)
            if next != index { _ = workspace.applySelection(runID, provider: run.provider, profileID: run.profileID, model: ids[next]) }
            return true
        }
        let levels = workspace.effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        guard !levels.isEmpty else { return false }
        workspace.setEffort(runID, EffortStep.next(current: run.effort, levels: levels, direction: direction))
        return true
    }

    /// The context ring once the window starts to fill (the microphone is the composer's own, `dictating()`).
    @ViewBuilder
    private func composerTrailing(_ run: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if let window = run.usage.contextWindow, let used = run.usage.contextTokens, window > 0,
               ContextMeter.worthShowing(Double(used) / Double(window)) {
                // Every agent that compacts on `/compact` (Claude Code, Codex, an ACP agent that offers it) gets the button.
                let compacts = AgentCommands.canCompact(run.provider, offered: workspace.acpCommands[runID] ?? [])
                ComposerContextRing(used: used, window: window,
                                    onCompact: run.status.isActive || !compacts ? nil : { workspace.send(runID, text: "/compact") })
            }
        }
    }

    // MARK: Turn diffs

    /// The finished turns that changed files, with the files and lines git counted where it did.
    private func turnDiffs(_ run: WorkspaceRun) -> [TurnDiff] {
        derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run)).turns
            .map { counted($0, run: run) }
            .filter { !$0.isEmpty }
    }

    /// The turn with what git counted for it, when it did.
    private func counted(_ turn: TurnDiff, run: WorkspaceRun) -> TurnDiff {
        countedLines[turn.id].map { turn.counted($0, relativeTo: run.workingDirectory) } ?? turn
    }

    /// Counts the finished turns with git, between the snapshots around them; a turn counted between both of its
    /// snapshots stays as it is, the others are counted again once their snapshot is made.
    private func countTurns(_ turns: [TurnDiff], run: WorkspaceRun) async {
        guard !run.isRemote else { return }
        for turn in turns where countedLines[turn.id]?.complete != true {
            guard let start = turn.start, let end = turn.end else { continue }
            if let lines = try? await workspace.turnLines(runID, paths: turn.files.map(\.path), start: start, end: end) {
                guard !Task.isCancelled else { return }
                countedLines[turn.id] = lines
            }
        }
    }

    // MARK: Timeline

    /// What sits under the timeline: an approval, a confirmation, the agent's question, or the composer.
    @ViewBuilder
    private func bottomBar(_ run: WorkspaceRun) -> some View {
        if let target = revertTarget {
            revertConfirmation(target)
        } else if let target = editTarget {
            editConfirmation(target)
        } else if confirmDelete {
            deleteConfirmation(run)
        } else if let pending = workspace.approvals[runID], let first = pending.first {
            // What the agent waits for takes the composer's place until answered, in every kind of session.
            approval(run, first, more: pending.count - 1).chatColumn().sessionComposerBounds()
        } else if let request = bridge.pending.first(where: { $0.caller.kind == .run(runID) }) {
            // A command or pull request the agent asks for through Nook's workspace.
            let approval = ApprovalCenter.make(request)
            ApprovalView(approval: approval, inline: true, onDecide: { app.approvals.decide(approval, $0) },
                         onSecret: { app.approvals.allow(approval, secret: $0) })
                .chatColumn()
                .sessionComposerBounds()
        } else if let question = workspace.questions[runID]?.first {
            // The agent asks something: its question takes the composer's place until answered (Stop stays).
            RunQuestionPanel(question: question, agent: run.provider.displayName, folder: run.workingDirectory,
                             onStop: { workspace.stop(runID) }) { answers in
                workspace.answer(runID, questionID: question.id, answers: answers)
            }
            .id(question.id)
            .chatColumn()
            .sessionComposerBounds()
        } else {
            // Redrawn on its own with every keystroke, without the conversation above it; and not for every streamed
            // token, which redraws the conversation (`timelines`) but changes nothing the composer shows.
            RunComposerHost(state: composerState, workspace: workspace, app: app, pullRequests: pullRequestSync,
                            key: RunComposerHost.Key(run: run, subagents: derived.subagents, commands: derived.commands, skills: skills,
                                                     repository: repository, shownSubagents: outputsLink.subagentsShown)) {
                composer(run)
            }
            .equatable()
            .chatColumn()
        }
    }

    private func timeline(_ run: WorkspaceRun) -> some View {
        let memo = derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run))
        let events = memo.events
        let blocks = memo.blocks
        let cards = memo.cards
        let found = finding ? memo.search(findQuery) : .idle
        let current = findIndex.flatMap { found.matches.indices.contains($0) ? found.matches[$0].eventID : nil } ?? flashed
        // While the agent works, as in an agent's own transcript: "Working for …" right under your message, and the step
        // that runs now only in the live line at the end, not also in the list above it.
        let active = run.status.isActive
        let workingUnder = active ? events.last(where: { $0.kind == .user })?.id : nil
        // A compaction that runs is the live line too ("Compacting the conversation…"); once done it is a row of its own.
        let liveStep = active ? events.last.flatMap {
            ($0.kind == .tool && $0.state == .running) || CompactionProgress.isRunning($0) ? $0.id : nil
        } : nil
        // Only the latest turns of a long session are drawn, from the turn the window starts at.
        let start = HistoryWindow.clamped(historyStart ?? HistoryWindow.initialStart(rowsPerTurn: memo.rowsPerTurn),
                                          turnCount: memo.rowsPerTurn.count)
        let firstRow = min(blocks.count, HistoryWindow.firstRow(rowsPerTurn: memo.rowsPerTurn, start: start))
        let shownBlocks = firstRow > 0 ? Array(blocks[firstRow...]) : blocks
        let context = TimelineRowContext(structure: memo.revision, status: run.status,
                                         directory: run.isRemote ? nil : run.workingDirectory, highlighted: current,
                                         openEvents: expanded, shownFile: sideLink.shownFile, counted: countedLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    if events.isEmpty {
                        // Still being read from disk is not an empty conversation.
                        if workspace.isTimelineLoaded(runID) {
                            ListEmptyNote(tr("agents.run.empty"))
                        } else {
                            PatientSpinner().frame(height: 160)
                        }
                    }
                    if firstRow > 0 {
                        TimelineEarlierRow {
                            // What you looked at stays where it is: the earlier turns go above it.
                            let anchor = shownBlocks.first?.id
                            scroll.userScrolled()
                            historyStart = HistoryWindow.earlier(from: start)
                            if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
                        }
                    }
                    // Finished turns fold to "Worked for …", tool calls in a row to one sentence.
                    ForEach(shownBlocks) { block in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                            if block.id == newSince { TimelineNewDivider() }
                            TimelineBlockView(block: block, expanded: openBlocks, context: context.scoped(to: block), toggle: toggleBlock) { event in
                                if event.id == liveStep { return AnyView(EmptyView()) }
                                return AnyView(
                                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                                        // What the turn changed (its card): under the final answer, inside it, as in an
                                        // agent's own transcript; a file or Open diff opens the diff beside it.
                                        // A turn that changed files only by a command still gets one, once git counted it.
                                        let card = cards[event.id].map { counted($0, run: run) }.flatMap { turn in
                                            turn.isEmpty ? nil : AnyView(TurnChangesCard(turn: turn, directory: run.workingDirectory) { file in
                                                sideLink.openDiff(TurnDiffSelection(turn: turn.id, file: file))
                                            })
                                        }
                                        let inReply = event.kind == .assistant && memo.finalAnswers.contains(event.id)
                                        eventRow(event, final: memo.finalAnswers.contains(event.id),
                                                 extras: inReply ? card : nil, answerable: memo.answerable == event.id)
                                        if !inReply, let card { card }
                                        if event.id == workingUnder { TranscriptWorkingLine(since: run.turnStartedAt) }
                                    }
                                    .padding(.vertical, current == event.id ? 4 : 0)
                                    .roundedBackground(NookTheme.iris.opacity(current == event.id ? 0.16 : 0), radius: NookTheme.Radius.control)
                                )
                            }
                            // While the agent writes, only the block it writes into is drawn again.
                            .equatable()
                        }
                        .pinProbe(block.id.uuidString, room: pinRoom)
                        .id(block.id)
                    }
                    if active {
                        // The agent's task list, live, right above what it does now: the same live line as in an agent's
                        // own transcript.
                        let turn = TimelinePresentation.lastTurn(events)
                        TranscriptLiveLine(activity: AgentActivity.current(turn),
                                           tasks: TaskChecklist.showsInline(run.tasks, active: true) ? run.tasks : nil,
                                           waiting: run.status == .waitingApproval || workspace.questions[runID] != nil,
                                           asking: workspace.questions[runID] != nil,
                                           openConsole: CommandConsole.running(turn).map { command -> () -> Void in
                                               { sideLink.toggleConsole(command.id) }
                                           },
                                           help: TimelinePresentation.live(turn).tool)
                    }
                    if run.status == .failed || run.status == .stopped {
                        recovery(run, events: events, blocks: blocks, proxy: proxy)
                    }
                    TurnPinSpacer(room: pinRoom)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                // The conversation's own space, so the room under a message you sent is measured between rows.
                .coordinateSpace(name: TurnPinRoom.space)
                .chatColumn()
            }
            // The files and lines of every finished turn from git (`countTurns`): again when a turn ends or a snapshot is made.
            .task(id: "\(runID)|\(memo.turns.count)|\(memo.turns.last?.files.count ?? 0)|\(run.checkpoints?.count ?? 0)") {
                await countTurns(memo.turns, run: run)
            }
            // Following the end while the answer streams: the scroll view keeps its bottom in place as the content grows,
            // instead of a `scrollTo` (a layout down to the end and a scroll) for every streamed update.
            // A session opens at its end, also when its timeline arrives after the first frame: never at its first messages.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor((run.status.isActive || landsOnLoad) && scroll.shouldFollowEnd ? .bottom : nil, for: .sizeChanges)
            .scrollIndicators(.never)
            // A mark per message of yours on the leading edge, as in an agent's own transcript: a click jumps to it.
            .overlay(alignment: .leading) {
                if overflows, !finding, !memo.marks.isEmpty {
                    TranscriptPromptRail(marks: memo.marks) { mark in
                        scroll.userScrolled()
                        guard let id = UUID(uuidString: mark.row) else { return }
                        if revealTurn(of: id) {
                            DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .top) } }
                        } else {
                            withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    .padding(.vertical, NookTheme.Spacing.md)
                    .transition(.opacity)
                }
            }
            // The conversation scrolls on behind the composer; the pill back to the end rides on top of it.
            .composerInset {
                VStack(spacing: NookTheme.Spacing.lg) { bottomBar(run) }
                    .toEndPill(scroll.showsToEndPill(atEnd: atEnd) && !finding) {
                        scroll.jumpedToEnd()
                        withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
            }
            .padding(.top, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Scrolling away from the end stops the following until you come back.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, nowAtEnd in
                atEnd = nowAtEnd
                if nowAtEnd { scroll.reachedEnd() }
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase.value = phase
                if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
            }
            .onScrollGeometryChange(for: ScrollFrame.self) { geometry in
                ScrollFrame(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                            container: geometry.containerSize.height,
                            insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
            } action: { old, frame in
                pinRoom.update(frame)
                keepEnd(old, frame, proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, now in
                overflows = now
            }
            // Never a black conversation: at rest with none of its blocks in view, back to the one you last saw (or the end).
            .recoversBlankRows(UUID.self, rows: shownBlocks.count, idle: { scrollPhase.value == .idle }) { last in
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if let last, !scroll.shouldFollowEnd, !atEnd {
                        proxy.scrollTo(last, anchor: .top)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .top) {
                if finding {
                    TimelineFindBar(query: $findQuery, result: found, current: findIndex,
                                    previous: { stepFind(found, blocks: blocks, proxy: proxy, forward: false) },
                                    next: { stepFind(found, blocks: blocks, proxy: proxy, forward: true) },
                                    close: closeFind)
                        .padding(.horizontal, NookTheme.Spacing.xs)
                        .padding(.top, NookTheme.Spacing.xs)
                }
            }
            .keyCommand("chat.find") { openFind() }
            // From a background command's row in the bar: to its call in the conversation, lit up for a moment.
            .onChange(of: conversationFocus) { _, id in
                guard let id else { return }
                conversationFocus = nil
                scroll.userScrolled()
                revealTurn(of: id)
                for key in TimelineContainers.keys(blocks)[id] ?? [] { openBlocks.insert(key) }
                flashed = id
                DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if flashed == id { withAnimation(NookTheme.reveal) { flashed = nil } }
                }
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = nil
                let fresh = TimelineSearch.search(events, query: findQuery)
                if let first = fresh.next(after: nil) { findIndex = first; reveal(fresh, at: first, blocks: blocks, proxy: proxy) }
            }
            // Always the end, with what is new since your last visit under its line;
            // after the handlers that follow the end on a new session, hence on the next turn of the run loop.
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                DispatchQueue.main.async { land(proxy) }
            }
            .onChange(of: runID) { _, _ in
                historyStart = nil
                DispatchQueue.main.async { land(proxy) }
            }
            .onChange(of: workspace.isTimelineLoaded(runID)) { _, loaded in
                if loaded, landsOnLoad { DispatchQueue.main.async { land(proxy) } }
            }
            // Opened from a search hit: find what it matched.
            .onReceive(app.viewModel.$sessionFind) { wanted in
                guard let wanted, !wanted.isEmpty else { return }
                app.viewModel.sessionFind = nil
                openFind()
                findQuery = wanted
            }
            .onChange(of: events.count) { _, _ in
                // The agent went on to its tools and the reply filled the view: follow its work from here.
                scroll.contentGrew(toolActivityStarted: events.last?.kind == .tool, overflows: pinRoom.height == 0)
                // Not animated, and only when the view is off its end: at the end `defaultScrollAnchor` and `keepEnd`
                // already hold it there, and an animated scroll on every new event fought them.
                guard scroll.shouldFollowEnd, !atEnd else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You sent something: it is the newest thing and shows again, also when you had scrolled up.
            .onChange(of: sentCount) { _, _ in settleAtEnd(proxy) }
            .onChange(of: scroll.anchorMessageID) { _, id in if id == nil { pinRoom.release() } }
            .onChange(of: events.last(where: { $0.kind == .user })?.id) { old, new in
                // A message that came in at the end stands near the top with the reply under it. The timeline loading
                // or going back to an earlier message only lands at the end.
                if old != nil, let new, !finding, events.suffix(2).contains(where: { $0.id == new }), let row = memo.marks.last?.row,
                   let id = UUID(uuidString: row) {
                    pinSent(id, proxy)
                } else {
                    settleAtEnd(proxy)
                }
            }
        }
    }

    /// Brings the message you sent near the top of the view, with room under it for the reply, until you scroll away.
    /// The room follows once the message is laid out; the view only goes to its end, again while the layout settles.
    private func pinSent(_ id: UUID, _ proxy: ScrollViewProxy) {
        pinRoom.hold(row: id.uuidString)
        scroll.sent(messageID: id)
        for delay in [0.0, 0.1, 0.25, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard scroll.anchorMessageID == id else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Scrolls to the end now and again while the layout settles: the lazy rows only learn their real height once
    /// laid out, so a single scroll from far up lands short of the end. Stops when you scroll away in the meantime.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        scroll.jumpedToEnd()
        proxy.scrollTo("bottom", anchor: .bottom)
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Where you left it

    private static func visitKey(_ id: UUID) -> String { "run:" + id.uuidString }

    /// The timeline's blocks in order with their times, as `timeline(_:)` shows them (already made as it opens).
    private var visitRows: [TimelineLanding.Row] {
        guard let run = workspace.run(runID) else { return [] }
        return derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run)).blocks.map { ($0.id.uuidString, $0.visitDate) }
    }

    /// The very end of the session, with what came in since your last visit under its line.
    private func land(_ proxy: ScrollViewProxy) {
        landsOnLoad = !workspace.isTimelineLoaded(runID)
        guard !landsOnLoad else { return }
        // The window opens on the latest turns and stays there as new ones come in.
        if historyStart == nil, !derived.rowsPerTurn.isEmpty {
            historyStart = HistoryWindow.initialStart(rowsPerTurn: derived.rowsPerTurn)
        }
        newSince = visit.flatMap { TimelineLanding.firstNew(visitRows, since: $0.lastViewedAt) }.flatMap(UUID.init(uuidString:))
        settleAtEnd(proxy)
    }

    /// Keeps the run at its end while it is there, as `TranscriptConversation.keepEnd` does: the lazy blocks below
    /// measure taller after the first scroll and the composer under it grows (a card, a draft), which let the run slip
    /// up from its end as it opens. A landing on what is new that fits on screen ends at the end too, and follows from
    /// there. Only moving while the sizes stay the same is you scrolling away.
    private func keepEnd(_ old: ScrollFrame, _ new: ScrollFrame, _ proxy: ScrollViewProxy) {
        let resized = new.content != old.content || new.container != old.container || new.insetBottom != old.insetBottom
        guard resized, !finding, scroll.mode != .anchoringNewTurn else { return }
        let wasAtEnd = old.maxOffset - old.offset <= 1
        guard scroll.shouldFollowEnd || wasAtEnd, scrollPhase.value == .idle, new.maxOffset - new.offset > 0.5 else { return }
        scroll.reachedEnd()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Where you leave a session: what you opened and when.
    private func rememberVisit(_ id: UUID) {
        // Left before its timeline was read: the earlier visit still says where you were.
        guard workspace.run(id) != nil, workspace.isTimelineLoaded(id) else { return }
        TimelineVisitStore.shared.remember(sessionID: Self.visitKey(id), visit: TimelineVisit(open: openBlocks, lastViewedAt: Date()))
    }

    // MARK: Quotes

    /// Picks a passage of an answer for the next message; `ask` also puts the keyboard in the box to ask about it.
    private func addQuote(_ text: String, ask: Bool) {
        // Where it was taken from, so the chip can go back there: the newest answer that holds these words.
        let entries = workspace.timeline(runID).filter { $0.kind == .assistant }.map { (id: $0.id, text: $0.text) }
        switch quotes.add(text, source: ComposerQuotes.source(of: text, in: entries)) {
        case .tooLong: ToastCenter.shared.warning(tr("ws.review.quoteTooLong"))
        case .full: ToastCenter.shared.warning(tr("compose.quote.full"))
        case .empty: break
        case nil: if ask { focused = true }
        }
    }

    /// Back to where a quote was taken from in the conversation, lit up for a moment; a note when it is gone.
    private func jumpToQuote(_ quote: ComposerQuotes.Quote) {
        guard let source = quote.source, workspace.timeline(runID).contains(where: { $0.id == source }) else {
            ToastCenter.shared.warning(tr("compose.quote.gone"))
            return
        }
        conversationFocus = source
    }

    /// ⇧⌘L / ⌘L on words selected in an answer; false (the key goes on) when nothing is selected there.
    private func quoteSelected(ask: Bool) -> Bool {
        guard let text = SelectableProse.selection(in: NSApp.keyWindow) else { return false }
        addQuote(text, ask: ask)
        return true
    }

    /// Sends the first queued message now; false (the key goes on) when nothing waits or it cannot go in yet.
    private func steerFirstQueued() -> Bool {
        guard let first = workspace.queued[runID]?.messages.first, workspace.canSendQueuedNow(runID) else { return false }
        workspace.sendQueuedNow(runID, message: first.id)
        return true
    }

    /// Widens the window (`HistoryWindow`) to hold the turn of an event it leaves out; true when it had to.
    @discardableResult
    private func revealTurn(of eventID: UUID) -> Bool {
        guard let turn = derived.turn(of: eventID) else { return false }
        let start = historyStart ?? HistoryWindow.initialStart(rowsPerTurn: derived.rowsPerTurn)
        let widened = HistoryWindow.revealing(turn, from: start)
        guard widened < start else { return false }
        historyStart = widened
        return true
    }

    // MARK: Find

    private func openFind() {
        finding = true
        scroll.findStarted()
    }

    private func closeFind() {
        finding = false
        findQuery = ""
        findIndex = nil
        scroll.findEnded()
    }

    private func stepFind(_ found: TimelineSearchResult, blocks: [TimelineBlock], proxy: ScrollViewProxy, forward: Bool) {
        guard let target = forward ? found.next(after: findIndex) : found.previous(before: findIndex) else { return }
        findIndex = target
        reveal(found, at: target, blocks: blocks, proxy: proxy)
    }

    /// Opens the groups around the match, then scrolls to it.
    private func reveal(_ found: TimelineSearchResult, at index: Int, blocks: [TimelineBlock], proxy: ScrollViewProxy) {
        guard found.matches.indices.contains(index) else { return }
        let id = found.matches[index].eventID
        // Find searches the whole session: a match in a turn the window leaves out widens it.
        revealTurn(of: id)
        for key in TimelineContainers.keys(blocks)[id] ?? [] { openBlocks.insert(key) }
        DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
    }

    private func recovery(_ run: WorkspaceRun, events: [RunEvent], blocks: [TimelineBlock], proxy: ScrollViewProxy) -> some View {
        AdaptiveActionRow(spacing: 10) {
            HStack(spacing: 10) {
                Image(icon: run.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                    .foregroundStyle(run.status.color)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(run.status == .failed ? tr("ws.recovery.failed") : tr("ws.recovery.stopped"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(run.statusDetail.flatMap { $0 == "interrupted" ? nil : $0 } ?? (run.providerSessionID != nil ? tr("ws.recovery.canResume") : tr("ws.recovery.noResume")))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            if let failure = FailureJump.firstFailure(in: events) {
                NookGhostButton(title: tr("timeline.goToFailure")) {
                    scroll.userScrolled()
                    revealTurn(of: failure)
                    for key in TimelineContainers.keys(blocks)[failure] ?? [] { openBlocks.insert(key) }
                    DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(failure, anchor: .center) } }
                }
            }
            NookGhostButton(title: tr("ws.action.retry")) { workspace.retry(runID) }
            // The login ran out: sign in again in the browser, and the turn runs again once you are back.
            if run.status == .failed, AgentSignInFailure.needsSignIn(run.statusDetail),
               AgentSignInFailure.canSignInAgain(run.provider) {
                let profile = app.profiles.profile(id: run.profileID) ?? .defaultProfile(run.provider.kind)
                let signingIn = app.agentConnect[profile.id]?.isBusy == true
                NookPrimaryButton(title: signingIn ? tr("accounts.reauthWaiting") : tr("accounts.reauth"),
                                  symbol: "person.badge.key") {
                    app.reauthenticate(profile) { workspace.retry(runID) }
                }
                .disabled(signingIn)
            }
        }
        .padding(10)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.card)
    }

    @ViewBuilder
    private func eventRow(_ event: RunEvent, final: Bool = true, extras: AnyView? = nil, answerable: Bool = false) -> some View {
        if event.kind == .assistant, event.tool == "plan" {
            let idle = !(workspace.run(runID)?.status.isActive ?? false)
            // Only the latest plan, and only until you sent something after it.
            let timeline = workspace.timeline(runID)
            let latest = timeline.last { $0.kind == .assistant && $0.tool == "plan" }?.id == event.id
            let answered = timeline.contains { $0.kind == .user && $0.date > event.date }
            PlanCard(text: event.text, canAct: idle && latest && !answered, implementInNew: {
                // The summary of a fork cuts long messages, so the whole plan goes into the first message.
                guard let id = workspace.fork(runID) else { return }
                workspace.configure(id, mode: .agent)
                workspace.send(id, text: tr("ws.plan.implementPrompt") + "\n\n" + event.text)
                app.viewModel.selectedAgentID = "run:" + id.uuidString
            }) {
                workspace.configure(runID, mode: .agent)
                workspace.send(runID, text: tr("ws.plan.implementPrompt"))
            }
        } else if event.kind == .user {
            eventView(event, onEdit: workspace.canEditFromHere(runID, before: event.date) ? {
                editError = nil
                revertTarget = nil
                editTarget = event
            } : nil)
                .contextMenu {
                    // "Edit from here": the worktree's files go back to how they were before this message.
                    Button(tr("ws.revert.menu")) {
                        revertError = nil
                        revertTarget = event
                    }
                    .disabled(!workspace.canRevert(runID, before: event.date))
                    // A fork that starts before this message, to try another way.
                    Button(tr("agents.fork.here")) { forkBefore(event) }
                        .disabled(!workspace.canTransfer(runID))
                }
        } else if event.kind == .assistant {
            eventView(event, final: final, extras: extras, answerable: answerable)
                .contextMenu {
                    // "Fork from this response".
                    Button(tr("agents.fork.fromResponse")) { forkThrough(event) }
                        .disabled(!workspace.canTransfer(runID))
                    // Quote the agent's words in your next message.
                    Button(tr("ws.review.quote")) {
                        draft = ReviewComments.quote(event.text, into: draft)
                        focused = true
                    }
                }
        } else {
            eventView(event)
        }
    }

    private func forkBefore(_ event: RunEvent) {
        guard let index = workspace.timeline(runID).firstIndex(where: { $0.id == event.id }),
              let id = workspace.fork(runID, keepingEvents: index) else { return }
        app.viewModel.selectedAgentID = "run:" + id.uuidString
    }

    private func forkThrough(_ event: RunEvent) {
        guard let index = workspace.timeline(runID).firstIndex(where: { $0.id == event.id }),
              let id = workspace.fork(runID, keepingEvents: index + 1) else { return }
        app.viewModel.selectedAgentID = "run:" + id.uuidString
    }

    private func revertConfirmation(_ target: RunEvent) -> some View {
        AdaptiveActionRow(spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("ws.revert.confirm"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(revertError ?? tr(workspace.canRollbackConversation(runID) ? "ws.revert.detailConversation" : "ws.revert.detail",
                                       ToolSummary.oneLine(target.text, 60)))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(revertError == nil ? NookTheme.textSecondary : NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            NookGhostButton(title: tr("button.cancel")) { revertTarget = nil }
            NookPrimaryButton(title: reverting ? tr("ws.revert.working") : tr("ws.revert.action")) {
                guard !reverting else { return }
                reverting = true
                Task {
                    do {
                        try await workspace.revertFiles(runID, before: target.date)
                        revertTarget = nil
                    } catch {
                        revertError = error.localizedDescription
                    }
                    reverting = false
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
    }

    /// "Edit from here": go back to before the message, keeping the files as they are or putting them back too (only
    /// where they can go back, see `canRevert`), then the message and its pictures are in the composer again.
    private func editConfirmation(_ target: RunEvent) -> some View {
        let canRevertFiles = workspace.canRevert(runID, before: target.date)
        return AdaptiveActionRow(spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("ws.edit.confirm"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(editError ?? tr(canRevertFiles ? "ws.edit.detail" : "ws.edit.detailKeepOnly", ToolSummary.oneLine(target.text, 60)))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(editError == nil ? NookTheme.textSecondary : NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            NookGhostButton(title: tr("button.cancel")) { editTarget = nil }
            NookGhostButton(title: tr("ws.edit.keepFiles")) { editFromHere(target, revertingFiles: false) }
            if canRevertFiles {
                NookPrimaryButton(title: editWorking ? tr("ws.revert.working") : tr("ws.edit.revertFiles")) {
                    editFromHere(target, revertingFiles: true)
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
    }

    private func editFromHere(_ target: RunEvent, revertingFiles: Bool) {
        guard !editWorking else { return }
        editWorking = true
        Task {
            do {
                try await workspace.editFromHere(runID, before: target.date, revertingFiles: revertingFiles)
                editTarget = nil
                // The message goes back into the composer: its words, and the pictures, files and folders that went as
                // paths in it.
                let parts = ImageAttachment.splittingAttachments(from: target.text)
                draft = parts.files.reduce(parts.text) { text, url in
                    ComposerAttachments.appending(ContextRef(kind: .file, id: url.path, label: url.lastPathComponent), to: text)
                }
                images = parts.images.compactMap(ImageAttachment.init(url:))
                focused = true
            } catch {
                editError = error.localizedDescription
            }
            editWorking = false
        }
    }

    private func eventView(_ event: RunEvent, final: Bool = true, extras: AnyView? = nil, answerable: Bool = false,
                           onEdit: (() -> Void)? = nil) -> some View {
        EventRow(
            event: event,
            final: final,
            extras: extras,
            // A question at the end of the newest answer, answered with a click, as in an agent's own transcript.
            onChoose: answerable ? { workspace.send(runID, text: $0) } : nil,
            expanded: expanded.contains(event.id),
            toggle: { toggle(event.id) },
            openFile: { path in
                // In the session's Changes tab; a session on another machine has no git here, so its own review.
                if headerAccessory != nil, let run = workspace.run(runID), !run.isRemote {
                    sideLink.openDiff(TurnDiffSelection(turn: TurnDiffSelection.branch,
                                                        file: TurnDiff.relative(path, to: run.workingDirectory)))
                } else {
                    app.viewModel.open(.changes(runID, file: path))
                }
            },
            decide: { decision in
                if let request = event.callID { app.approvals.decide(run: runID, requestID: request, ApprovalDecision(decision)) }
            },
            showFile: sideLink.showFile,
            // A session on another machine has its files there, not on this Mac.
            directory: workspace.run(runID).flatMap { $0.isRemote ? nil : $0.workingDirectory },
            shownFile: sideLink.shownFile,
            onEdit: onEdit,
            // In the bar while it is there (this turn's commands, and any still running); else in the side panel.
            showBackground: {
                if derived.commands.contains(where: { $0.id == event.id }) { barFocus = event.id } else { outputsLink.openSubagents() }
            }
        )
        // Undone by going back to before an earlier message: the agent no longer remembers it.
        .opacity(event.rolledBack == true ? 0.45 : 1)
    }

    private func toggleBlock(_ key: String) {
        withAnimation(NookTheme.reveal) {
            if openBlocks.contains(key) { openBlocks.remove(key) } else { openBlocks.insert(key) }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Approval

    private func approval(_ run: WorkspaceRun, _ pending: PendingPermission, more: Int) -> some View {
        let request = ApprovalCenter.make(pending, run: run)
        return ApprovalView(approval: request, more: more, inline: true, onDecide: { app.approvals.decide(request, $0) },
                            onSecret: { app.approvals.allow(request, secret: $0) },
                            onDenyWithReason: { app.approvals.decide(request, .deny, reason: $0) })
    }

    /// Inline instead of a dialog: the notch is a panel, not a window that sheets can attach to.
    private func deleteConfirmation(_ run: WorkspaceRun) -> some View {
        AdaptiveActionRow(spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("agents.run.deleteConfirm", run.title))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(tr("agents.run.deleteDetail"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            NookGhostButton(title: tr("button.cancel")) { confirmDelete = false }
            // The session's own worktree, which no other session uses, can go with it. With "remove it when its last
            // session is deleted" on, Delete itself takes care of that.
            if let worktree = workspace.orphanedWorktree(runID),
               !workspace.settings.worktreeCleanupRules(for: worktree.repo).onDeletedSession {
                NookGhostButton(title: tr("agents.run.deleteWithWorktree")) {
                    confirmDelete = false
                    workspace.deleteWithWorktree(runID)
                    app.viewModel.selectedAgentID = ""
                }
                .help(AgentPathFormat.tilde(worktree.path))
            }
            NookPrimaryButton(title: tr("agents.run.delete")) {
                confirmDelete = false
                workspace.delete(runID)
                app.viewModel.selectedAgentID = ""
            }
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
    }

    // MARK: Composer

    /// `/btw` or `/side` (with a question): a side chat beside this session, which keeps working (see `SideChat`). It
    /// opens selected; the question is its first message. False for any other message.
    private func openSideChat(_ text: String) -> Bool {
        guard let question = SideChat.question(in: text), workspace.canOpenSideChat(runID) else { return false }
        draft = ""
        if let id = workspace.openSideChat(runID, question: question) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
        return true
    }

    /// The same composer a new session starts with: the agent and its model, mode and permissions for the next turn,
    /// everything else under ⋯, and send (or stop while it works).
    private func composer(_ run: WorkspaceRun) -> some View {
        let active = run.status.isActive
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Return while a queued message is open in the box saves it instead of sending.
            if editingQueued != nil { saveQueuedEdit(); return }
            if openSideChat(text) { return }
            guard composerModel.hasContent(text), !active else { return }
            let outgoing = composerModel.outgoing(text)
            draft = ""
            images = []
            let message = quotes.message(outgoing.send)
            quotes.removeAll()
            // Still finishing the last turn (or messages wait in line): this one waits too, never sent past them.
            workspace.submit(runID, text: message, fromYou: true)
            sentCount += 1
        }
        // Codex over app-server and Claude Code take a new message during the turn (steering); others get it after the turn.
        // Return does what you chose in Settings, Cmd+Return the other.
        let canSteer = active && workspace.canSteer(runID)
        let preferred: ComposerDispatch.Intent = workspace.settings.steerByDefault ? .steer : .queue
        func deliver(_ intent: ComposerDispatch.Intent, now: Bool = false) -> () -> Void {
            {
                if editingQueued != nil { saveQueuedEdit(); return }
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                // `/btw` during a turn: the side chat starts from the last finished turn and this one goes on.
                if openSideChat(text) { return }
                guard composerModel.hasContent(text) else { return }
                let outgoing = composerModel.outgoing(text)
                draft = ""
                images = []
                let message = quotes.message(outgoing.send)
                quotes.removeAll()
                sentCount += 1
                // `/clear` and the message after it: a new conversation, after this turn (never steered into it).
                if workspace.startsFreshConversation(runID, text: message) { workspace.submit(runID, text: message, fromYou: true); return }
                // ⌘Return to steer means now: when the turn cannot take it in, it is interrupted and the message goes next.
                if intent == .steer, now { workspace.sendNow(runID, text: message); return }
                if ComposerDispatch.resolve(busy: true, intent: intent, canSteer: canSteer) == .steer,
                   workspace.steer(runID, text: message) { return }
                workspace.enqueue(runID, text: message)
            }
        }
        // ⌘Return while the last turn is still finishing (or messages wait in line): this one goes out first, right away.
        let sendNow = {
            if editingQueued != nil { saveQueuedEdit(); return }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if openSideChat(text) { return }
            guard composerModel.hasContent(text), !active else { return }
            let outgoing = composerModel.outgoing(text)
            draft = ""
            images = []
            let message = quotes.message(outgoing.send)
            quotes.removeAll()
            workspace.sendNow(runID, text: message)
            sentCount += 1
        }
        let primary = ComposerDispatch.resolve(busy: true, intent: preferred, canSteer: canSteer)
        let steers = primary == .steer
        return VStack(alignment: .leading, spacing: 5) {
            UsageLimitBanner(run: run)
            ConnectorSignInBanner(runID: runID)
            // Its side chats (/btw): open one, or bring its result back here.
            let sideChats = SideChat.children(of: runID, in: workspace.runs)
            if !sideChats.isEmpty { SideChatStrip(workspace: workspace, chats: sideChats) }
            GuestStrip(id: runID, shares: GuestShares.shared)
            if let goal = run.goal {
                GoalStrip(goal: goal, canPause: workspace.takesGoalOutsideTurns(runID)) { workspace.goalControl(runID, $0) }
            }
            if workspace.freshArmed.contains(runID) {
                FreshConversationStrip { workspace.keepConversation(runID) }
            }
            // The subagents the agent started since your message (also those still at work in the background after its
            // turn), and its task list.
            let subagents = derived.subagents
            if !subagents.isEmpty {
                SubagentBar(agents: subagents) { outputsLink.openSubagents() }
            }
            // The commands it left running in the background (a dev server, a watcher): the session is not done yet.
            let commands = derived.commands
            if !commands.isEmpty {
                BackgroundCommandBar(commands: commands, focus: $barFocus,
                                     reveal: { conversationFocus = $0 }) { outputsLink.openSubagents() }
            }
            // While the agent works its list shows in the timeline; one it left unfinished waits here.
            if let tasks = run.tasks, !tasks.isEmpty, !TaskChecklist.showsInline(tasks, active: run.status.isActive) {
                TasksStrip(steps: tasks)
            }
            // The pull request it watches and the messages waiting in line sit in a tray tucked above the box, the
            // same tray a new session shows its folder and branch in under the box.
            VStack(spacing: 0) {
                aboveBox(watches: run.prWatches, waiting: workspace.queued[runID] ?? MessageQueue())
                SessionComposer(
                    text: $composerState.draft,
                    prompt: active ? (steers ? tr("agents.run.steerPrompt", run.provider.kind.shortName)
                                             : tr("agents.run.busyPrompt", run.provider.kind.shortName)) : tr("agents.run.prompt"),
                    canSend: !active,
                    busy: active,
                    onStop: { workspace.stop(runID) },
                    focus: $focused,
                    onSend: send
                ) {
                    actionsMenu(run)
                    modelMenu(run)
                    ComposerDivider()
                    modeMenu(run)
                    ComposerDivider()
                    permissionMenu(run)
                    effortMenu(run)
                    ComposerSpeedTier(tiers: workspace.speedTiers(for: run), chosen: workspace.speedTier(run)) {
                        workspace.setSpeedTier(runID, $0)
                    }
                    ComposerUsageRing.forAccount(app.profile(for: run), app: app)
                }
                .rich(composerModel, composerConfig(run))
                .trailing { composerTrailing(run) }
                .dictating()
                // While it works, what you type steers the turn or waits in line, and Cmd+Return does the other.
                .queueing(active ? deliver(preferred) : nil,
                          alternate: active ? deliver(preferred == .steer ? .queue : .steer, now: true) : nil,
                          label: steers ? tr("compose.steer") : tr("compose.queue"),
                          symbol: steers ? "arrow.turn.down.right" : "text.append")
                .sendingNow(active ? nil : sendNow)
                // The message you will likely send next, once the turn has ended (Settings › Sessions); every agent.
                .suggesting(active ? nil : workspace.nextPrompt(runID),
                            onAccept: { workspace.dismissNextPrompt(runID) },
                            onDismiss: { workspace.dismissNextPrompt(runID) })
                .images($composerState.images)
                .zIndex(1)
                // Asked for only while this composer is on screen and empty: a finished turn, once.
                .onChange(of: run.status, initial: true) { _, _ in
                    workspace.requestNextPrompt(runID, composerEmpty: composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                // Files dropped on this session's row in the list: pictures as pictures, other files as references.
                .onReceive(app.viewModel.$filesToAttach) { drop in
                    guard let drop, drop.session == runID else { return }
                    app.viewModel.filesToAttach = nil
                    for url in drop.urls {
                        ImageAttachment.take(url, images: { composerState.images += $0 }, file: { attachDropped($0, root: run.workingDirectory) })
                    }
                }
            }
            // ⇧⌘Return while it works: the first message waiting in line goes in now, as the queue's own button does.
            // ⌥⌘Return: this message goes (as Return sends it) and the box of a new session opens for the next task, while
            // this one works on in the background ("Send and start new thread").
            .keyCommands(["queue.steerFirst": { steerFirstQueued() },
                          "composer.startInBackground": {
                              guard editingQueued == nil, composerModel.hasContent(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                              else { return false }
                              if active { deliver(preferred)() } else { send() }
                              app.viewModel.selectedAgentID = "new"
                              return true
                          },
                          "effort.increase": { stepEffort(.up) }, "effort.decrease": { stepEffort(.down) }])
            if !active, run.mode == .plan {
                Text(tr("agents.run.planHint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    /// The tray above the box, when there is something to show in it.
    @ViewBuilder
    private func aboveBox(watches: [PullRequestWatch], waiting: MessageQueue) -> some View {
        // The watched pull request while it can still change, else the session's open one, else the one that merged or
        // closed: its state stays in view. A watch that ended never hides a newer open one. Only one that can still change
        // can be watched.
        let watchable = watchablePullRequest()
        let pullRequest = SessionBranches.trayPullRequest(watch: watches.first, open: watchable,
                                                          links: pullRequestSync.links[runID] ?? [])
        let watch = pullRequest.flatMap { url in watches.first { $0.url == url.absoluteString } }
        let canWatch = watch != nil || watchable != nil
        // A session that worked on more than one branch lists each, with the state of its pull request.
        let branches = workspace.run(runID).map { run in
            SessionBranches.rows(earlier: run.earlierBranches ?? [], earlierLinks: pullRequestSync.earlier[runID] ?? [],
                                 current: run.branch, currentPullRequest: pullRequest,
                                 currentLinks: pullRequestSync.links[runID] ?? [])
        } ?? []
        // A pull request the git button is writing or opening shows here already, where it will appear.
        let pending = workspace.quickGitProgress(runID).flatMap { $0.action.proposes ? $0.step : nil }
        let hasPullRequests = pullRequest != nil || !branches.isEmpty || pending != nil
        if hasPullRequests || !waiting.isEmpty || !quotes.isEmpty {
            ComposerTray(edge: .top) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if !quotes.isEmpty {
                        ComposerQuoteChips(quotes: quotes.items, remove: { id in quotes.remove(id) },
                                           setNote: { id, note in quotes.setNote(note, for: id) },
                                           jump: { quote in jumpToQuote(quote) })
                        if hasPullRequests || !waiting.isEmpty { ComposerTrayDivider() }
                    }
                    if !branches.isEmpty {
                        branchList(branches, watches: watches, canWatchCurrent: watchable != nil)
                    } else if let pullRequest {
                        PullRequestWatchStrip(url: pullRequest, watch: watch, toggle: canWatch ? {
                            if watch == nil { workspace.watchPullRequest(runID, url: pullRequest) } else { workspace.stopWatchingPullRequest(runID, url: pullRequest) }
                        } : nil)
                    }
                    if let pending { PullRequestPendingRow(step: pending) }
                    if hasPullRequests && !waiting.isEmpty { ComposerTrayDivider() }
                    if !waiting.isEmpty {
                        QueuedMessagesStrip(
                            queue: waiting, editing: editingQueued,
                            remove: { id in
                                if editingQueued == id { cancelQueuedEdit() }
                                workspace.removeQueued(runID, message: id)
                            },
                            edit: { id in
                                if editingQueued != nil { cancelQueuedEdit() }
                                if let text = workspace.beginEditQueued(runID, message: id, currentDraft: draft) {
                                    editingQueued = id
                                    draft = text
                                    focused = true
                                }
                            },
                            move: { workspace.moveQueued(runID, message: $0, toIndex: $1) },
                            sendNow: workspace.canSendQueuedNow(runID) ? { id in
                                if editingQueued == id { cancelQueuedEdit() }
                                workspace.sendQueuedNow(runID, message: id)
                            } : nil)
                    }
                }
            }
        }
    }

    /// The session's branches in the tray, oldest first and the current one last, their names in one column so the pull
    /// requests line up. A chat with many keeps the newest ones open and folds the older ones behind one row.
    @ViewBuilder
    private func branchList(_ rows: [SessionBranches.Row], watches: [PullRequestWatch], canWatchCurrent: Bool) -> some View {
        let folded = SessionBranches.folded(rows, open: showsOlderBranches)
        let titles = Dictionary(((pullRequestSync.earlier[runID] ?? []) + (pullRequestSync.links[runID] ?? []))
            .compactMap { link in link.title.map { (link.url, $0) } }, uniquingKeysWith: { _, newer in newer })
        if folded.hidden > 0 || showsOlderBranches && rows.count > SessionBranches.shownWhenFolded {
            Button {
                withAnimation(NookTheme.reveal) { showsOlderBranches.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(icon: "chevron.up")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(showsOlderBranches ? 180 : 0))
                    Text(showsOlderBranches ? tr("ws.branches.hideOlder")
                                            : tr("ws.branches.showOlder", folded.hidden, folded.hiddenPullRequests))
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, NookTheme.Spacing.xs)
            .padding(.vertical, NookTheme.Spacing.xxs)
        }
        ForEach(folded.shown) { row in
            branchRow(row, watch: row.pullRequest.flatMap { url in watches.first { $0.url == url.absoluteString } }, title: row.pullRequest.flatMap { titles[$0.absoluteString] }, canWatchCurrent: canWatchCurrent)
        }
    }

    /// One of the session's branches in the tray: its pull request with state, title and checks (watched from here, one
    /// at a time), or its name and "no pull request" while it has none. `canWatchCurrent`: the current branch's pull
    /// request can still change (a merged or closed one is only shown).
    @ViewBuilder
    private func branchRow(_ row: SessionBranches.Row, watch: PullRequestWatch?, title: String?, canWatchCurrent: Bool) -> some View {
        if let url = row.pullRequest {
            let watched = watch != nil
            PullRequestWatchStrip(url: url, watch: watch, branch: row.branch, isCurrent: row.isCurrent,
                                  title: title, toggle: watched || !row.isCurrent || canWatchCurrent ? {
                if watched { workspace.stopWatchingPullRequest(runID, url: url) } else { workspace.watchPullRequest(runID, url: url) }
            } : nil)
        } else if let branch = row.branch {
            BranchTrayRow(branch: branch, isCurrent: row.isCurrent)
        }
    }

    /// The agent with its account and the model. A running agent with `liveSettings` switches at once, Codex and
    /// Antigravity from the next turn; another account or agent moves the session there with a summary of what happened (shown in the timeline),
    /// which waits until the agent is idle.
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let account = profile.map { AccountLabel.name($0, app: app) }
        let picked = run.model.isEmpty ? nil : app.modelMenuName(run.model, for: run.provider, profileID: run.profileID)
        // On Auto: "Auto · Claude Sonnet 5.5", the model it picked last.
        let model = run.autoModel == true ? [tr("auto.model"), picked].compactMap { $0 }.joined(separator: " · ") : picked
        let chosenModel = run.autoModel == true ? AutoModel.id : run.model
        let idle = workspace.canTransfer(runID)
        // The agents its project switched off are not offered to move to; the session's own agent always is.
        let allowed = app.connectedProviders(in: run.projectPath)
        let providers = idle ? (allowed.contains(run.provider) ? allowed : [run.provider] + allowed) : [run.provider]
        return ModelPickerDropdown {
            ComposerPill(agent: run.provider.displayName, account: AccountTag.badge(profile, app: app),
                         text: [run.provider.displayName, account, model].compactMap { $0 }.joined(separator: " · "),
                         short: model ?? run.provider.displayName)
        } content: {
            AgentModelPicker(providers: providers, provider: run.provider, profileID: run.profileID, model: chosenModel, showsAccounts: idle) { provider, accountID, option in
                let profileID = accountID ?? (provider == run.provider ? run.profileID : app.connectedProfiles(for: provider).first?.id ?? run.profileID)
                let chosen = option ?? (provider == run.provider ? chosenModel : workspace.settings.model(for: provider))
                workspace.applySelection(runID, provider: provider, profileID: profileID, model: chosen, resumeIfLimited: true)
            }
        }
        .help(run.resolvedModel ?? tr("ws.new.model"))
    }

    private func modeMenu(_ run: WorkspaceRun) -> some View {
        ModeToggle(mode: Binding(get: { run.mode }, set: { workspace.configure(runID, mode: $0) }))
    }

    private func permissionMenu(_ run: WorkspaceRun) -> some View {
        // ⇧⌘A opens it (`permissionPicker.toggle`).
        ComposerDropdown(width: 300, command: "permissionPicker.toggle") {
            ComposerPill(symbol: run.mode == .plan ? "lock" : run.permission.symbol,
                         text: run.mode == .plan ? tr("compose.readOnly") : run.permission.label,
                         tint: run.permission == .bypass && run.mode != .plan ? NookTheme.coralSoft : nil)
        } content: {
            DropdownHeader(title: tr("compose.access"))
            ForEach(run.provider.capabilities.policies) { policy in
                DropdownRow(symbol: policy.symbol, title: policy.label, detail: policy.help(for: run.provider),
                            chosen: run.permission == policy, tint: policy == .bypass ? NookTheme.coralSoft : nil) {
                    workspace.configure(runID, permission: policy)
                }
            }
        }
        .disabled(run.mode == .plan)
        .help(run.permission.help(for: run.provider))
    }
}

/// What you are writing in a session's composer: the text, its pictures, the passages quoted into it, and the queued
/// message open in it. `AgentRunPanel` holds it without observing it.
@MainActor
final class RunComposerState: ObservableObject {
    /// The session the draft belongs to: each change to it is saved for that session, as you type.
    private(set) var session: String?
    private var switching = false
    @Published var draft = "" {
        didSet {
            guard !switching, draft != oldValue, let session else { return }
            ComposerDraftStore.shared.save(sessionID: session, text: draft)
        }
    }

    /// Shows the draft saved for `session` (empty when there is none), saving nothing on the way: clearing the box of
    /// the session you leave is not a change you made to its draft.
    func show(session: String) {
        switching = true
        defer { switching = false }
        // The pictures of the session you leave wait for it; a queued message open for editing belongs to that session's
        // queue, so it closes (the next send would otherwise overwrite a message in a queue that is not shown).
        if let previous = self.session, previous != session {
            heldImages[previous] = images.isEmpty ? nil : images
            images = heldImages.removeValue(forKey: session) ?? []
            editingQueued = nil
        }
        self.session = session
        draft = ComposerDraftStore.shared.draft(for: session) ?? ""
    }
    /// Pictures added in other sessions' composers and not sent yet, by session, while this panel is open.
    private var heldImages: [String: [ImageAttachment]] = [:]
    @Published var images: [ImageAttachment] = []
    /// Passages of answers picked for the next message (Quote / Ask about this), as chips above the composer.
    @Published var quotes = ComposerQuotes()
    /// A queued message that is being edited in the composer, and the draft that waits behind it.
    @Published var editingQueued: UUID?
}

/// Draws `content` again whenever `object` changes, without the view around it: that view can hold the object without
/// observing it.
struct Observing<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder let content: () -> Content

    init(_ object: Object, @ViewBuilder content: @escaping () -> Content) {
        self.object = object
        self.content = content
    }

    var body: some View { content() }
}

/// Two closures made once and kept, for `quoteSelection` and `askAboutSelection`: a closure written in `body` is a new
/// value on every redraw, and an environment value that changes redraws every view that reads it, past `.equatable()`.
@MainActor
final class StableSelectionActions {
    private var handler: ((String, Bool) -> Void)?
    private(set) lazy var quote: (String) -> Void = { [weak self] in self?.handler?($0, false) }
    private(set) lazy var ask: (String) -> Void = { [weak self] in self?.handler?($0, true) }

    /// Points both closures at `handler` (text, and whether to ask) and returns itself.
    func bind(_ handler: @escaping (String, Bool) -> Void) -> StableSelectionActions {
        self.handler = handler
        return self
    }
}

/// The session composer of `AgentRunPanel`. The panel redraws for every streamed token (it observes the timeline), and a
/// fresh composer closure is never equal to the last, so the composer, its five menus and their popovers were built again
/// up to 20 times a second while nothing in them changed. As an `Equatable` view it is built again only when what it shows
/// from the panel changes (`key`), or when one of the objects it reads publishes (it observes them itself).
struct RunComposerHost<Content: View>: View, Equatable {
    struct Key: Equatable {
        var run: WorkspaceRun
        var subagents: [SubagentInfo]
        var commands: [BackgroundCommandInfo]
        var skills: [Skill]
        var repository: String?
        var shownSubagents: Bool

        init(run: WorkspaceRun, subagents: [SubagentInfo], commands: [BackgroundCommandInfo], skills: [Skill], repository: String?,
             shownSubagents: Bool) {
            // A streaming turn moves `updatedAt` every two seconds; the composer does not show it.
            var run = run
            run.updatedAt = .distantPast
            self.run = run
            self.subagents = subagents
            self.commands = commands
            self.skills = skills
            self.repository = repository
            self.shownSubagents = shownSubagents
        }
    }

    @ObservedObject var state: RunComposerState
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var app: AppModel
    @ObservedObject var pullRequests: PullRequestSync
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.state === rhs.state && lhs.workspace === rhs.workspace
    }

    var body: some View { content() }
}

/// What `AgentRunPanel` draws from a session's events: the shown events, their blocks, the turns that changed files, the
/// outputs and the running command. Each walks the whole timeline, and the panel's body runs on every keystroke in its
/// composer (the draft is its state), on hover and while the side panels resize; this makes them again only when the
/// events or the session's tasks, folder or activity change. Comparing the same array again is cheap: Swift sees it is
/// the same storage.
@MainActor
private final class RunTimelineDerived {
    private var key: (all: [RunEvent], active: Bool, tasks: [RunTaskStep]?, directory: String, detail: TimelineDetail)?
    private(set) var events: [RunEvent] = []
    private(set) var blocks: [TimelineBlock] = []
    private(set) var turns: [TurnDiff] = []
    /// The answer that ends each finished turn: only it carries the footer (copy and time), as in an agent's own
    /// transcript (`TranscriptPresentation`).
    private(set) var finalAnswers: Set<UUID> = []
    /// Each turn's changed-files card, under the turn's final answer (inside the reply, above its footer); a turn without
    /// an answer keeps it under the line that ends it.
    private(set) var cards: [UUID: TurnDiff] = [:]
    /// The newest final answer while the agent waits: a question at its end can be answered with a click.
    private(set) var answerable: UUID?
    private(set) var outputs: [SessionOutput] = []
    /// `SessionOutputs.signature` of each output: the panel compares them on every redraw, also for every streamed token.
    private(set) var outputSignatures: [String] = []
    /// The subagents since your last message while the agent works or any of them still runs, for the bar above the
    /// composer (which redraws on every keystroke).
    private(set) var subagents: [SubagentInfo] = []
    /// Every subagent of the session, for the Subagents tab of the side panel, and their `Subagents.signature`.
    private(set) var allSubagents: [SubagentInfo] = []
    private(set) var subagentsSignature = ""
    /// The commands it left running in the background since your last message while it works or any still runs, for the
    /// bar above the composer; and all of them, for the Subagents tab (`BackgroundCommands`).
    private(set) var commands: [BackgroundCommandInfo] = []
    private(set) var allCommands: [BackgroundCommandInfo] = []
    /// The last pull request the agent reported with `<pr-created>`, for the tray above the composer.
    private(set) var createdPullRequest: URL?

    /// Counts the changes to the events other than more text in the answer being written (`TimelineRowContext`).
    private(set) var revision = 0
    /// Your messages, for the marks on the rail beside the session.
    private(set) var marks: [PromptMark] = []
    /// The blocks of each turn, oldest first: what `HistoryWindow` leaves out when only the latest turns are drawn.
    private(set) var rowsPerTurn: [Int] = []
    /// The turn of each shown event, made when first asked after the turns changed.
    private var turnOfEvent: [UUID: Int]?
    /// The pull request the events before the last one link, so a streamed answer only has to look at itself.
    private var pullRequestBeforeLast: URL?
    /// Each turn's blocks, so only the turn that changed is laid out again.
    private var blockCache = TimelineBlockCache()
    /// The last search in the find bar, for the events it searched.
    private var found: (query: String, events: [RunEvent], result: TimelineSearchResult)?

    /// The find bar's matches, searched again only when the query or the events changed.
    func search(_ query: String) -> TimelineSearchResult {
        if let found, found.query == query, found.events == events { return found.result }
        let result = TimelineSearch.search(events, query: query)
        found = (query, events, result)
        return result
    }

    /// The turn an event is in (by `TimelinePresentation.split` of the shown events), for revealing it in the window.
    func turn(of eventID: UUID) -> Int? {
        if let turnOfEvent { return turnOfEvent[eventID] }
        var made: [UUID: Int] = [:]
        for (index, turn) in blockCache.turns.enumerated() {
            for event in turn.events { made[event.id] = index }
        }
        turnOfEvent = made
        return made[eventID]
    }

    @discardableResult
    func update(_ all: [RunEvent], run: WorkspaceRun, detail: TimelineDetail) -> RunTimelineDerived {
        let active = run.status.isActive
        let sameRun = key.map {
            $0.active == active && $0.directory == run.workingDirectory && $0.tasks == run.tasks && $0.detail == detail
        } ?? false
        if sameRun, let key, key.all == all { return self }
        // While the agent writes, only the text of its last answer grows, many times a second. The blocks show that text;
        // the turns, outputs, running command and earlier links do not read it, and each walks the whole session (an edit's
        // diff, every tool's input as JSON), so they stay as they are.
        let streamed = sameRun && key.map { Self.onlyStreamed(from: $0.all, to: all) } == true
        key = (all, active, run.tasks, run.workingDirectory, detail)
        // Only what is shown is filtered: the turns, outputs and subagents below still read every event.
        events = detail.filter(all.filter { !($0.kind == .system && $0.tool == "launch") })
        blocks = TimelinePresentation.blocks(events, active: active, cache: &blockCache)
        rowsPerTurn = blockCache.turns.map(\.blocks.count)
        if streamed, let last = all.last {
            createdPullRequest = RunPullRequestLinks.pullRequest(in: last) ?? pullRequestBeforeLast
            return self
        }
        revision &+= 1
        turnOfEvent = nil
        // Also the turns without an edit: git may find files they changed by a command (`countTurns`).
        turns = TurnDiff.collect(events: all, keepEmpty: true)
        finalAnswers = []
        cards = [:]
        let byTurn = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Split as `TurnDiff.collect` does, so a turn and its card share the id of its first event.
        let split = TimelinePresentation.split(all)
        for (index, turn) in split.enumerated() {
            // A turn still at work gets its final answer (and its card) when it is done.
            let finished = index < split.count - 1 || !active
            let answer = finished ? turn.last(where: { $0.kind == .assistant && $0.tool != "plan" && BackgroundWork.notice($0.text).isEmpty }) : nil
            if let answer { finalAnswers.insert(answer.id) }
            guard let first = turn.first, let diff = byTurn[first.id.uuidString] else { continue }
            if let answer {
                cards[answer.id] = diff
            } else if let end = diff.answerID.flatMap(UUID.init(uuidString:)) {
                cards[end] = diff
            }
        }
        answerable = active ? nil : events.last(where: { $0.kind == .assistant }).flatMap { finalAnswers.contains($0.id) ? $0.id : nil }
        outputs = SessionOutputs.collect(all, tasks: run.tasks, directory: run.workingDirectory)
        outputSignatures = outputs.map(SessionOutputs.signature)
        allSubagents = Subagents.list(all)
        allCommands = BackgroundCommands.list(all)
        subagentsSignature = Subagents.signature(allSubagents) + "|" + BackgroundCommands.signature(allCommands)
        let current = Subagents.current(all)
        subagents = active || current.contains(where: \.isRunning) ? current : []
        let currentCommands = BackgroundCommands.current(all)
        commands = active || currentCommands.contains(where: \.isRunning) ? currentCommands : []
        marks = TranscriptPresentation.promptMarks(events: events)
        pullRequestBeforeLast = RunPullRequestLinks.last(in: Array(all.dropLast()))
        createdPullRequest = all.last.flatMap(RunPullRequestLinks.pullRequest(in:)) ?? pullRequestBeforeLast
        return self
    }

    /// Whether `new` is `old` with only more (or other) text in its last answer or thinking: the same events, the last one
    /// the same apart from its text, already written to, and not a plan (whose text is an output) nor turning into a
    /// background notice.
    private static func onlyStreamed(from old: [RunEvent], to new: [RunEvent]) -> Bool {
        guard old.count == new.count, var before = old.last, let after = new.last, before.id == after.id,
              before.kind == .assistant || before.kind == .thinking, before.tool != "plan",
              // The first words make an answer of an empty event: the turns read which event answers.
              !before.text.isEmpty else { return false }
        let wasNotice = BackgroundWork.isNotice(before)
        before.text = after.text
        return before == after && wasNotice == BackgroundWork.isNotice(after) && old.dropLast().elementsEqual(new.dropLast())
    }
}

/// The last pull request a run's conversation links, for the tray above its composer and the badge on its row. Kept per
/// run and read again only when the conversation changed, as every row of the list asks on each redraw.
@MainActor
final class RunPullRequestLinks {
    static let shared = RunPullRequestLinks()
    private var memo: [UUID: (count: Int, last: UUID?, url: URL?)] = [:]

    func url(_ id: UUID, events: [RunEvent]) -> URL? {
        if let hit = memo[id], hit.count == events.count, hit.last == events.last?.id { return hit.url }
        let url: URL?
        if let hit = memo[id], hit.count > 0, hit.count < events.count, events[hit.count - 1].id == hit.last {
            // Events came after the ones read: only those (and the last one read, which may have grown while it streamed)
            // can hold a newer link. Reading the whole session again on every event of a long run cost the inbox list
            // a scan of thousands of events per update.
            url = Self.last(in: Array(events[(hit.count - 1)...])) ?? hit.url
        } else {
            url = Self.last(in: events)
        }
        memo[id] = (events.count, events.last?.id, url)
        return url
    }

    nonisolated static func last(in events: [RunEvent]) -> URL? {
        events.reversed().lazy.compactMap(pullRequest(in:)).first
    }

    /// The last pull request link an event carries: the agent's words, or what a tool that made or showed one printed
    /// (`gh pr create` prints its link, and the agent does not always repeat it).
    nonisolated static func pullRequest(in event: RunEvent) -> URL? {
        switch event.kind {
        case .assistant:
            return MarkdownBlock.lastGitHubPullRequest(in: event.text)
        case .tool:
            guard let output = event.output,
                  PullRequestToolCall.showsPullRequest(tool: event.tool, command: [event.text, event.detail]) else { return nil }
            return MarkdownBlock.lastGitHubPullRequest(in: output)
        default:
            return nil
        }
    }

    /// The same for a conversation Nook reads from an agent's transcript (a session it only sees).
    nonisolated static func last(in messages: [AgentChatMessage]) -> URL? {
        for message in messages.reversed() {
            switch message.kind {
            case .assistant:
                if let url = MarkdownBlock.lastGitHubPullRequest(in: message.text) { return url }
            case .tools:
                for step in message.steps.reversed() {
                    guard let output = step.output,
                          PullRequestToolCall.showsPullRequest(tool: step.name, command: [step.summary, step.command]) else { continue }
                    if let url = MarkdownBlock.lastGitHubPullRequest(in: output) { return url }
                }
            default:
                continue
            }
        }
        return nil
    }
}
