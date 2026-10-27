import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Agents run in a process group of their own, so stopping one also stops what it started (a build, a dev server, a shell
// a tool left running). Foundation's Process cannot start a child in a new group, and calling setpgid(pid, pid) after
// `run()` races the child's exec (it fails with EACCES once the child has exec'd, which on macOS is almost always), so
// `SpawnedProcess` starts agents with posix_spawn and POSIX_SPAWN_SETPGROUP: the child is in its own group before its
// first instruction runs.
//
// Which groups are alive is written down (`ProcessGroupLedger`). After a crash the next launch stops the groups an earlier
// Nook left behind, but only when the group's leader is provably the same process: same pid, same group, same start time.
// A pid the system has since given to another program is never signalled, and nothing is ever matched by name.

/// One process, told apart from any later process that gets the same pid.
struct ProcessIdentity: Codable, Equatable, Sendable {
    var pid: Int32
    var processGroup: Int32
    /// When it started, as the system reports it (microseconds since 1970 on macOS, clock ticks since boot on Linux).
    var startTime: UInt64

    /// The identity of a running process, or nil when there is none with this pid (or it cannot be read).
    static func of(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, processGroup: Int32(bitPattern: info.pbi_pgid),
                               startTime: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
        #elseif os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
        return parseLinuxStat(stat, pid: pid)
        #else
        return nil
        #endif
    }

    /// Reads /proc/<pid>/stat: the name in parentheses may hold spaces, so fields are counted after its last ")".
    static func parseLinuxStat(_ stat: String, pid: Int32) -> ProcessIdentity? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // fields[0] is the state (field 3), so field n sits at n - 3: pgrp is field 5, starttime field 22.
        guard fields.count > 19, let group = Int32(fields[2]), let start = UInt64(fields[19]) else { return nil }
        // A zombie has exited: it is no process to stop.
        guard fields[0] != "Z" else { return nil }
        return ProcessIdentity(pid: pid, processGroup: group, startTime: start)
    }
}

/// A process group an agent runs in, written down while it lives.
struct LiveProcessGroup: Codable, Equatable, Sendable {
    /// The group's leader: the agent itself. Its pid is the group id.
    var leader: ProcessIdentity
    /// The Nook that started it; while that Nook still runs (a second copy, a debug build) its groups are left alone.
    var owner: ProcessIdentity
    var executable: String
    var started: Date

    var groupID: Int32 { leader.pid }
}

/// Which process groups agents live in, kept in a small file so the next launch can clean up after a crash.
final class ProcessGroupLedger: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    /// Where the app keeps it.
    static var defaultURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("process-groups.json")
    }

    private static let box = LedgerBox()

    /// The ledger agents are written to; nil (tests, previews) writes nothing.
    static var current: ProcessGroupLedger? {
        get { box.get() }
        set { box.set(newValue) }
    }

    /// At launch: from now on agents' groups are written down, and the ones an earlier Nook left behind are stopped.
    static func install(url: URL = defaultURL, signal: @escaping @Sendable (Int32, Int32) -> Void = ProcessGroupLedger.signalGroup) {
        let ledger = ProcessGroupLedger(url: url)
        // Read before any agent of this launch is written down, so only groups of an earlier Nook are looked at.
        let leftovers = ledger.takeLeftovers(me: ProcessIdentity.of(getpid()))
        current = ledger
        guard !leftovers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            LeftoverProcessGroups.stop(leftovers, identity: ProcessIdentity.of, signal: signal,
                                       scheduler: DispatchProcessScheduler())
        }
    }

    static func signalGroup(_ group: Int32, _ signal: Int32) {
        guard group > 1 else { return }
        _ = killpg(group, signal)
    }

    func entries() -> [LiveProcessGroup] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    func record(_ group: LiveProcessGroup) {
        lock.lock()
        defer { lock.unlock() }
        var groups = read().filter { $0.groupID != group.groupID }
        groups.append(group)
        write(groups)
    }

    func forget(groupID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let groups = read()
        let kept = groups.filter { $0.groupID != groupID }
        if kept.count != groups.count { write(kept) }
    }

    /// The groups other, no longer running, Nooks left behind; they are taken off the ledger. Groups of a Nook that still
    /// runs stay on it.
    func takeLeftovers(me: ProcessIdentity?, identity: (Int32) -> ProcessIdentity? = ProcessIdentity.of) -> [LiveProcessGroup] {
        lock.lock()
        defer { lock.unlock() }
        let groups = read()
        guard !groups.isEmpty else { return [] }
        var kept: [LiveProcessGroup] = []
        var leftovers: [LiveProcessGroup] = []
        for group in groups {
            let ownerRuns = group.owner != me && identity(group.owner.pid) == group.owner
            if ownerRuns { kept.append(group) } else { leftovers.append(group) }
        }
        write(kept)
        return leftovers
    }

    private func read() -> [LiveProcessGroup] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode(LossyArray<LiveProcessGroup>.self, from: data))?.elements ?? []
    }

    private func write(_ groups: [LiveProcessGroup]) {
        guard let data = try? Self.encoder.encode(groups) else { return }
        try? SafeStorage.write(data, to: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private final class LedgerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ledger: ProcessGroupLedger?
        func get() -> ProcessGroupLedger? { lock.lock(); defer { lock.unlock() }; return ledger }
        func set(_ value: ProcessGroupLedger?) { lock.lock(); ledger = value; lock.unlock() }
    }
}

