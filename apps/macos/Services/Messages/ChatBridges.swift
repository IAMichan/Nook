import Foundation

/// A chat app Nook reads itself, history included, instead of waiting for its notifications: Messages from its database
/// on this Mac, Slack through its Web API with your token. What a bridge reads lands in the same `ChatInbox` as the
/// collected notifications (`ChatCaptureService` runs them), so a chat is one chat however it came in. Read-only:
/// answering still happens in the app itself.
@MainActor
protocol ChatBridge: AnyObject {
    /// The app's source id (`MessagingApp.id`).
    var app: String { get }
    /// Whether it can read right now: the app's data is there, or a token is set.
    var isReady: Bool { get }
    /// Its last read worked, so the app's notifications only repeat what it reads.
    var isWorking: Bool { get }
    /// How long to wait between two reads.
    var interval: TimeInterval { get }
    /// The chats that changed since the last read (everything on the first), with their newest messages.
    func read() async throws -> [BridgedChat]
}

// MARK: Messages

/// iMessage and sms from Messages' own database (`~/Library/Messages/chat.db`), read-only and only on this Mac. Needs
/// Full Disk Access, as collecting notifications does. The first read brings the newest chats with their history;
/// after that only the messages that came in since, and every chat's unread count as Messages keeps it.
@MainActor
final class MessagesBridge: ChatBridge {
    let app = "messages"
    let interval: TimeInterval = 5
    private(set) var isWorking = false

    /// Chats and messages per chat on the first read.
    private static let chats = 30
    private static let perChat = 30
    /// Only the newest messages are looked at: the database keeps the whole history and an old Mac has a lot of it.
    private static let window = 20_000

    private var path: String { AppDatabase.home + "/Library/Messages/chat.db" }
    private var lastRow: Int64?
    private var lastChange: Date?
    /// Every chat read so far by its id in the database, with its name in Nook, for the unread counts.
    private var names: [String: String] = [:]

    var isReady: Bool { FileManager.default.fileExists(atPath: path) }

