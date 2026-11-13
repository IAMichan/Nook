import SwiftUI

/// The side chats of a session (`/btw`, `/side`), above its composer: each opens with a click, and "Bring back" hands
/// its result to this session (`WorkspaceManager.mergeBack`). They are listed here and nested under this session in the
/// Agents list, never as sessions of their own.
struct SideChatStrip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    let chats: [WorkspaceRun]

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(chats, id: \.id) { chat in row(chat) }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, 7)
        .roundedBackground(NookTheme.composerTray, radius: NookTheme.Radius.card)
    }

    private func row(_ chat: WorkspaceRun) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Button {
                app.viewModel.selectedAgentID = "run:" + chat.id.uuidString
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    if chat.status.isActive {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else {
                        Image(icon: "bubble.left.and.bubble.right").font(NookTheme.font(11, .semibold))
                    }
                    Text(tr("ws.side.strip")).foregroundStyle(NookTheme.textTertiary)
                    Text(chat.task.isEmpty ? chat.title : chat.task)
                        .foregroundStyle(NookTheme.paper.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(tr("ws.side.open"))
            Button(tr("ws.side.bringBack")) { workspace.mergeBack(chat.id) }
                .buttonStyle(.nookPlain)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(workspace.canTransfer(chat.id) ? NookTheme.iris : NookTheme.textTertiary)
                .disabled(!workspace.canTransfer(chat.id))
                .help(tr("ws.side.bringBack.help"))
        }
    }
}
