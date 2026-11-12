import Foundation
import SQLite3

/// Opens Nook's own SQLite files (`nook.sqlite`, `chats.sqlite`, `runs.sqlite`) so that a file that cannot be used never
/// makes data silently seem lost.
///
/// Before, a damaged file was only logged: Nook ran on without a store, and nothing told you why your loops, chats or
/// timelines were gone. Now every writer opens through `open(_:flags:setUp:)`:
/// - The header and the schema are read once (and `PRAGMA quick_check` runs on a small file, see `quickCheckLimit`),
///   then the store's own setup (pragmas, migrations) runs.
/// - When SQLite says the file is damaged (`SQLITE_CORRUPT`) or is not a database at all (`SQLITE_NOTADB`), the file and
///   its `-wal` and `-shm` are moved aside under a dated name (`nook.damaged-20261112-101500.sqlite`), never deleted, and
///   a fresh database is made in its place, so Nook keeps working.
/// - Any other failure (the disk is full, the folder is not writable, another process holds a lock) leaves the file
///   exactly where it is: moving a healthy file aside would hide data that is fine.
///
/// Either way a `DatabaseIncident` is recorded, which the panel shows until you dismiss it: which file, why, where the
/// copy is, and how to get the data back (`AppModel+StorageIncidents`).
enum SQLiteRecovery {
    /// Files up to this size get `PRAGMA quick_check` when they open. It reads every page: measured at about 0.7 ms per MB
    /// with a warm cache (66 MB in 50 ms, 333 MB in 240 ms on an M-series Mac), so a large archive is not checked at launch.
    /// A small `nook.sqlite` costs a few milliseconds. Larger files still get the header and schema read, which finds a
    /// file that is not a database and most damage SQLite reports on open.
    static let quickCheckLimit: Int64 = 8 << 20

    /// Whether an SQLite result code means the file itself is damaged, rather than out of reach for now.
    static func isDamage(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Opens `url` for writing, setting it up with `setUp` (pragmas and migrations; it returns `SQLITE_OK` or the code
    /// that failed). A damaged file is moved aside and a fresh one set up in its place; a file that cannot be used for
    /// another reason is left alone. Returns the connection, or nil when there is none to use (an incident is recorded).
    static func open(_ url: URL, flags: Int32, label: String? = nil, now: Date = Date(),
                     incidents: DatabaseIncidents = .shared,
                     setUp: (OpaquePointer) -> Int32) -> OpaquePointer? {
        switch attempt(url, flags: flags, setUp: setUp) {
        case .success(let db):
            return db
        case .failure(let failure) where isDamage(failure.code):
            let backup: URL
            do {
                backup = try setAside(url, now: now)
            } catch {
                incidents.record(DatabaseIncident(file: url, kind: .unavailable, reason: failure.message, code: failure.code,
                                                  movedTo: nil, at: now))
                SafeStorage.report("\(url.lastPathComponent) is damaged (\(failure.message)) and could not be moved aside: \(error)")
                return nil
            }
            SafeStorage.report("\(url.lastPathComponent) is damaged (\(failure.message)); moved to \(backup.lastPathComponent), starting fresh")
            switch attempt(url, flags: flags, setUp: setUp) {
            case .success(let db):
                incidents.record(DatabaseIncident(file: url, kind: .damaged, reason: failure.message, code: failure.code,
                                                  movedTo: backup, at: now))
                return db
            case .failure(let second):
                // The copy is kept; the fresh file could not be made either (the folder is not writable, the disk is full).
                incidents.record(DatabaseIncident(file: url, kind: .unavailable, reason: second.message, code: second.code,
                                                  movedTo: backup, at: now))
                return nil
            }
        case .failure(let failure):
            SafeStorage.report("\(url.lastPathComponent) could not be opened (\(failure.message)); the file is left as it is")
            incidents.record(DatabaseIncident(file: url, kind: .unavailable, reason: failure.message, code: failure.code,
                                              movedTo: nil, at: now))
            return nil
        }
    }

    struct Failure: Error, Equatable {
        var code: Int32
        var message: String
    }

    /// One try: open, read the header and schema, check a small file, then the store's own setup. The connection is
    /// closed again on any failure.
    static func attempt(_ url: URL, flags: Int32, setUp: (OpaquePointer) -> Int32) -> Result<OpaquePointer, Failure> {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, flags, nil)
        guard opened == SQLITE_OK, let db else {
            let failure = Failure(code: opened, message: message(db, opened))
            sqlite3_close(db)
            return .failure(failure)
        }
        func fail(_ code: Int32) -> Result<OpaquePointer, Failure> {
            let failure = Failure(code: code, message: message(db, code))
            sqlite3_close(db)
            return .failure(failure)
        }
        // Another process may hold the file for a moment (a checkpoint): wait for it a little, as the stores do.
        sqlite3_busy_timeout(db, 2_000)
        // Reading the schema reads the header and page 1: a file that is not a database, or whose schema is damaged,
        // fails here before anything is written to it.
        let probe = sqlite3_exec(db, "SELECT count(*) FROM sqlite_master;", nil, nil, nil)
        if probe != SQLITE_OK { return fail(sqlite3_extended_errcode(db)) }
        if let size = fileSize(url), size > 0, size <= quickCheckLimit, !quickCheck(db) {
            return fail(SQLITE_CORRUPT)
        }
        let code = setUp(db)
        if code != SQLITE_OK { return fail(code) }
        return .success(db)
    }

    /// `PRAGMA quick_check`: true when it answers "ok". A check that cannot run at all says nothing about damage.
    static func quickCheck(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check(1);", -1, &stmt, nil) == SQLITE_OK else { return true }
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) { return String(cString: text) == "ok" }
        return !isDamage(step)
    }

