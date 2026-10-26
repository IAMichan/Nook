import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs scheduled work only when the test moves time forward.
final class ManualProcessScheduler: ProcessScheduler, @unchecked Sendable {
    private let condition = NSCondition()
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, work: @Sendable () -> Void)] = []
    private var order = 0

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        condition.lock()
        order += 1
        pending.append((now + seconds, order, work))
        condition.broadcast()
        condition.unlock()
    }

    var scheduledCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count
    }

    /// Blocks until `count` pieces of work are waiting (work scheduled from another thread), up to ten seconds.
    @discardableResult
    func waitUntilScheduled(_ count: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while pending.count < count {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    /// Runs, in order, everything due within `seconds` from now.
    func advance(by seconds: TimeInterval) {
        condition.lock()
        now += seconds
        let due = pending.filter { $0.at <= now }.sorted { ($0.at, $0.order) < ($1.at, $1.order) }
        pending.removeAll { $0.at <= now }
        condition.unlock()
        for item in due { item.work() }
    }
}

final class ProcessGroupsTests: XCTestCase {
    private func identity(_ pid: Int32, group: Int32? = nil, start: UInt64 = 100) -> ProcessIdentity {
        ProcessIdentity(pid: pid, processGroup: group ?? pid, startTime: start)
    }

    private func group(_ pid: Int32, start: UInt64 = 100, owner: ProcessIdentity? = nil) -> LiveProcessGroup {
        LiveProcessGroup(leader: identity(pid, start: start), owner: owner ?? identity(1, start: 1), executable: "/usr/bin/agent",
                         started: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func temporaryURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-pg-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("process-groups.json")
    }

    // MARK: Identity

    func testLinuxStatIsReadAfterTheProcessName() {
        // A name with spaces and a parenthesis must not shift the fields.
        let stat = "4242 (my (odd) agent) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 3 0 987654 1000 10"
        XCTAssertEqual(ProcessIdentity.parseLinuxStat(stat, pid: 4242), identity(4242, group: 4242, start: 987654))
        XCTAssertNil(ProcessIdentity.parseLinuxStat("4242 (zombie) Z 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0", pid: 4242))
        XCTAssertNil(ProcessIdentity.parseLinuxStat("garbage", pid: 1))
    }

    func testOwnIdentityIsReadable() throws {
        #if os(macOS) || os(Linux)
        let me = try XCTUnwrap(ProcessIdentity.of(getpid()))
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.processGroup, getpgrp())
        XCTAssertEqual(ProcessIdentity.of(getpid()), me, "the same process reads the same identity")
        #endif
    }

    // MARK: Verdicts

    func testOnlyAnUnchangedLeaderIsStopped() {
        let recorded = group(500, start: 100)
        XCTAssertEqual(LeftoverProcessGroups.verdict(recorded, current: identity(500, start: 100)), .stop)
        XCTAssertEqual(LeftoverProcessGroups.verdict(recorded, current: nil), .gone)
        // Same pid, later start: another program got the pid.
        XCTAssertEqual(LeftoverProcessGroups.verdict(recorded, current: identity(500, start: 101)), .reused)
        // Same process, but it moved to another group.
        XCTAssertEqual(LeftoverProcessGroups.verdict(recorded, current: identity(500, group: 77, start: 100)), .reused)
    }

    func testLeftoversGetTermThenKillAfterACheck() {
        let scheduler = ManualProcessScheduler()
        let signals = SentSignalLog()
        let world = FakeProcessTable([500: identity(500, start: 100), 600: identity(600, start: 999)])
        let stopped = LeftoverProcessGroups.stop([group(500, start: 100), group(600, start: 100), group(700)],
                                                 identity: world.identity, signal: signals.record, scheduler: scheduler)
        XCTAssertEqual(stopped.map(\.groupID), [500], "600 was reused, 700 is gone")
        XCTAssertEqual(signals.sent, [SentSignal(group: 500, signal: SIGTERM)])
        scheduler.advance(by: 2)
        XCTAssertEqual(signals.sent, [SentSignal(group: 500, signal: SIGTERM), SentSignal(group: 500, signal: SIGKILL)])
    }

    func testNoKillWhenThePidIsReusedDuringTheGrace() {
        let scheduler = ManualProcessScheduler()
        let signals = SentSignalLog()
        let world = FakeProcessTable([500: identity(500, start: 100)])
        LeftoverProcessGroups.stop([group(500, start: 100)], identity: world.identity, signal: signals.record, scheduler: scheduler)
        // The leader exits on SIGTERM and a new program gets pid 500.
        world.set(500, identity(500, start: 200))
        scheduler.advance(by: 2)
        XCTAssertEqual(signals.sent, [SentSignal(group: 500, signal: SIGTERM)])
    }

    // MARK: Ledger

    func testLedgerRecordsAndForgets() {
        let ledger = ProcessGroupLedger(url: temporaryURL())
        ledger.record(group(10))
        ledger.record(group(11))
        ledger.record(group(10, start: 5))
        XCTAssertEqual(ledger.entries().map(\.groupID), [11, 10])
        XCTAssertEqual(ledger.entries().last?.leader.startTime, 5, "a group id is written once, latest wins")
        ledger.forget(groupID: 11)
        XCTAssertEqual(ProcessGroupLedger(url: ledger.url).entries().map(\.groupID), [10], "kept on disk")
    }

    func testLeftoversOfARunningNookStayOnTheLedger() {
        let ledger = ProcessGroupLedger(url: temporaryURL())
        let otherNook = identity(300, start: 30)
        let crashedNook = identity(301, start: 31)
        ledger.record(group(10, owner: otherNook))
        ledger.record(group(11, owner: crashedNook))
        let world = FakeProcessTable([300: otherNook])
        let leftovers = ledger.takeLeftovers(me: identity(400), identity: world.identity)
        XCTAssertEqual(leftovers.map(\.groupID), [11])
        XCTAssertEqual(ledger.entries().map(\.groupID), [10], "the other Nook's agent is not ours to stop")
        XCTAssertEqual(ledger.takeLeftovers(me: identity(400), identity: world.identity), [], "taken once")
    }

    func testUnreadableLedgerIsEmpty() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ProcessGroupLedger(url: url).entries(), [])
    }

    // MARK: Real processes

    func testAgentLeadsItsOwnGroupAndTheGroupIsStopped() throws {
        let ledger = ProcessGroupLedger(url: temporaryURL())
        let process = SpawnedProcess()
        let lines = GroupLineWaiter()
        let ended = expectation(description: "stdout closed by every process in the group")
        let exited = expectation(description: "exited")
        // The background sleep keeps stdout open: the stream only ends once it is gone too.
        try process.start(.init(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"],
                                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", keepsInputOpen: false),
                          ledger: ledger,
                          onStdout: { data in
                              if data.isEmpty { ended.fulfill() } else { lines.append(data) }
                          },
                          onStderr: { _ in }, onExit: { _ in exited.fulfill() })
        let child = try XCTUnwrap(lines.waitForFirstLine().flatMap { Int32($0) })
        XCTAssertNotEqual(process.pid, getpgrp(), "not in Nook's group")
        XCTAssertEqual(ProcessIdentity.of(process.pid)?.processGroup, process.pid, "the agent leads its group")
        XCTAssertEqual(ProcessIdentity.of(child)?.processGroup, process.pid, "what it starts is in the group too")
        XCTAssertEqual(ledger.entries().map(\.groupID), [process.pid])

        XCTAssertTrue(process.signalGroup(SIGTERM))
        wait(for: [ended, exited], timeout: 10)
        XCTAssertNil(ProcessIdentity.of(child), "the agent's child was stopped with it")
    }

    func testExitedLeaderStaysSignallableWhileHeld() throws {
        let ledger = ProcessGroupLedger(url: temporaryURL())
        let process = SpawnedProcess()
        let exited = expectation(description: "exited")
        let status = ExitStatusBox()
        try process.start(.init(executable: "/bin/sh", arguments: ["-c", "read line; exit 3"],
                                environment: [:], workingDirectory: "/", keepsInputOpen: true),
                          ledger: ledger, onStdout: { _ in }, onStderr: { _ in },
                          onExit: { code in status.set(code); exited.fulfill() })
        process.hold()
        try process.write(Data("go\n".utf8))
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(status.value, 3)
        XCTAssertFalse(process.isRunning)
        XCTAssertTrue(process.signalGroup(0), "unreaped: the group id is still ours")
        XCTAssertEqual(ledger.entries().count, 1)
        process.release()
        XCTAssertFalse(process.signalGroup(0), "reaped: never signalled again")
        XCTAssertEqual(ledger.entries(), [])
    }

    func testStopEscalatesToTheWholeGroup() throws {
        let scheduler = ManualProcessScheduler()
        let spec = LaunchSpec(executable: "/bin/sh",
                              // Background jobs of a non-interactive shell ignore SIGINT: only SIGTERM ends the sleep.
                              arguments: ["-c", "sleep 30 & echo started; wait"],
                              extraEnvironment: [:], workingDirectory: "/", initialInput: [], keepsInputOpen: false)
        let process = AgentProcess(spec: spec, scheduler: scheduler)
        let started = expectation(description: "started")
        let exited = expectation(description: "exited")
        process.onLine = { _ in started.fulfill() }
        process.onExit = { _, _ in exited.fulfill() }
        try process.start()
        wait(for: [started], timeout: 10)
        process.stop(grace: 4)
        XCTAssertEqual(scheduler.scheduledCount, 2, "SIGTERM and SIGKILL are scheduled, nothing waits")
        scheduler.advance(by: 4)
        // SIGTERM ended the shell and its sleep; the exit is delivered through the scheduler too, next to the SIGKILL.
        XCTAssertTrue(scheduler.waitUntilScheduled(2))
        scheduler.advance(by: 4)
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(process.isRunning)
    }
}