/// Stops the process groups an earlier Nook left behind. Pure apart from what is passed in, so tests run it without
/// processes.
enum LeftoverProcessGroups {
    enum Verdict: Equatable, Sendable {
        /// The leader is still the process that was started: stop the group.
        case stop
        /// No process has the leader's pid any more.
        case gone
        /// Another process has the pid now (different start time or group): never signal it.
        case reused
    }

    static func verdict(_ group: LiveProcessGroup, current: ProcessIdentity?) -> Verdict {
        guard let current else { return .gone }
        // The leader's group must still be its own pid: a leader that moved to another group is not ours to stop.
        guard current == group.leader, current.processGroup == group.groupID else { return .reused }
        return .stop
    }

    /// SIGTERM to every group whose leader is unchanged, then SIGKILL after `grace` to those whose leader is still the
    /// same process. Returns the groups that were signalled.
    @discardableResult
    static func stop(_ groups: [LiveProcessGroup], identity: @escaping @Sendable (Int32) -> ProcessIdentity?,
                     signal: @escaping @Sendable (Int32, Int32) -> Void, scheduler: ProcessScheduler,
                     grace: TimeInterval = 2) -> [LiveProcessGroup] {
        let doomed = groups.filter { verdict($0, current: identity($0.leader.pid)) == .stop }
        guard !doomed.isEmpty else { return [] }
        for group in doomed { signal(group.groupID, SIGTERM) }
        scheduler.schedule(after: grace) {
            // Checked again: in the meantime the leader may have exited and its pid been given to someone else.
            for group in doomed where verdict(group, current: identity(group.leader.pid)) == .stop {
                signal(group.groupID, SIGKILL)
            }
        }
        return doomed
    }
}

/// Runs work later. Agents' stop escalation and exit delivery go through it, so tests run without waiting.
protocol ProcessScheduler: Sendable {
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

struct DispatchProcessScheduler: ProcessScheduler {
    var queue: DispatchQueue = .global()

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// A child process started with posix_spawn in a process group of its own, with pipes for stdin, stdout and stderr.
///
/// Its exit is noticed without reaping it (waitid with WNOWAIT): while a stop is under way the exited leader stays a
/// zombie, which keeps its pid, and so the group id, from being handed out again. Signalling the group stays safe until
/// the stop is over and the leader is reaped.
final class SpawnedProcess: @unchecked Sendable {
    struct Options: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var workingDirectory: String
        var keepsInputOpen: Bool
    }

    private let lock = NSLock()
    private(set) var pid: Int32 = 0
    private var exited = false
    private var reaped = false
    private var holds = 0
    private var input: FileHandle?
    /// stdout and stderr: kept here, so they stay open while their readability handlers run.
    private var outputs: [FileHandle] = []
    private var ledger: ProcessGroupLedger?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid > 0 && !exited
    }

