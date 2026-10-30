// An open chat in the Chats tab: what happens when it opens, scrolls back, opens a file, goes online or is removed, the
// same calls for every app. The chat view never asks where a chat came from; the switches below pick each app's own way.
import AppKit

extension AppModel {
    /// The chat's thread in the shared inbox: every chat in the Chats tab is one (`ChatsEntry.id`). Emoji shown at once,
    /// archiving and removing use it.
    func chatThread(_ entry: ChatsEntry) -> String? { entry.id }

    /// A chat that opens: its app is read for it now, so it shows the newest messages at once, its people and the
    /// pictures of its newest files with them. Every app that Nook reads itself is asked; a chat only notifications
    /// bring has nothing to ask.
    func openedChat(_ entry: ChatsEntry) async {
        guard case .whatsApp(let key) = chatRoute(for: entry) else {
            ChatCaptureService.shared.refresh(entry.id)
            return
        }
        // WhatsApp's gateway is asked for the chat's history, its group's people and its newest files: the link then
        // changes, and the chat with it (`WhatsAppGatewayBridge`).
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        _ = await link.loadHistory(jid)
        _ = await link.loadMembers(jid)
        guard let conversation = link.inbox.conversations[WAJID.normalized(jid)] else { return }
        let wanted = conversation.messages.filter { Self.whatsAppPreviews($0.media) }.suffix(Self.whatsAppPreviewCount)
            .filter { link.preview($0.id) == nil }.map(\.id)
        if !wanted.isEmpty { _ = await link.loadPreviews(wanted, chat: jid) }
    }

    /// The pointer rests on a chat in the list: what its click needs is fetched now, so it opens filled. A chat its app
    /// keeps on this Mac (in the shared inbox) has it already; a WhatsApp chat of the linked phone fetches its history.
    func prefetchChat(_ entry: ChatsEntry) async {
        guard case .whatsApp(let key) = chatRoute(for: entry) else { return }
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        _ = await link.loadHistory(jid)
    }

    /// A chat's row came into view without a line under its name (a chat on the phone that wrote nothing since Nook
    /// was linked): its newest message is fetched for it. Every other app brings each chat with its newest message.
    func loadChatLine(_ entry: ChatsEntry) {
        guard entry.preview.isEmpty, case .whatsApp(let key) = chatRoute(for: entry) else { return }
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        link.loadLine(jid)
    }

    /// The pictures of the chats in the list whose app gives them only on request (WhatsApp's linked phones), the newest
    /// first; every other app brings each chat's picture with it. Each account asks its own gateway device for its own
    /// newest chats, all accounts at once: one account's chats never wait behind the other's.
    func loadChatAvatars(_ entries: [ChatsEntry]) async {
        let accounts = WhatsAppAccounts.shared
        let keys = entries.compactMap { entry -> (account: String, jid: String)? in
            guard case .whatsApp(let key) = chatRoute(for: entry) else { return nil }
            return WAChatKey.split(key)
        }
        await withTaskGroup(of: Void.self) { group in
            for link in accounts.connected {
                let own = Array(keys.filter { $0.account == link.account }.prefix(60).map(\.jid))
                group.addTask { await link.loadAvatars(own) }
            }
        }
    }

    /// Whether the chat may have older messages to scroll back to, in its app.
    func canLoadOlderChat(_ entry: ChatsEntry) -> Bool {
        ChatCaptureService.shared.canLoadOlder(entry.id)
    }

    /// The batch of older messages from the chat's app, as you reach the top; true when there were any.
    func loadOlderChat(_ entry: ChatsEntry) async -> Bool {
        await ChatCaptureService.shared.loadOlder(entry.id)
    }

    /// The chat open in Nook (nil: none is). WhatsApp only says who types to a device that says it is online, as
    /// WhatsApp Web does; every other app says it without (`ChatTypingCenter`), so nothing is told to them.
    func setChatOnline(_ entry: ChatsEntry?) {
        let open = entry.flatMap { entry -> (WhatsAppLink, String)? in
            guard case .whatsApp(let key) = chatRoute(for: entry) else { return nil }
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
        if case .whatsApp(let key) = chatRoute(for: entry) {
            try await openWhatsAppFile(bubble, chat: key)
        } else {
            openChatApp(entry.app)
        }
    }

    /// Every chat can be removed from Nook; it comes back with its app's next message.
    func canRemoveChat(_ entry: ChatsEntry) -> Bool { true }
}
