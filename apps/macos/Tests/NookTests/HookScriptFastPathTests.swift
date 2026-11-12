import XCTest

/// The hook script runs before and after every tool call, and the agent waits for it. An agent Nook runs itself
/// (`NOOK_RUN_ID`) reports over its own connection and Nook drops what its hooks send, so for those the script must leave
/// at once, with the answer each agent needs. The script is read from `HookScript.swift` (AppKit keeps that file out of
/// the test target) and run with a home folder that has no Nook socket, so nothing real is reached.
final class HookScriptFastPathTests: XCTestCase {
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private var folder: URL!
    private var script: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hook-fast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try String(contentsOf: Self.root.appendingPathComponent("Services/HookScript.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static let contents = #\"\"\"\n"))
        let end = try XCTUnwrap(source.range(of: "\"\"\"#", range: start.upperBound..<source.endIndex))
        // The raw string's lines are indented by four spaces in the Swift source, as Swift strips them.
        let body = source[start.upperBound..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
        script = folder.appendingPathComponent("nook-hook.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String], runID: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path] + arguments
        var environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin"]
        if let runID { environment["NOOK_RUN_ID"] = runID }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "a hook never fails the agent")
        return String(decoding: data, as: UTF8.self)
    }

    func testAnAgentNookRunsGetsTheEmptyAnswerAtOnce() throws {
        XCTAssertEqual(try run(["--agent", "claude-code"], runID: "run-1"), "")
        XCTAssertEqual(try run(["--agent", "codex", "PreToolUse"], runID: "run-1"), "")
        // These agents always want JSON back.
        for agent in ["gemini", "antigravity", "copilot"] {
            XCTAssertEqual(try run(["--agent", agent, "PreToolUse"], runID: "run-1"), "{}\n", agent)
        }
    }

    func testTheFastPathAnswersAsTheFullScriptDoes() throws {
        // Without Nook's socket the full script gives the same answers: the fast path changes only the time it takes.
        for agent in ["claude-code", "gemini", "copilot"] {
            XCTAssertEqual(try run(["--agent", agent, "PreToolUse"], runID: nil),
                           try run(["--agent", agent, "PreToolUse"], runID: "run-1"), agent)
        }
    }
}
