// Sending from the Chats tab: text, files, polls, places and contact cards, to every chat Nook can write in.
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
}

/// What Nook can do in a chat: one list for every app, so the Chats tab offers the same things everywhere, each as far
/// as the app's own service lets Nook do it.
struct ChatAbilities: Equatable {
    /// Text goes to the chat (else it is copied for the app).
    var send = false
    /// What can go besides text.
    var sends: Set<ChatOutgoing.Kind> = []
    /// An answer quotes the message it answers.
    var reply = false
    var react = false
    /// Your own messages can be changed and deleted for everyone.
    var edit = false
    var delete = false
    /// "Mark as read in <app>" tells the app itself, instead of opening it.
    var markRead = false
    /// The chat can be pinned, muted and archived in its app; `pinned` and `muted` say where it stands.
    var pin = false
    var mute = false
    var archive = false
    var pinned = false
    var muted = false
}

extension AppModel {
    /// Where the Chats tab sends for this chat; nil when Nook can only read it.
    func chatRoute(for entry: ChatsEntry) -> ChatRoute? {
        switch entry.origin {
        case .whatsApp(let key):
            return .whatsApp(key)
        case .captured:
            let capture = ChatCaptureService.shared
            let telegram = capture.telegramBridge
            if entry.app == telegram.app, telegram.isReady, let id = telegram.chatID(named: entry.name) { return .telegram(id) }
            if let id = capture.serviceBridge.chatID(app: entry.app, name: entry.name) { return .linked(id) }
            if entry.app == capture.teamsBridge.app, capture.teamsBridge.canSend(name: entry.name) { return .teams(entry.name) }
            if entry.app == capture.slackBridge.app, capture.slackBridge.canSend(name: entry.name) { return .slack(entry.name) }
            if entry.app == capture.messagesBridge.app, capture.messagesBridge.canSend(name: entry.name) { return .messages(entry.name) }
            if entry.app == capture.snapchatBridge.app, capture.snapchatBridge.canSend(name: entry.name) { return .snapchat(entry.name) }
            return nil
        }
    }

    /// Everything Nook can do in the chat behind `route`.
    func chatAbilities(_ route: ChatRoute?) -> ChatAbilities {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            return ChatAbilities(send: true, sends: link.sends, reply: true, react: true, edit: link.canEdit, delete: link.canDelete,
                                 markRead: true, pin: link.canPin, mute: false, archive: link.canArchive,
                                 pinned: link.isPinned(jid))
        case .telegram(let id):
            let telegram = capture.telegramBridge
            return ChatAbilities(send: true, sends: ChatOutgoing.Kind.everything, reply: true, react: true, edit: true, delete: true,
                                 markRead: true, pin: true, mute: true, archive: true,
                                 pinned: telegram.isPinned(id), muted: telegram.isMuted(id))
        case .teams:
            return ChatAbilities(send: true, reply: true, react: true, edit: true, delete: true, markRead: true)
        case .slack:
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
            let chat = bridge.chats[id]
            return ChatAbilities(send: true, sends: bridge.sends, reply: true, react: chat?.canReact ?? true,
                                 edit: chat?.canEdit ?? true, delete: chat?.canDelete ?? true, markRead: true,
                                 pin: true, mute: true, archive: true, pinned: chat?.isPinned ?? false, muted: chat?.isMuted ?? false)
        case nil:
            return ChatAbilities()
        }
    }

    /// What can go to a chat besides text.
    func chatSends(_ route: ChatRoute?) -> Set<ChatOutgoing.Kind> { chatAbilities(route).sends }

    /// Your text from the Chats tab (as an answer to `replyTo` when set), after your own Return or click, logged as
    /// every send is.
    func sendChatText(_ text: String, route: ChatRoute, chat name: String, replyTo: String? = nil) async throws {
        let capture = ChatCaptureService.shared
        let tool: String
        switch route {
        case .whatsApp(let jid):
            try await sendWhatsAppFromChats(text, chat: jid, replyTo: replyTo)
            return
        case .telegram(let id):
            try capture.telegramBridge.send(text: text, to: id, replyTo: replyTo)
            tool = "telegram_send"
        case .teams(let chat):
            try await capture.teamsBridge.send(text: text, to: chat, replyTo: replyTo)
            tool = "teams_send"
        case .slack(let chat):
            try await capture.slackBridge.send(text: text, to: chat, replyTo: replyTo)
            tool = "slack_send"
        case .messages(let chat):
            try await capture.messagesBridge.send(text: text, to: chat)
            tool = "messages_send"
        case .snapchat(let chat):
            try await capture.snapchatBridge.send(text: text, to: chat)
            tool = "snapchat_send"
        case .linked(let id):
            try await capture.serviceBridge.send(text: text, to: id, replyTo: replyTo)
            tool = "chat_send"
        }
        capture.readSoon(appID(route))
        store.audit(tool: tool, args: name, result: "verstuurd")
    }

    /// A file, a poll, a place or a contact card from the Chats tab, after your own click, logged as every send is. A
    /// sticker or GIF you send is kept for the sticker panel.
    func sendChatItem(_ outgoing: ChatOutgoing, route: ChatRoute, chat name: String, replyTo: String? = nil) async throws {
        let capture = ChatCaptureService.shared
        let tool: String
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            try await link.send(outgoing, to: jid, replyTo: replyTo)
            tool = "whatsapp_send"
        case .telegram(let id):
            try capture.telegramBridge.send(outgoing, to: id, replyTo: replyTo)
            tool = "telegram_send"
        case .slack(let chat):
            try await capture.slackBridge.send(outgoing, to: chat, replyTo: replyTo)
            tool = "slack_send"
        case .messages(let chat):
            try await capture.messagesBridge.send(outgoing, to: chat)
            tool = "messages_send"
        case .linked(let id):
            try await capture.serviceBridge.send(outgoing, to: id, replyTo: replyTo)
            tool = "chat_send"
        case .teams, .snapchat:
            // Teams and Snapchat take text from Nook; their abilities offer nothing else for them.
            throw NookError(tr("chat.compose.unsupported"))
        }
        if case .whatsApp = route {} else { capture.readSoon(appID(route)) }
        store.audit(tool: tool, args: "\(name): \(outgoing.kind.rawValue)", result: "verstuurd")
        if case .file(let file) = outgoing, file.kind == .sticker || file.kind == .gif {
            ChatStickers.remember(file.url, gif: file.kind == .gif)
        }
    }

    /// The app a route's chat belongs to, for reading it again at once after a change; the chat helper reads all of its
    /// apps in one go.
    private func appID(_ route: ChatRoute) -> String {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp: return "whatsapp"
        case .telegram: return capture.telegramBridge.app
        case .teams: return capture.teamsBridge.app
        case .slack: return capture.slackBridge.app
        case .messages: return capture.messagesBridge.app
        case .snapchat: return capture.snapchatBridge.app
        case .linked: return capture.serviceBridge.app
        }
    }
}

