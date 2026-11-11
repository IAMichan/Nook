import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Quitting Nook waits for the agents it runs to exit. Without that wait, AppKit ended the process right after the first
// SIGINT: the SIGTERM and SIGKILL that `AgentProcess.stop` schedules never came, agents were cut off while writing their
// transcript, and what they started lived on until the next launch cleaned it up (`ProcessGroupLedger`). Now every live
// agent process (turns, Claude Code waiting between turns, Codex app-servers, ACP clients, text generation) gets SIGINT,
// then SIGTERM after a grace, then SIGKILL at one deadline shared by all of them, so quitting never takes longer than
// that deadline however many agents run.

/// What `QuitShutdown` stops: an agent process and its group.
protocol QuitStoppable: AnyObject, Sendable {
    /// Asks it to end (SIGINT unless a stop is already under way) and keeps its group signallable.
    func beginQuit()
    /// Whether it, or anything left in its group, still runs.
    var groupIsAlive: Bool { get }
    /// SIGTERM or SIGKILL to the whole group.
    func signalQuit(_ signal: Int32)
    /// The wait is over.
    func endQuit()
}

extension AgentProcess: QuitStoppable {}

enum QuitShutdown {
    struct Timing: Equatable, Sendable {
        /// After SIGINT: the time agents get to save and exit on their own.
        var grace: TimeInterval = 2
        /// From the start, for all of them together: what is still alive then gets SIGKILL.
        var deadline: TimeInterval = 4.5
        /// How often the groups are looked at while waiting.
        var poll: TimeInterval = 0.05
    }

    /// How the processes ended.
    enum Outcome: Equatable, Sendable {
        /// Nothing was running.
        case nothingRunning
        /// They all exited after SIGINT.
        case interrupted
        /// Some needed SIGTERM, and all were gone by the deadline.
        case terminated
        /// Some were still alive at the deadline and got SIGKILL.
        case killed
    }

    /// Stops the targets and waits, at most `timing.deadline`. Blocks: run it off the main thread.
    @discardableResult
    static func stopAll(_ targets: [any QuitStoppable], timing: Timing = Timing(), now: () -> Date = Date.init,
                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Outcome {
        guard !targets.isEmpty else { return .nothingRunning }
        let start = now()
        for target in targets { target.beginQuit() }
        defer { for target in targets { target.endQuit() } }
        func waitUntilGone(by limit: Date) -> Bool {
            while true {
                if !targets.contains(where: \.groupIsAlive) { return true }
                let left = limit.timeIntervalSince(now())
                if left <= 0 { return false }
                sleep(min(timing.poll, left))
            }
        }
        if waitUntilGone(by: start.addingTimeInterval(timing.grace)) { return .interrupted }
        for target in targets where target.groupIsAlive { target.signalQuit(SIGTERM) }
        if waitUntilGone(by: start.addingTimeInterval(max(timing.grace, timing.deadline))) { return .terminated }
        for target in targets where target.groupIsAlive { target.signalQuit(SIGKILL) }
        return .killed
    }
}

/// The agent processes that run now and are not kept running past Nook (`SessionKeeper`). Quitting stops these.
final class LiveAgentProcesses: @unchecked Sendable {
    static let shared = LiveAgentProcesses()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: AgentProcess] = [:]
    private var isQuitting = false

    func add(_ process: AgentProcess) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: AgentProcess) {
        lock.withLock { _ = processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    var all: [AgentProcess] { lock.withLock { Array(processes.values) } }

    /// Once Nook is quitting, no agent process starts any more.
    var quitting: Bool { lock.withLock { isQuitting } }

    /// Nook quits: from now on nothing new starts, and these are what is still running.
    func beginQuit() -> [AgentProcess] {
        lock.withLock {
            isQuitting = true
            return Array(processes.values)
        }
    }
}
