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
    ///
    /// While the main window is open, a card or a strip is not drawn on the notch: the notice is a toast in the window,
    /// as the result of something you did there ("Pull request merged"), and its button does what `open` does (the card
    /// when nil). `kind` colors that toast; `window` replaces `open` there, when opening means something else in the
    /// window than from a macOS notification.
    ///
    /// Notices keep their distance (`NoticePacer`): one thing (`pace`, the `id` when nil) pops up once in a while, and
    /// a burst from many sources ends in the history instead of on the notch. `urgent`: it waits on you, and always shows.
    /// A card of the same `id` that is on the notch already is redrawn, not counted as a new pop-up. `stillNew`: a
    /// notice the pacer held back pops up once the pacer lets it (`NoticePacer.nextPermitted`, within
    /// `heldNoticeLimit`), if `stillNew` then says it still has news (a chat not read meanwhile), instead of only waiting
    /// in the history: someone who wrote right after an earlier pop-up is still told, a moment later.
    @discardableResult
    func deliverNotice(_ source: NoticeSource, app: String = "", id: String, pace: String? = nil, urgent: Bool = false,
                       title: String, subtitle: String = "",
                       body: String = "", sound: NookSound? = nil, watching: Bool = false, kind: NookToastKind = .info,
                       card: @escaping () -> Void, strip: @escaping () -> Void,
                       open: (() -> Void)? = nil, window: (() -> Void)? = nil,
                       stillNew: (() -> Bool)? = nil) -> NoticeDecision {
        let decision = settings.noticeRules.decide(source, app: app, quiet: quiet.silent, watching: watching)
        guard let style = decision.style else { return decision }
        var onNotch = false
        if case .card(let shown) = viewModel.state { onNotch = shown.id == id }
        let key = pace ?? id
        guard onNotch || noticePacer.allow(key: key, urgent: urgent) else {
            if let stillNew {
                holdNotice(key: key, stillNew: stillNew) { [weak self] in
                    _ = self?.deliverNotice(source, app: app, id: id, pace: pace, urgent: urgent, title: title, subtitle: subtitle,
                                            body: body, sound: sound, watching: watching, kind: kind, card: card, strip: strip,
                                            open: open, window: window, stillNew: stillNew)
                }
            }
            return .historyOnly
        }
        // Shown now: a pop-up still held for the same thing has nothing left to say.
        Self.heldNotices.removeValue(forKey: key)?.cancel()
        if let sound { NookSound.play(sound) }
        if style != .system, WorkspaceWindowController.shared.isOpen {
            let detail = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ")
            ToastCenter.shared.show(title, detail: detail, kind: kind,
                                    action: NookToastAction(title: tr("button.view"), perform: window ?? open ?? card))
            return decision
        }
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

    /// Notices the pacer held back that pop up once it lets them, by their pace key: a newer one about the same thing
    /// replaces the one before.
    private static var heldNotices: [String: Task<Void, Never>] = [:]
    /// How long a held notice waits at most. One the pacer holds longer (a burst from many sources) stays in the history
    /// only, as before: a pop-up ten minutes after the message would be news to no one.
    static let heldNoticeLimit: TimeInterval = NoticePacer.sameKeyGap

    private func holdNotice(key: String, stillNew: @escaping () -> Bool, deliver: @escaping () -> Void) {
        Self.heldNotices.removeValue(forKey: key)?.cancel()
        let wait = noticePacer.nextPermitted(key: key).timeIntervalSinceNow
        guard wait <= Self.heldNoticeLimit else { return }
        Self.heldNotices[key] = Task { @MainActor in
            // A moment past the time itself, so the pacer's own comparison lets it through.
            try? await Task.sleep(for: .seconds(max(wait, 0) + 0.5))
            guard !Task.isCancelled else { return }
            Self.heldNotices[key] = nil
            guard stillNew() else { return }
            deliver()
        }
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
        case .chat(let id):
            // The chat's card, as it came up; the Chats tab for a chat Nook no longer holds.
            if ChatCaptureService.shared.loadedInbox.threads[id] != nil { presentChat(id, asked: true) } else { showChats(ChatsFocus(chat: id)) }
        case .nowhere:
            break
        }
    }
}
