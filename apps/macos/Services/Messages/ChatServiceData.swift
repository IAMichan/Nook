import Foundation

/// The local API of Nook's own chat helper (nook-chatd, see `ChatHelper`) as chats for the Chats tab: every app linked
/// through it, each chat under its own app (Instagram, Messenger, Signal, LinkedIn, X…). Foundation only, so it can be
/// tested anywhere; `ChatServiceBridge` makes the calls. Endpoints: /v1/chats, /v1/chats/{id}/messages. Beeper Desktop's
/// API has the same shape, so `BeeperImport` reads it with these too.
enum ChatServiceData {
    struct Chat: Equatable, Sendable {
        var id: String
        /// The app in Nook (`MessagingApp.id`) for its network.
        var app: String
        var title: String
        var isGroup: Bool
        var unread: Int
        var last: Date?
        /// The chat's picture as the service gives it (a file on this Mac or an `mxc://` address): the group's own, or
        /// the other person's in a private chat.
        var picture: String? = nil
        /// A group's other people by name (you left out), as far as the service lists them with the chat.
        var members: [String] = []
        /// Your own id in it, to tell your emoji from the others'.
        var me: String? = nil
        /// Everyone's name by their id in it, to say who read your message.
        var people: [String: String] = [:]
        /// In a group: the other people's pictures as the service gives them (a file or an `mxc://` address), by their
        /// id, for the face beside their messages.
        var pictures: [String: String] = [:]
        /// Everyone's name by their number (`ChatMentions.key`), to show a tag by name instead of by number.
        var tags: [String: String] = [:]
        /// Pinned or muted in its app.
        var isPinned = false
        var isMuted = false
        /// What its app takes besides text: editing or deleting your messages, and emoji on a message.
        var canEdit = true
        var canDelete = true
        var canReact = true
        /// Its network takes votes on polls from Nook (WhatsApp and Signal through the helper).
        var canVote = false
        /// The account in its app (Instagram username, etc.), when the service gives one.
        var account: String? = nil
        /// What the network says of the chat: a group's description and admins, how long messages last, the other
        /// person's number or username.
        var profile: ChatProfile? = nil
    }

    /// The networks by the words in their name or account id ("instagramgo", "Facebook/Messenger", "Twitter/X"), most
    /// specific first.
    private static let networks: [(word: String, app: String)] = [
        ("whatsapp", "whatsapp"), ("instagram", "instagram"), ("messenger", "messenger"), ("facebook", "messenger"),
        ("telegram", "telegram"), ("signal", "signal"), ("discord", "discord"), ("linkedin", "linkedin"),
        ("twitter", "x"), ("slack", "slack"), ("teams", "teams"), ("imessage", "messages"), ("googlechat", "googlechat"),
        ("google chat", "googlechat"),
    ]

    /// The app for a chat's network; nil for a network Nook has no source for (it is left out).
    static func app(network: String, account: String) -> String? {
        let words = (network + " " + account).lowercased()
        return networks.first { words.contains($0.word) }?.app
    }

    /// The chats of /v1/chats, without archived ones, merged ones and those of networks Nook does not know.
    /// Whether answers in a row Nook shows for two chats of one name go to `chat`: the one that moved last.
    static func isNewest(_ chat: Chat, than other: Chat?) -> Bool {
        guard let other, other.id != chat.id else { return true }
        return (chat.last ?? .distantPast) >= (other.last ?? .distantPast)
    }

    /// The chats the helper lists, with two different chats of one name told apart (`ChatNames`). Two threads with the
    /// same person (Instagram keeps those) stay one row: `isNewest` picks the one answers go to.
    static func chats(_ json: [String: Any]) -> [Chat] {
        let chats = listedChats(json)
        let names = ChatNames.unique(chats.map { chat in
            let person = chat.isGroup ? nil : chat.people.keys.filter { $0 != chat.me }.sorted().first
            return ChatNames.Chat(id: chat.id, app: chat.app, name: chat.title, same: person.map { (chat.account ?? "") + "|" + $0 })
        })
        return chats.map { chat in
            var named = chat
            named.title = names[chat.id] ?? chat.title
            return named
        }
    }

