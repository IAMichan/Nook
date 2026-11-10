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

    func testSetupScriptCanHoldTheAgent() {
        let json = #"{"scripts":[{"name":"Install","command":"pnpm install","runOnWorktreeCreate":true,"async":false},{"name":"Env","command":"cp .env.example .env","runOnWorktreeCreate":true},{"name":"Dev","command":"pnpm dev","async":false}]}"#
        let scripts = ProjectScripts.parse(Data(json.utf8))
        XCTAssertEqual(scripts.map(\.async), [false, true, false], "async is true unless the file says false")
        let setup = ProjectScripts.setup(scripts)
        XCTAssertEqual(setup.scripts.map(\.name), ["Install", "Env"], "async only matters for setup scripts")
        XCTAssertTrue(setup.holdsAgent)
        XCTAssertFalse(ProjectScripts.setup([scripts[1], scripts[2]]).holdsAgent, "a script that is no setup script holds nothing")
        XCTAssertFalse(ProjectScripts.setup([]).holdsAgent)
    }

    func testBlockingCommandWritesItsExitCode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ command: String) throws -> (shell: Int32, written: Int32?) {
            let status = folder.appendingPathComponent("it's \(UUID().uuidString)").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", ProjectScripts.blockingCommand(command, statusFile: status) + "; exit 99"]
            process.currentDirectoryURL = folder
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, ProjectScripts.exitStatus(FileManager.default.contents(atPath: status)))
        }
        let ok = try run("echo 'ready' > out.txt && test -f out.txt")
        XCTAssertEqual(ok.written, 0)
        XCTAssertEqual(ok.shell, 0, "a script that succeeds ends its terminal")
        let failed = try run("exit 3")
        XCTAssertEqual(failed.written, 3)
        XCTAssertEqual(failed.shell, 99, "a script that fails leaves its terminal to the shell")
        XCTAssertNil(ProjectScripts.exitStatus(nil))
        XCTAssertNil(ProjectScripts.exitStatus(Data()))
        XCTAssertEqual(ProjectScripts.exitStatus(Data("1\n".utf8)), 1)
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
