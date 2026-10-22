import Foundation

/// The notice history under the bell in the panel (`NoticeCenter`): what Nook told you, kept so a card that closed
/// before you looked can still be read, and opened where it came from.
extension AppModel {
    /// Keeps a notice in the history. Called where Nook decides to tell you something by himself, before the card,
    /// strip or banner is shown, so a notice held back (quiet during a meeting, a busy notch) is kept as well.
    func logNotice(_ kind: NoticeEntry.Kind, title: String, detail: String = "", context: String = "",
                   target: NoticeEntry.Target = .nowhere, key: String? = nil) {
        guard !demoMode else { return }
        NoticeHistory.shared.record(kind, title: title, detail: detail, context: context, target: target, key: key)
    }

    /// Opens what an entry in the history is about.
    func openNotice(_ entry: NoticeEntry) {
        switch entry.target {
        case .agent(let id):
            viewModel.selectedAgentID = id
            viewModel.show(.panel(.agents))
        case .run(let id):
            openWorkspace(run: id)
        case .agents:
            viewModel.show(.panel(.agents))
        case .conversation(let id):
            if chat.conversation(id) != nil { openConversation(id) } else { showChat() }
        case .whatsApp(let chat):
            presentWhatsApp(chat, asked: true)
        case .nowhere:
            break
        }
    }

    /// The history's state for an agent's status: done, failed, or waiting on you.
    static func noticeKind(_ status: AgentStatus) -> NoticeEntry.Kind {
        switch status {
        case .done: return .done
        case .failed: return .failed
        default: return .waiting
        }
    }
}