    func read() async throws -> [BridgedChat] {
        let change = [path, path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
        if lastRow != nil, change != nil, change == lastChange { return [] }
        let contacts = await ContactDirectory.names()
        let recent = "m.ROWID > (SELECT COALESCE(MAX(ROWID), 0) - \(Self.window) FROM message)"
        let rows: [[String: Any]]
        if let lastRow {
            rows = try await query(Self.select + " WHERE m.ROWID > \(lastRow) AND COALESCE(m.associated_message_type, 0) = 0 ORDER BY m.ROWID")
        } else {
            rows = try await query("""
            SELECT * FROM (
                SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.chat ORDER BY x.date DESC) AS position FROM (
                    \(Self.select) WHERE \(recent) AND COALESCE(m.associated_message_type, 0) = 0
                        AND cmj.chat_id IN (
                            SELECT cmj.chat_id FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                            WHERE \(recent) GROUP BY cmj.chat_id ORDER BY MAX(m.date) DESC LIMIT \(Self.chats))
                ) x
            ) WHERE position <= \(Self.perChat)
            """)
        }
        var messages: [String: [InboxMessage]] = [:]
        var newest = lastRow ?? 0
        let unnamed = try await groupNames(rows, contacts: contacts)
        for row in rows {
            let id = NotificationRecord.integer(row["id"]) ?? 0
            newest = max(newest, id)
            guard let message = AppData.messages([row], names: contacts).first else { continue }
            let chat = message.chat
            names[chat] = unnamed[chat] ?? names[chat] ?? message.chatName
            let group = (AppData.number(row["grp"]) ?? 0) != 0
            messages[chat, default: []].append(InboxMessage(
                id: "imessage-\(id)", sender: message.fromMe || !group ? "" : message.sender, text: message.text,
                date: message.date, fromMe: message.fromMe))
        }
        // Messages' own unread count of every chat Nook shows: reading it on the Mac or the phone clears it here too.
        let unreadRows = try await query("""
        SELECT cmj.chat_id AS chat, SUM(CASE WHEN m.is_from_me = 0 AND m.is_read = 0 THEN 1 ELSE 0 END) AS unread
        FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE \(recent) AND COALESCE(m.associated_message_type, 0) = 0 GROUP BY cmj.chat_id
        """)
        var unread: [String: Int] = [:]
        for row in unreadRows { unread[AppData.string(row["chat"])] = Int(AppData.number(row["unread"]) ?? 0) }

        lastRow = newest
        lastChange = change
        isWorking = true
        // An iMessage and an sms conversation with the same person are one chat in Nook, with both their counts.
        var chats: [String: BridgedChat] = [:]
        for (chat, name) in names {
            var merged = chats[name] ?? BridgedChat(app: app, name: name, messages: [], unread: 0)
            merged.messages += messages[chat] ?? []
            merged.unread = (merged.unread ?? 0) + (unread[chat] ?? 0)
            chats[name] = merged
        }
        return chats.values.map { chat in
            var chat = chat
            chat.messages.sort { $0.date < $1.date }
            return chat
        }
    }

    /// A group without a name of its own is called after its people, as Messages does ("Anna, Jan, Lisa"), instead of
    /// every such group becoming one chat.
    private func groupNames(_ rows: [[String: Any]], contacts: [String: String]) async throws -> [String: String] {
        let chats = Set(rows.filter { row in
            (AppData.number(row["grp"]) ?? 0) != 0 && AppData.string(row["chatname"]).hasPrefix("chat")
                && names[AppData.string(row["chat"])] == nil
        }.compactMap { Int(AppData.string($0["chat"])) })
        guard !chats.isEmpty else { return [:] }
        let people = try await query("""
        SELECT chj.chat_id AS chat, h.id AS handle FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
        WHERE chj.chat_id IN (\(chats.sorted().map(String.init).joined(separator: ",")))
        """)
        var handles: [String: [String]] = [:]
        for row in people {
            let handle = AppData.cleanHandle(AppData.string(row["handle"]))
            handles[AppData.string(row["chat"]), default: []].append(contacts[AppData.key(handle)] ?? handle)
        }
        return handles.mapValues { $0.sorted().joined(separator: ", ") }
    }

    private static let select = """
    SELECT m.ROWID AS id, cmj.chat_id AS chat, COALESCE(NULLIF(c.display_name, ''), c.chat_identifier, '') AS chatname,
           COALESCE(h.id, '') AS handle, m.is_from_me AS me, m.date AS date, m.text AS text, hex(m.attributedBody) AS body,
           CASE WHEN c.style = 43 THEN 1 ELSE 0 END AS grp
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    """

    private func query(_ sql: String) async throws -> [[String: Any]] {
        do {
            return try await AppDatabase.query(path, sql, app: "Messages")
        } catch {
            isWorking = false
            throw error
        }
    }
}

// MARK: Slack

/// Your Slack direct messages and group messages, with their history, through Slack's Web API and a user token you set
/// in Settings › Chats (kept in the Keychain). Read-only scopes are enough: im:history, mpim:history, im:read,
/// mpim:read and users:read. Only slack.com is asked, and only for your own conversations.
@MainActor
final class SlackBridge: ChatBridge {
    let app = "slack"
    let interval: TimeInterval = 60
    private(set) var isWorking = false

    /// Where the token is kept.
    static let tokenAccount = "chats.slack.token"

    static var token: String? {
        guard let token = CloudHelp.secret(tokenAccount), token.hasPrefix("xox") else { return nil }
        return token
    }

    /// Conversations read in one go: the most recently active first, then a few of the others in turn, so every one is
    /// read sooner or later without passing Slack's rate limits.
    private static let perRead = 12
    private static let rotating = 4
    private static let firstHistory = 30

