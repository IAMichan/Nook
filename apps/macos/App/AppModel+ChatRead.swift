// Read in Nook, and read in the chat's own app: one way for every chat in the Chats tab.
import AppKit

/// How Nook passes "read" on to a chat's own app.
enum ChatReadHandoff: Equatable {
    /// Nook tells the app itself (WhatsApp through the linked phone, Telegram once linked, a chat app linked through Nook's chat helper).
    case tells
    /// Nook cannot tell this app: it opens the chat's app, where you read it, and keeps it as read there.
    case opensApp
}

/// Every chat works the same way, whatever its app: opening it reads it in Nook (Settings › Connections can turn that off),
/// which nobody else sees and which stays after a restart; "Mark as read in <app>" is your own click that passes it on to
/// the app, so the chat is read on your phone too and the people who wrote can see it. "Mark as unread" marks it unread
/// in Nook and, where the app takes it, in the app too (as its own "Mark as unread": nobody who wrote sees it).
extension AppModel {
    /// Read in Nook: the badge goes, the app (and whoever wrote) hears nothing.
    func markChatReadInNook(_ entry: ChatsEntry) {
        ChatCaptureService.shared.markRead(entry.id)
        // WhatsApp's linked phone keeps its own count of what is new (it carries it across restarts): it hears it too.
        if case .whatsApp(let key) = chatRoute(for: entry) {
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            link.markReadInNook(jid)
        }
    }

    /// Unread again: the badge comes back in Nook until you open the chat again, and the app is told too where it takes
    /// it, so the chat waits on your phone as well. An app that refused says why in a toast; Nook's mark stays.
    func markChatUnread(_ entry: ChatsEntry) {
        ChatCaptureService.shared.markUnread(entry.id)
        let route = chatRoute(for: entry)
        if case .whatsApp(let key) = route {
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            link.markUnread(jid)
        }
        guard let route, chatAbilities(route).markUnread else { return }
        Task {
            do {
                try await self.markUnreadInChatApp(route, name: entry.name)
                ChatCaptureService.shared.markUnreadInApp(entry.id)
            } catch {
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }

    /// Every chat with something new read in Nook, in every app at once.
    func markAllChatsReadInNook(_ entries: [ChatsEntry]) {
        for entry in entries where entry.read.isUnread { markChatReadInNook(entry) }
    }

    /// Whether Nook can tell this chat's app itself, or opens the app instead.
    func chatReadHandoff(_ entry: ChatsEntry) -> ChatReadHandoff {
        chatAbilities(chatRoute(for: entry)).markRead ? .tells : .opensApp
    }

    /// "Mark as read in <app>", after your own click: read in Nook at once, and passed on to the app. The chat counts
    /// as read in the app (and is logged so) only once the app took it; when it refused, a toast says why and the chat
    /// stays read in Nook only. An app Nook cannot tell is opened instead, to read the chat there.
    func markChatReadInApp(_ entry: ChatsEntry) {
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        guard let route = chatRoute(for: entry), chatAbilities(route).markRead else {
            openChatApp(entry.app)
            markChatReadInNook(entry)
            ChatCaptureService.shared.markReadInApp(entry.id)
            store.audit(tool: ChatAction.markRead.auditTool, args: "\(appName): \(entry.name)", result: "app geopend")
            return
        }
        markChatReadInNook(entry)
        // What the app is told: what you saw now. A message that comes in while it goes stays new.
        let through = ChatCaptureService.shared.readMark(entry.id)
        Task {
            do {
                try await self.markReadInChatApp(route, name: entry.name)
                ChatCaptureService.shared.markReadInApp(entry.id, through: through)
            } catch {
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }
}
