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
                // The agent's connection opens now, so your first message goes straight in.
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

    /// The agent with its account, and the model for the next turn (model picker, for this session's agent).
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
