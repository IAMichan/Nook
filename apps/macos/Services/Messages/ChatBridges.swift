import Foundation

/// A chat app Nook reads itself, history included, instead of waiting for its notifications: Messages from its database
/// on this Mac, Slack through its Web API with your token. What a bridge reads lands in the same `ChatInbox` as the
/// collected notifications (`ChatCaptureService` runs them), so a chat is one chat however it came in. Where the app
/// lets Nook, a bridge also writes in its chats: what each one can do is listed in `AppModel.chatAbilities`.
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
    /// What the capture service keeps its turns, reads and failures under: the app's id, unless two bridges read one
    /// app (WhatsApp on this Mac and WhatsApp through the linked phone), which then each have their own.
    var bridgeID: String { get }
    /// Reads also while collecting chats (Settings › Chats) is off: an app switched on on its own (WhatsApp through the
    /// linked phone, which has its own switch and needs no Full Disk Access).
    var alwaysOn: Bool { get }
    /// Reads a database on this Mac, not a service: a read that failed for a passing reason is tried again within
    /// seconds (`ChatBackoff`), not after a minute.
    var readsLocally: Bool { get }
}

extension ChatBridge {
    var bridgeID: String { app }
    var alwaysOn: Bool { false }
    var readsLocally: Bool { false }
}

/// A bridge that scrolls back in a chat, as far as its app keeps the history: the batch of messages older than the
/// oldest one Nook shows, each time you reach the top. No cap: every batch goes further back, until the chat's start.
@MainActor
protocol ChatHistoryBridge: ChatBridge {
    /// Whether the chat Nook shows as `name` is one this bridge read, so it can ask for older messages.
    func canLoadOlder(name: String) -> Bool
    /// The batch of messages of the chat `name` sent before `before` (the oldest one Nook shows, with its id in Nook
    /// when it came from this bridge), as a chat to merge, and whether the app has more before those.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool)
}

/// A bridge whose chats its app knows by an id (`BridgedChat.chatID`), scrolling back in them by that id: WhatsApp
/// through the linked phone, whose gateway brings each older batch.
@MainActor
protocol ChatKeyedHistoryBridge: ChatBridge {
    /// Whether the chat with this id may have older messages in its app.
    func canLoadOlder(chatID: String) -> Bool
    /// The chat with its older messages, to merge, and whether the app has more before those.
    func older(chatID: String) async throws -> (chat: BridgedChat?, hasMore: Bool)
}

/// A bridge whose app says itself which chats got news (WhatsApp's linked phone, which knows what came in live and what
/// is a catch-up or history): those are told, instead of what the inbox makes of the read.
@MainActor
protocol ChatNewsBridge: ChatBridge {
    /// The chats (their ids in `ChatInbox`) with news since the last time, once.
    func takeNews() -> [String]
}

/// A bridge that searches its app's whole history, not only the newest messages the shared inbox keeps per chat
/// (`ChatInbox.keep`): Search everything (⌘K) asks every one of them, so a message from last month in a busy group is
/// found there as Nook's own `search_*` tools find it. One family, one shape: each app only translates its own search
/// into chats with their matching messages (`ChatHistorySearch`).
@MainActor
protocol ChatSearchBridge: ChatBridge, Sendable {
    /// Whether its app can be searched right now (signed in, its database there).
    var searchesHistory: Bool { get }
    /// The chats with messages that hold any of `words` (folded: lowercase, no accents), the newest `limit` per word,
    /// each chat as the bridge reads it (`BridgedChat`), so the inbox key and the message ids are the ones the Chats tab
    /// shows. Search everything decides which of them hold every word, over the whole chat.
    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat]
}

/// How many older messages one scroll back brings, for every bridge.
enum ChatHistory {
    static let step = 50
}

// MARK: Messages

/// iMessage and sms from Messages' own database (`~/Library/Messages/chat.db`), only on this Mac. Needs Full Disk
/// Access, as collecting notifications does. The first read brings the newest chats with their history, their answers
/// and tapbacks; after that only the messages and tapbacks that came in since, and every chat's unread count as Messages
/// keeps it. Sending goes through the Messages app itself (AppleScript, with your permission under Automation): text,
/// files, and a place or a contact as text. Messages lets no other app answer, react, edit or delete.
@MainActor
final class MessagesBridge: ChatHistoryBridge, ChatSearchBridge {
    let app = "messages"
    /// Often: a read first looks only at when the database changed, which costs nothing while it did not.
    let interval: TimeInterval = 2
    let readsLocally = true
    private(set) var isWorking = false
    /// What goes besides text: every file as itself (a sticker as its picture, a voice message as an audio file), a
    /// place or a contact as text. Messages has no polls another app can send.
    let sends = ChatOutgoing.Kind.noPolls

    /// Chats and messages per chat on the first read.
    private static let chats = 30
    private static let perChat = 30
    /// Only the newest messages are looked at: the database keeps the whole history and an old Mac has a lot of it.
    private static let window = 20_000

    private var path: String { AppDatabase.home + "/Library/Messages/chat.db" }
    private var lastRow: Int64?
    private var lastChange: Date?
    /// A query of the read going on found the database locked and read it without its write-ahead log
    /// (`AppDatabase.read`): the next turn reads again, also when the database did not change since.
    private var partial = false
    /// Every chat read so far by its id in the database, with its name in Nook, for the unread counts.
    private var names: [String: String] = [:]
    /// The group chats among them, and their people (you left out) once asked, as Messages lists them.
    private var groups: Set<String> = []
    private var members: [String: [String]] = [:]
    /// Your own newest messages by row, with their chat: their ticks are read again each time, as they move.
    private var mine: [Int64: (chat: String, message: InboxMessage)] = [:]
    private static let tracked = 200
    /// Every chat's own id in Messages (`chat.guid`, "iMessage;-;+31…") by its id in the database, to send to it, and
    /// when it last had a message, so a person with an iMessage and an sms chat gets the newest one.
    private var guids: [String: String] = [:]
    private var active: [String: Date] = [:]
    /// The newest messages read so far by their guid in Messages, with their row and chat: a tapback that comes in
    /// later shows on them.
    private var seen: [String: (row: Int64, chat: String, message: InboxMessage)] = [:]
    private static let remembered = 1_000
    /// The newest row looked at for tapbacks on messages read earlier.
    private var lastTapback: Int64?
    /// Whether the database has `associated_message_emoji` (a tapback with any emoji); an older one does not.
    private var customTapbacks = true
    /// The newest edit or unsend looked at, on Messages' own clock, and whether the database keeps them at all
    /// (`date_edited`, `date_retracted`: a database from before messages could be edited does not).
    private var lastEdit: Int64?
    private var keepsEdits = true

    var isReady: Bool { FileManager.default.fileExists(atPath: path) }

    func canLoadOlder(name: String) -> Bool { isReady && !chatIDs(name).isEmpty }

    /// Every chat of Messages in the inbox: the chat's own id in Messages is looked up when you send, if Nook did not
    /// read it since it started (`resolve`).
    func canSend(name: String) -> Bool { isReady }

    /// Messages' own ids of the chats of `name`, the one with the newest message first.
    private func chatGUIDs(_ name: String) -> [String] {
        chatIDs(name).map(String.init)
            .sorted { (active[$0] ?? .distantPast) > (active[$1] ?? .distantPast) }
            .compactMap { guids[$0] }
    }

    /// The chats of `name` in the database: an iMessage and an sms conversation with one person are one chat in Nook.
    private func chatIDs(_ name: String) -> [Int] {
        let key = ChatInbox.key(app: app, chat: name)
        return names.filter { ChatInbox.key(app: app, chat: $0.value) == key }.keys.compactMap(Int.init)
    }

