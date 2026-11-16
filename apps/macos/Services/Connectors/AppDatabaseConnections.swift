import Foundation
import SQLite3

/// One read-only connection per app database (Messages, WhatsApp, Mail's index…), kept open between reads. A chat bridge
/// asks its database seven to nine questions for one change, and opening the file each time (the schema read again,
/// the write-ahead log's index mapped again) cost more than most of those questions. Every read of one file runs on
/// that file's own serial queue, so its connection is never used by two threads at once; reads of different files still
/// run side by side. The connection is opened again when a read fails or the file was replaced (another device or inode
/// at the path, as when an app rebuilds its database), and closed once nothing read it for `idleClose`, so a quiet app
/// keeps no file open.
///
/// Each statement runs in a read transaction of its own, so a connection kept open still sees what the app wrote since.
/// The unchanging-file fallback (`AppDatabase.snapshotURI`) does not come here: it opens the file once for that read.
final class AppDatabaseConnections: @unchecked Sendable {
    static let shared = AppDatabaseConnections()

    /// How long a connection may go unused before it is closed.
    let idleClose: TimeInterval

    init(idleClose: TimeInterval = 60) {
        self.idleClose = idleClose
    }

    /// Where a file is: its device and inode. A file put in place of another has a new one.
    struct FileID: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    /// One file's connection. Everything in it is used on `queue` only.
    private final class Entry: @unchecked Sendable {
        let queue: DispatchQueue
        var db: OpaquePointer?
        var file: FileID?
        var idle: DispatchWorkItem?

        init(label: String) {
            queue = DispatchQueue(label: label, qos: .userInitiated)
        }

        func close() {
            idle?.cancel()
            idle = nil
            if let db { sqlite3_close(db) }
            db = nil
            file = nil
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private func entry(_ path: String) -> Entry {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries[path] { return entry }
        let entry = Entry(label: "nook.appdatabase.\(entries.count)")
        entries[path] = entry
        return entry
    }

    /// One query on the database at `path` (a plain file path), after the reads of that file asked before it.
    func query(_ path: String, _ sql: String) async -> Result<[[String: Any]], Error> {
        let entry = entry(path)
        return await withCheckedContinuation { continuation in
            entry.queue.async {
                continuation.resume(returning: self.run(entry, path: path, sql: sql))
            }
        }
    }

    /// Runs on `entry.queue`.
    private func run(_ entry: Entry, path: String, sql: String) -> Result<[[String: Any]], Error> {
        let file = Self.fileID(path)
        if entry.db != nil, file == nil || entry.file != file { entry.close() }
        if entry.db == nil {
            switch AppDatabaseSQL.open(path) {
            case .success(let db):
                entry.db = db
                entry.file = file
            case .failure(let error):
                return .failure(error)
            }
        }
        guard let db = entry.db else { return .failure(AppDatabaseSQL.failure("unable to open database file")) }
        let result = AppDatabaseSQL.rows(db, sql)
        // A failed read (a lock held past the wait, a file that went bad) starts from a fresh connection next time.
        if case .failure = result {
            entry.close()
            return result
        }
        entry.idle?.cancel()
        let idle = DispatchWorkItem { [weak entry] in entry?.close() }
        entry.idle = idle
        entry.queue.asyncAfter(deadline: .now() + idleClose, execute: idle)
        return result
    }

    /// Whether a connection to `path` is open now; for the tests.
    func isOpen(_ path: String) -> Bool {
        lock.lock()
        let entry = entries[path]
        lock.unlock()
        guard let entry else { return false }
        return entry.queue.sync { entry.db != nil }
    }

    static func fileID(_ path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino))
    }
}

/// Opening an app's database read-only and reading rows from it, as `AppDatabase` gives them back.
enum AppDatabaseSQL {
    /// The database at `path` (a file path, or a `file:` URI) opened read-only, waiting up to 3 seconds for a lock the
    /// app holds. The connection is used by one thread at a time (`AppDatabaseConnections`), so SQLite's own mutex is off.
    static func open(_ path: String) -> Result<OpaquePointer, Error> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database file"
            sqlite3_close(db)
            return .failure(failure(message))
        }
        sqlite3_busy_timeout(db, 3000)
        return .success(db)
    }

    /// The rows of one query, as `sqlite3 -json` gave them: numbers as `NSNumber`, text as `String`, NULL as `NSNull`.
    static func rows(_ db: OpaquePointer, _ sql: String) -> Result<[[String: Any]], Error> {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            return .failure(failure(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(statement) }
        let columns = sqlite3_column_count(statement)
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .failure(failure(String(cString: sqlite3_errmsg(db)))) }
            var row: [String: Any] = [:]
            for index in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, index))
                case SQLITE_TEXT, SQLITE_BLOB:
                    // The pointer first, then its length (SQLite's order, so no conversion runs in between).
                    let bytes = sqlite3_column_blob(statement, index)
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes, count > 0 {
                        row[name] = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
                    } else {
                        row[name] = ""
                    }
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return .success(rows)
    }

    /// One query on a connection of its own, closed right after: for the unchanging-file fallback.
    static func once(_ path: String, _ sql: String) -> Result<[[String: Any]], Error> {
        switch open(path) {
        case .success(let db):
            defer { sqlite3_close(db) }
            return rows(db, sql)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func failure(_ message: String) -> Error {
        NSError(domain: "nook.appdatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
