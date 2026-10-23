// Read in Nook, and read in the chat's own app: one way for every chat in the Chats tab.
import AppKit

/// How Nook passes "read" on to a chat's own app.
enum ChatReadHandoff: Equatable {
    /// Nook tells the app itself (WhatsApp through the linked phone, Telegram once linked, a chat app linked through Nook's chat helper).
    case tells
    /// Nook cannot tell this app: it opens the chat's app, where you read it, and keeps it as read there.
    case opensApp
}

/// Every chat works the same way, whatever its app: opening it reads it in Nook (Settings › Chats can turn that off),
/// which nobody else sees and which stays after a restart; "Mark as read in <app>" is your own click that passes it on to
/// the app, so the chat is read on your phone too and the people who wrote can see it. "Mark as unread" is Nook's alone.
extension AppModel {
    /// Read in Nook: the badge goes, the app (and whoever wrote) hears nothing.
    func markChatReadInNook(_ entry: ChatsEntry) {
        switch entry.origin {
        case .captured(let thread): ChatCaptureService.shared.markRead(thread)
        case .whatsApp(let jid): WhatsAppLink.shared.markReadInNook(jid)
        }
    }

    /// Unread again, in Nook only: the badge comes back until you open the chat again.
    func markChatUnread(_ entry: ChatsEntry) {
        switch entry.origin {
        case .captured(let thread): ChatCaptureService.shared.markUnread(thread)
        case .whatsApp(let jid): WhatsAppLink.shared.markUnread(jid)
        }
    }

    /// Every chat with something new read in Nook, in every app at once.
    func markAllChatsReadInNook(_ entries: [ChatsEntry]) {
        for entry in entries where entry.read.isUnread { markChatReadInNook(entry) }
    }

    /// Whether Nook can tell this chat's app itself, or opens the app instead.
    func chatReadHandoff(_ entry: ChatsEntry) -> ChatReadHandoff {
        chatRoute(for: entry) == nil ? .opensApp : .tells
    }

    /// "Mark as read in <app>", after your own click: read in Nook and passed on to the app. Logged, as anything Nook
    /// does in another app is.
    func markChatReadInApp(_ entry: ChatsEntry) {
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        switch (entry.origin, chatRoute(for: entry)) {
        case (.whatsApp(let jid), _):
            WhatsAppLink.shared.markReadInWhatsApp(jid)
        case (.captured(let thread), .telegram(let chat)?):
            ChatCaptureService.shared.telegramBridge.markRead(chat: chat)
            ChatCaptureService.shared.markReadInApp(thread)
        case (.captured(let thread), .linked(let chat)?):
            markLinkedChat(chat, read: true)
            ChatCaptureService.shared.markReadInApp(thread)
        case (.captured(let thread), _):
            // Nook cannot write in this app: it opens it, and you read the chat there.
            openChatApp(entry.app)
            ChatCaptureService.shared.markReadInApp(thread)
        }
        store.audit(tool: "chat_mark_read", args: "\(appName): \(entry.name)",
                    result: chatReadHandoff(entry) == .tells ? "doorgegeven" : "app geopend")
    }
}
