import Foundation

// How much room the coding agents Nook runs may take, so the Mac and Nook stay quick however many of them build at once.
//
// Agents run at full priority, so they are as quick as the Mac allows; heavy builds lower their own (scripts/build-slot.sh).
// That is about the processor; it does not stop four agents that each start a build from filling the memory together,
// and then everything waits for the swap. The governor watches the Mac and steps in, in three steps:
//
// - calm: agents run as usual.
// - pressed (memory tight, or the Mac hot): the commands agents run move to macOS's background band. The scheduler gives
//   them what is left over and their disk access is throttled, also for paging, so what you use stays quick. A busy
//   processor alone does not count: the build slot covers that, and the background band keeps a build to the
//   efficiency cores, which would make it many times slower for nothing.
//   Heavy work (a test run with a pool of workers, a full build: commands that hold a lot of memory) is the exception:
//   only one heavy job goes on at a time, at full speed so it frees its memory soon. When two or more agents run heavy
//   work, the youngest one's commands wait for the older ones to finish, right away instead of once the Mac swaps. Two
//   test runs that each start a worker per core no longer fill the memory together and then crawl on the efficiency
//   cores.
// - critical (the Mac keeps reading memory back from swap): the commands of the youngest agents wait, one at a time, until
//   memory is back. The agent itself keeps running, so its connection stays open; only the build or test it started holds
//   still. The oldest one always goes on, a pause ends after `maxPause` at the latest, and you can let one go on yourself.
//
// The decisions are pure (`AgentGovernorPolicy.next`) and tested on their own; `AgentGovernor` reads the Mac and applies them.

/// How hard the Mac is pressed right now.
enum MachineStrain: Int, Comparable, Sendable {
    case calm, pressed, critical

    static func < (lhs: MachineStrain, rhs: MachineStrain) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the governor does with one agent's work.
enum AgentThrottle: String, Equatable, Sendable {
    /// As usual (still behind your own work).
    case normal
    /// In macOS's background band: what is left of the processor, throttled disk access.
    case background
    /// The commands it runs hold still until the Mac has room again.
    case paused
}

/// One running agent, as the governor sees it.
struct AgentLoad: Equatable, Sendable {
    /// The agent's process (its group leader).
    var pid: Int32
    var started: Date
    /// It runs commands of its own (a build, a test run): there is something to pause.
    var hasWork: Bool
    /// Its commands hold a lot of memory (`AgentGovernorPolicy.heavyWorkBytes`): a test run with workers, a full build.
    var heavy = false
    /// You told Nook to let this one go on.
    var exempt = false
}

/// Where one agent stands.
struct AgentGovernorState: Equatable, Sendable {
    var throttle: AgentThrottle
    /// Since when it has this throttle.
    var since: Date
    /// When a pause last ended because it took too long: it is not paused again right away.
    var forcedResumeAt: Date?
}

enum AgentGovernorPolicy {
    /// Pages per second read back from swap at which the Mac counts as critical: four times what counts as tight. At this
    /// rate every app waits for the disk.
    static let swapinsPerSecondCritical: Double = EnergySignals.swapinsPerSecondTight * 4

    /// A pause ends after this long whatever the memory says: an agent's command has a time limit of its own, and a build
    /// that never moves helps nobody.
    static let maxPause: TimeInterval = 120
    /// After a pause that ended for taking too long, the agent is not paused again for this long.
    static let pauseCooldown: TimeInterval = 60
    /// The Mac has to be out of the critical state this long before paused work comes back, one agent per reading.
    static let resumeAfterCalm: TimeInterval = 15
    /// Resident memory of an agent's commands from which they count as heavy work: a bun or jest run with a worker per
    /// core holds 5 to 11 GB, a full Xcode build several; a shell, a grep or a single test file stays far below.
    static let heavyWorkBytes: UInt64 = 1_536 * 1_024 * 1_024

    /// How hard the Mac is pressed: macOS's pressure level (1 normal, 2 warning, 4 critical), the swap-in rate since the
    /// last reading, and whether the Mac is hot.
    static func strain(pressureLevel: Int32, swapinsPerSecond: Double?, hot: Bool) -> MachineStrain {
        if pressureLevel >= 4 || (swapinsPerSecond ?? 0) >= swapinsPerSecondCritical { return .critical }
        if hot || EnergySignals.isMemoryTight(pressureLevel: pressureLevel, swapinsPerSecond: swapinsPerSecond) {
            return .pressed
        }
        return .calm
    }

