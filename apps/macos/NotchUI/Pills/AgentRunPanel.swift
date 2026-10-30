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
    @State private var reverting = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var titleDraft = ""
    /// The older branches of a session that worked on many, shown in the tray above the composer.
    @State private var showsOlderBranches = false
    /// The `#` list needs the repository ("owner/repo") of the session's folder.
    @State private var repository: String?
    /// The agent's skills for `$`, read from its skill folders.
    @State private var skills: [Skill] = []
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    /// The blocks on screen, for where you left the session; not state, so scrolling does not redraw it.
    @State private var onScreen = VisibleTimelineRows()
    /// Where the timeline is scrolled, for the rail, and the position the rail scrolls it to when you drag it.
    @State private var viewport = TimelineViewport()
    @State private var position = ScrollPosition()
    /// The timeline is taller than the view: only then the rail with your messages shows.
    @State private var overflows = false
    /// Where you left this session's conversation last time (TimelineVisitStore), read as it opens.
    @State private var visit: TimelineVisit?
    /// The block the "New since your last visit" line sits above; decided as the session opens.
    @State private var newSince: UUID?
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findIndex: Int?
    @StateObject private var composerModel = ComposerModel()
    @FocusState private var focused: Bool
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared
    /// The pull requests of the session's branches, for the tray above the box.
    @ObservedObject private var pullRequestSync = PullRequestSync.shared
    /// The outputs tab of the side panel around this session (`SessionWorkbench`), which shows what the agent produced.
    @Environment(\.sessionOutputs) private var outputsLink
    @Environment(\.sessionSide) private var sideLink
    /// How wide the terminal is: drag the line beside it, double-click it to reset. Remembered.
    @AppStorage("nook.agents.consoleWidth") private var consoleWidth = PanelLayout.console
    @State private var totalWidth: Double = 0
    /// The outputs (by signature) you have seen, for the dot on the outputs tab; nil until the session shows.
    @State private var seenOutputs: Set<String>?
    /// The terminal on the left: the command it shows; nil while it is closed.
    @State private var consoleEventID: UUID?
    /// The lines git counted per turn (by the turn's id), in place of those read from the agent's edits.
    @State private var countedLines: [String: [String: EditLines]] = [:]
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
            let _ = derived.update(workspace.timeline(runID), run: run)
            let outputs = derived.outputs
            let runningCommand = derived.runningCommand
            let consoleOpen = consoleEventID != nil
            HStack(alignment: .top, spacing: 0) {
                if let consoleEventID, let event = workspace.timeline(runID).first(where: { $0.id == consoleEventID }) {
                    CommandConsolePanel(event: event) {
                        withAnimation(NookTheme.reveal) { self.consoleEventID = nil }
                    }
                    .sidePanel(.leading, width: $consoleWidth, defaultWidth: PanelLayout.console,
                               available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    header(run)
                    timeline(run)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
            .preference(key: SessionBesideWidth.self, value: consoleOpen ? SidePanelRoom.of(consoleWidth) : 0)
            // A file the agent links to (`src/app.swift:12`) opens in your editor at that line.
            .environment(\.fileLinkBase, run.isRemote ? nil : run.workingDirectory)
            // Selected words of an answer go with the reply as a chip above the composer (right-click › Quote in your
            // message, or Ask about this, which also puts the keyboard in the box; the same with ⇧⌘L and ⌘L).
            .environment(\.quoteSelection, { addQuote($0, ask: false) })
            .environment(\.askAboutSelection, { addQuote($0, ask: true) })
            .keyCommands(["selection.quote": { quoteSelected(ask: false) }, "selection.ask": { quoteSelected(ask: true) }])
            // An open terminal follows the agent to the next command it runs.
            .onChange(of: runningCommand) { _, next in
                if consoleEventID != nil, let next { consoleEventID = next }
            }
            // What the agent produced goes to the outputs tab of the side panel, with a dot while something is new.
            .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(
                outputs: outputs,
                turns: turnDiffs(run),
                pullRequest: derived.createdPullRequest,
                fresh:!outputsLink.shown && seenOutputs.map { SessionOutputs.hasNew(outputs, seen: $0) } == true))
            // What the outputs tab shows is seen.
            .onChange(of: outputsLink.shown) { _, isShown in
                if isShown { seenOutputs = Set(outputs.map(SessionOutputs.signature)) }
            }
            .onChange(of: outputs.map(SessionOutputs.signature)) { _, _ in 
                noticeOutputs(outputs, working: run.status.isActive, turnStart: run.turnStartedAt)
            }
            .onAppear {
                workspace.loadTimeline(runID)
                visit = TimelineVisitStore.shared.visit(for: Self.visitKey(runID))
                if let visit { openBlocks = visit.open }
                if run.repoRoot != nil { workspace.refreshGit(runID) }
                // The agent's connection opens now, so your first message goes straight in.
                workspace.prewarm(runID)
                focused = true
                // What was there before you opened the session is not news.
                seenOutputs = Set(outputs.map(SessionOutputs.signature))
                Task { repository = await workspace.githubRepository(runID) }
                loadComposerState(run)
            }
            .onDisappear { rememberVisit(runID) }
            .onChange(of: runID) { previous, _ in
                rememberVisit(previous)
                workspace.loadTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID) }
                workspace.prewarm(runID)
                // The draft of the session you left stays saved, and the one of this session comes back.
                composerState.show(session: runID.uuidString)
                if let fresh = workspace.run(runID) { loadComposerState(fresh) }
                renaming = false
                confirmDelete = false
                // Nothing of the previous session carries over: above all not a pending "restore files".
                revertTarget = nil
                revertError = nil
                reverting = false
                openBlocks = []
                expanded = []
                countedLines = [:]
                quotes.removeAll()
                seenOutputs = nil
                consoleEventID = nil
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
        HStack(spacing: NookTheme.Spacing.md) {
            // The folder keeps its name before the title gives way, but truncates too in a narrow conversation instead
            // of pushing the header past it (under a wide side panel).
            Text(run.projectName)
                .foregroundStyle(NookTheme.textTertiary)
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
                if let headerAccessory { headerAccessory }
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
            }
        }
        .font(NookTheme.TextStyle.body)
        .frame(height: 30)
    }

    /// Everything else you can do with this session: settings for the next turn, retry, archive, delete.
    private func actionsMenu(_ run: WorkspaceRun) -> some View {
        let idle = !run.status.isActive
        return ComposerPlusMenu(attach: { attachFile(run) }) {
            Button(tr("compose.stash.set")) {
                if let text = composerModel.stashKey(composerText: draft) { draft = text; ComposerDraftStore.shared.setStash(composerModel.stash) }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composerModel.stash.entries.isEmpty)
            Divider()
            Button(tr("agents.run.details")) { app.viewModel.open(.details(runID)) }
            Divider()
            if run.status.isActive {
                Button(tr("ws.action.stop")) { workspace.stop(runID) }
            } else if run.status == .failed || run.status == .stopped {
                Button(tr("ws.action.retry")) { workspace.retry(runID) }
            }
            let finishKey = FinishedSessions.key(run: run)
            let isFinished = finishedMarks.contains(finishKey)
            Button(isFinished ? tr("agents.finish.reopen") : tr("agents.finish.mark")) {
                if isFinished { finishedMarks.reopenByUser(finishKey) } else { finishedMarks.mark(finishKey) }
            }
            .disabled(run.status.isActive)
            Button(tr("agents.run.rename")) {
                titleDraft = run.title
                renaming = true
            }
            // A fork starts from this session; switching moves it to another agent with a summary of what happened.
            Button(tr("agents.fork")) {
                if let id = workspace.fork(runID) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            }
            .disabled(!workspace.canTransfer(runID))
            if run.lineage?.kind == .fork {
                Button(tr("agents.mergeBack")) {
                    if workspace.mergeBack(runID), let parent = run.lineage?.parentID {
                        app.viewModel.selectedAgentID = "run:" + parent.uuidString
                    }
                }
                .disabled(!workspace.canTransfer(runID))
            }
            // PR watch: CI, reviews and comments on the session's pull request wake the agent.
            if run.prWatch != nil {
                Button(tr("ws.prwatch.stop")) { workspace.watchPullRequest(runID, url: nil) }
            } else {
                let watchable = watchablePullRequest()
                Button(tr("ws.prwatch.start")) { workspace.watchPullRequest(runID, url: watchable) }
                    .disabled(watchable == nil)
            }
            // Kept local: copy it, or save it where you want.
            Button(tr("ws.export.copy")) {
                Pasteboard.copy(SessionExport.markdown(run, events: workspace.timeline(runID)))
            }
            Button(tr("ws.export.save")) { saveMarkdown(run) }
            // Terminal context: the last lines of this session's terminal go with your message.
            Button(tr("ws.context.terminal")) { addTerminalOutput(run) }
                .disabled(TerminalStore.shared.sessions(in: run.workingDirectory).isEmpty)
            Button(tr("button.openFolder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: run.workingDirectory, isDirectory: true))
            }
            .disabled(run.isRemote)
            Button(tr("agents.run.changes")) {
                if headerAccessory != nil { app.viewModel.sessionTool = .changes } else { app.viewModel.open(.changes(runID, file: nil)) }
            }
            .disabled(run.repoRoot == nil)
            Divider()
            Button(tr("agents.run.archive")) {
                workspace.setArchived(runID, true)
                app.viewModel.selectedAgentID = ""
            }
            .disabled(!idle)
            Button(tr("agents.run.delete"), role: .destructive) { confirmDelete = true }
                .disabled(!idle)
        }
    }

    /// A terminal on the session's machine, in its folder (ssh -t, then your login shell there).
    private func openRemoteTerminal(_ remote: RemoteTarget) {
        var parts = ["ssh", "-t"]
        if let port = remote.port { parts += ["-p", String(port)] }
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

    /// A file you add to the message: it sits in the text as a reference, the agent reads it itself.
    private func attachFile(_ run: WorkspaceRun) {
        guard let ref = ComposerFilePicker.pick(startingIn: run.workingDirectory) else { return }
        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + ContextRefs.link(ref) + " "
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
        // Only the commands this agent really has (see AgentCommands).
        config.commands = AgentCommands.commands(for: run.provider, hasProject: true, surface: .agent,
                                                 offered: workspace.acpCommands[runID] ?? [])
        config.skills = skills
        config.pullRequests = { repo in await GitHubPullRequests.openPullRequests(repo: repo) }
        config.keepsBigPastes = true
        config.onCommand = { [workspace, app, runID] command in
            switch command.action {
            case .plan: workspace.configure(runID, mode: .plan)
            case .fork:
                if let id = workspace.fork(runID) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            case .insert, .compact, .new: break
            }
        }
        return config
    }

    /// The draft you left in this session, the drafts set aside, and the agent's skills.
    private func loadComposerState(_ run: WorkspaceRun) {
        let store = ComposerDraftStore.shared
        if composerState.session != runID.uuidString { composerState.show(session: runID.uuidString) }
        composerModel.stash = store.stash
        composerModel.onStashChanged = { [composerModel] in store.setStash(composerModel.stash) }
        let folder = URL(fileURLWithPath: run.workingDirectory, isDirectory: true)
        Task {
            skills = await Task.detached(priority: .utility) {
                SkillIndex.scan(roots: SkillIndex.defaultRoots(home: FileManager.default.homeDirectoryForCurrentUser, project: folder))
            }.value
        }
    }

    /// The reasoning effort for the next turns, only for agents that have it.
    @ViewBuilder
    private func effortMenu(_ run: WorkspaceRun) -> some View {
        let levels = workspace.effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        if let family = app.modelFamily(run.model, for: run.provider, profileID: run.profileID) {
            // An agent that lists one model per thinking level: the level picks the model of that family.
            ComposerDivider()
            Menu {
                ForEach(family.members, id: \.self) { member in
                    Button { _ = workspace.applySelection(runID, provider: run.provider, profileID: run.profileID, model: member.id) } label: {
                        let title = tr(EffortLevels.label(variant: member.level))
                        if member.id == run.model { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                let current = family.members.first { $0.id == run.model }?.level ?? ""
                ComposerPill(symbol: "gauge.with.dots.needle.33percent", text: tr(EffortLevels.label(variant: current)))
            }
            .composerMenu()
            .help(tr("compose.effort.help"))
        } else if !levels.isEmpty {
            ComposerDivider()
            Menu {
                Button { workspace.setEffort(runID, nil) } label: {
                    if run.effort == nil { Label(tr(EffortLevels.label(nil)), systemImage: "checkmark") } else { Text(tr(EffortLevels.label(nil))) }
                }
                ForEach(levels, id: \.self) { level in
                    Button { workspace.setEffort(runID, level) } label: {
                        let title = workspace.effortTitle(level, for: run.provider, profileID: run.profileID)
                        if run.effort == level { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent",
                             text: workspace.effortTitle(run.effort, for: run.provider, profileID: run.profileID))
            }
            .composerMenu()
            .help(tr("compose.effort.help"))
        }
    }

    /// The context ring, and the microphone next to it.
    @ViewBuilder
    private func composerTrailing(_ run: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if let window = run.usage.contextWindow, let used = run.usage.contextTokens, window > 0 {
                // Every agent that compacts on `/compact` (Claude Code, Codex, an ACP agent that offers it) gets the button.
                let compacts = AgentCommands.canCompact(run.provider, offered: workspace.acpCommands[runID] ?? [])
                ComposerContextRing(used: used, window: window,
                                    onCompact: run.status.isActive || !compacts ? nil : { workspace.send(runID, text: "/compact") })
            }
            ComposerMic(text: $composerState.draft)
        }
    }

    // MARK: Turn diffs

    /// The finished turns that changed files, with the lines git counted where it did.
    private func turnDiffs(_ run: WorkspaceRun) -> [TurnDiff] {
        let turns = derived.update(workspace.timeline(runID), run: run).turns
        guard !countedLines.isEmpty else { return turns }
        return turns.map { turn in
            countedLines[turn.id].map { turn.counted($0, relativeTo: run.workingDirectory) } ?? turn
        }
    }

    /// Counts a turn's lines with git, between the snapshots around it (once per turn and set of files).
    private func countLines(_ turn: TurnDiff, run: WorkspaceRun) async {
        guard !run.isRemote, let start = turn.start, let end = turn.end else { return }
        if let counts = try? await workspace.turnLines(runID, paths: turn.files.map(\.path), start: start, end: end) {
            countedLines[turn.id] = counts
        }
    }

    // MARK: Timeline

    /// What sits under the timeline: an approval, a confirmation, the agent's question, or the composer.
    @ViewBuilder
    private func bottomBar(_ run: WorkspaceRun) -> some View {
        if let pending = workspace.approvals[runID], let first = pending.first {
            approval(run, first, more: pending.count - 1).chatColumn()
        } else if let request = bridge.pending.first(where: { $0.caller.kind == .run(runID) }) {
            // A command or pull request the agent asks for through Nook's workspace.
            let approval = ApprovalCenter.make(request)
            ApprovalView(approval: approval) { app.approvals.decide(approval, $0) }.chatColumn()
        }
        if let target = revertTarget {
            revertConfirmation(target)
        } else if confirmDelete {
            deleteConfirmation(run)
        } else if let question = workspace.questions[runID]?.first {
            // The agent asks something: its question takes the composer's place until answered (Stop stays).
            RunQuestionPanel(question: question, agent: run.provider.displayName,
                             onStop: { workspace.stop(runID) }) { answers in
                workspace.answer(runID, questionID: question.id, answers: answers)
            }
            .id(question.id)
            .chatColumn()
        } else {
            // Redrawn on its own with every keystroke, without the conversation above it.
            Observing(composerState) { composer(run) }.chatColumn()
        }
    }

    private func timeline(_ run: WorkspaceRun) -> some View {
        let memo = derived.update(workspace.timeline(runID), run: run)
        let events = memo.events
        let blocks = memo.blocks
        let cards = memo.cards
        let found = finding ? memo.search(findQuery) : .idle
        let current = findIndex.flatMap { found.matches.indices.contains($0) ? found.matches[$0].eventID : nil }
        // While the agent works, as in an agent's own transcript: "Working for …" right under your message, and the step
        // that runs now only in the live line at the end, not also in the list above it.
        let active = run.status.isActive
        let workingUnder = active ? events.last(where: { $0.kind == .user })?.id : nil
        let liveStep = active ? events.last.flatMap { $0.kind == .tool && $0.state == .running ? $0.id : nil } : nil
        let context = TimelineRowContext(structure: memo.revision, status: run.status,
                                         directory: run.isRemote ? nil : run.workingDirectory, highlighted: current,
                                         openEvents: expanded, shownFile: sideLink.shownFile, counted: countedLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    if events.isEmpty {
                        ListEmptyNote(tr("agents.run.empty"))
                    }
                    // Finished turns fold to "Worked for …", tool calls in a row to one sentence.
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                            if block.id == newSince { TimelineNewDivider() }
                            TimelineBlockView(block: block, expanded: openBlocks, context: context, toggle: toggleBlock) { event in
                                if event.id == liveStep { return AnyView(EmptyView()) }
                                return AnyView(
                                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                                        // What the turn changed (its card): under the final answer, inside it, as in an
                                        // agent's own transcript; a file or Open diff opens the diff beside it.
                                        let card = cards[event.id].map { turn in
                                            AnyView(TurnChangesCard(turn: turn, directory: run.workingDirectory) { file in
                                                sideLink.openDiff(TurnDiffSelection(turn: turn.id, file: file))
                                            }
                                            .task(id: turn.id + "|\(turn.files.count)") { await countLines(turn, run: run) })
                                        }
                                        let inReply = event.kind == .assistant && memo.finalAnswers.contains(event.id)
                                        eventRow(event, final: memo.finalAnswers.contains(event.id),
                                                 extras: inReply ? card : nil, answerable: memo.answerable == event.id)
                                        if !inReply, let card { card }
                                        if event.id == workingUnder { TranscriptWorkingLine(since: run.turnStartedAt) }
                                    }
                                    .padding(.vertical, current == event.id ? 4 : 0)
                                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.iris.opacity(current == event.id ? 0.16 : 0)))
                                )
                            }
                            // While the agent writes, only the block it writes into is drawn again.
                            .equatable()
                        }
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
                                               { withAnimation(NookTheme.reveal) { consoleEventID = consoleEventID == command.id ? nil : command.id } }
                                           },
                                           help: TimelinePresentation.live(turn).tool)
                    }
                    if run.status == .failed || run.status == .stopped {
                        recovery(run, events: events, blocks: blocks, proxy: proxy)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                .chatColumn()
            }
            .scrollPosition($position)
            .scrollIndicators(.never)
            // The conversation scrolls on behind the composer; the pill back to the end rides on top of it.
            .composerInset {
                VStack(spacing: NookTheme.Spacing.lg) { bottomBar(run) }
                    .toEndPill(scroll.mode == .free && !atEnd && !finding) {
                        scroll.jumpedToEnd()
                        withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
            }
            .padding(.top, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { ids in onScreen.ids = Set(ids.map(\.uuidString)) }
            // Scrolling away from the end stops the following until you come back.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, nowAtEnd in
                atEnd = nowAtEnd
                if nowAtEnd { scroll.reachedEnd() }
            }
            .onScrollPhaseChange { _, phase in
                if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
            }
            .onScrollGeometryChange(for: ScrollFrame.self) { geometry in
                ScrollFrame(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                            container: geometry.containerSize.height,
                            insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
            } action: { _, frame in
                viewport.frame = frame
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, now in
                overflows = now
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
            // A mark per message of yours along the edge, as in an agent's own transcript: it jumps and scrolls.
            .overlay(alignment: .trailing) {
                if overflows, !finding, !memo.marks.isEmpty {
                    TranscriptPromptRail(marks: memo.marks, viewport: viewport) { mark in
                        scroll.userScrolled()
                        guard let id = UUID(uuidString: mark.row) else { return }
                        withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .top) }
                    } onScrub: { offset in
                        if !scroll.isFreeAfterUserScroll { scroll.userScrolled() }
                        position.scrollTo(y: offset)
                    }
                    .padding(.vertical, NookTheme.Spacing.md)
                    .transition(.opacity)
                }
            }
            .keyCommand("chat.find") { openFind() }
            .onChange(of: findQuery) { _, _ in
                findIndex = nil
                let fresh = TimelineSearch.search(events, query: findQuery)
                if let first = fresh.next(after: nil) { findIndex = first; reveal(fresh, at: first, blocks: blocks, proxy: proxy) }
            }
            // Back where you left it: the end, what is new since, or the block you were reading (TimelineLanding);
            // after the handlers that follow the end on a new session, hence on the next turn of the run loop.
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                DispatchQueue.main.async { land(proxy) }
            }
            .onChange(of: runID) { _, _ in DispatchQueue.main.async { land(proxy) } }
            // Opened from a search hit: find what it matched.
            .onReceive(app.viewModel.$sessionFind) { wanted in
                guard let wanted, !wanted.isEmpty else { return }
                app.viewModel.sessionFind = nil
                openFind()
                findQuery = wanted
            }
            .onChange(of: events.count) { _, _ in
                if scroll.shouldFollowEnd { withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: events.last?.text.utf8.count ?? 0) { _, _ in
                if run.status.isActive, scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You sent something: it is the newest thing and follows again.
            .onChange(of: events.last(where: { $0.kind == .user })?.id) { _, _ in
                scroll.jumpedToEnd()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Where you left it

    private static func visitKey(_ id: UUID) -> String { "run:" + id.uuidString }

    /// The timeline's blocks in order with their times, as `timeline(_:)` shows them.
    private func visitRows(_ id: UUID) -> [TimelineLanding.Row] {
        // The session on screen: its blocks are already made (this runs as it opens and as you leave it).
        if id == runID, let run = workspace.run(id) {
            return derived.update(workspace.timeline(id), run: run).blocks.map { ($0.id.uuidString, $0.visitDate) }
        }
        let events = workspace.timeline(id).filter { !($0.kind == .system && $0.tool == "launch") }
        return TimelinePresentation.blocks(events, active: workspace.run(id)?.status.isActive ?? false)
            .map { ($0.id.uuidString, $0.visitDate) }
    }

    /// What came in since your last visit (under its line), the block you were reading when you left, or the end;
    /// following stops at a block, so what comes in does not pull you away from it.
    private func land(_ proxy: ScrollViewProxy) {
        let rows = visitRows(runID)
        newSince = visit.flatMap { TimelineLanding.firstNew(rows, since: $0.lastViewedAt) }.flatMap(UUID.init(uuidString:))
        switch TimelineLanding.decide(rows, visit: visit) {
        case .end:
            scroll.jumpedToEnd()
            proxy.scrollTo("bottom", anchor: .bottom)
        case .newSince(let id), .row(let id):
            guard let block = UUID(uuidString: id) else { return }
            scroll.userScrolled()
            proxy.scrollTo(block, anchor: .top)
        }
    }

    /// Where you leave a session: the block at the top, what you opened, and whether you were at the end.
    private func rememberVisit(_ id: UUID) {
        guard workspace.run(id) != nil else { return }
        TimelineVisitStore.shared.remember(sessionID: Self.visitKey(id), visit: TimelineVisit(
            anchorID: TimelineLanding.top(visitRows(id), visible: onScreen.ids), open: openBlocks, atEnd: atEnd,
            lastViewedAt: Date()))
    }

    // MARK: Quotes

    /// Picks a passage of an answer for the next message; `ask` also puts the keyboard in the box to ask about it.
    private func addQuote(_ text: String, ask: Bool) {
        switch quotes.add(text) {
        case .tooLong: ToastCenter.shared.warning(tr("ws.review.quoteTooLong"))
        case .full: ToastCenter.shared.warning(tr("compose.quote.full"))
        case .empty: break
        case nil: if ask { focused = true }
        }
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
        for key in TimelineContainers.keys(blocks)[id] ?? [] { openBlocks.insert(key) }
        DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
    }

    private func recovery(_ run: WorkspaceRun, events: [RunEvent], blocks: [TimelineBlock], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: run.status == .failed ? "exclamationmark.triangle" : "pause.circle")
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
            Spacer(minLength: 6)
            if let failure = FailureJump.firstFailure(in: events) {
                NookGhostButton(title: tr("timeline.goToFailure")) {
                    scroll.userScrolled()
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(NookTheme.surface))
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
            eventView(event)
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
        HStack(spacing: NookTheme.Spacing.md) {
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
            Spacer(minLength: 6)
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel).fill(NookTheme.surface))
    }

    private func eventView(_ event: RunEvent, final: Bool = true, extras: AnyView? = nil, answerable: Bool = false) -> some View {
        EventRow(
            event: event,
            final: final,
            extras: extras,
            // A question at the end of the newest answer, answered with a click, as in an agent's own transcript.
            onChoose: answerable ? { workspace.send(runID, text: $0) } : nil,
            expanded: expanded.contains(event.id),
            toggle: { toggle(event.id) },
            openFile: { path in app.viewModel.open(.changes(runID, file: path)) },
            decide: { decision in
                if let request = event.callID { workspace.decide(runID, requestID: request, decision) }
            },
            showFile: sideLink.showFile,
            // A session on another machine has its files there, not on this Mac.
            directory: workspace.run(runID).flatMap { $0.isRemote ? nil : $0.workingDirectory },
            shownFile: sideLink.shownFile
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
        return ApprovalView(approval: request, more: more) { app.approvals.decide(request, $0) }
    }

    /// Inline instead of a dialog: the notch is a panel, not a window that sheets can attach to.
    private func deleteConfirmation(_ run: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
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
            Spacer(minLength: 6)
            NookGhostButton(title: tr("button.cancel")) { confirmDelete = false }
            // The session's own worktree, which no other session uses, can go with it.
            if let worktree = workspace.orphanedWorktree(runID) {
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel).fill(NookTheme.surface))
    }

    // MARK: Composer

    /// The same composer a new session starts with: the agent and its model, mode and permissions for the next turn,
    /// everything else under ⋯, and send (or stop while it works).
    private func composer(_ run: WorkspaceRun) -> some View {
        let active = run.status.isActive
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Return while a queued message is open in the box saves it instead of sending.
            if editingQueued != nil { saveQueuedEdit(); return }
            guard composerModel.hasContent(text), !active else { return }
            let outgoing = composerModel.outgoing(text)
            draft = ""
            images = []
            let message = quotes.message(outgoing.send)
            quotes.removeAll()
            // Still finishing the last turn (or messages wait in line): this one waits too, never sent past them.
            workspace.submit(runID, text: message)
        }
        // Codex over app-server and Claude Code take a new message during the turn (steering); others get it after the turn.
        // Return does what you chose in Settings, Cmd+Return the other.
        let canSteer = active && workspace.canSteer(runID)
        let preferred: ComposerDispatch.Intent = workspace.settings.steerByDefault ? .steer : .queue
        func deliver(_ intent: ComposerDispatch.Intent) -> () -> Void {
            {
                if editingQueued != nil { saveQueuedEdit(); return }
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard composerModel.hasContent(text) else { return }
                let outgoing = composerModel.outgoing(text)
                draft = ""
                images = []
                let message = quotes.message(outgoing.send)
                quotes.removeAll()
                if ComposerDispatch.resolve(busy: true, intent: intent, canSteer: canSteer) == .steer,
                   workspace.steer(runID, text: message) { return }
                workspace.enqueue(runID, text: message)
            }
        }
        let primary = ComposerDispatch.resolve(busy: true, intent: preferred, canSteer: canSteer)
        let steers = primary == .steer
        return VStack(alignment: .leading, spacing: 5) {
            UsageLimitBanner(run: run)
            // The subagents the agent started this turn, and its task list.
            let subagents = active ? Subagents.latest(TimelinePresentation.lastTurn(workspace.timeline(runID))) : []
            if !subagents.isEmpty { SubagentBar(agents: subagents) }
            // While the agent works its list shows in the timeline; one it left unfinished waits here.
            if let tasks = run.tasks, !tasks.isEmpty, !TaskChecklist.showsInline(tasks, active: run.status.isActive) {
                TasksStrip(steps: tasks)
            }
            // The pull request it watches and the messages waiting in line sit in a tray tucked above the box, the
            // same tray a new session shows its folder and branch in under the box.
            VStack(spacing: 0) {
                aboveBox(watch: run.prWatch, waiting: workspace.queued[runID] ?? MessageQueue())
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
                }
                .rich(composerModel, composerConfig(run))
                .choicesBelowBox()
                .trailing { composerTrailing(run) }
                // While it works, what you type steers the turn or waits in line, and Cmd+Return does the other.
                .queueing(active ? deliver(preferred) : nil,
                          alternate: active ? deliver(preferred == .steer ? .queue : .steer) : nil,
                          label: steers ? tr("compose.steer") : tr("compose.queue"),
                          symbol: steers ? "arrow.turn.down.right" : "text.append")
                .images($composerState.images)
                .zIndex(1)
            }
            // ⇧⌘Return while it works: the first message waiting in line goes in now, as the queue's own button does.
            .keyCommands(["queue.steerFirst": { steerFirstQueued() }])
            if !active, run.mode == .plan {
                Text(tr("agents.run.planHint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    /// The tray above the box, when there is something to show in it.
    @ViewBuilder
    private func aboveBox(watch: PullRequestWatch?, waiting: MessageQueue) -> some View {
        // The watched pull request, the session's open one you stopped watching (or never watched), else the one that
        // merged or closed: its state stays in view. Only one that can still change can be watched.
        let watchable = watchablePullRequest()
        let pullRequest = watch.flatMap { URL(string: $0.url) } ?? watchable ?? PullRequestLink.shown(in: pullRequestSync.links[runID] ?? [])
        let canWatch = watch != nil || watchable != nil
        // A session that worked on more than one branch lists each, with the state of its pull request.
        let branches = workspace.run(runID).map { run in
            SessionBranches.rows(earlier: run.earlierBranches ?? [], earlierLinks: pullRequestSync.earlier[runID] ?? [],
                                 current: run.branch, currentPullRequest: pullRequest)
        } ?? []
        // A pull request the git button is writing or opening shows here already, where it will appear.
        let pending = workspace.quickGitProgress(runID).flatMap { $0.action.proposes ? $0.step : nil }
        let hasPullRequests = pullRequest != nil || !branches.isEmpty || pending != nil
        if hasPullRequests || !waiting.isEmpty || !quotes.isEmpty {
            ComposerTray(edge: .top) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if !quotes.isEmpty {
                        ComposerQuoteChips(quotes: quotes.items) { id in quotes.remove(id) }
                        if hasPullRequests || !waiting.isEmpty { ComposerTrayDivider() }
                    }
                    if !branches.isEmpty {
                        branchList(branches, watch: watch, canWatchCurrent: canWatch)
                    } else if let pullRequest {
                        PullRequestWatchStrip(url: pullRequest, watch: watch, toggle: canWatch ? {
                            workspace.watchPullRequest(runID, url: watch == nil ? pullRequest : nil)
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
    private func branchList(_ rows: [SessionBranches.Row], watch: PullRequestWatch?, canWatchCurrent: Bool) -> some View {
        let folded = SessionBranches.folded(rows, open: showsOlderBranches)
        let titles = Dictionary(((pullRequestSync.earlier[runID] ?? []) + (pullRequestSync.links[runID] ?? []))
            .compactMap { link in link.title.map { (link.url, $0) } }, uniquingKeysWith: { _, newer in newer })
        if folded.hidden > 0 || showsOlderBranches && rows.count > SessionBranches.shownWhenFolded {
            Button {
                withAnimation(NookTheme.reveal) { showsOlderBranches.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "chevron.up")
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
            branchRow(row, watch: watch, title: row.pullRequest.flatMap { titles[$0.absoluteString] }, canWatchCurrent: canWatchCurrent)
        }
    }

    /// One of the session's branches in the tray: its pull request with state, title and checks (watched from here, one
    /// at a time), or its name and "no pull request" while it has none. `canWatchCurrent`: the current branch's pull
    /// request can still change (a merged or closed one is only shown).
    @ViewBuilder
    private func branchRow(_ row: SessionBranches.Row, watch: PullRequestWatch?, title: String?, canWatchCurrent: Bool) -> some View {
        if let url = row.pullRequest {
            let watched = watch.flatMap { URL(string: $0.url) } == url
            PullRequestWatchStrip(url: url, watch: watched ? watch : nil, branch: row.branch, isCurrent: row.isCurrent,
                                  title: title, toggle: watched || !row.isCurrent || canWatchCurrent ? {
                workspace.watchPullRequest(runID, url: watched ? nil : url)
            } : nil)
        } else if let branch = row.branch {
            BranchTrayRow(branch: branch, isCurrent: row.isCurrent)
        }
    }

    /// The agent with its account and the model. A model counts from the next turn (a running Claude Code switches at
    /// once); another account or agent moves the session there with a summary of what happened (shown in the timeline),
    /// which waits until the agent is idle.
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let account = profile.map { AccountLabel.name($0, app: app) }
        let model = run.model.isEmpty ? nil : app.modelMenuName(run.model, for: run.provider, profileID: run.profileID)
        let idle = workspace.canTransfer(runID)
        let providers = idle ? app.connectedProviders : [run.provider]
        return ModelPickerDropdown {
            ComposerPill(agent: run.provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [run.provider.displayName, account, model].compactMap { $0 }.joined(separator: " · "),
                         short: model ?? run.provider.displayName)
        } content: {
            AgentModelPicker(providers: providers, provider: run.provider, profileID: run.profileID, model: run.model, showsAccounts: idle) { provider, accountID, option in
                let profileID = accountID ?? (provider == run.provider ? run.profileID : app.connectedProfiles(for: provider).first?.id ?? run.profileID)
                let chosen = option ?? (provider == run.provider ? run.model : workspace.settings.model(for: provider))
                workspace.applySelection(runID, provider: provider, profileID: profileID, model: chosen)
            }
        }
        .help(run.resolvedModel ?? tr("ws.new.model"))
    }

    private func modeMenu(_ run: WorkspaceRun) -> some View {
        ModeToggle(mode: Binding(get: { run.mode }, set: { workspace.configure(runID, mode: $0) }))
    }

    private func permissionMenu(_ run: WorkspaceRun) -> some View {
        ComposerDropdown(width: 300) {
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
        self.session = session
        draft = ComposerDraftStore.shared.draft(for: session) ?? ""
    }
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

/// What `AgentRunPanel` draws from a session's events: the shown events, their blocks, the turns that changed files, the
/// outputs and the running command. Each walks the whole timeline, and the panel's body runs on every keystroke in its
/// composer (the draft is its state), on hover and while the side panels resize; this makes them again only when the
/// events or the session's tasks, folder or activity change. Comparing the same array again is cheap: Swift sees it is
/// the same storage.
@MainActor
private final class RunTimelineDerived {
    private var key: (all: [RunEvent], active: Bool, tasks: [RunTaskStep]?, directory: String)?
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
    private(set) var runningCommand: UUID?
    /// The last pull request the agent reported with `<pr-created>`, for the tray above the composer.
    private(set) var createdPullRequest: URL?

    /// Counts the changes to the events other than more text in the answer being written (`TimelineRowContext`).
    private(set) var revision = 0
    /// Your messages, for the marks on the rail beside the session.
    private(set) var marks: [PromptMark] = []
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

    @discardableResult
    func update(_ all: [RunEvent], run: WorkspaceRun) -> RunTimelineDerived {
        let active = run.status.isActive
        let sameRun = key.map { $0.active == active && $0.directory == run.workingDirectory && $0.tasks == run.tasks } ?? false
        if sameRun, let key, key.all == all { return self }
        // While the agent writes, only the text of its last answer grows, many times a second. The blocks show that text;
        // the turns, outputs, running command and earlier links do not read it, and each walks the whole session (an edit's
        // diff, every tool's input as JSON), so they stay as they are.
        let streamed = sameRun && key.map { Self.onlyStreamed(from: $0.all, to: all) } == true
        key = (all, active, run.tasks, run.workingDirectory)
        events = all.filter { !($0.kind == .system && $0.tool == "launch") }
        blocks = TimelinePresentation.blocks(events, active: active, cache: &blockCache)
        if streamed, let last = all.last {
            createdPullRequest = RunPullRequestLinks.pullRequest(in: last) ?? pullRequestBeforeLast
            return self
        }
        revision &+= 1
        turns = TurnDiff.collect(events: all)
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
        runningCommand = CommandConsole.running(TimelinePresentation.lastTurn(all))?.id
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
        let url = Self.last(in: events)
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
            guard let output = event.output, showsPullRequest([event.tool, event.text, event.detail]) else { return nil }
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
                    guard let output = step.output, showsPullRequest([step.name, step.summary, step.command]) else { continue }
                    if let url = MarkdownBlock.lastGitHubPullRequest(in: output) { return url }
                }
            default:
                continue
            }
        }
        return nil
    }

    /// A tool call that makes or shows a pull request, so the link in its output is that pull request's.
    private nonisolated static func showsPullRequest(_ parts: [String?]) -> Bool {
        let call = parts.compactMap { $0 }.joined(separator: " ").lowercased()
        return call.contains("pr create") || call.contains("pr view") || call.contains("pull_request") || call.contains("pullrequest")
    }
}