    /// Scrolling back: the database keeps the whole history, so every batch goes further back, past the window the
    /// live reads look at.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        let ids = chatIDs(name)
        guard !ids.isEmpty else { return (nil, false) }
        let contacts = await ContactDirectory.names()
        // Messages counts in nanoseconds since 2001, an older database in seconds (as `AppData.appleDate` reads it).
        let limit = Int64(before.timeIntervalSinceReferenceDate * 1_000_000_000)
        let rows = try await query(Self.select + """
         WHERE cmj.chat_id IN (\(ids.sorted().map(String.init).joined(separator: ",")))
            AND COALESCE(m.associated_message_type, 0) = 0
            AND (CASE WHEN m.date > 100000000000 THEN m.date ELSE m.date * 1000000000 END) < \(limit)
         ORDER BY m.date DESC LIMIT \(ChatHistory.step + 1)
        """)
        let batch = Array(rows.prefix(ChatHistory.step))
        let files = try await attachments(batch)
        let extra = try await extras(batch, contacts: contacts)
        var messages: [InboxMessage] = []
        for row in batch {
            let id = NotificationRecord.integer(row["id"]) ?? 0
            guard let built = build(row, media: files[id], extras: extra, contacts: contacts) else { continue }
            remember(row, chat: built.message.chat, message: built.inbox)
            messages.append(built.inbox)
        }
        trimSeen()
        let more = rows.count > ChatHistory.step
        // A batch of nothing to show (only empty rows) is not the start: the next one goes on from its oldest row.
        if messages.isEmpty, more, let oldest = batch.last.map({ AppData.appleDate(AppData.number($0["date"]) ?? 0) }), oldest < before {
            return try await older(name: name, before: oldest, oldestID: nil)
        }
        let chat = messages.isEmpty ? nil : BridgedChat(app: app, name: name, messages: messages.sorted { $0.date < $1.date }, unread: nil)
        return (chat, more)
    }

    // MARK: Search everything

    var searchesHistory: Bool { isReady }

    /// The whole database, past the window the live reads look at: the text, and the body newer Messages keeps it in,
    /// as `search_messages` reads it. Read on the side: nothing the live reads keep changes.
    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard isReady, !words.isEmpty else { return [] }
        let contacts = await ContactDirectory.names()
        var found: [(chat: BridgedChat, messages: [InboxMessage])] = []
        for word in words {
            let rows = try await AppDatabase.read(path, Self.select + """
             WHERE COALESCE(m.associated_message_type, 0) = 0
                AND \(AppData.anyLike(["m.text", "CAST(m.attributedBody AS TEXT)"], [word]))
             ORDER BY m.date DESC LIMIT \(limit)
            """, app: "Messages").rows
            guard !rows.isEmpty else { continue }
            let unnamed = try await groupNames(rows, contacts: contacts)
            let extra = try await extras(rows, contacts: contacts)
            for row in rows {
                guard let built = build(row, media: nil, extras: extra, contacts: contacts),
                      ChatHistorySearch.matches(built.inbox, [word]) else { continue }
                let chat = built.message.chat
                let name = names[chat] ?? unnamed[chat] ?? built.message.chatName
                found.append((BridgedChat(app: app, name: name, messages: [], unread: nil), [built.inbox]))
            }
        }
        return ChatHistorySearch.chats(found)
    }

    func read() async throws -> [BridgedChat] {
        let change = [path, path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
        if lastRow != nil, change != nil, change == lastChange { return [] }
        partial = false
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
        let (retapped, tapbackCursor) = try await tapped()
        let (changedRows, unsent, editCursor) = try await changed(since: recent)
        let unnamed = try await groupNames(rows, contacts: contacts)
        let files = try await attachments(rows)
        let extra = try await extras(rows, contacts: contacts)
        for row in rows {
            let id = NotificationRecord.integer(row["id"]) ?? 0
            newest = max(newest, id)
            guard let built = build(row, media: files[id], extras: extra, contacts: contacts) else { continue }
            let message = built.message
            let inbox = built.inbox
            let chat = message.chat
            names[chat] = unnamed[chat] ?? names[chat] ?? message.chatName
            if (AppData.number(row["grp"]) ?? 0) != 0 { groups.insert(chat) }
            active[chat] = max(active[chat] ?? .distantPast, message.date)
            remember(row, chat: chat, message: inbox)
            if message.fromMe {
                // Only its ticks are brought again from here: its tapbacks come with `tapped()`.
                var tracked = inbox
                tracked.reactions = nil
                mine[id] = (chat, tracked)
            }
            messages[chat, default: []].append(inbox)
        }
        if mine.count > Self.tracked {
            for id in mine.keys.sorted().dropLast(Self.tracked) { mine[id] = nil }
        }
        // Tapbacks put on (or taken off) messages read earlier: the chat shows their emoji now.
        let others = retapped.subtracting(rows.map { AppData.string($0["guid"]) })
        if !others.isEmpty {
            let first = others.compactMap { seen[$0]?.row }.min() ?? 0
            let updated = try await reactions(on: others, after: first)
            for guid in others.sorted() {
                guard var known = seen[guid] else { continue }
                known.message.reactions = updated[guid] ?? []
                seen[guid] = known
                messages[known.chat, default: []].append(known.message)
            }
        }
        // Messages read earlier that were edited since (their new text) or unsent ("Undo Send"): the chat shows the new
        // text, or drops the message, as for every app (`BridgedChat.deleted`).
        var dropped: [String: [String]] = [:]
        let readNow = Set(rows.compactMap { NotificationRecord.integer($0["id"]) })
        let edited = changedRows.filter { row in
            NotificationRecord.integer(row["id"]).map { !readNow.contains($0) } ?? false
        }
        if !edited.isEmpty {
            let changedFiles = try await attachments(edited)
            let changedExtras = try await extras(edited, contacts: contacts)
            for row in edited {
                guard let id = NotificationRecord.integer(row["id"]) else { continue }
                let chat = AppData.string(row["chat"])
                guard names[chat] != nil else { continue }
                if unsent.contains(id) {
                    dropped[chat, default: []].append("imessage-\(id)")
                    mine[id] = nil
                    seen[AppData.string(row["guid"])] = nil
                    continue
                }
                guard let built = build(row, media: changedFiles[id], extras: changedExtras, contacts: contacts) else { continue }
                remember(row, chat: chat, message: built.inbox)
                if built.message.fromMe, mine[id] != nil {
                    var tracked = built.inbox
                    tracked.reactions = nil
                    mine[id] = (chat, tracked)
                }
                messages[chat, default: []].append(built.inbox)
            }
        }
        trimSeen()
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
                known.message.readers = Self.readers(row)
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

        // Both cursors move only now that the whole read worked: a query that fails halfway (a locked database) reads
        // the same messages and tapbacks again next time, instead of losing them.
        lastRow = newest
        lastTapback = tapbackCursor
        if let editCursor { lastEdit = editCursor }
        // A read without the write-ahead log may have missed the newest message: the next turn reads again.
        lastChange = partial ? nil : change
        isWorking = true
        // An iMessage and an sms conversation with the same person are one chat in Nook, with both their counts.
        var chats: [String: BridgedChat] = [:]
        for (chat, name) in names {
            var merged = chats[name] ?? BridgedChat(app: app, name: name, messages: [], unread: 0)
            merged.messages += messages[chat] ?? []
            merged.deleted += dropped[chat] ?? []
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

    /// One row as a message in Nook, with its file, the message it answers and its tapbacks; nil for a row with nothing
    /// to show. A photo without a caption has no text to read: it is read as one with a placeholder, then left without.
    private func build(_ row: [String: Any], media: ChatMedia?, extras: Extras,
                       contacts: [String: String]) -> (message: AppData.Message, inbox: InboxMessage)? {
        var readable = row
        if media != nil, AppData.messages([row], names: contacts).isEmpty { readable["text"] = Self.placeholder }
        guard let message = AppData.messages([readable], names: contacts).first else { return nil }
        let id = NotificationRecord.integer(row["id"]) ?? 0
        let group = (AppData.number(row["grp"]) ?? 0) != 0
        var inbox = InboxMessage(
            id: "imessage-\(id)", sender: message.fromMe || !group ? "" : message.sender,
            text: message.text == Self.placeholder ? "" : message.text, date: message.date, fromMe: message.fromMe, media: media)
        if message.fromMe {
            inbox.receipt = Self.receipt(row)
            inbox.readers = Self.readers(row)
        }
        inbox.reactions = extras.reactions[AppData.string(row["guid"])]
        let origin = AppData.string(row["origin"])
        if !origin.isEmpty, origin != AppData.string(row["guid"]) { inbox.quote = extras.quotes[origin] }
        return (message, inbox)
    }

    /// A message read, by its guid, for the tapbacks that come in later, and its chat's own id in Messages, to send to.
    private func remember(_ row: [String: Any], chat: String, message: InboxMessage) {
        let chatGUID = AppData.string(row["chatguid"])
        if !chatGUID.isEmpty { guids[chat] = chatGUID }
        let guid = AppData.string(row["guid"])
        guard !guid.isEmpty, let id = NotificationRecord.integer(row["id"]) else { return }
        seen[guid] = (id, chat, message)
    }

    /// Only the newest messages read are kept for their tapbacks.
    private func trimSeen() {
        guard seen.count > Self.remembered else { return }
        for (guid, _) in seen.sorted(by: { $0.value.row < $1.value.row }).prefix(seen.count - Self.remembered) { seen[guid] = nil }
    }

    /// What the messages of some rows answer (by the answered message's guid) and the emoji on them (by their own guid).
    private struct Extras {
        var quotes: [String: InboxQuote] = [:]
        var reactions: [String: [InboxReaction]] = [:]
    }

    private func extras(_ rows: [[String: Any]], contacts: [String: String]) async throws -> Extras {
        guard !rows.isEmpty else { return Extras() }
        let own = Set(rows.map { AppData.string($0["guid"]) }.filter { !$0.isEmpty })
        let first = rows.compactMap { NotificationRecord.integer($0["id"]) }.min() ?? 0
        let origins = Set(rows.map { AppData.string($0["origin"]) }.filter { !$0.isEmpty })
        let emoji = try await reactions(on: own, after: first)
        let answered = try await quotes(origins, contacts: contacts)
        return Extras(quotes: answered, reactions: emoji)
    }

    /// The messages these answer, by their guid: their id in Nook, so the chat shows the one it has, with who wrote it
    /// and its text for when Nook does not have it.
    private func quotes(_ guids: Set<String>, contacts: [String: String]) async throws -> [String: InboxQuote] {
        guard !guids.isEmpty else { return [:] }
        let rows = try await query("""
        SELECT m.ROWID AS id, m.guid AS guid, m.is_from_me AS me, COALESCE(h.id, '') AS handle, m.date AS date,
               m.text AS text, hex(m.attributedBody) AS body
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.guid IN (\(guids.sorted().map(AppData.literal).joined(separator: ",")))
        """)
        var quotes: [String: InboxQuote] = [:]
        for row in rows {
            guard let id = NotificationRecord.integer(row["id"]) else { continue }
            let mine = (AppData.number(row["me"]) ?? 0) != 0
            let handle = AppData.cleanHandle(AppData.string(row["handle"]))
            quotes[AppData.string(row["guid"])] = InboxQuote(
                id: "imessage-\(id)", sender: mine ? "" : (contacts[AppData.key(handle)] ?? handle),
                text: AppData.messages([row], names: contacts).first?.text ?? "", mine: mine)
        }
        return quotes
    }

    /// The emoji on the messages `guids`, from all their tapbacks (each comes after its message, so after row `first`).
    /// Every message with a tapback is in the answer, with no emoji when all were taken back.
    private func reactions(on guids: Set<String>, after first: Int64) async throws -> [String: [InboxReaction]] {
        guard !guids.isEmpty else { return [:] }
        let pointers = guids.sorted().flatMap { AppData.Tapback.pointers(to: $0) }.map(AppData.literal).joined(separator: ",")
        let rows: [[String: Any]]
        do {
            rows = try await query("""
            SELECT m.associated_message_guid AS target, m.associated_message_type AS type,
                   \(customTapbacks ? "m.associated_message_emoji" : "NULL") AS emoji, m.is_from_me AS me,
                   COALESCE(h.id, '') AS sender
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > \(first) AND m.associated_message_type BETWEEN 2000 AND 3999
                AND m.associated_message_guid IN (\(pointers))
            ORDER BY m.ROWID
            """)
        } catch where customTapbacks && error.localizedDescription.contains("no such column") {
            // A database from before any emoji could be a tapback: the classic six still show.
            customTapbacks = false
            return try await reactions(on: guids, after: first)
        }
        let tapbacks = rows.compactMap { tapback -> AppData.Tapback? in
            let mine = (AppData.number(tapback["me"]) ?? 0) != 0
            return AppData.Tapback(associated: AppData.string(tapback["target"]), type: Int(AppData.number(tapback["type"]) ?? 0),
                                   emoji: AppData.string(tapback["emoji"]), sender: mine ? "me" : AppData.string(tapback["sender"]),
                                   mine: mine)
        }
        // Who put each emoji there, by their name in Contacts (else their number or address).
        let contacts = await ContactDirectory.names()
        return AppData.Tapback.reactions(tapbacks) { handle in
            let clean = AppData.cleanHandle(handle)
            return clean.isEmpty ? nil : contacts[AppData.key(clean)] ?? clean
        }
    }

    /// The messages read earlier (by guid) that got a tapback, or lost one, since the last look, and where the next look
    /// starts (kept by `read` once all of it worked). The first read only marks where to look from: the tapbacks until
    /// then come with its own messages.
    /// The messages (in the window the reads look at, `recent`) edited or unsent since the last read, as full rows, with
    /// the unsent ones among them by row, and how far this read looked. The first read only notes where it starts.
    private func changed(since recent: String) async throws -> (rows: [[String: Any]], unsent: Set<Int64>, cursor: Int64?) {
        guard keepsEdits else { return ([], [], nil) }
        let stamp = "MAX(COALESCE(m.date_edited, 0), COALESCE(m.date_retracted, 0))"
        do {
            guard let lastEdit else {
                let top = try await query("SELECT COALESCE(MAX(\(stamp)), 0) AS top FROM message m")
                return ([], [], top.first.flatMap { NotificationRecord.integer($0["top"]) } ?? 0)
            }
            let marks = try await query("""
            SELECT m.ROWID AS id, \(stamp) AS changed, COALESCE(m.date_retracted, 0) AS retracted FROM message m
            WHERE \(recent) AND COALESCE(m.associated_message_type, 0) = 0 AND \(stamp) > \(lastEdit)
            """)
            guard !marks.isEmpty else { return ([], [], lastEdit) }
            let cursor = marks.compactMap { NotificationRecord.integer($0["changed"]) }.max() ?? lastEdit
            let unsent = Set(marks.filter { (AppData.number($0["retracted"]) ?? 0) != 0 }.compactMap { NotificationRecord.integer($0["id"]) })
            let ids = marks.compactMap { NotificationRecord.integer($0["id"]) }.sorted().map(String.init).joined(separator: ",")
            return (try await query(Self.select + " WHERE m.ROWID IN (\(ids))"), unsent, cursor)
        } catch where error.localizedDescription.contains("no such column") {
            // A database from before messages could be edited or unsent: nothing changes after it is read.
            keepsEdits = false
            return ([], [], nil)
        }
    }

    private func tapped() async throws -> (targets: Set<String>, cursor: Int64) {
        guard let lastTapback else {
            let top = try await query("SELECT COALESCE(MAX(ROWID), 0) AS top FROM message")
            return ([], top.first.flatMap { NotificationRecord.integer($0["top"]) } ?? 0)
        }
        let rows = try await query("""
        SELECT ROWID AS id, associated_message_guid AS target FROM message
        WHERE ROWID > \(lastTapback) AND associated_message_type BETWEEN 2000 AND 3999 ORDER BY ROWID
        """)
        let cursor = rows.compactMap { NotificationRecord.integer($0["id"]) }.max() ?? lastTapback
        return (Set(rows.compactMap { AppData.Tapback.target(AppData.string($0["target"])) }.filter { seen[$0] != nil }), cursor)
    }

    // MARK: Sending

    /// Your text to the chat `name`, through the Messages app.
    func send(text: String, to name: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        try await deliver([.text(text)], to: name)
    }

    /// A file (with its caption after it, as Messages shows one), or a place or a contact card as text. Messages has no
    /// polls another app can send.
    func send(_ outgoing: ChatOutgoing, to name: String) async throws {
        switch outgoing {
        case .file(let file):
            guard FileManager.default.isReadableFile(atPath: file.path) else { throw NookError(tr("chat.compose.notAFile", file.name)) }
            let path = await Task.detached(priority: .userInitiated) { MessagesBridge.readable(file) }.value
            var items: [AppData.MessagesSend.Item] = [.file(path)]
            let caption = file.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { items.append(.text(caption)) }
            try await deliver(items, to: name)
        case .location, .contact:
            try await deliver([.text(outgoing.text)], to: name)
        case .poll:
            throw NookError(tr("chat.compose.unsupported"))
        }
    }

    /// Runs the script that sends `items` (`AppData.MessagesSend`), away from the main thread: the first time macOS asks
    /// whether Nook may control Messages, and Messages may need a moment to start.
    private func deliver(_ items: [AppData.MessagesSend.Item], to name: String) async throws {
        var chats = chatGUIDs(name)
        if chats.isEmpty { chats = try await resolve(name) }
        guard !chats.isEmpty else { throw NookError(tr("chat.messages.notFound", name)) }
        let script = AppData.MessagesSend.script(items, chats: chats)
        let result = await Task.detached(priority: .userInitiated) { SystemControl.appleScriptResult(script, timeout: 30) }.value
        guard result.text != AppData.MessagesSend.done else { return }
        // -1743: not allowed under Automation; -1728: Messages knows none of the chat's ids. AppleScript's own sentence
        // says which, in the Mac's language.
        if result.errorNumber == -1743 { throw NookError(tr("chat.messages.automation"), kind: .config) }
        let reason = result.errorNumber == -1728 ? nil : result.errorMessage
        throw NookError([tr("chat.compose.notSent"), reason].compactMap { $0 }.joined(separator: " "))
    }

    /// Messages' own ids of the chat Nook shows as `name`, looked up in the database when Nook did not read it since it
    /// started (an older chat, or one collected from notifications): by the messages Nook keeps of it, else as a group
    /// with that name, else as the person of that name in Contacts (or that number or address itself). The newest
    /// first; what is found is kept, so the chat's next read and send know it.
    private func resolve(_ name: String) async throws -> [String] {
        var found: [(chat: String, guid: String)] = []
        let rows = ChatCaptureService.shared.loadedInbox.threads[ChatInbox.key(app: app, chat: name)]?.messages
            .compactMap { $0.id.hasPrefix("imessage-") ? Int64($0.id.dropFirst("imessage-".count)) : nil } ?? []
        if !rows.isEmpty {
            for row in try await query("""
            SELECT DISTINCT c.ROWID AS chat, c.guid AS guid FROM chat_message_join cmj JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE cmj.message_id IN (\(rows.suffix(50).map(String.init).joined(separator: ",")))
            """) {
                found.append((AppData.string(row["chat"]), AppData.string(row["guid"])))
            }
        }
        if found.isEmpty {
            for row in try await query("SELECT ROWID AS chat, guid FROM chat WHERE display_name = \(AppData.literal(name))") {
                found.append((AppData.string(row["chat"]), AppData.string(row["guid"])))
            }
        }
        if found.isEmpty {
            let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            var keys = Set((await ContactDirectory.entries()).filter { fold($0.name) == fold(name) }.flatMap(\.handles).map(AppData.key))
            keys.insert(AppData.key(name))
            keys.remove("")
            // Chats with one person (style 45): the person's handle as Messages keeps it ("+316…", an address).
            for row in try await query("""
            SELECT c.ROWID AS chat, c.guid AS guid, h.id AS handle FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID JOIN handle h ON h.ROWID = chj.handle_id WHERE c.style = 45
            """) where keys.contains(AppData.key(AppData.string(row["handle"]))) {
                found.append((AppData.string(row["chat"]), AppData.string(row["guid"])))
            }
        }
        found.removeAll { $0.chat.isEmpty || $0.guid.isEmpty }
        guard !found.isEmpty else { return [] }
        // The chat with the newest message first, as `chatGUIDs` orders them.
        let last = try await query("""
        SELECT cmj.chat_id AS chat, MAX(m.date) AS last FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
        WHERE cmj.chat_id IN (\(Set(found.map(\.chat)).sorted().joined(separator: ","))) GROUP BY cmj.chat_id
        """)
        for row in last {
            active[AppData.string(row["chat"])] = AppData.appleDate(AppData.number(row["last"]) ?? 0)
        }
        for chat in found {
            guids[chat.chat] = chat.guid
            if names[chat.chat] == nil { names[chat.chat] = name }
        }
        return chatGUIDs(name)
    }

    /// Where Messages may read a file to send from. Messages sends only files it may read itself: one in Nook's
    /// temporary folder (where a converted file or a recording lands) goes out as "Not Delivered". So each file is
    /// copied into a folder of Nook's own under Messages' attachments (`~/Library/Messages/Attachments/Nook`, which
    /// the same Full Disk Access lets Nook write), and copies older than a day are cleared then. The original is used
    /// when copying fails.
    private nonisolated static func readable(_ file: ChatAttachment) -> String {
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: AppDatabase.home + "/Library/Messages/Attachments/Nook", isDirectory: true)
        let old = Date().addingTimeInterval(-86_400)
        let copies = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in copies {
            let changed = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let changed, changed < old { try? manager.removeItem(at: dir) }
        }
        let safe = file.name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        let copy = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(safe.isEmpty ? file.url.lastPathComponent : String(safe.suffix(120)))
        do {
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: file.url, to: copy)
            return copy.path
        } catch {
            return file.path
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

    /// When they read your message, from its row (`readat`), for the message's info in a private chat: one reader
    /// without a name, as the chat already has it. Nil while it is not read (or they do not share read receipts).
    private static func readers(_ row: [String: Any]) -> [ChatReader]? {
        let read = AppData.number(row["readat"]) ?? 0
        guard read > 0 else { return nil }
        return [ChatReader(name: "", receipt: .read, date: AppData.appleDate(read))]
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
           COALESCE(m.date_read, 0) AS readat, COALESCE(m.error, 0) AS error, COALESCE(m.guid, '') AS guid,
           COALESCE(m.thread_originator_guid, '') AS origin, COALESCE(c.guid, '') AS chatguid
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    """

    private func query(_ sql: String) async throws -> [[String: Any]] {
        do {
            let read = try await AppDatabase.read(path, sql, app: "Messages")
            if !read.complete { partial = true }
            return read.rows
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
final class WhatsAppDesktopBridge: ChatHistoryBridge, ChatSearchBridge {
    let app = "whatsapp"
    /// Often: a read first looks only at when the database changed, which costs nothing while it did not.
    let interval: TimeInterval = 2
    let readsLocally = true
    private(set) var isWorking = false

    private static let chats = 30
    private static let perChat = 30
    private static var path: String {
        AppDatabase.home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }

    private var lastRow: Int64?
    private var lastChange: Date?
    /// A query of the read going on read the database without its write-ahead log (see `MessagesBridge.partial`).
    private var partial = false
    /// New rows that had nothing to show yet, with when Nook first saw them: WhatsApp writes a message's row before its
    /// text is decrypted, and fills it in a moment later. They are read again until they say something, so a message
    /// shows as soon as it is there, not only when its chat is opened. Given up after `waitingFor`.
    private var waiting: [Int64: Date] = [:]
    private static let waitingFor: TimeInterval = 600
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

    var isReady: Bool {
        // WhatsApp linked through the chat helper (as Beeper did it) brings it live, with its whole history.
        !WhatsAppAccounts.shared.isConnected && !ChatHelper.linked(app) && FileManager.default.fileExists(atPath: Self.path)
    }

    func read() async throws -> [BridgedChat] {
        guard isReady else { isWorking = false; return [] }
        let change = [Self.path, Self.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
        if lastRow != nil, change != nil, change == lastChange { return [] }
        partial = false
        let contacts = await ContactDirectory.names()
        // Private chats (0) and groups (1); not broadcast lists or status updates.
        let kinds = "s.ZSESSIONTYPE IN (0, 1)"
        var rows: [[String: Any]]
        if let lastRow {
            rows = try await select("WHERE m.Z_PK > \(lastRow) AND \(kinds) ORDER BY m.Z_PK")
            waiting = waiting.filter { Date().timeIntervalSince($0.value) < Self.waitingFor }
            if !waiting.isEmpty {
                let ids = waiting.keys.sorted().map(String.init).joined(separator: ",")
                rows = try await select("WHERE m.Z_PK IN (\(ids)) AND \(kinds) ORDER BY m.Z_PK") + rows
            }
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
            if group { groups.insert(chat) }
            guard let message = Self.message(row, contacts: contacts) else {
                // Read again at the next look, until WhatsApp filled it in (see `waiting`).
                if lastRow != nil, waiting[id] == nil, waiting.count < 200 { waiting[id] = Date() }
                continue
            }
            waiting[id] = nil
            if message.isMine { self.mine[id] = (chat, message) }
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
        // A read without the write-ahead log may have missed the newest message: the next turn reads again.
        lastChange = partial ? nil : change
        isWorking = true
        return names.map { chat, name in
            let people = groupPeople[chat] ?? []
            return BridgedChat(app: app, name: name, messages: (messages[chat] ?? []).sorted { $0.date < $1.date },
                               unread: unread[chat] ?? 0, members: people.isEmpty ? nil : people)
        }
    }

    /// A row as the chat shows it; nil for one with nothing to show.
    private static func message(_ row: [String: Any], contacts: [String: String]) -> InboxMessage? {
        let id = NotificationRecord.integer(row["id"]) ?? 0
        let group = (AppData.number(row["kind"]) ?? 0) == 1
        let mine = (AppData.number(row["me"]) ?? 0) != 0
        var text = AppData.string(row["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if ChatFormat.isBlank(text) { text = "" }
        let media = Self.media(row)
        let type = Int(AppData.number(row["type"]) ?? 0)
        // A poll shows as one, its question its text; its options and votes stay in the app.
        let poll = type == Self.pollType
            ? ChatPoll(question: text.isEmpty ? tr("chat.poll.title") : text, options: [], unknownCounts: true) : nil
        if poll != nil { text = "" }
        if text.isEmpty, media == nil, poll == nil { text = Self.label(type) }
        guard !text.isEmpty || media != nil || poll != nil else { return nil }
        var sender = ""
        if group, !mine {
            sender = AppData.string(row["sender"])
            if sender.isEmpty { sender = contacts[AppData.key(AppData.string(row["member"]))] ?? "" }
        }
        var message = InboxMessage(
            id: "wadesktop-\(id)", sender: sender, text: text,
            date: AppData.appleDate(AppData.number(row["date"]) ?? 0), fromMe: mine, media: media, poll: poll)
        if mine { message.receipt = ChatReceipts.whatsAppDesktop(status: Int(AppData.number(row["status"]) ?? 0)) }
        return message
    }

    func canLoadOlder(name: String) -> Bool { isReady && !sessions(name).isEmpty }

    /// The app's chats Nook shows as `name`.
    private func sessions(_ name: String) -> [Int] {
        let key = ChatInbox.key(app: app, chat: name)
        return names.filter { ChatInbox.key(app: app, chat: $0.value) == key }.keys.compactMap(Int.init)
    }

    /// Scrolling back: the app keeps what the phone synced to it, and every batch goes further back in that.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        let ids = sessions(name)
        guard isReady, !ids.isEmpty else { return (nil, false) }
        let contacts = await ContactDirectory.names()
        let rows = try await select("""
        WHERE m.ZCHATSESSION IN (\(ids.sorted().map(String.init).joined(separator: ",")))
            AND m.ZMESSAGEDATE < \(before.timeIntervalSinceReferenceDate)
        ORDER BY m.ZMESSAGEDATE DESC LIMIT \(ChatHistory.step + 1)
        """)
        let more = rows.count > ChatHistory.step
        let batch = Array(rows.prefix(ChatHistory.step))
        let messages = batch.compactMap { Self.message($0, contacts: contacts) }
        // A batch of nothing to show is not the start: the next one goes on from its oldest row.
        if messages.isEmpty, more, let oldest = batch.last.map({ AppData.appleDate(AppData.number($0["date"]) ?? 0) }), oldest < before {
            return try await older(name: name, before: oldest, oldestID: nil)
        }
        let people = ids.flatMap { groupPeople[String($0)] ?? [] }
        let chat = messages.isEmpty ? nil : BridgedChat(app: app, name: name, messages: messages.sorted { $0.date < $1.date },
                                                        unread: nil, members: people.isEmpty ? nil : people)
        return (chat, more)
    }

    // MARK: Search everything

    /// The app's database is searched also while a linked phone brings WhatsApp live: it keeps what the phone synced to
    /// it, and `ChatCaptureService.shownThread` finds the linked phone's chat of the same name for it.
    var searchesHistory: Bool { isReady }

    /// Everything the phone synced to this Mac, as `search_whatsapp` reads it, private chats and groups.
    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard isReady, !words.isEmpty else { return [] }
        let contacts = await ContactDirectory.names()
        var found: [(chat: BridgedChat, messages: [InboxMessage])] = []
        for word in words {
            let rows = try await select("""
            WHERE s.ZSESSIONTYPE IN (0, 1) AND m.ZTEXT IS NOT NULL AND \(AppData.anyLike(["m.ZTEXT"], [word]))
            ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """)
            for row in rows {
                guard let message = Self.message(row, contacts: contacts), ChatHistorySearch.matches(message, [word]) else { continue }
                let chat = AppData.string(row["chat"])
                var name = names[chat] ?? AppData.string(row["chatname"])
                if name.isEmpty { name = contacts[AppData.key(AppData.string(row["jid"]))] ?? WAJID.displayNumber(AppData.string(row["jid"])) }
                found.append((BridgedChat(app: app, name: name, messages: [], unread: nil), [message]))
            }
        }
        return ChatHistorySearch.chats(found)
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

    /// WhatsApp's message type of a poll.
    private static let pollType = 46

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
            let read = try await AppDatabase.read(Self.path, sql, app: "WhatsApp")
            if !read.complete { partial = true }
            return read.rows
        } catch {
            isWorking = false
            throw error
        }
    }
}

// MARK: Nook's chat helper

/// Every app linked through Nook's own chat helper (`ChatHelper`: Telegram, Signal, Messenger, Instagram, X, LinkedIn,
/// Slack), each chat under its own app, through the helper's local API on this Mac with the token Nook makes at each
/// start. Nothing leaves the Mac: the API is on 127.0.0.1. An app Nook reads with a bridge of its own is left to that
/// bridge.
@MainActor
final class ChatServiceBridge: ObservableObject, ChatBridge {
    let app = "service"
    /// While the live line is open a read only catches what it may have missed; without it, every ten seconds.
    var interval: TimeInterval { live.isLive ? 120 : 10 }
    private(set) var isWorking = false
    /// A chat changed and is read now (the live line said so): its turn comes at once.
    var onChange: () -> Void = {}
    /// The apps whose chats it brought in: their notifications only repeat it.
    private(set) var covered: Set<String> = []
    /// An app another bridge already reads.
    var skips: (String) -> Bool = { _ in false }

    /// The chat service Nook reads: its own helper.
    static var base: URL { ChatHelper.base }
    private static let chatCount = 40
    private static let history = 30

    /// The newest activity per chat at the last read: only chats that moved are read again.
    private var seen: [String: Date] = [:]
    /// Chats told to have changed (the live line, something Nook did in them) that were not read since: read at the next
    /// turn even when their newest activity looks the same. Kept apart from `seen`, so a change told while a read is
    /// under way is not lost when that read ends (Instagram tells of the message a moment after the chat moved).
    private var stale: Set<String> = []
    /// How often in a row a chat was read before its newest message was there (see `ChatServiceData.isBehind`).
    private var behind: [String: Int] = [:]
    /// Each chat's unread count as last passed on: a chat read on your phone (or in the app) changes only this, not its
    /// newest message, and still goes to the inbox at once, so it is read in Nook too.
    private var reportedUnread: [String: Int] = [:]
    private static let behindRetries = 3
    /// Files the helper downloaded for Nook, by their `mxc://` address.
    private var downloaded: [String: String] = [:]
    /// The helper's id of every chat it brought in, by its app and its name in Nook: where what you send from Nook goes.
    private var chatIDs: [String: String] = [:]
    /// Every chat at the last read by its id, for what can be done in it (pinned, muted, editing…).
    @Published private(set) var chats: [String: ChatServiceData.Chat] = [:]
    /// The live line is open: changes come in the moment they happen (Settings › Connections shows it).
    @Published private(set) var isLive = false
    private let live = ChatLiveStream()

    /// The helper's own token, made at its start; nil while it does not run.
    static var token: String? { ChatHelper.shared.isRunning ? ChatHelper.shared.token : nil }

    init() {
        live.onChange = { [weak self] chat in
            guard let self else { return }
            self.stale.insert(chat)
            self.onChange()
        }
        live.onLive = { [weak self] live in if self?.isLive != live { self?.isLive = live } }
        // Who types where: the chat as the Chats tab knows it, by its app and its name; in a private chat without a name.
        live.onTyping = { [weak self] id, person, name, kind, seconds in
            guard let chat = self?.chats[id] else { return }
            let key = ChatInbox.key(app: chat.app, chat: chat.title)
            if seconds > 0 {
                ChatTypingCenter.shared.typing(chat: key, person: person, name: chat.isGroup ? name : "", kind: kind,
                                               seconds: min(seconds, ChatTypingState.hold))
            } else {
                ChatTypingCenter.shared.stopped(chat: key, person: person)
            }
        }
        // What changed while the line was down is not told: every chat is read again.
        live.onDrop = { [weak self] in
            self?.seen = [:]
            self?.onChange()
        }
    }

    /// Closes the live line (Nook stops reading chats).
    func stop() {
        live.disconnect()
    }

    /// Once something was linked through the helper (it then starts at the first read).
    var isReady: Bool {
        ChatHelper.isBuilt && FileManager.default.fileExists(atPath: ChatHelper.dataDirectory.path)
    }

    func reset() {
        seen = [:]
        stale = []
        behind = [:]
        reportedUnread = [:]
        covered = []
        isWorking = false
    }

    private static func path(_ chat: String) -> String { "/v1/chats/" + ChatJSON.segment(chat) }

    func read() async throws -> [BridgedChat] {
        if ChatHelper.isBuilt, isReady, !ChatHelper.shared.isRunning { await ChatHelper.shared.start() }
        guard isReady, let token = Self.token else {
            isWorking = false
            live.disconnect()
            return []
        }
        var socket = URLComponents(url: Self.base.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false)
        socket?.scheme = "ws"
        if !live.isConnecting, let url = socket?.url { live.connect(url, token: token) }
        if ChatLinker.shared.networks.isEmpty { await ChatLinker.shared.refresh() }
        do {
            var listed = ChatServiceData.chats(try await get("/v1/chats", ["limit": String(Self.chatCount)], token: token))
                .filter { !skips($0.app) }
            // What Beeper had set for these chats (pinned, muted, archived), once, when someone moved over from it.
            let archived = await BeeperImporter.shared.apply(to: listed, in: self)
            if !archived.isEmpty { listed.removeAll { archived.contains($0.id) } }
            let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if byID != chats { chats = byID }
            var result: [BridgedChat] = []
            for chat in listed where !(stale.contains(chat.id) || (chat.last.map({ seen[chat.id] != $0 }) ?? (seen[chat.id] == nil))) {
                // Nothing new in it, but read (or marked unread) somewhere else since: only its count goes.
                guard let reported = reportedUnread[chat.id], reported != chat.unread else { continue }
                reportedUnread[chat.id] = chat.unread
                let account = chat.account ?? ChatLinker.shared.accountName(for: chat.app)
                result.append(BridgedChat(app: chat.app, name: chat.title, messages: [], unread: chat.unread, account: account))
            }
            // The chats read before one that fails are already marked seen: their messages must still go to the inbox, or
            // they never come again. The failed one stays stale and is read again at the next tick.
            var failure: Error?
            for chat in listed where stale.contains(chat.id) || (chat.last.map({ seen[chat.id] != $0 }) ?? (seen[chat.id] == nil)) {
                // Before the read: a change told while it runs marks the chat again, for the next turn.
                stale.remove(chat.id)
                let answer: [String: Any]
                do {
                    answer = try await get(Self.path(chat.id) + "/messages", ["limit": String(Self.history)], token: token)
                } catch {
                    stale.insert(chat.id)
                    failure = error
                    continue
                }
                let messages = await withFiles(ChatServiceData.messages(answer, chat: chat), token: token)
                let deleted = ChatServiceData.deleted(answer, chat: chat)
                // The chat moved to a message the answer does not hold yet (the app tells of a chat a moment before its
                // message is there): read it again at the next turns, a few times, instead of waiting for the chat to
                // move once more. Its row would show an older message than the chat until then.
                if ChatServiceData.isBehind(messages, chat: chat), (behind[chat.id] ?? 0) < Self.behindRetries {
                    behind[chat.id, default: 0] += 1
                    stale.insert(chat.id)
                    onChange()
                } else {
                    behind[chat.id] = nil
                }
                seen[chat.id] = chat.last ?? .distantPast
                reportedUnread[chat.id] = chat.unread
                covered.insert(chat.app)
                chatIDs[chat.app + "|" + chat.title] = chat.id
                guard !messages.isEmpty || !deleted.isEmpty else { continue }
                let picture = await local(chat.picture, token: token)
                let account = chat.account ?? ChatLinker.shared.accountName(for: chat.app)
                result.append(BridgedChat(app: chat.app, name: chat.title, messages: messages, unread: chat.unread, avatar: picture,
                                          members: chat.members.isEmpty ? nil : chat.members, deleted: deleted, account: account))
            }
            if let failure {
                if result.isEmpty { throw failure }
                onChange()
            }
            isWorking = true
            return result
        } catch {
            isWorking = false
            throw error
        }
    }

    /// How many older messages one scroll back asks for: the helper's batch (`paginateBatch` in apps/chatd).
    static let olderStep = ChatHistory.step

    /// Scrolling back in the chat Nook shows as `name` in `app`, as Beeper does it: the helper first brings in the next
    /// batch of older messages from the app (WhatsApp asks the phone), then Nook reads the batch before `before` from
    /// it. No cap: each scroll back goes on from the oldest message Nook shows. The batch as a chat, and whether there
    /// is still more before it.
    func older(app: String, name: String, before: Date) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        guard let token = Self.token, let id = chatID(app: app, name: name), let chat = chats[id] else { return (nil, false) }
        let answer = try await call("POST", Self.path(id) + "/paginate", [:], token: token, timeout: 75,
                                    failure: tr("chat.action.failed"))
        let more = (ChatJSON.object(answer)?["hasMore"] as? Bool) ?? false
        let millis = Int64((before.timeIntervalSince1970 * 1000).rounded(.down))
        let read = try await get(Self.path(id) + "/messages", ["limit": String(Self.olderStep), "before": String(millis)], token: token)
        let messages = await withFiles(ChatServiceData.messages(read, chat: chat).filter { $0.date < before }, token: token)
        let bridged = BridgedChat(app: app, name: name, messages: messages, unread: nil,
                                  members: chat.members.isEmpty ? nil : chat.members,
                                  account: chat.account ?? ChatLinker.shared.accountName(for: app))
        // The helper may still hold older ones it brought in earlier, even when the app has nothing more to send.
        let stored = (read["items"] as? [Any])?.count ?? 0
        return (messages.isEmpty ? nil : bridged, more || stored >= Self.olderStep)
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

    /// Where a file the helper names is on this Mac: a `file://` one as it is, an `mxc://` one once the helper downloaded
    /// it through its own API (it says where it put it). Nothing is fetched from anywhere but the helper on this Mac.
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
              let local = (ChatJSON.object(answer.0)?["srcURL"] as? String).flatMap({ URL(string: $0) }), local.isFileURL else { return nil }
        downloaded[source] = local.path
        return local.path
    }

    /// A chat you opened in Nook: read again at the next turn, so it shows what the app has now, also what the live line
    /// did not tell. False when the helper does not hold this chat.
    @discardableResult
    func refresh(app: String, name: String) -> Bool {
        guard let id = chatID(app: app, name: name) else { return false }
        stale.insert(id)
        return true
    }

    // MARK: Sending

    /// The helper's id of the chat Nook shows as `name` in `app`, once the helper brought it in.
    func chatID(app: String, name: String) -> String? {
        isReady ? chatIDs[app + "|" + name] : nil
    }

    /// What every app the helper links can take from Nook: text and files; a place or a contact goes as text.
    var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.noPolls }

    /// Sends what you typed, or a file, a place or a contact card, to a chat the helper brought in (Instagram, Signal,
    /// Messenger…), as an answer to `replyTo` (a message's id in Nook) when set. The helper hands it to the app; the
    /// chat shows it at the next read. Throws with a sentence you can act on.
    func send(text: String? = nil, _ outgoing: ChatOutgoing? = nil, to chat: String, replyTo: String? = nil) async throws {
        guard let token = Self.token else { throw NookError(tr("chats.service.unreachable")) }
        let messages = Self.path(chat) + "/messages"
        let answered = replyTo.flatMap { ChatServiceData.networkID($0, chat: chat) }
        var request: WASendRequest
        if let outgoing {
            if case .poll = outgoing { throw NookError(tr("chat.compose.unsupported")) }
            var uploadID: String?
            if case .file(let file) = outgoing {
                guard !file.tooLarge, let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
                    throw NookError(tr("chat.compose.tooLarge", file.name))
                }
                let upload = WASend.serviceUpload(file, data: data)
                guard let id = WASend.serviceUploadID(try await post(upload.path, upload.json ?? [:], token: token, timeout: 120)) else {
                    throw NookError(tr("chat.compose.notSent"))
                }
                uploadID = id
            }
            request = WASend.serviceMessage(outgoing, path: messages, uploadID: uploadID, replyTo: answered)
        } else {
            let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
            request = WASendRequest(path: messages, json: ["text": body])
            if let answered { request.json?["replyToMessageID"] = answered }
        }
        _ = try await post(request.path, request.json ?? [:], token: token, timeout: 30)
        // The chat is read again at the next turn, with the message just sent.
        stale.insert(chat)
    }

    // MARK: Doing things in a chat

    /// Marks the chat read in its app, up to its newest message: the other side sees it was read.
    func markRead(_ chat: String) async throws {
        try await act("POST", Self.path(chat) + "/read", [:], chat: chat)
    }

    /// Marks the chat unread in its app, so it waits there too.
    func markUnread(_ chat: String) async throws {
        try await act("POST", Self.path(chat) + "/unread", [:], chat: chat)
    }

    /// Your emoji on a message (Nook's id of it); `mine` takes yours back instead.
    func react(_ emoji: String, to message: String, in chat: String, mine: Bool) async throws {
        guard let id = ChatServiceData.networkID(message, chat: chat) else { throw NookError(tr("chat.action.failed")) }
        let reactions = Self.path(chat) + "/messages/" + ChatJSON.segment(id) + "/reactions"
        if mine {
            try await act("DELETE", reactions + "/" + ChatJSON.segment(emoji), nil, chat: chat)
        } else {
            try await act("POST", reactions, ["reactionKey": emoji], chat: chat)
        }
    }

    /// Your vote on a poll (its options' texts; an empty choice takes it back), where the chat's network takes votes.
    func vote(_ choice: [String], on message: String, in chat: String) async throws {
        guard let id = ChatServiceData.networkID(message, chat: chat) else { throw NookError(tr("chat.poll.failed")) }
        try await act("POST", Self.path(chat) + "/messages/" + ChatJSON.segment(id) + "/vote", ["answers": choice], chat: chat)
    }

    /// Changes the text of your message.
    func edit(_ message: String, in chat: String, to text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard let id = ChatServiceData.networkID(message, chat: chat) else { throw NookError(tr("chat.action.failed")) }
        try await act("PUT", Self.path(chat) + "/messages/" + ChatJSON.segment(id), ["text": body], chat: chat)
    }

    /// Deletes your message for everyone in the chat, where its app can.
    func delete(_ message: String, in chat: String) async throws {
        guard let id = ChatServiceData.networkID(message, chat: chat) else { throw NookError(tr("chat.action.failed")) }
        try await act("DELETE", Self.path(chat) + "/messages/" + ChatJSON.segment(id), nil, query: [URLQueryItem(name: "forEveryone", value: "true")],
                      chat: chat)
    }

    /// Pins or unpins the chat in its app.
    func setPinned(_ pinned: Bool, chat: String) async throws {
        try await act("PATCH", Self.path(chat), ["isPinned": pinned], chat: chat)
        chats[chat]?.isPinned = pinned
    }

    /// Mutes or unmutes the chat's notifications in its app.
    func setMuted(_ muted: Bool, chat: String) async throws {
        try await act("PATCH", Self.path(chat), ["isMuted": muted], chat: chat)
        chats[chat]?.isMuted = muted
    }

    /// Archives the chat in its app: it leaves the list there, and here.
    func archive(_ chat: String) async throws {
        try await act("POST", Self.path(chat) + "/archive", ["archived": true], chat: chat)
        chats[chat] = nil
    }

    /// One change in a chat; the chat is read again right after, to show it.
    private func act(_ method: String, _ path: String, _ json: [String: any Sendable]?, query: [URLQueryItem] = [],
                     chat: String) async throws {
        // Said as a chat's own failure: where Nook reads the chat from is not something to show here.
        guard let token = Self.token else { throw NookError(tr("chat.action.failed")) }
        _ = try await call(method, path, json, query: query, token: token, timeout: 30, failure: tr("chat.action.failed"), plain: true)
        stale.insert(chat)
        onChange()
    }

    private func post(_ path: String, _ json: [String: any Sendable], token: String, timeout: TimeInterval) async throws -> Data {
        try await call("POST", path, json, token: token, timeout: timeout, failure: tr("chat.compose.notSent"))
    }

    /// One request to the local service; `plain` keeps its errors to `failure` (no service name in them).
    func call(_ method: String, _ path: String, _ json: [String: any Sendable]?, query: [URLQueryItem] = [],
                      token: String, timeout: TimeInterval, failure: String, plain: Bool = false) async throws -> Data {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NookError(failure) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ConnectorHTTP.session(timeout: timeout).data(for: request)
        } catch {
            throw NookError(plain ? failure : tr("chats.service.unreachable"))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw NookError(plain ? failure : tr("chats.service.unreachable")) }
        guard (200..<300).contains(code) else {
            // The chat app's own reason, when it gives one (too old to edit, not allowed…).
            throw NookError(failure + " " + (ChatServiceData.errorMessage(data) ?? "HTTP \(code)"))
        }
        return data
    }

    func get(_ path: String, _ parameters: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NookError(path) }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ConnectorHTTP.session.data(for: request)
        } catch {
            throw NookError(tr("chats.service.unreachable"))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw NookError(tr("chats.service.unreachable")) }
        guard (200..<300).contains(code), let json = ChatJSON.object(data) else { throw NookError("HTTP \(code)") }
        return json
    }
}

// MARK: Slack

/// Your Slack direct messages and group messages, with their history, through Slack's Web API: with the sign-in of
/// Slack's website after you signed in on slack.com (`SlackWebSession`), or with a user token you set in Settings ›
/// Chats (kept in the Keychain; reading needs im:history, mpim:history, im:read, mpim:read, users:read and files:read).
/// Only Slack is asked, and only for your own conversations. After your own click it also writes there, as Slack's own
/// app does: text and files, answers in a thread, emoji, your messages' edits and deletions, and marking a
/// conversation read. A pasted token needs chat:write, reactions:write, files:write, im:write and mpim:write for that;
/// without one, Slack's refusal names the scope it misses.
@MainActor
final class SlackBridge: ChatHistoryBridge, ChatSearchBridge {
    let app = "slack"
    let interval: TimeInterval = 60
    private(set) var isWorking = false

    /// Where the token is kept.
    static let tokenAccount = "chats.slack.token"

    /// What Slack is asked with: the website's sign-in, else the token you pasted. Nil once Slack is linked through
    /// Nook's chat helper, so it is not read twice.
    static var auth: SlackData.Auth? {
        guard !ChatHelper.linked("slack") else { return nil }
        if let web = SlackWebSession.shared.auth { return web }
        guard let token = CloudHelp.secret(tokenAccount), token.hasPrefix("xox") else { return nil }
        return SlackData.Auth(token: token)
    }

    /// The token you pasted, if that is how Slack is linked.
    static var token: String? {
        guard let auth = Self.auth, auth.cookie == nil else { return nil }
        return auth.token
    }

    /// Conversations read in one go: the most recently active first, then a few of the others in turn, so every one is
    /// read sooner or later without passing Slack's rate limits.
    private static let perRead = 12
    private static let rotating = 4
    private static let firstHistory = 30
    /// Pages of newer messages one later read follows at most per conversation (30 each).
    private static let catchUpPages = 5

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
    /// Conversations changed from Nook, to read at once, with the messages (their `ts`) to read again: one you edited or
    /// put an emoji on, which a read of only the newer messages would not bring back.
    private var stale: [String: Set<String>] = [:]
    /// Your messages deleted from Nook, per conversation (their id in Nook), for the next read to drop from the chat.
    private var gone: [String: [String]] = [:]
    /// Where you stand in each conversation as Slack says (`client.counts`), and the newest messages read of each (their
    /// `ts`, whether yours), to count what is unread in Slack itself.
    private var lastRead: [String: String] = [:]
    private var recent: [String: [(ts: Double, mine: Bool)]] = [:]
    private static let counted = 100

    var isReady: Bool { Self.auth != nil }

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
        stale = [:]
        gone = [:]
        lastRead = [:]
        recent = [:]
        isWorking = false
    }

    func read() async throws -> [BridgedChat] {
        guard let auth = Self.auth else { isWorking = false; return [] }
        do {
            if me == nil { me = SlackData.me(try await call("auth.test", [:], auth: auth)) }
            if usersAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                let members = try await pages("users.list", ["limit": "200"], auth: auth, maxPages: 5)
                users = members.reduce(into: [:]) { $0.merge(SlackData.users($1)) { a, _ in a } }
                avatars = members.reduce(into: [:]) { $0.merge(SlackData.avatars($1)) { a, _ in a } }
                usersAt = Date()
            }
            if conversationsAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                conversations = try await pages("conversations.list", ["types": "im,mpim", "exclude_archived": "true", "limit": "200"],
                                                auth: auth, maxPages: 5).flatMap(SlackData.conversations)
                for conversation in conversations { active[conversation.id] = max(active[conversation.id] ?? 0, conversation.updated) }
                conversationsAt = Date()
            }
            // Where you stand in each conversation, as Slack's website asks it (Slack answers it for the website's sign-in):
            // reading a chat in Slack reads it in Nook too. Without an answer Nook counts new messages itself.
            let marks = (try? await call("client.counts", [:], auth: auth)).map(SlackData.readMarks) ?? [:]
            var handed = Set<String>()
            var chats: [BridgedChat] = []
            // The conversations read before one that fails already moved `newest` on: their messages must still go to the
            // inbox, or they never come again. The failed one is read again next time; a rate limit or a lost sign-in
            // ends this round.
            var failure: Error?
            for conversation in pick() {
                var parameters = ["channel": conversation.id, "limit": String(Self.firstHistory)]
                if let ts = newest[conversation.id] { parameters["oldest"] = ts }
                var listed: [[String: Any]] = []
                var read: [InboxMessage]
                do {
                    // After the first read every page newer than the last one read comes in, not only the newest 30: a
                    // busy conversation would otherwise skip what came between two reads for good.
                    let jsons = try await pages("conversations.history", parameters, auth: auth,
                                                maxPages: newest[conversation.id] == nil ? 1 : Self.catchUpPages)
                    listed = jsons.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
                    read = jsons.flatMap { SlackData.messages($0, conversation: conversation, users: users, me: me) }
                    for ts in stale[conversation.id] ?? [] {
                        let again = try await call("conversations.history", [
                            "channel": conversation.id, "oldest": ts, "latest": ts, "inclusive": "true", "limit": "1",
                        ], auth: auth)
                        for message in SlackData.messages(again, conversation: conversation, users: users, me: me)
                        where !read.contains(where: { $0.id == message.id }) {
                            read.append(message)
                        }
                    }
                } catch let error as NookError where error.kind == .auth || error.kind == .rateLimited {
                    failure = error
                    break
                } catch {
                    failure = error
                    continue
                }
                stale[conversation.id] = nil
                let messages = await withFiles(read.sorted { $0.date < $1.date }, auth: auth)
                if let last = listed.compactMap({ $0["ts"] as? String })
                    .max(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }) {
                    newest[conversation.id] = last
                    active[conversation.id] = max(active[conversation.id] ?? 0, Double(last) ?? 0)
                } else if newest[conversation.id] == nil {
                    newest[conversation.id] = "0"
                }
                let deleted = gone.removeValue(forKey: conversation.id) ?? []
                guard !messages.isEmpty || !deleted.isEmpty else { continue }
                let picture = await avatar(of: conversation.user)
                if conversation.isGroup, people[conversation.id] == nil {
                    // One refused list (a missing scope) leaves the group without its people, not without its messages.
                    let json = try? await call("conversations.members", ["channel": conversation.id, "limit": "200"], auth: auth)
                    people[conversation.id] = json.map { SlackData.members($0, users: users, me: me) } ?? []
                }
                let members = people[conversation.id] ?? []
                remember(messages, in: conversation.id)
                handed.insert(conversation.id)
                chats.append(BridgedChat(app: app, name: SlackData.chatName(conversation, users: users, me: me),
                                         messages: messages, unread: unread(conversation.id, marks: marks), avatar: picture,
                                         members: members.isEmpty ? nil : members, deleted: deleted))
            }
            // A chat read (or marked unread) in Slack since, without a new message: its count follows.
            for conversation in conversations where !handed.contains(conversation.id) && recent[conversation.id] != nil
                && marks[conversation.id] != nil && marks[conversation.id] != lastRead[conversation.id] {
                chats.append(BridgedChat(app: app, name: SlackData.chatName(conversation, users: users, me: me), messages: [],
                                         unread: unread(conversation.id, marks: marks)))
            }
            if !marks.isEmpty { lastRead = marks }
            if chats.isEmpty, let failure { throw failure }
            isWorking = true
            return chats
        } catch {
            isWorking = false
            throw error
        }
    }

    /// The newest messages read of a conversation, to count from.
    private func remember(_ messages: [InboxMessage], in conversation: String) {
        var known = recent[conversation] ?? []
        for message in messages {
            let ts = message.date.timeIntervalSince1970
            if !known.contains(where: { $0.ts == ts }) { known.append((ts, message.isMine)) }
        }
        recent[conversation] = Array(known.sorted { $0.ts < $1.ts }.suffix(Self.counted))
    }

    /// The conversation's unread count in Slack itself, when Slack said where you stand; nil lets Nook count.
    private func unread(_ conversation: String, marks: [String: String]) -> Int? {
        guard let read = marks[conversation] else { return nil }
        return SlackData.unread(recent[conversation] ?? [], lastRead: read)
    }

    /// The conversation Nook shows as `name`.
    private func conversation(_ name: String) -> SlackData.Conversation? {
        let key = ChatInbox.key(app: app, chat: name)
        return conversations.first { ChatInbox.key(app: app, chat: SlackData.chatName($0, users: users, me: me)) == key }
    }

    func canLoadOlder(name: String) -> Bool { isReady && conversation(name) != nil }

    /// Scrolling back: Slack's history before `before`, a page at a time, as far back as the workspace keeps it.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        guard let auth = Self.auth, let conversation = conversation(name) else { return (nil, false) }
        let json = try await call("conversations.history", [
            "channel": conversation.id, "limit": String(ChatHistory.step), "inclusive": "false",
            "latest": String(format: "%.6f", before.timeIntervalSince1970),
        ], auth: auth)
        let read = SlackData.messages(json, conversation: conversation, users: users, me: me).filter { $0.date < before }
        let messages = await withFiles(read, auth: auth)
        let more = (json["has_more"] as? Bool) ?? false
        // A page of nothing to show (people joining, bot notes) is not the start: the next one goes on from its oldest.
        if messages.isEmpty, more, let oldest = (json["messages"] as? [[String: Any]])?.compactMap({ ($0["ts"] as? String).flatMap(Double.init) }).min(),
           oldest < before.timeIntervalSince1970 {
            return try await older(name: name, before: Date(timeIntervalSince1970: oldest), oldestID: nil)
        }
        let members = people[conversation.id] ?? []
        let chat = messages.isEmpty ? nil : BridgedChat(app: app, name: name, messages: messages, unread: nil,
                                                        members: members.isEmpty ? nil : members)
        return (chat, more)
    }

    // MARK: Search everything

    /// Slack's own search (`search.messages`), as far back as the workspace keeps: with the website's sign-in, or a
    /// pasted token with search:read. Only the conversations Nook reads are kept, so a hit opens a chat it shows.
    var searchesHistory: Bool { isReady && !conversations.isEmpty }

    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard let auth = Self.auth, !words.isEmpty else { return [] }
        let known = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [(chat: BridgedChat, messages: [InboxMessage])] = []
        for word in words {
            let json = try await call("search.messages", [
                "query": word, "count": String(min(limit, 100)), "sort": "timestamp", "sort_dir": "desc",
            ], auth: auth)
            let matches = ((json["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
            for match in matches {
                guard let id = (match["channel"] as? [String: Any])?["id"] as? String, let conversation = known[id] else { continue }
                let messages = SlackData.messages(["messages": [match]], conversation: conversation, users: users, me: me)
                    .filter { ChatHistorySearch.matches($0, [word]) }
                guard !messages.isEmpty else { continue }
                let name = SlackData.chatName(conversation, users: users, me: me)
                found.append((BridgedChat(app: app, name: name, messages: [], unread: nil), messages))
            }
        }
        return ChatHistorySearch.chats(found)
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
    private func withFiles(_ messages: [InboxMessage], auth: SlackData.Auth) async -> [InboxMessage] {
        var result = messages
        for index in result.indices {
            guard var media = result[index].media, media.path == nil, let source = media.source,
                  let url = URL(string: source), SlackData.isSlack(url) else { continue }
            let target = ChatMedia.destination(key: result[index].id, name: media.name ?? url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                let request = Self.request(url, auth: auth)
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

    /// The conversations to read now: the ones changed from Nook, never read ones and the busiest, then a few others
    /// in turn.
    private func pick() -> [SlackData.Conversation] {
        let ordered = conversations.sorted { (active[$0.id] ?? 0) > (active[$1.id] ?? 0) }
        let changed = ordered.filter { stale[$0.id] != nil || gone[$0.id] != nil }
        let others = ordered.filter { stale[$0.id] == nil && gone[$0.id] == nil }
        let unread = others.filter { newest[$0.id] == nil }
        let busy = others.filter { newest[$0.id] != nil }
        var picked = Array((changed + unread).prefix(Self.perRead))
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

    private func pages(_ method: String, _ parameters: [String: String], auth: SlackData.Auth, maxPages: Int) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var query = parameters
            if let cursor { query["cursor"] = cursor }
            let json = try await call(method, query, auth: auth)
            results.append(json)
            cursor = SlackData.nextCursor(json)
            if cursor == nil { break }
        }
        return results
    }

    /// A request to Slack with the token, and the website's cookie when it is signed in that way (sent as given, not
    /// mixed with cookies of the session).
    private static func request(_ url: URL, auth: SlackData.Auth) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in auth.headers { request.setValue(value, forHTTPHeaderField: name) }
        if auth.cookie != nil { request.httpShouldHandleCookies = false }
        return request
    }

    private func call(_ method: String, _ parameters: [String: String], auth: SlackData.Auth) async throws -> [String: Any] {
        var components = URLComponents(string: "https://slack.com/api/" + method)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NookError("Slack: \(method)") }
        return try await answer(Self.request(url, auth: auth))
    }

    /// A change through Slack's Web API (chat.postMessage, reactions.add…), its fields sent as a form, as Slack's own
    /// clients do. A refusal in `ignoring` ("already_reacted") means it is so already, and counts as done.
    private func post(_ method: String, _ fields: [String: String], auth: SlackData.Auth,
                      ignoring: Set<String> = []) async throws -> [String: Any] {
        guard let url = URL(string: "https://slack.com/api/" + method) else { throw NookError("Slack: \(method)") }
        var request = Self.request(url, auth: auth)
        request.httpMethod = "POST"
        request.httpBody = SlackData.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await answer(request, ignoring: ignoring)
    }

    /// Slack's answer to a request: its JSON, or an error that says why not (too many requests, or Slack's own reason,
    /// such as the scope a pasted token misses).
    private func answer(_ request: URLRequest, ignoring: Set<String> = []) async throws -> [String: Any] {
        var request = request
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw NookError(tr("chats.slack.rateLimited"), kind: .rateLimited) }
        if code == 401 { throw NookError(tr("chats.slack.signInAgain"), kind: .auth) }
        guard (200..<300).contains(code), let json = ChatJSON.object(data) else { throw NookError("Slack: HTTP \(code)") }
        // A lost sign-in says so as one, as Teams and Snapchat do: the read stops at once and Settings asks to sign in.
        if SlackData.signedOut(json) { throw NookError(tr("chats.slack.signInAgain"), kind: .auth) }
        if let error = SlackData.error(json), !ignoring.contains((json["error"] as? String) ?? "") {
            throw NookError(tr("chats.slack.refused", error))
        }
        return json
    }

    // MARK: Writing

    /// Whether Nook can write in the chat it shows as `name`: one of the conversations it reads from Slack.
    func canSend(name: String) -> Bool { isReady && conversation(name) != nil }

    /// What can go besides text: every kind of file (Slack keeps each as a file), and a place or a contact card as
    /// text. Slack has no polls of its own.
    var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.noPolls }

    /// Sends what you typed to the chat Nook shows as `name`; as an answer to `replyTo` (a message's id in Nook) it goes
    /// in that message's thread and to the conversation too, so it shows there as an answer. The chat shows it at the
    /// next read, which comes at once.
    func send(text: String, to name: String, replyTo: String? = nil) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        let (auth, conversation) = try target(name)
        let thread = replyTo.flatMap { threadTS(answering: $0, in: conversation, name: name) }
        _ = try await post("chat.postMessage", SlackData.postFields(channel: conversation.id, text: body, thread: thread), auth: auth)
        changed(conversation)
    }

    /// Sends a file (with its caption) as Slack's own app does: Slack gives an address for its bytes, they go there,
    /// and Slack then shares it in the conversation (in the thread of `replyTo` when it answers a message). A place or
    /// a contact card goes as text; a poll cannot go.
    func send(_ outgoing: ChatOutgoing, to name: String, replyTo: String? = nil) async throws {
        let file: ChatAttachment
        switch outgoing {
        case .file(let attachment): file = attachment
        case .poll: throw NookError(tr("chat.compose.unsupported"))
        case .location, .contact:
            try await send(text: outgoing.text, to: name, replyTo: replyTo)
            return
        }
        guard !file.tooLarge, let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
            throw NookError(tr("chat.compose.tooLarge", file.name))
        }
        let (auth, conversation) = try target(name)
        let thread = replyTo.flatMap { threadTS(answering: $0, in: conversation, name: name) }
        let ticket = try await post("files.getUploadURLExternal", ["filename": file.name, "length": String(data.count)], auth: auth)
        guard let upload = SlackData.uploadTarget(ticket) else { throw NookError(tr("chat.compose.notSent")) }
        var request = Self.request(upload.url, auth: auth)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (_, response) = try await ConnectorHTTP.session(timeout: request.timeoutInterval).data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw NookError(tr("chats.slack.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(code) else { throw NookError(tr("chats.slack.refused", "HTTP \(code)")) }
        _ = try await post("files.completeUploadExternal", SlackData.completeFields(
            channel: conversation.id, file: upload.file, title: file.name, caption: file.caption, thread: thread), auth: auth)
        changed(conversation)
    }

    /// Puts your emoji on a message (its id in Nook) of the chat Nook shows as `name`, or takes it back when it is
    /// yours already (`mine`). Slack names its emoji; one Nook knows no name of cannot go.
    func react(_ emoji: String, to message: String, in name: String, mine: Bool) async throws {
        let (auth, conversation) = try target(name)
        guard let ts = SlackData.ts(of: message, conversation: conversation.id),
              let shortcode = SlackData.shortcode(emoji: emoji) else { throw NookError(tr("chat.react.notInApp", "Slack")) }
        let fields = ["channel": conversation.id, "timestamp": ts, "name": shortcode]
        if mine {
            _ = try await post("reactions.remove", fields, auth: auth, ignoring: ["no_reaction"])
        } else {
            _ = try await post("reactions.add", fields, auth: auth, ignoring: ["already_reacted"])
        }
        changed(conversation, ts: ts)
    }

    /// Changes the text of your message (its id in Nook) for everyone.
    func edit(_ message: String, in name: String, to text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        let (auth, conversation) = try target(name)
        guard let ts = SlackData.ts(of: message, conversation: conversation.id) else { throw NookError(tr("chat.compose.unsupported")) }
        _ = try await post("chat.update", ["channel": conversation.id, "ts": ts, "text": SlackData.escape(body)], auth: auth)
        changed(conversation, ts: ts)
    }

    /// Deletes your message (its id in Nook) for everyone; the next read drops it from the chat.
    func delete(_ message: String, in name: String) async throws {
        let (auth, conversation) = try target(name)
        guard let ts = SlackData.ts(of: message, conversation: conversation.id) else { throw NookError(tr("chat.compose.unsupported")) }
        // Deleted already (in Slack itself) is what was asked.
        _ = try await post("chat.delete", ["channel": conversation.id, "ts": ts], auth: auth, ignoring: ["message_not_found"])
        gone[conversation.id, default: []].append(message)
        changed(conversation)
    }

    /// Tells Slack you read the chat Nook shows as `name`, up to its newest message, so Slack no longer shows it unread.
    func markRead(name: String) async throws {
        let (auth, conversation) = try target(name)
        let latest = try await call("conversations.history", ["channel": conversation.id, "limit": "1"], auth: auth)
        guard let ts = SlackData.newestTS(latest) else { return }
        _ = try await post("conversations.mark", ["channel": conversation.id, "ts": ts], auth: auth)
    }

    /// What Slack is asked with, and the conversation behind the chat Nook shows as `name`.
    private func target(_ name: String) throws -> (SlackData.Auth, SlackData.Conversation) {
        guard let auth = Self.auth, let conversation = conversation(name) else { throw NookError(tr("chat.action.failed")) }
        return (auth, conversation)
    }

    /// The thread an answer to `id` (a message's id in Nook) goes in: the thread's first message's `ts`. Slack's threads
    /// are one level deep, so an answer to an answer goes in the same thread. Nil for a message Slack did not bring
    /// (one only its notification showed): the text then goes as a message of its own.
    private func threadTS(answering id: String, in conversation: SlackData.Conversation, name: String) -> String? {
        guard let ts = SlackData.ts(of: id, conversation: conversation.id) else { return nil }
        let answered = ChatCaptureService.shared.loadedInbox.threads[ChatInbox.key(app: app, chat: name)]?.messages.first { $0.id == id }
        return answered?.quote?.id.flatMap { SlackData.ts(of: $0, conversation: conversation.id) } ?? ts
    }

    /// After a change from Nook: the conversation is read at once, with the message `ts` (one you changed) read again.
    private func changed(_ conversation: SlackData.Conversation, ts: String? = nil) {
        stale[conversation.id, default: []].formUnion(ts.map { [$0] } ?? [])
        active[conversation.id] = max(active[conversation.id] ?? 0, Date().timeIntervalSince1970)
        ChatCaptureService.shared.readSoon(app)
    }
}
