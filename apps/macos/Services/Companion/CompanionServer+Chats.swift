import Foundation

/// The Chats tab on the iPhone companion: the same inbox as on the Mac (WhatsApp through the linked phone, and every
/// other chat app collected from its notifications), read from `ChatsEntry.all` so the phone and the Mac list the same
/// chats. Only a WhatsApp chat can be answered, with your own words and your own tap, as in the Chats tab; any other
/// chat is answered in its own app. "@nook …" stays on the Mac: the phone never lets Nook write into a chat.
extension CompanionServer {
    /// How many chats the phone lists, newest first.
    static let inboxLimit = 80

    func inbox(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let capture = ChatCaptureService.shared
        let whatsApp = WhatsAppLink.shared
        let chats = ChatsEntry.all(whatsApp: whatsApp, capture: capture).prefix(Self.inboxLimit).map(Self.digest)
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
        if case .whatsApp(let jid) = entry.origin { _ = await WhatsAppLink.shared.loadHistory(jid) }
        // The chat may have changed while its history loaded.
        guard let current = inboxEntry(entry.id) else { return .failure(request.id, .unknownItem) }
        let readOnOpen = UserDefaults.standard.object(forKey: ChatsTab.readOnOpenKey) as? Bool ?? true
        if readOnOpen, current.read.isUnread { app.markChatReadInNook(current) }
        return CompanionResponse(id: request.id, ok: true, inboxLines: inboxLines(current))
    }

    /// Your own words to a WhatsApp chat (to one of its messages, when `replyTo` is set), sent and logged as the Chats
    /// tab sends them.
    func inboxSend(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        guard case .whatsApp(let jid) = entry.origin else { return .failure(request.id, .notAllowedFromPhone) }
        // "@nook …" asks Nook to write the message, which is never sent as it is; that stays on the Mac.
        guard let text = CompanionPolicy.cleanMessage(request.text ?? ""), ChatDraft.instruction(in: text) == nil else {
            return .failure(request.id, .badRequest)
        }
        do {
            let name = try await app.sendWhatsAppFromChats(text, chat: jid, replyTo: request.replyTo)
            audit("chat_send", name)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
        return CompanionResponse(id: request.id, ok: true, inboxLines: inboxEntry(entry.id).map(inboxLines) ?? [])
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
        return ChatsEntry.all(whatsApp: WhatsAppLink.shared, capture: ChatCaptureService.shared).first { $0.id == id }
    }

    private static func digest(_ entry: ChatsEntry) -> InboxChatDigest {
        let canSend: Bool
        if case .whatsApp = entry.origin { canSend = true } else { canSend = false }
        return InboxChatDigest(id: entry.id, app: entry.app, appName: MessagingApps.app(id: entry.app)?.name ?? entry.app,
                               name: CompanionPolicy.clip(entry.name, limit: 120), preview: CompanionPolicy.clip(entry.preview, limit: 200),
                               last: entry.last.timeIntervalSince1970, unread: entry.unread, canSend: canSend,
                               ticks: entry.ticks.map(Self.ticks), waitsInApp: entry.waitsInApp)
    }

    /// The newest messages of a chat that fit in one answer, oldest first.
    private func inboxLines(_ entry: ChatsEntry) -> [InboxLine] {
        let lines: [InboxLine]
        switch entry.origin {
        case .whatsApp(let jid):
            let bubbles = WhatsAppLink.shared.inbox.conversations[jid].map { AppModel.whatsAppBubbles($0) } ?? []
            lines = bubbles.suffix(60).map { bubble in
                InboxLine(id: bubble.id, text: CompanionPolicy.clip(ChatFormat.plain(bubble.text)),
                          date: (bubble.date ?? Date()).timeIntervalSince1970, sender: CompanionPolicy.clip(bubble.sender, limit: 120),
                          fromMe: bubble.fromMe, attachment: bubble.attachment.map { CompanionPolicy.clip($0, limit: 120) },
                          ticks: bubble.ticks.map(Self.ticks),
                          quoteSender: bubble.quote.map { CompanionPolicy.clip($0.sender, limit: 120) },
                          quoteText: bubble.quote.map { CompanionPolicy.clip($0.text, limit: 200) },
                          reactions: bubble.reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji })
            }
        case .captured(let id):
            let messages = ChatCaptureService.shared.inbox.threads[id]?.messages ?? []
            lines = messages.suffix(60).map { message in
                InboxLine(id: message.id, text: CompanionPolicy.clip(message.poll?.line ?? ChatFormat.plain(message.text)),
                          date: message.date.timeIntervalSince1970, sender: CompanionPolicy.clip(message.sender, limit: 120),
                          fromMe: message.isMine, attachment: message.media.map { CompanionPolicy.clip($0.label, limit: 120) },
                          ticks: nil, quoteSender: nil, quoteText: nil, reactions: [])
            }
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
