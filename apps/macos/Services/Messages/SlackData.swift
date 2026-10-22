import Foundation

/// What Slack's Web API answers, turned into chats for the Chats tab: your direct messages and group messages with their
/// newest messages. Foundation only, so it can be tested anywhere; `SlackBridge` makes the calls.
/// Methods used: auth.test, users.list, conversations.list (types im, mpim), conversations.history.
enum SlackData {
    /// One direct or group conversation.
    struct Conversation: Equatable, Sendable {
        var id: String
        /// The other person in a direct message.
        var user: String?
        /// Slack's own name for a group message: "mpdm-anna--jan--you-1".
        var name: String
        var isGroup: Bool
        /// When it last changed, as Slack lists it (seconds); 0 when Slack does not say.
        var updated: Double
    }

    /// The JSON object of an answer; nil when it is none.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Slack answers 200 with `"ok": false` and the reason ("invalid_auth", "missing_scope"…).
    static func error(_ json: [String: Any]) -> String? {
        (json["ok"] as? Bool) == true ? nil : ((json["error"] as? String) ?? "unknown_error")
    }

    /// The cursor of the next page, nil on the last.
    static func nextCursor(_ json: [String: Any]) -> String? {
        let cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        return cursor.isEmpty ? nil : cursor
    }

    /// Your own user id, from auth.test.
    static func me(_ json: [String: Any]) -> String? {
        json["user_id"] as? String
    }

    /// Names per user id, from users.list: the display name people chose, else their real name, else the handle.
    static func users(_ json: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for member in json["members"] as? [[String: Any]] ?? [] {
            guard let id = member["id"] as? String else { continue }
            let profile = member["profile"] as? [String: Any] ?? [:]
            let candidates = [profile["display_name"], profile["real_name"], member["real_name"], member["name"]]
            if let name = candidates.compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                names[id] = name
            }
        }
        return names
    }

    /// The direct and group messages from conversations.list, without the ones that were closed or belong to a user
    /// that was deleted.
    static func conversations(_ json: [String: Any]) -> [Conversation] {
        (json["channels"] as? [[String: Any]] ?? []).compactMap { channel in
            guard let id = channel["id"] as? String else { return nil }
            if channel["is_user_deleted"] as? Bool == true || channel["is_archived"] as? Bool == true { return nil }
            let isIM = channel["is_im"] as? Bool == true
            let isGroup = channel["is_mpim"] as? Bool == true
            guard isIM || isGroup else { return nil }
            // `updated` is in milliseconds; `created` in seconds.
            let updated = (channel["updated"] as? Double).map { $0 > 10_000_000_000 ? $0 / 1000 : $0 }
                ?? (channel["created"] as? Double) ?? 0
            return Conversation(id: id, user: channel["user"] as? String, name: (channel["name"] as? String) ?? "",
                                isGroup: isGroup, updated: updated)
        }
    }

    /// What the chat is called in Nook: the person in a direct message, the people in a group (yourself left out).
    static func chatName(_ conversation: Conversation, users: [String: String], me: String?) -> String {
        if let user = conversation.user, !conversation.isGroup { return users[user] ?? user }
        // "mpdm-anna--jan--you-1" → "anna, jan".
        var handle = conversation.name
        if handle.hasPrefix("mpdm-") { handle.removeFirst(5) }
        if let dash = handle.lastIndex(of: "-"), handle[handle.index(after: dash)...].allSatisfy(\.isNumber) {
            handle = String(handle[..<dash])
        }
        let mine = me.flatMap { users[$0] }?.lowercased()
        let people = handle.components(separatedBy: "--").filter { !$0.isEmpty && $0.lowercased() != mine }
        return people.isEmpty ? conversation.name : people.joined(separator: ", ")
    }

    /// The messages of conversations.history, oldest first. Joins, leaves and other notices are left out; a message
    /// with only a file shows its name.
    static func messages(_ json: [String: Any], conversation: Conversation, users: [String: String], me: String?) -> [InboxMessage] {
        let skipped: Set<String> = ["channel_join", "channel_leave", "group_join", "group_leave", "bot_add", "bot_remove",
                                    "channel_topic", "channel_purpose", "channel_name", "message_deleted", "message_changed"]
        let messages: [InboxMessage] = (json["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let ts = message["ts"] as? String, let seconds = Double(ts) else { return nil }
            if let subtype = message["subtype"] as? String, skipped.contains(subtype) { return nil }
            var text = clean((message["text"] as? String) ?? "", users: users)
            if text.isEmpty, let files = message["files"] as? [[String: Any]] {
                text = files.compactMap { ($0["name"] as? String) ?? ($0["title"] as? String) }.joined(separator: ", ")
            }
            guard !text.isEmpty else { return nil }
            let user = (message["user"] as? String) ?? (message["bot_id"] as? String) ?? ""
            let mine = me != nil && user == me
            let sender = mine || !conversation.isGroup ? "" : (users[user] ?? (message["username"] as? String) ?? user)
            return InboxMessage(id: "slack-\(conversation.id)-\(ts)", sender: sender, text: text,
                                date: Date(timeIntervalSince1970: seconds), fromMe: mine)
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// Slack's markup as plain text: `<@U1>` → "@Anna", `<#C1|general>` → "#general", `<https://x|label>` → "label",
    /// `<https://x>` → the link, and the three escaped characters back.
    static func clean(_ text: String, users: [String: String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            result += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : nil
            if target.hasPrefix("@") {
                let id = String(target.dropFirst())
                result += "@" + (label ?? users[id] ?? id)
            } else if target.hasPrefix("#") {
                result += "#" + (label ?? String(target.dropFirst()))
            } else if target.hasPrefix("!") {
                // <!here>, <!channel>, <!subteam^ID|@team>
                result += label ?? "@" + target.dropFirst()
            } else {
                result += label ?? target
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
