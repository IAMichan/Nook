// Doing things in a chat from the Chats tab: text, files, polls, places and contact cards, emoji, edits, deletions, read
// marks, votes, and pinning, muting and archiving, in every chat Nook can write in, the same way for every app.
import Foundation

/// Where what you send in a chat goes: WhatsApp through the linked phone's gateway (by the chat's key across accounts,
/// `WAChatKey`), Telegram through TDLib, Teams through
/// the website's session, Slack through its web API, Messages through the Messages app on this Mac (the last three by
/// the chat's name in Nook), Snapchat through its website (by the chat's name too), or any app the chat helper on this Mac links (Instagram, Messenger, Signal…). A chat
/// without one is only read: its text is copied for its own app instead.
enum ChatRoute: Equatable {
    case whatsApp(String)
    case telegram(Int64)
    case teams(String)
    case slack(String)
    case messages(String)
    case snapchat(String)
    case linked(String)

    var isWhatsApp: Bool {
        if case .whatsApp = self { return true }
        return false
    }
}

extension AppModel {
    /// Where the Chats tab sends for this chat; nil when Nook can only read it.
    func chatRoute(for entry: ChatsEntry) -> ChatRoute? {
        chatRoute(app: entry.app, name: entry.name, chatID: entry.chatID)
    }

    /// Where a chat card, the companion or Nook sends for this chat; nil when Nook can only read it.
    func chatRoute(for thread: InboxThread) -> ChatRoute? {
        chatRoute(app: thread.app, name: thread.name, chatID: thread.chatID)
    }

    /// The route of a chat by its app, its name and its own id in its app (`InboxThread.chatID`).
    func chatRoute(app: String, name: String, chatID: String?) -> ChatRoute? {
        let capture = ChatCaptureService.shared
        // A linked phone's WhatsApp chat goes through its gateway, by its key across accounts, while its account is linked.
        let gateway = capture.whatsAppGatewayBridge
        if app == gateway.app, let key = chatID { return gateway.isLinked(key) ? .whatsApp(key) : nil }
        let telegram = capture.telegramBridge
        if app == telegram.app, telegram.isReady, let id = telegram.chatID(named: name) { return .telegram(id) }
        if let id = capture.serviceBridge.chatID(app: app, name: name) { return .linked(id) }
        if app == capture.teamsBridge.app, capture.teamsBridge.canSend(name: name) { return .teams(name) }
        if app == capture.slackBridge.app, capture.slackBridge.canSend(name: name) { return .slack(name) }
        if app == capture.messagesBridge.app, capture.messagesBridge.canSend(name: name) { return .messages(name) }
        if app == capture.snapchatBridge.app, capture.snapchatBridge.canSend(name: name) { return .snapchat(name) }
        return nil
    }

