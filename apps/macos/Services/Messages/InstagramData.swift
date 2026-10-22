import Foundation

/// What Instagram's own web API answers about your direct messages, turned into chats for the Chats tab, and what Nook
/// sends back to it. This is how Beeper reads Instagram too: you sign in once on instagram.com (inside Nook, Settings ›
/// Chats › Log in), and Nook asks the same API the website itself uses, with that sign-in. The requests run inside
/// Nook's own signed-in instagram.com page (`InstagramBridge`), so the sign-in never leaves it. Foundation only, so it
/// can be tested anywhere. Endpoints: /api/v1/direct_v2/inbox/, /api/v1/direct_v2/threads/{id}/ and
/// /api/v1/direct_v2/threads/broadcast/text/.
enum InstagramData {
    /// One conversation, with its newest messages oldest first.
    struct Thread: Equatable, Sendable {
        var id: String
        var name: String
        var isGroup: Bool
        /// When something last happened in it: a thread whose last activity did not change needs no new read.
        var last: Date?
        /// Messages from others you have not seen yet, as Instagram keeps it.
        var unread: Int
        /// A group's other people by name (you left out).
        var members: [String] = []
        var messages: [InboxMessage] = []
    }

    /// The website's own app id, which it sends with every API request.
    static let appID = "936619743392459"
    /// The page the requests run in, and where you sign in.
    static let site = URL(string: "https://www.instagram.com/direct/inbox/")!
    /// The cookie Instagram keeps only while you are signed in.
    static let sessionCookie = "sessionid"
    /// The newest threads with their newest messages.
    static let inboxPath = "/api/v1/direct_v2/inbox/?persistentBadging=true&folder=&limit=30&thread_message_limit=20"
    static let sendPath = "/api/v1/direct_v2/threads/broadcast/text/"
    /// The longest text Nook sends in one message.
    static let maxText = 1_000

    /// One thread's newest messages.
    static func threadPath(_ id: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return "/api/v1/direct_v2/threads/\(safe)/?limit=20"
    }

    /// Whether a cookie in Nook's instagram.com store says you are signed in.
    static func isSession(name: String, domain: String, value: String) -> Bool {
        name == sessionCookie && !value.isEmpty && isInstagram(domain)
    }

