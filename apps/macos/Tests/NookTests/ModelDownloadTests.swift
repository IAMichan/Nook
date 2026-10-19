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
