import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class QuitShutdownTests: XCTestCase {
    // MARK: The escalation, on a clock the test moves

    func testNothingRunningReturnsAtOnce() {
        XCTAssertEqual(QuitShutdown.stopAll([]), .nothingRunning)
    }

    func testAgentsThatExitOnSigintGetNothingMore() {
        let clock = FakeClock()
        let a = FakeTarget(diesOn: SIGINT), b = FakeTarget(diesOn: SIGINT)
        let outcome = QuitShutdown.stopAll([a, b], timing: .init(grace: 2, deadline: 4.5, poll: 0.1),
                                           now: clock.now, sleep: clock.sleep)
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertEqual(a.signals, [SIGINT])
        XCTAssertEqual(b.signals, [SIGINT])
        XCTAssertTrue(a.ended && b.ended, "every group may be reaped afterwards")
        XCTAssertLessThan(clock.elapsed, 0.5)
    }

    func testOnlyWhatOutlivesTheGraceGetsSigterm() {
        let clock = FakeClock()
        let polite = FakeTarget(diesOn: SIGINT), stubborn = FakeTarget(diesOn: SIGTERM)
        let outcome = QuitShutdown.stopAll([polite, stubborn], timing: .init(grace: 2, deadline: 4.5, poll: 0.1),
                                           now: clock.now, sleep: clock.sleep)
        XCTAssertEqual(outcome, .terminated)
        XCTAssertEqual(polite.signals, [SIGINT])
        XCTAssertEqual(stubborn.signals, [SIGINT, SIGTERM])
        XCTAssertEqual(clock.elapsed, 2, accuracy: 0.15, "SIGTERM came at the grace")
    }

    func testOneSharedDeadlineThenSigkill() {
        let clock = FakeClock()
        let targets = (0..<5).map { _ in FakeTarget(diesOn: SIGKILL) }
        let outcome = QuitShutdown.stopAll(targets, timing: .init(grace: 2, deadline: 4.5, poll: 0.1),
                                           now: clock.now, sleep: clock.sleep)
        XCTAssertEqual(outcome, .killed)
        for target in targets { XCTAssertEqual(target.signals, [SIGINT, SIGTERM, SIGKILL]) }
        XCTAssertEqual(clock.elapsed, 4.5, accuracy: 0.15, "five stubborn agents together still take one deadline")
    }

    // MARK: Real processes

    func testRealAgentThatIgnoresEverythingIsKilledByTheDeadline() throws {
        // The shell and its sleep ignore SIGINT and SIGTERM (an ignored signal stays ignored across exec).
        let process = try started("trap '' INT TERM; sleep 30 & echo started; wait")
        let start = Date()
        let outcome = QuitShutdown.stopAll([process], timing: .init(grace: 0.3, deadline: 0.8, poll: 0.02))
        XCTAssertEqual(outcome, .killed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "quitting never waits past the deadline")
        XCTAssertTrue(waitUntil { !process.groupIsAlive }, "SIGKILL ended the group")
    }

    func testRealAgentThatLeavesOnSigintEndsWithoutEscalation() throws {
        let process = try started("trap 'exit 0' INT; echo started; while :; do sleep 0.05; done")
        let outcome = QuitShutdown.stopAll([process], timing: .init(grace: 3, deadline: 5, poll: 0.02))
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(process.groupIsAlive)
    }

    func testTheWaitCoversWhatTheAgentStarted() throws {
        // The shell leaves on SIGINT but its background sleep ignores SIGINT: the group lives until SIGTERM.
        let process = try started("trap '' INT; (trap '' INT; sleep 30) & trap 'exit 0' INT; echo started; wait")
        let outcome = QuitShutdown.stopAll([process], timing: .init(grace: 0.4, deadline: 3, poll: 0.02))
        XCTAssertEqual(outcome, .terminated)
        XCTAssertFalse(process.groupIsAlive)
    }

    func testStartedAgentsAreListedUntilTheyExit() throws {
        let process = try started("echo started; sleep 30")
        XCTAssertTrue(LiveAgentProcesses.shared.all.contains { $0 === process })
        QuitShutdown.stopAll([process], timing: .init(grace: 2, deadline: 3, poll: 0.02))
        XCTAssertTrue(waitUntil { !LiveAgentProcesses.shared.all.contains { $0 === process } })
    }

    // MARK: Helpers

    private func started(_ script: String) throws -> AgentProcess {
        let spec = LaunchSpec(executable: "/bin/sh", arguments: ["-c", script], extraEnvironment: [:], workingDirectory: "/",
                              initialInput: [], keepsInputOpen: false)
        let process = AgentProcess(spec: spec)
        let started = expectation(description: "started")
        process.onLine = { line in if line == "started" { started.fulfill() } }
        try process.start(baseEnvironment: ["PATH": "/usr/bin:/bin"])
        wait(for: [started], timeout: 10)
        addTeardownBlock { process.signalQuit(SIGKILL) }
        return process
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}

/// Time that moves only when the code under test sleeps.
private final class FakeClock: @unchecked Sendable {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private(set) var elapsed: TimeInterval = 0
    var now: () -> Date { { [unowned self] in start.addingTimeInterval(elapsed) } }
    var sleep: (TimeInterval) -> Void { { [unowned self] in elapsed += $0 } }
}

/// An agent that exits on one signal (or a stronger one).
private final class FakeTarget: QuitStoppable, @unchecked Sendable {
    private let lock = NSLock()
    private let diesOn: Int32
    private var sent: [Int32] = []
    private var alive = true
    private var finished = false

    init(diesOn: Int32) { self.diesOn = diesOn }

    var signals: [Int32] { lock.withLock { sent } }
    var ended: Bool { lock.withLock { finished } }

    private func receive(_ signal: Int32) {
        lock.withLock {
            sent.append(signal)
            let order = [SIGINT, SIGTERM, SIGKILL]
            if (order.firstIndex(of: signal) ?? 0) >= (order.firstIndex(of: diesOn) ?? 0) { alive = false }
        }
    }

    func beginQuit() { receive(SIGINT) }
    var groupIsAlive: Bool { lock.withLock { alive } }
    func signalQuit(_ signal: Int32) { receive(signal) }
    func endQuit() { lock.withLock { finished = true } }
}