    /// Everything Nook can do in the chat behind `route`. This list is also what every action checks before it goes
    /// (`runInChat`), so what the Chats tab offers is exactly what works.
    func chatAbilities(_ route: ChatRoute?) -> ChatAbilities {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            // Muting goes through OpenWA; GOWA has no call for it.
            return ChatAbilities(send: true, sends: link.sends, reply: true, react: true, edit: link.canEdit, delete: link.canDelete,
                                 markRead: link.isConnected, pin: link.canPin, mute: link.canMuteInWhatsApp, archive: link.canArchive,
                                 pinned: link.isPinned(jid), muted: link.isMutedInWhatsApp(jid), vote: link.canVote)
        case .telegram(let id):
            let telegram = capture.telegramBridge
            return ChatAbilities(send: true, sends: ChatOutgoing.Kind.everything, reply: true, react: true, edit: true, delete: true,
                                 markRead: true, pin: true, mute: true, archive: true,
                                 pinned: telegram.isPinned(id), muted: telegram.isMuted(id), vote: true, deleteForMe: true)
        case .teams:
            // Teams' website session takes text, answers, emoji, edits, deletions and read marks; not files, and it
            // has no pinning, muting or archiving Nook can reach.
            return ChatAbilities(send: true, reply: true, react: true, edit: true, delete: true, markRead: true)
        case .slack:
            // Slack's Web API has no pinning, muting or archiving of a direct conversation, and no polls.
            return ChatAbilities(send: true, sends: capture.slackBridge.sends, reply: true, react: true, edit: true, delete: true,
                                 markRead: true)
        case .messages:
            // Messages lets another app send text and files, and nothing else.
            return ChatAbilities(send: true, sends: capture.messagesBridge.sends)
        case .snapchat:
            // Snapchat for Web takes typed text from Nook, and nothing else Nook can reach.
            return ChatAbilities(send: true)
        case .linked(let id):
            let bridge = capture.serviceBridge
            // A chat the helper does not list (any more) offers only what every network takes: text.
            guard let chat = bridge.chats[id] else { return ChatAbilities(send: true, sends: bridge.sends, markRead: true) }
            return ChatAbilities(send: true, sends: bridge.sends, reply: true, react: chat.canReact,
                                 edit: chat.canEdit, delete: chat.canDelete, markRead: true,
                                 pin: true, mute: true, archive: true, pinned: chat.isPinned, muted: chat.isMuted,
                                 vote: chat.canVote)
        case nil:
            return ChatAbilities()
        }
    }

    /// What can go to a chat besides text.
    func chatSends(_ route: ChatRoute?) -> Set<ChatOutgoing.Kind> { chatAbilities(route).sends }

    /// The one way every action in a chat goes, whatever its app: the checks every app shares (`ChatAction.refusal`:
    /// the app takes it, there is text, the message is yours), then the app's own bridge (`work`, which only
    /// translates), then the chat is read again from its app, and the action is logged under one name. A refusal or a
    /// failure throws a sentence for the chat to show; nothing is logged then.
    func runInChat(_ action: ChatAction, route: ChatRoute, name: String, text: String? = nil, fromMe: Bool = true,
                   result: String = "verstuurd", work: () async throws -> Void) async throws {
        if let refusal = action.refusal(chatAbilities(route), text: text, fromMe: fromMe) {
            throw NookError(tr(refusal.rawValue))
        }
        try await work()
        readChatSoon(route)
        store.audit(tool: action.auditTool, args: "\(chatAppName(route)): \(name)", result: result)
    }

    /// After a change from Nook, the chat is read again from its app at once and twice more shortly after, so it shows
    /// what the app made of it (its id, ticks, the edit as the app keeps it). The WhatsApp gateways push every change to
    /// Nook themselves (their webhook), and the link shows the change the moment the gateway took it.
    private func readChatSoon(_ route: ChatRoute) {
        guard let app = bridgeApp(route) else { return }
        ChatCaptureService.shared.readSoon(app)
    }

    /// The bridge that reads a route's chat, by its app id; nil for WhatsApp through a gateway, which reads itself. The
    /// chat helper reads all of its apps in one go.
    private func bridgeApp(_ route: ChatRoute) -> String? {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp: return nil
        case .telegram: return capture.telegramBridge.app
        case .teams: return capture.teamsBridge.app
        case .slack: return capture.slackBridge.app
        case .messages: return capture.messagesBridge.app
        case .snapchat: return capture.snapchatBridge.app
        case .linked: return capture.serviceBridge.app
        }
    }

    /// The app a route's chat is in ("telegram"; the network's own for a chat the helper links).
    private func chatAppID(_ route: ChatRoute) -> String {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp: return capture.whatsAppGatewayBridge.app
        case .linked(let chat): return capture.serviceBridge.chats[chat]?.app ?? capture.serviceBridge.app
        default: return bridgeApp(route) ?? ""
        }
    }

    /// The app's name for the audit log ("Telegram").
    private func chatAppName(_ route: ChatRoute) -> String {
        let id = chatAppID(route)
        return MessagingApps.app(id: id)?.name ?? id
    }

    /// You answered in a chat (`thread`, its id in the shared inbox; nil does nothing): it is read in Nook, and in its
    /// app too where Settings › Chats says so for that app (on by default), so whoever wrote sees you read it. `told`:
    /// the app heard it with the answer already (WhatsApp's link does that when it sends text). A failure there leaves
    /// the answer sent.
    func answeredInChat(_ route: ChatRoute, name: String, thread: String?, told: Bool = false) async {
        // Without the chat's id this was one part of a send that reads the chat once, at its end.
        guard let thread else { return }
        ChatCaptureService.shared.markRead(thread)
        guard !told, ChatNoticeRulesStore.shared.rules.readsOnReply(chatAppID(route)), chatAbilities(route).markRead else { return }
        try? await markReadInChatApp(route, name: name)
    }

    // MARK: Sending

    /// Your text from the Chats tab (as an answer to `replyTo` when set), after your own Return or click. `thread` is the
    /// chat's id in the shared inbox: answering reads it (`answeredInChat`).
    func sendChatText(_ text: String, route: ChatRoute, chat name: String, replyTo: String? = nil,
                      thread: String? = nil) async throws {
        let capture = ChatCaptureService.shared
        let replyTo = chatAbilities(route).reply ? replyTo : nil
        try await runInChat(.send, route: route, name: name, text: text) {
            switch route {
            case .whatsApp(let key): try await WhatsAppAccounts.shared.send(text, to: key, replyTo: replyTo)
            case .telegram(let id): try capture.telegramBridge.send(text: text, to: id, replyTo: replyTo)
            case .teams(let chat): try await capture.teamsBridge.send(text: text, to: chat, replyTo: replyTo)
            case .slack(let chat): try await capture.slackBridge.send(text: text, to: chat, replyTo: replyTo)
            case .messages(let chat): try await capture.messagesBridge.send(text: text, to: chat)
            case .snapchat(let chat): try await capture.snapchatBridge.send(text: text, to: chat)
            case .linked(let id): try await capture.serviceBridge.send(text: text, to: id, replyTo: replyTo)
            }
        }
        // WhatsApp's link tells the phone itself, as it sends (`WhatsAppLink.send`).
        await answeredInChat(route, name: name, thread: thread, told: route.isWhatsApp)
    }

    /// A file, a poll, a place or a contact card from the Chats tab, after your own click. A sticker or GIF you send is
    /// kept for the sticker panel. Answering this way reads the chat too (`answeredInChat`).
    func sendChatItem(_ outgoing: ChatOutgoing, route: ChatRoute, chat name: String, replyTo: String? = nil,
                      thread: String? = nil) async throws {
        let capture = ChatCaptureService.shared
        let replyTo = chatAbilities(route).reply ? replyTo : nil
        try await runInChat(.sendItem(outgoing.kind), route: route, name: name) {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.send(outgoing, to: jid, replyTo: replyTo)
            case .telegram(let id): try capture.telegramBridge.send(outgoing, to: id, replyTo: replyTo)
            case .slack(let chat): try await capture.slackBridge.send(outgoing, to: chat, replyTo: replyTo)
            case .messages(let chat): try await capture.messagesBridge.send(outgoing, to: chat)
            case .linked(let id): try await capture.serviceBridge.send(outgoing, to: id, replyTo: replyTo)
            case .teams, .snapchat:
                // Their abilities offer nothing besides text, so `runInChat` stops before this.
                throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
        if case .file(let file) = outgoing, file.kind == .sticker || file.kind == .gif {
            ChatStickers.remember(file.url, gif: file.kind == .gif)
        }
        await answeredInChat(route, name: name, thread: thread)
    }
}

