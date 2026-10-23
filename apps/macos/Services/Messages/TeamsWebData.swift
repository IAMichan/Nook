import Foundation

/// Teams' own chat service ("chatsvc"), as the Teams website reads your chats: the session token the website sends on
/// those requests (picked up by `TeamsWebSession` after you signed in on teams.microsoft.com), the chat list and each
/// chat's messages, turned into chats for the Chats tab. Foundation only, so it can be tested anywhere; `TeamsBridge`
/// makes the calls. Work or school accounts, as on the website; channels are left out, as with Microsoft Graph.
/// Endpoints: {base}/v1/users/ME/conversations and {base}/v1/users/ME/conversations/{id}/messages.
enum TeamsWebData {
    /// What reading needs: where the chat service of your region is, the website's token for it, and who you are there.
    struct Session: Codable, Equatable, Sendable {
        /// "https://teams.microsoft.com/api/chatsvc/emea"
        var base: String
        var token: String
        var expires: Date
        /// Your id in the chat service ("8:orgid:…").
        var me: String
        /// Your name, once one of your own messages says it.
        var name: String = ""
    }

    /// The session from a request the website sent: its address and its authentication header ("skypetoken=…"). Nil
    /// for any other request, or a token that does not say who you are.
    static func session(url: String, header: String, now: Date = Date()) -> Session? {
        guard let range = url.range(of: #"^https://[^/?#]+/api/chatsvc/[^/?#]+(?=/v1/)"#, options: .regularExpression) else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        let token = value.lowercased().hasPrefix("skypetoken=") ? String(value.dropFirst("skypetoken=".count)) : value
        guard !token.isEmpty, let claims = claims(token), let id = claims["skypeid"] as? String, !id.isEmpty else { return nil }
        let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init)
        return Session(base: String(url[range]), token: token,
                      expires: exp.map(Date.init(timeIntervalSince1970:)) ?? now.addingTimeInterval(3600),
                      me: id.hasPrefix("8:") ? id : "8:" + id)
    }

    /// The claims of a JSON web token, read without checking it: the token goes back only to the service that made it.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A private chat, a group chat or a meeting chat; not a channel, and not the service's own lists (48:…).
    static func isChat(_ id: String) -> Bool {
        !id.hasPrefix("48:") && (id.hasSuffix("@unq.gbl.spaces") || id.hasSuffix("@thread.v2"))
    }

    /// The chats of the chat list. A chat with a topic is called by it; a private chat after the other person once a
    /// message of theirs says their name, else its name stays empty until its messages are read. Meeting chats
    /// without a topic and deleted chats are left out.
    static func chats(_ json: [String: Any], me: String) -> [TeamsData.Chat] {
        (json["conversations"] as? [[String: Any]] ?? []).compactMap { conversation in
            guard let id = conversation["id"] as? String, isChat(id) else { return nil }
            let thread = conversation["threadProperties"] as? [String: Any] ?? [:]
            if "\(thread["isdeleted"] ?? "")" == "true" { return nil }
            let topic = ((thread["topic"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if id.hasPrefix("19:meeting_"), topic.isEmpty { return nil }
            let oneOnOne = id.hasSuffix("@unq.gbl.spaces") || (thread["productThreadType"] as? String) == "OneToOneChat"
            let last = conversation["lastMessage"] as? [String: Any] ?? [:]
            let lastFrom = contact(last["from"])
            let theirName = ((last["imdisplayname"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let name = !topic.isEmpty ? topic : (oneOnOne && lastFrom != nil && lastFrom != me ? theirName : "")
            var chat = TeamsData.Chat(id: id, name: name, isGroup: !oneOnOne, last: date(last),
                                      readUntil: readUntil(conversation["properties"] as? [String: Any]))
            chat.preview = messages(["messages": [last]], chat: chat, me: me).first
            return chat
        }
    }

    /// Until when you read a chat: the first part of its "consumption horizon", in milliseconds.
    static func readUntil(_ properties: [String: Any]?) -> Date? {
        guard let horizon = properties?["consumptionhorizon"] as? String,
              let first = horizon.split(separator: ";").first, let ms = Double(first), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Who a message is from: the last part of its "from" address ("…/contacts/8:orgid:…").
    static func contact(_ value: Any?) -> String? {
        guard let from = value as? String, !from.isEmpty else { return nil }
        return from.split(separator: "/").last.map(String.init)
    }

    private static func date(_ message: [String: Any]) -> Date? {
        ChatJSON.date(message["composetime"]) ?? ChatJSON.date(message["originalarrivaltime"])
    }

    /// A chat's messages, oldest first: text and rich text only (no calls, no one joining), deleted ones left out; a
    /// message with only files shows their names.
    static func messages(_ json: [String: Any], chat: TeamsData.Chat, me: String) -> [InboxMessage] {
        let messages: [InboxMessage] = (json["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, let type = message["messagetype"] as? String,
                  type == "Text" || type.hasPrefix("RichText"), let sent = date(message) else { return nil }
            let properties = message["properties"] as? [String: Any] ?? [:]
            if properties["deletetime"] != nil { return nil }
            let content = (message["content"] as? String) ?? ""
            var text = (type == "Text" ? content : TeamsData.plain(html: content)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = files(properties["files"]) }
            guard !text.isEmpty else { return nil }
            let mine = contact(message["from"]) == me
            let sender = mine || !chat.isGroup ? "" : ((message["imdisplayname"] as? String) ?? "")
            var inbox = InboxMessage(id: "teams-\(id)", sender: sender, text: text, date: sent, fromMe: mine)
            if mine { inbox.receipt = .sent }
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// The names of the files sent with a message (a JSON list, as text).
    private static func files(_ value: Any?) -> String {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return "" }
        return list.compactMap { ($0["fileName"] as? String) ?? ($0["title"] as? String) }.joined(separator: ", ")
    }

    /// The other people who wrote in a chat, by name, in the order they first wrote: what a chat without a topic is
    /// called after.
    static func people(_ json: [String: Any], me: String) -> [String] {
        var names: [String] = []
        for message in (json["messages"] as? [[String: Any]] ?? []).reversed() where contact(message["from"]) != me {
            let name = ((message["imdisplayname"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Your own name, as one of your messages says it.
    static func myName(_ json: [String: Any], me: String) -> String? {
        (json["messages"] as? [[String: Any]] ?? []).first { contact($0["from"]) == me }
            .flatMap { ($0["imdisplayname"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the messages already list the newest one the chat list announced (see `TeamsData.caughtUp`).
    static func caughtUp(_ json: [String: Any], last: Date?) -> Bool {
        guard let last else { return true }
        let newest = (json["messages"] as? [[String: Any]] ?? []).compactMap(date).max()
        return newest.map { $0 >= last.addingTimeInterval(-1) } ?? false
    }
}
