import XCTest

final class RemoteBridgeTests: XCTestCase {
    private let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!

    func testNothingThatActsOnTheMacIsAllowed() {
        for tool: BridgeTool in [.terminalRun, .pullRequestCreate, .delegateTask, .sessionStart, .sessionSend, .nookUse,
                                 .requestSecret, .takeOverScreen, .deviceOpen, .scheduleTask] {
            XCTAssertFalse(RemoteBridge.allows(tool), tool.rawValue)
        }
        XCTAssertTrue(RemoteBridge.allows(.browserOpen))
        XCTAssertTrue(RemoteBridge.allows(.sessionRead))
    }

    func testAnotherMachineReachesOnlyItsOwnSession() {
        XCTAssertFalse(RemoteBridge.allows(.sessionList))
        XCTAssertFalse(RemoteBridge.allows(.sessionSearch))
        XCTAssertTrue(RemoteBridge.mayRead(id.uuidString.lowercased(), caller: id))
        XCTAssertFalse(RemoteBridge.mayRead(UUID().uuidString, caller: id))
        XCTAssertFalse(RemoteBridge.mayRead(nil, caller: id))
    }

    func testPaths() {
        XCTAssertEqual(RemoteBridge.socketPath(home: "/home/a", run: id), "/home/a/.nook/b-abcdef12.sock")
        XCTAssertEqual(RemoteBridge.tokenPath(home: "/home/a", run: id), "/home/a/.nook/bridge-tokens/" + id.uuidString.lowercased())
        XCTAssertEqual(RemoteBridge.forward(socket: "/s", local: "/l b").suffix(2), ["-R", "/s:/l b"])
    }

    func testTheServerGetsItsWayBack() {
        let launch = BridgeLaunch(script: "/home/a/.nook/nook-mcp",
                                  remote: .init(socket: "/s", token: "secret-token", tokenFile: "/home/a/.nook/bridge-tokens/x"))
        let environment = launch.environment(runID: id)
        XCTAssertEqual(environment["NOOK_BRIDGE_SOCK"], "/s")
        XCTAssertEqual(environment[BridgeTokenFiles.variable], "/home/a/.nook/bridge-tokens/x")
        XCTAssertNil(environment["NOOK_BRIDGE_TOKEN"])
        XCTAssertEqual(launch.note, RemoteBridge.instructions)
        XCTAssertTrue(launch.codexArguments(runID: id).contains { $0.contains("NOOK_BRIDGE_SOCK = \"/s\"") })
        // On no command line there: not Claude Code's, not Codex's.
        XCTAssertFalse((launch.claudeArguments(runID: id) + launch.codexArguments(runID: id)).contains { $0.contains("secret-token") })
        XCTAssertNil(BridgeLaunch(script: "/x").environment(runID: id)["NOOK_BRIDGE_SOCK"])
    }

    func testAForwardGoesInFrontOfTheHost() {
        var target = RemoteTarget(machine: RemoteMachine(name: "pi", host: "pi"), directory: "/d")
        target.host = "pi"
        let spec = RemoteLaunch.wrap(LaunchSpec(executable: "claude", arguments: [], extraEnvironment: [:], workingDirectory: "/",
                                                initialInput: [], keepsInputOpen: true),
                                     target: target, forward: RemoteBridge.forward(socket: "/s", local: "/l"))
        XCTAssertLessThan(spec.arguments.firstIndex(of: "-R")!, spec.arguments.firstIndex(of: "--")!)
    }

    func testTheTokenGoesOverStdinNotOnTheCommandLine() {
        let target = RemoteTarget(machine: RemoteMachine(name: "pi", host: "pi"), directory: "/d")
        let token = RemoteLaunch.Token(value: "secret-token", file: "/home/a/.nook/bridge-tokens/x")
        let claude = RemoteLaunch.wrap(LaunchSpec(executable: "claude", arguments: ["-p"], extraEnvironment: [:], workingDirectory: "/",
                                                  initialInput: ["hello"], keepsInputOpen: true), target: target, token: token)
        XCTAssertFalse(claude.arguments.contains { $0.contains("secret-token") })
        XCTAssertEqual(claude.secretInput, "secret-token")
        XCTAssertEqual(claude.initialInput, ["hello"])
        XCTAssertTrue(claude.keepsInputOpen)
        XCTAssertFalse(claude.closesInputAfterStart)
        XCTAssertTrue(claude.arguments.last!.contains("nook-token /home/a/.nook/bridge-tokens/x"))
        XCTAssertFalse(claude.arguments.last!.contains("/dev/null"))

        // An agent without stdin (codex exec): stdin is open only for the token, and the agent gets /dev/null there.
        let codex = RemoteLaunch.wrap(LaunchSpec(executable: "codex", arguments: ["exec"], extraEnvironment: [:], workingDirectory: "/",
                                                 initialInput: [], keepsInputOpen: false), target: target, token: token)
        XCTAssertTrue(codex.keepsInputOpen)
        XCTAssertTrue(codex.closesInputAfterStart)
        XCTAssertTrue(codex.arguments.last!.contains("</dev/null"))

        // Without a bridge nothing changes.
        let plain = RemoteLaunch.wrap(LaunchSpec(executable: "codex", arguments: ["exec"], extraEnvironment: [:], workingDirectory: "/",
                                                 initialInput: [], keepsInputOpen: false), target: target)
        XCTAssertNil(plain.secretInput)
        XCTAssertFalse(plain.keepsInputOpen)
        XCTAssertFalse(plain.arguments.last!.contains("nook-token"))
    }

    /// The remote side's writer, run here in /bin/sh: the first line becomes a 0600 file in a 0700 folder, and what follows
    /// is left for the agent.
    func testTheWriterTakesOnlyTheFirstLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tokens").appendingPathComponent("run").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteLaunch.tokenWriter(file: file) + "; cat"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("secret-token\n{\"type\":\"user\"}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let rest = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(rest, "{\"type\":\"user\"}\n")
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "secret-token\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: (file as NSString).deletingLastPathComponent)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSetupPutsTheScriptInPlaceAndChecksPerl() {
        let command = RemoteBridge.setupCommand(script: "hello")
        XCTAssertTrue(command.contains(Data("hello".utf8).base64EncodedString()))
        XCTAssertTrue(command.contains("JSON::PP"))
        XCTAssertTrue(command.hasSuffix(#"printf %s "$HOME""#))
    }
}
