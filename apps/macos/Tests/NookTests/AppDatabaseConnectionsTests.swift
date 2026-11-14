import XCTest
import SQLite3

/// `AppDatabaseConnections` keeps one read-only connection per app database: it must see what the app writes after
/// it opened, follow a file put in place of the old one, serve reads that come at once, and close when left alone.
final class AppDatabaseConnectionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-appdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs `sql` on a read-write connection of its own, as the app that owns the database would.
    private func write(_ path: String, _ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func names(_ result: Result<[[String: Any]], Error>) throws -> [String] {
        try result.get().compactMap { $0["name"] as? String }
    }

    func testAKeptConnectionSeesLaterWrites() async throws {
        let path = folder.appendingPathComponent("chat.db").path
        write(path, "PRAGMA journal_mode=WAL; CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('a');")
        let connections = AppDatabaseConnections()
        let first = try names(await connections.query(path, "SELECT name FROM t ORDER BY name"))
        XCTAssertEqual(first, ["a"])
        XCTAssertTrue(connections.isOpen(path))
        write(path, "INSERT INTO t VALUES ('b');")
        let second = try names(await connections.query(path, "SELECT name FROM t ORDER BY name"))
        XCTAssertEqual(second, ["a", "b"])
    }

    func testAReplacedFileIsOpenedAgain() async throws {
        let path = folder.appendingPathComponent("chat.db").path
        write(path, "CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('old');")
        let connections = AppDatabaseConnections()
        let before = try names(await connections.query(path, "SELECT name FROM t"))
        XCTAssertEqual(before, ["old"])
        // A new file moved in place of the old one, as an app that rebuilds its database does.
        let fresh = folder.appendingPathComponent("fresh.db").path
        write(fresh, "CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('new');")
        XCTAssertEqual(rename(fresh, path), 0)
        let after = try names(await connections.query(path, "SELECT name FROM t"))
        XCTAssertEqual(after, ["new"])
    }

    func testAFailedQueryLeavesNoConnectionAndTheNextOneWorks() async throws {
        let path = folder.appendingPathComponent("chat.db").path
        write(path, "CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('a');")
        let connections = AppDatabaseConnections()
        guard case .failure = await connections.query(path, "SELECT nothing FROM missing") else { return XCTFail("expected a failure") }
        XCTAssertFalse(connections.isOpen(path))
        let again = try names(await connections.query(path, "SELECT name FROM t"))
        XCTAssertEqual(again, ["a"])
    }

    func testAMissingFileFails() async {
        let connections = AppDatabaseConnections()
        guard case .failure = await connections.query(folder.appendingPathComponent("none.db").path, "SELECT 1") else {
            return XCTFail("expected a failure")
        }
    }

    func testReadsThatComeAtOnceAllAnswer() async throws {
        let path = folder.appendingPathComponent("chat.db").path
        write(path, "CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('a'), ('b'), ('c');")
        let connections = AppDatabaseConnections()
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<40 {
                group.addTask { (try? await connections.query(path, "SELECT name FROM t").get().count) ?? -1 }
            }
            var all: [Int] = []
            for await count in group { all.append(count) }
            return all
        }
        XCTAssertEqual(counts, Array(repeating: 3, count: 40))
    }

    func testAnUnusedConnectionCloses() async throws {
        let path = folder.appendingPathComponent("chat.db").path
        write(path, "CREATE TABLE t(name TEXT);")
        let connections = AppDatabaseConnections(idleClose: 0.05)
        _ = await connections.query(path, "SELECT name FROM t")
        XCTAssertTrue(connections.isOpen(path))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(connections.isOpen(path))
    }
}
