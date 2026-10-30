// The Chats tab and the chat cards: every chat app in one inbox, every chat answered the same way.
import SwiftUI

/// Chats from every chat app in one list and one kind of card: WhatsApp through the linked phone, Telegram, Slack,
/// Teams, Messages, Snapchat, the chat helper's networks, and what other apps' notifications bring. A chat Nook writes in
/// is answered right there, in the Chats tab and on its card; any other chat's answer is copied for its own app.
extension AppModel {
    func startChats() {
        let capture = ChatCaptureService.shared
        // A linked phone brings WhatsApp in live, your own messages included: its notifications would only repeat it.
        capture.skips = { notice in notice.app == "whatsapp" && WhatsAppAccounts.shared.isConnected }
        capture.onFresh = { [weak self] ids in ids.forEach { self?.presentChat($0) } }
        // Read in its own app (on the phone, in the app on this Mac): a card still waiting in line goes, and so does its
        // macOS notification; the card on screen stays (you may be typing) and follows its chat.
        capture.onReadElsewhere = { [weak self] ids in
            guard let self else { return }
            for id in ids {
                self.viewModel.removePending(id: Self.chatCardPrefix + id)
                SystemNotifier.shared.withdraw(Self.chatCardPrefix + id)
            }
        }
        // The chats with a card up or in line: their apps are read quickly meanwhile, for every app alike.
        capture.watching = { [weak self] in
            Set(self?.viewModel.cardIDs(prefix: Self.chatCardPrefix).map { String($0.dropFirst(Self.chatCardPrefix.count)) } ?? [])
        }
        // A chat's card follows its chat while it is up or waits in line: the newest message, your own answer and its
        // ticks show in it, not only what was there when it came up.
        capture.$inbox
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] inbox in self?.refreshChatCards(inbox) }
            .store(in: &bag)
        capture.start()
    }

    /// The chats whose card was drawn last, as they were then: a card is drawn again only when its chat changed.
    private static var drawnChatCards: [String: InboxThread] = [:]

    private func refreshChatCards(_ inbox: ChatInbox) {
        let shown = viewModel.cardIDs(prefix: Self.chatCardPrefix)
        Self.drawnChatCards = Self.drawnChatCards.filter { shown.contains(Self.chatCardPrefix + $0.key) }
        for token in shown {
            let id = String(token.dropFirst(Self.chatCardPrefix.count))
            guard let thread = inbox.threads[id], Self.drawnChatCards[id] != thread else { continue }
            showChatCard(id, opened: false)
        }
    }

    static let chatCardPrefix = "chatnotice-"

    /// The chat a chat card shows, by its id in the shared inbox; nil for any other card.
    static func chatCardThread(_ card: NookCard) -> String? {
        card.id.hasPrefix(chatCardPrefix) ? String(card.id.dropFirst(chatCardPrefix.count)) : nil
    }

    /// Someone wrote in a chat (of any app): kept in the notice history, and shown the way Settings › Notifications says
    /// for chats of that app (a card with the chat and a field to answer, one line, or a macOS notification). Nothing is
    /// marked read by showing it. `asked`: you opened the chat yourself ("@chat Jan"), so the card comes up now,
    /// whatever the rules.
    func presentChat(_ id: String, asked opened: Bool = false) {
        let capture = ChatCaptureService.shared
        guard let thread = capture.loadedInbox.threads[id] else { return }
        let token = Self.chatCardPrefix + id
        let asked = opened || viewModel.hasCard(id: token)
        guard asked ? !thread.messages.isEmpty : thread.messages.contains(where: { !$0.isMine }) else { return }
        let context = Self.chatContext(thread)
        // In the notice history: the newest message from them, once (the card also follows your own answers and ticks).
        var line = ""
        if !opened, let last = thread.messages.last(where: { !$0.isMine }) {
            let text = (thread.isGroup && !last.sender.isEmpty ? last.sender + ": " : "") + last.summary
            if NoticeHistory.shared.entries.first(where: { $0.key == token })?.detail != NoticeLog.detail(text) {
                line = text
                logNotice(.info, title: thread.name, detail: line, context: context, target: .chat(id), key: token,
                          source: .chats, app: thread.app)
            }
        }
        guard !asked else {
            showChatCard(id, opened: opened)
            return
        }
        // Nothing new from them (your own answer, new ticks): nothing to tell.
        guard !line.isEmpty else { return }
        let open: () -> Void = { [weak self] in self?.presentChat(id, asked: true) }
        deliverNotice(.chats, app: thread.app, id: token, pace: "chat:" + id, title: thread.name, subtitle: context,
                      body: line,
                      card: { [weak self] in self?.showChatCard(id, opened: false) },
                      strip: { [weak self] in
                          self?.viewModel.notify(thread.name + ": " + line, button: tr("notices.openChat"), action: open)
                      },
                      open: open,
                      window: { [weak self] in self?.showChats(ChatsFocus(chat: id)) })
    }

    /// Where a chat is, as its card, notice and search result say it: its app, and the account while the app has more
    /// than one linked ("WhatsApp · Business").
    static func chatContext(_ thread: InboxThread) -> String {
        let app = MessagingApps.app(id: thread.app)?.name ?? thread.app
        return thread.account.map { app + " · " + $0 } ?? app
    }

    /// The card of a chat, the same for every app: its messages (they scroll back), a field to answer it (in the chat
    /// itself where Nook writes in it, else copied for its app), quoting a message and putting an emoji on it where the
    /// app takes them, Read, Let Nook answer, the chat in the Chats tab and in its app, and Quiet and Hide. Redrawn
    /// when it is on screen already. `opened`: you opened the chat yourself, so the card takes the keyboard and comes
    /// first.
    private func showChatCard(_ id: String, opened: Bool) {
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[id], !thread.messages.isEmpty else { return }
        Self.drawnChatCards[id] = thread
        let token = Self.chatCardPrefix + id
        let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
        let route = chatRoute(for: thread)
        let abilities = chatAbilities(route)
        let entry = ChatsEntry.entry(thread)
        viewModel.register("\(token)#read") { [weak self] in self?.readFromCard(id) }
        viewModel.register("\(token)#nook") { [weak self] in self?.letNookAnswer(id) }
        viewModel.register("\(token)#open") { [weak self] in self?.showChats(ChatsFocus(chat: id)) }
        viewModel.register("\(token)#app") { [weak self] in self?.openChatApp(thread.app) }
        viewModel.register("\(token)#quiet") { ChatNoticeRulesStore.shared.setMode(.muted, for: id) }
        viewModel.register("\(token)#hide") { [weak self] in
            ChatNoticeRulesStore.shared.setHidden(true, chat: id)
            self?.viewModel.dismissCard(id: token)
        }
        let time = Self.chatBubbleTime
        // The newest a bridged chat keeps (a chat only notifications bring keeps every message: its newest that many).
        let bubbles = ChatBubble.bubbles(thread, last: ChatInbox.keep) { time.string(from: $0) }
        let unread = thread.unread > 1 ? " · \(tr("whatsapp.card.unread", thread.unread))" : ""
        let card = NookCard(
            id: token,
            mood: .remind,
            context: Self.chatContext(thread) + unread,
            appIcon: thread.app,
            title: thread.name,
            detail: .chat(bubbles),
            primary: CardAction(label: tr("whatsapp.card.read"), outcome: .callback("\(token)#read", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: Self.chatCardHeight(bubbles),
            input: true,
            inputPrompt: route == nil ? tr("chats.reply.copyPrompt", thread.name) : tr("whatsapp.card.answer", thread.name),
            // A new message never takes the keyboard from what you are doing; a chat you opened yourself does.
            focusesInput: opened,
            chatReply: true,
            replyCopiesTo: route == nil ? appName : nil,
            chatQuotes: abilities.reply,
            chatReacts: abilities.react,
            extra: [CardAction(label: tr("whatsapp.card.nook"), outcome: .callback("\(token)#nook", ""), symbol: "sparkles")],
            more: [CardAction(label: tr("notices.openChat"), outcome: .callback("\(token)#open", ""), symbol: "bubble.left.and.bubble.right"),
                   CardAction(label: tr("notices.openApp", appName), outcome: .callback("\(token)#app", ""),
                              symbol: "arrow.up.forward.app"),
                   CardAction(label: tr("whatsapp.card.quiet"), outcome: .callback("\(token)#quiet", ""), symbol: "bell.slash"),
                   CardAction(label: tr("whatsapp.card.mute"), outcome: .callback("\(token)#hide", ""), symbol: "eye.slash")],
            escape: CardAction(label: "", outcome: .dismiss)
        )
        let fresh = !viewModel.hasCard(id: token)
        // A hidden notch (a full-screen app) keeps it in line until it shows again.
        if opened, !viewModel.isShowing(card: token) {
            // Asked for: in front now, ahead of the queue, instead of waiting behind the chat.
            viewModel.removePending(id: token)
            viewModel.presentUrgent(card)
        } else if viewModel.hasCard(id: token) {
            viewModel.updateCard(card)
        } else {
            viewModel.present(card)
        }
        // Coming up: its app is read for it, so the card scrolls back further and shows its newest files; the card
        // follows the chat as that comes in.
        if fresh || opened { Task { await openedChat(entry) } }
    }

    /// "14:05" under each bubble: one formatter for every redraw, not a new one each time.
    static let chatBubbleTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Read on a chat's card, by your own click: read in Nook, and in its app too where answering does so for that app
    /// (Settings › Chats) and something was new.
    private func readFromCard(_ id: String) {
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[id] else { return }
        let entry = ChatsEntry.entry(thread)
        let hadUnread = thread.unread > 0
        markChatReadInNook(entry)
        guard hadUnread, ChatNoticeRulesStore.shared.rules.readsOnReply(thread.app),
              let route = chatRoute(for: thread), chatAbilities(route).markRead else { return }
        Task { [weak self] in
            // Read in the app only when the app took it: a refusal leaves the chat read in Nook alone, with "Mark as read
            // in <app>" still offered.
            do {
                try await self?.markReadInChatApp(route, name: thread.name)
                ChatCaptureService.shared.markReadInApp(id)
            } catch {}
        }
    }

    /// "Let Nook answer" on a chat's card: Nook reads only this chat and proposes an answer you approve. Asking for a
    /// draft teaches memory nothing about you.
    private func letNookAnswer(_ id: String) {
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[id] else { return }
        // Read as Read on the card reads it: in Nook, and in the app where Settings › Chats says so.
        readFromCard(id)
        // WhatsApp's linked phone is read by its key across accounts; every other chat by its name and app.
        let focus: Prefetch.Call
        if case .whatsApp(let key) = chatRoute(for: thread) {
            focus = Prefetch.Call(tool: "whatsapp_live", input: ["chat": key, "limit": 20])
        } else {
            focus = Prefetch.Call(tool: "chat_inbox", input: ["chat": thread.name, "app": thread.app, "limit": 20])
        }
        ask(tr("whatsapp.card.nookPrompt", thread.name), focus: [focus], reflects: false)
    }

    /// Return in a chat card's field: the text goes to that chat as typed (as an answer to `replyTo` when a message was
    /// quoted), where Nook writes in it; else it is copied for its app. The card shows it going out above its field;
    /// when that fails it says why and puts the text back, so nothing typed is lost.
    func replyFromCard(_ text: String, card: NookCard, replyTo: String? = nil) {
        guard let id = Self.chatCardThread(card), let thread = ChatCaptureService.shared.loadedInbox.threads[id] else { return }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "@nook …" is a request to Nook, never a message for the chat; the card's field lets Nook write it.
        guard !reply.isEmpty, ChatDraft.instruction(in: reply) == nil else { return }
        guard let route = chatRoute(for: thread) else {
            copyCardReply(reply, card: card)
            return
        }
        editShownCard(card.id) { $0.notice = nil; $0.sending = reply; $0.draft = nil }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sendChatText(reply, route: route, chat: thread.name, replyTo: replyTo, thread: id)
                self.viewModel.dismissCard(id: card.id)
                self.viewModel.finish(tr("whatsapp.sent", thread.name))
            } catch {
                let shown = self.editShownCard(card.id) {
                    $0.sending = nil
                    $0.notice = tr("whatsapp.card.notSent", error.localizedDescription)
                    $0.draft = reply
                }
                if !shown { self.viewModel.present(self.errorCard(error.localizedDescription)) }
            }
        }
    }

    /// The field of a chat card quoted one of its messages: the text goes to that chat as an answer to it.
    func replyCardMessage(_ text: String, to bubble: ChatBubble, card: NookCard) {
        guard Self.chatCardThread(card) != nil else { return handleCardReply(text, card: card) }
        replyFromCard(text, card: card, replyTo: bubble.id)
    }

    /// An emoji on a message in a chat card, after your own click: it goes to the chat (the same emoji again takes it
    /// back) and is logged as every action in a chat is; the card follows, or says why it could not.
    func reactCardMessage(_ bubble: ChatBubble, _ emoji: String, card: NookCard) {
        guard let id = Self.chatCardThread(card), let thread = ChatCaptureService.shared.loadedInbox.threads[id],
              let route = chatRoute(for: thread) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reactInChat(emoji, to: bubble, route: route, thread: id, name: thread.name)
            } catch {
                self.editShownCard(card.id) { $0.notice = error.localizedDescription }
            }
        }
    }

    /// A click on a file in a chat card's bubble: from this Mac when Nook has it, fetched from its app where Nook can
    /// (WhatsApp's gateway), else in its app. The card stays open and says what happens.
    func openCardAttachment(_ bubble: ChatBubble, card: NookCard) {
        guard let id = Self.chatCardThread(card), let thread = ChatCaptureService.shared.loadedInbox.threads[id] else { return }
        if bubble.file == nil, let name = bubble.attachment { editShownCard(card.id) { $0.notice = tr("whatsapp.file.opening", name) } }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.openChatFile(bubble, in: ChatsEntry.entry(thread))
                self.editShownCard(card.id) { if $0.notice != nil { $0.notice = nil } }
            } catch {
                let shown = self.editShownCard(card.id) { $0.notice = error.localizedDescription }
                if !shown { self.viewModel.present(self.errorCard(error.localizedDescription)) }
            }
        }
    }

    /// A chat card's field, for a chat Nook cannot write in: the text goes on the clipboard and the app opens to paste
    /// it, as in the Chats tab.
    func copyCardReply(_ text: String, card: NookCard) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, ChatDraft.instruction(in: reply) == nil,
              let id = Self.chatCardThread(card), let thread = ChatCaptureService.shared.loadedInbox.threads[id]
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        viewModel.dismissCard(id: card.id)
        openChatApp(thread.app)
        viewModel.finish(tr("chats.reply.copied", card.replyCopiesTo ?? thread.app))
    }

    /// Opens a chat app: beside the chat in Nook when Nook can show it there (the Mac app, else its web version), else
    /// the Mac app in its own window.
    func openChatApp(_ appID: String) {
        if let app = EmbeddedAppCatalog.find(appID) {
            openEmbeddedApp(app)
            showChat()
            return
        }
        let workspace = NSWorkspace.shared
        guard let url = MessagingApps.app(id: appID)?.bundleIDs.lazy
            .compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first else {
            // No Mac app: a website you added (or a known app's web version) opens in the browser.
            if let source = MessagingApps.app(id: appID), let host = source.domains.first ?? source.site,
               let site = URL(string: "https://" + host) {
                workspace.open(site)
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// A file in a WhatsApp chat in the Chats tab: fetched from the gateway and shown in Quick Look, else in the app the
    /// Mac uses for it.
    func openWhatsAppFile(_ bubble: ChatBubble, chat: String) async throws {
        let (link, jid) = WhatsAppAccounts.shared.route(chat)
        let url = try await link.download(message: bubble.id, chat: jid)
        let shown = FilePreviewWindow.shared.show(url, title: bubble.attachment ?? url.lastPathComponent)
        guard shown || NSWorkspace.shared.open(url) else { throw NookError(tr("whatsapp.file.noApp")) }
    }

    // MARK: From the chat

    /// The Chats tab, on what `focus` asks for.
    func showChats(_ focus: ChatsFocus = ChatsFocus()) {
        viewModel.chatsFocus = focus
        viewModel.show(.panel(.inbox))
    }

    /// The Chats tab's id of the chat with this name, the same for every app: a WhatsApp chat by its name or number in
    /// a linked account first (as WhatsApp finds it), else any chat that shows by its name.
    func chatsEntryID(named name: String) -> String? {
        let capture = ChatCaptureService.shared
        if let target = WhatsAppAccounts.shared.resolve(name) {
            let id = ChatInbox.key(app: capture.whatsAppGatewayBridge.app, id: target.key)
            if let thread = capture.loadedInbox.threads[id], capture.isShown(thread) { return id }
        }
        return capture.loadedInbox.thread(named: name, among: capture.isShown)?.id
    }

    /// The chats "@chat …" offers, newest first, the same for every app: each with where it is and how many are new.
    func chatChoices() -> [(name: String, detail: String)] {
        let capture = ChatCaptureService.shared
        return capture.loadedInbox.sorted.filter(capture.isShown).map { thread in
            let context = Self.chatContext(thread)
            return (thread.name, thread.unread > 0 ? context + " · " + tr("whatsapp.card.unread", thread.unread) : context)
        }
    }

    // MARK: Nook writes a message

    /// "@nook …" in a chat's answer field: the message Nook writes from the chat and what you asked. It only goes into the
    /// field; sending stays your own click. Throws with a sentence you can act on.
    func draftChatMessage(app appName: String, chat name: String, transcript: String, instruction: String) async throws -> String {
        guard settings.brainReady else { throw NookError(tr("chats.draft.noBrain")) }
        let prompt = ChatDraft.prompt(app: appName, chat: name, transcript: transcript, instruction: instruction)
        guard let answer = await brain.rewrite(system: ChatDraft.system, prompt: prompt, timeout: 90),
              let message = ChatDraft.clean(answer) else { throw NookError(tr("chats.draft.failed")) }
        return message
    }

    /// "@nook …" in a card's field: the message Nook writes from the chat the card shows, as the Chats tab does. A card
    /// from Nook itself (an answer, a question back) is that chat's one message, so Nook writes your answer to it.
    func draftCardReply(_ instruction: String, card: NookCard) async throws -> String {
        guard case .chat(let bubbles) = card.detail else {
            return try await draftChatMessage(app: "Nook", chat: "Nook", transcript: "Nook: " + card.title, instruction: instruction)
        }
        let thread = Self.chatCardThread(card).flatMap { ChatCaptureService.shared.loadedInbox.threads[$0] }
        let app = thread.map { MessagingApps.app(id: $0.app)?.name ?? $0.app } ?? card.replyCopiesTo ?? card.context
        let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: card.title)
        return try await draftChatMessage(app: app, chat: card.title, transcript: transcript, instruction: instruction)
    }
}
