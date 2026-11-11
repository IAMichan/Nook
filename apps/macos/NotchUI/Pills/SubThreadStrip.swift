import SwiftUI

/// Above a session's composer: the tasks it delegated (`delegate_task`), the way t3code
/// shows a thread's subagents. A row opens the sub-thread; one that ended stays until your next message here.
struct SubThreadStrip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    let threads: [WorkspaceRun]

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(threads, id: \.id) { thread in row(thread) }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, 7)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
    }

    private func row(_ thread: WorkspaceRun) -> some View {
        let asks = !(workspace.questions[thread.id] ?? []).isEmpty
        return Button {
            app.viewModel.selectedAgentID = "run:" + thread.id.uuidString
        } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                if asks {
                    Image(icon: "questionmark.bubble").font(NookTheme.font(11, .semibold)).foregroundStyle(NookTheme.iris)
                } else if thread.status.isActive {
                    ProgressView().controlSize(.mini).frame(width: 12)
                } else {
                    Image(icon: Self.symbol(thread.status)).font(NookTheme.font(11, .semibold))
                        .foregroundStyle(thread.status == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                        .frame(width: 12)
                }
                Text(tr("ws.subthread.strip")).foregroundStyle(NookTheme.textTertiary)
                Text(thread.title)
                    .foregroundStyle(NookTheme.paper.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if asks {
                    Text(tr("ws.subthread.asks")).foregroundStyle(NookTheme.iris)
                } else if let state = Self.stateKey(thread.status) {
                    Text(tr(state)).foregroundStyle(thread.status == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                }
                Text(thread.provider.displayName).foregroundStyle(NookTheme.textTertiary)
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("ws.subthread.open"))
    }

    private static func symbol(_ status: RunStatus) -> String {
        switch status {
        case .failed: return "xmark.circle"
        case .stopped: return "stop.circle"
        case .completed, .preparing, .running, .waitingApproval: return "checkmark.circle"
        }
    }

    /// What an ended task says beside its title; nil while it works.
    private static func stateKey(_ status: RunStatus) -> String? {
        switch status {
        case .completed: return "ws.subthread.done"
        case .failed: return "ws.subthread.failed"
        case .stopped: return "ws.subthread.stopped"
        case .preparing, .running, .waitingApproval: return nil
        }
    }
}
