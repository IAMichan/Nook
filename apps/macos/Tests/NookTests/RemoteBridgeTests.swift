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

    func testPaths() {
        XCTAssertEqual(RemoteBridge.socketPath(home: "/home/a", run: id), "/home/a/.nook/b-abcdef12.sock")
        XCTAssertEqual(RemoteBridge.forward(socket: "/s", local: "/l b").suffix(2), ["-R", "/s:/l b"])
    }

    func testTheServerGetsItsWayBack() {
        let launch = BridgeLaunch(script: "/home/a/.nook/nook-mcp", remote: .init(socket: "/s", token: "t"))
        let environment = launch.environment(runID: id)
        XCTAssertEqual(environment["NOOK_BRIDGE_SOCK"], "/s")
        XCTAssertEqual(environment["NOOK_BRIDGE_TOKEN"], "t")
        XCTAssertEqual(launch.note, RemoteBridge.instructions)
        XCTAssertTrue(launch.codexArguments(runID: id).contains { $0.contains("NOOK_BRIDGE_SOCK = \"/s\"") })
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

    func testSetupPutsTheScriptInPlaceAndChecksPerl() {
        let command = RemoteBridge.setupCommand(script: "hello")
        XCTAssertTrue(command.contains(Data("hello".utf8).base64EncodedString()))
        XCTAssertTrue(command.contains("JSON::PP"))
        XCTAssertTrue(command.hasSuffix(#"printf %s "$HOME""#))
    }
}
