import XCTest

/// The governor on real processes: two fake agents each start a command in a process group of its own (as Claude Code
/// does); when the Mac swaps hard, the younger one's command holds still, the older one's goes on, and whatever was paused
/// always comes back: on release, at quit, and after a crash.
final class AgentGovernorTests: XCTestCase {
    private var folder: String!
    private var commands: [Int32] = []
    private var agents: [AgentProcess] = []

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "agent-governor-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for pid in commands {
            kill(pid, SIGCONT)
            kill(pid, SIGKILL)
        }
        for agent in agents { agent.stop(grace: 0.5) }
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// A fake agent that starts `sleep` in a process group of its own and says its pid.
    private func startAgent(_ name: String) throws -> (agent: AgentProcess, command: Int32) {
        let path = folder + "/\(name).sh"
        try "#!/bin/sh\nperl -e 'setpgrp(0,0); exec \"sleep\", \"60\"' &\necho $!\nwait\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let spec = LaunchSpec(executable: path, arguments: [], extraEnvironment: ["NOOK_RUN_ID": UUID().uuidString],
                              workingDirectory: folder, initialInput: [], keepsInputOpen: false)
        let agent = AgentProcess(spec: spec)
        let said = expectation(description: "\(name) started its command")
        let pid = LockedBox<Int32>(0)
        agent.onLine = { line in
            if let value = Int32(line) {
                pid.value = value
                said.fulfill()
            }
        }
        try agent.start()
        agents.append(agent)
        wait(for: [said], timeout: 10)
        commands.append(pid.value)
        // The command has moved to its own group before the governor looks.
        for _ in 0..<50 where ProcessIdentity.of(pid.value)?.processGroup != pid.value { usleep(20_000) }
        return (agent, pid.value)
    }

    private func ps(_ field: String, _ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "\(field)=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isStopped(_ pid: Int32) -> Bool { ps("stat", pid).hasPrefix("T") }

    func testPausesTheYoungestAgentsCommandAndAlwaysBringsItBack() throws {
        let record = URL(fileURLWithPath: folder + "/paused-groups.json")
        let governor = AgentGovernor(record: record)
        let older = try startAgent("older")
        Thread.sleep(forTimeInterval: 1.1)
        let younger = try startAgent("younger")

        governor.readNow(forcing: .critical)
        XCTAssertTrue(isStopped(younger.command), "the younger agent's command waits")
        XCTAssertFalse(isStopped(older.command), "the older one goes on")
        XCTAssertFalse(isStopped(younger.agent.pid), "the agent itself keeps running")
        XCTAssertEqual(ps("pri", older.command), "4", "the commands that go on run in the background band")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "written down, so a crash cannot leave it paused")

        // Nook quits: everything comes back, out of the background band too.
        governor.releaseAll()
        XCTAssertFalse(isStopped(younger.command))
        XCTAssertNotEqual(ps("pri", older.command), "4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))

        // Paused again, then Nook crashes: the next Nook finds the record and lets it go on.
        governor.readNow(forcing: .critical)
        XCTAssertTrue(isStopped(younger.command))
        AgentGovernor(record: record).resumeLeftoversNow()
        XCTAssertFalse(isStopped(younger.command), "resumed after a crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testCalmMacLeavesCommandsAloneAndStoppingAnAgentReleasesItsCommand() throws {
        let governor = AgentGovernor(record: URL(fileURLWithPath: folder + "/paused-groups.json"))
        let older = try startAgent("older")
        Thread.sleep(forTimeInterval: 1.1)
        let younger = try startAgent("younger")

        governor.readNow(forcing: .calm)
        XCTAssertFalse(isStopped(younger.command))
        XCTAssertNotEqual(ps("pri", older.command), "4")

        governor.readNow(forcing: .critical)
        XCTAssertTrue(isStopped(younger.command))
        governor.release(agent: younger.agent.pid)
        XCTAssertFalse(isStopped(younger.command), "an agent that stops lets its commands go on first")
    }
}

/// A value set from another thread.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