    /// The next state of every running agent. `calmSince` is when the Mac last left the critical state (nil while it is
    /// critical). At most one agent is paused and one resumed per reading, so the Mac is never jolted. Paused work comes
    /// back only while no other agent's heavy work goes on: it would fill the memory again and the pause would start over.
    static func next(agents: [AgentLoad], current: [Int32: AgentGovernorState], strain: MachineStrain,
                     calmSince: Date?, now: Date) -> [Int32: AgentGovernorState] {
        var result: [Int32: AgentGovernorState] = [:]
        let band: AgentThrottle = strain >= .pressed ? .background : .normal
        // Heavy work under pressure keeps full speed (only one runs, see below) unless the Mac swaps hard: in the
        // background band it would crawl on the efficiency cores and hold its memory all that time.
        func base(for agent: AgentLoad) -> AgentThrottle { agent.heavy && strain == .pressed ? .normal : band }
        var resumedOne = false
        // Paused ones first, oldest agent first: the one that has waited for its turn longest comes back first.
        let byAge = agents.sorted { $0.started < $1.started }
        for agent in byAge {
            let state = current[agent.pid]
            guard let state, state.throttle == .paused else { continue }
            let tooLong = now.timeIntervalSince(state.since) >= maxPause
            // Another agent's heavy work that goes on after this reading (older ones are already decided).
            let othersHeavy = byAge.contains { other in
                other.pid != agent.pid && other.heavy && other.hasWork
                    && (result[other.pid] ?? current[other.pid])?.throttle != .paused
            }
            let roomAgain = !othersHeavy && (calmSince.map { now.timeIntervalSince($0) >= resumeAfterCalm } ?? false)
            if agent.exempt || !agent.hasWork || tooLong || (roomAgain && !resumedOne) {
                if roomAgain && !tooLong && !agent.exempt && agent.hasWork { resumedOne = true }
                result[agent.pid] = AgentGovernorState(throttle: base(for: agent), since: now,
                                                       forcedResumeAt: tooLong ? now : state.forcedResumeAt)
            } else {
                result[agent.pid] = state
            }
        }
        // Everyone else follows the Mac.
        for agent in byAge where result[agent.pid] == nil {
            let old = current[agent.pid]
            let throttle = base(for: agent)
            let since = old?.throttle == throttle ? old!.since : now
            result[agent.pid] = AgentGovernorState(throttle: throttle, since: since, forcedResumeAt: old?.forcedResumeAt)
        }
        // The youngest of a set that may wait does, as long as an older one keeps going.
        func youngestThatMayWait(_ working: [AgentLoad]) -> AgentLoad? {
            guard working.count >= 2 else { return nil }
            return working.dropFirst().reversed().first { agent in
                guard !agent.exempt else { return false }
                if let forced = result[agent.pid]?.forcedResumeAt, now.timeIntervalSince(forced) < pauseCooldown { return false }
                return true
            }
        }
        let working = byAge.filter { $0.hasWork && result[$0.pid]?.throttle != .paused }
        var candidate: AgentLoad?
        // Pressed: one heavy job at a time, before the memory is full.
        if strain >= .pressed { candidate = youngestThatMayWait(working.filter(\.heavy)) }
        // Critical: the youngest agent with work that may wait does, heavy or not.
        if candidate == nil, strain == .critical { candidate = youngestThatMayWait(working) }
        if let candidate {
            result[candidate.pid] = AgentGovernorState(throttle: .paused, since: now,
                                                       forcedResumeAt: result[candidate.pid]?.forcedResumeAt)
        }
        return result
    }
}

/// One process as the governor reads the process table.
struct ProcessEntry: Equatable, Sendable {
    var pid: Int32
    var parent: Int32
    var group: Int32
}

/// The commands an agent runs: every process below it, and the process groups they are in. Claude Code (like most agents)
/// starts each command in a group of its own, so a build is found by following the tree, not the agent's group. The
/// agent's own group stays out of `groups`: pausing that would pause the agent and its connection.
struct AgentWork: Equatable, Sendable {
    var processes: [Int32]
    var groups: Set<Int32>

    static func of(agent: Int32, in table: [ProcessEntry]) -> AgentWork {
        var children: [Int32: [Int32]] = [:]
        var groupOf: [Int32: Int32] = [:]
        for entry in table {
            children[entry.parent, default: []].append(entry.pid)
            groupOf[entry.pid] = entry.group
        }
        let own = groupOf[agent] ?? agent
        var found: [Int32] = []
        var seen: Set<Int32> = [agent]
        var stack = children[agent] ?? []
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            found.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        let groups = Set(found.compactMap { groupOf[$0] }).subtracting([own])
        // Only processes in those groups: what stays in the agent's own group (a language server it keeps) is the agent's.
        return AgentWork(processes: found.filter { groupOf[$0].map(groups.contains) ?? false }.sorted(), groups: groups)
    }
}
