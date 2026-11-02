import XCTest

final class FileViewingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileViewingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ data: Data) -> String {
        let url = folder.appendingPathComponent(name)
        try? data.write(to: url)
        return url.path
    }

    func testSourceFileShowsAsColoredLines() {
        let path = write("App.swift", Data("import SwiftUI\n// note\nlet x = 1\n".utf8))
        guard case .text(let lines, let tokens) = FileViewing.load(path: path) else { return XCTFail("expected text") }
        XCTAssertEqual(lines, ["import SwiftUI", "// note", "let x = 1"])
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].first?.kind, .keyword)
        XCTAssertEqual(tokens[1].first?.kind, .comment)
    }

    func testUnknownLanguageIsPlainText() {
        let path = write("notes.txt", Data("one\r\ntwo".utf8))
        XCTAssertEqual(FileViewing.load(path: path), .text(lines: ["one", "two"], tokens: [[], []]))
    }

    func testBinaryPicturesAndFoldersAreNotText() {
        XCTAssertEqual(FileViewing.load(path: write("blob.bin", Data([0x41, 0x00, 0x42]))), .preview)
        XCTAssertEqual(FileViewing.load(path: write("shot.png", Data("not really a png".utf8))), .preview)
        XCTAssertEqual(FileViewing.load(path: folder.path), .folder)
        XCTAssertEqual(FileViewing.load(path: folder.appendingPathComponent("gone.swift").path), .missing)
    }

    func testBlockCommentCarriesOverLines() {
        let tokens = FileViewing.tokens(["/* start", "still comment */ let y = 2"], path: "a.swift")
        XCTAssertEqual(tokens[0].first?.kind, .comment)
        XCTAssertEqual(tokens[1].first?.kind, .comment)
        XCTAssertTrue(tokens[1].contains { $0.kind == .keyword })
    }

    func testLinesAndLineClamping() {
        XCTAssertEqual(FileViewing.split("a\nb\n"), ["a", "b"])
        XCTAssertEqual(FileViewing.split(""), [""])
        XCTAssertEqual(FileViewing.decode(Data([0xEF, 0xBB, 0xBF, 0x68, 0x69])), "hi")
        XCTAssertEqual(FileViewing.clampedLine(40, count: 10), 10)
        XCTAssertEqual(FileViewing.clampedLine(0, count: 10), 1)
        XCTAssertNil(FileViewing.clampedLine(nil, count: 10))
    }

    func testEditingKeepsLineBreaksMarkAndPermissions() throws {
        let path = write(".env", Data("\u{FEFF}KEY=old\r\nOTHER=1\r\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let file = try XCTUnwrap(FileViewing.editable(path: path))
        XCTAssertEqual(file.text, "KEY=old\nOTHER=1\n")
        XCTAssertTrue(file.byteOrderMark)
        XCTAssertTrue(file.windowsBreaks)
        guard case .saved = FileViewing.save("KEY=new\nOTHER=1\n", as: file, to: path) else { return XCTFail("not saved") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("\u{FEFF}KEY=new\r\nOTHER=1\r\n".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testSavingOverAChangeOnDiskAsksFirst() throws {
        let path = write("config.json", Data("{}".utf8))
        var file = try XCTUnwrap(FileViewing.editable(path: path))
        file.modified = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(FileViewing.save("{\"a\": 1}", as: file, to: path), .changedOnDisk)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{}")
        guard case .saved = FileViewing.save("{\"a\": 1}", as: file, to: path, overwrite: true) else { return XCTFail("not saved") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{\"a\": 1}")
    }

    func testBinaryIsNotEditable() {
        XCTAssertNil(FileViewing.editable(Data([0x41, 0x00, 0x42])))
        XCTAssertEqual(FileViewing.editable(Data("a\nb".utf8))?.windowsBreaks, false)
    }
}
