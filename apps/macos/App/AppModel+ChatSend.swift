// Sending from the Chats tab: text, files, polls, places and contact cards, to every chat Nook can write in.
import Foundation

/// Where what you send in a chat goes: WhatsApp through the linked phone's gateway, Telegram through TDLib, or any app the
/// chat helper on this Mac links (Instagram, Messenger, Signal…). A chat without
/// one is only read: its text is copied for its own app instead.
enum ChatRoute: Equatable {
    case whatsApp(String)
    case telegram(Int64)
    case linked(String)
}

extension AppModel {
    /// Where the Chats tab sends for this chat; nil when Nook can only read it.
    func chatRoute(for entry: ChatsEntry) -> ChatRoute? {
        switch entry.origin {
        case .whatsApp(let jid):
            return .whatsApp(jid)
        case .captured:
            let capture = ChatCaptureService.shared
            let telegram = capture.telegramBridge
            if entry.app == telegram.app, telegram.isReady, let id = telegram.chatID(named: entry.name) { return .telegram(id) }
            if let id = capture.serviceBridge.chatID(app: entry.app, name: entry.name) { return .linked(id) }
            return nil
        }
    }

    /// What can go to a chat besides text.
    func chatSends(_ route: ChatRoute?) -> Set<ChatOutgoing.Kind> {
        switch route {
        case .whatsApp: return WhatsAppLink.shared.sends
        case .telegram: return ChatOutgoing.Kind.everything
        case .linked: return ChatCaptureService.shared.serviceBridge.sends
        case nil: return []
        }
    }

    /// Your text from the Chats tab (as an answer to `replyTo` when set), after your own Return or click, logged as
    /// every send is.
    func sendChatText(_ text: String, route: ChatRoute, chat name: String, replyTo: String? = nil) async throws {
        switch route {
        case .whatsApp(let jid):
            try await sendWhatsAppFromChats(text, chat: jid, replyTo: replyTo)
            return
        case .telegram(let id):
            try ChatCaptureService.shared.telegramBridge.send(text: text, to: id, replyTo: replyTo)
            store.audit(tool: "telegram_send", args: name, result: "verstuurd")
        case .linked(let id):
            try await ChatCaptureService.shared.serviceBridge.send(text: text, to: id, replyTo: replyTo)
            store.audit(tool: "chat_send", args: name, result: "verstuurd")
        }
    }

    /// A file, a poll, a place or a contact card from the Chats tab, after your own click, logged as every send is. A
    /// sticker or GIF you send is kept for the sticker panel.
    func sendChatItem(_ outgoing: ChatOutgoing, route: ChatRoute, chat name: String, replyTo: String? = nil) async throws {
        let tool: String
        switch route {
        case .whatsApp(let jid):
            try await WhatsAppLink.shared.send(outgoing, to: jid, replyTo: replyTo)
            tool = "whatsapp_send"
        case .telegram(let id):
            try ChatCaptureService.shared.telegramBridge.send(outgoing, to: id, replyTo: replyTo)
            tool = "telegram_send"
        case .linked(let id):
            try await ChatCaptureService.shared.serviceBridge.send(outgoing, to: id, replyTo: replyTo)
            tool = "chat_send"
        }
        store.audit(tool: tool, args: "\(name): \(outgoing.kind.rawValue)", result: "verstuurd")
        if case .file(let file) = outgoing, file.kind == .sticker || file.kind == .gif {
            ChatStickers.remember(file.url, gif: file.kind == .gif)
        }
    }
}

// MARK: Doing things in a chat

/// What else Nook can do in a chat it writes in through the linked chat service (Instagram, Messenger, Signal…): read
/// state, emoji, your messages' edits and deletions, and pinning, muting and archiving it in its app.
extension AppModel {
    /// The linked chat behind a route, when it is one; nil for WhatsApp and Telegram.
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

    /// Your emoji on a message, after your own click; the same one again takes it back.
    func reactInLinkedChat(_ emoji: String, to bubble: ChatBubble, chat id: String, name: String) async throws {
        let mine = bubble.reactions.contains { $0.emoji == emoji && $0.mine }
        try await ChatCaptureService.shared.serviceBridge.react(emoji, to: bubble.id, in: id, mine: mine)
        store.audit(tool: "chat_react", args: "\(name): \(emoji)", result: mine ? "weggehaald" : "verstuurd")
    }

    /// The new text of your message, after your own Return or click.
    func editInLinkedChat(_ bubble: ChatBubble, text: String, chat id: String, name: String) async throws {
        try await ChatCaptureService.shared.serviceBridge.edit(bubble.id, in: id, to: text)
        store.audit(tool: "chat_edit", args: name, result: "bewerkt")
    }

    /// Deletes your message for everyone, after you confirmed it.
    func deleteInLinkedChat(_ bubble: ChatBubble, chat id: String, name: String) async throws {
        try await ChatCaptureService.shared.serviceBridge.delete(bubble.id, in: id)
        store.audit(tool: "chat_delete", args: name, result: "verwijderd")
    }

    /// Pins, mutes or archives the chat in its app, after your own click.
    func setLinkedChatPinned(_ pinned: Bool, chat id: String, name: String) async throws {
        try await ChatCaptureService.shared.serviceBridge.setPinned(pinned, chat: id)
        store.audit(tool: "chat_pin", args: name, result: pinned ? "vastgezet" : "losgemaakt")
    }

    func setLinkedChatMuted(_ muted: Bool, chat id: String, name: String) async throws {
        try await ChatCaptureService.shared.serviceBridge.setMuted(muted, chat: id)
        store.audit(tool: "chat_mute", args: name, result: muted ? "gedempt" : "niet meer gedempt")
    }

    /// Archives the chat in its app; it leaves the Chats tab too, and comes back with a newer message.
    func archiveLinkedChat(_ id: String, thread: String, name: String) async throws {
        try await ChatCaptureService.shared.serviceBridge.archive(id)
        ChatCaptureService.shared.remove(thread)
        store.audit(tool: "chat_archive", args: name, result: "gearchiveerd")
    }
}
