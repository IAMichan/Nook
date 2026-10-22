import SwiftUI

/// Workspace inspector: folder, branch and worktree, changes and Git, session usage and permissions.
struct RunInspector: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    /// Shown inside the notch: changes, commit and pull request open as notch tasks instead of sheets.
    var embedded = false
    @State private var changes: GitFileChange?
    @State private var showCommit = false
    @State private var showPullRequest = false
    @State private var confirmRemove = false
    @State private var busy = false

    var body: some View {
        if let run = workspace.run(runID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workspaceSection(run)
                    changesSection(run)
                    usageSection(run)
                    sessionSection(run)
                }
                .padding(16)
            }
            .scrollIndicators(embedded ? .never : .automatic)
            .background(embedded ? Color.clear : WS.sidebar)
            .sheet(item: $changes) { file in ChangesSheet(runID: runID, initialFile: file) }
            .sheet(isPresented: $showCommit) { CommitSheet(runID: runID) }
            .sheet(isPresented: $showPullRequest) { PullRequestSheet(runID: runID) }
            .confirmationDialog(tr("ws.worktree.removeTitle"), isPresented: $confirmRemove) {
                let dirty = (workspace.git[runID]?.status?.files.count ?? 0) > 0
                if dirty {
                    Button(tr("ws.worktree.removeForce"), role: .destructive) { remove(force: true) }
                } else {
                    Button(tr("ws.worktree.remove"), role: .destructive) { remove(force: false) }
                }
                Button(tr("button.cancel"), role: .cancel) {}
            } message: {
                let count = workspace.git[runID]?.status?.files.count ?? 0
                Text(count > 0 ? tr("ws.worktree.removeDirty", count) : tr("ws.worktree.removeClean"))
            }
        }
    }

    // MARK: Working directory

    private func workspaceSection(_ run: WorkspaceRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.inspector.workspace"))
            InfoRow(label: tr("ws.inspector.project"), value: run.projectName)
            InfoRow(label: tr("ws.inspector.folder"), value: AgentPathFormat.tilde(run.workingDirectory), mono: true)
            if run.repoRoot == nil {
                InfoRow(label: "Git", value: tr("ws.inspector.noRepo"))
            } else {
                InfoRow(label: tr("ws.inspector.branch"), value: workspace.git[runID]?.status?.branch ?? run.branch, mono: true)
                if run.isolation == .worktree {
                    InfoRow(label: tr("ws.inspector.base"), value: run.baseBranch, mono: true)
                    InfoRow(label: "Worktree", value: workspace.worktreeExists(run) ? tr("ws.inspector.worktreeIsolated") : tr("ws.inspector.worktreeRemoved"))
                } else {
                    InfoRow(label: tr("ws.inspector.isolation"), value: tr("ws.inspector.sharedFolder"),
                            help: tr("ws.inspector.sharedFolderHelp"))
                }
                if let divergence = workspace.git[runID]?.divergence {
                    InfoRow(label: tr("ws.inspector.divergence"), value: tr("ws.inspector.aheadBehind", divergence.ahead, divergence.behind))
                }
                if let status = workspace.git[runID]?.status, status.upstream != nil {
                    InfoRow(label: "Upstream", value: "\(status.upstream ?? "") (↑\(status.ahead) ↓\(status.behind))", mono: true)
                }
            }
            HStack(spacing: 6) {
                Button(tr("ws.action.openEditor")) { workspace.openInEditor(run.workingDirectory) }
                Button(tr("ws.action.openTerminal")) { workspace.openTerminal(run.workingDirectory) }
                Button { workspace.revealInFinder(run.workingDirectory) } label: { Image(systemName: "folder") }
                    .help(tr("ws.action.reveal"))
            }
            .controlSize(.small)
            .disabled(!FileManager.default.fileExists(atPath: run.workingDirectory))
        }
    }

    // MARK: Changes

    @ViewBuilder
    private func changesSection(_ run: WorkspaceRun) -> some View {
        if run.repoRoot != nil {
            let snapshot = workspace.git[runID]
            let files = snapshot?.status?.files ?? []
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WSSectionTitle(title: tr("ws.inspector.changes"), trailing: files.isEmpty ? nil : "\(files.count)")
                    ToolbarIconButton("arrow.clockwise", tr("ws.git.refresh"), height: 20, width: 20,
                                      enabled: snapshot?.loading != true) { workspace.refreshGit(runID) }
                }
                if let error = snapshot?.error {
                    Text(error).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.coralSoft)
                } else if snapshot == nil || (snapshot?.loading == true && snapshot?.status == nil) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4).fill(WS.subtle).frame(height: 14)
                    }
                } else if files.isEmpty {
                    Text(tr("ws.inspector.clean")).font(NookTheme.font(12)).foregroundStyle(WS.tertiary)
                } else {
                    let added = files.compactMap(\.added).reduce(0, +)
                    let removed = files.compactMap(\.removed).reduce(0, +)
                    HStack(spacing: 8) {
                        Text("+\(added)").foregroundStyle(NookTheme.mint)
                        Text("−\(removed)").foregroundStyle(NookTheme.coral)
                        Text(tr("ws.inspector.filesChanged", files.count)).foregroundStyle(WS.tertiary)
                    }
                    .font(NookTheme.mono(11.5))
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(files.prefix(40)) { file in
                            Button { review(file) } label: { FileChangeRow(file: file) }
                                .buttonStyle(.plain)
                        }
                        if files.count > 40 {
                            Text(tr("ws.inspector.moreFiles", files.count - 40)).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                        }
                    }
                }
                GitQuickButton(runID: runID)
                HStack(spacing: 6) {
                    Button(tr("ws.git.review")) {
                        if let first = files.first { review(first) }
                    }
                    .disabled(files.isEmpty)
                    Button(tr("ws.git.commit")) { if embedded { app.viewModel.open(.commit(runID)) } else { showCommit = true } }
                        .disabled(files.isEmpty || run.status.isActive)
                        .help(run.status.isActive ? tr("ws.error.busy") : tr("ws.git.commit.help"))
                    Button(tr("ws.git.push")) { push() }
                        .disabled(busy || run.status.isActive || snapshot?.status?.detached == true)
                        .help(tr("ws.git.push.help"))
                    Menu {
                        Button(tr("ws.git.pullRequest")) { if embedded { app.viewModel.open(.pullRequest(runID)) } else { showPullRequest = true } }
                        if run.isolation == .worktree && workspace.worktreeExists(run) {
                            Divider()
                            Button(tr("ws.worktree.remove"), role: .destructive) { confirmRemove = true }
                                .disabled(run.status.isActive)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help(tr("a11y.more"))
                    .accessibilityLabel(tr("a11y.more"))
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Usage

    private func usageSection(_ run: WorkspaceRun) -> some View {
        let caps = run.provider.capabilities
        let usage = run.usage
        return VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.inspector.usage"))
            InfoRow(label: tr("ws.usage.input"), value: WSFormat.tokens(usage.inputTokens))
            InfoRow(label: tr("ws.usage.output"), value: WSFormat.tokens(usage.outputTokens))
            InfoRow(label: tr("ws.usage.cacheRead"), value: caps.reportsCacheTokens ? WSFormat.tokens(usage.cacheReadTokens) : nil)
            if run.provider == .claude {
                InfoRow(label: tr("ws.usage.cacheWrite"), value: WSFormat.tokens(usage.cacheWriteTokens))
            }
            InfoRow(label: tr("ws.usage.context"), value: contextText(usage, caps: caps), help: tr("ws.header.contextHelp"))
            if workspace.settings.showCost {
                InfoRow(label: tr("ws.usage.cost"),
                        value: caps.reportsCost ? WSFormat.cost(usage.reportedCostUSD) : nil,
                        help: caps.reportsCost ? tr("ws.usage.costReportedHelp") : tr("ws.usage.costUnavailable", run.provider.displayName))
            }
            InfoRow(label: tr("ws.usage.turns"), value: "\(usage.turns)")
            InfoRow(label: tr("ws.usage.active"), value: usage.activeSeconds > 0 ? AgentPathFormat.duration(usage.activeSeconds) : nil)
            Text(caps.reportsCost ? tr("ws.usage.note.claude") : tr("ws.usage.note.codex"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(WS.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if run.provider == .claude, let profile = app.profile(for: run), let plan = app.hub.subscriptionUsage(for: profile) {
                // Subscription limit for account (entire account, not just this session), parsed from status line.
                InfoRow(label: tr("ws.usage.accountQuota"), value: plan.label, help: tr("ws.usage.accountQuotaHelp"))
            }
        }
    }

    private func contextText(_ usage: RunUsage, caps: ProviderCapabilities) -> String? {
        guard let tokens = usage.contextTokens else { return nil }
        if let window = usage.contextWindow, window > 0 {
            return "\(TokenTally.format(tokens)) / \(TokenTally.format(window)) (\(Int((Double(tokens) / Double(window) * 100).rounded()))%)"
        }
        return TokenTally.format(tokens) + " · " + tr("ws.usage.windowUnknown")
    }

    // MARK: Session

    private func sessionSection(_ run: WorkspaceRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle(title: tr("ws.inspector.session"))
            InfoRow(label: tr("ws.inspector.status"), value: run.status.label)
            InfoRow(label: tr("ws.inspector.agent"), value: run.provider.displayName)
            InfoRow(label: tr("ws.inspector.account"), value: app.profile(for: run).map { AccountLabel.line($0, app: app) },
                    help: tr("ws.inspector.accountPinned"))
            InfoRow(label: tr("ws.inspector.model"), value: run.resolvedModel ?? (run.model.isEmpty ? tr("ws.model.default") : run.model), mono: true)
            InfoRow(label: tr("ws.inspector.mode"), value: run.mode.label)
            InfoRow(label: tr("ws.inspector.permissions"), value: run.permission.label, help: run.permission.help(for: run.provider))
            InfoRow(label: tr("ws.inspector.approvals"), value: run.provider.capabilities.approvals ? tr("ws.inspector.approvalsInNook") : nil,
                    help: run.provider.capabilities.approvals ? nil : tr("ws.inspector.approvalsUnavailable"))
            InfoRow(label: tr("ws.inspector.started"), value: run.createdAt.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: tr("ws.inspector.lastActive"), value: NookDates.ago(run.updatedAt))
            InfoRow(label: tr("ws.inspector.sessionID"), value: run.providerSessionID, mono: true,
                    help: tr("ws.inspector.sessionIDHelp"))
            if !run.instructions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("ws.inspector.instructions")).font(NookTheme.font(12)).foregroundStyle(WS.tertiary)
                    Text(run.instructions).font(NookTheme.font(12)).foregroundStyle(WS.secondary).textSelection(.enabled)
                }
            }
            Text(tr("ws.inspector.isolationNote"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(WS.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func review(_ file: GitFileChange) {
        workspace.markReviewed(runID)
        if embedded { app.viewModel.open(.changes(runID, file: file.path)) } else { changes = file }
    }

    private func push() {
        busy = true
        Task {
            do {
                try await workspace.push(runID)
                ToastCenter.shared.gitQuick(.push, result: .success(nil))
            } catch {
                ToastCenter.shared.gitQuick(.push, result: .failure(error))
            }
            busy = false
        }
    }

    private func remove(force: Bool) {
        Task {
            do {
                try await workspace.removeWorktree(runID, force: force)
                ToastCenter.shared.success(tr("ws.worktree.removed"))
            } catch {
                ToastCenter.shared.error(error, title: tr("ws.worktree.removeFailed"))
            }
        }
    }
}

struct FileChangeRow: View {
    let file: GitFileChange

    var body: some View {
        HStack(spacing: 6) {
            Text(file.kind.letter)
                .font(NookTheme.mono(10.5, .bold))
                .foregroundStyle(file.kind.color)
                .frame(width: 12)
            Text(file.path)
                .font(NookTheme.mono(11.5))
                .foregroundStyle(WS.text)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let added = file.added { Text("+\(added)").foregroundStyle(NookTheme.mint.opacity(0.85)) }
            if let removed = file.removed, removed > 0 { Text("−\(removed)").foregroundStyle(NookTheme.coral.opacity(0.85)) }
        }
        .font(NookTheme.mono(10.5))
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