// MARK: Doing things in a chat

/// What else Nook can do in a chat it writes in, the same for every app as far as its service allows (`ChatAbilities`):
/// read state, emoji, votes, your messages' edits and deletions, and pinning, muting and archiving it in its app. Each
/// goes through `runInChat`; the switches below only pick the app's own call.
extension AppModel {
    /// The linked chat behind a route, when it is one; nil for every other app.
    func linkedChat(_ route: ChatRoute?) -> ChatServiceData.Chat? {
        guard case .linked(let id) = route else { return nil }
        return ChatCaptureService.shared.serviceBridge.chats[id]
    }

    /// Tells the chat's app you read it, after your own click: the chat is read on your phone too and the people who
    /// wrote can see it. Throws when the app refused it.
    func markReadInChatApp(_ route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.markRead, route: route, name: name, result: "doorgegeven") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.markReadInWhatsApp(jid)
            case .telegram(let id): try capture.telegramBridge.markRead(chat: id)
            case .teams(let chat): try await capture.teamsBridge.markRead(name: chat)
            case .slack(let chat): try await capture.slackBridge.markRead(name: chat)
            case .linked(let id): try await capture.serviceBridge.markRead(id)
            case .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// Your emoji on a message in any chat Nook writes in, after your own click; the same one again takes it back. The
    /// chat shows it as soon as its app took it, before the app's next read confirms it.
    func reactInChat(_ emoji: String, to bubble: ChatBubble, route: ChatRoute, thread: String?, name: String) async throws {
        let mine = bubble.reactions.contains { $0.emoji == emoji && $0.mine }
        let capture = ChatCaptureService.shared
        try await runInChat(.react, route: route, name: name, result: mine ? "weggehaald" : "verstuurd") {
            switch route {
            case .whatsApp(let key):
                // The link works out your earlier emoji itself and shows the new one in its own inbox.
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.react(emoji, to: bubble.id, chat: jid)
            case .telegram: try capture.telegramBridge.react(emoji, to: bubble.id, mine: mine)
            case .teams(let chat): try await capture.teamsBridge.react(emoji, to: bubble.id, in: chat, mine: mine)
            case .slack(let chat): try await capture.slackBridge.react(emoji, to: bubble.id, in: chat, mine: mine)
            case .linked(let id): try await capture.serviceBridge.react(emoji, to: bubble.id, in: id, mine: mine)
            case .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
            // WhatsApp's link shows it in its chat itself, which the shared inbox then takes over.
            if let thread, !route.isWhatsApp { capture.toggleReaction(emoji, on: bubble.id, in: thread) }
        }
    }

    /// Your vote on a poll, after your own click; the poll shows it at once.
    func voteInChat(_ choice: [String], on bubble: ChatBubble, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.vote, route: route, name: name) {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.vote(choice, poll: bubble.id, chat: jid)
            case .telegram: try capture.telegramBridge.vote(choice, message: bubble.id)
            case .linked(let id): try await capture.serviceBridge.vote(choice, on: bubble.id, in: id)
            case .teams, .slack, .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// The new text of your message, after your own Return or click.
    func editInChat(_ bubble: ChatBubble, text: String, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.edit, route: route, name: name, text: text, fromMe: bubble.fromMe, result: "bewerkt") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.edit(bubble.id, chat: jid, to: text)
            case .telegram: try capture.telegramBridge.edit(bubble.id, to: text)
            case .teams(let chat): try await capture.teamsBridge.edit(bubble.id, in: chat, to: text)
            case .slack(let chat): try await capture.slackBridge.edit(bubble.id, in: chat, to: text)
            case .linked(let id): try await capture.serviceBridge.edit(bubble.id, in: id, to: text)
            case .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// Deletes your message for everyone, after you confirmed it.
    func deleteInChat(_ bubble: ChatBubble, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.delete, route: route, name: name, fromMe: bubble.fromMe, result: "verwijderd") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.delete(bubble.id, chat: jid)
            case .telegram: try capture.telegramBridge.delete(bubble.id)
            case .teams(let chat): try await capture.teamsBridge.delete(bubble.id, in: chat)
            case .slack(let chat): try await capture.slackBridge.delete(bubble.id, in: chat)
            case .linked(let id): try await capture.serviceBridge.delete(bubble.id, in: id)
            case .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// Deletes a message for you alone, after you chose it: the chat no longer shows it in Nook (in every app), and an
    /// app that can delete for one person (`ChatAbilities.deleteForMe`: Telegram, on all your devices) does so too.
    /// `chat` is the Chats tab's chat id.
    func deleteInChatForMe(_ bubble: ChatBubble, route: ChatRoute?, chat: String, name: String) {
        if chatAbilities(route).deleteForMe, case .telegram = route {
            try? ChatCaptureService.shared.telegramBridge.delete(bubble.id, forEveryone: false)
        }
        ChatHiddenMessages.shared.hide(bubble.id, in: chat)
        store.audit(tool: "chat_delete_for_me", args: name, result: "verwijderd voor mij")
    }

    /// Pins the chat in its app, or unpins it, after your own click.
    func setChatPinned(_ pinned: Bool, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.pin, route: route, name: name, result: pinned ? "vastgezet" : "losgemaakt") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.setPinned(pinned, chat: jid)
            case .telegram(let id): try capture.telegramBridge.setPinned(pinned, chat: id)
            case .linked(let id): try await capture.serviceBridge.setPinned(pinned, chat: id)
            case .teams, .slack, .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// Mutes the chat in its app, or unmutes it, after your own click.
    func setChatMuted(_ muted: Bool, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.mute, route: route, name: name, result: muted ? "gedempt" : "niet meer gedempt") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.setMutedInWhatsApp(muted, chat: jid)
            case .telegram(let id): try capture.telegramBridge.setMuted(muted, chat: id)
            case .linked(let id): try await capture.serviceBridge.setMuted(muted, chat: id)
            case .teams, .slack, .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
    }

    /// Archives the chat in its app; it leaves the Chats tab too (`thread`, a chat collected in the inbox), and comes
    /// back with a newer message.
    func archiveChat(route: ChatRoute, thread: String?, name: String) async throws {
        let capture = ChatCaptureService.shared
        try await runInChat(.archive, route: route, name: name, result: "gearchiveerd") {
            switch route {
            case .whatsApp(let key):
                let (link, jid) = WhatsAppAccounts.shared.route(key)
                try await link.archive(jid)
            case .telegram(let id): try capture.telegramBridge.archive(id)
            case .linked(let id): try await capture.serviceBridge.archive(id)
            case .teams, .slack, .messages, .snapchat: throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
            }
        }
        if let thread { capture.remove(thread) }
    }
}
