import Foundation
import SQLite3

struct OpenLoop: Identifiable, Equatable {
    var id: String
    var title: String
    var source: String
    var created: Date
    var due: Date?
}

/// One line of the action log: what Nook did (or was asked to do) on the user's behalf.
struct AuditEntry: Identifiable, Equatable {
    var id: Int64
    var date: Date
    var tool: String
    var args: String
    var result: String
}

/// Nook's memory: open loops and an audit log of everything Nook does. Everything remains local.
///
/// The schema is versioned with `PRAGMA user_version`: each migration below runs once, in order, so an existing database
/// from any earlier version is brought up to date without losing anything.
final class NookStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSLock()

    /// How long the action log is kept. It can contain message text, so it is not kept forever.
    static let auditRetention: TimeInterval = 90 * 86_400

    /// Schema migrations; index + 1 is the version they bring the database to.
    private static let migrations: [String] = [
        // 1: the original tables (also what databases from before versioning already have).
        """
        CREATE TABLE IF NOT EXISTS loops (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            source TEXT NOT NULL,
            created REAL NOT NULL,
            due REAL,
            done INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS executed_actions (
            key TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            tool TEXT NOT NULL,
            result TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            tool TEXT NOT NULL,
            args TEXT NOT NULL,
            result TEXT NOT NULL
        );
        """,
        // 2: faster log browsing and pruning.
        "CREATE INDEX IF NOT EXISTS audit_ts ON audit (ts);"
    ]

    init(url: URL = NookPaths.databaseURL) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            Log.storage.error("Could not open the database at \(url.path, privacy: .public)")
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        exec("PRAGMA journal_mode = WAL;")
        migrate()
        pruneAudit()
    }

    deinit { sqlite3_close(db) }

    /// The schema version of the open database.
    var schemaVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            version = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return version
    }

    private func migrate() {
        let current = schemaVersion
        guard current < Self.migrations.count else { return }
        for (index, sql) in Self.migrations.enumerated() where index >= current {
            exec("BEGIN;")
            guard exec(sql) else {
                exec("ROLLBACK;")
                Log.storage.error("Database migration \(index + 1) failed; staying on version \(index)")
                return
            }
            exec("PRAGMA user_version = \(index + 1);")
            exec("COMMIT;")
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                Log.storage.error("SQLite: \(String(cString: err), privacy: .public)")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }

    // MARK: Open Loops

    @discardableResult
    func addLoop(title: String, source: String, due: Date?) -> OpenLoop {
        let loop = OpenLoop(id: UUID().uuidString, title: title, source: source, created: Date(), due: due)
        var stmt: OpaquePointer?
        let sql = "INSERT INTO loops (id, title, source, created, due, done) VALUES (?, ?, ?, ?, ?, 0)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, loop.id, -1, transient)
            sqlite3_bind_text(stmt, 2, loop.title, -1, transient)
            sqlite3_bind_text(stmt, 3, loop.source, -1, transient)
            sqlite3_bind_double(stmt, 4, loop.created.timeIntervalSince1970)
            if let due { sqlite3_bind_double(stmt, 5, due.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return loop
    }

    func openLoops() -> [OpenLoop] {
        var result: [OpenLoop] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, title, source, created, due FROM loops WHERE done = 0 ORDER BY created ASC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let source = String(cString: sqlite3_column_text(stmt, 2))
                let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                var due: Date?
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    due = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                }
                result.append(OpenLoop(id: id, title: title, source: source, created: created, due: due))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func completeLoop(id: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE loops SET done = 1 WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func completeLoop(matching idOrTitle: String) -> OpenLoop? {
        let loops = openLoops()
        let needle = idOrTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let byPrefix = needle.count >= 6 ? loops.filter { $0.id.lowercased().hasPrefix(needle.lowercased()) } : []
        guard let loop = loops.first(where: { $0.id == needle })
                ?? (byPrefix.count == 1 ? byPrefix.first : nil)
                ?? loops.first(where: { $0.title.caseInsensitiveCompare(needle) == .orderedSame }) else { return nil }
        completeLoop(id: loop.id)
        return loop
    }

    // MARK: Executed Actions

    /// When exactly this action (same tool, same input) last succeeded, within `window` seconds.
    func executedAction(_ key: String, within window: TimeInterval) -> Date? {
        var stmt: OpaquePointer?
        var result: Date?
        if sqlite3_prepare_v2(db, "SELECT ts FROM executed_actions WHERE key = ? AND ts >= ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            sqlite3_bind_double(stmt, 2, Date().addingTimeInterval(-window).timeIntervalSince1970)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func recordExecuted(_ key: String, tool: String, result: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO executed_actions (key, ts, tool, result) VALUES (?, ?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, tool, -1, transient)
            sqlite3_bind_text(stmt, 4, String(result.prefix(500)), -1, transient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Old entries do not need to be retained.
        exec("DELETE FROM executed_actions WHERE ts < \(Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970)")
    }

    // MARK: Audit Log

    /// Most recent entries first. `matching` filters on tool name or text.
    func auditEntries(limit: Int = 200, matching query: String = "") -> [AuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [AuditEntry] = []
        var stmt: OpaquePointer?
        let filter = query.trimmingCharacters(in: .whitespaces)
        let sql = filter.isEmpty
            ? "SELECT id, ts, tool, args, result FROM audit ORDER BY ts DESC LIMIT ?"
            : "SELECT id, ts, tool, args, result FROM audit WHERE tool LIKE ?2 OR args LIKE ?2 OR result LIKE ?2 ORDER BY ts DESC LIMIT ?1"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            if !filter.isEmpty { sqlite3_bind_text(stmt, 2, "%\(filter)%", -1, transient) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(AuditEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    tool: String(cString: sqlite3_column_text(stmt, 2)),
                    args: String(cString: sqlite3_column_text(stmt, 3)),
                    result: String(cString: sqlite3_column_text(stmt, 4))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// Removes log entries older than the retention period.
    func pruneAudit(now: Date = Date()) {
        exec("DELETE FROM audit WHERE ts < \(now.addingTimeInterval(-Self.auditRetention).timeIntervalSince1970)")
    }

    /// Empties the action log (Settings › Privacy).
    func clearAudit() {
        exec("DELETE FROM audit")
    }

    func audit(tool: String, args: String, result: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO audit (ts, tool, args, result) VALUES (?, ?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, tool, -1, transient)
            sqlite3_bind_text(stmt, 3, String(args.prefix(2000)), -1, transient)
            sqlite3_bind_text(stmt, 4, String(result.prefix(2000)), -1, transient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}
