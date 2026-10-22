import Foundation

/// What Microsoft Graph answers about your Teams chats, turned into chats for the Chats tab, and the sign-in with a code
/// (the OAuth device code flow). Foundation only, so it can be tested anywhere; `TeamsBridge` makes the calls.
/// Endpoints: /me, /me/chats (with members and the last message), /me/chats/{id}/messages. Work or school accounts only:
/// Graph has no chats of personal Teams.
enum TeamsData {
    struct Chat: Equatable, Sendable {
        var id: String
        var name: String
        var isGroup: Bool
        /// When its newest message was sent: a chat whose newest message did not change needs no new read.
        var last: Date?
        /// Until when you read it, as Teams keeps it.
        var readUntil: Date?
        /// A group chat's other people by name (you left out).
        var members: [String] = []
    }

    /// What the sign-in page needs: the code to type and where.
    struct DeviceCode: Equatable, Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURL: URL
        var interval: TimeInterval
        var expires: Date
    }

    /// The answer to asking for a token.
    enum TokenResult: Equatable, Sendable {
        case token(access: String, refresh: String?, expires: Date)
        /// The code is not typed in yet: ask again after the interval (longer after "slow_down").
        case pending(slowDown: Bool)
        case failed(String)
    }

    static let scopes = "Chat.Read User.Read offline_access"

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A form body for the token endpoints, with the values escaped.
    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func deviceCode(_ json: [String: Any], now: Date = Date()) -> DeviceCode? {
        guard let code = json["device_code"] as? String, let user = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else { return nil }
        let interval = (json["interval"] as? Double) ?? 5
        let expires = (json["expires_in"] as? Double) ?? 900
        return DeviceCode(deviceCode: code, userCode: user, verificationURL: uri, interval: interval,
                          expires: now.addingTimeInterval(expires))
    }

    static func token(_ json: [String: Any], now: Date = Date()) -> TokenResult {
        if let access = json["access_token"] as? String {
            // A number, whole or not (Microsoft sends a whole one), or a numeral; an hour when it says nothing.
            let value = json["expires_in"]
            let expires = (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? String).flatMap(Double.init) ?? 3600
            return .token(access: access, refresh: json["refresh_token"] as? String, expires: now.addingTimeInterval(expires))
        }
        switch json["error"] as? String {
        case "authorization_pending": return .pending(slowDown: false)
        case "slow_down": return .pending(slowDown: true)
        default:
            return .failed((json["error_description"] as? String).map { $0.components(separatedBy: "\r\n").first ?? $0 }
                ?? (json["error"] as? String) ?? "unknown_error")
        }
    }

    /// Graph's dates: "2026-10-22T09:14:56.123Z", with or without the fraction.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Your own id and name, from /me.
    static func me(_ json: [String: Any]) -> (id: String, name: String)? {
        guard let id = json["id"] as? String else { return nil }
        return (id, (json["displayName"] as? String) ?? "")
    }

    /// The chats of /me/chats. A chat with a topic is called by it; any other after its people, yourself left out.
    /// Meeting chats are left out unless they have a topic, as Teams lists them.
    static func chats(_ json: [String: Any], me: String?) -> [Chat] {
        (json["value"] as? [[String: Any]] ?? []).compactMap { chat in
            guard let id = chat["id"] as? String else { return nil }
            let kind = (chat["chatType"] as? String) ?? "oneOnOne"
            let topic = ((chat["topic"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if kind == "meeting", topic.isEmpty { return nil }
            let people = (chat["members"] as? [[String: Any]] ?? [])
                .filter { me == nil || ($0["userId"] as? String) != me }
                .compactMap { ($0["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let name = topic.isEmpty ? people.joined(separator: ", ") : topic
            guard !name.isEmpty else { return nil }
            let preview = chat["lastMessagePreview"] as? [String: Any]
            let viewpoint = chat["viewpoint"] as? [String: Any]
            if viewpoint?["isHidden"] as? Bool == true { return nil }
            return Chat(id: id, name: name, isGroup: kind != "oneOnOne", last: date(preview?["createdDateTime"]),
                        readUntil: date(viewpoint?["lastMessageReadDateTime"]), members: kind == "oneOnOne" ? [] : people)
        }
    }

    /// The link to the next page of a list, nil on the last.
    static func nextLink(_ json: [String: Any]) -> URL? {
        (json["@odata.nextLink"] as? String).flatMap(URL.init(string:))
    }

    /// The messages of /me/chats/{id}/messages, oldest first. System notices (someone joined, a call ended) and deleted
    /// messages are left out; a message with only a file shows its name.
    static func messages(_ json: [String: Any], chat: Chat, me: String?) -> [InboxMessage] {
        let messages: [InboxMessage] = (json["value"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, (message["messageType"] as? String ?? "message") == "message",
                  message["deletedDateTime"] as? String == nil, let sent = Self.date(message["createdDateTime"]) else { return nil }
            let body = message["body"] as? [String: Any] ?? [:]
            var text = (body["content"] as? String) ?? ""
            if (body["contentType"] as? String)?.lowercased() == "html" { text = plain(html: text) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                text = (message["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            }
            guard !text.isEmpty else { return nil }
            let user = ((message["from"] as? [String: Any])?["user"] as? [String: Any]) ?? [:]
            let mine = me != nil && (user["id"] as? String) == me
            let sender = mine || !chat.isGroup ? "" : ((user["displayName"] as? String) ?? "")
            var inbox = InboxMessage(id: "teams-\(id)", sender: sender, text: text, date: sent, fromMe: mine)
            // Graph shares no one's read receipts but your own: your message is on Teams, and that is all it says.
            if mine { inbox.receipt = .sent }
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// Whether an answer of /me/chats/{id}/messages already lists the newest message the chat list announced. Graph can
    /// announce a message in the list a few seconds before the chat's own messages show it; a chat read too early must
    /// be read again. System notices count too, since the list announces those as well.
    static func caughtUp(_ json: [String: Any], last: Date?) -> Bool {
        guard let last else { return true }
        let newest = (json["value"] as? [[String: Any]] ?? []).compactMap { date($0["createdDateTime"]) }.max()
        // The list and the messages round the same moment differently (milliseconds or not).
        return newest.map { $0 >= last.addingTimeInterval(-1) } ?? false
    }

    /// How many of these messages from others came after you last read the chat.
    static func unread(_ messages: [InboxMessage], readUntil: Date?) -> Int {
        guard let readUntil else { return 0 }
        return messages.filter { !$0.isMine && $0.date > readUntil }.count
    }

    /// Teams' HTML as plain text: line breaks kept, tags dropped, the common entities back.
    static func plain(html: String) -> String {
        var text = html
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
