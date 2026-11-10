import XCTest

/// Real keepers with a real shell script as the agent, in a temporary folder.
final class SessionKeeperTests: XCTestCase {
    var base: URL!
    var script: URL!

    override func setUpWithError() throws {
        // Socket paths are short: not under the long test folder.
        base = URL(fileURLWithPath: "/tmp/nkk-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        script = try SessionKeeper.install(at: base.appendingPathComponent("keeper"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var ended: Int32?
        func add(_ data: Data) { lock.withLock { bytes.append(data) } }
        func end(_ status: Int32) { lock.withLock { ended = status } }
        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        var status: Int32? { lock.withLock { ended } }
    }

    private func start(_ transport: KeptTransport, _ shell: String, keepsInput: Bool = true) throws -> Collected {
        let seen = Collected()
        try transport.start(.init(executable: "/bin/sh", arguments: ["-c", shell], environment: ["PATH": "/usr/bin:/bin"],
                                  workingDirectory: "/tmp", keepsInputOpen: keepsInput),
                            onStdout: { seen.add($0) }, onStderr: { _ in }, onExit: { seen.end($0) })
        return seen
    }

    func startForStop(_ transport: KeptTransport) throws -> Collected {
        try start(transport, "echo started; sleep 30")
    }

    private func wait(_ what: String, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !check(), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(check(), what)
    }

    func testFramesSurviveBeingCut() {
        var whole = SessionKeeper.encode(.stdout, Data("hello".utf8)) + SessionKeeper.encode(.exit, Data("0".utf8))
        var part = whole.prefix(4)
        XCTAssertEqual(SessionKeeper.decode(&part), [])
        XCTAssertEqual(part.count, 4)
        let frames = SessionKeeper.decode(&whole)
        XCTAssertEqual(frames?.map(\.kind), [.stdout, .exit])
        XCTAssertEqual(frames?.first?.payload, Data("hello".utf8))
        XCTAssertEqual(whole.count, 0)
        var bad = Data([0, 0, 0, 0, 0])
        XCTAssertNil(SessionKeeper.decode(&bad))
    }

    func testAnAgentRunsAndEnds() throws {
        let transport = KeptTransport(folder: base.appendingPathComponent("a"), script: script.path)
        let seen = try start(transport, "read line; echo got:$line; exit 7")
        try transport.write(Data("hi\n".utf8))
        wait("it ended") { seen.status != nil }
        XCTAssertEqual(seen.text, "got:hi\n")
        XCTAssertEqual(seen.status, 7)
        wait("the keeper cleaned up") { !FileManager.default.fileExists(atPath: self.base.appendingPathComponent("a").path) }
    }

    func testTheAgentOutlivesNookAndNothingIsLost() throws {
        let folder = base.appendingPathComponent("b")
        let first = KeptTransport(folder: folder, script: script.path)
        let seen = try start(first, "echo one; read line; echo two:$line; read line; echo three; exit 3")
        wait("first line") { seen.text == "one\n" }
        let offset = first.offset
        first.detach()
        XCTAssertTrue(KeptTransport.isAlive(folder: folder))
        // The agent carries on with nobody watching; a new Nook takes over where the old one read.
        let second = KeptTransport(folder: folder, script: script.path, offset: offset)
        let later = Collected()
        try second.start(.init(executable: "", arguments: [], environment: [:], workingDirectory: "/", keepsInputOpen: true),
                         onStdout: { later.add($0) }, onStderr: { _ in }, onExit: { later.end($0) })
        try second.write(Data("x\n".utf8))
        wait("second line") { later.text == "two:x\n" }
        try second.write(Data("y\n".utf8))
        wait("it ended") { later.status == 3 }
        XCTAssertEqual(later.text, "two:x\nthree\n")
    }

    func testOutputWhileNobodyWatchesIsReplayed() throws {
        let folder = base.appendingPathComponent("c")
        let first = KeptTransport(folder: folder, script: script.path)
        let seen = try start(first, "echo ready; read line; echo during; exit 0")
        wait("ready") { seen.text == "ready\n" }
        let offset = first.offset
        try first.write(Data("go\n".utf8))
        first.detach()
        usleep(300_000)
        let second = KeptTransport(folder: folder, script: script.path, offset: offset)
        let later = Collected()
        try second.start(.init(executable: "", arguments: [], environment: [:], workingDirectory: "/", keepsInputOpen: true),
                         onStdout: { later.add($0) }, onStderr: { _ in }, onExit: { later.end($0) })
        wait("replayed") { later.status == 0 }
        XCTAssertEqual(later.text, "during\n")
    }

    func testStoppingSignalsTheGroup() throws {
        let transport = KeptTransport(folder: base.appendingPathComponent("d"), script: script.path)
        let seen = try start(transport, "sleep 30 & echo started; wait")
        wait("started") { seen.text == "started\n" }
        transport.signalGroup(SIGTERM)
        wait("it ended") { seen.status != nil }
        XCTAssertEqual(seen.status, SIGTERM)
    }

    func testAStoppedAgentIsSeenThroughWithNookGone() throws {
        let folder = base.appendingPathComponent("e")
        let transport = KeptTransport(folder: folder, script: script.path)
        let seen = try start(transport, "trap '' INT; echo started; sleep 30")
        wait("started") { seen.text == "started\n" }
        transport.stopForGood()
        transport.detach()
        // INT is ignored, so the keeper goes on to TERM by itself, and cleans up with nobody connected.
        wait("cleaned up") { !FileManager.default.fileExists(atPath: folder.path) }
    }

    func testStoppingWithNookThereEndsAsUsual() throws {
        let transport = KeptTransport(folder: base.appendingPathComponent("i"), script: script.path)
        let seen = try start(transport, "trap 'echo bye; exit 9' INT; echo started; while :; do sleep 0.1; done")
        wait("started") { seen.text == "started\n" }
        transport.stopForGood()
        wait("it ended with its own status") { seen.status == 9 }
        XCTAssertEqual(seen.text, "started\nbye\n")
    }

    func testAnEndedAgentWaitsForNook() throws {
        let folder = base.appendingPathComponent("f")
        let first = KeptTransport(folder: folder, script: script.path)
        let seen = try start(first, "echo a; read line; echo b; exit 5")
        wait("a") { seen.text == "a\n" }
        let offset = first.offset
        try first.write(Data("go\n".utf8))
        first.detach()
        usleep(1_500_000)
        XCTAssertTrue(KeptTransport.isAlive(folder: folder), "the keeper stays until Nook has the end")
        let second = KeptTransport(folder: folder, script: script.path, offset: offset)
        let later = Collected()
        try second.start(.init(executable: "", arguments: [], environment: [:], workingDirectory: "/", keepsInputOpen: true),
                         onStdout: { later.add($0) }, onStderr: { _ in }, onExit: { later.end($0) })
        wait("the end arrived") { later.status == 5 }
        XCTAssertEqual(later.text, "b\n")
    }

    /// Complete lines only: half a line is not handled, so another Nook reads it whole.
    func testHandledOffsetCountsCompleteLines() throws {
        let folder = base.appendingPathComponent("g")
        let spec = LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf 'one\\ntw'; sleep 30"], extraEnvironment: [:],
                              workingDirectory: "/tmp", initialInput: [], keepsInputOpen: true,
                              keeper: KeeperPlacement(folder: folder.path, script: script.path))
        let process = AgentProcess(spec: spec)
        process.onLines = { [weak process] lines in
            XCTAssertEqual(lines, ["one"])
            process?.markHandled(process?.consumed ?? 0)
        }
        try process.start()
        wait("handled") { process.handledOffset == 4 }
        process.stop()
    }

