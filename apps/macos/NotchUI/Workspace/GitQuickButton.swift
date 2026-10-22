import SwiftUI
import AppKit

/// Single git action button for a session: commit, push and pull request in one go, as far as the branch needs. The
/// agent writes the commit message and the pull request; pushing to the default branch asks first.
struct GitQuickButton: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    @State private var state: GitQuickState?
    @State private var progress: String?
    @State private var confirmDefault: GitQuickAction?

    var body: some View {
        let active = workspace.run(runID)?.status.isActive == true
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch state.map(GitQuickResolver.resolve) {
                case .success(let action)?:
                    Button { start(action) } label: {
                        HStack(spacing: 6) {
                            if progress != nil { ProgressView().controlSize(.mini) } else { Image(systemName: symbol(action)) }
                            Text(progress ?? tr(action.labelKey))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(progress != nil || active)
                    .help(active ? tr("ws.error.busy") : tr("ws.quick.help"))
                case .failure(let reason)?:
                    Text(tr(reason.key))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(WS.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
                if let link = workspace.openPullRequests[runID] {
                    Button(tr("ws.quick.viewPR")) { BrowserStore.show(link) }
                }
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
        case .commitPushPR, .pushPR, .createPR: return "arrow.triangle.pull"
        case .pull: return "arrow.down.circle"
        }
    }

    private func start(_ action: GitQuickAction) {
        if state?.isDefaultBranch == true && action.pushes {
            confirmDefault = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: GitQuickAction) {
        progress = tr(action.labelKey)
        Task {
            do {
                // A pull request it made stays put: "View PR" opens it in Nook's browser when you want it.
                let link = try await workspace.performQuickGit(runID, action, progress: { progress = $0 })
                ToastCenter.shared.gitQuick(action, result: .success(link))
            } catch {
                ToastCenter.shared.gitQuick(action, result: .failure(error))
            }
            progress = nil
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
                NookToastAction(title: tr("ws.quick.viewPR")) { BrowserStore.show(url) }
            })
        case .failure(let failure):
            error(failure, title: tr("toast.failed", tr(action.labelKey)))
        }
    }
}
