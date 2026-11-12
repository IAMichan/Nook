import XCTest
import SQLite3

/// A database of Nook's own that cannot be opened: a damaged one is kept aside (never deleted) and a fresh one takes its
/// place; one that is out of reach for another reason is left exactly where it is. Every store gets its own folder in
/// the temporary directory and its own incident list, never the real support folder.
final class SQLiteRecoveryTests: XCTestCase {
    private var folder: URL!
    private var incidents: DatabaseIncidents!
    private let garbage = Data("this is not an SQLite database, only some text that happens to be here".utf8)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        incidents = DatabaseIncidents()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func backup(of name: String) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let found = try XCTUnwrap(files().first { $0.hasPrefix(stem + ".damaged-") && $0.hasSuffix(".sqlite") }, "no copy in \(files())")
        return folder.appendingPathComponent(found)
    }

    // MARK: Damaged files

    func testGarbageNookStoreIsKeptAsideAndAFreshOneWorks() throws {
        let url = folder.appendingPathComponent("nook.sqlite")
        try garbage.write(to: url)

        let store = NookStore(url: url, incidents: incidents)

        // The garbage is kept, byte for byte, under a dated name.
        let copy = try backup(of: "nook.sqlite")
        XCTAssertEqual(try Data(contentsOf: copy), garbage)
        // The store works on a fresh file in the same place.
        XCTAssertEqual(store.fileURL, url)
        store.addLoop(title: "Call the bank", source: "test", due: nil)
        XCTAssertEqual(store.openLoops().map(\.title), ["Call the bank"])
        XCTAssertEqual(store.schemaVersion, 3)
        // And it is said: which file, why, and where the copy went.
        let incident = try XCTUnwrap(incidents.all.first)
        XCTAssertEqual(incidents.all.count, 1)
        XCTAssertEqual(incident.kind, .damaged)
        XCTAssertEqual(incident.file, url)
        XCTAssertEqual(incident.movedTo?.lastPathComponent, copy.lastPathComponent)
        XCTAssertEqual(incident.code & 0xFF, SQLITE_NOTADB)
        XCTAssertTrue(incident.reason.contains("not a database"), incident.reason)
        XCTAssertTrue(incident.recoverCommand?.contains(".recover") == true)
    }

    func testGarbageChatArchiveAndTimelineLogAreKeptAside() throws {
        let chats = folder.appendingPathComponent("chats.sqlite")
        let runs = folder.appendingPathComponent("runs.sqlite")
        try garbage.write(to: chats)
        try garbage.write(to: runs)

        let store = try XCTUnwrap(ChatStore(url: chats, incidents: incidents))
        let log = try XCTUnwrap(RunEventLog(url: runs, incidents: incidents))

        XCTAssertEqual(try Data(contentsOf: try backup(of: "chats.sqlite")), garbage)
        XCTAssertEqual(try Data(contentsOf: try backup(of: "runs.sqlite")), garbage)
        XCTAssertEqual(Set(incidents.all.map(\.kind)), [.damaged])
        XCTAssertEqual(Set(incidents.all.map(\.file.lastPathComponent)), ["chats.sqlite", "runs.sqlite"])
        // Both are usable: a reader opens the fresh file beside the writer.
        XCTAssertEqual(log.schemaVersion, 1)
        XCTAssertNotNil(RunEventLog(url: runs, readOnly: true, incidents: incidents))
        XCTAssertNotNil(ChatStore(url: chats, readOnly: true, incidents: incidents))
        _ = store
    }

    func testDamagedHeaderIsKeptAsideWithTheFilesBesideIt() throws {
        let url = folder.appendingPathComponent("runs.sqlite")
        // A real timeline log first.
        do {
            let log = try XCTUnwrap(RunEventLog(url: url, incidents: incidents))
            _ = log.append(UUID(), .event, Data("{}".utf8))
        }
        XCTAssertTrue(incidents.all.isEmpty)
        // Apple's SQLite keeps the write-ahead log after the last connection closes; stock SQLite (Linux) checkpoints and
        // deletes it. Only a log that is there can go with the copy.
        let hadWriteAheadLog = FileManager.default.fileExists(atPath: url.path + "-wal")
        // Then damage the header's magic string, as a failing disk could.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        handle.write(Data(repeating: 0x5A, count: 16))
        try handle.close()

        let reopened = try XCTUnwrap(RunEventLog(url: url, incidents: incidents))

        let copy = try backup(of: "runs.sqlite")
        XCTAssertEqual(incidents.all.first?.kind, .damaged)
        XCTAssertEqual(try Data(contentsOf: copy).prefix(16), Data(repeating: 0x5A, count: 16))
        // The write-ahead log and its index went with the copy, under its name; the fresh file has its own.
        XCTAssertEqual(FileManager.default.fileExists(atPath: copy.path + "-wal"), hadWriteAheadLog, "\(files())")
        XCTAssertEqual(reopened.runIDs(), [])
    }

    func testSetAsideMovesTheWriteAheadLogByteForByte() throws {
        // A write-ahead log holds committed data that is not in the file yet: it has to stay with the copy, unchanged.
        let url = folder.appendingPathComponent("nook.sqlite")
        try garbage.write(to: url)
        let wal = Data("committed pages not yet in the file".utf8)
        try wal.write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("index".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))

        let copy = try SQLiteRecovery.setAside(url)

        XCTAssertEqual(try Data(contentsOf: copy), garbage)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy.path + "-wal")), wal)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy.path + "-shm")), Data("index".utf8))
        XCTAssertEqual(files().filter { $0.hasPrefix("nook.sqlite") }, [], "nothing left under the old name")
    }

    func testAFileOutOfReachIsLeftWhereItIs() throws {
        // A folder where the database should be: SQLite cannot open it, and it is not damage.
        let url = folder.appendingPathComponent("nook.sqlite")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let store = NookStore(url: url, incidents: incidents)

        XCTAssertEqual(files(), ["nook.sqlite"], "nothing moved")
        let incident = try XCTUnwrap(incidents.all.first)
        XCTAssertEqual(incident.kind, .unavailable)
        XCTAssertNil(incident.movedTo)
        XCTAssertNil(incident.recoverCommand)
        // Nook keeps working this session, in memory.
        XCTAssertNil(store.fileURL)
        store.addLoop(title: "In memory", source: "test", due: nil)
        XCTAssertEqual(store.openLoops().map(\.title), ["In memory"])

        XCTAssertNil(ChatStore(url: url, incidents: incidents))
        XCTAssertNil(RunEventLog(url: url, incidents: incidents))
        XCTAssertEqual(files(), ["nook.sqlite"])
    }

    func testALockedFileIsNeverMovedAside() throws {
        let url = folder.appendingPathComponent("runs.sqlite")
        // Another process holds the file (a second Nook, a tool): a healthy database that cannot be migrated right now.
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &other), SQLITE_OK)
        defer { sqlite3_close(other) }
        XCTAssertEqual(sqlite3_exec(other, "CREATE TABLE unrelated (x); BEGIN EXCLUSIVE; INSERT INTO unrelated VALUES (1);", nil, nil, nil), SQLITE_OK)

        let started = Date()
        let log = RunEventLog(url: url, incidents: incidents)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)

        XCTAssertNil(log)
        XCTAssertEqual(files().filter { $0.contains("damaged") }, [], "a busy file is not damaged")
        XCTAssertEqual(incidents.all.first?.kind, .unavailable)
        XCTAssertEqual((incidents.all.first?.code ?? 0) & 0xFF, SQLITE_BUSY)
        sqlite3_exec(other, "ROLLBACK;", nil, nil, nil)
    }

    func testAHealthyDatabaseOpensWithoutAnIncident() throws {
        let url = folder.appendingPathComponent("chats.sqlite")
        XCTAssertNotNil(ChatStore(url: url, incidents: incidents))
        XCTAssertNotNil(ChatStore(url: url, incidents: incidents))
        XCTAssertTrue(incidents.all.isEmpty)
        XCTAssertEqual(files().filter { $0.contains("damaged") }, [])
    }

    func testQuickCheckOnASmallFileIsCheap() throws {
        let url = folder.appendingPathComponent("nook.sqlite")
        do {
            let store = NookStore(url: url, incidents: incidents)
            for index in 0..<2_000 { store.audit(tool: "tool", args: "argument \(index)", result: "result \(index)") }
        }
        let started = Date()
        _ = NookStore(url: url, incidents: incidents)
        // The whole open, quick_check included, stays far under a frame budget for a file of this size.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertTrue(incidents.all.isEmpty)
    }

    // MARK: Names

    func testBackupNamesAreDatedAndNeverReused() throws {
        let url = folder.appendingPathComponent("chats.sqlite")
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 12; components.hour = 10; components.minute = 15
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let when = try XCTUnwrap(calendar.date(from: components))
        let first = SQLiteRecovery.backupURL(for: url, now: when)
        XCTAssertEqual(first.lastPathComponent, "chats.damaged-20261112-101500.sqlite")
        try Data().write(to: first)
        XCTAssertEqual(SQLiteRecovery.backupURL(for: url, now: when).lastPathComponent, "chats.damaged-20261112-101500-2.sqlite")
    }

    func testOnlyCorruptAndNotADatabaseCountAsDamage() {
        XCTAssertTrue(SQLiteRecovery.isDamage(SQLITE_CORRUPT))
        XCTAssertTrue(SQLiteRecovery.isDamage(SQLITE_NOTADB))
        XCTAssertTrue(SQLiteRecovery.isDamage(SQLITE_CORRUPT | (1 << 8)))
        for code in [SQLITE_BUSY, SQLITE_FULL, SQLITE_CANTOPEN, SQLITE_READONLY, SQLITE_IOERR, SQLITE_PERM, SQLITE_ERROR] {
            XCTAssertFalse(SQLiteRecovery.isDamage(code), "\(code)")
        }
    }

    func testRecoverCommandQuotesThePaths() {
        let incident = DatabaseIncident(file: URL(fileURLWithPath: "/Users/a/Application Support/Nook/chats.sqlite"),
                                        kind: .damaged, reason: "file is not a database", code: SQLITE_NOTADB,
                                        movedTo: URL(fileURLWithPath: "/Users/a/Application Support/Nook/chats.damaged-1.sqlite"),
                                        at: Date())
        XCTAssertEqual(incident.recoverCommand,
                       "sqlite3 '/Users/a/Application Support/Nook/chats.damaged-1.sqlite' \".recover\" | sqlite3 '/Users/a/Application Support/Nook/chats.damaged-1.recovered.sqlite'")
    }
}