    func testAnOldPromptsAnswerReachesTheNewNook() throws {
        let folder = base.appendingPathComponent("h")
        let first = KeptTransport(folder: folder, script: script.path)
        let seen = try start(first, #"echo ready; read line; echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'; sleep 1"#)
        wait("ready") { seen.text == "ready\n" }
        let offset = first.offset
        try first.write(Data("go\n".utf8))
        first.detach()
        let spec = LaunchSpec(executable: "", arguments: [], extraEnvironment: [:], workingDirectory: "/", initialInput: [],
                              keepsInputOpen: true, keeper: KeeperPlacement(folder: folder.path, script: script.path, offset: offset))
        let client = AcpClient(spec: spec)
        let answer = Collected()
        client.onOrphanAnswer = { answer.add(Data(($0.dictionary["stopReason"] as? String ?? "").utf8)) }
        try client.start()
        wait("the turn's end") { answer.text == "end_turn" }
    }

    func testAKeptSessionStaysActiveOverLoading() throws {
        let store = RunStore(directory: base.appendingPathComponent("store", isDirectory: true))
        var kept = Self.run(status: .running)
        kept.kept = KeptSession(folder: "x", offset: 5)
        let plain = Self.run(status: .running)
        try store.saveRuns([kept, plain])
        let loaded = store.loadRuns()
        XCTAssertEqual(loaded.first { $0.id == kept.id }?.status, .running)
        XCTAssertEqual(loaded.first { $0.id == kept.id }?.kept?.offset, 5)
        XCTAssertNotEqual(loaded.first { $0.id == plain.id }?.status, .running)
    }

    private static func run(status: RunStatus) -> WorkspaceRun {
        let now = Date()
        return WorkspaceRun(id: UUID(), title: "t", task: "t", provider: .claude, profileID: "claude", model: "", mode: .agent,
                            permission: .ask, isolation: .folder, projectPath: "/tmp", workingDirectory: "/tmp", repoRoot: nil,
                            branch: nil, baseBranch: nil, worktreePath: nil, instructions: "", status: status, statusDetail: nil,
                            providerSessionID: nil, createdAt: now, updatedAt: now, archived: false, usage: RunUsage(),
                            turnStartedAt: now, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil)
    }

    func testAMissingKeeperSaysSo() {
        XCTAssertFalse(KeptTransport.isAlive(folder: base.appendingPathComponent("nothing")))
        let transport = KeptTransport(folder: base.appendingPathComponent("nothing"), script: script.path, offset: 0)
        XCTAssertThrowsError(try transport.start(.init(executable: "", arguments: [], environment: [:], workingDirectory: "/", keepsInputOpen: true),
                                                 onStdout: { _ in }, onStderr: { _ in }, onExit: { _ in }))
    }
}

extension SessionKeeperTests {
    /// Settings' "Stop unused": a keeper with nobody attached is stopped by its folder alone and cleans up.
    func testAnUnclaimedKeeperStopsByItsFolder() throws {
        let folder = base.appendingPathComponent("j")
        let transport = KeptTransport(folder: folder, script: script.path)
        let seen = try startForStop(transport)
        let deadline = Date().addingTimeInterval(8)
        while seen.text != "started\n", Date() < deadline { usleep(20_000) }
        transport.detach()
        XCTAssertTrue(KeptTransport.stop(folder: folder))
        let gone = Date().addingTimeInterval(12)
        while FileManager.default.fileExists(atPath: folder.path), Date() < gone { usleep(50_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(KeptTransport.stop(folder: folder))
    }
}
