import Foundation

/// The Chats tab on the iPhone companion: the same inbox as on the Mac (WhatsApp through the linked phone, and every
/// other chat app collected from its notifications), read from `ChatsEntry.all` so the phone and the Mac list the same
/// chats. Every chat the Chats tab can write in can be answered, with your own words and your own tap, as there; any
/// other chat is answered in its own app. "@nook …" stays on the Mac: the phone never lets Nook write into a chat.
extension CompanionServer {
    /// How many chats the phone lists, newest first; and of status updates and channels, each.
    static let inboxLimit = 80
    static let inboxOtherLimit = 30

    /// `allKinds`: the phone shows status updates and channels under an app's own tabs, as the Mac does
    /// (`CompanionFeature.chatActions`); an older phone gets the chats only.
    func inbox(_ request: CompanionRequest, app: AppModel, allKinds: Bool = false) -> CompanionResponse {
        let capture = ChatCaptureService.shared
        // Asked right after launch, the inbox may still be read in the background: the phone gets the chats, not none.
        _ = capture.loadedInbox
        // The faces from Contacts, also when the Chats tab on the Mac was never opened (nothing without access, at most
        // every ten minutes).
        ContactPhotos.shared.refresh()
        let whatsApp = WhatsAppAccounts.shared
        // The chats; and for a phone with the app tabs, the status updates and channels the Mac shows under them.
        let all = ChatsEntry.all(capture: capture)
        var shown = Array(all.filter { $0.listKind == .chats }.prefix(Self.inboxLimit))
        if allKinds {
            shown += all.filter { $0.listKind == .status }.prefix(Self.inboxOtherLimit)
            shown += all.filter { $0.listKind == .channels }.prefix(Self.inboxOtherLimit)
        }
        let chats = shown.map { digest($0, app: app) }
        // Why the list may be empty: nothing is collected, or macOS does not let Nook read the notifications.
        var status: String?
        if !capture.enabled, !whatsApp.isConnected {
            status = "chatsoff"
        } else if capture.status == .needsAccess {
            status = "chatsaccess"
        }
        return CompanionResponse(id: request.id, ok: true, message: status, inbox: Array(chats))
    }

