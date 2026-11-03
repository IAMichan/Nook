import XCTest

/// A chat video whose file name says nothing (a chat helper's id, "video.bin") is still recognized by its first bytes,
/// so the player is told what it holds instead of refusing it.
final class ChatVideoTypeTests: XCTestCase {
    private func head(_ brand: String, size: UInt8 = 0x20) -> Data {
        Data([0, 0, 0, size]) + Data("ftyp".utf8) + Data(brand.utf8)
    }

    func testMP4AndISOBrandsAreMP4() {
        XCTAssertEqual(ChatMedia.videoMIMEType(head: head("isom")), "video/mp4")
        XCTAssertEqual(ChatMedia.videoMIMEType(head: head("mp42")), "video/mp4")
    }

    func testQuickTimeAnd3GP() {
        XCTAssertEqual(ChatMedia.videoMIMEType(head: head("qt  ")), "video/quicktime")
        XCTAssertEqual(ChatMedia.videoMIMEType(head: head("3gp4")), "video/3gpp")
        XCTAssertEqual(ChatMedia.videoMIMEType(head: head("M4A ")), "audio/mp4")
    }

    func testOtherFilesAreNotVideos() {
        XCTAssertNil(ChatMedia.videoMIMEType(head: Data()))
        XCTAssertNil(ChatMedia.videoMIMEType(head: Data([0, 0, 0, 0x20]) + Data("ftyp".utf8)))
        // WebM / Matroska and a JPEG.
        XCTAssertNil(ChatMedia.videoMIMEType(head: Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertNil(ChatMedia.videoMIMEType(head: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1])))
    }
}

/// A fetched file counts as whole only once it is there, not empty, and no longer being written.
final class ChatMediaSettledTests: XCTestCase {
    func testMissingEmptyAndFreshFilesAreNotSettled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.jpg")
        XCTAssertFalse(ChatMedia.isSettled(file))
        try Data().write(to: file)
        XCTAssertFalse(ChatMedia.isSettled(file, now: Date().addingTimeInterval(10)))
        try Data([1, 2, 3]).write(to: file)
        XCTAssertFalse(ChatMedia.isSettled(file))
        XCTAssertTrue(ChatMedia.isSettled(file, now: Date().addingTimeInterval(10)))
    }
}
