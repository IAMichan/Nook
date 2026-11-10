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

    func testCachedSizeMeasuresAgainOnlyWhenOld() throws {
        let file = folder.appendingPathComponent("build.o")
        try Data(count: 100_000).write(to: file)
        let now = Date()
        let first = try XCTUnwrap(DiskUsage.cachedAllocatedSize(of: folder.path, now: now))
        try Data(count: 400_000).write(to: folder.appendingPathComponent("more.o"))
        // Within the age the first measurement stands; past it (or with no age, the refresh button) the folder is walked.
        XCTAssertEqual(DiskUsage.cachedAllocatedSize(of: folder.path, now: now.addingTimeInterval(60)), first)
        let later = try XCTUnwrap(DiskUsage.cachedAllocatedSize(of: folder.path, maxAge: 0, now: now.addingTimeInterval(60)))
        XCTAssertGreaterThanOrEqual(later, first + 400_000)
        // With the Worktrees list closed a refresh takes what was measured, however old, and measures nothing.
        XCTAssertEqual(DiskUsage.knownSize(of: folder.path), later)
        XCTAssertNil(DiskUsage.knownSize(of: folder.appendingPathComponent("never-measured").path))
    }

    func testListingSeesGrowthNewAndRemovedFilesWithoutListingAgain() throws {
        let listing = DirectoryListing()
        let transcripts: (String) -> Bool = { $0.hasSuffix(".jsonl") }
        let first = folder.appendingPathComponent("a.jsonl")
        try Data("one\n".utf8).write(to: first)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let listed = listing.files(in: folder, where: transcripts)
        XCTAssertEqual(listed.map(\.url.lastPathComponent), ["a.jsonl"])
        XCTAssertEqual(listed.first?.stamp.size, 4)
        // Unchanged, the same stamps: a caller keyed on them parses nothing again.
        XCTAssertEqual(listing.files(in: folder, where: transcripts).map(\.stamp), listed.map(\.stamp))

        // Appending leaves the directory's date alone: the known file is looked at again.
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        XCTAssertEqual(listing.files(in: folder, where: transcripts).first?.stamp.size, 8)

        try Data("three\n".utf8).write(to: folder.appendingPathComponent("b.jsonl"))
        XCTAssertEqual(Set(listing.files(in: folder, where: transcripts).map(\.url.lastPathComponent)), ["a.jsonl", "b.jsonl"])
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(listing.files(in: folder, where: transcripts).map(\.url.lastPathComponent), ["b.jsonl"])
        XCTAssertTrue(listing.files(in: folder.appendingPathComponent("gone"), where: transcripts).isEmpty)
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
