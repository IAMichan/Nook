import SwiftUI
import AppKit

/// Single git action button for a session: commit, push and pull request in one go, as far as the branch needs. The
/// agent writes the commit message and the pull request; pushing to the default branch asks first.
struct GitQuickButton: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    @State private var state: GitQuickState?
    @State private var progress: String?
    @State private var error: String?
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
                    Button(tr("ws.quick.viewPR")) { NSWorkspace.shared.open(link) }
                }
            }
            if let error {
                Text(error)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
        error = nil
        progress = tr(action.labelKey)
        Task {
            do {
                if let link = try await workspace.performQuickGit(runID, action, progress: { progress = $0 }),
                   link.host == "github.com", link.path.contains("/pull/") {
                    NSWorkspace.shared.open(link)
                }
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
            state = await workspace.quickGitState(runID)
        }
    }
}