    /// A cookie's domain that is Instagram's own (".instagram.com", "www.instagram.com"), not one that only ends alike.
    static func isInstagram(_ domain: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// An answer of the API as JSON, or the reason it is none: signed out (Instagram sends the request to its sign-in
    /// page, or says a login is required), a check Instagram wants you to do on its website first, too many requests,
    /// or a refusal with its own words.
    static func check(status: Int, url: String, body: String) throws -> [String: Any] {
        let json = object(body)
        let message = (json?["message"] as? String) ?? ""
        if url.contains("/accounts/login") || message == "login_required" || (status == 401 && json == nil) {
            throw NookError(tr("chats.instagram.signedOut"), kind: .auth)
        }
        if message.contains("checkpoint") || message.contains("challenge") {
            throw NookError(tr("chats.instagram.checkpoint"), kind: .auth)
        }
        if status == 429 || message.contains("wait a few minutes") { throw NookError(tr("chats.instagram.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(status), let json, (json["status"] as? String) != "fail" else {
            throw NookError(tr("chats.instagram.refused", message.isEmpty ? "HTTP \(status)" : message), kind: status == 403 ? .auth : .other)
        }
        return json
    }

    /// An id as Instagram sends it: a number or a numeral.
    static func id(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Instagram's moments: microseconds since 1970, as a number or a numeral.
    static func date(_ value: Any?) -> Date? {
        let micro = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let micro, micro > 0 else { return nil }
        return Date(timeIntervalSince1970: micro / 1_000_000)
    }

    /// Your own id: the inbox names you as its viewer, a thread does as well.
    static func viewer(_ json: [String: Any]) -> String? {
        id((json["viewer"] as? [String: Any])?["pk"]) ?? id(json["viewer_id"])
    }

    /// The threads of the inbox, the most recently active first.
    static func threads(_ json: [String: Any]) -> [Thread] {
        let me = viewer(json)
        let list = (json["inbox"] as? [String: Any])?["threads"] as? [[String: Any]] ?? []
        return list.compactMap { thread($0, me: me) }
    }

    /// One thread of the inbox or of /threads/{id}/ (`{"thread": …}`). A thread is called by its title, which Instagram
    /// sets to the other person's name in a private chat; else after its people.
    static func thread(_ json: [String: Any], me: String?) -> Thread? {
        guard let id = Self.id(json["thread_id"]) else { return nil }
        let viewer = me ?? Self.id(json["viewer_id"])
        let users = (json["users"] as? [[String: Any]] ?? []).filter { viewer == nil || Self.id($0["pk"]) != viewer }
        var names: [String: String] = [:]
        for user in users {
            guard let pk = Self.id(user["pk"]) else { continue }
            names[pk] = displayName(user)
        }
        let people = users.map(displayName).filter { !$0.isEmpty }
        let title = ((json["thread_title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? people.joined(separator: ", ") : title
        guard !name.isEmpty else { return nil }
        let isGroup = (json["is_group"] as? Bool) ?? (users.count > 1)
        let items = json["items"] as? [[String: Any]] ?? []
        let messages = items.compactMap { message($0, me: viewer, isGroup: isGroup, names: names) }.sorted { $0.date < $1.date }
        let last = date(json["last_activity_at"]) ?? messages.last?.date
        return Thread(id: id, name: name, isGroup: isGroup, last: last,
                      unread: unread(json, messages: messages, me: viewer),
                      members: isGroup ? people : [], messages: messages)
    }

    /// A person's name as Instagram shows it: their full name, else their username.
    private static func displayName(_ user: [String: Any]) -> String {
        let full = ((user["full_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? ((user["username"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : full
    }

    /// How many messages from others came after you last saw the thread. A thread Instagram marks unread counts at least
    /// one, even when its newest messages are not in the answer.
    static func unread(_ json: [String: Any], messages: [InboxMessage], me: String?) -> Int {
        let marked = ((json["read_state"] as? NSNumber)?.intValue ?? 0) == 1
        var seen: Date?
        if let me, let mine = (json["last_seen_at"] as? [String: Any])?[me] as? [String: Any] { seen = date(mine["timestamp"]) }
        let theirs = messages.filter { !$0.isMine }
        let count = seen.map { seen in theirs.filter { $0.date > seen }.count } ?? (marked ? theirs.suffix(1).count : 0)
        return marked ? max(count, 1) : count
    }

    /// One message, or nil for what is no message (a notice that someone joined, a reaction).
    static func message(_ item: [String: Any], me: String?, isGroup: Bool, names: [String: String]) -> InboxMessage? {
        guard let id = Self.id(item["item_id"]), let sent = date(item["timestamp"]) else { return nil }
        let user = Self.id(item["user_id"])
        let mine = me != nil && user == me
        var text = ""
        var media: ChatMedia?
        switch (item["item_type"] as? String) ?? "" {
        case "text":
            text = (item["text"] as? String) ?? ""
        case "link":
            text = ((item["link"] as? [String: Any])?["text"] as? String) ?? (item["text"] as? String) ?? ""
        case "media", "raw_media", "visual_media":
            let container = (item["media"] as? [String: Any]) ?? ((item["visual_media"] as? [String: Any])?["media"] as? [String: Any]) ?? [:]
            media = ChatMedia(kind: (container["media_type"] as? NSNumber)?.intValue == 2 ? .video : .photo)
        case "animated_media":
            media = ChatMedia(kind: .gif)
        case "voice_media":
            media = ChatMedia(kind: .voice)
        case "like":
            text = "❤️"
        case "media_share", "clip", "felix_share", "xma_media_share", "xma_clip", "story_share", "reel_share", "xma_reel_share", "xma_story_share":
            text = ((item["reel_share"] as? [String: Any])?["text"] as? String) ?? ""
            text = text.isEmpty ? tr("chats.instagram.shared") : text
        case "action_log", "placeholder", "video_call_event", "reaction":
            return nil
        default:
            text = (item["text"] as? String) ?? tr("chats.instagram.unsupported")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || media != nil else { return nil }
        let sender = mine || !isGroup ? "" : (user.flatMap { names[$0] } ?? "")
        var message = InboxMessage(id: "instagram-\(id)", sender: sender, text: text, date: sent, fromMe: mine, media: media)
        // Instagram tells who saw it per thread, not per message: your message is on Instagram, and that is all it says.
        if mine { message.receipt = .sent }
        return message
    }

    /// The form that sends `text` to a thread, as the website sends it. `context` is the message's own id, so sending
    /// it twice never shows it twice.
    static func sendForm(thread: String, text: String, context: String) -> [String: String] {
        let ids = (try? JSONSerialization.data(withJSONObject: [thread])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\(thread)\"]"
        return ["action": "send_item", "client_context": context, "mutation_token": context, "offline_threading_id": context,
                "thread_ids": ids, "text": text]
    }

    /// A new message id as the website makes one: a large number.
    static func newContext() -> String {
        String(UInt64.random(in: 6_000_000_000_000_000_000...6_999_999_999_999_999_999))
    }

    /// The form as the body of a POST, with the values escaped.
    static func form(_ fields: [String: String]) -> String {
        String(decoding: TeamsData.form(fields), as: UTF8.self)
    }
}
