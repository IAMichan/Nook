import Foundation

/// Beeper Desktop's local API (Settings › Developers in Beeper, port 23373) as chats for the Chats tab: every network
/// linked in Beeper, each chat under its own app (Instagram, Messenger, Discord, Signal, LinkedIn, X…). Foundation only,
/// so it can be tested anywhere; `BeeperBridge` makes the calls. Endpoints: /v1/chats, /v1/chats/{id}/messages.
enum BeeperData {
    struct Chat: Equatable, Sendable {
        var id: String
        /// The app in Nook (`MessagingApp.id`) for its network.
        var app: String
        var title: String
        var isGroup: Bool
        var unread: Int
        var last: Date?
        /// The chat's picture as Beeper gives it (a file on this Mac or an `mxc://` address): the group's own, or the
        /// other person's in a private chat.
        var picture: String? = nil
        /// A group's other people by name (you left out), as far as Beeper lists them with the chat.
        var members: [String] = []
        /// Your own id in it, to tell your emoji from the others'.
        var me: String? = nil
        /// Pinned or muted in its app.
        var isPinned = false
        var isMuted = false
        /// What its app takes besides text: editing or deleting your messages, and emoji on a message.
        var canEdit = true
        var canDelete = true
        var canReact = true
    }

    /// Beeper's networks by the words in their name or account id ("instagramgo", "Facebook/Messenger", "Twitter/X"),
    /// most specific first.
    private static let networks: [(word: String, app: String)] = [
        ("whatsapp", "whatsapp"), ("instagram", "instagram"), ("messenger", "messenger"), ("facebook", "messenger"),
        ("telegram", "telegram"), ("signal", "signal"), ("discord", "discord"), ("linkedin", "linkedin"),
        ("twitter", "x"), ("slack", "slack"), ("teams", "teams"), ("imessage", "messages"), ("googlechat", "googlechat"),
        ("google chat", "googlechat"), ("hungryserv", "beeper"), ("beeper", "beeper"), ("matrix", "beeper"),
    ]

    /// The app for a chat's network; nil for a network Nook has no source for (it is left out).
    static func app(network: String, account: String) -> String? {
        let words = (network + " " + account).lowercased()
        return networks.first { words.contains($0.word) }?.app
    }

    /// The chats of /v1/chats, without archived ones, merged ones and those of networks Nook does not know.
    static func chats(_ json: [String: Any]) -> [Chat] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { chat in
            guard let id = chat["id"] as? String, chat["isArchived"] as? Bool != true, chat["merge"] == nil,
                  (chat["mergedIntoChatID"] as? String ?? "").isEmpty,
                  let source = Self.app(network: (chat["network"] as? String) ?? "", account: (chat["accountID"] as? String) ?? "") else { return nil }
            let title = ((chat["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let unread = (chat["unreadCount"] as? Int) ?? Int((chat["unreadCount"] as? Double) ?? 0)
            let isGroup = chat["type"] as? String == "group"
            let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let abilities = chat["capabilities"] as? [String: Any]
            return Chat(id: id, app: source, title: title, isGroup: isGroup, unread: unread,
                        last: ChatJSON.date(chat["lastActivity"]), picture: picture(chat), members: isGroup ? members(chat) : [],
                        me: people.first { $0["isSelf"] as? Bool == true }?["id"] as? String,
                        isPinned: chat["isPinned"] as? Bool == true, isMuted: chat["isMuted"] as? Bool == true,
                        canEdit: supports(abilities?["edit"]), canDelete: supports(abilities?["delete"]),
                        canReact: supports(abilities?["reaction"]))
        }
    }

    /// A capability level (-2 rejected … 2 fully supported); one that is not given counts as there, and the app says
    /// so when it is not.
    static func supports(_ level: Any?) -> Bool {
        guard let level = (level as? Int) ?? (level as? Double).map(Int.init) else { return true }
        return level > 0
    }

    /// Nook's id of a message in a chat, and back: "beeper-<chat>-<message>".
    static func messageID(_ id: String, chat: String) -> String { "beeper-\(chat)-\(id)" }

    static func networkID(_ id: String, chat: String) -> String? {
        let prefix = "beeper-\(chat)-"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }

    /// The messages of /v1/chats/{id}/messages that were deleted, by their id in Nook.
    static func deleted(_ json: [String: Any], chat: Chat) -> [String] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { message in
            guard message["isDeleted"] as? Bool == true, let id = message["id"] as? String else { return nil }
            return messageID(id, chat: chat.id)
        }
    }

    /// The emoji on a message, the most used first; yours are those of `me`.
    static func reactions(_ message: [String: Any], me: String?) -> [InboxReaction] {
        var counts: [String: (count: Int, mine: Bool, first: Int)] = [:]
        for (index, reaction) in (message["reactions"] as? [[String: Any]] ?? []).enumerated() {
            guard let key = reaction["reactionKey"] as? String, !key.isEmpty else { continue }
            let mine = me != nil && reaction["participantID"] as? String == me
            let known = counts[key] ?? (0, false, index)
            counts[key] = (known.count + 1, known.mine || mine, known.first)
        }
        return counts.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.first < $1.value.first }
            .map { InboxReaction(emoji: $0.key, count: $0.value.count, mine: $0.value.mine) }
    }

