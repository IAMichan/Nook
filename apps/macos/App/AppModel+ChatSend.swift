// Sending from the Chats tab: text, files, polls, places and contact cards, to every chat Nook can write in.
import Foundation

/// Where what you send in a chat goes: WhatsApp through the linked phone's gateway, Telegram through TDLib, or any
/// network Beeper bridges (Instagram, Messenger, Signal…). A chat without one is only read: its text is copied for its
/// own app instead.
enum ChatRoute: Equatable {
    case whatsApp(String)
    case telegram(Int64)
    case beeper(String)
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
            if let id = capture.beeperBridge.chatID(app: entry.app, name: entry.name) { return .beeper(id) }
            return nil
        }
    }

    /// What can go to a chat besides text.
    func chatSends(_ route: ChatRoute?) -> Set<ChatOutgoing.Kind> {
        switch route {
        case .whatsApp: return WhatsAppLink.shared.sends
        case .telegram: return ChatOutgoing.Kind.everything
        case .beeper: return ChatCaptureService.shared.beeperBridge.sends
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
        case .beeper(let id):
            try await ChatCaptureService.shared.beeperBridge.send(text: text, to: id, replyTo: replyTo)
            store.audit(tool: "beeper_send", args: name, result: "verstuurd")
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
        case .beeper(let id):
            try await ChatCaptureService.shared.beeperBridge.send(outgoing, to: id, replyTo: replyTo)
            tool = "beeper_send"
        }
        store.audit(tool: tool, args: "\(name): \(outgoing.kind.rawValue)", result: "verstuurd")
        if case .file(let file) = outgoing, file.kind == .sticker || file.kind == .gif {
            ChatStickers.remember(file.url, gif: file.kind == .gif)
        }
    }
}
