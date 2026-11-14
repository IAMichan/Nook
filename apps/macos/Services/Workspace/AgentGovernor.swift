import Foundation
import Combine
import Darwin
import os

/// Keeps the coding agents Nook runs from taking the Mac over (`AgentGovernorPolicy` decides, this applies it).
///
/// Every few seconds while agents run, it reads how hard the Mac is pressed and which commands each agent runs, and then:
/// moves those commands into macOS's background band (`PRIO_DARWIN_BG`: leftover processor, throttled disk) when memory is
/// tight or the Mac is hot; and when the Mac swaps hard, holds the commands of the youngest agents still (`SIGSTOP` to their
/// process groups) until there is room again. The agent processes themselves are never slowed or paused, so their
/// connections and Nook's view of them stay live.
///
/// A paused command must never be left behind: the groups are written down (`paused-groups.json`), resumed when the agent
/// stops, when Nook quits, and on the next launch after a crash (only when the process is provably the same one).
final class AgentGovernor: @unchecked Sendable {
    static let shared = AgentGovernor()

    /// How often the Mac is read while agents run.
    static let interval: TimeInterval = 5

    private let queue = DispatchQueue(label: "nook.agent-governor", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// On `queue`, like every use of `timer`: whether the timer is suspended because no agent runs. A dispatch source's
    /// suspends and resumes must balance (resuming one that runs, or releasing a suspended one, crashes), so only
    /// `sleepIfIdle` suspends and only `wake` resumes, each after checking this. The timer is never cancelled.
    private var sleeping = false
    // On `queue`.
    private var states: [Int32: AgentGovernorState] = [:]
    private var backgrounded: [Int32: Set<Int32>] = [:]
    private var paused: [Int32: [ProcessIdentity]] = [:]
    private var lastSwapins: (count: UInt64, at: Date)?
    private var calmSince: Date? = Date()
    private var lastStrain: MachineStrain = .calm
    // Under `lock`: runs you told to go on.
    private var exempt: Set<UUID> = []

    private let record: URL

    init(record: URL = NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("paused-groups.json")) {
        self.record = record
    }

    /// Resumes what an earlier Nook left paused, and starts reading. Safe to call more than once.
    func start() {
        // An agent that starts wakes the reading up again (see `sleepIfIdle`).
        LiveAgentProcesses.onTrack = { [weak self] in self?.wake() }
        queue.async { [self] in
            guard timer == nil else { return }
            resumeLeftovers()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// An agent started: readings go on if they slept. Queued after the agent was tracked, so a reading that just found
    /// none and went to sleep is always followed by this.
    func wake() {
        queue.async { [self] in
            guard sleeping, let timer else { return }
            sleeping = false
            timer.resume()
        }
    }

    /// No agent runs and nothing is held back: the timer stops until `wake`, so an idle Nook reads nothing every few
    /// seconds. On `queue`.
    private func sleepIfIdle() {
        guard !sleeping, let timer, paused.isEmpty, backgrounded.isEmpty,
              LiveAgentProcesses.shared.everyRunning.isEmpty else { return }
        sleeping = true
        // The next swap-in rate starts afresh instead of averaging over the whole time asleep.
        lastSwapins = nil
        timer.suspend()
    }

    /// One reading now, waited for (tests).
    func readNow(forcing strain: MachineStrain? = nil) {
        queue.sync { tick(forcing: strain) }
    }

    /// Resumes what an earlier Nook left paused, waited for (tests).
    func resumeLeftoversNow() {
        queue.sync { resumeLeftovers() }
    }

    /// You let this run's commands go on: they come back now and are not paused again while it runs.
    func letGoOn(_ runID: UUID) {
        lock.withLock { _ = exempt.insert(runID) }
        queue.async { [self] in tick() }
    }

    /// The agent stops: its commands come back first, so they hear the stop and are not left holding still.
    func release(agent pid: Int32) {
        queue.sync { resume(agent: pid, forget: true) }
    }

    /// Nook quits: everything paused comes back.
    func releaseAll() {
        queue.sync {
            for pid in Array(paused.keys) { resume(agent: pid, forget: true) }
            for (_, pids) in backgrounded { for pid in pids { setBackground(pid, false) } }
            backgrounded = [:]
        }
    }

    // MARK: Reading and applying

    /// One reading. `forcing` replaces what the Mac says (tests); on `queue`.
    func tick(forcing: MachineStrain? = nil) {
        let agents = LiveAgentProcesses.shared.everyRunning.filter { $0.pid > 0 && $0.isRunning }
        let swapRate = swapinRate()
        let strain = forcing ?? AgentGovernorPolicy.strain(pressureLevel: SystemLoad.memoryPressureLevel,
                                                           swapinsPerSecond: swapRate, hot: SystemLoad.isHot)
        if strain == .critical { calmSince = nil } else if calmSince == nil { calmSince = Date() }
        if strain != lastStrain {
            // Every change with what it was read from: the thresholds are checked against these.
            let level = SystemLoad.memoryPressureLevel
            Log.resources.notice("""
                strain \(String(describing: self.lastStrain), privacy: .public) -> \(String(describing: strain), privacy: .public): \
                pressure level \(level), swap-ins/s \(swapRate ?? -1, format: .fixed(precision: 0)), \
                load \(SystemLoad.loadAverage, format: .fixed(precision: 1)), hot \(SystemLoad.isHot), \
                agents \(LiveAgentProcesses.shared.everyRunning.count)
                """)
            lastStrain = strain
        }

        let livePIDs = Set(agents.map(\.pid))
        // Agents that ended: whatever they left paused comes back.
        for pid in Array(paused.keys) where !livePIDs.contains(pid) { resume(agent: pid, forget: true) }
        for pid in Array(backgrounded.keys) where !livePIDs.contains(pid) { backgrounded[pid] = nil }
        states = states.filter { livePIDs.contains($0.key) }
        guard !agents.isEmpty else {
            publish([:])
            sleepIfIdle()
            return
        }

        let table = Self.processTable()
        let exempted = lock.withLock { exempt }
        var work: [Int32: AgentWork] = [:]
        var runOf: [Int32: UUID] = [:]
        var loads: [AgentLoad] = []
        for agent in agents {
            let found = AgentWork.of(agent: agent.pid, in: table)
            work[agent.pid] = found
            let run = agent.spec.extraEnvironment["NOOK_RUN_ID"].flatMap(UUID.init(uuidString:))
            runOf[agent.pid] = run
            let started = ProcessIdentity.of(agent.pid).map { Date(timeIntervalSince1970: Double($0.startTime) / 1_000_000) }
            loads.append(AgentLoad(pid: agent.pid, started: started ?? .distantPast, hasWork: !found.groups.isEmpty,
                                   exempt: run.map(exempted.contains) ?? false))
        }

        let before = states
        states = AgentGovernorPolicy.next(agents: loads, current: states, strain: strain, calmSince: calmSince, now: Date())
        for (pid, state) in states where before[pid]?.throttle != state.throttle && (before[pid] != nil || state.throttle != .normal) {
            Log.resources.notice("""
                agent \(pid) -> \(state.throttle.rawValue, privacy: .public) \
                (\(work[pid]?.processes.count ?? 0) commands in \(work[pid]?.groups.count ?? 0) groups)
                """)
        }
        for agent in loads {
            guard let state = states[agent.pid], let found = work[agent.pid] else { continue }
            apply(state.throttle, agent: agent.pid, work: found)
        }
        var published: [UUID: AgentThrottle] = [:]
        for (pid, state) in states where state.throttle != .normal {
            if let run = runOf[pid] { published[run] = state.throttle }
        }
        // A run you let go on no longer needs to be remembered once it has ended.
        let liveRuns = Set(runOf.values)
        lock.withLock { exempt.formIntersection(liveRuns) }
        publish(published)
    }

    private func apply(_ throttle: AgentThrottle, agent: Int32, work: AgentWork) {
        // Background: every command of the agent, also ones started since the last reading (new children inherit it,
        // but a command started just before the switch did not).
        let wantsBackground = throttle != .normal
        let current = backgrounded[agent] ?? []
        if wantsBackground {
            for pid in work.processes where !current.contains(pid) { setBackground(pid, true) }
            backgrounded[agent] = current.union(work.processes)
        } else if !current.isEmpty {
            for pid in current.union(work.processes) { setBackground(pid, false) }
            backgrounded[agent] = nil
        }

        if throttle == .paused {
            var held = paused[agent] ?? []
            for group in work.groups where !held.contains(where: { $0.processGroup == group }) {
                // Written down before the signal, so a crash right after still finds it.
                guard let member = work.processes.lazy.compactMap(ProcessIdentity.of).first(where: { $0.processGroup == group })
                else { continue }
                held.append(member)
                paused[agent] = held
                saveRecord()
                killpg(group, SIGSTOP)
            }
        } else if paused[agent] != nil {
            resume(agent: agent, forget: true)
        }
    }

    /// SIGCONT to every group this agent has paused, when its recorded member is still the same process.
    private func resume(agent: Int32, forget: Bool) {
        guard let held = paused[agent] else { return }
        for member in held where ProcessIdentity.of(member.pid) == member {
            killpg(member.processGroup, SIGCONT)
        }
        if forget {
            paused[agent] = nil
            saveRecord()
        }
    }

    private func setBackground(_ pid: Int32, _ on: Bool) {
        _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0)
    }

    private func swapinRate() -> Double? {
        guard let count = SystemLoad.swapins else { return nil }
        let now = Date()
        defer { lastSwapins = (count, now) }
        guard let last = lastSwapins, count >= last.count else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        return seconds >= 1 ? Double(count - last.count) / seconds : nil
    }

    // MARK: The record of paused groups

    private func saveRecord() {
        let all = paused.values.flatMap { $0 }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: record)
            return
        }
        try? FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: record, options: .atomic) }
    }

    /// After a crash: what an earlier Nook paused comes back, when it is provably still the same process.
    private func resumeLeftovers() {
        guard let data = try? Data(contentsOf: record),
              let left = try? JSONDecoder().decode([ProcessIdentity].self, from: data) else { return }
        for member in left where ProcessIdentity.of(member.pid) == member { killpg(member.processGroup, SIGCONT) }
        try? FileManager.default.removeItem(at: record)
    }

    // MARK: The process table

    static func processTable() -> [ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var table: [ProcessEntry] = []
        table.reserveCapacity(Int(count))
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            table.append(ProcessEntry(pid: pid, parent: Int32(bitPattern: info.pbi_ppid), group: Int32(bitPattern: info.pbi_pgid)))
        }
        return table
    }

    // MARK: What the panel shows

    private var lastPublished: [UUID: AgentThrottle] = [:]

    private func publish(_ throttles: [UUID: AgentThrottle]) {
        guard throttles != lastPublished else { return }
        lastPublished = throttles
        Task { @MainActor in AgentGovernorStatus.shared.throttles = throttles }
    }
}

/// What the governor does with each run right now, for the panel. Only runs it slows or pauses are in it.
@MainActor
final class AgentGovernorStatus: ObservableObject {
    static let shared = AgentGovernorStatus()
    @Published fileprivate(set) var throttles: [UUID: AgentThrottle] = [:]
}