    /// Starts the process. Handlers are called on background threads: stdout and stderr data as it arrives (empty data:
    /// end of stream), the exit status once the process has exited (the signal number when a signal ended it).
    func start(_ options: Options, ledger: ProcessGroupLedger? = ProcessGroupLedger.current,
               onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw Self.posixError(errno) }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw Self.posixError(errno)
        }
        if options.keepsInputOpen, pipe(&stdinPipe) != 0 {
            for fd in stdoutPipe + stderrPipe { close(fd) }
            throw Self.posixError(errno)
        }
        // None of these may leak into processes started elsewhere in Nook; the child gets its copies through dup2.
        for fd in stdinPipe + stdoutPipe + stderrPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if options.keepsInputOpen {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, options.workingDirectory)

        // Its own group (pgroup 0: the child's pid), default signal handlers (Nook ignores SIGPIPE, which a child would
        // otherwise inherit) and an empty signal mask.
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        // Only the three descriptors above reach the agent, never Nook's other files and sockets.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = [options.executable] + options.arguments
        let envp = options.environment.map { "\($0.key)=\($0.value)" }
        var child: pid_t = 0
        let status = Self.withCStrings(argv) { argv in
            Self.withCStrings(envp) { envp in
                posix_spawn(&child, options.executable, &actions, &attributes, argv, envp)
            }
        }
        // The child's ends belong to the child now.
        if stdinPipe[0] >= 0 { close(stdinPipe[0]) }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard status == 0 else {
            if stdinPipe[1] >= 0 { close(stdinPipe[1]) }
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw Self.posixError(status)
        }

        let started = Date()
        lock.lock()
        pid = child
        input = options.keepsInputOpen ? FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true) : nil
        self.ledger = ledger
        lock.unlock()
        if let ledger, let leader = ProcessIdentity.of(child), let owner = ProcessIdentity.of(getpid()) {
            ledger.record(LiveProcessGroup(leader: leader, owner: owner, executable: options.executable, started: started))
        }

        let outputs = [Self.read(stdoutPipe[0], onData: onStdout), Self.read(stderrPipe[0], onData: onStderr)]
        lock.lock()
        self.outputs = outputs
        lock.unlock()
        let spawned = child
        let thread = Thread { [self] in
            let code = Self.waitForExit(spawned)
            lock.lock()
            exited = true
            lock.unlock()
            onExit(code)
            reapUnlessHeld()
        }
        thread.name = "nook.agent-process.wait"
        thread.start()
    }

    /// Writes to the child's stdin.
    func write(_ data: Data) throws {
        lock.lock()
        let handle = exited ? nil : input
        lock.unlock()
        try handle?.write(contentsOf: data)
    }

    func closeInput() {
        lock.lock()
        let handle = input
        input = nil
        lock.unlock()
        try? handle?.close()
    }

    /// Sends a signal to the whole group. Never once the leader is reaped: its group id could belong to another program.
    /// True while the group id is still ours (the leader is not reaped, so no other program can get it). That holds
    /// also when nothing in the group lives any more and macOS refuses the signal for an exited, unreaped leader.
    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, !reaped else { return false }
        _ = killpg(pid, signal)
        return true
    }

    /// Keeps an exited leader unreaped (so the group can still be signalled) until `release()`.
    func hold() {
        lock.lock()
        holds += 1
        lock.unlock()
    }

    func release() {
        lock.lock()
        holds = max(0, holds - 1)
        lock.unlock()
        reapUnlessHeld()
    }

    private func reapUnlessHeld() {
        lock.lock()
        guard exited, !reaped, holds == 0, pid > 0 else {
            lock.unlock()
            return
        }
        reaped = true
        let child = pid
        let ledger = ledger
        input = nil
        lock.unlock()
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        ledger?.forget(groupID: child)
    }

    /// Blocks until the child has exited, leaving it unreaped. Returns its exit code, or the signal that ended it.
    private static func waitForExit(_ child: pid_t) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else { return -1 }
        }
        #if canImport(Darwin)
        return info.si_status
        #else
        return info._sifields._sigchld.si_status
        #endif
    }

    private static func read(_ fd: Int32, onData: @escaping @Sendable (Data) -> Void) -> FileHandle {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            onData(data)
        }
        return handle
    }

    private static func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