    private var me: String?
    private var users: [String: String] = [:]
    private var usersAt: Date?
    private var conversations: [SlackData.Conversation] = []
    private var conversationsAt: Date?
    /// The newest message read per conversation (Slack's `ts`), to ask only for what is newer.
    private var newest: [String: String] = [:]
    /// The latest activity seen per conversation, to read the busiest first.
    private var active: [String: Double] = [:]
    private var turn = 0

    var isReady: Bool { Self.token != nil }

    /// Forgets what was read (a new token may be another workspace).
    func reset() {
        me = nil
        users = [:]
        usersAt = nil
        conversations = []
        conversationsAt = nil
        newest = [:]
        active = [:]
        isWorking = false
    }

    func read() async throws -> [BridgedChat] {
        guard let token = Self.token else { isWorking = false; return [] }
        do {
            if me == nil { me = SlackData.me(try await call("auth.test", [:], token: token)) }
            if usersAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                users = try await pages("users.list", ["limit": "200"], token: token, maxPages: 5).reduce(into: [:]) { $0.merge(SlackData.users($1)) { a, _ in a } }
                usersAt = Date()
            }
            if conversationsAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                conversations = try await pages("conversations.list", ["types": "im,mpim", "exclude_archived": "true", "limit": "200"],
                                                token: token, maxPages: 5).flatMap(SlackData.conversations)
                for conversation in conversations { active[conversation.id] = max(active[conversation.id] ?? 0, conversation.updated) }
                conversationsAt = Date()
            }
            var chats: [BridgedChat] = []
            for conversation in pick() {
                var parameters = ["channel": conversation.id, "limit": String(Self.firstHistory)]
                if let ts = newest[conversation.id] { parameters["oldest"] = ts }
                let json = try await call("conversations.history", parameters, token: token)
                let messages = SlackData.messages(json, conversation: conversation, users: users, me: me)
                if let last = (json["messages"] as? [[String: Any]])?.compactMap({ $0["ts"] as? String })
                    .max(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }) {
                    newest[conversation.id] = last
                    active[conversation.id] = max(active[conversation.id] ?? 0, Double(last) ?? 0)
                } else if newest[conversation.id] == nil {
                    newest[conversation.id] = "0"
                }
                guard !messages.isEmpty else { continue }
                chats.append(BridgedChat(app: app, name: SlackData.chatName(conversation, users: users, me: me),
                                         messages: messages, unread: nil))
            }
            isWorking = true
            return chats
        } catch {
            isWorking = false
            throw error
        }
    }

    /// The conversations to read now: never read ones and the busiest, then a few others in turn.
    private func pick() -> [SlackData.Conversation] {
        let ordered = conversations.sorted { (active[$0.id] ?? 0) > (active[$1.id] ?? 0) }
        let unread = ordered.filter { newest[$0.id] == nil }
        let busy = ordered.filter { newest[$0.id] != nil }
        var picked = Array(unread.prefix(Self.perRead))
        let room = Self.perRead - picked.count
        guard room > 0 else { return picked }
        picked += busy.prefix(max(0, room - Self.rotating))
        let rest = Array(busy.dropFirst(max(0, room - Self.rotating)))
        if !rest.isEmpty {
            for offset in 0..<min(Self.rotating, rest.count, room) { picked.append(rest[(turn + offset) % rest.count]) }
            turn += Self.rotating
        }
        return picked
    }

    private func pages(_ method: String, _ parameters: [String: String], token: String, maxPages: Int) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var query = parameters
            if let cursor { query["cursor"] = cursor }
            let json = try await call(method, query, token: token)
            results.append(json)
            cursor = SlackData.nextCursor(json)
            if cursor == nil { break }
        }
        return results
    }

    private func call(_ method: String, _ parameters: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://slack.com/api/" + method)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NookError("Slack: \(method)") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw NookError(tr("chats.slack.rateLimited")) }
        guard (200..<300).contains(code), let json = SlackData.object(data) else { throw NookError("Slack: HTTP \(code)") }
        if let error = SlackData.error(json) { throw NookError(tr("chats.slack.refused", error)) }
        return json
    }
}