    private static func listedChats(_ json: [String: Any]) -> [Chat] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { chat in
            guard let id = chat["id"] as? String, chat["isArchived"] as? Bool != true, chat["merge"] == nil,
                  (chat["mergedIntoChatID"] as? String ?? "").isEmpty,
                  let source = Self.app(network: (chat["network"] as? String) ?? "", account: (chat["accountID"] as? String) ?? "") else { return nil }
            let title = ((chat["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let unread = Int(ChatJSON.int64(chat["unreadCount"]) ?? 0)
            let isGroup = chat["type"] as? String == "group"
            let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let abilities = chat["capabilities"] as? [String: Any]
            let account = ((chat["account"] as? String) ?? ((chat["user"] as? [String: Any])?["username"] as? String))?
                .trimmingCharacters(in: .whitespaces)
            return Chat(id: id, app: source, title: title, isGroup: isGroup, unread: unread,
                        last: ChatJSON.date(chat["lastActivity"]), picture: picture(chat), members: isGroup ? members(chat) : [],
                        me: people.first { $0["isSelf"] as? Bool == true }?["id"] as? String, people: names(people),
                        pictures: isGroup ? pictures(people) : [:],
                        tags: tags(people), isPinned: chat["isPinned"] as? Bool == true, isMuted: chat["isMuted"] as? Bool == true,
                        canEdit: supports(abilities?["edit"]), canDelete: supports(abilities?["delete"]),
                        canReact: supports(abilities?["reaction"]), canVote: chat["canVote"] as? Bool == true,
                        account: (account?.isEmpty == false ? account : nil), profile: profile(chat, people: people, isGroup: isGroup))
        }
    }

    /// What a chat says of itself besides its people: a group's `description`, its admins (`isAdmin` people, you as
    /// yourself) and how long messages last (`disappearAfter`, seconds); in a private chat what the network says of the
    /// other person (`identifiers`: "tel:+31…", "mailto:…", a username; `isBot`).
    static func profile(_ chat: [String: Any], people: [[String: Any]], isGroup: Bool) -> ChatProfile? {
        var profile = ChatProfile(about: ChatProfile.text(chat["description"] as? String))
        if let seconds = ChatJSON.number(chat["disappearAfter"]), seconds > 0 { profile.disappearAfter = seconds }
        if isGroup {
            let admins = people.filter { $0["isAdmin"] as? Bool == true }.compactMap { person -> String? in
                person["isSelf"] as? Bool == true ? ChatMembership.me : ChatProfile.text(person["fullName"] as? String)
            }
            if !admins.isEmpty { profile.admins = admins }
        } else if let other = people.first(where: { $0["isSelf"] as? Bool != true }) {
            for identifier in other["identifiers"] as? [String] ?? [] {
                if identifier.hasPrefix("tel:") { profile.phone = profile.phone ?? String(identifier.dropFirst(4)) }
                else if identifier.hasPrefix("mailto:") { profile.email = profile.email ?? String(identifier.dropFirst(7)) }
                else if let colon = identifier.firstIndex(of: ":") {
                    // "instagram:anna.b", "x:anna": the username they go by on the network.
                    let name = identifier[identifier.index(after: colon)...]
                    if !name.isEmpty, !name.allSatisfy(\.isNumber), profile.username == nil { profile.username = "@" + name }
                }
            }
            if other["isBot"] as? Bool == true { profile.bot = true }
        }
        return profile.isEmpty ? nil : profile
    }

    /// A capability level (-2 rejected … 2 fully supported); one that is not given counts as there, and the app says
    /// so when it is not.
    static func supports(_ level: Any?) -> Bool {
        guard let level = ChatJSON.int64(level) else { return true }
        return level > 0
    }

    /// Nook's id of a message in a chat, and back: "nook-<chat>-<message>". An inbox stored with the earlier prefix
    /// ("beeper-") is renamed once when it is read (`ChatInbox.renameMessageIDs`), so no message comes in twice.
    static func messageID(_ id: String, chat: String) -> String { "\(idPrefix)\(chat)-\(id)" }

    static func networkID(_ id: String, chat: String) -> String? {
        let prefix = "\(idPrefix)\(chat)-"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }

    static let idPrefix = "nook-"
    /// The prefix before Nook had its own chat helper; only `ChatInbox.renameMessageIDs` still reads it.
    static let earlierIDPrefix = "beeper-"

    /// The service's own reason in an error answer (`{code, message}`).
    static func errorMessage(_ data: Data) -> String? {
        guard let object = ChatJSON.object(data) else { return nil }
        for key in ["message", "code"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// Whether a chat's messages stop before its newest activity: the list says it moved later than the newest message
    /// read (by more than a second, the rounding of the two), so that message is still on its way.
    static func isBehind(_ messages: [InboxMessage], chat: Chat) -> Bool {
        guard let last = chat.last, let newest = messages.last?.date else { return false }
        return newest < last.addingTimeInterval(-1)
    }

    /// The messages of /v1/chats/{id}/messages that were deleted, by their id in Nook: the chat shows them as deleted.
    static func deleted(_ json: [String: Any], chat: Chat) -> [String] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { message in
            guard message["isDeleted"] as? Bool == true, let id = message["id"] as? String else { return nil }
            return messageID(id, chat: chat.id)
        }
    }

    /// The emoji on a message, the most used first; yours are those of `me`.
    static func reactions(_ message: [String: Any], me: String?, people: [String: String] = [:]) -> [InboxReaction] {
        var counts: [String: (count: Int, mine: Bool, first: Int, names: [String])] = [:]
        for (index, reaction) in (message["reactions"] as? [[String: Any]] ?? []).enumerated() {
            guard let key = reaction["reactionKey"] as? String, !key.isEmpty else { continue }
            let person = reaction["participantID"] as? String
            let mine = me != nil && person == me
            var known = counts[key] ?? (0, false, index, [])
            known.count += 1
            known.mine = known.mine || mine
            if !mine, let person, let name = people[person], !name.isEmpty { known.names.append(name) }
            counts[key] = known
        }
        return counts.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.first < $1.value.first }
            .map { InboxReaction(emoji: $0.key, count: $0.value.count, mine: $0.value.mine,
                                 people: $0.value.names.isEmpty ? nil : $0.value.names) }
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

    /// Who has your message and who read it (and when), as far as the service says: `deliveredToUsers`, and `seen` as a
    /// time (a private chat: its person, without a name) or per person. Nil when it says nothing of the kind.
    static func readers(_ message: [String: Any], chat: Chat) -> [ChatReader]? {
        var readers: [String: ChatReader] = [:]
        let delivered = ((message["sendStatus"] as? [String: Any])?["deliveredToUsers"] as? [String]) ?? []
        for id in delivered where id != chat.me {
            readers[id] = ChatReader(name: chat.isGroup ? chat.people[id] ?? id : "", receipt: .delivered, key: chat.isGroup ? id : nil)
        }
        switch message["seen"] {
        case let time as String where !time.isEmpty && !chat.isGroup:
            return [ChatReader(name: "", receipt: .read, date: ChatJSON.date(time))]
        case let people as [String: Any]:
            for (id, value) in people where id != chat.me && seen(value) {
                readers[id] = ChatReader(name: chat.isGroup ? chat.people[id] ?? id : "", receipt: .read,
                                         date: ChatJSON.date(value), key: chat.isGroup ? id : nil)
            }
        default: break
        }
        guard !readers.isEmpty else { return nil }
        // The first to read first: a private chat's info takes the first one's time.
        return readers.values.sorted { a, b in
            a.receipt != b.receipt ? a.receipt > b.receipt : (a.date ?? .distantFuture) < (b.date ?? .distantFuture)
        }
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
        /// Someone in a chat is typing (or recording, or sending a file) for `seconds`; 0 says they stopped.
        case typing(chat: String, person: String, name: String, kind: ChatTypist.Kind, seconds: TimeInterval)
        case other
    }

    static func event(_ json: [String: Any]) -> Event {
        switch json["type"] as? String {
        case "ready": return .ready
        case "subscriptions.updated": return .subscribed
        case "chat.upserted", "chat.deleted", "message.upserted", "message.deleted":
            guard let chat = json["chatID"] as? String, !chat.isEmpty else { return .other }
            return .changed(chat: chat)
        case "typing":
            guard let chat = json["chatID"] as? String, !chat.isEmpty,
                  let person = json["userID"] as? String, !person.isEmpty else { return .other }
            let kind = ChatTypist.Kind(rawValue: (json["kind"] as? String) ?? "") ?? .text
            let millis = ChatJSON.number(json["timeoutMs"]) ?? 0
            return .typing(chat: chat, person: person, name: (json["name"] as? String) ?? "", kind: kind,
                           seconds: max(0, millis / 1000))
        default: return .other
        }
    }

    /// What the socket sends once it is ready: every chat's changes.
    static let subscribeAll: [String: Any] = ["type": "subscriptions.set", "chatIDs": ["*"]]

    /// The people of a chat the service lists with it, yourself (`isSelf`) left out: their full name, else their username.
    static func members(_ chat: [String: Any]) -> [String] {
        let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return people.compactMap { person in
            guard person["isSelf"] as? Bool != true else { return nil }
            let name = ((person["fullName"] as? String) ?? (person["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// The people of a chat by their id: their full name, else their username.
    static func names(_ people: [[String: Any]]) -> [String: String] {
        var names: [String: String] = [:]
        for person in people {
            guard let id = person["id"] as? String else { continue }
            let name = ((person["fullName"] as? String) ?? (person["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names[id] = name }
        }
        return names
    }

    /// The people of a chat by their id with their picture (`imgURL`), yourself left out.
    static func pictures(_ people: [[String: Any]]) -> [String: String] {
        var pictures: [String: String] = [:]
        for person in people where person["isSelf"] as? Bool != true {
            guard let id = person["id"] as? String, let picture = person["imgURL"] as? String, !picture.isEmpty else { continue }
            pictures[id] = picture
        }
        return pictures
    }

    /// The people of a chat by their number, for tags: the phone number the service gives, else the digits in their id
    /// ("@whatsapp_31612345678:nook.local", "whatsapp-lid-123456789012"). Yourself too: a tag of you shows your name.
    static func tags(_ people: [[String: Any]]) -> [String: String] {
        var tags: [String: String] = [:]
        for person in people {
            let name = ((person["fullName"] as? String) ?? (person["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("+"), !name.allSatisfy({ $0.isNumber || $0 == " " }) else { continue }
            // Only an id of words and then a number: a UUID's digits (Signal) are no number.
            let user = ((person["id"] as? String) ?? "").split(separator: ":").first ?? ""
            let parts = user.split { "@_-".contains($0) }
            let words = parts.dropLast().allSatisfy { !$0.contains(where: \.isNumber) }
            let id = words ? parts.last.map(String.init).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil } ?? "" : ""
            for number in [(person["phoneNumber"] as? String) ?? "", id] {
                if let key = ChatMentions.key(number), tags[key] == nil { tags[key] = name }
            }
        }
        return tags
    }

    /// A chat's picture: its own, else (in a private chat) the other person's.
    static func picture(_ chat: [String: Any]) -> String? {
        if let own = chat["imgURL"] as? String, !own.isEmpty { return own }
        guard chat["type"] as? String != "group" else { return nil }
        let people = (chat["participants"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return people.first { $0["isSelf"] as? Bool != true }.flatMap { $0["imgURL"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The messages of /v1/chats/{id}/messages, oldest first, without reactions and hidden ones; a deleted one shows
    /// as deleted (`InboxMessage.withdrawn()`), an edited one says so.
    static func messages(_ json: [String: Any], chat: Chat) -> [InboxMessage] {
        let messages: [InboxMessage] = (json["items"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, message["type"] as? String != "REACTION",
                  message["isHidden"] as? Bool != true,
                  let sent = ChatJSON.date(message["timestamp"]) else { return nil }
            let mine = message["isSender"] as? Bool == true
            if let change = membership(message, chat: chat) {
                return .notice(id: messageID(id, chat: chat.id), date: sent, membership: change)
            }
            if message["type"] as? String == "GROUP_CHANGE", let change = message["groupChange"] as? [String: Any],
               let kind = (change["kind"] as? String).flatMap(ChatGroupChange.Kind.init(rawValue:)) {
                // The chat's new name, topic or picture, by the sender when the network says.
                let senderID = (message["senderID"] as? String) ?? ""
                let by: String? = mine ? ChatMembership.me : senderID.isEmpty ? nil
                    : ((message["senderName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? chat.people[senderID] ?? tr("chat.member.someone"))
                return .notice(id: messageID(id, chat: chat.id), date: sent,
                               groupChange: ChatGroupChange(kind, by: by, text: change["text"] as? String), fromMe: mine)
            }
            // Who wrote it in a group, by the service's id for them: their face beside the bubble goes by it.
            let senderID = mine || !chat.isGroup ? nil : (message["senderID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if message["isDeleted"] as? Bool == true {
                let sender = mine || !chat.isGroup ? "" : ((message["senderName"] as? String) ?? "")
                var gone = InboxMessage(id: messageID(id, chat: chat.id), sender: sender, text: "", date: sent, fromMe: mine)
                gone.senderID = senderID
                return gone.withdrawn()
            }
            var text = ((message["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Only invisible marks (what an app sends around a reaction): nothing to show.
            if ChatFormat.isBlank(text) { text = "" }
            text = ChatMentions.named(text) { ChatMentions.key($0).flatMap { chat.tags[$0] } }
            let media = (message["attachments"] as? [[String: Any]])?.first.flatMap(Self.file)
            if text.isEmpty, media == nil { text = label(message) }
            // The service writes a file's name as the text of a message with only that file.
            if let name = media?.name, text == name { text = "" }
            guard !text.isEmpty || media != nil else { return nil }
            let sender = mine || !chat.isGroup ? "" : ((message["senderName"] as? String) ?? "")
            var inbox = InboxMessage(id: messageID(id, chat: chat.id), sender: sender, text: text, date: sent, fromMe: mine,
                                     media: media)
            inbox.senderID = senderID
            if mine {
                inbox.receipt = receipt(message)
                inbox.readers = readers(message, chat: chat)
            }
            inbox.poll = poll(message, chat: chat)
            // An empty list too: the last emoji taken back leaves none.
            inbox.reactions = reactions(message, me: chat.me, people: chat.people)
            // The message it answers, by the service's id ("linkedMessageID"; "replyToMessageID" as Nook sends it).
            if let answered = ((message["linkedMessageID"] as? String) ?? (message["replyToMessageID"] as? String)), !answered.isEmpty {
                inbox.quote = InboxQuote(id: messageID(answered, chat: chat.id))
            }
            if message["isEdited"] as? Bool == true { inbox.edited = true }
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// Someone coming into the chat or going (`type: MEMBERSHIP`, `membership: {membership: "join"|"leave", userID,
    /// userName, isSelf}`, the sender who did it when the network says), by their names in the chat. Nil for any other
    /// message.
    static func membership(_ message: [String: Any], chat: Chat) -> ChatMembership? {
        guard message["type"] as? String == "MEMBERSHIP", let change = message["membership"] as? [String: Any] else { return nil }
        let user = (change["userID"] as? String) ?? ""
        let person = change["isSelf"] as? Bool == true || (chat.me != nil && user == chat.me) ? ChatMembership.me
            : ((change["userName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? chat.people[user] ?? "")
        let senderID = (message["senderID"] as? String) ?? ""
        let by: String? = message["isSender"] as? Bool == true ? ChatMembership.me
            : senderID.isEmpty ? nil : ((message["senderName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? chat.people[senderID] ?? "")
        let joined = change["membership"] as? String == "join"
        // The person themselves, or nobody named: they came in or went by themselves, or the network does not say how.
        if senderID.isEmpty || senderID == user {
            return ChatMembership(joined ? .joined : (senderID.isEmpty ? .gone : .left), people: [person])
        }
        return ChatMembership(joined ? .added : .removed, by: by == "" ? tr("chat.member.someone") : by, people: [person])
    }

    /// A poll (`type: POLL`, its text the question) with who chose each option, the same as every app's poll: you as
    /// "You" first, the others by name; one the chat does not name still counts.
    static func poll(_ message: [String: Any], chat: Chat) -> ChatPoll? {
        guard message["type"] as? String == "POLL", let poll = message["poll"] as? [String: Any] else { return nil }
        let options = (poll["options"] as? [[String: Any]] ?? []).compactMap { option -> ChatPoll.Option? in
            guard let text = option["text"] as? String, !text.isEmpty else { return nil }
            let ids = option["voters"] as? [String] ?? []
            let mine = chat.me.map { ids.contains($0) } ?? false
            let others = ids.filter { $0 != chat.me }.compactMap { chat.people[$0] }.filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return ChatPoll.Option(text: text, votes: ids.count, chosen: mine, voters: (mine ? [tr("chat.poll.you")] : []) + others)
        }
        guard !options.isEmpty else { return nil }
        return ChatPoll(question: (poll["question"] as? String) ?? "", options: options, multiple: poll["multiple"] as? Bool == true)
    }

    /// An attachment: what it is (the service says whether it is a GIF, a sticker or a voice message), and where it is:
    /// a file on this Mac once the service has it, else its own address for it, fetched through its API.
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
        var media = ChatMedia(kind: kind, name: name, seconds: ChatJSON.number(attachment["duration"]))
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
