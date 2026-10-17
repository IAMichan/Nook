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
    @State private var expanded: Set<UUID> = []
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
                if confirmDelete {
                    deleteConfirmation(run)
                } else {
                    composer(run)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                workspace.loadTimeline(runID)
                if run.repoRoot != nil { workspace.refreshGit(runID) }
                focused = true
            }
            .onChange(of: runID) { _, _ in
                workspace.loadTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID) }
                draft = ""
                renaming = false
                confirmDelete = false
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
        return Menu {
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
            Button(tr("button.openFolder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: run.workingDirectory, isDirectory: true))
            }
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .composerMenu()
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
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            expanded: expanded.contains(event.id),
                            toggle: { toggle(event.id) },
                            openFile: { path in app.viewModel.open(.changes(runID, file: path)) },
                            decide: { decision in
                                if let request = event.callID { workspace.decide(runID, requestID: request, decision) }
                            }
                        )
                        .id(event.id)
                    }
                    if run.status.isActive {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(run.status == .waitingApproval ? tr("ws.timeline.waiting") : tr("ws.timeline.working"))
                                .font(NookTheme.font(12))
                                .foregroundStyle(NookTheme.textSecondary)
                        }
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
        return VStack(alignment: .leading, spacing: 5) {
            SessionComposer(
                text: $draft,
                prompt: active ? tr("agents.run.busyPrompt", run.provider.kind.shortName) : tr("agents.run.prompt"),
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
            if !active, run.mode == .plan {
                Text(tr("agents.run.planHint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    /// The agent with its account, and the model for the next turn.
    private func modelMenu(_ run: WorkspaceRun) -> some View {
        let profile = app.profile(for: run)
        let account = profile.map { AccountLabel.name($0, app: app) }
        let model = run.model.isEmpty ? nil : run.model
        return Menu {
            Section(tr("ws.new.model")) {
                ForEach(app.models(for: run.provider), id: \.self) { option in
                    Button {
                        workspace.configure(runID, model: option)
                    } label: {
                        let title = option.isEmpty ? tr("ws.model.default") : option
                        if run.model == option { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: {
            ComposerPill(agent: run.provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [run.provider.displayName, account, model].compactMap { $0 }.joined(separator: " · "))
        }
        .composerMenu()
        .disabled(run.status.isActive)
        .help(run.resolvedModel ?? tr("ws.new.model"))
    }

    private func modeMenu(_ run: WorkspaceRun) -> some View {
        Menu {
            ForEach(ExecutionMode.allCases) { mode in
                Button {
                    workspace.configure(runID, mode: mode)
                } label: {
                    if run.mode == mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                }
            }
        } label: {
            ComposerPill(symbol: run.mode == .plan ? "list.bullet.clipboard" : "sparkles", text: run.mode.label)
        }
        .composerMenu()
        .disabled(run.status.isActive)
        .help(run.mode.help)
    }

    private func permissionMenu(_ run: WorkspaceRun) -> some View {
        Menu {
            ForEach(run.provider.capabilities.policies) { policy in
                Button {
                    workspace.configure(runID, permission: policy)
                } label: {
                    if run.permission == policy { Label(policy.label, systemImage: "checkmark") } else { Text(policy.label) }
                }
            }
        } label: {
            ComposerPill(symbol: run.permission == .bypass ? "lock.open" : "lock",
                         text: run.mode == .plan ? tr("compose.readOnly") : run.permission.label,
                         tint: run.permission == .bypass && run.mode != .plan ? NookTheme.coralSoft : nil)
        }
        .composerMenu()
        .disabled(run.status.isActive || run.mode == .plan)
        .help(run.permission.help(for: run.provider))
    }
}