// MARK: Doing things in a chat

/// What else Nook can do in a chat it writes in, the same for every app as far as its service allows (`ChatAbilities`):
/// read state, emoji, your messages' edits and deletions, and pinning, muting and archiving it in its app.
extension AppModel {
    /// The linked chat behind a route, when it is one; nil for every other app.
    func linkedChat(_ route: ChatRoute?) -> ChatServiceData.Chat? {
        guard case .linked(let id) = route else { return nil }
        return ChatCaptureService.shared.serviceBridge.chats[id]
    }

    /// "Mark as read" or "Mark as unread" by your own click: in Nook, and in the chat's app.
    func markLinkedChat(_ id: String, read: Bool) {
        let bridge = ChatCaptureService.shared.serviceBridge
        Task {
            do {
                if read { try await bridge.markRead(id) } else { try await bridge.markUnread(id) }
            } catch {
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }

    /// Tells the chat's app you read it, after your own click; a failure shows as a toast. False when this app cannot
    /// be told (the caller opens it instead).
    func markReadInChatApp(_ route: ChatRoute?) -> Bool {
        let capture = ChatCaptureService.shared
        let work: (() async throws -> Void)?
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            link.markReadInWhatsApp(jid)
            return true
        case .telegram(let id): capture.telegramBridge.markRead(chat: id); return true
        case .linked(let id): markLinkedChat(id, read: true); return true
        case .teams(let chat): work = { try await capture.teamsBridge.markRead(name: chat) }
        case .slack(let chat): work = { try await capture.slackBridge.markRead(name: chat) }
        case .messages, .snapchat, nil: work = nil
        }
        guard let work else { return false }
        Task {
            do { try await work() } catch { ToastCenter.shared.error(error.localizedDescription) }
        }
        return true
    }

    /// Your emoji on a message in any chat Nook writes in, after your own click; the same one again takes it back. A
    /// chat collected in the inbox shows it at once, before its app's next read confirms it.
    func reactInChat(_ emoji: String, to bubble: ChatBubble, route: ChatRoute, thread: String?, name: String) async throws {
        let mine = bubble.reactions.contains { $0.emoji == emoji && $0.mine }
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp(let jid):
            try await reactWhatsApp(emoji, to: bubble.id, chat: jid)
            return
        case .telegram:
            try capture.telegramBridge.react(emoji, to: bubble.id, mine: mine)
        case .teams(let chat):
            try await capture.teamsBridge.react(emoji, to: bubble.id, in: chat, mine: mine)
        case .slack(let chat):
            try await capture.slackBridge.react(emoji, to: bubble.id, in: chat, mine: mine)
        case .linked(let id):
            try await capture.serviceBridge.react(emoji, to: bubble.id, in: id, mine: mine)
        case .messages, .snapchat:
            throw NookError(tr("chat.compose.unsupported"))
        }
        if let thread { capture.toggleReaction(emoji, on: bubble.id, in: thread) }
        store.audit(tool: "chat_react", args: "\(name): \(emoji)", result: mine ? "weggehaald" : "verstuurd")
    }

