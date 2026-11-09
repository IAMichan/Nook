import SwiftUI
import AppKit

/// Single git action button for a session: commit, push and pull request in one go, as far as the branch needs. The
/// agent writes the commit message and the pull request; pushing to the default branch asks first.
struct GitQuickButton: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    @State private var state: GitQuickState?
    /// The step of the action under way, kept by the workspace so every view of the session shows it.
    private var progress: String? { workspace.quickGitProgress(runID)?.step }
    @State private var confirmDefault: GitQuickAction?

    var body: some View {
        let active = workspace.run(runID)?.status.isActive == true
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.md) {
                switch state.map(GitQuickResolver.resolve) {
                case .success(let action)?:
                    Button { start(action) } label: {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            if progress != nil { ProgressView().controlSize(.mini) } else { NookSymbol(symbol(action)) }
                            Text(progress ?? tr(action.labelKey))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(progress != nil || active)
                    .help(active ? tr("ws.error.busy") : tr("ws.quick.help"))
                    if progress == nil, let state {
                        // The other way to go: a new branch and pull request of their own for these changes.
                        ForEach(GitQuickResolver.alternatives(state), id: \.labelKey) { other in
                            Button { start(other) } label: {
                                HStack(spacing: NookTheme.Spacing.sm) {
                                    NookSymbol(symbol(other))
                                    Text(tr(other.labelKey))
                                }
                            }
                            .disabled(active)
                            .help(tr("ws.quick.newBranchHint"))
                        }
                    }
                case .failure(let reason)?:
                    Text(tr(reason.key))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(WS.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
            }
            // Where the work goes: onto the open pull request, or a new branch once that one is merged.
            if progress == nil, let state, case .success(let action) = GitQuickResolver.resolve(state),
               let key = GitQuickResolver.destinationKey(state, action: action) {
                Text(tr(key))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(WS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        // Looked at again whenever git does (after a turn, a commit, a refresh).
        .task(id: workspace.git[runID]?.updated) {
            guard progress == nil else { return }
            state = await workspace.quickGitState(runID)
        }
        .confirmationDialog(tr("ws.quick.defaultTitle", state?.branch ?? ""),
                            isPresented: Binding(get: { confirmDefault != nil }, set: { if !$0 { confirmDefault = nil } })) {
            Button(tr("ws.quick.confirm")) { if let action = confirmDefault { perform(action) } }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("ws.quick.defaultMessage", state?.branch ?? ""))
        }
    }

    private func symbol(_ action: GitQuickAction) -> String {
        switch action {
        case .commit: return "checkmark.circle"
        case .commitPush, .push: return "arrow.up.circle"
        case .commitPushPR, .pushPR, .createPR: return PullRequestIcon.generic
        case .branchCommitPushPR, .branchPushPR: return "arrow.triangle.branch"
        case .pull: return "arrow.down.circle"
        }
    }

    private func start(_ action: GitQuickAction) {
        if state?.isDefaultBranch == true && action.pushes && !action.startsBranch {
            confirmDefault = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: GitQuickAction) {
        Task {
            do {
                // A pull request it made stays put in the tray above the composer.
                let link = try await workspace.performQuickGit(runID, action, progress: { _ in })
                ToastCenter.shared.gitQuick(action, result: .success(link))
            } catch {
                ToastCenter.shared.gitQuick(action, result: .failure(error))
            }
            state = await workspace.quickGitState(runID)
        }
    }
}

extension ToastCenter {
    /// The result of a git quick action: what it did (with "View PR" when it opened one), or why it failed.
    func gitQuick(_ action: GitQuickAction, result: Result<URL?, Error>) {
        switch result {
        case .success(let link):
            success(tr(action.doneKey), action: link.map { url in
                NookToastAction(title: tr("ws.quick.viewPR")) { PullRequestViewer.show(url) }
            })
        case .failure(let failure):
            error(failure, title: tr("toast.failed", tr(action.labelKey)))
        }
    }
}

/// Where "View PR" opens a pull request Nook just made: in the session's side panel when Nook can read it (GitHub
/// connected), else in Nook's browser.
@MainActor
enum PullRequestViewer {
    static func show(_ url: URL) {
        if !AppModel.shared.openPullRequestLink(url, beside: true) { BrowserStore.show(url) }
    }
}

/// The git step a finished session's hover card offers: the one its branch needs (commit, push, pull request) with the
/// other way to go under it, as the session panel's commit row. A session Nook runs goes through its workspace, one it
/// only sees (a terminal, another app) through its folder, so every coding agent gets it. Nothing shows while there is
/// nothing to do. Clicks keep the card open: it shows the step under way and asks before pushing to the default branch.
struct HoverCardGitAction: View {
    @ObservedObject private var workspace = AppModel.shared.workspace
    let runID: UUID?
    let directory: String
    @State private var state: GitQuickState?
    /// The repository root of a session Nook only sees.
    @State private var root: String?
    @State private var confirmDefault: GitQuickAction?

    /// The step under way, kept by the workspace so the row, the panel and this card show the same.
    private var progress: String? {
        if let runID { return workspace.quickGitProgress(runID)?.step }
        return workspace.quickGitProgress(folder: root ?? directory)?.step
    }

    private var active: Bool { runID.flatMap { workspace.run($0)?.status.isActive } ?? false }

    var body: some View {
        Group {
            if let progress {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    NookDivider()
                    HStack(spacing: NookTheme.Spacing.md) {
                        ProgressView().controlSize(.mini).frame(width: 16)
                        Text(progress).lineLimit(1)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                }
            } else if let state, !active, case .success(let action) = GitQuickResolver.resolve(state) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    NookDivider()
                    if let confirmDefault {
                        confirmation(confirmDefault, branch: state.branch ?? "")
                    } else {
                        line(action, primary: true)
                        if let key = GitQuickResolver.destinationKey(state, action: action) {
                            Text(tr(key))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(GitQuickResolver.alternatives(state), id: \.labelKey) { other in
                            line(other, primary: false)
                        }
                    }
                }
            }
        }
        // Read when the card opens, and again whenever the workspace reads the session's git.
        .task(id: runID.flatMap { workspace.git[$0]?.updated }) { await load() }
    }

    private func line(_ action: GitQuickAction, primary: Bool) -> some View {
        HoverCardButton(help: primary ? tr("ws.quick.help") : tr("ws.quick.newBranchHint"), closes: false,
                        action: { start(action) }) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: Self.symbol(action))
                    .font(NookTheme.font(11, .medium))
                    .foregroundStyle(primary ? NookTheme.iris : NookTheme.textTertiary)
                    .frame(width: 16)
                Text(tr(action.labelKey))
                    .lineLimit(1)
            }
            .font(primary ? NookTheme.TextStyle.strong : NookTheme.TextStyle.detail)
            .foregroundStyle(primary ? NookTheme.paper : NookTheme.textSecondary)
        }
    }

    /// Pushing to the default branch asks first, in the card.
    private func confirmation(_ action: GitQuickAction, branch: String) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("ws.quick.defaultMessage", branch))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.sm) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("button.cancel")) { confirmDefault = nil }
                SmallPrimaryButton(title: tr("ws.quick.confirm")) { perform(action) }
            }
        }
    }

    private static func symbol(_ action: GitQuickAction) -> String {
        switch action {
        case .commit: return "checkmark.circle"
        case .commitPush, .push: return "arrow.up.circle"
        case .commitPushPR, .pushPR, .createPR: return PullRequestIcon.generic
        case .branchCommitPushPR, .branchPushPR: return "arrow.triangle.branch"
        case .pull: return "arrow.down.circle"
        }
    }

    private func load() async {
        if let runID {
            // Not read yet (a session nobody opened since launch): the workspace reads it, and this runs again then.
            guard workspace.git[runID]?.status != nil else { return workspace.refreshGit(runID, quiet: true) }
            state = await workspace.quickGitState(runID)
        } else {
            let model = FolderGitModel(directory: directory)
            await model.refresh()
            guard let found = model.root, let status = model.status else { state = nil; return }
            root = found
            state = await workspace.quickGitState(folder: found, status: status)
        }
    }

    private func start(_ action: GitQuickAction) {
        // A new branch never lands on the default one, so it needs no confirmation.
        if state?.isDefaultBranch == true && action.pushes && !action.startsBranch { confirmDefault = action } else { perform(action) }
    }

    private func perform(_ action: GitQuickAction) {
        confirmDefault = nil
        let folder = root ?? directory
        Task {
            do {
                let link: URL?
                if let runID {
                    link = try await workspace.performQuickGit(runID, action, progress: { _ in })
                } else {
                    link = try await workspace.performQuickGit(folder: folder, action, progress: { _ in })
                }
                ToastCenter.shared.gitQuick(action, result: .success(link))
            } catch {
                ToastCenter.shared.gitQuick(action, result: .failure(error))
            }
            await load()
        }
    }
}
