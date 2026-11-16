import Foundation

/// Whether a command an agent left running in the background is still at work, read from this Mac's process table: the
/// processes it started, their CPU use, and the newest of them ("xcodebuild"). A command that runs a long time looks
/// stuck from its elapsed time alone; this tells working (it uses CPU), waiting (its processes live but sit idle, on a
/// lock or the network) and gone (none of its processes is left, while its row still says it runs) apart.
///
/// Works for every agent Nook starts a process for: the command is found as the shell below the agent's process whose
/// command line holds it (Claude Code's `eval '…'`, Codex's `bash -lc …`, and the others).
struct BackgroundCommandActivity: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Its processes use CPU.
        case working
        /// Its processes live but use (almost) no CPU: waiting on something.
        case waiting
        /// None of its processes is left.
        case gone
    }

    var state: State
    /// Percent of one core over the last reading; nil on the first one.
    var cpuPercent: Double?
    /// The process it runs now: the busiest one, else the newest ("xcodebuild").
    var process: String?
    /// When its output file last changed (Claude Code writes one per background command); nil while it is empty.
    var lastOutput: Date?
    /// Nook knows its output file, so a missing `lastOutput` means it printed nothing yet.
    var hasOutputFile = false
    /// The share done the end of its output file reports ("[12/340]", "45%"; `WorkProgress.reported`).
    var reported: Double? = nil

    /// Below this much CPU (percent of one core) a command counts as waiting.
    static let idleCPU = 1.0

    /// "Working · 140 % CPU · xcodebuild".
    var cpuLabel: String? {
        guard let cpuPercent else { return nil }
        return cpuPercent < 10 ? String(format: "%.1f %%", cpuPercent) : "\(Int(cpuPercent.rounded())) %"
    }

    // MARK: Finding its processes

    /// A part of `command` its shell's command line holds: its first line, at most 80 characters. Nil for an empty one.
    static func fragment(_ command: String) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// Whether a process's command line runs `command`: as it is, or single-quoted the way a shell `eval '…'` holds it,
    /// each `'` written as `'\''` or as `'"'"'` (Claude Code's newer form). Missing a form made a running command look gone.
    static func runs(_ commandLine: String, _ command: String) -> Bool {
        guard let fragment = fragment(command) else { return false }
        if commandLine.contains(fragment) { return true }
        guard fragment.contains("'") else { return false }
        return [#"'\''"#, #"'"'"'"#].contains { commandLine.contains(fragment.replacingOccurrences(of: "'", with: $0)) }
    }

    /// The processes of `command`: the topmost process below `roots` (the agent's processes) whose command line runs it,
    /// and everything below that. Empty when none is found.
    static func processes(of command: String, roots: [Int32], in samples: [ProcessSample],
                          commandLine: (Int32) -> String?) -> [ProcessSample] {
        var below: [ProcessSample] = []
        var seen = Set<String>()
        for root in roots {
            for sample in ResourceMeter.tree(root: root, in: samples) where sample.pid != root && seen.insert(sample.identity).inserted {
                below.append(sample)
            }
        }
        let byPID = Dictionary(below.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let matching = below.filter { commandLine($0.pid).map { runs($0, command) } ?? false }
        // Only the topmost: a shell that runs the command starts children whose command lines may hold it too.
        let tops = matching.filter { sample in
            var parent = sample.parent
            while let up = byPID[parent] {
                if matching.contains(where: { $0.pid == up.pid }) { return false }
                parent = up.parent
            }
            return true
        }
        var result: [ProcessSample] = []
        var taken = Set<String>()
        for top in tops {
            for sample in ResourceMeter.tree(root: top.pid, in: below) where taken.insert(sample.identity).inserted {
                result.append(sample)
            }
        }
        return result
    }

    /// The process to name: the one that used the most CPU since the last reading, else the newest.
    static func current(_ tree: [ProcessSample], previous: [String: UInt64]) -> ProcessSample? {
        let used = tree.map { ($0, $0.cpuNanoseconds - min($0.cpuNanoseconds, previous[$0.identity] ?? $0.cpuNanoseconds)) }
        if let busiest = used.max(by: { $0.1 < $1.1 }), busiest.1 > 0 { return busiest.0 }
        return tree.max { $0.started < $1.started }
    }

    // MARK: Its output

    /// The last `bytes` of the file at `path`, as text: where a progress line is. Nil when it cannot be read.
    static func tail(_ path: String, bytes: Int = 4_096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The file Claude Code writes a background command's output to, from the note its call returned ("Output is being
    /// written to: /private/tmp/…/tasks/b3k9.output.").
    static func outputFile(_ output: String?) -> String? {
        guard let output, let start = output.range(of: "Output is being written to: ") else { return nil }
        let rest = output[start.upperBound...]
        let path = rest.prefix { !$0.isWhitespace }
        let trimmed = path.hasSuffix(".") ? String(path.dropLast()) : String(path)
        return trimmed.hasPrefix("/") ? trimmed : nil
    }
}

/// Reads one command's activity again and again: a reading keeps the CPU time of the one before, to tell CPU use.
struct BackgroundCommandProbe: Sendable {
    private var meter = ResourceMeter()
    private var previous: [String: UInt64] = [:]
    /// Readings in a row that found none of its processes: one miss may be a process between two steps.
    private var misses = 0
    /// What its output file reported when it last changed (`lastRead`).
    private var reported: Double?
    private var lastRead: Date?
    /// Since when none of its processes is left, and its output file has not changed since.
    private var goneSince: TimeInterval?
    private var goneOutput: Date?

    /// How long a command must stay gone, its output file still, before it counts as ended: an agent may never report the
    /// end of a command (Claude Code drops the note for a call it moved to the background), and its row then spun on.
    static let endedAfter: TimeInterval = 45

    /// The command has been gone, its output unchanged, for `endedAfter` seconds at `time`: it ended, whether or not its
    /// agent says so.
    func ended(at time: TimeInterval) -> Bool {
        goneSince.map { time - $0 >= Self.endedAfter } ?? false
    }

    /// The command's activity in `table`, a reading of every process at `time`. Nil while that cannot be told (the agent
    /// runs no process Nook knows, or it missed once).
    mutating func read(command: String, output: String?, roots: [Int32], table: [ProcessSample], at time: TimeInterval,
                       commandLine: (Int32) -> String?, modified: (String) -> Date?,
                       tail: (String) -> String? = { _ in nil }) -> BackgroundCommandActivity? {
        // `modified`: when the file last changed, nil while it is empty or missing.
        guard !roots.isEmpty else { return nil }
        let tree = BackgroundCommandActivity.processes(of: command, roots: roots, in: table, commandLine: commandLine)
        let file = BackgroundCommandActivity.outputFile(output)
        let lastOutput = file.flatMap(modified)
        guard !tree.isEmpty else {
            misses += 1
            meter = ResourceMeter()
            previous = [:]
            if goneSince == nil || lastOutput != goneOutput {
                goneSince = time
                goneOutput = lastOutput
            }
            return misses >= 2 ? BackgroundCommandActivity(state: .gone, lastOutput: lastOutput, hasOutputFile: file != nil) : nil
        }
        misses = 0
        goneSince = nil
        let current = BackgroundCommandActivity.current(tree, previous: previous)
        previous = Dictionary(tree.map { ($0.identity, $0.cpuNanoseconds) }, uniquingKeysWith: { $1 })
        let cpu = meter.measure(tree, at: time)?.cpuPercent
        let state: BackgroundCommandActivity.State = (cpu ?? 0) >= BackgroundCommandActivity.idleCPU ? .working : .waiting
        // Only read again when the file changed since: a command that prints nothing new reports the same.
        if lastOutput != lastRead { reported = file.flatMap(tail).flatMap(WorkProgress.reported(in:)); lastRead = lastOutput }
        return BackgroundCommandActivity(state: cpu == nil ? .working : state, cpuPercent: cpu,
                                         process: current.map(\.name).flatMap { $0.isEmpty ? nil : $0 }, lastOutput: lastOutput,
                                         hasOutputFile: file != nil, reported: reported)
    }
}

