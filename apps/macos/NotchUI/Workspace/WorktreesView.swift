import SwiftUI

/// All repository worktrees: associated session, modified files, and available actions.
struct WorktreesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @State private var confirm: WorktreeRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("ws.worktrees.title")).font(NookTheme.TextStyle.heading)
                    Text(tr("ws.worktrees.subtitle")).font(NookTheme.TextStyle.detail).foregroundStyle(WS.secondary)
                }
                Spacer()
                if workspace.worktreesLoading { ProgressView().controlSize(.small) }
                Button { workspace.refreshWorktrees() } label: { Label(tr("ws.git.refresh"), systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .padding(18)
            Divider()
            if workspace.gitAvailable == false {
                WSEmptyState(symbol: "exclamationmark.triangle", title: tr("ws.worktrees.noGitTitle"), message: tr("ws.error.noGit"))
            } else if workspace.worktreeRows.isEmpty && !workspace.worktreesLoading {
                WSEmptyState(symbol: "arrow.triangle.branch", title: tr("ws.worktrees.emptyTitle"), message: tr("ws.worktrees.emptyMessage"))
            } else {
                Table(workspace.worktreeRows) {
                    TableColumn(tr("ws.worktrees.col.worktree")) { row in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(URL(fileURLWithPath: row.worktree.path).lastPathComponent).font(NookTheme.TextStyle.body)
                            Text(AgentPathFormat.tilde(row.worktree.path)).font(NookTheme.mono(10.5)).foregroundStyle(WS.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn(tr("ws.worktrees.col.branch")) { row in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(row.worktree.branch ?? tr("ws.new.detached")).font(NookTheme.mono(11.5))
                            if let base = row.baseBranch { Text("← \(base)").font(NookTheme.mono(10.5)).foregroundStyle(WS.tertiary) }
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn(tr("ws.worktrees.col.session")) { row in
                        sessionCell(row)
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn(tr("ws.worktrees.col.changes")) { row in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(row.changedFiles.map { $0 == 0 ? tr("ws.inspector.clean") : tr("ws.inspector.filesChanged", $0) } ?? tr("ws.unavailable"))
                                .foregroundStyle((row.changedFiles ?? 0) > 0 ? NookTheme.amber : WS.secondary)
                            if let ahead = row.ahead, let behind = row.behind {
                                Text(tr("ws.inspector.aheadBehind", ahead, behind)).foregroundStyle(WS.tertiary)
                            }
                        }
                        .font(NookTheme.TextStyle.detail)
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("") { row in
                        actions(row)
                    }
                    .width(min: 120, ideal: 140)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .onAppear { workspace.refreshWorktrees() }
        .confirmationDialog(tr("ws.worktree.removeTitle"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { row in
            if (row.changedFiles ?? 0) > 0 {
                Button(tr("ws.worktree.removeForce"), role: .destructive) { remove(row, force: true) }
            } else {
                Button(tr("ws.worktree.remove"), role: .destructive) { remove(row, force: false) }
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: { row in
            Text((row.changedFiles ?? 0) > 0 ? tr("ws.worktree.removeDirty", row.changedFiles ?? 0) : tr("ws.worktree.removeClean"))
        }
    }

    @ViewBuilder
    private func sessionCell(_ row: WorktreeRow) -> some View {
        if let run = row.runIDs.compactMap({ workspace.run($0) }).first {
            Button {
                workspace.selectedRunID = run.id
                app.viewModel.selectedAgentID = "run:" + run.id.uuidString
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    StatusBadge(status: run.status, compact: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(NookTheme.TextStyle.detail).lineLimit(1)
                        HStack(spacing: NookTheme.Spacing.xs) {
                            AgentLogo(run.provider.kind, size: 10)
                            Text("\(run.provider.kind.shortName) · \(NookDates.ago(run.updatedAt))")
                        }
                        .font(NookTheme.TextStyle.caption).foregroundStyle(WS.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(tr("ws.worktrees.openSession"))
        } else {
            Text(row.worktree.isMain ? tr("ws.worktrees.main") : tr("ws.worktrees.noSession"))
                .font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
        }
    }

    private func actions(_ row: WorktreeRow) -> some View {
        let active = row.runIDs.compactMap { workspace.run($0) }.contains { $0.status.isActive }
        return HStack(spacing: NookTheme.Spacing.xs) {
            Button { workspace.openInEditor(row.worktree.path) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .help(tr("ws.action.openEditor"))
            Button { workspace.openTerminal(row.worktree.path) } label: { Image(systemName: "terminal") }
                .help(tr("ws.action.openTerminal"))
            if !row.worktree.isMain {
                Button(role: .destructive) { confirm = row } label: { Image(systemName: "trash") }
                    .help(active ? tr("ws.error.busy") : tr("ws.worktree.remove"))
                    .disabled(active || row.worktree.locked)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func remove(_ row: WorktreeRow, force: Bool) {
        Task {
            do {
                try await workspace.removeWorktree(repo: row.repoRoot, path: row.worktree.path, force: force)
                ToastCenter.shared.success(tr("ws.worktree.removed"))
            } catch let failure {
                ToastCenter.shared.error(failure, title: tr("ws.worktree.removeFailed"))
            }
        }
    }
}
