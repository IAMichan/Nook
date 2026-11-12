import Foundation
import SQLite3

/// Session timelines as an append-only log in SQLite (`runs.sqlite`, WAL).
///
/// Every change to a timeline is one new row, never a rewrite of what is already there:
/// - `event`: an event that was not in the timeline yet (its JSON);
/// - `update`: a new version of an event that is (same id, the whole event again: a streamed answer grows this way);
/// - `snapshot`: the whole timeline (a JSON list), written when events were removed or reordered and when a long log is
///   compacted. It stands in for every earlier row of that session, which are removed in the same transaction.
///
/// A timeline is read back by replaying its rows in `seq` order. A crash can lose at most the rows not yet written; it
/// never leaves a half-written file behind, because SQLite commits each batch atomically.
///
/// Its own file next to `runs.json` rather than a table in nook.sqlite: it belongs to the workspace folder `RunStore`
/// owns (tests and a second store use their own folder), its many small writes during streaming do not contend with the
/// audit log and memory, and it can be dropped or rebuilt without touching them.
final class RunEventLog {
    enum Kind: String {
        case event, update, snapshot
    }

    struct Row: Equatable {
        var seq: Int64
        var runID: UUID
        var kind: Kind
        var payload: Data
        var at: Date
    }

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Schema migrations; index + 1 is the version they bring the database to.
    private static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS run_events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS run_events_run ON run_events (run_id, seq);
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    ]

    /// The first failure while the log sets itself up, for `SQLiteRecovery` to tell damage from other trouble.
    private var setupFailure: Int32 = SQLITE_OK

    /// Opens (or creates) the log. A damaged file is moved aside and a fresh one made (`SQLiteRecovery`); nil when there
    /// is no file to use this session.
    /// - Parameter readOnly: a second connection to a log that exists, only for reading. With WAL it sees the last commit
    ///   and never waits for a write, nor a write for it. It never moves the file.
    init?(url: URL, readOnly: Bool = false, incidents: DatabaseIncidents = .shared) {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        if readOnly {
            guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            sqlite3_busy_timeout(db, 2_000)
            return
        }
        db = SQLiteRecovery.open(url, flags: flags, incidents: incidents) { handle in
            db = handle
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 2_000)
            exec("PRAGMA journal_mode = WAL;")
            // Durable across a crash of Nook; only a power cut can lose the last commits, never corrupt the file.
            exec("PRAGMA synchronous = NORMAL;")
            setupFailure = SQLITE_OK
            guard migrate() else { return setupFailure == SQLITE_OK ? SQLITE_ERROR : setupFailure }
            return SQLITE_OK
        }
        guard db != nil else { return nil }
        // The search index is extra: a SQLite without FTS5 or its trigram tokenizer only means search scans instead.
        dropSearchWithText()
        searchAvailable = exec(Self.searchSchema(contentless: true)) || exec(Self.searchSchema(contentless: false))
    }

    /// An index that kept its own copy of every event's text (as built before 2026-11-10), or the position of every
    /// trigram (before 2026-11-12), is dropped with its keys: searching only matches, so neither was ever read, and the
    /// positions made the index larger than the timelines themselves (273 MB against 39 MB on one Mac). `RunStore`
    /// builds it anew.
    @discardableResult
    private func dropSearchWithText() -> Bool {
        // An older SQLite cannot build the contentless index: it keeps the one it has (dropping it would repeat each launch).
        guard sqlite3_libversion_number() >= 3_043_000 else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE name = 'run_search'", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return false }
        let schema = String(cString: text)
        guard !schema.contains("content") || !schema.contains("detail") else { return false }
        sqlite3_finalize(stmt)
        stmt = nil
        return exec("DROP TABLE IF EXISTS run_search; DROP TABLE IF EXISTS run_search_keys;")
    }

    /// Gives free room inside the file back to the disk when there is a lot of it, as a dropped index leaves (`VACUUM`
    /// rewrites the whole file, so not for a little). Returns whether it did.
    @discardableResult
    func compact(over bytes: Int64 = 64 << 20) -> Bool {
        guard let pages = ids("PRAGMA freelist_count", [])?.first, let size = ids("PRAGMA page_size", [])?.first,
              pages * size > bytes else { return false }
        return exec("VACUUM;")
    }

    // MARK: Search index

    /// Text of every event, for finding the sessions that mention a word without reading every timeline. One row per
    /// event, folded (`TimelineSearchText.fold`) and cut into trigrams, so a match is any piece of text of three or more
    /// characters, as "Find in session" matches. A prefilter: `TimelineSearch` still finds the exact matches.
    ///
    /// Which session and event a row belongs to lives in `run_search_keys`, whose `id` is the row's rowid in `run_search`:
    /// FTS5 cannot look up its own columns, so finding an event's row there scans the whole index. Through the keys every
    /// replacement is a lookup by rowid, however large the index grows.
    ///
    /// Contentless: a search only matches and joins the rowids, so FTS5 keeps no copy of the text (a fifth of the file
    /// on one Mac). `contentless_delete` (SQLite 3.43) lets a row be replaced; without it the index keeps the text.
    /// `detail = none`: which rows hold a trigram, not where in them, so a query is its trigrams together rather than a
    /// phrase (`TrigramQuery`), and a row that holds them all apart is a false hit the caller's own search drops.
    private static func searchSchema(contentless: Bool) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS run_search USING fts5(body, tokenize = 'trigram', detail = none\(contentless ? ", content = '', contentless_delete = 1" : ""));
        CREATE TABLE IF NOT EXISTS run_search_keys (
            id INTEGER PRIMARY KEY,
            run_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            UNIQUE (run_id, event_id)
        );
        """
    }

    /// The index can be used (FTS5 with the trigram tokenizer is there).
    private(set) var searchAvailable = false

    /// Indexes events of a session: each replaces what was indexed for that event. All of them, or none.
    @discardableResult
    func index(_ runID: UUID, _ entries: [(event: UUID, text: String)]) -> Bool {
        guard searchAvailable else { return false }
        guard !entries.isEmpty else { return true }
        let run = runID.uuidString
        return inSavepoint {
            for entry in entries {
                let event = entry.event.uuidString
                let key = ids("SELECT id FROM run_search_keys WHERE run_id = ? AND event_id = ?", [run, event])?.first
                if let key {
                    guard execute("DELETE FROM run_search WHERE rowid = ?", [key]) else { return false }
                }
                if entry.text.isEmpty {
                    if let key, !execute("DELETE FROM run_search_keys WHERE id = ?", [key]) { return false }
                    continue
                }
                let id: Int64
                if let key {
                    id = key
                } else {
                    guard execute("INSERT INTO run_search_keys (run_id, event_id) VALUES (?, ?)", [run, event]) else { return false }
                    id = sqlite3_last_insert_rowid(db)
                }
                guard execute("INSERT INTO run_search (rowid, body) VALUES (?, ?)", [id, entry.text]) else { return false }
            }
            return true
        }
    }

    /// Indexes a whole timeline: what was indexed for the session before goes. All in one transaction.
    @discardableResult
    func reindex(_ runID: UUID, _ entries: [(event: UUID, text: String)]) -> Bool {
        guard searchAvailable else { return false }
        return inSavepoint { removeIndex(runID) && index(runID, entries) }
    }

    @discardableResult
    func removeIndex(_ runID: UUID) -> Bool {
        guard searchAvailable else { return false }
        return inSavepoint {
            guard let keys = ids("SELECT id FROM run_search_keys WHERE run_id = ?", [runID.uuidString]) else { return false }
            for key in keys where !execute("DELETE FROM run_search WHERE rowid = ?", [key]) { return false }
            return execute("DELETE FROM run_search_keys WHERE run_id = ?", [runID.uuidString])
        }
    }

    /// Drops the first version of the index (`run_text`), whose lookups scanned the whole table. Nothing reads it.
    func dropLegacySearchIndex() {
        exec("DROP TABLE IF EXISTS run_text;")
    }

    /// The sessions that may mention `query` (folded), newest match first: every one that does, and a few whose event
    /// only holds its trigrams apart, which the caller's own search drops. Nil when the index cannot answer: it is not
    /// there, or the query is shorter than a trigram; then the caller reads the timelines itself.
    func sessions(mentioning query: String, limit: Int = 2_000) -> [UUID]? {
        let folded = TimelineSearchText.fold(query)
        guard searchAvailable, folded.count >= 3 else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT k.run_id, MAX(s.rowid) AS last FROM run_search s JOIN run_search_keys k ON k.id = s.rowid
            WHERE run_search MATCH ? GROUP BY k.run_id ORDER BY last DESC LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, TrigramQuery.text(folded), -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var result: [UUID] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) { result.append(id) }
            step = sqlite3_step(stmt)
        }
        return step == SQLITE_DONE ? result : nil
    }

    /// Runs `body` in a savepoint: in a transaction of its own, or nested in the one already open.
    private func inSavepoint(_ body: () -> Bool) -> Bool {
        guard exec("SAVEPOINT search_index;") else { return false }
        if body(), exec("RELEASE search_index;") { return true }
        exec("ROLLBACK TO search_index;")
        exec("RELEASE search_index;")
        return false
    }

    /// Binds text and integer arguments to a prepared statement.
    private func bind(_ stmt: OpaquePointer?, _ arguments: [Any]) {
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case let value as Int64: sqlite3_bind_int64(stmt, Int32(index + 1), value)
            case let value as String: sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
            default: sqlite3_bind_null(stmt, Int32(index + 1))
            }
        }
    }

    /// Runs one statement that returns no rows.
    private func execute(_ sql: String, _ arguments: [Any]) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bind(stmt, arguments)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// The integers in the first column of a query; nil when it fails.
    private func ids(_ sql: String, _ arguments: [Any]) -> [Int64]? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, arguments)
        var result: [Int64] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            result.append(sqlite3_column_int64(stmt, 0))
            step = sqlite3_step(stmt)
        }
        return step == SQLITE_DONE ? result : nil
    }

    /// Every session that has rows, for building the index once.
    func runIDs() -> [UUID] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT run_id FROM run_events", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var result: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) { result.append(id) }
        }
        return result
    }

    deinit { sqlite3_close(db) }

    var schemaVersion: Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func migrate() -> Bool {
        let current = schemaVersion
        for (index, sql) in Self.migrations.enumerated() where index >= current {
            exec("BEGIN;")
            guard exec(sql) else {
                exec("ROLLBACK;")
                return false
            }
            exec("PRAGMA user_version = \(index + 1);")
            exec("COMMIT;")
        }
        return true
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if setupFailure == SQLITE_OK { setupFailure = sqlite3_extended_errcode(db) }
            return false
        }
        return true
    }

    /// Runs `body` in one transaction: all of its rows are written, or none.
    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        guard exec("BEGIN IMMEDIATE;") else { return false }
        if body(), exec("COMMIT;") { return true }
        exec("ROLLBACK;")
        return false
    }

    @discardableResult
    func append(_ runID: UUID, _ kind: Kind, _ payload: Data, at: Date = Date()) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO run_events (run_id, kind, payload_json, at) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, kind.rawValue, -1, transient)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt, 3, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), transient)
        }
        sqlite3_bind_double(stmt, 4, at.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// A session's rows, oldest first.
    func rows(_ runID: UUID) -> [Row] { readRows(runID) ?? [] }

    /// A session's rows, oldest first; nil when the read failed halfway, which is not the same as a short timeline.
    func readRows(_ runID: UUID) -> [Row]? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT seq, kind, payload_json, at FROM run_events WHERE run_id = ? ORDER BY seq ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        var result: [Row] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(stmt) }
            // A kind from a newer version is skipped, never guessed at.
            guard let kindText = sqlite3_column_text(stmt, 1), let kind = Kind(rawValue: String(cString: kindText)) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 2))
            let payload = sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: length) } ?? Data()
            result.append(Row(seq: sqlite3_column_int64(stmt, 0), runID: runID, kind: kind, payload: payload,
                              at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return step == SQLITE_DONE ? result : nil
    }

    /// The sequence number of a session's newest row.
    func lastSequence(_ runID: UUID) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT MAX(seq) FROM run_events WHERE run_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Removes a session's rows up to and including `seq` (all of them without it).
    func delete(_ runID: UUID, through seq: Int64 = .max) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM run_events WHERE run_id = ? AND seq <= ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        sqlite3_bind_int64(stmt, 2, seq)
        sqlite3_step(stmt)
    }

    func hasRows(_ runID: UUID) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM run_events WHERE run_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    var rowCount: Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM run_events", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func meta(_ key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    func setMeta(_ key: String, _ value: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, value, -1, transient)
        sqlite3_step(stmt)
    }
}

/// Replays a session's log rows into its timeline. Pure, so the folding rules are tested without a database.
enum RunEventFold {
    struct Result {
        var events: [RunEvent]
        /// Rows that no longer add anything (replaced by later updates or a snapshot): a measure for compaction.
        var supersededRows: Int
        /// Rows that could not be read (from a newer version, or damaged); skipped.
        var unreadableRows: Int
    }

    static func fold(_ rows: [RunEventLog.Row], decoder: JSONDecoder) -> Result {
        var events: [RunEvent] = []
        var index: [UUID: Int] = [:]
        var unreadable = 0
        for row in rows {
            switch row.kind {
            case .snapshot:
                guard let list = try? decoder.decode(LossyArray<RunEvent>.self, from: row.payload) else {
                    unreadable += 1
                    continue
                }
                events = list.elements
                index = Dictionary(events.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
            case .event, .update:
                guard let event = try? decoder.decode(RunEvent.self, from: row.payload) else {
                    unreadable += 1
                    continue
                }
                // An update of an event the log never saw is kept as a new event rather than lost.
                if let at = index[event.id] {
                    events[at] = event
                } else {
                    index[event.id] = events.count
                    events.append(event)
                }
            }
        }
        return Result(events: events, supersededRows: max(0, rows.count - unreadable - events.count), unreadableRows: unreadable)
    }
}

/// What the search index keeps of an event: the same fields "Find in session" searches (not thinking), folded the way
/// it compares (case and diacritics ignored).
enum TimelineSearchText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func body(_ event: RunEvent) -> String {
        guard event.kind != .thinking else { return "" }
        return fold([event.text, event.detail ?? "", event.output ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    static func entries(_ events: [RunEvent]) -> [(event: UUID, text: String)] {
        events.map { ($0.id, body($0)) }
    }
}
