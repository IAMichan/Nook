import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The composer under the conversation, with its tray, menus and attachments.
extension AgentRunPanel {
    /// The session's machine when it logs in with a password that was not typed in this run of Nook yet.
    func lockedMachine(_ run: WorkspaceRun) -> RemoteMachine? {
        _ = unlockedAt
        guard let remote = run.remote,
              let machine = RemoteMachines.load().first(where: { $0.id == remote.machineID }),
              !RemotePasswords.shared.isUnlocked(machine) else { return nil }
        return machine
    }

    /// A terminal on the session's machine, in its folder (ssh -t, then your login shell there).
    func openRemoteTerminal(_ remote: RemoteTarget) {
        var parts = ["ssh", "-t"]
        parts += RemoteLaunch.destination(port: remote.port, identityFile: remote.identityFile)
        let inner = "cd " + RemoteLaunch.quotedDirectory(remote.directory) + #" && exec "${SHELL:-/bin/sh}" -l"#
        parts += ["--", remote.host, inner]
        let command = parts.map(CustomAgents.quote).joined(separator: " ")
        _ = TerminalStore.shared.open(in: NSHomeDirectory(), command: command, title: remote.name)
        app.viewModel.selectedAgentID = AgentsPage.terminals
    }

    func saveMarkdown(_ run: WorkspaceRun) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SessionExport.fileName(run)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        try? SessionExport.markdown(run, events: workspace.timeline(runID)).write(to: url, atomically: true, encoding: .utf8)
    }

    func takeFromSidePanel() {
        guard let delivery = ComposerInbox.shared.take(run: runID, directory: workspace.run(runID)?.workingDirectory ?? "") else { return }
        delivery.keepSnippets(in: composerModel)
        draft = delivery.merged(into: draft)
        composerState.images += delivery.images
        focused = true
    }

    /// "Reply" on an answer: the answer (or what you selected of it) as a quote at the top of the draft, the caret under it.
    func replyToAnswer(_ answer: String) {
        var text = draft
        ComposerFieldStyle.reply(to: answer, in: &text)
        draft = text
        focused = true
    }

    func addTerminalOutput(_ run: WorkspaceRun) {
        guard let terminal = TerminalStore.shared.sessions(in: run.workingDirectory).last else { return }
        let output = terminal.output(lines: 80).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        draft = "<terminal_context title=\"\(terminal.title)\">\n\(output)\n</terminal_context>\n\n" + draft
        focused = true
    }

    /// The session's open GitHub pull request or GitLab merge request, from the git button or the pull request list.
    func watchablePullRequest() -> URL? {
        if let url = workspace.openPullRequests[runID], PullRequestWatch.canWatch(url) { return url }
        if let synced = PullRequestSync.shared.links[runID]?
            .first(where: { ($0.state == .open || $0.state == .draft) && ($0.host == .github || $0.host == .gitlab) })
            .flatMap({ URL(string: $0.url) }) { return synced }
        // The one the agent just made, before the sync has found it.
        return derived.createdPullRequest.flatMap { PullRequestWatch.canWatch($0) ? $0 : nil }
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The suggested next prompt for a finished turn, when the gate allows it (`requestNextPrompt`).
    private func requestNextPrompt() {
        workspace.requestNextPrompt(runID, composerEmpty: draftIsEmpty)
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
    func attachFile(_ run: WorkspaceRun) {
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
        // The sentence suggestions read who the message goes to and the agent's last answer (`ComposerCompleter`).
        config.situation = { [workspace, runID] in
            let run = workspace.runs.first { $0.id == runID }
            return ComposerCompletion.Situation(recipient: run?.provider.displayName,
                                                project: run.map { ($0.workingDirectory as NSString).lastPathComponent },
                                                lastAnswer: workspace.lastAnswer(runID))
        }
        config.onCommand = { [workspace, app, runID] command in
            switch command.action {
            case .plan: workspace.configure(runID, mode: .plan)
            case .fork:
                if let id = workspace.fork(runID) { app.viewModel.selectedAgentID = "run:" + id.uuidString }
            // The next message starts the new conversation, also while a turn runs; the strip above the
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
    func loadComposerState(_ run: WorkspaceRun) {
        let store = ComposerDraftStore.shared
        if composerState.session != runID.uuidString { composerState.show(session: runID.uuidString) }
        composerModel.stash = store.stash
        // ArrowUp walks through what you sent this session, also after a relaunch.
        composerModel.history.seed(workspace.timeline(runID).filter { $0.kind == .user }.map { ContextRefs.visible($0.text) })
        // Weakly: the model holds this closure, so a strong capture would keep it (and its stash) alive for good.
        composerModel.onStashChanged = { [weak composerModel] in
            guard let composerModel else { return }
            store.setStash(composerModel.stash)
        }
        let (working, project) = (run.workingDirectory, run.projectPath)
        Task {
            skills = await Task.detached(priority: .utility) {
                let folder = SkillIndex.projectFolder(workingDirectory: working, projectPath: project)
                return SkillIndex.scan(roots: SkillIndex.defaultRoots(home: FileManager.default.homeDirectoryForCurrentUser, project: folder))
            }.value
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
    func composer(_ run: WorkspaceRun) -> some View {
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
            // Still finishing the last turn (or messages wait in line): this one waits too, never sent past them. Back
            // at a long session whose cache ran out, the chip may say to summarize first.
            if !workspace.submitAfterCompacting(runID, text: message) {
                workspace.submit(runID, text: message, fromYou: true)
            }
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
            ConnectorSignInBanner(runID: runID)
            ResourceWaitStrip(runID: runID)
            // Its side chats (/btw): open one, or bring its result back here.
            let sideChats = SideChat.children(of: runID, in: workspace.runs)
            if !sideChats.isEmpty { SideChatStrip(workspace: workspace, chats: sideChats) }
            // The tasks it delegated: at work, asking something, or ended since your last message (its sub-threads).
            let subThreads = workspace.subThreads(of: runID)
            if !subThreads.isEmpty { SubThreadStrip(workspace: workspace, threads: subThreads) }
            GuestStrip(id: runID, shares: GuestShares.shared)
            if let goal = run.goal {
                GoalStrip(goal: goal, canPause: workspace.takesGoalOutsideTurns(runID)) { workspace.goalControl(runID, $0) }
            }
            if workspace.freshArmed.contains(runID) {
                FreshConversationStrip { workspace.keepConversation(runID) }
            }
            // What it does besides talking, in one dock with a tab per kind: its task list, the subagents it started since
            // your message (also those still at work in the background after its turn), and the commands it left
            // running in the background (a dev server, a watcher): the session is not done while those run.
            let tasks = run.tasks.flatMap { TaskChecklist.showsAboveComposer($0) ? $0 : nil } ?? []
            let subagents = derived.subagents
            let commands = derived.commands
            if !tasks.isEmpty || !subagents.isEmpty || !commands.isEmpty {
                AgentActivityDock(tasks: tasks, working: run.status.isActive,
                                  subagents: subagents,
                                  stopSubagent: run.provider.capabilities.stopsOneSubagent ? { workspace.stopSubagent(runID, $0) } : nil,
                                  commands: commands, focus: $barFocus,
                                  reveal: { conversationFocus = $0 },
                                  openPanel: outputsLink.showSubagents,
                                  agentPIDs: { workspace.agentPIDs(runID) })
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
                    if run.mode == .plan {
                        modeMenu(run)
                        ComposerDivider()
                    }
                }
                .rich(composerModel, composerConfig(run))
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
                // Asked for only while this composer is on screen and empty: a finished turn, once. Asked again when the
                // turn's last reply lands, a hold clears or the box is emptied, so a finished turn always gets one.
                .onChange(of: workspace.nextPromptTrigger(runID), initial: true) { _, _ in requestNextPrompt() }
                .onChange(of: draftIsEmpty) { _, _ in requestNextPrompt() }
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
            // this one works on in the background.
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
        // The pull requests it works on besides its own branch's: one it was asked to fix, one you linked. Open first.
        // They show above the session's own branches, so its current branch (where a new pull request appears) and the
        // one being opened stay at the bottom, right above the box.
        let shownURLs = Set(([pullRequest] + branches.map(\.pullRequest)).compactMap { $0?.absoluteString })
        // Every pull request the session watches shows too, not only the first.
        let linked = pullRequestSync.others(run: runID)
        let watchedOnly = watches.compactMap { watch in
            linked.contains { $0.url == watch.url } ? nil : URL(string: watch.url).flatMap(PullRequestLink.init(url:))
        }
        let others = (linked + watchedOnly)
            .filter { !shownURLs.contains($0.url) && URL(string: $0.url) != nil }
            .sorted { ($0.state.isOpen ? 0 : 1, -$0.number) < ($1.state.isOpen ? 0 : 1, -$1.number) }
        let hasPullRequests = pullRequest != nil || !branches.isEmpty || pending != nil || !others.isEmpty
        if hasPullRequests || !waiting.isEmpty || !quotes.isEmpty {
            ComposerTray(edge: .top) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if !quotes.isEmpty {
                        ComposerQuoteChips(quotes: quotes.items, remove: { id in quotes.remove(id) },
                                           setNote: { id, note in quotes.setNote(note, for: id) },
                                           jump: { quote in jumpToQuote(quote) })
                        if hasPullRequests || !waiting.isEmpty { ComposerTrayDivider() }
                    }
                    ForEach(others) { link in otherRow(link, watches: watches) }
                    if !branches.isEmpty {
                        RunBranchTray(rows: branches, watches: watches, canWatchCurrent: watchable != nil, runID: runID, workspace: workspace,
                                      pullRequestSync: pullRequestSync, showsOlderBranches: $showsOlderBranches)
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

    /// A pull request the session works on that is not its own branch's, in the same row as those: its state, title and
    /// checks, watched from here (CI and reviews then wake the agent) while it can still change.
    @ViewBuilder
    private func otherRow(_ link: PullRequestLink, watches: [PullRequestWatch]) -> some View {
        if let url = URL(string: link.url) {
            let watch = watches.first { $0.url == link.url }
            PullRequestWatchStrip(url: url, watch: watch, title: link.title,
                                  toggle: watch != nil || (link.state.isOpen && PullRequestWatch.canWatch(url)) ? {
                if watch == nil { workspace.watchPullRequest(runID, url: url) } else { workspace.stopWatchingPullRequest(runID, url: url) }
            } : nil)
        }
    }

    /// The agent with its account and the model. A running agent with `liveSettings` switches at once, Codex and
    /// Antigravity from the next turn; another account or agent moves the session there with a summary of what happened (shown in the timeline),
    /// which waits until the agent is idle.
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let picked = run.model.isEmpty ? nil
            : ComposerModelLabel.compact(app.modelMenuName(run.model, for: run.provider, profileID: run.profileID),
                                         agent: run.provider.displayName)
        // On Auto: "Auto · Claude Sonnet 5.5", the model it picked last.
        let model = run.autoModel == true ? [tr("auto.model"), picked].compactMap { $0 }.joined(separator: " · ") : picked
        let chosenModel = run.autoModel == true ? AutoModel.id : run.model
        let idle = workspace.canTransfer(runID)
        // The agents its project switched off are not offered to move to; the session's own agent always is.
        let allowed = app.connectedProviders(in: run.projectPath)
        let providers = idle ? (allowed.contains(run.provider) ? allowed : [run.provider] + allowed) : [run.provider]
        return ModelPickerDropdown(holdsOptions: true, hasSideColumn: reasoning(run) != nil) {
            ComposerPill(agent: run.provider.displayName, account: AccountTag.badge(profile, app: app),
                         text: model ?? run.provider.displayName,
                         detail: effortWord(run),
                         badge: subThreadsOn(run) ? ("app.connected.to.app.below.fill", tr("compose.mainThread.on")) : nil,
                         showsChevron: false)
        } content: {
            AgentModelPicker(providers: providers, provider: run.provider, profileID: run.profileID, model: chosenModel, showsAccounts: idle,
                             footer: AnyView(options(run)),
                             trailing: reasoning(run).map { AnyView(ModelPickerReasoning(effort: $0)) }) { provider, accountID, option in
                let profileID = accountID ?? (provider == run.provider ? run.profileID : app.connectedProfiles(for: provider).first?.id ?? run.profileID)
                let chosen = option ?? (provider == run.provider ? chosenModel : workspace.settings.model(for: provider))
                workspace.applySelection(runID, provider: provider, profileID: profileID, model: chosen, resumeIfLimited: true)
            }
        }
        .composerTip(run.resolvedModel ?? tr("ws.new.model"))
    }

    private func modeMenu(_ run: WorkspaceRun) -> some View {
        ModeToggle(mode: Binding(get: { run.mode }, set: { workspace.configure(runID, mode: $0) }))
    }

    /// Access, speed and sub-threads, in the footer of the model picker (the agent decides on Plan itself).
    private func options(_ run: WorkspaceRun) -> some View {
        ModelPickerOptions(
            access: .init(provider: run.provider, chosen: run.permission, readOnly: run.mode == .plan,
                          pick: { workspace.configure(runID, permission: $0) }),
            speedTiers: workspace.speedTiers(for: run), speed: workspace.speedTier(run),
            pickSpeed: { workspace.setSpeedTier(runID, $0) },
            ultracodeOffered: Ultracode.offered(provider: run.provider, model: run.model),
            ultracode: run.ultracode == true, setUltracode: { workspace.setUltracode(runID, $0) },
            mainThreadOffered: MainThread.offered(provider: run.provider, access: workspace.settings.bridgeAccess),
            mainThread: run.mainThread == true, setMainThread: { workspace.setMainThread(runID, $0) })
    }

    /// The chosen effort as the model pill says it ("High"); nil on the agent's default.
    private func effortWord(_ run: WorkspaceRun) -> String? {
        if let family = app.modelFamily(run.model, for: run.provider, profileID: run.profileID) {
            guard let level = family.members.first(where: { $0.id == run.model })?.level, !level.isEmpty else { return nil }
            return tr(EffortLevels.label(variant: level))
        }
        return run.effort.map { workspace.effortTitle($0, for: run.provider, profileID: run.profileID) }
    }

    /// Main thread (or Ultracode, the same choice in the picker) is on for this session.
    private func subThreadsOn(_ run: WorkspaceRun) -> Bool {
        MainThread.offered(provider: run.provider, access: workspace.settings.bridgeAccess) ? run.mainThread == true
            : Ultracode.offered(provider: run.provider, model: run.model) && run.ultracode == true
    }

    /// The reasoning levels, in the column beside the models; nil when the agent has none for this model.
    private func reasoning(_ run: WorkspaceRun) -> ModelPickerOptions.Effort? {
        let levels = workspace.effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        let effort = ModelPickerOptions.Effort(
            family: app.modelFamily(run.model, for: run.provider, profileID: run.profileID),
            model: run.model,
            modelName: run.model.isEmpty ? run.provider.displayName
                : app.modelMenuName(run.model, for: run.provider, profileID: run.profileID),
            levels: levels, chosen: run.effort,
            title: { workspace.effortTitle($0, for: run.provider, profileID: run.profileID) },
            pickLevel: { workspace.setEffort(runID, $0) },
            pickModel: { _ = workspace.applySelection(runID, provider: run.provider, profileID: run.profileID, model: $0) })
        return effort.family != nil || !levels.isEmpty ? effort : nil
    }
}
