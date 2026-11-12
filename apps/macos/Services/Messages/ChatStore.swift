import Foundation
import SQLite3

/// Every chat message Nook has seen, from every app, in one SQLite file (`chats.sqlite`): the one place the Chats tab,
/// scrolling back and search read from. Built the way WhatsApp, Signal and Telegram keep their histories small and fast:
///
/// - **One row per message**, its text stored once as plain text. Only the fields most messages lack (a file, a poll,
///   reactions, receipts) go into a small JSON blob, and only when there is one; files themselves never go in here.
/// - **Paging by key, never by offset**: `message_page (chat, at)` (the rowid breaks ties) answers "the 50 before this
///   one" with one index lookup however long a chat is.
/// - **A contentless trigram index** (`message_search`) finds any piece of text of three or more characters, as the
///   Chats tab and Search everything match ("ploeg" in "voetbalploeg"), without keeping a second copy of the text.
/// - **Incremental vacuum**, WAL with a bounded log, and `PRAGMA optimize` when idle keep the file as small as what it
///   holds.
///
/// The inbox in memory (`ChatInbox`) holds each chat's newest messages; this holds all of them. `ChatArchive` runs it off
/// the main thread. Not thread-safe by itself: one connection per queue.
final class ChatStore {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The trigram index can be used (FTS5 with its trigram tokenizer is there); without it search scans.
    private(set) var searchAvailable = false

