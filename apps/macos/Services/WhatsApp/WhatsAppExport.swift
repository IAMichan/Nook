// WhatsApp's chats as every chat app's: what the linked phone's link keeps (`WAInbox`, by JIDs, with each person's
// emoji, each voter's choice and each member's ticks) turned into the shared inbox's `BridgedChat`, by the names your
// Contacts and the phone give them. The link stays WhatsApp's own (the gateway, its ids, its ledgers); everything Nook
// shows of WhatsApp reads what comes out of here, as it reads every other app's chats. Tested in
// Tests/NookTests/WhatsAppExportTests.swift.
import Foundation

enum WhatsAppExport {
    /// What the link knows of a chat besides its messages, as `chat(_:)` needs it.
    struct Facts: Equatable {
        /// The chat's key across accounts (`WAChatKey`): its id in the shared inbox.
        var key: String
        /// The account's name while more than one is linked; nil otherwise.
        var account: String? = nil
        /// Messages new in Nook, as the link counts them (`WhatsAppLink.unread`).
        var unread: Int = 0
        /// Still unread in WhatsApp itself (`WhatsAppLink.waitsInWhatsApp`).
        var waitsInApp: Bool = false
        /// Muted on the phone (`WhatsAppLink.mutedChats`).
        var mutedInApp: Bool = false
        /// Whether the link knows where the chat stands (`WhatsAppLink.readIsKnown`).
        var readKnown: Bool = true
        /// The chat's picture on this Mac.
        var avatar: String? = nil
        /// The phone's list has it: it shows while the phone lists it, also without messages.
        var listed: Bool = false
        /// When the phone's list says it last had a message.
        var activity: Date? = nil
        /// The file fetched for each message so far (photos, videos, documents, voice messages), by message id.
        var files: [String: String] = [:]
        /// In a group: the profile photo on this Mac of each person who wrote one of `messages`, by their JID.
        var faces: [String: String] = [:]
    }

    /// A chat of the link as the shared inbox keeps it: its messages as every app's, each person by the name your
    /// Contacts and the phone give them (`ephemeral`: removed from Nook's archive when WhatsApp is turned off).
    static func chat(_ conversation: WAConversation, facts: Facts, names book: WANameBook) -> BridgedChat {
        var names = WAMemberIndex(conversation, book: book)
        let kind = ChatKind(conversation.kind)
        let group = kind == .group
        let messages = conversation.messages.map { message in
            self.message(message, in: conversation, kind: kind, names: &names, files: facts.files)
        }
        var chat = BridgedChat(app: "whatsapp", name: conversation.name, messages: messages, unread: facts.unread,
                               avatar: facts.avatar, members: group && conversation.members != nil ? names.all : nil,
                               listed: facts.listed, chatID: facts.key, account: facts.account, kind: kind,
                               handle: kind == .person ? conversation.id : nil, readKnown: facts.readKnown,
                               hasOlder: conversation.hasOlder, history: false)
        chat.activity = max(conversation.lastActivity, facts.activity ?? .distantPast)
        chat.waitsInApp = facts.waitsInApp
        chat.mutedInApp = facts.mutedInApp
        chat.ephemeral = true
        if group, !facts.faces.isEmpty { chat.faces = facts.faces }
        if group, let members = conversation.members { chat.profile = profile(conversation.profile, members: members, names: &names) }
        if kind == .person {
            // Their number (not for an @lid, which is no number), and what the gateway said of them.
            var person = conversation.person ?? ChatProfile()
            if !conversation.id.hasSuffix("@lid") { person.phone = WAJID.displayNumber(conversation.id) }
            if person.ownName == conversation.name { person.ownName = nil }
            chat.profile = person.isEmpty ? nil : person
        }
        return chat
    }

    /// What the gateway says of a group, everyone by their name in it: its admins (you as yourself), who set the
    /// description and who made it.
    static func profile(_ group: WAGroupProfile?, members: [WAMember], names: inout WAMemberIndex) -> ChatProfile? {
        var admins: [String] = []
        // By the same names the member list shows (`WAMemberIndex.all`), so the list marks them.
        for (member, name) in zip(members, names.all) where member.admin { admins.append(name) }
        if group?.youAreAdmin == true { admins.append(ChatMembership.me) }
        guard let group else { return admins.isEmpty ? nil : ChatProfile(admins: admins) }
        var profile = ChatProfile(about: group.about, aboutSince: group.aboutSince, created: group.created,
                                  admins: admins, adminsOnly: group.adminsOnly, locked: group.locked)
        if let by = group.aboutBy { profile.aboutBy = names.name(by) }
        if let by = group.createdBy { profile.createdBy = names.name(by) }
        return profile
    }

    /// A chat the phone lists that wrote nothing Nook holds yet: its row, with when it last had a message.
    static func listed(_ info: WAChatInfo, name: String, facts: Facts) -> BridgedChat {
        let kind = ChatKind(WAJID.kind(info.jid))
        var chat = BridgedChat(app: "whatsapp", name: name, messages: [], unread: facts.unread, avatar: facts.avatar,
                               listed: true, chatID: facts.key, account: facts.account, kind: kind,
                               handle: kind == .person ? info.jid : nil, readKnown: facts.readKnown)
        chat.activity = max(info.last, facts.activity ?? .distantPast)
        chat.waitsInApp = facts.waitsInApp
        chat.mutedInApp = facts.mutedInApp
        chat.ephemeral = true
        return chat
    }

