import Foundation

/// What TDLib (Telegram's own client library, JSON interface) sends and answers, turned into chats for the Chats tab.
/// Foundation only, so it can be tested anywhere; `TelegramBridge` runs TDLib. Object and field names follow TDLib's
/// API (core.telegram.org/tdlib/docs, td_api.tl).
enum TelegramData {
    /// One chat as TDLib describes it.
    struct Chat: Equatable, Sendable {
        var id: Int64
        var title: String
        var isGroup: Bool
        var unread: Int
        /// The order of the main chat list (the newest activity first); 0 when the chat is not in it.
        var order: Int64
        /// The chat's picture (a person's, a group's) as a file in TDLib, and where it is once downloaded.
        var photo: Int64? = nil
        var avatar: String? = nil
        /// The newest of your messages someone read: yours up to it have two ticks.
        var readOutbox: Int64 = 0
        /// The group behind the chat, to ask who is in it: a basic group or a supergroup.
        var basicGroup: Int64? = nil
        var supergroup: Int64? = nil
        /// Pinned at the top of the main chat list.
        var isPinned: Bool = false
        /// Its notifications are muted (for a while or for good).
        var isMuted: Bool = false
    }

    /// Where the login stands.
    enum Authorization: Equatable, Sendable {
        case parameters
        case encryptionKey
        case phone
        case code(phone: String)
        case password(hint: String)
        case ready
        case loggingOut
        case closed
        /// A state Nook does not handle (an email address, a sign-up): log in in the Telegram app first.
        case other(String)
    }