    /// Moves the database and the files that belong to it (`-wal` holds committed data, `-shm`, `-journal`) aside under a
    /// dated name next to it. Returns where the database went. Throws, moving nothing back, when the database itself
    /// could not be moved.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let backup = backupURL(for: url, now: now, fileManager: fileManager)
        try fileManager.moveItem(at: url, to: backup)
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: side.path) else { continue }
            try? fileManager.moveItem(at: side, to: URL(fileURLWithPath: backup.path + suffix))
        }
        return backup
    }

    /// `name.damaged-<date>.ext` next to `url`, with a number added when that name is taken (two in the same second).
    static func backupURL(for url: URL, now: Date, fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let stamp = formatter.string(from: now)
        var candidate = folder.appendingPathComponent("\(name).damaged-\(stamp)\(ext)")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name).damaged-\(stamp)-\(number)\(ext)")
            number += 1
        }
        return candidate
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func message(_ db: OpaquePointer?, _ code: Int32) -> String {
        if let db, let text = sqlite3_errmsg(db) {
            let said = String(cString: text)
            if !said.isEmpty, said != "not an error" { return said }
        }
        return String(cString: sqlite3_errstr(code))
    }
}

/// A database of Nook's own that could not be used as it was.
struct DatabaseIncident: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        /// The file was damaged: it was moved to `movedTo` and a fresh database is in its place.
        case damaged
        /// The file could not be used and was left where it is (or moved, when only the fresh one failed); this session
        /// works without it.
        case unavailable
    }

    var id: String { file.path }
    let file: URL
    let kind: Kind
    /// SQLite's own words ("file is not a database", "database disk image is malformed", "disk I/O error").
    let reason: String
    let code: Int32
    /// Where the damaged file is now.
    let movedTo: URL?
    let at: Date

    /// A command that reads what can still be read from the copy into a new file beside it, for the notice.
    var recoverCommand: String? {
        guard let movedTo else { return nil }
        let recovered = movedTo.deletingPathExtension().path + ".recovered." + (movedTo.pathExtension.isEmpty ? "sqlite" : movedTo.pathExtension)
        return "sqlite3 \(Self.quoted(movedTo.path)) \".recover\" | sqlite3 \(Self.quoted(recovered))"
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The incidents of this launch, in the order they happened. Stores open on any thread, often before the panel exists,
/// so they are kept here and the panel reads them when it starts and is told of later ones (`onRecord`, on the thread that
/// recorded it).
final class DatabaseIncidents: @unchecked Sendable {
    static let shared = DatabaseIncidents()

    private let lock = NSLock()
    private var recorded: [DatabaseIncident] = []
    private var observer: ((DatabaseIncident) -> Void)?

    var all: [DatabaseIncident] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Keeps the incident (one per file: a later one replaces it) and tells the observer.
    func record(_ incident: DatabaseIncident) {
        lock.lock()
        recorded.removeAll { $0.file == incident.file }
        recorded.append(incident)
        let observer = observer
        lock.unlock()
        observer?(incident)
    }

    /// Called for every incident recorded from now on.
    func onRecord(_ observer: @escaping (DatabaseIncident) -> Void) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }
}