    /// One message as every app's: who wrote it by name in a group, its file, its poll with who voted, its emoji with
    /// who put them there, the message it answers, and your own message's ticks and readers.
    static func message(_ message: WAMessage, in conversation: WAConversation, kind: ChatKind, names: inout WAMemberIndex,
                        files: [String: String]) -> InboxMessage {
        let group = kind == .group
        // A group's messages and the status updates of your contacts (one chat for everyone) say who wrote them.
        let named = group || kind == .status
        var inbox = InboxMessage(id: message.id, sender: named && !message.fromMe ? names.name(message.sender) : "",
                                 text: names.namingMentions(in: text(message)), date: message.date, fromMe: message.fromMe)
        inbox.media = media(message, path: files[message.id])
        // Who voted or put an emoji there: in a group or a status by name, in a private chat the chat itself.
        inbox.poll = message.poll?.chatPoll { id in named ? names.name(id) : conversation.name }
        inbox.receipt = message.fromMe ? message.receipt : nil
        inbox.readers = readers(message, kind: kind, hasMembers: conversation.members != nil, names: &names)
        inbox.reactions = reactions(message.reactions) { id in named ? names.name(id) : conversation.name }
        if let replyTo = message.replyTo {
            inbox.quote = InboxQuote(id: replyTo, text: names.namingMentions(in: message.quotedText ?? ""))
        }
        inbox.mentionsMe = message.mentionsMe
        inbox.senderID = message.fromMe ? nil : WAJID.normalized(message.sender)
        if let change = message.groupChange {
            var people: [String] = []
            for jid in change.people { people.append(jid == ChatMembership.me ? jid : names.name(jid)) }
            var by = change.by
            if let jid = by, jid != ChatMembership.me { by = names.name(jid) }
            inbox.groupChange = ChatGroupChange(change.kind, by: by, text: change.text, people: people)
            inbox.sender = ""
            inbox.senderID = nil
        }
        if let membership = message.membership {
            // Everyone by their name in the group, you as yourself; the line says who did it, not a sender above it.
            var people: [String] = []
            for jid in membership.people { people.append(jid == ChatMembership.me ? jid : names.name(jid)) }
            var by = membership.by
            if let jid = by, jid != ChatMembership.me { by = names.name(jid) }
            inbox.membership = ChatMembership(membership.change, by: by, people: people)
            inbox.sender = ""
            inbox.senderID = nil
        }
        if message.edited { inbox.edited = true }
        return message.deleted ? inbox.withdrawn() : inbox
    }

    /// The message's words: its text, after what came with it when that has no file of its own to show (a place, a
    /// contact card, something WhatsApp sends without a kind).
    static func text(_ message: WAMessage) -> String {
        let kind: String?
        switch message.media {
        case .location: kind = "📍 " + tr("chat.media.location")
        case .contact: kind = "👤 " + tr("chat.media.contact")
        case .other: kind = message.text.isEmpty ? tr("chat.media.attachment") : nil
        default: kind = nil
        }
        return [kind, message.text.isEmpty ? nil : message.text].compactMap { $0 }.joined(separator: " ")
    }

    /// The messages a chat no longer holds that it held when it was last handed over, newer than its oldest now: gone
    /// from the gateway's history (deleted for everyone), not let go of because the chat keeps only its newest. The
    /// shared inbox shows them as deleted.
    static func deleted(before: BridgedChat?, now: BridgedChat) -> [String] {
        guard let before, let oldest = now.messages.first?.date else { return [] }
        let kept = Set(now.messages.map(\.id))
        // A change in who is in the group only ever came live: the history never has it.
        return before.messages.filter { !kept.contains($0.id) && $0.date >= oldest && !$0.isNotice }.map(\.id)
    }

    /// The file that came with a message, the same for every app, from this Mac once the link fetched it (`path`).
    static func media(_ message: WAMessage, path: String?) -> ChatMedia? {
        message.media.chatMedia(path: path)
    }

    /// Your own message's readers: in a private chat the other person (whom the chat names), in a group every member
    /// who answered by their name, also while none did once the group's members are known (the info then lists who does
    /// not have it yet). Nil for theirs, and wherever WhatsApp says nothing per person.
    static func readers(_ message: WAMessage, kind: ChatKind, hasMembers: Bool, names: inout WAMemberIndex) -> [ChatReader]? {
        guard message.fromMe, message.receipt != nil else { return nil }
        switch kind {
        case .person:
            return message.readers.values.map { ChatReader(name: "", receipt: $0.receipt, date: $0.date) }
        case .group:
            guard !message.readers.isEmpty || hasMembers else { return nil }
            return message.readers.sorted { $0.key < $1.key }.map { id, reader in
                ChatReader(name: names.name(id), receipt: reader.receipt, date: reader.date, key: WAJID.normalized(id))
            }
        case .status, .channel:
            return nil
        }
    }

    /// The emoji on a message, one chip each with who put it there, the most used first (then in the order they came).
    static func reactions(_ reactions: [WAReaction], name: (String) -> String) -> [InboxReaction] {
        var chips: [InboxReaction] = []
        for reaction in reactions where !reaction.emoji.isEmpty {
            // Who put it there, by the name the chat knows them by; you are told apart by `mine`.
            let person = reaction.fromMe ? "" : name(reaction.sender)
            if let index = chips.firstIndex(where: { $0.emoji == reaction.emoji }) {
                chips[index].count += 1
                chips[index].mine = chips[index].mine || reaction.fromMe
                if !person.isEmpty { chips[index].people = (chips[index].people ?? []) + [person] }
            } else {
                chips.append(InboxReaction(emoji: reaction.emoji, count: 1, mine: reaction.fromMe,
                                           people: person.isEmpty ? nil : [person]))
            }
        }
        return chips.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }
}
