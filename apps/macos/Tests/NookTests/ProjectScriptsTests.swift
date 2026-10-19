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
        try Data(#"{"scripts":[{"name":"Dev","command":"pnpm dev"}]}"#.utf8).write(to: repo.appendingPathComponent("legacy-scripts.json"))
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(ProjectScripts.load(folder: sub.path).map(\.command), ["pnpm dev"])
    }
}
