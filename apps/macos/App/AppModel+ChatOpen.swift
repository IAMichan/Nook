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
        ChatMediaWarmup.warm(ChatCaptureService.shared.inbox.threads[entry.id])
        guard case .whatsApp(let key) = chatRoute(for: entry) else {
            ChatCaptureService.shared.hurryFiles(entry.id)
            ChatCaptureService.shared.refresh(entry.id)
            return
        }
        // WhatsApp's gateway is asked for the chat's history, its group's people and the files of the messages Nook
        // has at once, then for the files the history brought: the link then changes, and the chat with it
        // (`WhatsAppGatewayBridge`). The photos on screen never wait for the history.
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        async let members = link.loadMembers(jid)
        async let shown: Void = loadWhatsAppPreviews(link, jid: jid)
        _ = await link.loadHistory(jid)
        await shown
        await loadWhatsAppPreviews(link, jid: jid)
        _ = await members
    }

    /// The files of a WhatsApp chat's newest messages, fetched from the gateway (a few at a time) when not yet here.
    private func loadWhatsAppPreviews(_ link: WhatsAppLink, jid: String) async {
        guard let conversation = link.inbox.conversations[WAJID.normalized(jid)] else { return }
        let wanted = conversation.messages.filter { Self.whatsAppPreviews($0.media) }.suffix(Self.whatsAppPreviewCount)
            .filter { link.preview($0.id) == nil }.map(\.id)
        if !wanted.isEmpty { _ = await link.loadPreviews(wanted, chat: jid) }
    }

    /// The pointer rests on a chat in the list: what its click needs is fetched now, so it opens filled. Every app's
    /// chat readies the pictures of its newest messages (`ChatMediaWarmup`); a WhatsApp chat of the linked phone fetches
    /// its history and newest files too.
    func prefetchChat(_ entry: ChatsEntry) async {
        ChatMediaWarmup.warm(ChatCaptureService.shared.inbox.threads[entry.id])
        guard case .whatsApp(let key) = chatRoute(for: entry) else { return }
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        async let shown: Void = loadWhatsAppPreviews(link, jid: jid)
        _ = await link.loadHistory(jid)
        await shown
        await loadWhatsAppPreviews(link, jid: jid)
        // The files that just came in are part of the chat now: their pictures are readied as well.
        ChatMediaWarmup.warm(ChatCaptureService.shared.inbox.threads[entry.id])
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
    /// newest chats, all accounts at once: one account's chats never wait behind the other's. Your own picture in each
    /// account comes first, for the account's row in the sidebar.
    func loadChatAvatars(_ entries: [ChatsEntry]) async {
        let accounts = WhatsAppAccounts.shared
        let keys = entries.compactMap { entry -> (account: String, jid: String)? in
            guard case .whatsApp(let key) = chatRoute(for: entry) else { return nil }
            return WAChatKey.split(key)
        }
        await withTaskGroup(of: Void.self) { group in
            for link in accounts.connected {
                let mine = link.me.map { [WAJID.normalized($0)] } ?? []
                let own = mine + Array(keys.filter { $0.account == link.account }.prefix(60).map(\.jid))
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
    /// WhatsApp Web does; every other app says it without (`ChatTypingCenter`), so nothing is told to them. Every app's
    /// open chat is read as quickly as a chat card meanwhile (`ChatCaptureService.openChat`).
    func setChatOnline(_ entry: ChatsEntry?) {
        ChatCaptureService.shared.openChat = entry?.id
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

    /// A message's file the chat names but Nook does not have yet, asked of its app as its bubble comes into view: a
    /// photo that came in while the chat was open, or one whose fetch failed. WhatsApp's gateway is asked for that one
    /// file; every other app's chat is read again, which fetches the files its messages hold (each bridge's own way),
    /// at most once per `fileReadPause` per chat however many bubbles ask.
    func fetchChatFile(_ message: String, in entry: ChatsEntry) async {
        if case .whatsApp(let key) = chatRoute(for: entry) {
            let (link, jid) = WhatsAppAccounts.shared.route(key)
            guard link.preview(message) == nil,
                  let found = link.inbox.conversations[WAJID.normalized(jid)]?.messages.first(where: { $0.id == message }),
                  Self.whatsAppPreviews(found.media) else { return }
            _ = await link.loadPreviews([message], chat: jid)
            return
        }
        ChatCaptureService.shared.hurryFiles(entry.id)
        if let last = Self.fileReads[entry.id], Date().timeIntervalSince(last) < Self.fileReadPause { return }
        Self.fileReads[entry.id] = Date()
        ChatCaptureService.shared.refresh(entry.id)
    }

    /// `fetchChatFile` for the chat of a message card.
    func fetchCardChatFile(_ message: String, card: NookCard) async {
        guard let id = Self.chatCardThread(card), let thread = ChatCaptureService.shared.loadedInbox.threads[id] else { return }
        await fetchChatFile(message, in: ChatsEntry.entry(thread))
    }

    /// When each chat was last read again for a file its bubbles asked for.
    private static var fileReads: [String: Date] = [:]
    private static let fileReadPause: TimeInterval = 2.5

    /// Every chat can be removed from Nook; it comes back with its app's next message.
    func canRemoveChat(_ entry: ChatsEntry) -> Bool { true }
}
