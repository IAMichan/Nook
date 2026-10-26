import Foundation

/// Teams' own chat service ("chatsvc"), as the Teams website reads your chats: the session token the website sends on
/// those requests (picked up by `TeamsWebSession` after you signed in on teams.microsoft.com), the chat list and each
/// chat's messages, turned into chats for the Chats tab. Foundation only, so it can be tested anywhere; `TeamsBridge`
/// makes the calls. Work or school accounts, as on the website; channels are left out, as with Microsoft Graph.
/// Endpoints: {base}/v1/users/ME/conversations and {base}/v1/users/ME/conversations/{id}/messages; a message is
/// edited and deleted at …/messages/{messageId}, and a chat marked read at …/{id}/properties?name=consumptionhorizon.
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
        /// Your sign-in address, when the token you signed in with says it.
        var email: String?
    }

    /// An account linked through the website: its session, and the website's store on this Mac that keeps that
    /// account's sign-in apart from the others'.
    struct Account: Codable, Equatable, Sendable, Identifiable {
        var session: Session
        var store: UUID
        var id: String { session.me }
        /// What the account is called in Settings: your name, else your address.
        var label: String { !session.name.isEmpty ? session.name : (session.email ?? "") }
    }

    /// Keeps a session the website gave in `store`: in place of the same account (signed in before, in this store or
    /// another, whose store is then no longer needed), in place of the account this store held, or as one more account.
    /// What the accounts already knew of your name and address stays.
    static func keep(_ found: Session, store: UUID, in accounts: [Account]) -> (accounts: [Account], dropped: [UUID]) {
        var result = accounts
        var kept = found
        if let known = accounts.first(where: { $0.id == found.me })?.session {
            if kept.name.isEmpty { kept.name = known.name }
            if kept.email == nil { kept.email = known.email }
        }
        var dropped: [UUID] = []
        if let same = result.firstIndex(where: { $0.id == found.me }) {
            if result[same].store != store { dropped.append(result[same].store) }
            result[same] = Account(session: kept, store: store)
            // The store held another account until now: that one signed out there.
            result.removeAll { $0.store == store && $0.id != found.me }
        } else if let held = result.firstIndex(where: { $0.store == store }) {
            result[held] = Account(session: kept, store: store)
        } else {
            result.append(Account(session: kept, store: store))
        }
        return (result, dropped)
    }

    /// The session with your name and address from the token you signed in with, where it says them.
    static func named(_ session: Session, by token: String) -> Session {
        guard let claims = claims(token) else { return session }
        var named = session
        if named.name.isEmpty, let name = claims["name"] as? String { named.name = name.trimmingCharacters(in: .whitespaces) }
        if named.email == nil {
            named.email = ["upn", "preferred_username", "unique_name"].lazy.compactMap { claims[$0] as? String }
                .first { $0.contains("@") }
        }
        return named
    }

    /// The session from a request the website sent: its address and its authentication header ("skypetoken=…"). Nil
    /// for any other request, or a token that does not say who you are.
    static func session(url: String, header: String, now: Date = Date()) -> Session? {
        guard let range = url.range(of: chatService, options: .regularExpression) else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        var token = value
        for prefix in ["skypetoken=", "bearer "] where token.lowercased().hasPrefix(prefix) {
            token = String(token.dropFirst(prefix.count))
        }
        guard !token.isEmpty, let claims = claims(token), let id = claims["skypeid"] as? String, !id.isEmpty else { return nil }
        let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init)
        return Session(base: String(url[range]), token: token,
                      expires: exp.map(Date.init(timeIntervalSince1970:)) ?? now.addingTimeInterval(3600),
                      me: id.hasPrefix("8:") ? id : "8:" + id)
    }

    /// The chat service's address in a request: "…/api/chatsvc/{region}" on the website's own host, or the regional
    /// host the new Teams asks directly ("https://emea.ng.msg.teams.microsoft.com").
    static let chatService = #"^https://(?:[^/?#]+/api/chatsvc/[^/?#]+|[^/?#]+\.msg\.teams\.microsoft\.com)(?=/v1/)"#

    /// The session from what Teams' sign-in service (`/api/authsvc/v1.0/authz`) answers: the session token and the
    /// chat service of your region. Nil for any other answer.
    static func session(authz json: [String: Any], now: Date = Date()) -> Session? {
        guard let token = (json["tokens"] as? [String: Any])?["skypeToken"] as? String, !token.isEmpty else { return nil }
        let regions = json["regionGtms"] as? [String: Any] ?? [:]
        let header = "skypetoken=" + token
        for key in ["chatServiceAfd", "chatService"] {
            var base = (regions[key] as? String) ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            if let found = session(url: base + "/v1/", header: header, now: now) { return found }
        }
        guard let region = json["region"] as? String, !region.isEmpty else { return nil }
        return session(skypeToken: token, region: region, now: now)
    }

    /// A token the website signed in with that Teams' sign-in service turns into a session token: one for
    /// api.spaces.skype.com that has not run out.
    static func isSpacesToken(_ token: String, now: Date = Date()) -> Bool {
        guard let claims = claims(token), let audience = claims["aud"] as? String,
              audience.contains("api.spaces.skype.com") else { return false }
        let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init)
        return exp.map { Date(timeIntervalSince1970: $0) > now } ?? true
    }

    /// A session token itself (it says who you are) that has not run out, as the website may keep it.
    static func isSkypeToken(_ token: String, now: Date = Date()) -> Bool {
        guard let claims = claims(token), let id = claims["skypeid"] as? String, !id.isEmpty else { return false }
        let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init)
        return exp.map { Date(timeIntervalSince1970: $0) > now } ?? true
    }

    /// The session for a session token found on its own, with the chat service of `region` ("emea").
    static func session(skypeToken token: String, region: String, now: Date = Date()) -> Session? {
        session(url: "https://teams.microsoft.com/api/chatsvc/\(region)/v1/", header: "skypetoken=" + token, now: now)
    }

    /// The region a session token names ("rgn"), if it does.
    static func region(_ token: String) -> String? {
        (claims(token)?["rgn"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// The tokens in a text the website handled (a sign-in answer, an entry of its token cache): each one once.
    static func tokens(in text: String) -> [String] {
        var found: [String] = []
        var rest = text[...]
        while let range = rest.range(of: #"eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+"#, options: .regularExpression) {
            let token = String(rest[range])
            if !found.contains(token) { found.append(token) }
            rest = rest[range.upperBound...]
        }
        return found
    }

    /// The token in the website's `authtoken` cookie: "Bearer%3DeyJ…%26Origin%3D…".
    static func bearer(cookie: String) -> String? {
        let value = cookie.removingPercentEncoding ?? cookie
        guard let range = value.range(of: "Bearer=") else { return nil }
        let token = value[range.upperBound...].prefix { $0 != "&" }
        return token.isEmpty ? nil : String(token)
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
            let answer: (html: String, quote: InboxQuote?) = type == "Text" ? (content, nil) : reply(content, me: me)
            var text = (type == "Text" ? answer.html : TeamsData.plain(html: answer.html)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = files(properties["files"]) }
            guard !text.isEmpty else { return nil }
            let mine = contact(message["from"]) == me
            let sender = mine || !chat.isGroup ? "" : ((message["imdisplayname"] as? String) ?? "")
            var inbox = InboxMessage(id: "teams-\(id)", sender: sender, text: text, date: sent, fromMe: mine)
            if mine { inbox.receipt = .sent }
            inbox.quote = answer.quote
            inbox.reactions = reactions(properties["emotions"], me: me)
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// The answer a message's rich text holds (`<blockquote itemtype="http://schema.skype.com/Reply" itemid="{id}">`
    /// with who wrote the answered message and the start of its text): the quote, and the message without it.
    static func reply(_ html: String, me: String) -> (html: String, quote: InboxQuote?) {
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard let range = html.range(of: #"<blockquote[^>]*schema\.skype\.com/Reply[^>]*>[\s\S]*?</blockquote>"#, options: options)
        else { return (html, nil) }
        let block = String(html[range])
        let rest = html.replacingCharacters(in: range, with: "")
        let opening = block.range(of: "<blockquote[^>]*>", options: options).map { String(block[$0]) } ?? ""
        let author = block.range(of: #"<strong[^>]*itemprop="mri"[^>]*>[\s\S]*?</strong>"#, options: options).map { String(block[$0]) }
        let preview = block.range(of: #"<p[^>]*itemprop="preview"[^>]*>[\s\S]*?</p>"#, options: options).map { String(block[$0]) }
        let mri = author.flatMap { attribute("itemid", in: $0) }
        let id = attribute("itemid", in: opening)
        var quote = InboxQuote(id: id.map { "teams-" + $0 }, sender: TeamsData.plain(html: author ?? ""),
                               text: TeamsData.plain(html: preview ?? ""), mine: mri != nil && mri == me)
        if quote.text.isEmpty {
            // No preview of its own: whatever the quote says besides who and when.
            var body = block
            for pattern in [#"<strong[^>]*itemprop="mri"[\s\S]*?</strong>"#, #"<span[^>]*itemprop="time"[\s\S]*?</span>"#] {
                body = body.replacingOccurrences(of: pattern, with: "", options: options)
            }
            quote.text = TeamsData.plain(html: body)
        }
        return (rest, quote)
    }

    /// An attribute's value in an HTML tag, entities left as they are (ids have none).
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\\s" + name + #"="[^"]*""#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = tag[range].drop { $0 != "\"" }.dropFirst().dropLast()
        return value.isEmpty ? nil : String(value)
    }

    /// The emoji on a message from its "emotions" property (a list, or that list as JSON text): each key with the
    /// people who chose it. Nil when the message does not say (a chat list's preview), so what the chat showed stays.
    static func reactions(_ value: Any?, me: String) -> [InboxReaction]? {
        var list = value as? [[String: Any]]
        if list == nil, let text = value as? String, let data = text.data(using: .utf8) {
            list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        }
        guard let list else { return nil }
        return TeamsData.reactions(list.flatMap { emotion -> [(key: String, mine: Bool)] in
            let key = (emotion["key"] as? String) ?? ""
            return (emotion["users"] as? [[String: Any]] ?? []).map { (key: key, mine: contact($0["mri"]) == me) }
        })
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

    /// Where the page before these messages is (`_metadata.backwardLink`): nil at the chat's start. Only a link on the
    /// session's own chat service (`base`) is followed, never another host, since the token goes with it.
    static func backwardLink(_ json: [String: Any], base: String) -> String? {
        guard let link = (json["_metadata"] as? [String: Any])?["backwardLink"] as? String, !link.isEmpty,
              let url = URL(string: link), url.scheme == "https", let host = url.host?.lowercased(),
              host == URL(string: base)?.host?.lowercased() else { return nil }
        return link
    }

    // MARK: Sending

    /// What sending a message posts to {base}/v1/users/ME/conversations/{id}/messages, as the website sends it: your
    /// message as rich text (`html(_:)`, after `replyHTML` for an answer) under your name, with an id of the sender's
    /// own that tells a retry from a new message.
    static func outgoing(html: String, name: String, clientMessageID: String) -> [String: Any] {
        [
            "content": html, "messagetype": "RichText/Html", "contenttype": "text",
            "clientmessageid": clientMessageID, "imdisplayname": name,
            "properties": ["importance": "", "subject": ""],
        ]
    }

    /// Text as the rich text the website sends: escaped, each line a paragraph of its own, an empty line kept.
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "<p>" + (line.isEmpty ? "&nbsp;" : escaped(String(line))) + "</p>"
        }.joined()
    }

    /// The quote an answer starts with, as the website writes it (and `reply(_:me:)` reads it): the answered message's
    /// id in Nook ("teams-…"), who wrote it (their id, when known, and name) and the start of its text.
    static func replyHTML(to message: String, author: String?, sender: String, text: String) -> String {
        let id = escaped(message.hasPrefix("teams-") ? String(message.dropFirst("teams-".count)) : message)
        let preview = text.count > 200 ? String(text.prefix(200)) + "…" : text
        return #"<blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="\#(id)">"#
            + #"<strong itemprop="mri" itemid="\#(escaped(author ?? ""))">\#(escaped(sender))</strong>"#
            + #"<span itemprop="time" itemid="\#(id)"></span>"#
            + #"<p itemprop="preview">\#(escaped(preview))</p></blockquote>"#
    }

    /// Text escaped for HTML.
    static func escaped(_ text: String) -> String {
        var escaped = text
        for (character, entity) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")] {
            escaped = escaped.replacingOccurrences(of: character, with: entity)
        }
        return escaped
    }

    /// The messages Teams marked as deleted (`properties.deletetime`), by their id in Nook ("teams-…"): `messages`
    /// leaves them out, and the chat in Nook drops them too.
    static func deleted(_ json: [String: Any]) -> [String] {
        (json["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String, !id.isEmpty,
                  let properties = message["properties"] as? [String: Any], properties["deletetime"] != nil else { return nil }
            return "teams-" + id
        }
    }

    // MARK: Changing a chat

    /// A message's id on the chat service, from its id in Nook ("teams-…"); nil for a message Nook did not read there.
    static func serviceID(_ message: String) -> String? {
        guard message.hasPrefix("teams-") else { return nil }
        let id = String(message.dropFirst("teams-".count))
        return id.isEmpty ? nil : id
    }

    /// Where a chat's messages are on the chat service (after the session's base), or one message of them, as the
    /// website edits ("PUT") and deletes ("DELETE") it there.
    static func messagePath(chat: String, message: String? = nil) -> String {
        "/v1/users/ME/conversations/" + ChatJSON.segment(chat) + "/messages" + (message.map { "/" + ChatJSON.segment($0) } ?? "")
    }

    /// What editing a message puts at `messagePath(chat:message:)`: the new text as rich text under your name, as
    /// sending writes it (`outgoing`).
    static func edited(html: String, name: String, clientMessageID: String) -> [String: Any] {
        ["content": html, "messagetype": "RichText/Html", "contenttype": "text", "clientmessageid": clientMessageID,
         "imdisplayname": name]
    }

    /// The newest of these messages (ids in Nook, "teams-…"): Teams' message ids are the time the message arrived, in
    /// milliseconds, so the largest is the newest. Nil when none is a message of the chat service.
    static func newest(_ messages: [String]) -> (id: String, arrived: Int64)? {
        messages.compactMap { message -> (id: String, arrived: Int64)? in
            guard let id = serviceID(message), let ms = Int64(id) else { return nil }
            return (id, ms)
        }.max { $0.arrived < $1.arrived }
    }

    /// Where a chat's "consumption horizon" is (after the session's base): until when you read it.
    static func horizonPath(chat: String) -> String {
        "/v1/users/ME/conversations/" + ChatJSON.segment(chat) + "/properties?name=consumptionhorizon"
    }

    /// What marking a chat read puts at `horizonPath(chat:)`, as the website does. The horizon is three numbers with
    /// semicolons between them: when the newest message you read arrived (milliseconds since 1970, which is also its
    /// id), when you read it (now, in milliseconds), and that message's id. `readUntil` reads the first one back.
    static func horizon(newest id: String, arrived: Int64, now: Date = Date()) -> [String: Any] {
        let read = Int64((now.timeIntervalSince1970 * 1000).rounded())
        return ["consumptionhorizon": "\(arrived);\(read);\(id)"]
    }

    /// Who wrote each message ("8:orgid:…"), by its id in Nook.
    static func authors(_ json: [String: Any]) -> [String: String] {
        var authors: [String: String] = [:]
        for message in json["messages"] as? [[String: Any]] ?? [] {
            if let id = message["id"] as? String, let from = contact(message["from"]) { authors["teams-" + id] = from }
        }
        return authors
    }

    /// Whether the messages already list the newest one the chat list announced (see `TeamsData.caughtUp`).
    static func caughtUp(_ json: [String: Any], last: Date?) -> Bool {
        guard let last else { return true }
        let newest = (json["messages"] as? [[String: Any]] ?? []).compactMap(date).max()
        return newest.map { $0 >= last.addingTimeInterval(-1) } ?? false
    }
}
