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
    /// The group chats among them, and their people (you left out) once asked, as Messages lists them.
    private var groups: Set<String> = []
    private var members: [String: [String]] = [:]
    /// Your own newest messages by row, with their chat: their ticks are read again each time, as they move.
    private var mine: [Int64: (chat: String, message: InboxMessage)] = [:]
    private static let tracked = 200

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
        let files = try await attachments(rows)
        for row in rows {
            let id = NotificationRecord.integer(row["id"]) ?? 0
            newest = max(newest, id)
            let media = files[id]
            // A photo without a caption has no text to read: it is read as one with a placeholder, then left without.
            var readable = row
            if media != nil, AppData.messages([row], names: contacts).isEmpty { readable["text"] = Self.placeholder }
            guard let message = AppData.messages([readable], names: contacts).first else { continue }
            let chat = message.chat
            names[chat] = unnamed[chat] ?? names[chat] ?? message.chatName
            let group = (AppData.number(row["grp"]) ?? 0) != 0
            if group { groups.insert(chat) }
            var inbox = InboxMessage(
                id: "imessage-\(id)", sender: message.fromMe || !group ? "" : message.sender,
                text: message.text == Self.placeholder ? "" : message.text, date: message.date, fromMe: message.fromMe, media: media)
            if message.fromMe {
                inbox.receipt = Self.receipt(row)
                mine[id] = (chat, inbox)
            }
            messages[chat, default: []].append(inbox)
        }
        if mine.count > Self.tracked {
            for id in mine.keys.sorted().dropLast(Self.tracked) { mine[id] = nil }
        }
        // Your earlier messages whose ticks moved since (delivered, read): the chat shows them now.
        let fresh = Set(rows.compactMap { NotificationRecord.integer($0["id"]) })
        let earlier = mine.keys.filter { !fresh.contains($0) }
        if !earlier.isEmpty {
            for row in try await query("""
            SELECT ROWID AS id, is_sent AS sent, is_delivered AS delivered, COALESCE(date_read, 0) AS readat,
                   COALESCE(error, 0) AS error
            FROM message WHERE ROWID IN (\(earlier.sorted().map(String.init).joined(separator: ",")))
            """) {
                guard let id = NotificationRecord.integer(row["id"]), var known = mine[id] else { continue }
                let receipt = Self.receipt(row)
                guard receipt != known.message.receipt else { continue }
                known.message.receipt = receipt
                mine[id] = known
                messages[known.chat, default: []].append(known.message)
            }
        }
        try await loadMembers(contacts: contacts)
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
            if let people = members[chat], !people.isEmpty { merged.members = people }
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

    /// The text a message with only a file is read with, so it is not skipped as empty.
    private static let placeholder = "\u{1}"

    /// How far your message got, from its row (`sent`, `delivered`, `readat`, `error`). Read is the date they read it,
    /// which Messages only has when they share read receipts; `is_read` is about your own reading.
    private static func receipt(_ row: [String: Any]) -> ChatReceipt {
        ChatReceipts.messages(sent: (AppData.number(row["sent"]) ?? 0) != 0,
                              delivered: (AppData.number(row["delivered"]) ?? 0) != 0,
                              read: (AppData.number(row["readat"]) ?? 0) > 0,
                              failed: (AppData.number(row["error"]) ?? 0) != 0)
    }

    /// The people of the group chats not asked yet, by their name in Contacts (else their number or address).
    private func loadMembers(contacts: [String: String]) async throws {
        let asked = groups.filter { members[$0] == nil }.compactMap(Int.init)
        guard !asked.isEmpty else { return }
        let people = try await query("""
        SELECT chj.chat_id AS chat, h.id AS handle FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
        WHERE chj.chat_id IN (\(asked.sorted().map(String.init).joined(separator: ",")))
        """)
        var found: [String: Set<String>] = [:]
        for row in people {
            let handle = AppData.cleanHandle(AppData.string(row["handle"]))
            guard !handle.isEmpty else { continue }
            found[AppData.string(row["chat"]), default: []].insert(contacts[AppData.key(handle)] ?? handle)
        }
        for id in asked.map(String.init) {
            members[id] = (found[id] ?? []).sorted()
        }
    }

    /// The first file of each of these messages, where Messages keeps it on this Mac (`~/Library/Messages/Attachments`):
    /// a photo, a sticker, a GIF, a video or an audio message, shown as itself.
    private func attachments(_ rows: [[String: Any]]) async throws -> [Int64: ChatMedia] {
        let ids = rows.compactMap { NotificationRecord.integer($0["id"]) }
        guard !ids.isEmpty else { return [:] }
        let found: [[String: Any]]
        do {
            found = try await query("""
            SELECT maj.message_id AS id, a.filename AS file, a.mime_type AS type, a.transfer_name AS name,
                   COALESCE(a.is_sticker, 0) AS sticker, a.uti AS uti
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(ids.map(String.init).joined(separator: ","))) ORDER BY maj.attachment_id
            """)
        } catch where error.localizedDescription.contains("no such") {
            // An older Messages database without these columns: the messages still come, without their files.
            return [:]
        }
        var media: [Int64: ChatMedia] = [:]
        for row in found {
            guard let id = NotificationRecord.integer(row["id"]), media[id] == nil else { continue }
            var path = AppData.string(row["file"])
            if path.hasPrefix("~") { path = AppDatabase.home + path.dropFirst() }
            let name = AppData.string(row["name"])
            let uti = AppData.string(row["uti"])
            var kind = ChatMedia.kind(mimeType: AppData.string(row["type"]), name: name.isEmpty ? path : name,
                                      sticker: (AppData.number(row["sticker"]) ?? 0) != 0)
            // An audio message recorded in Messages is a .caf file.
            if kind == .audio, uti == "com.apple.coreaudio-format" { kind = .voice }
            media[id] = ChatMedia(kind: kind, name: name.isEmpty ? nil : name, path: path.isEmpty ? nil : path)
        }
        return media
    }

    private static let select = """
    SELECT m.ROWID AS id, cmj.chat_id AS chat, COALESCE(NULLIF(c.display_name, ''), c.chat_identifier, '') AS chatname,
           COALESCE(h.id, '') AS handle, m.is_from_me AS me, m.date AS date, m.text AS text, hex(m.attributedBody) AS body,
           CASE WHEN c.style = 43 THEN 1 ELSE 0 END AS grp, m.is_sent AS sent, m.is_delivered AS delivered,
           COALESCE(m.date_read, 0) AS readat, COALESCE(m.error, 0) AS error
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

// MARK: WhatsApp Desktop

/// WhatsApp from the WhatsApp app's own database on this Mac (`ChatStorage.sqlite`), read-only, for when no phone is
/// linked through a gateway: then the linked phone brings WhatsApp live and this bridge stays out of the way. Needs
/// Full Disk Access. The first read brings the newest chats with their history, after that only what is new, with
/// WhatsApp's own unread counts.
@MainActor
final class WhatsAppDesktopBridge: ChatBridge {
    let app = "whatsapp"
    let interval: TimeInterval = 5
    private(set) var isWorking = false

    private static let chats = 30
    private static let perChat = 30
    private static var path: String {
        AppDatabase.home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }

    private var lastRow: Int64?
    private var lastChange: Date?
    /// Every chat read so far by its row, with its name in Nook, for the unread counts.
    private var names: [String: String] = [:]
    /// Whether the group member table can be joined (it is not in every version of the app).
    private var members = true
    /// Whether the media table can be joined, for the photos, stickers, videos and voice messages the app keeps.
    private var mediaItems = true
    /// The group chats read so far, and their people (you left out) once asked.
    private var groups: Set<String> = []
    private var groupPeople: [String: [String]] = [:]
    /// Your own newest messages by row, with their chat: their ticks are read again each time, as they move.
    private var mine: [Int64: (chat: String, message: InboxMessage)] = [:]
    private static let tracked = 200
    /// Where the app keeps the files of its chats; a media item's path is relative to it.
    private static var mediaRoot: String {
        AppDatabase.home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/"
    }

    var isReady: Bool { !WhatsAppLink.shared.isConnected && FileManager.default.fileExists(atPath: Self.path) }

    func read() async throws -> [BridgedChat] {
        guard isReady else { isWorking = false; return [] }
        let change = [Self.path, Self.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
        if lastRow != nil, change != nil, change == lastChange { return [] }
        let contacts = await ContactDirectory.names()
        // Private chats (0) and groups (1); not broadcast lists or status updates.
        let kinds = "s.ZSESSIONTYPE IN (0, 1)"
        let rows: [[String: Any]]
        if let lastRow {
            rows = try await select("WHERE m.Z_PK > \(lastRow) AND \(kinds) ORDER BY m.Z_PK")
        } else {
            rows = try await select("""
            WHERE \(kinds) AND m.ZCHATSESSION IN (
                SELECT s.Z_PK FROM ZWACHATSESSION s WHERE \(kinds) ORDER BY s.ZLASTMESSAGEDATE DESC LIMIT \(Self.chats))
            """, window: Self.perChat)
        }
        var messages: [String: [InboxMessage]] = [:]
        var newest = lastRow ?? 0
        for row in rows {
            let id = NotificationRecord.integer(row["id"]) ?? 0
            newest = max(newest, id)
            let chat = AppData.string(row["chat"])
            let group = (AppData.number(row["kind"]) ?? 0) == 1
            var name = AppData.string(row["chatname"])
            if name.isEmpty { name = contacts[AppData.key(AppData.string(row["jid"]))] ?? WAJID.displayNumber(AppData.string(row["jid"])) }
            names[chat] = name
            let mine = (AppData.number(row["me"]) ?? 0) != 0
            var text = AppData.string(row["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let media = Self.media(row)
            if text.isEmpty, media == nil { text = Self.label(Int(AppData.number(row["type"]) ?? 0)) }
            guard !text.isEmpty || media != nil else { continue }
            var sender = ""
            if group {
                groups.insert(chat)
                if !mine {
                    sender = AppData.string(row["sender"])
                    if sender.isEmpty { sender = contacts[AppData.key(AppData.string(row["member"]))] ?? "" }
                }
            }
            var message = InboxMessage(
                id: "wadesktop-\(id)", sender: sender, text: text,
                date: AppData.appleDate(AppData.number(row["date"]) ?? 0), fromMe: mine, media: media)
            if mine {
                message.receipt = ChatReceipts.whatsAppDesktop(status: Int(AppData.number(row["status"]) ?? 0))
                self.mine[id] = (chat, message)
            }
            messages[chat, default: []].append(message)
        }
        if self.mine.count > Self.tracked {
            for id in self.mine.keys.sorted().dropLast(Self.tracked) { self.mine[id] = nil }
        }
        // Your earlier messages whose ticks moved since (delivered, read): the chat shows them now.
        let fresh = Set(rows.compactMap { NotificationRecord.integer($0["id"]) })
        let earlier = self.mine.keys.filter { !fresh.contains($0) }
        if !earlier.isEmpty {
            for row in try await query("""
            SELECT Z_PK AS id, COALESCE(ZMESSAGESTATUS, 0) AS status FROM ZWAMESSAGE
            WHERE Z_PK IN (\(earlier.sorted().map(String.init).joined(separator: ",")))
            """) {
                guard let id = NotificationRecord.integer(row["id"]), var known = self.mine[id],
                      let receipt = ChatReceipts.whatsAppDesktop(status: Int(AppData.number(row["status"]) ?? 0)),
                      receipt != known.message.receipt else { continue }
                known.message.receipt = receipt
                self.mine[id] = known
                messages[known.chat, default: []].append(known.message)
            }
        }
        await loadPeople(contacts: contacts)
        let known = names.keys.compactMap(Int.init).map(String.init).joined(separator: ",")
        var unread: [String: Int] = [:]
        if !known.isEmpty {
            for row in try await query("SELECT Z_PK AS chat, ZUNREADCOUNT AS unread FROM ZWACHATSESSION WHERE Z_PK IN (\(known))") {
                unread[AppData.string(row["chat"])] = max(0, Int(AppData.number(row["unread"]) ?? 0))
            }
        }
        lastRow = newest
        lastChange = change
        isWorking = true
        return names.map { chat, name in
            let people = groupPeople[chat] ?? []
            return BridgedChat(app: app, name: name, messages: (messages[chat] ?? []).sorted { $0.date < $1.date },
                               unread: unread[chat] ?? 0, members: people.isEmpty ? nil : people)
        }
    }

    /// The people of the group chats not asked yet (`ZWAGROUPMEMBER`, the ones still in it), by their name in WhatsApp,
    /// else in Contacts, else their number. Without that table (an older app) groups list nobody.
    private func loadPeople(contacts: [String: String]) async {
        let asked = groups.filter { groupPeople[$0] == nil }.compactMap(Int.init)
        guard members, !asked.isEmpty else { return }
        let rows: [[String: Any]]
        do {
            rows = try await query("""
            SELECT ZCHATSESSION AS chat, COALESCE(ZCONTACTNAME, '') AS name, COALESCE(ZMEMBERJID, '') AS jid
            FROM ZWAGROUPMEMBER WHERE ZCHATSESSION IN (\(asked.sorted().map(String.init).joined(separator: ","))) AND COALESCE(ZISACTIVE, 1) = 1
            """)
        } catch {
            for id in asked.map(String.init) { groupPeople[id] = [] }
            return
        }
        var found: [String: Set<String>] = [:]
        for row in rows {
            let jid = AppData.string(row["jid"])
            var name = AppData.string(row["name"])
            if name.isEmpty { name = contacts[AppData.key(jid)] ?? WAJID.displayNumber(jid) }
            guard !name.isEmpty else { continue }
            found[AppData.string(row["chat"]), default: []].insert(name)
        }
        for id in asked.map(String.init) { groupPeople[id] = (found[id] ?? []).sorted() }
    }

    /// The file of a photo, video, voice message, sticker or document, where the app keeps it on this Mac.
    private static func media(_ row: [String: Any]) -> ChatMedia? {
        let file = AppData.string(row["file"])
        guard !file.isEmpty, !file.contains("..") else { return nil }
        let type = Int(AppData.number(row["type"]) ?? 0)
        guard [1, 2, 3, 8, 15].contains(type) else { return nil }
        var kind = ChatMedia.kind(mimeType: nil, name: file, sticker: type == 15, voice: type == 3)
        if type == 8 { kind = .file }
        let title = AppData.string(row["title"])
        let seconds = AppData.number(row["seconds"]) ?? 0
        return ChatMedia(kind: kind, name: type == 8 && !title.isEmpty ? title : nil, path: mediaRoot + file,
                         seconds: seconds > 0 ? seconds : nil)
    }

    /// The messages with their chat; `window` keeps only the newest of each chat. Without the group member table (or
    /// the media table) the same query runs again without the senders' names (or the files).
    private func select(_ filter: String, window: Int? = nil) async throws -> [[String: Any]] {
        func sql(_ members: Bool, _ media: Bool) -> String {
            let base = """
            SELECT m.Z_PK AS id, m.ZCHATSESSION AS chat, COALESCE(s.ZPARTNERNAME, '') AS chatname,
                   COALESCE(s.ZCONTACTJID, '') AS jid, s.ZSESSIONTYPE AS kind, m.ZISFROMME AS me, m.ZMESSAGEDATE AS date,
                   m.ZTEXT AS text, m.ZMESSAGETYPE AS type, COALESCE(m.ZMESSAGESTATUS, 0) AS status,
                   \(members ? "COALESCE(g.ZCONTACTNAME, '') AS sender, COALESCE(g.ZMEMBERJID, '') AS member" : "'' AS sender, '' AS member"),
                   \(media ? "COALESCE(mi.ZMEDIALOCALPATH, '') AS file, COALESCE(mi.ZMOVIEDURATION, 0) AS seconds, COALESCE(mi.ZTITLE, '') AS title" : "'' AS file, 0 AS seconds, '' AS title")
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            \(members ? "LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER" : "")
            \(media ? "LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM" : "")
            \(filter)
            """
            guard let window else { return base }
            return "SELECT * FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.chat ORDER BY x.date DESC) AS position FROM (\(base)) x) WHERE position <= \(window)"
        }
        if mediaItems {
            do {
                return try await query(sql(members, true))
            } catch where error.localizedDescription.contains("no such") {
                mediaItems = false
            }
        }
        if members {
            do {
                return try await query(sql(true, false))
            } catch where error.localizedDescription.contains("no such") {
                members = false
            }
        }
        return try await query(sql(false, false))
    }

    /// What a message without text holds, by WhatsApp's message type.
    private static func label(_ type: Int) -> String {
        switch type {
        case 1: return tr("whatsapp.file.photo")
        case 2: return tr("whatsapp.file.video")
        case 3: return tr("whatsapp.file.voice")
        case 8: return tr("whatsapp.file.document")
        case 15: return "🙂"
        case 5: return "📍"
        case 4: return "👤"
        default: return ""
        }
    }

    private func query(_ sql: String) async throws -> [[String: Any]] {
        do {
            return try await AppDatabase.query(Self.path, sql, app: "WhatsApp")
        } catch {
            isWorking = false
            throw error
        }
    }
}

// MARK: Beeper

/// Every network linked in Beeper Desktop (Instagram, Messenger, Discord, Signal, LinkedIn, X, Google Chat…), each chat
/// under its own app, through Beeper's own local API on this Mac (Settings › Developers in Beeper) with the token set in
/// Settings › Chats. Nothing leaves the Mac: the API is Beeper's, on localhost. A network Nook reads with a bridge of
/// its own (Telegram, Slack…) is left to that bridge. While Beeper is the WhatsApp gateway, its chats already come in
/// through the linked phone list (with answering in place), so this bridge stays out of the way.
@MainActor
final class BeeperBridge: ChatBridge {
    let app = "beeper"
    let interval: TimeInterval = 10
    private(set) var isWorking = false
    /// The apps whose chats it brought in: their notifications only repeat it.
    private(set) var covered: Set<String> = []
    /// An app another bridge already reads.
    var skips: (String) -> Bool = { _ in false }

    static let tokenAccount = "chats.beeper.token"
    private static let base = URL(string: "http://localhost:23373")!
    private static let chatCount = 40
    private static let history = 30

    /// The newest activity per chat at the last read: only chats that moved are read again.
    private var seen: [String: Date] = [:]
    /// Files Beeper downloaded for Nook, by their `mxc://` address.
    private var downloaded: [String: String] = [:]
    /// Beeper's id of every chat it brought in, by its app and its name in Nook: where what you send from Nook goes.
    private var chatIDs: [String: String] = [:]

    static var token: String? { CloudHelp.secret(tokenAccount) }

    var isReady: Bool {
        !(WhatsAppSettings.enabled && WhatsAppSettings.gateway == .beeper) && Self.token != nil
    }

    func reset() {
        seen = [:]
        covered = []
        isWorking = false
    }

    func read() async throws -> [BridgedChat] {
        guard isReady, let token = Self.token else { isWorking = false; return [] }
        do {
            let chats = BeeperData.chats(try await get("/v1/chats", ["limit": String(Self.chatCount)], token: token))
                .filter { !skips($0.app) }
            var result: [BridgedChat] = []
            for chat in chats where chat.last.map({ seen[chat.id] != $0 }) ?? (seen[chat.id] == nil) {
                let path = "/v1/chats/" + (chat.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? chat.id) + "/messages"
                let history = BeeperData.messages(try await get(path, ["limit": String(Self.history)], token: token), chat: chat)
                let messages = await withFiles(history, token: token)
                seen[chat.id] = chat.last ?? .distantPast
                covered.insert(chat.app)
                chatIDs[chat.app + "|" + chat.title] = chat.id
                guard !messages.isEmpty else { continue }
                let picture = await local(chat.picture, token: token)
                result.append(BridgedChat(app: chat.app, name: chat.title, messages: messages, unread: chat.unread, avatar: picture,
                                          members: chat.members.isEmpty ? nil : chat.members))
            }
            isWorking = true
            return result
        } catch {
            isWorking = false
            throw error
        }
    }

    /// The messages with their files on this Mac (see `local`).
    private func withFiles(_ messages: [InboxMessage], token: String) async -> [InboxMessage] {
        var result = messages
        for index in result.indices {
            guard var media = result[index].media, media.path == nil, let path = await local(media.source, token: token) else { continue }
            media.path = path
            result[index].media = media
        }
        return result
    }

    /// Where a file Beeper names is on this Mac: a `file://` one as it is, an `mxc://` one once Beeper downloaded it
    /// through its own API (it says where it put it). Nothing is fetched from anywhere but Beeper on this Mac.
    private func local(_ source: String?, token: String) async -> String? {
        guard let source else { return nil }
        if let url = URL(string: source), url.isFileURL { return url.path }
        guard source.hasPrefix("mxc://") || source.hasPrefix("localmxc://") else { return nil }
        if let known = downloaded[source], FileManager.default.fileExists(atPath: known) { return known }
        var request = URLRequest(url: Self.base.appendingPathComponent("v1/assets/download"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": source])
        guard let answer = try? await ConnectorHTTP.session.data(for: request),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200,
              let local = (BeeperData.object(answer.0)?["srcURL"] as? String).flatMap({ URL(string: $0) }), local.isFileURL else { return nil }
        downloaded[source] = local.path
        return local.path
    }

    // MARK: Sending

    /// Beeper's id of the chat Nook shows as `name` in `app`, once Beeper brought it in.
    func chatID(app: String, name: String) -> String? {
        isReady ? chatIDs[app + "|" + name] : nil
    }

    /// What every network Beeper bridges can take from Nook: text and files; a place or a contact goes as text.
    var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.noPolls }

    /// Sends what you typed, or a file, a place or a contact card, to a chat Beeper brought in (Instagram, Signal,
    /// Messenger…), as an answer to `replyTo` (a message's id in Nook) when set. Beeper hands it to the network; the
    /// chat shows it at Beeper's next read. Throws with a sentence you can act on.
    func send(text: String? = nil, _ outgoing: ChatOutgoing? = nil, to chat: String, replyTo: String? = nil) async throws {
        guard let token = Self.token else { throw NookError(tr("chats.beeper.unauthorized")) }
        let messages = "/v1/chats/" + (chat.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? chat) + "/messages"
        let prefix = "beeper-\(chat)-"
        let answered = replyTo.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        var request: WASendRequest
        if let outgoing {
            if case .poll = outgoing { throw NookError(tr("chat.compose.unsupported")) }
            var uploadID: String?
            if case .file(let file) = outgoing {
                guard !file.tooLarge, let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
                    throw NookError(tr("chat.compose.tooLarge", file.name))
                }
                let upload = WASend.beeperUpload(file, data: data)
                guard let id = WASend.beeperUploadID(try await post(upload.path, upload.json ?? [:], token: token, timeout: 120)) else {
                    throw NookError(tr("chat.compose.notSent"))
                }
                uploadID = id
            }
            request = WASend.beeperMessage(outgoing, path: messages, uploadID: uploadID, replyTo: answered)
        } else {
            let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
            request = WASendRequest(path: messages, json: ["text": body])
            if let answered { request.json?["replyToMessageID"] = answered }
        }
        _ = try await post(request.path, request.json ?? [:], token: token, timeout: 30)
        // The chat is read again at the next turn, with the message just sent.
        seen[chat] = nil
    }

    private func post(_ path: String, _ json: [String: any Sendable], token: String, timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        guard let url = components.url else { throw NookError("Beeper: \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ConnectorHTTP.session.data(for: request)
        } catch {
            throw NookError(tr("chats.beeper.unreachable"))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw NookError(tr("chats.beeper.unauthorized")) }
        guard (200..<300).contains(code) else {
            throw NookError(tr("chat.compose.notSent") + " " + (WABeeper.errorMessage(data) ?? "HTTP \(code)"))
        }
        return data
    }

    private func get(_ path: String, _ parameters: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NookError("Beeper: \(path)") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ConnectorHTTP.session.data(for: request)
        } catch {
            throw NookError(tr("chats.beeper.unreachable"))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw NookError(tr("chats.beeper.unauthorized")) }
        guard (200..<300).contains(code), let json = BeeperData.object(data) else { throw NookError("Beeper: HTTP \(code)") }
        return json
    }
}

// MARK: Slack

/// Your Slack direct messages and group messages, with their history, through Slack's Web API and a user token you set
/// in Settings › Chats (kept in the Keychain). Read-only scopes are enough: im:history, mpim:history, im:read,
/// mpim:read, users:read and files:read (for the photos, GIFs and voice clips in them). Only Slack is asked, and only
/// for your own conversations.
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
    /// Each person's profile picture address, and where it is on this Mac once fetched.
    private var avatars: [String: String] = [:]
    private var avatarFiles: [String: String] = [:]
    private var usersAt: Date?
    private var conversations: [SlackData.Conversation] = []
    private var conversationsAt: Date?
    /// The newest message read per conversation (Slack's `ts`), to ask only for what is newer.
    private var newest: [String: String] = [:]
    /// The latest activity seen per conversation, to read the busiest first.
    private var active: [String: Double] = [:]
    /// The people of each group conversation, by name, asked once.
    private var people: [String: [String]] = [:]
    private var turn = 0

    var isReady: Bool { Self.token != nil }

    /// Forgets what was read (a new token may be another workspace).
    func reset() {
        me = nil
        users = [:]
        avatars = [:]
        avatarFiles = [:]
        usersAt = nil
        conversations = []
        conversationsAt = nil
        newest = [:]
        active = [:]
        people = [:]
        isWorking = false
    }

    func read() async throws -> [BridgedChat] {
        guard let token = Self.token else { isWorking = false; return [] }
        do {
            if me == nil { me = SlackData.me(try await call("auth.test", [:], token: token)) }
            if usersAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                let members = try await pages("users.list", ["limit": "200"], token: token, maxPages: 5)
                users = members.reduce(into: [:]) { $0.merge(SlackData.users($1)) { a, _ in a } }
                avatars = members.reduce(into: [:]) { $0.merge(SlackData.avatars($1)) { a, _ in a } }
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
                let read = SlackData.messages(json, conversation: conversation, users: users, me: me)
                let messages = await withFiles(read, token: token)
                if let last = (json["messages"] as? [[String: Any]])?.compactMap({ $0["ts"] as? String })
                    .max(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }) {
                    newest[conversation.id] = last
                    active[conversation.id] = max(active[conversation.id] ?? 0, Double(last) ?? 0)
                } else if newest[conversation.id] == nil {
                    newest[conversation.id] = "0"
                }
                guard !messages.isEmpty else { continue }
                let picture = await avatar(of: conversation.user)
                if conversation.isGroup, people[conversation.id] == nil {
                    // One refused list (a missing scope) leaves the group without its people, not without its messages.
                    let json = try? await call("conversations.members", ["channel": conversation.id, "limit": "200"], token: token)
                    people[conversation.id] = json.map { SlackData.members($0, users: users, me: me) } ?? []
                }
                let members = people[conversation.id] ?? []
                chats.append(BridgedChat(app: app, name: SlackData.chatName(conversation, users: users, me: me),
                                         messages: messages, unread: nil, avatar: picture, members: members.isEmpty ? nil : members))
            }
            isWorking = true
            return chats
        } catch {
            isWorking = false
            throw error
        }
    }

    /// A direct message's picture: the other person's profile photo, fetched once (a public address, no token sent).
    private func avatar(of user: String?) async -> String? {
        guard let user else { return nil }
        if let file = avatarFiles[user], FileManager.default.fileExists(atPath: file) { return file }
        guard let address = avatars[user], let url = URL(string: address), url.scheme == "https",
              let answer = try? await ConnectorHTTP.session.data(from: url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200, answer.0.count < 2_000_000 else { return nil }
        let target = ChatMedia.destination(key: "slack-avatar-" + user, name: "avatar." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? answer.0.write(to: target, options: .atomic)) != nil else { return nil }
        avatarFiles[user] = target.path
        return target.path
    }

    /// The messages with their files fetched from Slack (with the token, only from Slack's own addresses), so a photo,
    /// GIF or voice clip shows as itself. One that cannot be fetched (the token lacks files:read) stays a file to open
    /// in Slack.
    private func withFiles(_ messages: [InboxMessage], token: String) async -> [InboxMessage] {
        var result = messages
        for index in result.indices {
            guard var media = result[index].media, media.path == nil, let source = media.source,
                  let url = URL(string: source), SlackData.isSlack(url) else { continue }
            let target = ChatMedia.destination(key: result[index].id, name: media.name ?? url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                var request = URLRequest(url: url)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                guard let answer = try? await ConnectorHTTP.session.data(for: request),
                      let response = answer.1 as? HTTPURLResponse, response.statusCode == 200,
                      answer.0.count <= ChatMedia.maxBytes,
                      // Without the right scope Slack answers with its sign-in page instead of the file.
                      !(response.mimeType ?? "").contains("html") else { continue }
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? answer.0.write(to: target, options: .atomic)) != nil else { continue }
            }
            media.path = target.path
            result[index].media = media
        }
        return result
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
