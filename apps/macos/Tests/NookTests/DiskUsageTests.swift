import XCTest

final class DiskUsageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSizeCountsFilesInSubfolders() throws {
        let nested = folder.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: nested.appendingPathComponent("build.o"))
        try Data(count: 50_000).write(to: folder.appendingPathComponent("main.swift"))
        let size = try XCTUnwrap(DiskUsage.allocatedSize(of: folder.path))
        XCTAssertGreaterThanOrEqual(size, 150_000)
    }

    func testPurgeRemovesOnlyOldEntries() throws {
        let manager = FileManager.default
        let old = folder.appendingPathComponent("nook-core-tests.old")
        let fresh = folder.appendingPathComponent("nook-core-tests.fresh")
        try manager.createDirectory(at: old, withIntermediateDirectories: true)
        try manager.createDirectory(at: fresh, withIntermediateDirectories: true)
        let now = Date()
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)

        let removed = DiskUsage.purge(folder, olderThan: 86_400, now: now)

        XCTAssertEqual(removed, ["nook-core-tests.old"])
        XCTAssertFalse(manager.fileExists(atPath: old.path))
        XCTAssertTrue(manager.fileExists(atPath: fresh.path))
    }

    func testPurgeOfMissingFolderDoesNothing() {
        XCTAssertEqual(DiskUsage.purge(folder.appendingPathComponent("missing"), olderThan: 0), [])
    }
}
