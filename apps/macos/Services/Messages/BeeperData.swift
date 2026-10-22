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
    }

    /// Beeper's networks by the words in their name or account id ("instagramgo", "Facebook/Messenger", "Twitter/X"),
    /// most specific first.
    private static let networks: [(word: String, app: String)] = [
        ("whatsapp", "whatsapp"), ("instagram", "instagram"), ("messenger", "messenger"), ("facebook", "messenger"),
        ("telegram", "telegram"), ("signal", "signal"), ("discord", "discord"), ("linkedin", "linkedin"),
        ("twitter", "x"), ("slack", "slack"), ("imessage", "messages"), ("googlechat", "googlechat"),
        ("google chat", "googlechat"), ("hungryserv", "beeper"), ("beeper", "beeper"), ("matrix", "beeper"),
    ]

    /// The app for a chat's network; nil for a network Nook has no source for (it is left out).
    static func app(network: String, account: String) -> String? {
        let words = (network + " " + account).lowercased()
        return networks.first { words.contains($0.word) }?.app
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
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
            return Chat(id: id, app: source, title: title, isGroup: chat["type"] as? String == "group", unread: unread,
                        last: date(chat["lastActivity"]))
        }
    }

    /// The messages of /v1/chats/{id}/messages, oldest first, without reactions, hidden and deleted ones.
    static func messages(_ json: [String: Any], chat: Chat) -> [InboxMessage] {
        let messages: [InboxMessage] = (json["items"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, message["type"] as? String != "REACTION",
                  message["isHidden"] as? Bool != true, message["isDeleted"] as? Bool != true,
                  let sent = date(message["timestamp"]) else { return nil }
            var text = ((message["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = label(message) }
            guard !text.isEmpty else { return nil }
            let mine = message["isSender"] as? Bool == true
            let sender = mine || !chat.isGroup ? "" : ((message["senderName"] as? String) ?? "")
            return InboxMessage(id: "beeper-\(chat.id)-\(id)", sender: sender, text: text, date: sent, fromMe: mine)
        }
        return messages.sorted { $0.date < $1.date }
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
