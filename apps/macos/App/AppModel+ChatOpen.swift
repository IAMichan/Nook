// An open chat in the Chats tab: what happens when it opens, scrolls back, opens a file, goes online or is removed, the
// same calls for every app. The chat view never asks where a chat came from; the switches below pick each app's own way.
import AppKit

extension AppModel {
    /// The collected chat behind an entry (its id in `ChatInbox`); nil for a chat of a linked WhatsApp phone, which its
    /// link keeps. Emoji shown at once, archiving and removing use it.
    func chatThread(_ entry: ChatsEntry) -> String? {
        if case .captured(let id) = entry.origin { return id }
        return nil
    }

    /// A chat that opens: its app is read for it now, so it shows the newest messages at once, its people and the
    /// pictures of its newest photos with them. Every app that Nook reads itself is asked; a chat only notifications
    /// bring has nothing to ask.
    func openedChat(_ entry: ChatsEntry) async {
        switch entry.origin {
        case .captured(let id):
            ChatCaptureService.shared.refresh(id)
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            _ = await link.loadHistory(jid)
            // A group's people: its header lists them, and your messages' info says who does not have them yet.
            _ = await link.loadMembers(jid)
            guard let conversation = link.inbox.conversations[WAJID.normalized(jid)] else { return }
            let wanted = conversation.messages.filter { Self.whatsAppPreviews($0.media) }.suffix(Self.whatsAppPreviewCount)
                .filter { link.preview($0.id) == nil }.map(\.id)
            if !wanted.isEmpty { _ = await link.loadPreviews(wanted, chat: jid) }
        }
    }

    /// The pointer rests on a chat in the list: what its click needs is fetched now, so it opens filled. A collected
    /// chat keeps its messages on this Mac already; a WhatsApp chat of the linked phone fetches its history.
    func prefetchChat(_ entry: ChatsEntry) async {
        guard case .whatsApp(let key) = entry.origin else { return }
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        _ = await link.loadHistory(jid)
    }

    /// A chat's row came into view without a line under its name (a chat on the phone that wrote nothing since Nook
    /// was linked): its newest message is fetched for it. A collected chat always has one.
    func loadChatLine(_ entry: ChatsEntry) {
        guard entry.preview.isEmpty, case .whatsApp(let key) = entry.origin else { return }
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        link.loadLine(jid)
    }

    /// Whether the chat may have older messages to scroll back to, in its app.
    func canLoadOlderChat(_ entry: ChatsEntry) -> Bool {
        switch entry.origin {
        case .captured(let id): return ChatCaptureService.shared.canLoadOlder(id)
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            return link.inbox.conversations[WAJID.normalized(jid)]?.canLoadOlder ?? false
        }
    }

    /// The batch of older messages from the chat's app, as you reach the top; true when there were any.
    func loadOlderChat(_ entry: ChatsEntry) async -> Bool {
        switch entry.origin {
        case .captured(let id): return await ChatCaptureService.shared.loadOlder(id)
        case .whatsApp(let key):
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            return await link.loadOlder(jid)
        }
    }

    /// The chat open in Nook (nil: none is). WhatsApp only says who types to a device that says it is online, as
    /// WhatsApp Web does; every other app says it without (`ChatTypingCenter`), so nothing is told to them.
    func setChatOnline(_ entry: ChatsEntry?) {
        let open = entry.flatMap { entry -> (WhatsAppLink, String)? in
            guard case .whatsApp(let key) = entry.origin else { return nil }
            return WhatsAppAccounts.shared.route(key)
        }
        for link in WhatsAppAccounts.shared.connected where link !== open?.0 { link.setOnline(nil) }
        open.map { $0.0.setOnline($0.1) }
    }

    /// A file in a chat bubble, after your own click: from this Mac when Nook has it (whichever app it came from), from
    /// the gateway for WhatsApp, else in the chat's own app, which has it. Shown in Quick Look, else in the app the Mac
    /// uses for it. Throws a sentence for the chat to show.
    func openChatFile(_ bubble: ChatBubble, in entry: ChatsEntry) async throws {
        if let file = bubble.file {
            guard FilePreviewWindow.shared.show(file, title: bubble.attachment ?? file.lastPathComponent)
                    || NSWorkspace.shared.open(file) else { throw NookError(tr("whatsapp.file.noApp")) }
            return
        }
        guard bubble.attachment != nil else { return }
        switch entry.origin {
        case .whatsApp(let key): try await openWhatsAppFile(bubble, chat: key)
        case .captured: openChatApp(entry.app)
        }
    }

    /// Whether the chat can be removed from Nook (it comes back with its app's next message); a linked WhatsApp phone's
    /// chats are hidden in Settings instead.
    func canRemoveChat(_ entry: ChatsEntry) -> Bool { chatThread(entry) != nil }
}
