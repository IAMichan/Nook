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
        /// Its newest message as the chat list shows it, so the chat has a line before its history is read.
        var preview: InboxMessage? = nil
    }

    /// A Teams account you signed in with. Its refresh token is in the Keychain under `refreshAccount`; the rest is not
    /// secret and kept in the user defaults.
    struct Account: Codable, Equatable, Identifiable, Sendable {
        /// Nook's own key for it; empty for the one account of a version that knew only one.
        var id: String
        /// Its Microsoft Graph user id, once known: signing in again with the same account replaces it.
        var userID: String? = nil
        var name: String = ""
        /// Its sign-in address ("anna@contoso.com").
        var email: String = ""

        var refreshAccount: String { id.isEmpty ? "chats.teams.refresh" : "chats.teams.refresh." + id }
        /// What tells it apart from your other accounts: its organization's domain, else its name.
        var label: String {
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            return email.contains("@") && !domain.isEmpty ? domain : (name.isEmpty ? email : name)
        }
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

    /// Whether a refused refresh means the sign-in itself is gone (revoked, expired, or a new consent needed), so only
    /// signing in again helps. Anything else (Microsoft busy, a server error, no answer) is passing: the refresh token
    /// is kept and asked with again at the next read, instead of signing you out for one bad answer.
    static func signInGone(_ json: [String: Any]) -> Bool {
        ["invalid_grant", "interaction_required", "consent_required", "login_required", "unauthorized_client", "invalid_client"]
            .contains((json["error"] as? String) ?? "")
    }

    /// Your own id, name and sign-in address, from /me.
    static func me(_ json: [String: Any]) -> (id: String, name: String, email: String)? {
        guard let id = json["id"] as? String else { return nil }
        let email = (json["userPrincipalName"] as? String) ?? (json["mail"] as? String) ?? ""
        return (id, (json["displayName"] as? String) ?? "", email)
    }

    /// The chats of /me/chats, every one you are in, whether anyone wrote in it or not. A chat with a topic is called by
    /// it; any other after its people, yourself left out (by their address when Teams has no name for them), and the chat
    /// with yourself after you. Meeting chats are left out unless they have a topic, as Teams lists them, and so are the
    /// chats you hid in Teams.
    static func chats(_ json: [String: Any], me: String?, myName: String = "") -> [Chat] {
        (json["value"] as? [[String: Any]] ?? []).compactMap { chat in
            guard let id = chat["id"] as? String else { return nil }
            let kind = (chat["chatType"] as? String) ?? "oneOnOne"
            let topic = ((chat["topic"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if kind == "meeting", topic.isEmpty { return nil }
            let members = chat["members"] as? [[String: Any]] ?? []
            let people = members
                .filter { me == nil || ($0["userId"] as? String) != me }
                .compactMap { member -> String? in
                    let name = ((member["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? (member["email"] as? String)?.trimmingCharacters(in: .whitespaces) : name
                }
                .filter { !$0.isEmpty }
            let alone = me != nil && !members.isEmpty && members.allSatisfy { ($0["userId"] as? String) == me }
            let name = !topic.isEmpty ? topic : (people.isEmpty && alone ? myName : people.joined(separator: ", "))
            guard !name.isEmpty else { return nil }
            let preview = chat["lastMessagePreview"] as? [String: Any]
            let viewpoint = chat["viewpoint"] as? [String: Any]
            if viewpoint?["isHidden"] as? Bool == true { return nil }
            var result = Chat(id: id, name: name, isGroup: kind != "oneOnOne", last: ChatJSON.date(preview?["createdDateTime"]),
                              readUntil: ChatJSON.date(viewpoint?["lastMessageReadDateTime"]), members: kind == "oneOnOne" ? [] : people)
            if let preview { result.preview = messages(["value": [preview]], chat: result, me: me).first }
            return result
        }
    }

    /// The chats of several accounts, with a name that turns up in more than one account followed by the account
    /// ("Anna (contoso.com)"), so two chats of different accounts never become one in the Chats tab.
    static func distinguish(_ lists: [[Chat]], labels: [String]) -> [[Chat]] {
        let fold = { (name: String) in name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var accounts: [String: Set<Int>] = [:]
        for (index, list) in lists.enumerated() {
            for chat in list { accounts[fold(chat.name), default: []].insert(index) }
        }
        return lists.enumerated().map { index, list in
            list.map { chat in
                // A chat without a name yet (a private chat whose newest message is yours) is named by its messages
                // later: "(account)" alone would make it a chat of its own.
                guard !chat.name.isEmpty, (accounts[fold(chat.name)]?.count ?? 0) > 1, index < labels.count, !labels[index].isEmpty
                else { return chat }
                var named = chat
                named.name = "\(chat.name) (\(labels[index]))"
                return named
            }
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
                  message["deletedDateTime"] as? String == nil, message["isDeleted"] as? Bool != true, let sent = ChatJSON.date(message["createdDateTime"]) else { return nil }
            let body = message["body"] as? [String: Any] ?? [:]
            var text = (body["content"] as? String) ?? ""
            if (body["contentType"] as? String)?.lowercased() == "html" { text = plain(html: text) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = message["attachments"] as? [[String: Any]] ?? []
            if text.isEmpty {
                text = attachments.filter { $0["contentType"] as? String != "messageReference" }
                    .compactMap { $0["name"] as? String }.joined(separator: ", ")
            }
            guard !text.isEmpty else { return nil }
            let user = ((message["from"] as? [String: Any])?["user"] as? [String: Any]) ?? [:]
            let mine = me != nil && (user["id"] as? String) == me
            let sender = mine || !chat.isGroup ? "" : ((user["displayName"] as? String) ?? "")
            var inbox = InboxMessage(id: "teams-\(id)", sender: sender, text: text, date: sent, fromMe: mine)
            // Graph shares no one's read receipts but your own: your message is on Teams, and that is all it says.
            if mine { inbox.receipt = .sent }
            inbox.quote = attachments.lazy.compactMap { quote($0, me: me) }.first
            inbox.reactions = reactions((message["reactions"] as? [[String: Any]] ?? []).map { reaction -> (key: String, mine: Bool, name: String?) in
                let user = (reaction["user"] as? [String: Any])?["user"] as? [String: Any]
                return (key: (reaction["reactionType"] as? String) ?? "", mine: me != nil && user?["id"] as? String == me,
                        name: user?["displayName"] as? String)
            })
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// The message an answer quotes, from Graph's `messageReference` attachment (its content a JSON text with the
    /// message's id, the start of its text and who sent it). Nil for any other attachment.
    static func quote(_ attachment: [String: Any], me: String?) -> InboxQuote? {
        guard attachment["contentType"] as? String == "messageReference",
              let content = (attachment["content"] as? String)?.data(using: .utf8),
              let reference = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any] else { return nil }
        let id = (reference["messageId"] as? String) ?? (attachment["id"] as? String)
        let user = (reference["messageSender"] as? [String: Any])?["user"] as? [String: Any]
        let mine = me != nil && user?["id"] as? String == me
        return InboxQuote(id: id.map { "teams-" + $0 }, sender: (user?["displayName"] as? String) ?? "",
                          text: plain(html: (reference["messagePreview"] as? String) ?? ""), mine: mine)
    }

    // MARK: Reactions

    /// Teams' own reactions by their key, each as the emoji the reaction buttons of every chat in Nook use.
    /// The emoji of a Teams reaction key: one from Teams' own list ("like", "cwl", "1f64f_foldedhands", see
    /// `TeamsEmoji`), an emoji itself (as Graph writes the newer ones), or for a key the list does not have yet, its
    /// code points before "_". Nil when it says none.
    static func emoji(key: String) -> String? {
        if let known = TeamsEmoji.byKey[key.lowercased()] { return known }
        if key.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF }) {
            return key
        }
        let code = key.split(separator: "_").first.map(String.init) ?? ""
        let scalars = code.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap { Unicode.Scalar($0) } }
        guard !scalars.isEmpty, scalars.count == code.split(separator: "-").count,
              scalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The key Teams keeps an emoji under, from its own list; nil for an emoji Teams does not offer, which it would
    /// show as a placeholder.
    static func key(emoji: String) -> String? {
        TeamsEmoji.byEmoji[TeamsEmoji.bare(emoji)]
    }

    /// Reactions as (key, yours) pairs, one per person, as chips: one per emoji with how many, the most used first
    /// (then in the order they came). An empty list too, so the last one taken back leaves none.
    static func reactions(_ pairs: [(key: String, mine: Bool, name: String?)]) -> [InboxReaction] {
        var chips: [InboxReaction] = []
        for pair in pairs {
            guard let emoji = emoji(key: pair.key) else { continue }
            let names = !pair.mine && !(pair.name ?? "").isEmpty ? [pair.name!] : []
            if let index = chips.firstIndex(where: { $0.emoji == emoji }) {
                chips[index].count += 1
                chips[index].mine = chips[index].mine || pair.mine
                if !names.isEmpty { chips[index].people = (chips[index].people ?? []) + names }
            } else {
                chips.append(InboxReaction(emoji: emoji, count: 1, mine: pair.mine, people: names.isEmpty ? nil : names))
            }
        }
        return chips.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Whether an answer of /me/chats/{id}/messages already lists the newest message the chat list announced. Graph can
    /// announce a message in the list a few seconds before the chat's own messages show it; a chat read too early must
    /// be read again. System notices count too, since the list announces those as well.
    static func caughtUp(_ json: [String: Any], last: Date?) -> Bool {
        guard let last else { return true }
        let newest = (json["value"] as? [[String: Any]] ?? []).compactMap { ChatJSON.date($0["createdDateTime"]) }.max()
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
