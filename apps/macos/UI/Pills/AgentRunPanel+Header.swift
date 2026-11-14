import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The session's header: its title, state and the actions on it.
extension AgentRunPanel {
    // MARK: Header

    /// While the agent works, a plan, design or image that is new (or a document it handed to you) opens the outputs tab
    /// on it (`SessionOutputs.opensByItself`), and anything new while that tab is out of view puts a dot on it. What a
    /// session that does not work shows (its timeline loading as you open it) is not news.
    func noticeOutputs(_ outputs: [SessionOutput], working: Bool, turnStart: Date?) {
        guard working, let seen = seenOutputs else {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
            return
        }
        let fresh = outputs.filter { !seen.contains(SessionOutputs.signature($0)) }
        // Only what this turn made opens the tab by itself, not earlier work that comes in as the timeline loads.
        if let shown = fresh.first(where: { SessionOutputs.opensByItself($0, turnStart: turnStart) }),
           outputsLink.open(shown.id) {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
        } else if outputsLink.shown {
            seenOutputs = Set(outputs.map(SessionOutputs.signature))
        }
    }

    /// "nook / Agents-pagina rustiger maken" (click the folder for a new session in it, double-click the name to rename it) with the branch button on the right.
    func header(_ run: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            // The folder keeps its name before the title gives way, but truncates too in a narrow conversation instead
            // of pushing the header past it (under a wide side panel).
            FolderCrumb(name: run.projectName, directory: run.projectPath, workingDirectory: run.workingDirectory,
                        local: run.remote == nil)
                .layoutPriority(1)
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
                ComposerDropdown(width: 248, scrolls: true) {
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
            if let launcher = app.launcher(of: run) { LauncherLink(launcher: launcher) }
            // Its parent, forks, delegated tasks and side chats: the only way to the ones the Agents list leaves out.
            LineageControl(workspace: workspace, runID: runID)
            Spacer(minLength: 8)
            ResourceUsageBadge(workspace: workspace, runID: runID)
            if let remote = run.remote {
                // On another machine: its name, and a terminal there over SSH instead of this Mac's git and tools.
                Button { openRemoteTerminal(remote) } label: {
                    Label(remote.name, icon: "server.rack")
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .buttonStyle(.nookPlain)
                .help(tr("ws.remote.terminal", remote.host))
                // On another machine the session panel does not dock, so its usage is the ring here.
                SessionUsageButton(source: SessionUsageSource(runID: runID)).toolbarGroup()
            } else {
                FolderGitButton(directory: run.workingDirectory, runID: runID, agentWorking: run.status.isActive,
                                usage: SessionUsageSource(runID: runID), showChanges: {
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
    func actionsMenu(_ run: WorkspaceRun) -> some View {
        ComposerPlusMenu(attach: { attachFile(run) }, screenshot: { app.captureFrontWindow() }) {
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
    func timelineDetail(_ run: WorkspaceRun) -> TimelineDetail {
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
        // their own in the panel (folded when there are many), so there is no submenu to lose under the pointer.
        if let connectors = workspace.connectorSignIns[runID], !connectors.isEmpty {
            DropdownDivider()
            ConnectorSignInGroup(runID: runID, connectors: connectors)
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
}
