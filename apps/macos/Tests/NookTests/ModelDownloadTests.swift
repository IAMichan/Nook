import XCTest

/// Nook downloads a built-in model itself, so it knows how many bytes are in and the bar follows them.
final class ModelDownloadTests: XCTestCase {
    func testKeepsOnlyTheFilesMLXNeedsWithTheirRealSize() throws {
        let listing = """
        [
          {"type": "file", "path": "config.json", "size": 1200},
          {"type": "file", "path": "model-00001-of-00002.safetensors", "size": 134, "lfs": {"size": 5000000000}},
          {"type": "file", "path": "model.safetensors.index.json", "size": 80000},
          {"type": "file", "path": "chat_template.jinja", "size": 4000},
          {"type": "file", "path": "README.md", "size": 900},
          {"type": "file", "path": ".gitattributes", "size": 1500},
          {"type": "directory", "path": "assets", "size": 0}
        ]
        """
        let files = try ModelDownload.parseFiles(Data(listing.utf8))
        XCTAssertEqual(files.map(\.path), ["config.json", "model-00001-of-00002.safetensors", "model.safetensors.index.json", "chat_template.jinja"])
        XCTAssertEqual(files[1].size, 5_000_000_000)
    }

    func testTakesTheSHA256OfLargeFilesOnly() throws {
        let oid = String(repeating: "ab", count: 32)
        let listing = """
        [
          {"type": "file", "path": "config.json", "size": 1200, "oid": "0123456789abcdef0123456789abcdef01234567"},
          {"type": "file", "path": "model.safetensors", "size": 134, "lfs": {"oid": "\(oid.uppercased())", "size": 5000}}
        ]
        """
        let files = try ModelDownload.parseFiles(Data(listing.utf8))
        XCTAssertNil(files[0].sha256, "a small file's oid is a git hash, not a SHA-256")
        XCTAssertEqual(files[1].sha256, oid)
    }

    func testACutOffOrAlteredFileIsNeverTrusted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("model.safetensors")
        try Data("hello".utf8).write(to: url)
        // SHA-256 of "hello".
        let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(try ModelDownload.sha256(of: url), hash)
        XCTAssertNoThrow(try ModelDownload.verify(url, as: .init(path: "model.safetensors", size: 5, sha256: hash)))
        XCTAssertThrowsError(try ModelDownload.verify(url, as: .init(path: "model.safetensors", size: 6, sha256: hash)), "too short")
        XCTAssertThrowsError(try ModelDownload.verify(url, as: .init(path: "model.safetensors", size: 5,
                                                                         sha256: String(repeating: "0", count: 64))), "altered")
        XCTAssertNoThrow(try ModelDownload.verify(url, as: .init(path: "config.json", size: 5)), "without a hash the size is the check")
    }

    func testAnUnexpectedListingFallsBackToTheLibrary() {
        XCTAssertThrowsError(try ModelDownload.parseFiles(Data(#"{"error": "not found"}"#.utf8))) { error in
            XCTAssertTrue(error is ModelDownload.ListingUnavailable)
        }
    }

    func testEachModelGetsItsOwnFolder() {
        let folder = ModelDownload.directory(for: "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(folder.lastPathComponent, "mlx-community--Qwen3-8B-4bit")
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "Models")
    }
}
