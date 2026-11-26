import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The confirmations before going back to an earlier message, editing one, or deleting the session, and an approval.
extension AgentRunPanel {
    /// Rewind: back to before a message of yours, with the files and the conversation, only the files, or only the
    /// conversation, as far as this session can (`WorkspaceManager.rewindScopes`).
    func revertConfirmation(_ target: RunEvent) -> some View {
        let scopes = workspace.rewindScopes(runID, before: target.date)
        let message = ToolSummary.oneLine(target.text, 60)
        return AdaptiveActionRow(spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("ws.rewind.confirm"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(revertError ?? Self.rewindDetail(scopes, message: message))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(revertError == nil ? NookTheme.textSecondary : NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            NookGhostButton(title: tr("button.cancel")) { revertTarget = nil }
            ForEach(Array(scopes.enumerated()), id: \.element) { index, scope in
                if index == 0 {
                    NookPrimaryButton(title: reverting ? tr("ws.revert.working") : Self.rewindTitle(scope)) { rewind(target, scope) }
                } else {
                    NookGhostButton(title: Self.rewindTitle(scope)) { rewind(target, scope) }
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
    }

    private static func rewindTitle(_ scope: RewindScope) -> String {
        switch scope {
        case .everything: return tr("ws.rewind.everything")
        case .files: return tr("ws.rewind.files")
        case .conversation: return tr("ws.rewind.conversation")
        }
    }

    /// What each choice does, for the choices there are.
    private static func rewindDetail(_ scopes: [RewindScope], message: String) -> String {
        if scopes.isEmpty { return tr("ws.edit.unavailable") }
        if scopes == [.files] { return tr("ws.rewind.detailFiles", message) }
        if scopes == [.conversation] { return tr("ws.rewind.detailConversation", message) }
        return tr("ws.rewind.detail", message)
    }

    private func rewind(_ target: RunEvent, _ scope: RewindScope) {
        guard !reverting else { return }
        reverting = true
        Task {
            do {
                try await workspace.rewind(runID, before: target.date, scope: scope)
                revertTarget = nil
            } catch {
                revertError = error.localizedDescription
            }
            reverting = false
        }
    }

    /// "Edit from here": go back to before the message, keeping the files as they are or putting them back too (only
    /// where they can go back, see `canRevert`), then the message and its pictures are in the composer again.
    func editConfirmation(_ target: RunEvent) -> some View {
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

    // MARK: Approval

    func approval(_ run: WorkspaceRun, _ pending: PendingPermission, more: Int) -> some View {
        let request = ApprovalCenter.make(pending, run: run)
        return ApprovalView(approval: request, more: more, inline: true, onDecide: { app.approvals.decide(request, $0) },
                            onSecret: { app.approvals.allow(request, secret: $0) },
                            onDenyWithReason: { app.approvals.decide(request, .deny, reason: $0) })
    }

    /// Inline instead of a dialog: the notch is a panel, not a window that sheets can attach to.
    func deleteConfirmation(_ run: WorkspaceRun) -> some View {
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
}
