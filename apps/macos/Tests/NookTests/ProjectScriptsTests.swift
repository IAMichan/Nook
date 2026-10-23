import XCTest

/// nook.json: project script definitions, read leniently.
final class ProjectScriptsTests: XCTestCase {
    func testParse() {
        let json = #"{"scripts":[{"id":"dev","name":"Dev server","command":"pnpm dev","previewUrl":"http://localhost:5173","autoOpenPreview":true},{"name":"Install","command":"pnpm install","runOnWorktreeCreate":true},{"name":"Leeg"},{"command":"make test"}]}"#
        let scripts = ProjectScripts.parse(Data(json.utf8))
        XCTAssertEqual(scripts.map(\.id), ["dev", "install", "make-test"])
        XCTAssertEqual(scripts[0].previewURL?.absoluteString, "http://localhost:5173")
        XCTAssertTrue(scripts[0].autoOpenPreview)
        XCTAssertTrue(scripts[1].runOnWorktreeCreate)
        XCTAssertEqual(scripts[2].name, "make test", "a script without a name is called by its command")
    }

    func testLoadFindsTheRepositoryFile() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("nook-scripts-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("packages/web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data(#"{"scripts":[{"name":"Dev","command":"pnpm dev"}]}"#.utf8).write(to: repo.appendingPathComponent("nook.json"))
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(ProjectScripts.load(folder: sub.path).map(\.command), ["pnpm dev"])
    }

    func testAppendingKeepsTheRestOfTheFile() throws {
        let json = #"{"name":"web","scripts":[{"id":"dev","name":"Dev","command":"pnpm dev"}]}"#
        let data = try ProjectScripts.appending(name: "Dev", command: "pnpm dev --host", to: Data(json.utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["name"] as? String, "web")
        let scripts = ProjectScripts.parse(data)
        XCTAssertEqual(scripts.map(\.id), ["dev", "dev-2"], "a new script never takes an id that is already there")
        XCTAssertEqual(scripts.last?.command, "pnpm dev --host")
    }

    func testAppendingStartsAFile() throws {
        let scripts = ProjectScripts.parse(try ProjectScripts.appending(name: "", command: "make test", to: nil))
        XCTAssertEqual(scripts.map(\.name), ["make test"])
        XCTAssertThrowsError(try ProjectScripts.appending(name: "Empty", command: "  ", to: nil))
        XCTAssertThrowsError(try ProjectScripts.appending(name: "Dev", command: "pnpm dev", to: Data("[1]".utf8)),
                             "a file that is not a JSON object is left alone")
    }

    func testAddWritesNextToTheRepositoryRoot() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("nook-scripts-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("packages/web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = try ProjectScripts.add(name: "Lint", command: "pnpm lint", folder: sub.path)
        XCTAssertEqual(file.standardizedFileURL.path, repo.appendingPathComponent("nook.json").standardizedFileURL.path)
        try ProjectScripts.add(name: "Test", command: "pnpm test", folder: repo.path)
        XCTAssertEqual(ProjectScripts.load(folder: sub.path).map(\.name), ["Lint", "Test"])
    }
}