    static func type(_ object: [String: Any]) -> String {
        (object["@type"] as? String) ?? ""
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Double { return Int64(number) }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    /// The JSON object of a string TDLib returned; nil when it is none.
    static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// A request as the JSON string TDLib takes.
    static func request(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `updateAuthorizationState` or an `authorizationState…` object.
    static func authorization(_ object: [String: Any]) -> Authorization {
        let state = type(object) == "updateAuthorizationState" ? (object["authorization_state"] as? [String: Any] ?? [:]) : object
        switch type(state) {
        case "authorizationStateWaitTdlibParameters": return .parameters
        case "authorizationStateWaitEncryptionKey": return .encryptionKey
        case "authorizationStateWaitPhoneNumber": return .phone
        case "authorizationStateWaitCode":
            let info = state["code_info"] as? [String: Any] ?? [:]
            return .code(phone: (info["phone_number"] as? String) ?? "")
        case "authorizationStateWaitPassword": return .password(hint: (state["password_hint"] as? String) ?? "")
        case "authorizationStateReady": return .ready
        case "authorizationStateLoggingOut": return .loggingOut
        case "authorizationStateClosed", "authorizationStateClosing": return .closed
        default: return .other(type(state))
        }
    }

    /// A `chat` object. Channels (one-way broadcasts) are left out: they are no conversations.
    static func chat(_ object: [String: Any]) -> Chat? {
        guard type(object) == "chat", let id = int64(object["id"]) else { return nil }
        let kind = object["type"] as? [String: Any] ?? [:]
        if type(kind) == "chatTypeSupergroup", kind["is_channel"] as? Bool == true { return nil }
        let isGroup = ["chatTypeBasicGroup", "chatTypeSupergroup"].contains(type(kind))
        let picture = photo(object["photo"])
        return Chat(id: id, title: (object["title"] as? String) ?? "", isGroup: isGroup,
                    unread: Int(int64(object["unread_count"]) ?? 0), order: order(object["positions"]),
                    photo: picture?.id, avatar: picture?.path, readOutbox: int64(object["last_read_outbox_message_id"]) ?? 0,
                    basicGroup: type(kind) == "chatTypeBasicGroup" ? int64(kind["basic_group_id"]) : nil,
                    supergroup: type(kind) == "chatTypeSupergroup" ? int64(kind["supergroup_id"]) : nil,
                    isPinned: isPinned(object["positions"]), isMuted: isMuted(object["notification_settings"]))
    }

    /// The people of a group, by their user id: a `basicGroupFullInfo`'s or a `chatMembers`' `members`.
    static func members(_ object: [String: Any]) -> [Int64] {
        (object["members"] as? [[String: Any]] ?? []).compactMap { member in
            let sender = member["member_id"] as? [String: Any] ?? [:]
            return type(sender) == "messageSenderUser" ? int64(sender["user_id"]) : int64(member["user_id"])
        }
    }

    /// Who saw one of your messages in a group, and when: a `messageViewers` (`viewers: [{user_id, view_date}]`), or the
    /// `users` an older TDLib answers with (no times).
    static func viewers(_ object: [String: Any]) -> [(user: Int64, date: Date?)] {
        if type(object) == "users" {
            return (object["user_ids"] as? [Any] ?? []).compactMap { int64($0) }.map { ($0, nil) }
        }
        return (object["viewers"] as? [[String: Any]] ?? []).compactMap { viewer in
            guard let user = int64(viewer["user_id"]) else { return nil }
            let seconds = int64(viewer["view_date"]) ?? 0
            return (user, seconds > 0 ? Date(timeIntervalSince1970: Double(seconds)) : nil)
        }
    }

    /// `updateChatAction`: who in which chat types, records or sends a file (`chatActionTyping`,
    /// `chatActionRecordingVoiceNote`, `chatActionUploadingPhoto`…), or stopped (`chatActionCancel`, kind nil). Nil for
    /// an action that is not someone's (a chat as sender), or one Nook shows nothing for (choosing a sticker, watching
    /// emoji).
    static func chatAction(_ object: [String: Any]) -> (chat: Int64, user: Int64, kind: ChatTypist.Kind?)? {
        guard let chat = int64(object["chat_id"]), let sender = object["sender_id"] as? [String: Any],
              sender["@type"] as? String == "messageSenderUser", let user = int64(sender["user_id"]),
              let action = (object["action"] as? [String: Any])?["@type"] as? String else { return nil }
        switch action {
        case "chatActionCancel": return (chat, user, nil)
        case "chatActionTyping": return (chat, user, .text)
        case "chatActionRecordingVoiceNote", "chatActionRecordingVideo", "chatActionRecordingVideoNote": return (chat, user, .recording)
        case _ where action.hasPrefix("chatActionUploading"): return (chat, user, .uploading)
        default: return nil
        }
    }

    /// Your message's ticks: a clock while it goes out, a red mark when it could not, else two once the chat says it was
    /// read up to it.
    static func receipt(_ object: [String: Any], readOutbox: Int64) -> ChatReceipt? {
        guard object["is_outgoing"] as? Bool == true, let id = int64(object["id"]) else { return nil }
        let sending = type(object["sending_state"] as? [String: Any] ?? [:])
        return ChatReceipts.telegram(message: id, readUpTo: readOutbox, pending: sending == "messageSendingStatePending",
                                     failed: sending == "messageSendingStateFailed")
    }

    /// A `chatPhotoInfo`: its small picture, as the chat list shows it.
    static func photo(_ info: Any?) -> (id: Int64, path: String?)? {
        guard let small = (info as? [String: Any])?["small"] as? [String: Any], let id = int64(small["id"]) else { return nil }
        return (id, downloaded(small))
    }

    /// A chat's place in the main list, from its `positions`.
    static func order(_ positions: Any?) -> Int64 {
        for position in positions as? [[String: Any]] ?? [] {
            let list = position["list"] as? [String: Any] ?? [:]
            if type(list) == "chatListMain" { return int64(position["order"]) ?? 0 }
        }
        return 0
    }

    /// Whether a chat is pinned in the main list, from its `positions`.
    static func isPinned(_ positions: Any?) -> Bool {
        for position in positions as? [[String: Any]] ?? [] {
            let list = position["list"] as? [String: Any] ?? [:]
            if type(list) == "chatListMain" { return position["is_pinned"] as? Bool == true }
        }
        return false
    }

    /// Whether a chat's `chatNotificationSettings` mute it: notifications stay off for some time yet.
    static func isMuted(_ settings: Any?) -> Bool {
        (int64((settings as? [String: Any])?["mute_for"]) ?? 0) > 0
    }

    /// The chat's new place in the main list from an `updateChatPosition`: its order (0 when it left the list) and
    /// whether it is pinned. Nil for a position in another list (the archive, a folder).
    static func mainPosition(_ update: [String: Any]) -> (chat: Int64, order: Int64, pinned: Bool)? {
        guard let chat = int64(update["chat_id"]), let position = update["position"] as? [String: Any],
              type(position["list"] as? [String: Any] ?? [:]) == "chatListMain" else { return nil }
        let order = int64(position["order"]) ?? 0
        return (chat, order, order != 0 && position["is_pinned"] as? Bool == true)
    }

    /// The messages Telegram deleted from a chat for good, from an `updateDeleteMessages`; nil when they only left
    /// TDLib's cache (`is_permanent` false) and are still in the chat.
    static func deletedMessages(_ update: [String: Any]) -> (chat: Int64, messages: [Int64])? {
        guard update["is_permanent"] as? Bool == true, let chat = int64(update["chat_id"]) else { return nil }
        let ids = (update["message_ids"] as? [Any] ?? []).compactMap { int64($0) }
        return ids.isEmpty ? nil : (chat, ids)
    }

    /// "Anna Smit" from a `user` object; its @username, else its phone number, when it has no name.
    static func userName(_ object: [String: Any]) -> String? {
        guard type(object) == "user" else { return nil }
        let name = [object["first_name"] as? String, object["last_name"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        let usernames = (object["usernames"] as? [String: Any])?["active_usernames"] as? [String]
        if let username = usernames?.first { return "@" + username }
        return (object["phone_number"] as? String).map { "+" + $0 }
    }

    /// The user who wrote a message, from its `sender_id`; nil when a chat (a channel or group itself) wrote it.
    static func senderUser(_ message: [String: Any]) -> Int64? {
        let sender = message["sender_id"] as? [String: Any] ?? [:]
        return type(sender) == "messageSenderUser" ? int64(sender["user_id"]) : nil
    }

    /// A `message` as a message in Nook: what it says (a file by its kind and caption), who wrote it in a group, and
    /// whether it is yours. Nil for a message without anything to show (a service message, a pinned notice).
    static func message(_ object: [String: Any], chat: Chat, users: [Int64: String]) -> InboxMessage? {
        guard type(object) == "message", let id = int64(object["id"]) else { return nil }
        let content = object["content"] as? [String: Any] ?? [:]
        let attached = file(content)
        let asked = poll(content)
        // A file shows as itself, with its caption as the text; a poll as itself; anything else as its text.
        let text: String? = asked != nil ? "" : (attached == nil ? Self.text(content) : Optional(caption(content)))
        guard let text, !text.isEmpty || attached != nil || asked != nil else { return nil }
        let mine = object["is_outgoing"] as? Bool == true
        let sender = mine || !chat.isGroup ? "" : senderUser(object).flatMap { users[$0] } ?? ""
        let date = Date(timeIntervalSince1970: Double(int64(object["date"]) ?? 0))
        var message = InboxMessage(id: "telegram-\(chat.id)-\(id)", sender: sender, text: text, date: date, fromMe: mine,
                                   media: attached?.media, poll: asked)
        message.receipt = receipt(object, readOutbox: chat.readOutbox)
        message.quote = quote(object, chat: chat.id)
        if let info = object["interaction_info"] { message.reactions = reactions(info) }
        return message
    }

    /// The message this one answers, in the same chat: `reply_to` (TDLib 1.8.21 and later, with the part you quoted,
    /// if any) or `reply_to_message_id` (before). The chat finds the answered message by its id in Nook.
    static func quote(_ object: [String: Any], chat: Int64) -> InboxQuote? {
        var answered = int64(object["reply_to_message_id"])
        var quoted = ""
        if let reply = object["reply_to"] as? [String: Any], type(reply) == "messageReplyToMessage" {
            if let from = int64(reply["chat_id"]), from != chat, from != 0 { return nil }
            answered = int64(reply["message_id"])
            let text = (reply["quote"] as? [String: Any])?["text"]
            quoted = (text as? String) ?? ((text as? [String: Any])?["text"] as? String) ?? ""
        }
        guard let answered, answered != 0 else { return nil }
        return InboxQuote(id: "telegram-\(chat)-\(answered)", text: quoted)
    }

    /// The emoji on a message from its `interaction_info`: `reactions.reactions` (TDLib 1.8.21 and later) or a list
    /// of them (before). Custom emoji and paid stars are left out; an empty list when there are none.
    static func reactions(_ info: Any?) -> [InboxReaction] {
        let value = (info as? [String: Any])?["reactions"]
        let list = ((value as? [String: Any])?["reactions"] as? [[String: Any]]) ?? (value as? [[String: Any]]) ?? []
        let chips = list.compactMap { reaction -> InboxReaction? in
            let kind = reaction["type"] as? [String: Any] ?? [:]
            // Before 1.8.21 the emoji itself was the reaction.
            let emoji = kind.isEmpty ? reaction["reaction"] as? String : (type(kind) == "reactionTypeEmoji" ? kind["emoji"] as? String : nil)
            guard let emoji, !emoji.isEmpty else { return nil }
            return InboxReaction(emoji: emoji, count: Int(int64(reaction["total_count"]) ?? 1),
                                 mine: reaction["is_chosen"] as? Bool == true)
        }
        return chips.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// `addMessageReaction` or `removeMessageReaction` for an emoji on a message.
    static func reaction(_ emoji: String, chat: Int64, message: Int64, add: Bool) -> [String: Any] {
        var request: [String: Any] = [
            "@type": add ? "addMessageReaction" : "removeMessageReaction", "chat_id": chat, "message_id": message,
            "reaction_type": ["@type": "reactionTypeEmoji", "emoji": emoji] as [String: Any],
        ]
        if add {
            request["is_big"] = false
            request["update_recent_reactions"] = true
        }
        return request
    }

    /// A `messagePoll`'s poll: its question, each option with its votes and whether you chose it, and whether more
    /// than one may be chosen. Texts are plain strings in older TDLib, formatted text since 1.8.33.
    static func poll(_ content: [String: Any]) -> ChatPoll? {
        guard type(content) == "messagePoll", let poll = content["poll"] as? [String: Any] else { return nil }
        func plain(_ value: Any?) -> String { (value as? String) ?? ((value as? [String: Any])?["text"] as? String) ?? "" }
        let options = (poll["options"] as? [[String: Any]] ?? []).map { option in
            ChatPoll.Option(text: plain(option["text"]), votes: Int(int64(option["voter_count"]) ?? 0),
                            chosen: option["is_chosen"] as? Bool == true)
        }
        let kind = poll["type"] as? [String: Any] ?? [:]
        return ChatPoll(question: plain(poll["question"]), options: options,
                        multiple: type(kind) == "pollTypeRegular" && kind["allow_multiple_answers"] as? Bool == true)
    }

    /// The chat and message ids in Nook's id of a Telegram message ("telegram-<chat>-<message>"); a chat id can be
    /// negative ("telegram--100123-45").
    static func ids(_ messageID: String) -> (chat: Int64, message: Int64)? {
        guard messageID.hasPrefix("telegram-") else { return nil }
        let rest = messageID.dropFirst("telegram-".count)
        guard let split = rest.lastIndex(of: "-"), let chat = Int64(rest[..<split]),
              let message = Int64(rest[rest.index(after: split)...]) else { return nil }
        return (chat, message)
    }

    /// A file TDLib has, or can download: its id in TDLib, and what it is.
    struct File: Equatable, Sendable {
        var id: Int64
        var size: Int
        var media: ChatMedia
    }

    /// The file of a photo, video, GIF, sticker, voice or audio message or document: the photo in its largest size, a
    /// sticker that is no picture (an animated or video one) by its still picture. Nil for a message without one.
    static func file(_ content: [String: Any]) -> File? {
        func object(_ key: String) -> [String: Any]? { content[key] as? [String: Any] }
        func seconds(_ owner: [String: Any]?) -> Double? { int64(owner?["duration"]).map(Double.init) }
        let found: ([String: Any]?, ChatMedia)
        switch type(content) {
        case "messagePhoto":
            let largest = (object("photo")?["sizes"] as? [[String: Any]])?.last
            found = (largest?["photo"] as? [String: Any], ChatMedia(kind: .photo))
        case "messageVideo":
            let video = object("video")
            found = (video?["video"] as? [String: Any],
                     ChatMedia(kind: .video, name: video?["file_name"] as? String, seconds: seconds(video)))
        case "messageVideoNote":
            let note = object("video_note")
            found = (note?["video"] as? [String: Any], ChatMedia(kind: .video, seconds: seconds(note)))
        case "messageAnimation":
            let animation = object("animation")
            found = (animation?["animation"] as? [String: Any], ChatMedia(kind: .gif, name: animation?["file_name"] as? String))
        case "messageSticker":
            let sticker = object("sticker")
            let still = type(sticker?["format"] as? [String: Any] ?? [:]) == "stickerFormatWebp"
            let file = still ? sticker?["sticker"] : (sticker?["thumbnail"] as? [String: Any])?["file"]
            found = (file as? [String: Any], ChatMedia(kind: .sticker, name: sticker?["emoji"] as? String))
        case "messageVoiceNote":
            let voice = object("voice_note")
            found = (voice?["voice"] as? [String: Any], ChatMedia(kind: .voice, seconds: seconds(voice)))
        case "messageAudio":
            let audio = object("audio")
            found = (audio?["audio"] as? [String: Any],
                     ChatMedia(kind: .audio, name: audio?["file_name"] as? String, seconds: seconds(audio)))
        case "messageDocument":
            let document = object("document")
            let name = document?["file_name"] as? String
            found = (document?["document"] as? [String: Any],
                     ChatMedia(kind: ChatMedia.kind(mimeType: document?["mime_type"] as? String, name: name), name: name))
        default:
            return nil
        }
        guard let file = found.0, let id = int64(file["id"]) else { return nil }
        var media = found.1
        media.path = downloaded(file)
        return File(id: id, size: Int(int64(file["size"]) ?? int64(file["expected_size"]) ?? 0), media: media)
    }

    /// Where a `file` is on this Mac once TDLib downloaded it completely.
    static func downloaded(_ file: [String: Any]) -> String? {
        let local = file["local"] as? [String: Any] ?? [:]
        guard local["is_downloading_completed"] as? Bool == true, let path = local["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    /// A file's caption, "" without one.
    static func caption(_ content: [String: Any]) -> String {
        ((content["caption"] as? [String: Any])?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The text of a message's `content`: its text, or a file's caption after its kind ("Photo: on the beach").
    static func text(_ content: [String: Any]) -> String? {
        let caption = ((content["caption"] as? [String: Any])?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func file(_ label: String) -> String { caption.isEmpty ? label : "\(label): \(caption)" }
        switch type(content) {
        case "messageText":
            return ((content["text"] as? [String: Any])?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case "messagePhoto": return file(tr("whatsapp.file.photo"))
        case "messageVideo", "messageVideoNote", "messageAnimation": return file(tr("whatsapp.file.video"))
        case "messageVoiceNote", "messageAudio": return file(tr("whatsapp.file.voice"))
        case "messageDocument":
            let name = ((content["document"] as? [String: Any])?["file_name"] as? String) ?? ""
            return file(name.isEmpty ? tr("whatsapp.file.document") : name)
        case "messageSticker":
            return ((content["sticker"] as? [String: Any])?["emoji"] as? String) ?? "🙂"
        case "messageLocation", "messageVenue": return "📍"
        case "messageContact": return "👤"
        case "messagePoll":
            // A plain string in older TDLib, formatted text since 1.8.33.
            let question = (content["poll"] as? [String: Any])?["question"]
            return (question as? String) ?? ((question as? [String: Any])?["text"] as? String)
        default: return nil
        }
    }

    // MARK: Sending

    /// Text as TDLib takes it.
    static func formatted(_ text: String) -> [String: Any] {
        ["@type": "formattedText", "text": text, "entities": [Any]()]
    }

    /// `sendMessage` for `content` in a chat, as an answer to its message `replyTo` (TDLib's own id) when set. `extra`
    /// comes back with TDLib's answer, so a failure can be told apart.
    static func sendMessage(chat: Int64, content: [String: Any], replyTo: Int64?, extra: String) -> [String: Any] {
        var request: [String: Any] = ["@type": "sendMessage", "chat_id": chat, "input_message_content": content, "@extra": extra]
        if let replyTo { request["reply_to"] = ["@type": "inputMessageReplyToMessage", "message_id": replyTo] as [String: Any] }
        return request
    }

    /// Typed text as a message.
    static func textContent(_ text: String) -> [String: Any] {
        ["@type": "inputMessageText", "text": formatted(text), "clear_draft": true]
    }

    /// What is sent besides text, as TDLib takes it. `legacy`: the shape of TDLib before files came wrapped in their own
    /// objects (`inputPhoto`…) and poll options in `inputPollOption`; a build of either age gets what it reads, as the
    /// bridge asks again in the older shape when the newer one is refused. A sticker that is no WebP goes as a photo:
    /// Telegram takes stickers as WebP only.
    static func content(_ outgoing: ChatOutgoing, legacy: Bool = false) -> [String: Any] {
        switch outgoing {
        case .file(let file):
            let local: [String: Any] = ["@type": "inputFileLocal", "path": file.path]
            let caption = formatted(file.caption.trimmingCharacters(in: .whitespacesAndNewlines))
            let seconds = Int(file.seconds ?? 0)
            // The file, in its own object in a newer TDLib (with what describes it), or as it is in an older one, whose
            // description then sits on the content itself.
            var described: [String: Any] = [:]
            let route: (type: String, field: String)
            switch file.kind {
            case .photo:
                route = ("inputMessagePhoto", "photo")
            case .sticker where file.fileExtension != "webp":
                route = ("inputMessagePhoto", "photo")
            case .sticker:
                route = ("inputMessageSticker", "sticker")
            case .video:
                route = ("inputMessageVideo", "video")
                described["supports_streaming"] = true
            case .gif:
                route = ("inputMessageAnimation", "animation")
            case .audio:
                route = ("inputMessageAudio", "audio")
                described["duration"] = seconds
            case .voice:
                route = ("inputMessageVoiceNote", "voice_note")
                described["duration"] = seconds
            case .file:
                route = ("inputMessageDocument", "document")
            }
            var content: [String: Any] = ["@type": route.type]
            if legacy {
                content[route.field] = local
                content.merge(described) { _, new in new }
            } else {
                var wrapped = described
                wrapped["@type"] = wrappers[route.field] ?? "inputDocument"
                wrapped[route.field] = local
                content[route.field] = wrapped
            }
            // A sticker has no caption, only the emoji it stands for.
            if route.type == "inputMessageSticker" { content["emoji"] = "" } else { content["caption"] = caption }
            return content
        case .poll(let poll):
            var content: [String: Any] = ["@type": "inputMessagePoll", "question": formatted(poll.cleanQuestion),
                                          "is_anonymous": false, "is_closed": false]
            if legacy {
                content["options"] = poll.cleanOptions.map(formatted)
                content["type"] = ["@type": "pollTypeRegular", "allow_multiple_answers": poll.multiple] as [String: Any]
            } else {
                content["options"] = poll.cleanOptions.map { ["@type": "inputPollOption", "text": formatted($0)] as [String: Any] }
                content["allows_multiple_answers"] = poll.multiple
                content["type"] = ["@type": "inputPollTypeRegular", "allow_adding_options": false] as [String: Any]
            }
            return content
        case .location(let place):
            let location: [String: Any] = ["@type": "location", "latitude": place.latitude, "longitude": place.longitude]
            return ["@type": "inputMessageLocation", "location": location]
        case .contact(let card):
            let words = card.name.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            let contact: [String: Any] = [
                "@type": "contact", "phone_number": card.cleanPhone, "first_name": words.first ?? card.name,
                "last_name": words.count > 1 ? words[1] : "", "vcard": "", "user_id": 0,
            ]
            return ["@type": "inputMessageContact", "contact": contact]
        }
    }

    /// The object a newer TDLib wraps each kind of file in, by the content's field for it.
    private static let wrappers = [
        "photo": "inputPhoto", "sticker": "inputSticker", "video": "inputVideo", "animation": "inputAnimation",
        "audio": "inputAudio", "voice_note": "inputVoiceNote", "document": "inputDocument",
    ]

    // MARK: Chat actions

    /// How long "muted" lasts: Telegram takes anything over a year as for good.
    static let muteForever = Int(Int32.max)

    /// `toggleChatIsPinned` in the main chat list.
    static func togglePinned(_ pinned: Bool, chat: Int64) -> [String: Any] {
        ["@type": "toggleChatIsPinned", "chat_list": ["@type": "chatListMain"] as [String: Any], "chat_id": chat,
         "is_pinned": pinned]
    }

    /// `setChatNotificationSettings` that mutes a chat for good, or unmutes it. The chat's other settings (sound,
    /// preview…) stay as `current` has them; without them they follow Telegram's defaults.
    static func setMuted(_ muted: Bool, chat: Int64, current: [String: Any]? = nil) -> [String: Any] {
        var settings = current ?? [
            "use_default_sound": true, "use_default_show_preview": true, "use_default_mute_stories": true,
            "use_default_story_sound": true, "use_default_show_story_sender": true,
            "use_default_disable_pinned_message_notifications": true, "use_default_disable_mention_notifications": true,
        ]
        settings["@type"] = "chatNotificationSettings"
        settings["use_default_mute_for"] = false
        settings["mute_for"] = muted ? muteForever : 0
        return ["@type": "setChatNotificationSettings", "chat_id": chat, "notification_settings": settings]
    }

    /// `addChatToList` for the archive.
    static func archive(chat: Int64) -> [String: Any] {
        ["@type": "addChatToList", "chat_id": chat, "chat_list": ["@type": "chatListArchive"] as [String: Any]]
    }

    /// `editMessageText`: a message's new text.
    static func editMessageText(chat: Int64, message: Int64, text: String) -> [String: Any] {
        ["@type": "editMessageText", "chat_id": chat, "message_id": message, "input_message_content": textContent(text)]
    }

    /// `deleteMessages` for everyone in the chat.
    static func deleteMessages(chat: Int64, messages: [Int64]) -> [String: Any] {
        ["@type": "deleteMessages", "chat_id": chat, "message_ids": messages, "revoke": true]
    }

    /// Whether `sending_state` says a message is still on its way from this device: Nook shows it once Telegram has it.
    static func isPending(_ message: [String: Any]) -> Bool {
        type(message["sending_state"] as? [String: Any] ?? [:]) == "messageSendingStatePending"
    }
}
