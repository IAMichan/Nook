import Foundation
#if os(macOS)
import Darwin
#endif

/// What an agent session costs this Mac right now: the CPU and memory of the
/// agent's process and everything it started (a build, a test run, a dev server). Only measured while the session is
/// on screen; nothing is kept.
struct ResourceUsage: Equatable, Sendable {
    /// Percent of one core, so a build on four cores reads 400 %.
    var cpuPercent: Double
    /// Physical memory (what Activity Monitor shows as Memory), in bytes.
    var memoryBytes: UInt64
    var processes: Int

    /// "12 % · 340 MB".
    var label: String {
        let cpu = cpuPercent < 10 ? String(format: "%.1f", cpuPercent) : String(Int(cpuPercent.rounded()))
        return "\(cpu) % · \(Self.bytes(memoryBytes))"
    }

    static func bytes(_ value: UInt64) -> String {
        let mb = Double(value) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }
}

/// One process at the moment it was read. A pid is only the same process together with its start time: macOS hands
/// out pids again.
struct ProcessSample: Equatable, Sendable {
    var pid: Int32
    var parent: Int32
    /// Microseconds since 1970.
    var started: UInt64
    /// User and system time used so far, in nanoseconds.
    var cpuNanoseconds: UInt64
    var memoryBytes: UInt64

    var identity: String { "\(pid)@\(started)" }
}

/// Turns two readings of a process tree into CPU use over the time between them.
struct ResourceMeter: Sendable {
    private var last: [String: UInt64] = [:]
    private var lastTime: TimeInterval?

    /// `root` and every process below it, from a reading of all processes.
    static func tree(root: Int32, in samples: [ProcessSample]) -> [ProcessSample] {
        var children: [Int32: [ProcessSample]] = [:]
        for sample in samples { children[sample.parent, default: []].append(sample) }
        guard let top = samples.first(where: { $0.pid == root }) else { return [] }
        var result = [top]
        var queue = [root]
        var seen: Set<Int32> = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    /// The usage of a tree read at `time` (seconds). The first reading has no CPU figure yet (nil). A process that
    /// started between two readings counts all of its CPU time; one that ended simply drops out.
    mutating func measure(_ tree: [ProcessSample], at time: TimeInterval) -> ResourceUsage? {
        defer {
            last = Dictionary(tree.map { ($0.identity, $0.cpuNanoseconds) }, uniquingKeysWith: { $1 })
            lastTime = time
        }
        guard let previous = lastTime, time > previous else { return nil }
        let used = tree.reduce(UInt64(0)) { total, sample in
            let before = last[sample.identity] ?? 0
            return total + (sample.cpuNanoseconds >= before ? sample.cpuNanoseconds - before : 0)
        }
        let percent = Double(used) / 1_000_000_000 / (time - previous) * 100
        return ResourceUsage(cpuPercent: max(0, percent), memoryBytes: tree.reduce(0) { $0 + $1.memoryBytes }, processes: tree.count)
    }
}

#if os(macOS)
/// Reads every process on this Mac with libproc: parent, start time, CPU time and physical footprint. Processes of other
/// users that cannot be read are skipped.
enum ProcessTable {
    static func read() -> [ProcessSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            guard ok else { return nil }
            // rusage times are in Mach time units (not nanoseconds on Apple silicon).
            let cpu = Double(usage.ri_user_time + usage.ri_system_time) * scale
            return ProcessSample(pid: pid, parent: Int32(info.pbi_ppid),
                                 started: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec),
                                 cpuNanoseconds: UInt64(cpu), memoryBytes: usage.ri_phys_footprint)
        }
    }
}
#endif