    /// How far your message got: its send status, then whether it was delivered or seen.
    static func receipt(_ message: [String: Any]) -> ChatReceipt {
        let status = message["sendStatus"] as? [String: Any]
        switch status?["status"] as? String {
        case "PENDING": return .pending
        case "FAIL_RETRIABLE", "FAIL_PERMANENT": return .failed
        default: break
        }
        if seen(message["seen"]) { return .read }
        if !((status?["deliveredToUsers"] as? [String]) ?? []).isEmpty { return .delivered }
        return .sent
    }

    /// Whether a message was seen: `true`, a time, or (in a group) by anyone.
    private static func seen(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let time as String: return !time.isEmpty
        case let people as [String: Any]: return people.values.contains { seen($0) }
        default: return false
        }
    }

    /// What one event of /v1/ws asks for: subscribing once the socket is ready, reading a chat that changed again.
    enum Event: Equatable {
        case ready
        case subscribed
        case changed(chat: String)
        case other
    }

    static func event(_ json: [String: Any]) -> Event {
        switch json["type"] as? String {
        case "ready": return .ready
        case "subscriptions.updated": return .subscribed
        case "chat.upserted", "chat.deleted", "message.upserted", "message.deleted":
            guard let chat = json["chatID"] as? String, !chat.isEmpty else { return .other }
            return .changed(chat: chat)
        default: return .other
        }
    }

    /// What the socket sends once it is ready: every chat's changes.
    static let subscribeAll: [String: Any] = ["type": "subscriptions.set", "chatIDs": ["*"]]

    /// The people of a chat Beeper lists with it, yourself (`isSelf`) left out: their full name, else their username.
    static func members(_ chat: [String: Any]) -> [String] {
        let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return people.compactMap { person in
            guard person["isSelf"] as? Bool != true else { return nil }
            let name = ((person["fullName"] as? String) ?? (person["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// A chat's picture: its own, else (in a private chat) the other person's.
    static func picture(_ chat: [String: Any]) -> String? {
        if let own = chat["imgURL"] as? String, !own.isEmpty { return own }
        guard chat["type"] as? String != "group" else { return nil }
        let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return people.first { $0["isSelf"] as? Bool != true }.flatMap { $0["imgURL"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The messages of /v1/chats/{id}/messages, oldest first, without reactions, hidden and deleted ones.
    static func messages(_ json: [String: Any], chat: Chat) -> [InboxMessage] {
        let messages: [InboxMessage] = (json["items"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, message["type"] as? String != "REACTION",
                  message["isHidden"] as? Bool != true, message["isDeleted"] as? Bool != true,
                  let sent = ChatJSON.date(message["timestamp"]) else { return nil }
            var text = ((message["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let media = (message["attachments"] as? [[String: Any]])?.first.flatMap(Self.file)
            if text.isEmpty, media == nil { text = label(message) }
            // Beeper writes a file's name as the text of a message with only that file.
            if let name = media?.name, text == name { text = "" }
            guard !text.isEmpty || media != nil else { return nil }
            let mine = message["isSender"] as? Bool == true
            let sender = mine || !chat.isGroup ? "" : ((message["senderName"] as? String) ?? "")
            var inbox = InboxMessage(id: messageID(id, chat: chat.id), sender: sender, text: text, date: sent, fromMe: mine,
                                     media: media)
            if mine { inbox.receipt = receipt(message) }
            // An empty list too: the last emoji taken back leaves none.
            inbox.reactions = reactions(message, me: chat.me)
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// An attachment: what it is (Beeper says whether it is a GIF, a sticker or a voice message), and where it is:
    /// a file on this Mac once Beeper has it, else Beeper's own address for it, fetched through its API.
    static func file(_ attachment: [String: Any]) -> ChatMedia? {
        let name = (attachment["fileName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let source = (attachment["srcURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard name != nil || source != nil else { return nil }
        var kind = ChatMedia.kind(mimeType: attachment["mimeType"] as? String, name: name,
                                  sticker: attachment["isSticker"] as? Bool == true, gif: attachment["isGif"] as? Bool == true,
                                  voice: attachment["isVoiceNote"] as? Bool == true)
        if kind == .file {
            switch attachment["type"] as? String {
            case "img": kind = .photo
            case "video": kind = .video
            case "audio": kind = .audio
            default: break
            }
        }
        var media = ChatMedia(kind: kind, name: name, seconds: attachment["duration"] as? Double)
        if let source, let url = URL(string: source), url.isFileURL {
            media.path = url.path
        } else {
            media.source = source
        }
        return media
    }

    /// What a message without text holds: its file's name, else its kind.
    private static func label(_ message: [String: Any]) -> String {
        let attachment = (message["attachments"] as? [[String: Any]])?.first
        if let name = attachment?["fileName"] as? String, !name.isEmpty { return name }
        switch message["type"] as? String {
        case "IMAGE": return tr("whatsapp.file.photo")
        case "VIDEO": return tr("whatsapp.file.video")
        case "VOICE", "AUDIO": return tr("whatsapp.file.voice")
        case "FILE": return tr("whatsapp.file.document")
        case "STICKER": return "🙂"
        case "LOCATION": return "📍"
        default: return attachment == nil ? "" : tr("whatsapp.file.document")
        }
    }
}
