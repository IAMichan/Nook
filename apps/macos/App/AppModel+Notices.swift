import Foundation

/// The notice history under the bell in the panel (`NoticeCenter`): what Nook told you, kept so a card that closed
/// before you looked can still be read, and opened where it came from.
extension AppModel {
    /// Keeps a notice in the history. Called where Nook decides to tell you something by himself, before the card,
    /// strip or banner is shown, so a notice held back (quiet during a meeting, a busy notch, "only in the list") is kept
    /// as well. `source` and `app` name where it comes from: an app switched off in Settings › Notifications is silent
    /// here too (its own tab still has it). Without them (a permission request) it is always kept.
    func logNotice(_ kind: NoticeEntry.Kind, title: String, detail: String = "", context: String = "",
                   target: NoticeEntry.Target = .nowhere, key: String? = nil, source: NoticeSource? = nil, app: String = "") {
        guard !demoMode else { return }
        if let source, !settings.noticeRules.isOn(source, app: app) { return }
        NoticeHistory.shared.record(kind, title: title, detail: detail, context: context, target: target, key: key)
    }

    /// Shows a notice the way Settings › Notifications says, the same for every source: as a card, one slim line, a
    /// macOS notification, or not at all (only in the history). `card` and `strip` draw it on the notch; `open` is what
    /// a click on its macOS notification brings up (the card when nil). Nothing pops up, and nothing sounds, for an app
    /// switched off, a source set to "only in the list", or while you are in a meeting or share your screen and chose
    /// quiet for it. Log the notice with `logNotice` first: the history keeps it whatever happens here.
    @discardableResult
    func deliverNotice(_ source: NoticeSource, app: String = "", id: String, title: String, subtitle: String = "",
                       body: String = "", sound: NookSound? = nil, watching: Bool = false,
                       card: @escaping () -> Void, strip: @escaping () -> Void,
                       open: (() -> Void)? = nil) -> NoticeDecision {
        let decision = settings.noticeRules.decide(source, app: app, quiet: quiet.silent, watching: watching)
        guard let style = decision.style else { return decision }
        if let sound { NookSound.play(sound) }
        switch style {
        case .card, .off:
            card()
        case .strip:
            strip()
        case .system:
            SystemNotifier.shared.notice(id: id, title: title, subtitle: subtitle, body: body, open: open ?? card,
                                         fallback: card)
        }
        return decision
    }

    /// Whether a notice may take the notch now: it rests (or shows something passing, a nudge or a moment), or shows an
    /// earlier agent notice that gives way to the newer one. Anything you opened or that waits on you stays.
    var notchFreeForNotice: Bool {
        switch viewModel.state {
        case .idle, .music, .track, .done, .nudge, .moment: return true
        case .card(let shown): return shown.id.hasPrefix("agentstatus-")
        default: return false
        }
    }

    /// Whether Nook asks macOS for permission to notify: some source shows as macOS notifications.
    func requestNotificationAccessIfNeeded() {
        if settings.noticeRules.usesSystem { SystemNotifier.shared.requestAccess() }
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
        case .chat(let id):
            showChats(ChatsFocus(chat: id))
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