private struct SentSignal: Equatable {
    var group: Int32
    var signal: Int32
}

private final class SentSignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [SentSignal] = []
    var sent: [SentSignal] { lock.lock(); defer { lock.unlock() }; return log }
    var record: @Sendable (Int32, Int32) -> Void {
        { [self] group, signal in lock.lock(); log.append(SentSignal(group: group, signal: signal)); lock.unlock() }
    }
}

private final class FakeProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: ProcessIdentity]
    init(_ processes: [Int32: ProcessIdentity]) { self.processes = processes }
    func set(_ pid: Int32, _ identity: ProcessIdentity?) { lock.lock(); processes[pid] = identity; lock.unlock() }
    var identity: @Sendable (Int32) -> ProcessIdentity? {
        { [self] pid in lock.lock(); defer { lock.unlock() }; return processes[pid] }
    }
}

private final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Int32) { lock.lock(); stored = value; lock.unlock() }
}

private final class GroupLineWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()

    func append(_ chunk: Data) {
        condition.lock()
        data.append(chunk)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks (up to ten seconds) until a whole line arrived.
    func waitForFirstLine() -> String? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !data.contains(0x0A) {
            guard condition.wait(until: deadline) else { return nil }
        }
        return String(decoding: data.prefix(while: { $0 != 0x0A }), as: UTF8.self)
    }
}
