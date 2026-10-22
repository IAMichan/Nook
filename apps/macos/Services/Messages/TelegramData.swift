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
        return Chat(id: id, title: (object["title"] as? String) ?? "", isGroup: isGroup,
                    unread: Int(int64(object["unread_count"]) ?? 0), order: order(object["positions"]))
    }

    /// A chat's place in the main list, from its `positions`.
    static func order(_ positions: Any?) -> Int64 {
        for position in positions as? [[String: Any]] ?? [] {
            let list = position["list"] as? [String: Any] ?? [:]
            if type(list) == "chatListMain" { return int64(position["order"]) ?? 0 }
        }
        return 0
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
        guard let text = Self.text(object["content"] as? [String: Any] ?? [:]), !text.isEmpty else { return nil }
        let mine = object["is_outgoing"] as? Bool == true
        let sender = mine || !chat.isGroup ? "" : senderUser(object).flatMap { users[$0] } ?? ""
        let date = Date(timeIntervalSince1970: Double(int64(object["date"]) ?? 0))
        return InboxMessage(id: "telegram-\(chat.id)-\(id)", sender: sender, text: text, date: date, fromMe: mine)
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
}
