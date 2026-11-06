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

    /// Opens (or creates) the log. Nil when the file cannot be opened as a database.
    /// - Parameter readOnly: a second connection to a log that exists, only for reading. With WAL it sees the last commit
    ///   and never waits for a write, nor a write for it.
    init?(url: URL, readOnly: Bool = false) {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        if readOnly {
            sqlite3_busy_timeout(db, 2_000)
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 2_000)
        exec("PRAGMA journal_mode = WAL;")
        // Durable across a crash of Nook; only a power cut can lose the last commits, never corrupt the file.
        exec("PRAGMA synchronous = NORMAL;")
        guard migrate() else {
            sqlite3_close(db)
            return nil
        }
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
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
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

    /// Removes a session's rows up to and including `seq` (all of them without it).
    func delete(_ runID: UUID, through seq: Int64 = .max) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM run_events WHERE run_id = ? AND seq <= ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        sqlite3_bind_int64(stmt, 2, seq)
        sqlite3_step(stmt)
    }

    /// The newest row of a session.
    func lastSeq(_ runID: UUID) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(seq) FROM run_events WHERE run_id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, runID.uuidString, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
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
