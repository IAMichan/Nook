import XCTest

final class ZipTextTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let utf8: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }

    /// Zips `files` (path inside the archive → contents) with the system's zip.
    private func makeZip(_ files: [String: String], name: String = "archive.zip") throws -> URL {
        let source = folder.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let archive = folder.appendingPathComponent(name)
        let result = try ProcessRunner.run("/usr/bin/zip", ["-qr", archive.path, "."], in: source.path)
        XCTAssertEqual(result.status, 0, result.stderr)
        return archive
    }

    func testListsTheFilesAndReadsTheirText() throws {
        let archive = try makeZip(["notes.txt": "Buy milk", "docs/plan.md": "# Plan\nShip it", ".hidden": "secret"])
        let text = try ZipText.read(archive, readFile: utf8)
        XCTAssertTrue(text.contains("archive.zip, 2 files"), text)
        XCTAssertTrue(text.contains("docs/plan.md\nnotes.txt"), "sorted, by their path inside")
        XCTAssertTrue(text.contains("--- notes.txt ---\nBuy milk"))
        XCTAssertTrue(text.contains("Ship it"))
        XCTAssertFalse(text.contains("secret"), "hidden files stay out")
    }

    func testStopsAtTheLimit() throws {
        let archive = try makeZip(["a.txt": String(repeating: "a", count: 5_000), "b.txt": "after the limit"])
        let text = try ZipText.read(archive, limit: 1_000, readFile: utf8)
        XCTAssertLessThan(text.count, 1_100)
        XCTAssertFalse(text.contains("after the limit"))
        XCTAssertTrue(text.contains("1 more file not read"))
    }

    func testAFileThatIsNoZipIsUnreadable() throws {
        let fake = folder.appendingPathComponent("fake.zip")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ZipText.read(fake, readFile: utf8)) { error in
            XCTAssertEqual(error as? ZipText.Failure, .unreadable("fake.zip"))
        }
    }

    func testAnEmptyArchiveSaysSo() throws {
        let empty = folder.appendingPathComponent("empty.zip")
        // The end-of-central-directory record alone: a valid zip with nothing in it.
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: empty)
        XCTAssertThrowsError(try ZipText.read(empty, readFile: utf8)) { error in
            XCTAssertEqual(error as? ZipText.Failure, .empty("empty.zip"))
        }
    }

    func testUnpackedSizeComesFromTheDirectory() throws {
        let archive = try makeZip(["one.txt": String(repeating: "x", count: 1_234)])
        XCTAssertEqual(ZipText.unpackedSize(archive), 1_234)
    }
}