    /// The new text of your message, after your own Return or click.
    func editInChat(_ bubble: ChatBubble, text: String, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            try await link.edit(bubble.id, chat: jid, to: text)
        case .telegram: try capture.telegramBridge.edit(bubble.id, to: text)
        case .teams(let chat): try await capture.teamsBridge.edit(bubble.id, in: chat, to: text)
        case .slack(let chat): try await capture.slackBridge.edit(bubble.id, in: chat, to: text)
        case .linked(let id): try await capture.serviceBridge.edit(bubble.id, in: id, to: text)
        case .messages, .snapchat: throw NookError(tr("chat.compose.unsupported"))
        }
        if case .whatsApp = route {} else { capture.readSoon(appID(route)) }
        store.audit(tool: "chat_edit", args: name, result: "bewerkt")
    }

    /// Deletes your message for everyone, after you confirmed it.
    func deleteInChat(_ bubble: ChatBubble, route: ChatRoute, name: String) async throws {
        let capture = ChatCaptureService.shared
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            try await link.delete(bubble.id, chat: jid)
        case .telegram: try capture.telegramBridge.delete(bubble.id)
        case .teams(let chat): try await capture.teamsBridge.delete(bubble.id, in: chat)
        case .slack(let chat): try await capture.slackBridge.delete(bubble.id, in: chat)
        case .linked(let id): try await capture.serviceBridge.delete(bubble.id, in: id)
        case .messages, .snapchat: throw NookError(tr("chat.compose.unsupported"))
        }
        if case .whatsApp = route {} else { capture.readSoon(appID(route)) }
        store.audit(tool: "chat_delete", args: name, result: "verwijderd")
    }

    /// Deletes a message for you alone, after you chose it: the chat no longer shows it in Nook (in every app), and an
    /// app that can delete for one person (Telegram, on all your devices) does so too. `chat` is the Chats tab's chat id.
    func deleteInChatForMe(_ bubble: ChatBubble, route: ChatRoute?, chat: String, name: String) {
        if case .telegram = route { try? ChatCaptureService.shared.telegramBridge.delete(bubble.id, forEveryone: false) }
        ChatHiddenMessages.shared.hide(bubble.id, in: chat)
        store.audit(tool: "chat_delete_for_me", args: name, result: "verwijderd voor mij")
    }

    /// Pins the chat in its app, or unpins it, after your own click.
    func setChatPinned(_ pinned: Bool, route: ChatRoute, name: String) async throws {
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            try await link.setPinned(pinned, chat: jid)
        case .telegram(let id): try ChatCaptureService.shared.telegramBridge.setPinned(pinned, chat: id)
        case .linked(let id): try await ChatCaptureService.shared.serviceBridge.setPinned(pinned, chat: id)
        case .teams, .slack, .messages, .snapchat: throw NookError(tr("chat.compose.unsupported"))
        }
        store.audit(tool: "chat_pin", args: name, result: pinned ? "vastgezet" : "losgemaakt")
    }

    /// Mutes the chat in its app, or unmutes it, after your own click.
    func setChatMuted(_ muted: Bool, route: ChatRoute, name: String) async throws {
        switch route {
        case .telegram(let id): try ChatCaptureService.shared.telegramBridge.setMuted(muted, chat: id)
        case .linked(let id): try await ChatCaptureService.shared.serviceBridge.setMuted(muted, chat: id)
        case .whatsApp, .teams, .slack, .messages, .snapchat: throw NookError(tr("chat.compose.unsupported"))
        }
        store.audit(tool: "chat_mute", args: name, result: muted ? "gedempt" : "niet meer gedempt")
    }

    /// Archives the chat in its app; it leaves the Chats tab too (`thread`, a chat collected in the inbox), and comes
    /// back with a newer message.
    func archiveChat(route: ChatRoute, thread: String?, name: String) async throws {
        switch route {
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            try await link.archive(jid)
        case .telegram(let id): try ChatCaptureService.shared.telegramBridge.archive(id)
        case .linked(let id): try await ChatCaptureService.shared.serviceBridge.archive(id)
        case .teams, .slack, .messages, .snapchat: throw NookError(tr("chat.compose.unsupported"))
        }
        if let thread { ChatCaptureService.shared.remove(thread) }
        store.audit(tool: "chat_archive", args: name, result: "gearchiveerd")
    }
}
