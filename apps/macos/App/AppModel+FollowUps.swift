import Foundation

/// Your follow-ups in chats, carried out: "waiting for reply" reminders when their time is up, and messages you scheduled
/// when theirs is. What is due is decided by `ChatFollowUpTick`; this settles the follow-ups with the inbox, tells you, and
/// sends through the same checks and audit as a message you send by hand (`sendChatText` › `runInChat`). The same for
/// every chat app.
extension AppModel {
    /// When the follow-ups were last looked at.
    private static var lastFollowUpTick = Date.distantPast
    /// How many chats the inbox had when notes were last carried over to people's keys.
    private static var carriedNotesChats = -1
    /// Scheduled messages on their way, so a slow send is not started twice.
    private static var sendingScheduled: Set<UUID> = []

    /// Runs with the buddy's half-minute timer, at most once a minute. With nothing to follow up it returns at once.
    func chatFollowUpTick(now: Date = Date()) {
        guard !demoMode, now.timeIntervalSince(Self.lastFollowUpTick) >= ChatFollowUpTick.interval - 1 else { return }
        Self.lastFollowUpTick = now
        let store = ChatFollowUpStore.shared
        // Notes kept under a name before people were matched by address follow them: only while any are left, and only
        // when the inbox has other chats than last time, so a note of someone matched by name costs nothing each minute.
        if store.notes.hasNameKeys {
            let chats = ChatCaptureService.shared.loadedInbox
            if chats.threads.count != Self.carriedNotesChats {
                Self.carriedNotesChats = chats.threads.count
                store.carryOverNotes(with: chats)
            }
        }
        guard ChatFollowUpTick.hasWork(store.follow) else { return }
        let inbox = ChatCaptureService.shared.loadedInbox
        // Answered waits, ended snoozes and chats that are gone are forgotten first (written only when something changed).
        store.settle(with: inbox, now: now)
        let plan = ChatFollowUpTick.plan(store.follow, chats: Set(inbox.threads.keys), now: now)
        guard !plan.isEmpty else { return }
        for chat in plan.reminders { remindWaiting(chat, now: now) }
        for send in plan.sends where !Self.sendingScheduled.contains(send.id) { sendScheduled(send) }
        for send in plan.confirm { confirmScheduled(send) }
    }

    /// "Still no reply from Lisa": once, then again after a day until they answer or you stop waiting.
    private func remindWaiting(_ id: String, now: Date) {
        ChatFollowUpStore.shared.change { $0.acknowledge(chat: id, now: now) }
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[id],
              !ChatNoticeRulesStore.shared.rules.isHidden(id) else { return }
        let token = "chatfollowup-" + id
        let title = tr("chats.followUp.reminder", thread.name)
        let context = Self.chatContext(thread)
        let last = thread.messages.last(where: { !$0.isNotice })?.summary ?? ""
        logNotice(.info, title: title, detail: last, context: context, target: .chat(id), key: token, source: .chats, app: thread.app)
        let open: () -> Void = { [weak self] in self?.presentChat(id, asked: true) }
        deliverNotice(.chats, app: thread.app, id: token, pace: "chat:" + id, title: title, subtitle: context, body: last,
                      card: open,
                      strip: { [weak self] in self?.viewModel.notify(title, button: tr("notices.openChat"), action: open) },
                      open: open,
                      window: { [weak self] in self?.showChats(ChatsFocus(chat: id)) },
                      banner: NoticeBanner(target: .chat(id)))
    }

    /// A message you wrote and scheduled, at its time: your text and your time are your OK, so it goes through the usual
    /// checks and the audit log. When it cannot go, its chat comes up with the text back in the field and why.
    private func sendScheduled(_ send: ChatScheduledSend) {
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[send.chat], let route = chatRoute(for: thread) else {
            return confirmScheduled(send)
        }
        Self.sendingScheduled.insert(send.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { Self.sendingScheduled.remove(send.id) }
            do {
                try await self.sendChatText(send.text, route: route, chat: thread.name, thread: send.chat)
                ChatFollowUpStore.shared.change { $0.cancelScheduled(id: send.id) }
                self.viewModel.finish(tr("whatsapp.sent", thread.name))
            } catch {
                self.confirmScheduled(send, problem: tr("whatsapp.card.notSent", error.localizedDescription))
            }
        }
    }

    /// A scheduled message that is too late to send by itself, or that could not go: its chat's card comes up with the
    /// text in the field, for you to send or drop. It is no longer scheduled.
    private func confirmScheduled(_ send: ChatScheduledSend, problem: String? = nil) {
        ChatFollowUpStore.shared.change { $0.cancelScheduled(id: send.id) }
        guard ChatCaptureService.shared.loadedInbox.threads[send.chat] != nil else {
            viewModel.present(errorCard(problem ?? tr("chats.scheduled.gone")))
            return
        }
        presentChat(send.chat, asked: true)
        let shown = editShownCard(Self.chatCardPrefix + send.chat) {
            $0.draft = send.text
            $0.notice = problem ?? tr("chats.scheduled.late")
        }
        if !shown, let problem { viewModel.present(errorCard(problem)) }
    }
}