    /// One chat's messages. Opening it on the phone reads it the way opening it on the Mac does (Settings › Connections, in
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
        if readOnOpen, current.read != .read { app.readOpenedChat(current) }
        let page = inboxPage(current, before: nil)
        var response = CompanionResponse(id: request.id, ok: true, inboxLines: page.lines, inboxTyping: Self.typing(current.id))
        response.inboxMore = page.more || app.canLoadOlderChat(current)
        return response
    }

    /// Your own words to a chat the Chats tab writes in (to one of its messages, when `replyTo` is set and the app
    /// quotes), sent and logged as the Chats tab sends them.
    func inboxSend(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        guard let route = app.chatRoute(for: entry) else { return .failure(request.id, .notAllowedFromPhone) }
        let hasFiles = request.images?.isEmpty == false || request.attachments?.isEmpty == false
        // A picture or a file may go without words, as from the Mac's composer.
        let words = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = words.isEmpty && hasFiles ? "" : CompanionPolicy.cleanMessage(request.text ?? "")
        // "@nook …" asks Nook to write the message, which is never sent as it is; that stays on the Mac.
        guard let text, ChatDraft.instruction(in: text) == nil else { return .failure(request.id, .badRequest) }
        do {
            let replyTo = app.chatAbilities(route).reply ? request.replyTo : nil
            if hasFiles {
                try await sendFiles(request, text: text, entry: entry, route: route, replyTo: replyTo, app: app)
            } else {
                try await app.sendChatText(text, route: route, chat: entry.name, replyTo: replyTo, thread: entry.id)
            }
            audit("chat_send", entry.name)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
        return CompanionResponse(id: request.id, ok: true, inboxLines: inboxEntry(entry.id).map { inboxPage($0, before: nil).lines } ?? [],
                                 inboxTyping: Self.typing(entry.id))
    }

    /// The pictures and files of a message from the phone, saved on this Mac and sent as the Mac's composer sends them:
    /// the words go as the caption of the first that carries one, else after them. Only kinds the chat's app takes.
    private func sendFiles(_ request: CompanionRequest, text: String, entry: ChatsEntry, route: ChatRoute, replyTo: String?,
                           app: AppModel) async throws {
        guard let saved = CompanionImages.save(request.images), let files = CompanionFiles.save(request.attachments, images: request.images) else {
            throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
        }
        let sends = app.chatSends(route)
        var attachments: [ChatAttachment] = []
        for url in saved { if let attachment = ChatAttachment(url: url, as: .photo) { attachments.append(attachment) } }
        for url in files { if let attachment = ChatAttachment(url: url) { attachments.append(attachment) } }
        guard !attachments.isEmpty, attachments.allSatisfy({ sends.contains(ChatOutgoing.Kind($0.kind)) }) else {
            throw NookError(tr(ChatAction.Refusal.unsupported.rawValue))
        }
        var caption = text
        for (index, var attachment) in attachments.enumerated() {
            if !caption.isEmpty, ChatForward.captioned.contains(attachment.kind) {
                attachment.caption = caption
                caption = ""
            }
            try await app.sendChatItem(.file(attachment), route: route, chat: entry.name, replyTo: index == 0 ? replyTo : nil,
                                       thread: entry.id)
        }
        if !caption.isEmpty { try await app.sendChatText(caption, route: route, chat: entry.name, thread: entry.id) }
    }

    /// Read or unread by hand, as on the Mac: read is passed on to the chat's app where Nook can tell it (so the sender
    /// sees it), else read in Nook; unread is Nook's alone. An app Nook can only open stays as it is from the phone.
    func inboxMark(_ request: CompanionRequest, app: AppModel, allKinds: Bool = false) -> CompanionResponse {
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
        return inbox(request, app: app, allKinds: allKinds)
    }

    /// A chat the Chats tab lists: one you hid in WhatsApp, or of an app you switched off, cannot be reached.
    func inboxEntry(_ id: String?) -> ChatsEntry? {
        guard let id, !id.isEmpty else { return nil }
        _ = ChatCaptureService.shared.loadedInbox
        return ChatsEntry.all(capture: ChatCaptureService.shared).first { $0.id == ChatIDMigration.current(id) }
    }

    func digest(_ entry: ChatsEntry, app: AppModel) -> InboxChatDigest {
        let route = app.chatRoute(for: entry)
        let abilities = app.chatAbilities(route)
        var digest = InboxChatDigest(id: entry.id, app: entry.app, appName: MessagingApps.app(id: entry.app)?.name ?? entry.app,
                                     name: CompanionPolicy.clip(entry.name, limit: 120), preview: CompanionPolicy.clip(entry.preview, limit: 200),
                                     last: entry.last.timeIntervalSince1970, unread: entry.unread, canSend: route != nil,
                                     ticks: entry.ticks.map(Self.ticks), waitsInApp: entry.waitsInApp, typing: Self.typing(entry.id),
                                     // The chat's own picture, else its photo from Contacts, as the Mac's Chats tab shows it.
                                     avatar: CompanionAvatars.version(entry.avatar)
                                         ?? CompanionAvatars.contactVersion(handle: entry.handle, name: entry.name))
        digest.abilities = InboxAbility.names(Self.abilities(abilities))
        digest.kind = entry.listKind.rawValue
        digest.pinned = entry.pinned
        if abilities.pin { digest.pinnedInApp = abilities.pinned }
        if abilities.mute { digest.mutedInApp = abilities.muted }
        digest.group = entry.kind == .group || (entry.members?.count ?? 0) > 1
        digest.account = entry.account.map { CompanionPolicy.clip($0, limit: 80) }
        digest.hasInfo = !(entry.members ?? []).isEmpty || entry.profile.map { !$0.isEmpty } == true || app.chatPhone(entry) != nil
        return digest
    }

    /// The Mac's `ChatAbilities` as the phone reads them.
    static func abilities(_ abilities: ChatAbilities) -> Set<InboxAbility> {
        var names: Set<InboxAbility> = []
        if abilities.reply { names.insert(.reply) }
        if abilities.react { names.insert(.react) }
        if abilities.edit { names.insert(.edit) }
        if abilities.delete { names.insert(.delete) }
        if abilities.deleteForMe { names.insert(.deleteForMe) }
        if abilities.markRead { names.insert(.markReadInApp) }
        if abilities.markUnread { names.insert(.markUnreadInApp) }
        if abilities.pin { names.insert(.pinInApp) }
        if abilities.mute { names.insert(.muteInApp) }
        if abilities.archive { names.insert(.archive) }
        if abilities.deleteChat { names.insert(.deleteChat) }
        if abilities.vote { names.insert(.vote) }
        if abilities.send, abilities.sends.contains(.photo) { names.insert(.photo) }
        if abilities.send, abilities.sends.contains(.file) { names.insert(.file) }
        return names
    }

    /// The chat the phone has open (`CompanionOp.watchChat`): read as `inboxChat` reads it, and from now on its messages
    /// follow over the live connection (`pushChats`). Nil `item` closes it.
    func watchChat(_ request: CompanionRequest, deviceID: String, app: AppModel) async -> CompanionResponse {
        let peer = streams.first { $0.deviceID == deviceID }
        guard request.item?.isEmpty == false else {
            peer?.watchChat = nil
            peer?.sentChatLines = nil
            return CompanionResponse(id: request.id, ok: true)
        }
        var response = await inboxChat(request, app: app)
        guard response.ok, let id = request.item else { return response }
        if let peer {
            peer.watchChat = id
            peer.sentChatLines = response.inboxLines
            peer.sentChatTyping = response.inboxTyping
        }
        response.inboxChat = id
        return response
    }

    /// The chats' pictures the phone asks for (`CompanionOp.avatars`): only of chats it can list, as small JPEGs.
    func avatars(_ request: CompanionRequest) async -> CompanionResponse {
        let wanted = Array((request.items ?? []).prefix(ChatAvatar.batch))
        guard !wanted.isEmpty else { return .failure(request.id, .badRequest) }
        var files: [(chat: String, path: String, version: String)] = []
        // App icons and photos from Contacts are made here; a chat's own picture file is read off the main thread.
        var made: [ChatAvatar] = []
        for id in wanted {
            if id.hasPrefix(ChatAvatar.appPrefix) {
                if let icon = CompanionAvatars.appIcon(id) { made.append(icon) }
                continue
            }
            guard let entry = inboxEntry(id) else { continue }
            if let path = entry.avatar, let version = CompanionAvatars.version(path) {
                files.append((id, path, version))
            } else if let photo = CompanionAvatars.contactPicture(chat: id, handle: entry.handle, name: entry.name) {
                made.append(photo)
            }
        }
        return CompanionResponse(id: request.id, ok: true, avatars: made + (await CompanionAvatars.pictures(files)))
    }

    /// The lines of the chat a live phone has open, as `inboxChat` answers them, without reading the chat from its app
    /// again: what came in since is in the shared inbox already. Nil when the chat is gone.
    func liveChatLines(_ id: String) -> (lines: [InboxLine], typing: [InboxTypist], more: Bool)? {
        guard let entry = inboxEntry(id) else { return nil }
        let page = inboxPage(entry, before: nil)
        return (page.lines, Self.typing(entry.id), page.more || ChatCaptureService.shared.canLoadOlder(entry.id))
    }

    /// The Chats tab's list as the phone gets it, for the live connection.
    func liveInbox(app: AppModel, allKinds: Bool = false) -> CompanionResponse {
        inbox(CompanionRequest(op: .inbox), app: app, allKinds: allKinds)
    }

    /// Who is typing in a chat now, as the Chats tab on the Mac shows it.
    static func typing(_ chat: String) -> [InboxTypist] {
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

    /// The chat's thread without the messages you deleted for yourself, as the Chats tab shows it.
    private func visibleThread(_ entry: ChatsEntry) -> InboxThread? {
        guard var thread = ChatCaptureService.shared.loadedInbox.threads[entry.id] else { return nil }
        thread.messages = ChatHiddenMessages.shared.visible(thread.messages, in: entry.id) { $0.id }
        return thread
    }

    /// Every bubble of a chat as the Chats tab shows it, for an action on one of them.
    func inboxBubbles(_ entry: ChatsEntry) -> [ChatBubble] {
        visibleThread(entry).map { ChatBubble.bubbles($0) { _ in "" } } ?? []
    }

    /// One page of a chat's messages that fits in one answer, oldest first: the newest ones (`before` nil), or the ones
    /// before the message `before`. `more`: there are older ones in Nook than this page. The newest page makes only its
    /// own bubbles: it is made again for every live update of an open chat.
    func inboxPage(_ entry: ChatsEntry, before: String?) -> (lines: [InboxLine], more: Bool) {
        // The same bubbles as the Chats tab, for every app: answers quote what they answer, emoji and ticks show as there.
        guard let thread = visibleThread(entry) else { return ([], false) }
        var bubbles: [ChatBubble]
        let total: Int
        if let before {
            bubbles = ChatBubble.bubbles(thread) { _ in "" }
            guard let index = bubbles.firstIndex(where: { $0.id == before }) else { return ([], false) }
            bubbles = Array(bubbles[..<index])
            total = bubbles.count
        } else {
            bubbles = ChatBubble.bubbles(thread, last: InboxPaging.pageSize) { _ in "" }
            total = thread.messages.count
        }
        let lines = CompanionPolicy.newestFitting(bubbles.suffix(InboxPaging.pageSize).map(Self.line))
        return (lines, total > lines.count)
    }

    /// The bubbles of these messages alone, for their photos.
    func inboxBubbles(_ entry: ChatsEntry, ids: Set<String>) -> [ChatBubble] {
        guard let thread = visibleThread(entry) else { return [] }
        return thread.messages.filter { ids.contains($0.id) }.map { ChatBubble($0, time: "") }
    }

    /// One bubble as the phone draws it: its text, its file and photo, its poll, its quote, the emoji, the ticks.
    static func line(_ bubble: ChatBubble) -> InboxLine {
        let text = bubble.notice ?? (bubble.deleted && !bubble.keepsDeleted ? bubble.deletedLine : ChatFormat.plain(bubble.text))
        var line = InboxLine(id: bubble.id, text: CompanionPolicy.clip(bubble.poll?.line ?? text),
                             date: (bubble.date ?? Date()).timeIntervalSince1970, sender: CompanionPolicy.clip(bubble.sender, limit: 120),
                             fromMe: bubble.fromMe, attachment: bubble.attachment.map { CompanionPolicy.clip($0, limit: 120) },
                             ticks: bubble.ticks.map(Self.ticks),
                             quoteSender: bubble.quote.map { CompanionPolicy.clip($0.sender, limit: 120) },
                             quoteText: bubble.quote.map { CompanionPolicy.clip($0.text, limit: 200) },
                             reactions: bubble.reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji },
                             readers: Self.readers(bubble))
        let mine = bubble.reactions.filter(\.mine).map(\.emoji)
        if !mine.isEmpty { line.myReactions = mine }
        if bubble.edited { line.edited = true }
        if bubble.deleted { line.deleted = true }
        if bubble.notice != nil { line.notice = true }
        if bubble.local { line.local = true }
        if let poll = bubble.poll {
            line.poll = InboxPoll(question: CompanionPolicy.clip(poll.question, limit: 300),
                                  options: poll.options.prefix(32).map {
                                      InboxPoll.Option(text: CompanionPolicy.clip($0.text, limit: 200), votes: $0.votes, chosen: $0.chosen)
                                  },
                                  multiple: poll.multiple, counted: poll.counted)
        }
        let media = CompanionChatMedia.describe(bubble)
        line.media = media.kind
        line.thumb = media.version
        line.seconds = media.seconds
        return line
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
