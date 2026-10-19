import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A session that Nook runs itself, inside the Agents tab: the whole conversation, approvals, stop, follow-up
/// messages, and the settings for the next turn (mode, permissions, model). Everything you would otherwise do in a
/// terminal happens here.
struct AgentRunPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    let runID: UUID
    /// The terminal and browser icons, next to the branch button.
    var headerAccessory: AnyView? = nil
    @State private var draft = ""
    @State private var images: [ImageAttachment] = []
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
    /// The `#` list needs the repository ("owner/repo") of the session's folder.
    @State private var repository: String?
    /// The agent's skills for `$`, read from its skill folders.
    @State private var skills: [Skill] = []
    /// A queued message that is being edited in the composer, and the draft that waits behind it.
    @State private var editingQueued: UUID?
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findIndex: Int?
    @StateObject private var composerModel = ComposerModel()
    @FocusState private var focused: Bool
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared
    /// The panel next to the conversation with what the agent produced: open, which output it shows, and wider.
    @State private var outputsOpen = false
    @State private var outputSelection: String?
    /// How wide the results and the terminal are: drag the line beside them, double-click it to reset. Remembered.
    @AppStorage("nook.agents.outputsWidth") private var outputsWidth = PanelLayout.outputs
    @AppStorage("nook.agents.consoleWidth") private var consoleWidth = PanelLayout.console
    @State private var totalWidth: Double = 0
    /// The outputs (by signature) you have seen, for the dot on the panel's button; nil until the session shows.
    @State private var seenOutputs: Set<String>?
    /// The terminal on the left: the command it shows; nil while it is closed.
    @State private var consoleEventID: UUID?

    var body: some View {
        if let run = workspace.run(runID) {
            let outputs = SessionOutputs.collect(workspace.timeline(runID), tasks: run.tasks, directory: run.workingDirectory)
            let runningCommand = CommandConsole.running(workspace.timeline(runID))?.id
            let consoleOpen = consoleEventID != nil
            HStack(alignment: .top, spacing: 0) {
                if let consoleEventID, let event = workspace.timeline(runID).first(where: { $0.id == consoleEventID }) {
                    CommandConsolePanel(event: event) {
                        withAnimation(.easeInOut(duration: 0.2)) { self.consoleEventID = nil }
                    }
                    .resizablePanel(width: $consoleWidth, defaultWidth: PanelLayout.console, minimum: PanelLayout.minimumPanel,
                                    available: PanelLayout.room(totalWidth, besides: outputsOpen ? outputsWidth : nil),
                                    rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .trailing)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 10) {
                    header(run, outputs: outputs)
                    timeline(run)
                    if let pending = workspace.approvals[runID], let first = pending.first {
                        approval(run, first, more: pending.count - 1)
                    } else if let request = bridge.pending.first(where: { $0.caller.kind == .run(runID) }) {
                        // A command or pull request the agent asks for through Nook's workspace.
                        let approval = ApprovalCenter.make(request)
                        ApprovalView(approval: approval, maxHeight: 110) { app.approvals.decide(approval, $0) }
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
                    } else {
                        composer(run)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if outputsOpen {
                    SessionOutputsPanel(outputs: outputs, selection: $outputSelection, wide: PanelLayout.wide($outputsWidth)) {
                        withAnimation(.easeInOut(duration: 0.2)) { outputsOpen = false }
                    }
                    .resizablePanel(width: $outputsWidth, defaultWidth: PanelLayout.outputs, minimum: PanelLayout.minimumPanel,
                                    available: PanelLayout.room(totalWidth, besides: consoleOpen ? consoleWidth : nil),
                                    rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .leading)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
            // An open terminal follows the agent to the next command it runs.
            .onChange(of: runningCommand) { _, next in
                if consoleEventID != nil, let next { consoleEventID = next }
            }
            .onChange(of: outputs.map(SessionOutputs.signature)) { _, _ in 
                noticeOutputs(outputs, working: run.status.isActive, turnStart: run.turnStartedAt)
            }
            .onAppear {
                workspace.loadTimeline(runID)
                if run.repoRoot != nil { workspace.refreshGit(runID) }
                // The agent's connection opens now, so your first message goes straight in.
                workspace.prewarm(runID)
                focused = true
                // What was there before you opened the session is not news.
                seenOutputs = Set(outputs.map(SessionOutputs.signature))
                Task { repository = await workspace.githubRepository(runID) }
                loadComposerState(run)
            }
            .onChange(of: draft) { _, new in ComposerDraftStore.shared.save(sessionID: runID.uuidString, text: new) }
            .onChange(of: runID) { _, _ in
                workspace.loadTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID) }
                workspace.prewarm(runID)
                draft = ""
                if let fresh = workspace.run(runID) { loadComposerState(fresh) }
                renaming = false
                confirmDelete = false
                // Nothing of the previous session carries over: above all not a pending "restore files".
                revertTarget = nil
                revertError = nil
                reverting = false
                openBlocks = []
                expanded = []
                outputsOpen = false
                outputSelection = nil
                seenOutputs = nil
                consoleEventID = nil
            }
        } else {
            Text(tr("agents.run.gone"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Header

    /// While the agent works, a plan, design, document or image that is new opens the outputs panel on it, and anything
    /// new while it is closed puts a dot on its button. What a session that does not work shows (its timeline loading
    /// as you open it) is not news.
    private func noticeOutputs(_ outputs: [SessionOutput], working: Bool, turnStart: Date?) {
        guard working, let seen = seenOutputs else {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
            return
        }
        let fresh = outputs.filter { !seen.contains(SessionOutputs.signature($0)) }
        // Only what this turn made opens the panel by itself, not earlier work that comes in as the timeline loads.
        if let shown = fresh.first(where: { output in
            if case .tasks = output.kind { return false }
            return output.date >= (turnStart ?? .distantFuture)
        }) {
            outputSelection = shown.id
            withAnimation(.easeInOut(duration: 0.2)) { outputsOpen = true }
        }
        if outputsOpen { seenOutputs = Set(outputs.map(SessionOutputs.signature)) }
    }

    /// Opens or closes the outputs panel; opening it marks everything seen.
    private func outputsButton(_ run: WorkspaceRun, _ outputs: [SessionOutput]) -> some View {
        let fresh = !outputsOpen && SessionOutputs.hasNew(outputs, seen: seenOutputs ?? [])
        return SessionOutputsButton(open: outputsOpen, fresh: fresh, tint: run.provider.color) {
            outputsOpen.toggle()
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
        }
    }

    /// "nook / Agents-pagina rustiger maken" (double-click the name to rename it) with the branch button on the right.
    private func header(_ run: WorkspaceRun, outputs: [SessionOutput]) -> some View {
        HStack(spacing: 8) {
            Text(run.projectName)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .help(AgentPathFormat.tilde(run.workingDirectory))
            Text("/").foregroundStyle(NookTheme.textTertiary)
            if renaming {
                TextField(tr("ws.title.placeholder"), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .onSubmit {
                        workspace.rename(runID, to: titleDraft)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
            } else {
                Text(run.title)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        titleDraft = run.title
                        renaming = true
                    }
                    .help(tr("ws.title.renameHelp"))
            }
            Spacer(minLength: 8)
            outputsButton(run, outputs)
            if let fraction = run.usage.contextFraction, fraction > 0.6 {
                Text("ctx \(Int((fraction * 100).rounded()))%")
                    .font(NookTheme.mono(11, .medium))
                    .foregroundStyle(fraction > 0.85 ? NookTheme.coral : NookTheme.amber)
                    .help(tr("ws.header.contextHelp"))
            }
            if let remote = run.remote {
                // On another machine: its name, and a terminal there over SSH instead of this Mac's git and tools.
                Button { openRemoteTerminal(remote) } label: {
                    Label(remote.name, systemImage: "server.rack")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("ws.remote.terminal", remote.host))
            } else {
                if let headerAccessory { headerAccessory }
                FolderGitButton(directory: run.workingDirectory, runID: runID, agentWorking: run.status.isActive, showChanges: {
                    workspace.markReviewed(runID)
                    app.viewModel.open(.changes(runID, file: nil))
                }, onChange: {
                    workspace.refreshGit(runID)
                })
                .id(run.workingDirectory)
            }
        }
        .font(NookTheme.font(13.5))
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
            let isFinished = finishedMarks.isFinished(key: finishKey, idle: !run.status.isActive, lastActive: run.updatedAt)
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
            if run.lineage != nil {
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SessionExport.markdown(run, events: workspace.timeline(runID)), forType: .string)
            }
            Button(tr("ws.export.save")) { saveMarkdown(run) }
            // Terminal context: the last lines of this session's terminal go with your message.
            Button(tr("ws.context.terminal")) { addTerminalOutput(run) }
                .disabled(TerminalStore.shared.sessions(in: run.workingDirectory).isEmpty)
            Button(tr("button.openFolder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: run.workingDirectory, isDirectory: true))
            }
            .disabled(run.isRemote)
            Button(tr("agents.run.changes")) { app.viewModel.open(.changes(runID, file: nil)) }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
        return PullRequestSync.shared.links[runID]?
            .first { ($0.state == .open || $0.state == .draft) && ($0.host == .github || $0.host == .gitlab) }
            .flatMap { URL(string: $0.url) }
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

    /// What this composer offers beyond typing: the commands, files and sessions to point at, and the agent's own color.
    private func composerConfig(_ run: WorkspaceRun) -> ComposerConfig {
        var config = ComposerConfig()
        config.tint = run.provider.composerTint
        config.fileRoot = run.workingDirectory
        config.repository = repository
        config.sessions = { [workspace, runID] in
            workspace.runs.filter { $0.id != runID && !$0.archived }.map { ($0.id.uuidString.lowercased(), $0.title) }
        }
        // Only the commands this agent really has (see AgentCommands).
        config.commands = AgentCommands.commands(for: run.provider, hasProject: true, surface: .agent)
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
        if draft.isEmpty, let saved = store.draft(for: runID.uuidString) { draft = saved }
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
        let levels = EffortLevels.levels(for: run.provider, model: run.model)
        if !levels.isEmpty {
            ComposerDivider()
            Menu {
                Button { workspace.setEffort(runID, nil) } label: {
                    if run.effort == nil { Label(tr(EffortLevels.label(nil)), systemImage: "checkmark") } else { Text(tr(EffortLevels.label(nil))) }
                }
                ForEach(levels, id: \.self) { level in
                    Button { workspace.setEffort(runID, level) } label: {
                        if run.effort == level { Label(tr(EffortLevels.label(level)), systemImage: "checkmark") } else { Text(tr(EffortLevels.label(level))) }
                    }
                }
            } label: {
                ComposerPill(symbol: "gauge.with.dots.needle.33percent", text: tr(EffortLevels.label(run.effort)))
            }
            .composerMenu()
            .help(tr("compose.effort.help"))
        }
    }

    /// The context ring, and the microphone next to it.
    @ViewBuilder
    private func composerTrailing(_ run: WorkspaceRun) -> some View {
        HStack(spacing: 2) {
            if let window = run.usage.contextWindow, let used = run.usage.contextTokens, window > 0 {
                ComposerContextRing(used: used, window: window,
                                    onCompact: run.status.isActive || !(run.provider == .claude || run.provider == .codex) ? nil
                                        : { workspace.send(runID, text: "/compact") })
            }
            ComposerMic(text: $draft)
        }
    }

    // MARK: Timeline

    private func timeline(_ run: WorkspaceRun) -> some View {
        let events = workspace.timeline(runID).filter { !($0.kind == .system && $0.tool == "launch") }
        let blocks = TimelinePresentation.blocks(events, active: run.status.isActive)
        let turnFiles = TurnChanges.byTurnEnd(events)
        let found = finding ? TimelineSearch.search(events, query: findQuery) : .idle
        let current = findIndex.flatMap { found.matches.indices.contains($0) ? found.matches[$0].eventID : nil }
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if events.isEmpty {
                        Text(tr("agents.run.empty"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    // Finished turns fold to "Worked for …", tool calls in a row to one sentence.
                    ForEach(blocks) { block in
                        TimelineBlockView(block: block, expanded: openBlocks, toggle: toggleBlock) { event in
                            AnyView(
                                VStack(alignment: .leading, spacing: 6) {
                                    eventRow(event)
                                    if let turn = turnFiles[event.id] {
                                        TurnChangesChip(turn: turn, directory: run.workingDirectory) { path in
                                            try await workspace.turnDiff(runID, path: path, start: turn.start, end: turn.end)
                                        }
                                    }
                                }
                                .padding(.vertical, current == event.id ? 4 : 0)
                                .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.iris.opacity(current == event.id ? 0.16 : 0)))
                            )
                        }
                        .id(block.id)
                    }
                    if run.status.isActive {
                        // The agent's task list, live, right above what it does now.
                        if TaskChecklist.showsInline(run.tasks, active: true), let tasks = run.tasks {
                            TaskChecklistCard(steps: tasks)
                        }
                        LiveActivityRow(live: TimelinePresentation.live(events), activity: AgentActivity.current(events),
                                        step: run.tasks.flatMap(TaskChecklist.activeStep),
                                        since: run.turnStartedAt,
                                        waiting: run.status == .waitingApproval, asking: workspace.questions[runID] != nil,
                                        accent: run.provider.color,
                                        openConsole: CommandConsole.running(events).map { command -> () -> Void in
                                            { withAnimation(.easeInOut(duration: 0.2)) { consoleEventID = consoleEventID == command.id ? nil : command.id } }
                                        })
                    }
                    if run.status == .failed || run.status == .stopped {
                        recovery(run, events: events, blocks: blocks, proxy: proxy)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .overlay(alignment: .bottom) {
                if scroll.mode == .free, !atEnd, !finding {
                    TimelineToEndPill {
                        scroll.jumpedToEnd()
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .top) {
                if finding {
                    TimelineFindBar(query: $findQuery, result: found, current: findIndex,
                                    previous: { stepFind(found, blocks: blocks, proxy: proxy, forward: false) },
                                    next: { stepFind(found, blocks: blocks, proxy: proxy, forward: true) },
                                    close: closeFind)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            }
            // A mark per message of yours, to jump through a long session.
            .overlay(alignment: .topTrailing) {
                let turns = events.filter { $0.kind == .user }
                if turns.count >= 4, !finding {
                    TurnMinimap(turns: turns) { id in
                        scroll.userScrolled()
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .padding(.top, 8)
                }
            }
            .background {
                Button("") { openFind() }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = nil
                let fresh = TimelineSearch.search(events, query: findQuery)
                if let first = fresh.next(after: nil) { findIndex = first; reveal(fresh, at: first, blocks: blocks, proxy: proxy) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: events.count) { _, _ in
                if scroll.shouldFollowEnd { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: events.last?.text.count ?? 0) { _, _ in
                if run.status.isActive, scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You sent something: it is the newest thing and follows again.
            .onChange(of: events.last(where: { $0.kind == .user })?.id) { _, _ in
                scroll.jumpedToEnd()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
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
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }

    private func recovery(_ run: WorkspaceRun, events: [RunEvent], blocks: [TimelineBlock], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: run.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                .foregroundStyle(run.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.status == .failed ? tr("ws.recovery.failed") : tr("ws.recovery.stopped"))
                    .font(NookTheme.font(12.5, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(run.statusDetail.flatMap { $0 == "interrupted" ? nil : $0 } ?? (run.providerSessionID != nil ? tr("ws.recovery.canResume") : tr("ws.recovery.noResume")))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            if let failure = FailureJump.firstFailure(in: events) {
                NookGhostButton(title: tr("timeline.goToFailure")) {
                    scroll.userScrolled()
                    for key in TimelineContainers.keys(blocks)[failure] ?? [] { openBlocks.insert(key) }
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(failure, anchor: .center) } }
                }
            }
            NookGhostButton(title: tr("ws.action.retry")) { workspace.retry(runID) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(run.status.color.opacity(0.07)))
    }

    @ViewBuilder
    private func eventRow(_ event: RunEvent) -> some View {
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
            eventView(event)
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("ws.revert.confirm"))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(revertError ?? tr("ws.revert.detail", ToolSummary.oneLine(target.text, 60)))
                    .font(NookTheme.font(11.5))
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.08)))
    }

    private func eventView(_ event: RunEvent) -> some View {
        EventRow(
            event: event,
            expanded: expanded.contains(event.id),
            toggle: { toggle(event.id) },
            openFile: { path in app.viewModel.open(.changes(runID, file: path)) },
            decide: { decision in
                if let request = event.callID { workspace.decide(runID, requestID: request, decision) }
            }
        )
    }

    private func toggleBlock(_ key: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if openBlocks.contains(key) { openBlocks.remove(key) } else { openBlocks.insert(key) }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Approval

    private func approval(_ run: WorkspaceRun, _ pending: PendingPermission, more: Int) -> some View {
        let request = ApprovalCenter.make(pending, run: run)
        return ApprovalView(approval: request, more: more, maxHeight: 110) { app.approvals.decide(request, $0) }
    }

    /// Inline instead of a dialog: the notch is a panel, not a window that sheets can attach to.
    private func deleteConfirmation(_ run: WorkspaceRun) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("agents.run.deleteConfirm", run.title))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(tr("agents.run.deleteDetail"))
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            NookGhostButton(title: tr("button.cancel")) { confirmDelete = false }
            NookPrimaryButton(title: tr("agents.run.delete")) {
                confirmDelete = false
                workspace.delete(runID)
                app.viewModel.selectedAgentID = ""
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.coral.opacity(0.08)))
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
            guard !text.isEmpty, !active else { return }
            let outgoing = composerModel.outgoing(text)
            draft = ""
            workspace.send(runID, text: outgoing.send)
        }
        // Codex over app-server and Claude Code take a new message during the turn (steering); others get it after the turn.
        // Return does what you chose in Settings, Cmd+Return the other.
        let canSteer = active && workspace.canSteer(runID)
        let preferred: ComposerDispatch.Intent = workspace.settings.steerByDefault ? .steer : .queue
        func deliver(_ intent: ComposerDispatch.Intent) -> () -> Void {
            {
                if editingQueued != nil { saveQueuedEdit(); return }
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let outgoing = composerModel.outgoing(text)
                draft = ""
                if ComposerDispatch.resolve(busy: true, intent: intent, canSteer: canSteer) == .steer,
                   workspace.steer(runID, text: outgoing.send) { return }
                workspace.enqueue(runID, text: outgoing.send)
            }
        }
        let primary = ComposerDispatch.resolve(busy: true, intent: preferred, canSteer: canSteer)
        let steers = primary == .steer
        return VStack(alignment: .leading, spacing: 5) {
            UsageLimitBanner(run: run)
            // The subagents the agent started this turn, and its task list.
            let subagents = active ? Subagents.latest(workspace.timeline(runID)) : []
            if !subagents.isEmpty { SubagentBar(agents: subagents) }
            // While the agent works its list shows in the timeline; one it left unfinished waits here.
            if let tasks = run.tasks, !tasks.isEmpty, !TaskChecklist.showsInline(tasks, active: run.status.isActive) {
                TasksStrip(steps: tasks)
            }
            if let watch = run.prWatch {
                PullRequestWatchStrip(watch: watch) { workspace.watchPullRequest(runID, url: nil) }
            }
            if let waiting = workspace.queued[runID], !waiting.isEmpty {
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
                    sendNow: workspace.canSendQueuedNow(runID) ? { workspace.sendQueuedNow(runID, message: $0) } : nil)
            }
            SessionComposer(
                text: $draft,
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
            .trailing { composerTrailing(run) }
            // While it works, what you type steers the turn or waits in line, and Cmd+Return does the other.
            .queueing(active ? deliver(preferred) : nil,
                      alternate: active ? deliver(preferred == .steer ? .queue : .steer) : nil,
                      label: steers ? tr("compose.steer") : tr("compose.queue"),
                      symbol: steers ? "arrow.turn.down.right" : "text.append")
            .images($images)
            if !active, run.mode == .plan {
                Text(tr("agents.run.planHint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    /// The agent with its account and the model. A model counts from the next turn (a running Claude Code switches at
    /// once); another account or agent moves the session there with a summary of what happened (shown in the timeline),
    /// which waits until the agent is idle.
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let account = profile.map { AccountLabel.name($0, app: app) }
        let model = run.model.isEmpty ? nil : app.modelName(run.model, for: run.provider)
        let idle = workspace.canTransfer(runID)
        let providers = idle ? app.connectedProviders : [run.provider]
        return ComposerDropdown(width: providers.count > 1 ? 340 : 296) {
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
            ComposerPill(symbol: run.permission == .bypass ? "lock.open" : "lock",
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