    private static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS chat (
            id INTEGER PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            app TEXT NOT NULL,
            shown INTEGER NOT NULL DEFAULT 1,
            complete INTEGER NOT NULL DEFAULT 0,
            meta BLOB
        );
        CREATE TABLE IF NOT EXISTS message (
            id INTEGER PRIMARY KEY,
            chat INTEGER NOT NULL,
            ext TEXT NOT NULL,
            at REAL NOT NULL,
            mine INTEGER,
            sender TEXT,
            text TEXT,
            extra BLOB,
            UNIQUE (chat, ext)
        );
        CREATE INDEX IF NOT EXISTS message_page ON message (chat);
        CREATE TABLE IF NOT EXISTS message_version (
            message INTEGER NOT NULL,
            at REAL NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS message_version_of ON message_version (message);
        CREATE TABLE IF NOT EXISTS state (
            key TEXT PRIMARY KEY,
            value BLOB
        ) WITHOUT ROWID;
        """,
        // Pages by time, the rowid breaking ties: a message whose second was full took a later id than one of the next
        // second, and only `at` keeps them in the order they were sent.
        """
        DROP INDEX IF EXISTS message_page;
        CREATE INDEX message_page ON message (chat, at);
        """,
    ]

    /// The first failure while the store sets itself up, for `SQLiteRecovery` to tell damage from other trouble.
    private var setupFailure: Int32 = SQLITE_OK

    /// Opens (or creates) the archive. A damaged file is moved aside and a fresh one made (`SQLiteRecovery`); nil when
    /// there is no file to use this session.
    init?(url: URL, readOnly: Bool = false, incidents: DatabaseIncidents = .shared) {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        if readOnly {
            // A second connection to the file the writer already opened (and set aside if it had to): never moves it.
            guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            sqlite3_busy_timeout(db, 5_000)
            exec("PRAGMA temp_store = MEMORY;")
            exec("PRAGMA cache_size = -4000;")
            searchAvailable = (try? scalar("SELECT 1 FROM sqlite_master WHERE name = 'message_search'")) != nil
            return
        }
        db = SQLiteRecovery.open(url, flags: flags, incidents: incidents) { handle in
            db = handle
            setupFailure = SQLITE_OK
            sqlite3_busy_timeout(handle, 5_000)
            exec("PRAGMA temp_store = MEMORY;")
            exec("PRAGMA cache_size = -4000;")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Before the first table, or it has no effect: freed pages can be given back to the disk a few at a time.
            exec("PRAGMA auto_vacuum = INCREMENTAL;")
            exec("PRAGMA journal_mode = WAL;")
            exec("PRAGMA synchronous = NORMAL;")
            // The write-ahead log shrinks back to this after a checkpoint instead of keeping its largest size.
            exec("PRAGMA journal_size_limit = 8388608;")
            setupFailure = SQLITE_OK
            guard migrate() else { return setupFailure == SQLITE_OK ? SQLITE_ERROR : setupFailure }
            return SQLITE_OK
        }
        guard db != nil else { return nil }
        searchAvailable = exec(Self.searchSchema(contentless: true)) || exec(Self.searchSchema(contentless: false))
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    /// Contentless (SQLite 3.43+): the index keeps no copy of the text, only what finds it. An older SQLite keeps one.
    /// Without positions (`detail = none`), a fraction of the size: a word is asked for as all of its trigrams, and what
    /// that finds is checked against the message itself (`ChatHistorySearch.matches`).
    private static func searchSchema(contentless: Bool) -> String {
        "CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(body, tokenize = 'trigram', detail = none"
            + (contentless ? ", content = '', contentless_delete = 1" : "") + ");"
    }

    private func migrate() -> Bool {
        let version = Int((try? scalar("PRAGMA user_version")) ?? 0)
        for (index, sql) in Self.migrations.enumerated() where index >= version {
            guard transaction({ exec(sql) && exec("PRAGMA user_version = \(index + 1);") }) else { return false }
        }
        return true
    }

    // MARK: Rows

    /// What a message keeps beyond the columns: the fields most messages lack. Every stored field of `InboxMessage`
    /// is a column or here (`ChatStoreTests` fails when one is added to neither).
    struct Extra: Codable, Equatable {
        var media: ChatMedia?
        var poll: ChatPoll?
        var receipt: ChatReceipt?
        var readers: [ChatReader]?
        var reactions: [InboxReaction]?
        var quote: InboxQuote?
        var mentionsMe: Bool?
        var senderID: String?
        var edited: Bool?
        var deleted: Bool?
        var membership: ChatMembership?
        var groupChange: ChatGroupChange?

        /// Short: these keys are in every row that has an extra.
        enum CodingKeys: String, CodingKey {
            case media = "f", poll = "p", receipt = "r", readers = "w", reactions = "e", quote = "q", mentionsMe = "m"
            case senderID = "s", edited = "d", deleted = "x", membership = "b", groupChange = "g"
        }

        init(_ message: InboxMessage) {
            media = message.media
            poll = message.poll
            receipt = message.receipt
            readers = message.readers
            reactions = message.reactions
            quote = message.quote
            mentionsMe = message.mentionsMe
            senderID = message.senderID
            edited = message.edited
            deleted = message.deleted
            membership = message.membership
            groupChange = message.groupChange
        }

        private static let none = Extra(InboxMessage(id: "", text: "", date: .distantPast))
        var isEmpty: Bool { self == Self.none }

        func apply(to message: inout InboxMessage) {
            message.media = media
            message.poll = poll
            message.receipt = receipt
            message.readers = readers
            message.reactions = reactions
            message.quote = quote
            message.mentionsMe = mentionsMe
            message.senderID = senderID
            message.edited = edited
            message.deleted = deleted
            message.membership = membership
            message.groupChange = groupChange
        }
    }

    /// What the search index holds for a message: its line and who wrote it, folded the way search compares.
    static func searchBody(_ message: InboxMessage) -> String {
        SearchText.fold(message.summary + " " + message.sender)
    }

    private static let messageColumns = "m.id, m.ext, m.at, m.mine, m.sender, m.text, m.extra"

    /// A message from a row whose columns start at `first` in the order of `messageColumns`.
    private func message(_ stmt: OpaquePointer?, from first: Int32 = 0) -> InboxMessage? {
        guard let ext = text(stmt, first + 1) else { return nil }
        var message = InboxMessage(id: ext, sender: text(stmt, first + 4) ?? "", text: text(stmt, first + 5) ?? "",
                                   date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, first + 2)))
        if sqlite3_column_type(stmt, first + 3) != SQLITE_NULL { message.fromMe = sqlite3_column_int(stmt, first + 3) != 0 }
        if let data = blob(stmt, first + 6), let extra = try? decoder.decode(Extra.self, from: data) { extra.apply(to: &message) }
        return message
    }

    // MARK: Writing

    /// The id of the chat row for `thread`, made when it is not there; its description (`meta`) is written too.
    @discardableResult
    func saveChat(_ thread: InboxThread) -> Int64? {
        var description = thread
        description.messages = []
        guard let meta = (try? encoder.encode(description)).map(Self.packed) else { return nil }
        let sql = """
            INSERT INTO chat (key, app, shown, meta) VALUES (?, ?, 1, ?)
            ON CONFLICT (key) DO UPDATE SET app = excluded.app, shown = 1, meta = excluded.meta RETURNING id
            """
        guard let stmt = prepared(sql) else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, thread.id, -1, transient)
        sqlite3_bind_text(stmt, 2, thread.app, -1, transient)
        bind(meta, to: stmt, at: 3)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    func chatID(_ key: String) -> Int64? {
        guard let stmt = prepared("SELECT id FROM chat WHERE key = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    /// A message's row id: its second times 16, plus a slot. Rows then sort by time on their own, so the newest matches
    /// come straight out of the search index, as TDLib numbers messages. Small
    /// steps between ids keep the index small too: it stores each row as the step from the one before. Two messages of
    /// one second take the next free id (`maxSpill` at most); a row keeps the id it got first.
    static func rowID(_ date: Date, slot: Int64 = 0) -> Int64 {
        let seconds = date.timeIntervalSinceReferenceDate.rounded(.down)
        return Int64(max(-100_000_000_000, min(100_000_000_000, seconds))) * slots + slot
    }

    static let slots: Int64 = 16
    /// How far past its own second a message's id may go when its second is full.
    static let maxSpill: Int64 = 256

    /// Writes a message of a chat, over the one with its id. `reindex` false leaves the search index as it is (only its
    /// receipts or reactions changed).
    @discardableResult
    func saveMessage(_ message: InboxMessage, chat: Int64, reindex: Bool = true) -> Bool {
        let sql = """
            INSERT INTO message (id, chat, ext, at, mine, sender, text, extra) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (chat, ext) DO UPDATE SET at = excluded.at, mine = excluded.mine, sender = excluded.sender,
                text = excluded.text, extra = excluded.extra
            RETURNING id
            """
        guard let stmt = prepared(sql) else { return false }
        let extra = Extra(message)
        let extraData = extra.isEmpty ? nil : try? encoder.encode(extra)
        // A slot from the id, so two messages of one second rarely meet; when they do, the next free id.
        let first = Self.rowID(message.date, slot: Int64(Self.hash(message.id) % UInt64(Self.slots)))
        var id: Int64?
        for attempt in 0...Self.maxSpill {
            sqlite3_bind_int64(stmt, 2, chat)
            // Every id near its second taken: any free one. Paging goes by `at`, so only search sees it out of place.
            if attempt == Self.maxSpill { sqlite3_bind_null(stmt, 1) } else { sqlite3_bind_int64(stmt, 1, first + attempt) }
            sqlite3_bind_text(stmt, 3, message.id, -1, transient)
            sqlite3_bind_double(stmt, 4, message.date.timeIntervalSinceReferenceDate)
            if let fromMe = message.fromMe { sqlite3_bind_int(stmt, 5, fromMe ? 1 : 0) } else { sqlite3_bind_null(stmt, 5) }
            bindOptional(message.sender, to: stmt, at: 6)
            bindOptional(message.text, to: stmt, at: 7)
            if let extraData { bind(extraData, to: stmt, at: 8) } else { sqlite3_bind_null(stmt, 8) }
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { id = sqlite3_column_int64(stmt, 0) }
            sqlite3_reset(stmt)
            if id != nil || step != SQLITE_CONSTRAINT { break }
        }
        guard let id else { return false }
        guard reindex, searchAvailable else { return true }
        return index(id, Self.searchBody(message))
    }

    /// A chat's description, compressed (LZFSE) when that pays: its people, pictures and profile are JSON that shrinks to
    /// a third. The first byte says which: JSON starts with "{".
    static func packed(_ json: Data) -> Data {
        #if canImport(Darwin)
        if json.count > 128, let small = try? (json as NSData).compressed(using: .lzfse) as Data, small.count + 1 < json.count {
            return Data([0x01]) + small
        }
        #endif
        return json
    }

    static func unpacked(_ data: Data) -> Data {
        #if canImport(Darwin)
        if data.first == 0x01, let json = try? (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data { return json }
        #endif
        return data
    }

    /// FNV-1a, the same on every launch.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func index(_ id: Int64, _ body: String) -> Bool {
        guard let remove = prepared("DELETE FROM message_search WHERE rowid = ?") else { return false }
        sqlite3_bind_int64(remove, 1, id)
        let removed = sqlite3_step(remove) == SQLITE_DONE
        sqlite3_reset(remove)
        guard removed else { return false }
        guard !body.isEmpty, let insert = prepared("INSERT INTO message_search (rowid, body) VALUES (?, ?)") else { return true }
        defer { sqlite3_reset(insert) }
        sqlite3_bind_int64(insert, 1, id)
        sqlite3_bind_text(insert, 2, body, -1, transient)
        return sqlite3_step(insert) == SQLITE_DONE
    }

    // MARK: Edits and deletions

    /// The message stored under its id in the app, in a chat.
    func stored(_ id: String, chat: Int64) -> (row: Int64, message: InboxMessage)? {
        guard let stmt = prepared("SELECT \(Self.messageColumns) FROM message m WHERE m.chat = ? AND m.ext = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let message = message(stmt) else { return nil }
        return (sqlite3_column_int64(stmt, 0), message)
    }

    /// A change of its text that its app calls an edit, or a deletion that took someone else's text away: the text it had
    /// is kept. Your own deleted message keeps nothing of what it said, as it shows nothing of it.
    static func isEdit(from old: InboxMessage, to new: InboxMessage) -> Bool {
        guard !old.text.isEmpty, old.text != new.text, !old.isDeleted else { return false }
        return new.isDeleted ? !old.isMine : new.isEdited
    }

    /// Keeps the text `old` had as one of its earlier versions, dated by when it was replaced.
    private func keepVersion(of old: InboxMessage, chat: Int64, now: Date = Date()) -> Bool {
        guard let row = stored(old.id, chat: chat)?.row else { return true }
        return execute("INSERT INTO message_version (message, at, text) VALUES (?, ?, ?)",
                       [row, Int64(now.timeIntervalSinceReferenceDate), old.text])
    }

    /// The texts a message had before it was edited (or deleted), oldest first, with when each was replaced.
    func versions(_ id: String, inChat key: String) -> [ChatVersion] {
        guard let chat = chatID(key), let row = stored(id, chat: chat)?.row,
              let stmt = prepared("SELECT at, text FROM message_version WHERE message = ? ORDER BY rowid") else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, row)
        var versions: [ChatVersion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            versions.append(ChatVersion(replaced: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)),
                                        text: text(stmt, 1) ?? ""))
        }
        return versions
    }

    /// What a read says of a message the archive may hold already, over what it holds, under the rules the inbox has for
    /// the messages it shows (`ChatInbox.merge`): a deleted one stays deleted, keeping what Nook had of someone else's;
    /// an edit brings the new text and the mark; a read that brings less (a preview, no file) keeps what was there.
    static func merged(_ old: InboxMessage, with new: InboxMessage) -> InboxMessage {
        if old.isDeleted { return old }
        if new.isDeleted { return old.withdrawn() }
        var message = old
        if new.isEdited { message.edited = true }
        if !new.text.isEmpty { message.text = new.text }
        if !new.sender.isEmpty { message.sender = new.sender }
        if let sender = new.senderID { message.senderID = sender }
        if let media = ChatInbox.media(new.media, keeping: old.media) { message.media = media }
        if let poll = new.poll { message.poll = poll }
        if let quote = new.quote { message.quote = quote }
        if let receipt = new.receipt { message.receipt = old.receipt.map { $0.advanced(to: receipt) } ?? receipt }
        if let readers = new.readers { message.readers = readers }
        if let mentions = new.mentionsMe { message.mentionsMe = mentions }
        if let reactions = new.reactions { message.reactions = reactions }
        if message.fromMe == nil { message.fromMe = new.fromMe }
        return message
    }

    /// Writes what a read brought of a message outside what the inbox shows: new, it is kept as it came (a deleted one
    /// as `withdrawn()`); known, the two are put together (`merged`), keeping the text an edit or deletion replaced.
    @discardableResult
    func saveMerged(_ incoming: InboxMessage, chat: Int64) -> Bool {
        guard let known = stored(incoming.id, chat: chat) else {
            return saveMessage(incoming.isDeleted ? incoming.withdrawn() : incoming, chat: chat)
        }
        let merged = Self.merged(known.message, with: incoming)
        guard merged != known.message else { return true }
        if Self.isEdit(from: known.message, to: merged), !keepVersion(of: known.message, chat: chat) { return false }
        return saveMessage(merged, chat: chat, reindex: Self.searchBody(merged) != Self.searchBody(known.message))
    }

    /// A page of a chat's history as its app has it now, laid beside what is stored of the same stretch (`ChatReconcile`):
    /// what Nook missed is added (a hole closes), an edit brings the new text and keeps the old, and what the app no
    /// longer has (`absent`) or says it deleted is marked deleted, keeping someone else's text. A copy a notification
    /// left of a message the page has goes. How many of the page's messages were new here, or nil when the chat is not
    /// stored (removed meanwhile): a chat is never made here.
    func reconcile(_ page: ChatReconcile.Page, key: String) -> Int? {
        var fresh = 0
        let saved = transaction {
            guard let chat = chatID(key) else { return false }
            for message in page.messages {
                let known = stored(message.id, chat: chat)?.message
                if known == nil { fresh += 1 }
                guard saveMerged(ChatReconcile.marked(message, over: known, textChangeIsEdit: page.textChangeIsEdit), chat: chat)
                else { return false }
            }
            var gone = page.deleted
            var copies: [String] = []
            if let low = page.low {
                // A little before the page for what the app keeps as deleted (its copy may be dated a moment later); only
                // what lies past the page's oldest message for absence.
                let stretch = between(chat: chat, after: low.addingTimeInterval(-ChatReconcile.sameMoment - ChatBackfill.instant),
                                      before: page.high)
                let inside = stretch.filter { $0.date > low }
                copies = ChatReconcile.copies(inside, of: page.messages)
                if page.omitsDeleted { gone += ChatReconcile.absent(inside, from: page.messages).filter { !copies.contains($0) } }
                let ids = Set(page.messages.map(\.id))
                gone += ChatReconcile.gone(stretch.filter { !ids.contains($0.id) }, like: page.gone)
            }
            return withdraw(gone, chat: chat) && deleteMessages(copies, chat: chat)
        }
        return saved ? fresh : nil
    }

    /// A chat's stored messages after `after` and before `before` (both left out), oldest first.
    func between(_ key: String, after: Date, before: Date) -> [InboxMessage] {
        guard let chat = chatID(key) else { return [] }
        return between(chat: chat, after: after, before: before)
    }

    private func between(chat: Int64, after: Date, before: Date) -> [InboxMessage] {
        let sql = "SELECT \(Self.messageColumns) FROM message m WHERE m.chat = ? AND m.at > ? AND m.at < ? ORDER BY m.at, m.id"
        guard let stmt = prepared(sql) else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        sqlite3_bind_double(stmt, 2, after.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(stmt, 3, before.timeIntervalSinceReferenceDate)
        var messages: [InboxMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let message = message(stmt) { messages.append(message) } }
        return messages
    }

    /// How many messages of a chat are stored from `date` on: how far back from the newest a page by count starts.
    func count(_ key: String, since date: Date) -> Int {
        Int((try? scalar("SELECT COUNT(*) FROM message WHERE chat = (SELECT id FROM chat WHERE key = ?) AND at >= ?",
                         [key, date.timeIntervalSinceReferenceDate])) ?? 0)
    }

    /// A message its app says was edited, as far as the archive holds it: the new text (nil when the app does not say
    /// it), marked "Edited", the old one kept.
    @discardableResult
    func edit(_ id: String, chat: Int64, to text: String?) -> Bool {
        guard let known = stored(id, chat: chat) else { return true }
        var incoming = known.message
        if let text { incoming.text = text }
        incoming.edited = true
        return saveMerged(incoming, chat: chat)
    }

    /// Messages its app says were deleted for everyone, by their id, as far as the archive holds them.
    @discardableResult
    func withdraw(_ ids: [String], chat: Int64) -> Bool {
        ids.allSatisfy { id in
            guard let known = stored(id, chat: chat), !known.message.isDeleted else { return true }
            let gone = known.message.withdrawn()
            if Self.isEdit(from: known.message, to: gone), !keepVersion(of: known.message, chat: chat) { return false }
            return saveMessage(gone, chat: chat, reindex: Self.searchBody(gone) != Self.searchBody(known.message))
        }
    }

    /// Removes these messages (by their id in the app) from a chat, with what the index held of them.
    @discardableResult
    func deleteMessages(_ ids: [String], chat: Int64) -> Bool {
        guard !ids.isEmpty else { return true }
        for id in ids {
            guard let find = prepared("SELECT id FROM message WHERE chat = ? AND ext = ?") else { return false }
            sqlite3_bind_int64(find, 1, chat)
            sqlite3_bind_text(find, 2, id, -1, transient)
            let row = sqlite3_step(find) == SQLITE_ROW ? sqlite3_column_int64(find, 0) : nil
            sqlite3_reset(find)
            guard let row else { continue }
            if searchAvailable, !execute("DELETE FROM message_search WHERE rowid = ?", [row]) { return false }
            guard execute("DELETE FROM message_version WHERE message = ?", [row]),
                  execute("DELETE FROM message WHERE id = ?", [row]) else { return false }
        }
        return true
    }

    /// Removes every message of a chat; `keepChat` leaves what Nook knows of the chat itself.
    @discardableResult
    func deleteChat(_ key: String, keepChat: Bool = false) -> Bool {
        guard let chat = chatID(key) else { return true }
        if searchAvailable, !execute("DELETE FROM message_search WHERE rowid IN (SELECT id FROM message WHERE chat = ?)", [chat]) {
            return false
        }
        guard execute("DELETE FROM message_version WHERE message IN (SELECT id FROM message WHERE chat = ?)", [chat]),
              execute("DELETE FROM message WHERE chat = ?", [chat]) else { return false }
        return keepChat || execute("DELETE FROM chat WHERE id = ?", [chat])
    }

    /// Everything goes (the inbox was cleared).
    @discardableResult
    func deleteAll() -> Bool {
        transaction {
            (!searchAvailable || exec("DELETE FROM message_search;"))
                && exec("DELETE FROM message_version; DELETE FROM message; DELETE FROM chat; DELETE FROM state WHERE key = 'inbox';")
        }
    }

    /// A chat the inbox no longer shows (quiet for too long, or beyond the most it shows): its messages stay, for search
    /// and for when it comes back.
    func hideChat(_ key: String) {
        execute("UPDATE chat SET shown = 0 WHERE key = ?", [key])
    }

    /// The chat's start in its app was reached: nothing older is asked for again.
    func markComplete(_ key: String, _ complete: Bool = true) {
        execute("UPDATE chat SET complete = ? WHERE key = ?", [Int64(complete ? 1 : 0), key])
    }

    func setState(_ key: String, _ value: Data) {
        guard let stmt = prepared("INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)") else { return }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        bind(value, to: stmt, at: 2)
        sqlite3_step(stmt)
    }

    func state(_ key: String) -> Data? {
        guard let stmt = prepared("SELECT value FROM state WHERE key = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? blob(stmt, 0) : nil
    }

    // MARK: The inbox

    /// Writes what changed between two states of the inbox, in one transaction. A message that left a chat's window
    /// because it got older than what the chat shows stays here; one that went from within that window (moved to its
    /// group, or replaced under another id) goes. A chat that left the inbox stays for search unless you removed it.
    @discardableResult
    func apply(from old: ChatInbox?, to new: ChatInbox) -> Bool {
        transaction {
            if old.map(Self.inboxState) != Self.inboxState(new), let state = try? encoder.encode(Self.inboxState(new)) {
                setState("inbox", state)
            }
            for (key, thread) in new.threads {
                let before = old?.threads[key]
                guard before != thread else { continue }
                guard let chat = Self.description(of: before) == Self.description(of: thread) ? chatID(key) ?? saveChat(thread)
                    : saveChat(thread) else { return false }
                let known = Dictionary((before?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for message in thread.messages {
                    let was = known[message.id]
                    guard was != message else { continue }
                    if let was, Self.isEdit(from: was, to: message), !keepVersion(of: was, chat: chat) { return false }
                    let reindex = was.map { Self.searchBody($0) != Self.searchBody(message) } ?? true
                    guard saveMessage(message, chat: chat, reindex: reindex) else { return false }
                }
                if let before, let first = thread.messages.first?.date {
                    guard deleteMessages(Self.removedFromWindow(before.messages, now: thread.messages, first: first), chat: chat)
                    else { return false }
                }
            }
            // Written from nothing (the first save, or after a failed one): every chat it no longer has is settled.
            if old == nil, !settleLeft(new) { return false }
            let left = (old?.threads.keys).map { Set($0).subtracting(new.threads.keys) } ?? []
            guard !left.isEmpty else { return true }
            let everywhere = Set(new.threads.values.flatMap { $0.messages.map(\.id) })
            for key in left {
                if let removed = new.removed?[key], removed != old?.removed?[key] {
                    guard deleteChat(key) else { return false }
                    continue
                }
                hideChat(key)
                // Its messages that now show in another chat (a group took back what its notifications put here).
                if let chat = chatID(key), let moved = old?.threads[key]?.messages.map(\.id).filter(everywhere.contains),
                   !deleteMessages(moved, chat: chat) {
                    return false
                }
            }
            return true
        }
    }

    /// The messages that went from within a chat's window, not off its old end: those before the oldest one it still
    /// shows (by place, so one of the same second as the new first one counts as trimmed) stay; any newer than its new
    /// first message, or after one it still shows, went.
    static func removedFromWindow(_ before: [InboxMessage], now: [InboxMessage], first: Date) -> [String] {
        let kept = Set(now.map(\.id))
        let firstKept = before.firstIndex { kept.contains($0.id) }
        return before.enumerated().filter { index, message in
            !kept.contains(message.id) && (message.date > first || firstKept.map { index > $0 } ?? false)
        }.map(\.element.id)
    }

    /// Chats that are not in the inbox any more, as a save from nothing finds them: hidden, or gone when you removed them.
    private func settleLeft(_ inbox: ChatInbox) -> Bool {
        guard let stmt = prepared("SELECT key FROM chat WHERE shown = 1") else { return false }
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let key = text(stmt, 0) { keys.append(key) } }
        sqlite3_reset(stmt)
        for key in keys where inbox.threads[key] == nil {
            if inbox.removed?[key] != nil {
                guard deleteChat(key) else { return false }
            } else {
                hideChat(key)
            }
        }
        return true
    }

    /// The inbox without its chats: what it keeps about itself.
    private static func inboxState(_ inbox: ChatInbox) -> ChatInbox {
        var state = inbox
        state.threads = [:]
        return state
    }

    private static func description(of thread: InboxThread?) -> InboxThread? {
        guard var thread else { return nil }
        thread.messages = []
        return thread
    }

    /// The inbox as it was written: every chat it shows with its newest `window` messages, and when each chat's oldest
    /// stored message is. Nil when nothing was ever written.
    func loadInbox(window: Int) -> (inbox: ChatInbox, oldest: [String: Date])? {
        guard let state = state("inbox"), var inbox = try? decoder.decode(ChatInbox.self, from: state) else { return nil }
        inbox.threads = [:]
        guard let chats = prepared("SELECT id, key, meta FROM chat WHERE shown = 1") else { return nil }
        var rows: [(id: Int64, key: String, meta: Data)] = []
        while sqlite3_step(chats) == SQLITE_ROW {
            if let key = text(chats, 1), let meta = blob(chats, 2) { rows.append((sqlite3_column_int64(chats, 0), key, meta)) }
        }
        sqlite3_reset(chats)
        for row in rows {
            guard var thread = try? decoder.decode(InboxThread.self, from: Self.unpacked(row.meta)) else { continue }
            thread.id = row.key
            // Everything older is here: scrolling back reads it again, so no chat holds more than its window in memory.
            thread.capacity = nil
            thread.messages = newest(chat: row.id, limit: window)
            inbox.threads[row.key] = thread
        }
        return (inbox, oldestDates())
    }

    /// When each chat's oldest stored message is, by its key.
    func oldestDates() -> [String: Date] {
        let sql = "SELECT c.key, (SELECT MIN(at) FROM message WHERE chat = c.id) FROM chat c"
        guard let stmt = prepared(sql) else { return [:] }
        defer { sqlite3_reset(stmt) }
        var dates: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let key = text(stmt, 0), sqlite3_column_type(stmt, 1) != SQLITE_NULL else { continue }
            dates[key] = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
        }
        return dates
    }

    /// A chat as written (shown or not), with its newest `window` messages: for one that left the inbox and comes back.
    func thread(_ key: String, window: Int) -> InboxThread? {
        guard let stmt = prepared("SELECT id, meta FROM chat WHERE key = ?") else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        let row = sqlite3_step(stmt) == SQLITE_ROW ? (sqlite3_column_int64(stmt, 0), blob(stmt, 1)) : nil
        sqlite3_reset(stmt)
        guard let row, let meta = row.1, var thread = try? decoder.decode(InboxThread.self, from: Self.unpacked(meta)) else { return nil }
        thread.id = key
        thread.capacity = nil
        thread.messages = newest(chat: row.0, limit: window)
        return thread
    }

    private func newest(chat: Int64, limit: Int) -> [InboxMessage] {
        let sql = "SELECT \(Self.messageColumns) FROM message m WHERE m.chat = ? ORDER BY m.at DESC, m.id DESC LIMIT ?"
        guard let stmt = prepared(sql) else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var messages: [InboxMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let message = message(stmt) { messages.append(message) } }
        return messages.reversed()
    }

    // MARK: Reading

    /// The `limit` messages of a chat before `date` (and those at `date` not in `excluding`), oldest first: one index
    /// lookup, however long the chat.
    func older(_ key: String, before date: Date, excluding: Set<String> = [], limit: Int) -> [InboxMessage] {
        guard let chat = chatID(key) else { return [] }
        let sql = """
            SELECT \(Self.messageColumns) FROM message m WHERE m.chat = ? AND m.at <= ?
            ORDER BY m.at DESC, m.id DESC LIMIT ?
            """
        guard let stmt = prepared(sql) else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        sqlite3_bind_double(stmt, 2, date.timeIntervalSinceReferenceDate)
        sqlite3_bind_int(stmt, 3, Int32(limit + excluding.count))
        var messages: [InboxMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW, messages.count < limit {
            guard let message = message(stmt), !excluding.contains(message.id) else { continue }
            messages.append(message)
        }
        return messages.reversed()
    }

    /// The oldest message stored for a chat: where a backfill goes on from.
    func oldest(_ key: String) -> InboxMessage? {
        guard let chat = chatID(key) else { return nil }
        let sql = "SELECT \(Self.messageColumns) FROM message m WHERE m.chat = ? ORDER BY m.at ASC, m.id ASC LIMIT 1"
        guard let stmt = prepared(sql) else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        return sqlite3_step(stmt) == SQLITE_ROW ? message(stmt) : nil
    }

    func isComplete(_ key: String) -> Bool {
        (try? scalar("SELECT complete FROM chat WHERE key = ?", [key])) == 1
    }

    func messageCount(_ key: String? = nil) -> Int {
        let count = key.map { try? scalar("SELECT COUNT(*) FROM message WHERE chat = (SELECT id FROM chat WHERE key = ?)", [$0]) }
            ?? (try? scalar("SELECT COUNT(*) FROM message"))
        return Int(count ?? 0)
    }

    /// One search hit: the chat (as written) and its matching messages, oldest first.
    struct Found: Sendable {
        var thread: InboxThread
        var messages: [InboxMessage]
    }

    /// The messages that hold any of `words` (folded, as `ChatHistorySearch` gives them), the newest `limit` per word,
    /// grouped by chat. Words of three characters or more go through the trigram index, newest first along its rowids
    /// (which follow time), so a common word costs no more than a rare one; shorter ones (and every word when the index
    /// is missing) scan the messages from the newest back until `limit` are found.
    func search(_ words: [String], limit: Int) -> [Found] {
        var byChat: [Int64: [InboxMessage]] = [:]
        var seen: Set<Int64> = []
        for word in words where !word.isEmpty {
            let hits = searchAvailable && word.count >= 3 ? indexed(word, limit: limit) : scanned(word, limit: limit)
            for hit in hits where seen.insert(hit.row).inserted { byChat[hit.chat, default: []].append(hit.message) }
        }
        return byChat.compactMap { chat, messages in
            guard let thread = describedThread(chat) else { return nil }
            return Found(thread: thread, messages: messages.sorted { $0.date < $1.date })
        }
    }

    private typealias Hit = (row: Int64, chat: Int64, message: InboxMessage)

    /// At most this many index rows are looked at per word: what a word finds beyond that is too old to matter.
    private static let searchBudget = 20_000

    private func indexed(_ word: String, limit: Int) -> [Hit] {
        // Every trigram of the word, each as a term of its own: the index keeps no positions.
        let characters = Array(word)
        let grams = Set((0...(characters.count - 3)).map { String(characters[$0..<$0 + 3]) })
        let query = grams.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
        let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? AND rowid < ? ORDER BY rowid DESC LIMIT ?"
        guard let stmt = prepared(sql) else { return [] }
        var hits: [Hit] = []
        var below = Int64.max
        var looked = 0
        let batch = max(limit * 4, 200)
        while hits.count < limit, looked < Self.searchBudget {
            sqlite3_bind_text(stmt, 1, query, -1, transient)
            sqlite3_bind_int64(stmt, 2, below)
            sqlite3_bind_int(stmt, 3, Int32(batch))
            var rows: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(sqlite3_column_int64(stmt, 0)) }
            sqlite3_reset(stmt)
            looked += rows.count
            for row in rows where hits.count < limit {
                if let hit = messageRow(row), ChatHistorySearch.matches(hit.message, [word]) { hits.append(hit) }
            }
            guard rows.count == batch, let last = rows.last else { break }
            below = last
        }
        return hits
    }

    private func scanned(_ word: String, limit: Int) -> [Hit] {
        let sql = "SELECT m.chat, \(Self.messageColumns) FROM message m ORDER BY m.id DESC"
        guard let stmt = prepared(sql) else { return [] }
        defer { sqlite3_reset(stmt) }
        var hits: [Hit] = []
        var looked = 0
        while hits.count < limit, looked < Self.searchBudget * 10, sqlite3_step(stmt) == SQLITE_ROW {
            looked += 1
            guard let message = message(stmt, from: 1), ChatHistorySearch.matches(message, [word]) else { continue }
            hits.append((sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 0), message))
        }
        return hits
    }

    private func messageRow(_ row: Int64) -> Hit? {
        guard let stmt = prepared("SELECT m.chat, \(Self.messageColumns) FROM message m WHERE m.id = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, row)
        guard sqlite3_step(stmt) == SQLITE_ROW, let message = message(stmt, from: 1) else { return nil }
        return (row, sqlite3_column_int64(stmt, 0), message)
    }

    private func describedThread(_ chat: Int64) -> InboxThread? {
        guard let stmt = prepared("SELECT key, meta FROM chat WHERE id = ?") else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int64(stmt, 1, chat)
        guard sqlite3_step(stmt) == SQLITE_ROW, let key = text(stmt, 0), let meta = blob(stmt, 1),
              var thread = try? decoder.decode(InboxThread.self, from: Self.unpacked(meta)) else { return nil }
        thread.id = key
        return thread
    }

    // MARK: Upkeep

    /// While Nook is idle: gives free pages back to the disk once they are a tenth of the file, merges the search
    /// index's segments a little, lets SQLite refresh what it knows of the tables, and empties the write-ahead log.
    func maintain() {
        if let free = try? scalar("PRAGMA freelist_count"), let pages = try? scalar("PRAGMA page_count"), pages > 0, free * 10 > pages {
            exec("PRAGMA incremental_vacuum;")
        }
        if searchAvailable { exec("INSERT INTO message_search (message_search, rank) VALUES ('merge', 64);") }
        exec("PRAGMA optimize;")
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// The file's size in bytes, as its pages count it.
    var fileBytes: Int64 {
        guard let pages = try? scalar("PRAGMA page_count"), let size = try? scalar("PRAGMA page_size") else { return 0 }
        return pages * size
    }

    // MARK: SQLite

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if setupFailure == SQLITE_OK { setupFailure = sqlite3_extended_errcode(db) }
            return false
        }
        return true
    }

    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        guard exec("BEGIN IMMEDIATE;") else { return false }
        if body(), exec("COMMIT;") { return true }
        exec("ROLLBACK;")
        return false
    }

    private struct Failed: Error {}

    private func scalar(_ sql: String, _ arguments: [Any] = []) throws -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failed() }
        bind(stmt, arguments)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failed() }
        return sqlite3_column_int64(stmt, 0)
    }

    @discardableResult
    private func execute(_ sql: String, _ arguments: [Any]) -> Bool {
        guard let stmt = prepared(sql) else { return false }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        bind(stmt, arguments)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// A statement prepared once and kept: the same few run for every message.
    private func prepared(_ sql: String) -> OpaquePointer? {
        if let stmt = statements[sql] { return stmt }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        statements[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ arguments: [Any]) {
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case let value as Int64: sqlite3_bind_int64(stmt, Int32(index + 1), value)
            case let value as Double: sqlite3_bind_double(stmt, Int32(index + 1), value)
            case let value as String: sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
            default: sqlite3_bind_null(stmt, Int32(index + 1))
            }
        }
    }

    private func bind(_ data: Data, to stmt: OpaquePointer?, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
    }

    private func bindOptional(_ value: String, to stmt: OpaquePointer?, at index: Int32) {
        if value.isEmpty { sqlite3_bind_null(stmt, index) } else { sqlite3_bind_text(stmt, index, value, -1, transient) }
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    private func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data? {
        let length = Int(sqlite3_column_bytes(stmt, column))
        guard length > 0, let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: length)
    }
}

/// A text a message had before it was edited or deleted, and when it was replaced: what "Edited" and "Deleted" open.
struct ChatVersion: Equatable, Sendable, Identifiable {
    var replaced: Date
    var text: String
    var id: String { "\(replaced.timeIntervalSinceReferenceDate)|\(text.hashValue)" }
}
