import SwiftUI
import AppKit

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
    @FocusState private var focused: Bool
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        if let run = workspace.run(runID) {
            VStack(alignment: .leading, spacing: 10) {
                header(run)
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
            .onAppear {
                workspace.loadTimeline(runID)
                if run.repoRoot != nil { workspace.refreshGit(runID) }
                // The agent's connection opens now, so your first message goes straight in (T3Code keeps it alive too).
                workspace.prewarm(runID)
                focused = true
            }
            .onChange(of: runID) { _, _ in
                workspace.loadTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID) }
                workspace.prewarm(runID)
                draft = ""
                renaming = false
                confirmDelete = false
                // Nothing of the previous session carries over: above all not a pending "restore files".
                revertTarget = nil
                revertError = nil
                reverting = false
                openBlocks = []
                expanded = []
            }
        } else {
            Text(tr("agents.run.gone"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Header

    /// "nook / Agents-pagina rustiger maken" (double-click the name to rename it) with the branch button on the right.
    private func header(_ run: WorkspaceRun) -> some View {
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
            if let fraction = run.usage.contextFraction, fraction > 0.6 {
                Text("ctx \(Int((fraction * 100).rounded()))%")
                    .font(NookTheme.mono(11, .medium))
                    .foregroundStyle(fraction > 0.85 ? NookTheme.coral : NookTheme.amber)
                    .help(tr("ws.header.contextHelp"))
            }
            if let headerAccessory { headerAccessory }
            FolderGitButton(directory: run.workingDirectory, agentWorking: run.status.isActive, showChanges: {
                workspace.markReviewed(runID)
                app.viewModel.open(.changes(runID, file: nil))
            }, onChange: {
                workspace.refreshGit(runID)
            })
            .id(run.workingDirectory)
        }
        .font(NookTheme.font(13.5))
        .frame(height: 30)
    }

    /// Everything else you can do with this session: settings for the next turn, retry, archive, delete.
    private func actionsMenu(_ run: WorkspaceRun) -> some View {
        let idle = !run.status.isActive
        let finishKey = FinishedSessions.key(run: run)
        let isFinished = finishedMarks.isFinished(key: finishKey, idle: idle, lastActive: run.updatedAt)
        return ComposerDropdown(width: 240) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        } content: {
            DropdownRow(symbol: "info.circle", title: tr("agents.run.details")) { app.viewModel.open(.details(runID)) }
            DropdownDivider()
            if run.status.isActive {
                DropdownRow(symbol: "stop.circle", title: tr("ws.action.stop")) { workspace.stop(runID) }
            } else if run.status == .failed || run.status == .stopped {
                DropdownRow(symbol: "arrow.clockwise", title: tr("ws.action.retry")) { workspace.retry(runID) }
            }
            DropdownRow(symbol: isFinished ? "arrow.uturn.backward.circle" : "checkmark.circle",
                        title: isFinished ? tr("agents.finish.reopen") : tr("agents.finish.mark"),
                        disabledReason: idle ? nil : tr("ws.error.busy")) {
                if isFinished { finishedMarks.reopenByUser(finishKey) } else { finishedMarks.mark(finishKey) }
            }
            DropdownRow(symbol: "pencil", title: tr("agents.run.rename")) {
                titleDraft = run.title
                renaming = true
            }
            DropdownRow(symbol: "folder", title: tr("button.openFolder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: run.workingDirectory, isDirectory: true))
            }
            DropdownRow(symbol: "plusminus", title: tr("agents.run.changes"),
                        disabledReason: run.repoRoot == nil ? tr("ws.error.notRepository") : nil) {
                app.viewModel.open(.changes(runID, file: nil))
            }
            DropdownDivider()
            DropdownRow(symbol: "archivebox", title: tr("agents.run.archive"), disabledReason: idle ? nil : tr("ws.error.busy")) {
                workspace.setArchived(runID, true)
                app.viewModel.selectedAgentID = ""
            }
            DropdownRow(symbol: "trash", title: tr("agents.run.delete"), tint: NookTheme.coralSoft,
                        disabledReason: idle ? nil : tr("ws.error.busy")) { confirmDelete = true }
        }
        .help(tr("agents.run.actions"))
    }

    // MARK: Timeline

    private func timeline(_ run: WorkspaceRun) -> some View {
        let events = workspace.timeline(runID).filter { !($0.kind == .system && $0.tool == "launch") }
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if events.isEmpty {
                        Text(tr("agents.run.empty"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    // Finished turns fold to "Worked for …", tool calls in a row to one sentence (after T3Code).
                    ForEach(TimelinePresentation.blocks(events, active: run.status.isActive)) { block in
                        TimelineBlockView(block: block, expanded: openBlocks, toggle: toggleBlock) { event in
                            AnyView(eventRow(event))
                        }
                        .id(block.id)
                    }
                    if run.status.isActive {
                        LiveActivityRow(live: TimelinePresentation.live(events), since: run.turnStartedAt,
                                        waiting: run.status == .waitingApproval, asking: workspace.questions[runID] != nil,
                                        accent: run.provider.color)
                    }
                    if run.status == .failed || run.status == .stopped {
                        recovery(run)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: events.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: events.last?.text.count ?? 0) { _, _ in
                if run.status.isActive { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func recovery(_ run: WorkspaceRun) -> some View {
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
            }
            Spacer(minLength: 6)
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
            PlanCard(text: event.text, canAct: idle && latest && !answered) {
                workspace.configure(runID, mode: .agent)
                workspace.send(runID, text: tr("ws.plan.implementPrompt"))
            }
        } else if event.kind == .user {
            eventView(event)
                .contextMenu {
                    // T3Code's "edit from here": the worktree's files go back to how they were before this message.
                    Button(tr("ws.revert.menu")) {
                        revertError = nil
                        revertTarget = event
                    }
                    .disabled(!workspace.canRevert(runID, before: event.date))
                }
        } else {
            eventView(event)
        }
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
            guard !text.isEmpty, !active else { return }
            draft = ""
            workspace.send(runID, text: text)
        }
        // Codex over app-server and Claude Code take a new message during the turn (steering); others get it after the turn.
        let steers = active && workspace.canSteer(runID)
        let queue = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            draft = ""
            if !(steers && workspace.steer(runID, text: text)) { workspace.enqueue(runID, text: text) }
        }
        return VStack(alignment: .leading, spacing: 5) {
            UsageLimitBanner(run: run)
            if let waiting = workspace.queued[runID], !waiting.isEmpty {
                QueuedMessagesStrip(messages: waiting, remove: { workspace.removeQueued(runID, at: $0) },
                                    sendNow: active ? nil : { workspace.sendQueuedNow(runID) })
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
                modelMenu(run)
                ComposerDivider()
                modeMenu(run)
                ComposerDivider()
                permissionMenu(run)
                actionsMenu(run)
            }
            // While it works, what you type waits in line and goes out when the turn is done.
            .queueing(active ? queue : nil, label: steers ? tr("compose.steer") : tr("compose.queue"),
                      symbol: steers ? "arrow.turn.down.right" : "text.append")
            .images($images)
            if !active, run.mode == .plan {
                Text(tr("agents.run.planHint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    /// The agent with its account, and the model for the next turn (T3Code's model picker, for this session's agent).
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let account = profile.map { AccountLabel.name($0, app: app) }
        let model = run.model.isEmpty ? nil : app.modelName(run.model, for: run.provider)
        return ComposerDropdown(width: 296) {
            ComposerPill(agent: run.provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [run.provider.displayName, account, model].compactMap { $0 }.joined(separator: " · "))
        } content: {
            AgentModelPicker(providers: [run.provider], provider: run.provider, profileID: nil, model: run.model) { _, _, option in
                if let option { workspace.configure(runID, model: option) }
            }
        }
        .disabled(run.status.isActive)
        .help(run.resolvedModel ?? tr("ws.new.model"))
    }

    private func modeMenu(_ run: WorkspaceRun) -> some View {
        ModeToggle(mode: Binding(get: { run.mode }, set: { workspace.configure(runID, mode: $0) }))
            .disabled(run.status.isActive)
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
        .disabled(run.status.isActive || run.mode == .plan)
        .help(run.permission.help(for: run.provider))
    }
}
