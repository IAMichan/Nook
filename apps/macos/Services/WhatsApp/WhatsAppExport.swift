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
    }

    /// A chat of the link as the shared inbox keeps it: its messages as every app's, each person by the name your
    /// Contacts and the phone give them, kept in memory only (`ephemeral`).
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
        chat.ephemeral = true
        return chat
    }

    /// A chat the phone lists that wrote nothing Nook holds yet: its row, with when it last had a message.
    static func listed(_ info: WAChatInfo, name: String, facts: Facts) -> BridgedChat {
        let kind = ChatKind(WAJID.kind(info.jid))
        var chat = BridgedChat(app: "whatsapp", name: name, messages: [], unread: facts.unread, avatar: facts.avatar,
                               listed: true, chatID: facts.key, account: facts.account, kind: kind,
                               handle: kind == .person ? info.jid : nil, readKnown: facts.readKnown)
        chat.activity = max(info.last, facts.activity ?? .distantPast)
        chat.waitsInApp = facts.waitsInApp
        chat.ephemeral = true
        return chat
    }

    /// One message as every app's: who wrote it by name in a group, its file, its poll with who voted, its emoji with
    /// who put them there, the message it answers, and your own message's ticks and readers.
    static func message(_ message: WAMessage, in conversation: WAConversation, kind: ChatKind, names: inout WAMemberIndex,
                        files: [String: String]) -> InboxMessage {
        let group = kind == .group
        var inbox = InboxMessage(id: message.id, sender: group && !message.fromMe ? names.name(message.sender) : "",
                                 text: text(message), date: message.date, fromMe: message.fromMe)
        inbox.media = media(message, path: files[message.id])
        // Who voted or put an emoji there: in a group by name, in a private chat the chat itself.
        inbox.poll = message.poll?.chatPoll { id in group ? names.name(id) : conversation.name }
        inbox.receipt = message.fromMe ? message.receipt : nil
        inbox.readers = readers(message, kind: kind, hasMembers: conversation.members != nil, names: &names)
        inbox.reactions = reactions(message.reactions) { id in group ? names.name(id) : conversation.name }
        if let replyTo = message.replyTo {
            inbox.quote = InboxQuote(id: replyTo, text: message.quotedText ?? "")
        }
        inbox.mentionsMe = message.mentionsMe
        inbox.senderID = message.fromMe ? nil : WAJID.normalized(message.sender)
        return inbox
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

    /// The file that came with a message, the same for every app, from this Mac once the link fetched it (`path`).
    static func media(_ message: WAMessage, path: String?) -> ChatMedia? {
        switch message.media {
        case .image: return ChatMedia(kind: .photo, path: path)
        case .video: return ChatMedia(kind: .video, path: path)
        case .audio(let seconds): return ChatMedia(kind: .audio, path: path, seconds: seconds.map(Double.init))
        case .voice(let seconds): return ChatMedia(kind: .voice, path: path, seconds: seconds.map(Double.init))
        case .document(let name): return ChatMedia(kind: .file, name: name, path: path)
        case .sticker: return ChatMedia(kind: .sticker, path: path)
        case .none, .location, .contact, .other: return nil
        }
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

extension ChatKind {
    /// WhatsApp's kind of chat by its JID, by the shared name.
    init(_ kind: WAJID.Kind) {
        switch kind {
        case .person: self = .person
        case .group: self = .group
        case .status: self = .status
        case .channel: self = .channel
        }
    }
}
