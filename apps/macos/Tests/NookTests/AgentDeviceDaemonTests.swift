import XCTest

/// The agent-device daemon's lifecycle (`DeviceHub` decisions, run by `DeviceHubService`).
final class AgentDeviceDaemonTests: XCTestCase {
    private let current = DeviceHub.agentVersion

    private func record(pid: Int32? = 42, version: String = DeviceHub.agentVersion, entry: String = "/tools/agent-device/x/entry.mjs") -> DeviceHub.DaemonRecord {
        DeviceHub.DaemonRecord(pid: pid, version: version, entry: entry, node: "/usr/local/bin/node")
    }

    func testDaemonFileReadsPidAndVersion() {
        let daemon = DeviceHub.daemon(Data(#"{"httpPort":5123,"token":"t","pid":4321,"version":"0.20.1"}"#.utf8))
        XCTAssertEqual(daemon, DeviceHub.AgentDaemon(port: 5123, token: "t", pid: 4321, version: "0.20.1"))
        XCTAssertEqual(DeviceHub.daemon(Data(#"{"httpPort":5123,"token":"t"}"#.utf8))?.pid, nil)
        XCTAssertNil(DeviceHub.daemon(Data(#"{"token":"t"}"#.utf8)))
    }

    func testRecordRoundTrips() throws {
        let data = try JSONEncoder().encode(record())
        XCTAssertEqual(DeviceHub.daemonRecord(data), record())
        XCTAssertNil(DeviceHub.daemonRecord(Data("{}".utf8)))
    }

    func testOnlyAHealthyDaemonOfTheCurrentVersionIsReused() {
        let same = DeviceHub.AgentDaemon(port: 1, token: "t", pid: 42, version: current)
        let older = DeviceHub.AgentDaemon(port: 1, token: "t", pid: 42, version: "0.1.0")
        let unknown = DeviceHub.AgentDaemon(port: 1, token: "t", pid: 42)
        XCTAssertEqual(DeviceHub.daemonReuse(nil, record: nil, healthy: false), .start)
        XCTAssertEqual(DeviceHub.daemonReuse(same, record: nil, healthy: false), .start, "one that does not answer is replaced by a new start")
        XCTAssertEqual(DeviceHub.daemonReuse(same, record: nil, healthy: true), .reuse)
        XCTAssertEqual(DeviceHub.daemonReuse(older, record: nil, healthy: true), .replace)
        // The file does not say the version: Nook's record of the same pid does.
        XCTAssertEqual(DeviceHub.daemonReuse(unknown, record: record(version: "0.1.0"), healthy: true), .replace)
        XCTAssertEqual(DeviceHub.daemonReuse(unknown, record: record(), healthy: true), .reuse)
        // A record of another pid says nothing about this daemon.
        XCTAssertEqual(DeviceHub.daemonReuse(unknown, record: record(pid: 7, version: "0.1.0"), healthy: true), .reuse)
        XCTAssertEqual(DeviceHub.daemonReuse(unknown, record: nil, healthy: true), .reuse)
    }

    func testStopUsesTheRecordedVersionsCliFirst() {
        let daemon = DeviceHub.AgentDaemon(port: 1, token: "t", pid: 42, version: "0.1.0")
        let old = record(version: "0.1.0", entry: "/tools/agent-device/0.1.0/entry.mjs")
        let stop = DeviceHub.daemonStop(record: old, daemon: daemon, currentNode: "/opt/node", currentEntry: "/tools/agent-device/new/entry.mjs",
                                        alive: { _ in true }, exists: { _ in true })
        XCTAssertEqual(stop, .run(node: old.node, entry: old.entry))
    }

    func testStopFallsBackToTheCurrentCliThenToASignal() {
        let daemon = DeviceHub.AgentDaemon(port: 1, token: "t", pid: 42)
        let old = record(entry: "/gone/entry.mjs")
        let current = DeviceHub.daemonStop(record: old, daemon: daemon, currentNode: "/opt/node", currentEntry: "/now/entry.mjs",
                                           alive: { _ in true }, exists: { $0 != "/gone/entry.mjs" })
        XCTAssertEqual(current, .run(node: "/opt/node", entry: "/now/entry.mjs"))
        let none = DeviceHub.daemonStop(record: old, daemon: daemon, currentNode: nil, currentEntry: "/now/entry.mjs",
                                        alive: { _ in true }, exists: { _ in false })
        XCTAssertEqual(none, .signal(pid: 42))
    }

    func testARecordWhoseProcessIsGoneIsDropped() {
        XCTAssertEqual(DeviceHub.daemonStop(record: record(), daemon: nil, currentNode: "/n", currentEntry: "/e",
                                            alive: { _ in false }, exists: { _ in true }), .forget)
        XCTAssertEqual(DeviceHub.daemonStop(record: nil, daemon: nil, currentNode: "/n", currentEntry: "/e",
                                            alive: { _ in true }, exists: { _ in true }), .nothing)
    }

    func testAnEarlierInstallStaysWhileItsDaemonRuns() {
        let folder = URL(fileURLWithPath: "/tools/agent-device/0.1.0", isDirectory: true)
        XCTAssertTrue(DeviceHub.inUse(folder, by: record(entry: "/tools/agent-device/0.1.0/node_modules/agent-device/bin/agent-device.mjs")))
        XCTAssertFalse(DeviceHub.inUse(folder, by: record(entry: "/tools/agent-device/0.1.00/entry.mjs")))
        XCTAssertFalse(DeviceHub.inUse(folder, by: nil))
    }

    func testStopArgumentsNameTheStateDirectory() {
        XCTAssertEqual(DeviceHub.daemonStopArguments(entry: "/e.mjs", stateDir: "/s"), ["/e.mjs", "daemon", "stop", "--state-dir", "/s"])
    }
}
