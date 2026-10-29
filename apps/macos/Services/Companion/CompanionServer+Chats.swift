import Foundation

/// The Chats tab on the iPhone companion: the same inbox as on the Mac (WhatsApp through the linked phone, and every
/// other chat app collected from its notifications), read from `ChatsEntry.all` so the phone and the Mac list the same
/// chats. Every chat the Chats tab can write in can be answered, with your own words and your own tap, as there; any
/// other chat is answered in its own app. "@nook …" stays on the Mac: the phone never lets Nook write into a chat.
extension CompanionServer {
    /// How many chats the phone lists, newest first.
    static let inboxLimit = 80

    func inbox(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let capture = ChatCaptureService.shared
        let whatsApp = WhatsAppAccounts.shared
        let chats = ChatsEntry.all(capture: capture).prefix(Self.inboxLimit).map {
            Self.digest($0, canSend: app.chatRoute(for: $0) != nil)
        }
        // Why the list may be empty: nothing is collected, or macOS does not let Nook read the notifications.
        var status: String?
        if !capture.enabled, !whatsApp.isConnected {
            status = "chatsoff"
        } else if capture.status == .needsAccess {
            status = "chatsaccess"
        }
        return CompanionResponse(id: request.id, ok: true, message: status, inbox: Array(chats))
    }

    /// One chat's messages. Opening it on the phone reads it the way opening it on the Mac does (Settings › Chats, in
    /// Nook only: WhatsApp keeps it unread and the sender sees no blue ticks).
    func inboxChat(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        // Read from its app now, as the Mac does when a chat opens; WhatsApp's linked phone brings its history, which is
        // in the shared inbox once the link's news is.
        await app.openedChat(entry)
        if case .whatsApp = app.chatRoute(for: entry) {
            let capture = ChatCaptureService.shared
            await capture.readAndWait(capture.whatsAppGatewayBridge)
        }
        // The chat may have changed while its history loaded.
        guard let current = inboxEntry(entry.id) else { return .failure(request.id, .unknownItem) }
        let readOnOpen = UserDefaults.standard.object(forKey: ChatsTab.readOnOpenKey) as? Bool ?? true
        if readOnOpen, current.read.isUnread { app.markChatReadInNook(current) }
        return CompanionResponse(id: request.id, ok: true, inboxLines: inboxLines(current), inboxTyping: Self.typing(current.id))
    }

    /// Your own words to a chat the Chats tab writes in (to one of its messages, when `replyTo` is set and the app
    /// quotes), sent and logged as the Chats tab sends them.
    func inboxSend(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        guard let route = app.chatRoute(for: entry) else { return .failure(request.id, .notAllowedFromPhone) }
        // "@nook …" asks Nook to write the message, which is never sent as it is; that stays on the Mac.
        guard let text = CompanionPolicy.cleanMessage(request.text ?? ""), ChatDraft.instruction(in: text) == nil else {
            return .failure(request.id, .badRequest)
        }
        do {
            let replyTo = app.chatAbilities(route).reply ? request.replyTo : nil
            try await app.sendChatText(text, route: route, chat: entry.name, replyTo: replyTo, thread: entry.id)
            audit("chat_send", entry.name)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
        return CompanionResponse(id: request.id, ok: true, inboxLines: inboxEntry(entry.id).map(inboxLines) ?? [],
                                 inboxTyping: Self.typing(entry.id))
    }

    /// Read or unread by hand, as on the Mac: read is passed on to the chat's app where Nook can tell it (so the sender
    /// sees it), else read in Nook; unread is Nook's alone. An app Nook can only open stays as it is from the phone.
    func inboxMark(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        let read = request.allow == true
        if !read {
            app.markChatUnread(entry)
        } else if app.chatReadHandoff(entry) == .tells {
            app.markChatReadInApp(entry)
        } else {
            app.markChatReadInNook(entry)
        }
        audit(read ? "chat_read" : "chat_unread", entry.name)
        return inbox(request, app: app)
    }

    /// A chat the Chats tab lists: one you hid in WhatsApp, or of an app you switched off, cannot be reached.
    private func inboxEntry(_ id: String?) -> ChatsEntry? {
        guard let id, !id.isEmpty else { return nil }
        return ChatsEntry.all(capture: ChatCaptureService.shared).first { $0.id == ChatIDMigration.current(id) }
    }

    private static func digest(_ entry: ChatsEntry, canSend: Bool) -> InboxChatDigest {
        InboxChatDigest(id: entry.id, app: entry.app, appName: MessagingApps.app(id: entry.app)?.name ?? entry.app,
                               name: CompanionPolicy.clip(entry.name, limit: 120), preview: CompanionPolicy.clip(entry.preview, limit: 200),
                               last: entry.last.timeIntervalSince1970, unread: entry.unread, canSend: canSend,
                               ticks: entry.ticks.map(Self.ticks), waitsInApp: entry.waitsInApp, typing: typing(entry.id))
    }

    /// Who is typing in a chat now, as the Chats tab on the Mac shows it.
    private static func typing(_ chat: String) -> [InboxTypist] {
        ChatTypingCenter.shared.typists(chat).map { InboxTypist(name: CompanionPolicy.clip($0.name, limit: 120), kind: $0.kind.rawValue) }
    }

    /// Your message's info as the Mac's ticks open it: who has it and who read it, and when.
    private static func readers(_ bubble: ChatBubble) -> [InboxReader]? {
        guard bubble.fromMe, !bubble.readers.isEmpty else { return nil }
        return bubble.readers.prefix(256).map { reader in
            InboxReader(name: CompanionPolicy.clip(reader.name, limit: 120), receipt: receiptName(reader.receipt),
                        date: reader.date?.timeIntervalSince1970)
        }
    }

    private static func receiptName(_ receipt: ChatReceipt) -> String {
        switch receipt {
        case .failed: return "failed"
        case .pending: return "pending"
        case .sent: return "sent"
        case .delivered: return "delivered"
        case .read: return "read"
        }
    }

    /// The newest messages of a chat that fit in one answer, oldest first.
    private func inboxLines(_ entry: ChatsEntry) -> [InboxLine] {
        // The same bubbles as the Chats tab, for every app: answers quote what they answer, emoji and ticks show as there.
        let bubbles = ChatCaptureService.shared.inbox.threads[entry.id].map { ChatBubble.bubbles($0, last: 60) { _ in "" } } ?? []
        let lines = bubbles.map { bubble in
            InboxLine(id: bubble.id, text: CompanionPolicy.clip(bubble.poll?.line ?? ChatFormat.plain(bubble.text)),
                      date: (bubble.date ?? Date()).timeIntervalSince1970, sender: CompanionPolicy.clip(bubble.sender, limit: 120),
                      fromMe: bubble.fromMe, attachment: bubble.attachment.map { CompanionPolicy.clip($0, limit: 120) },
                      ticks: bubble.ticks.map(Self.ticks),
                      quoteSender: bubble.quote.map { CompanionPolicy.clip($0.sender, limit: 120) },
                      quoteText: bubble.quote.map { CompanionPolicy.clip($0.text, limit: 200) },
                      reactions: bubble.reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji },
                      readers: Self.readers(bubble))
        }
        return CompanionPolicy.newestFitting(lines)
    }

    private static func ticks(_ ticks: BubbleTicks) -> String {
        switch ticks {
        case .pending: return "pending"
        case .sent: return "sent"
        case .delivered: return "delivered"
        case .read: return "read"
        case .failed: return "failed"
        }
    }
}
