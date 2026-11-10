import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Parents and children of processes on this Mac, to tell what Nook started (a terminal's shell, an agent) from what runs
/// elsewhere, and to stop a process together with what it started. Nothing is ever matched by name: only by pid, read from
/// the system's own process table.
enum ProcessTree {
    /// How far up a parent chain is followed; deeper chains end at launchd long before.
    static let maxDepth = 64

    /// `pid` is `roots` or was started, directly or further down, by one of them. `parent` gives a process's parent.
    static func descends(_ pid: Int32, from roots: Set<Int32>, parent: (Int32) -> Int32?) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            if roots.contains(current) { return true }
            guard let next = parent(current), next > 1, next != current else { return false }
            current = next
        }
        return false
    }

    /// Every process below `root` (children, their children …), found with `children`. At most `limit`.
    static func descendants(of root: Int32, children: (Int32) -> [Int32], limit: Int = 512) -> [Int32] {
        var found: [Int32] = []
        var seen: Set<Int32> = [root]
        var queue = [root]
        while let next = queue.first, found.count < limit {
            queue.removeFirst()
            for child in children(next) where seen.insert(child).inserted {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// How to stop `pid`: its whole process group (a dev server's wrapper and workers live in one), unless that group is
    /// one that must live on (Nook's own, an agent's, a terminal shell you keep): then only the process itself.
    enum StopTarget: Hashable, Sendable {
        case group(Int32)
        case process(Int32)
    }

    static func stopTarget(pid: Int32, group: Int32?, protectedGroups: Set<Int32>) -> StopTarget {
        guard let group, group > 1, !protectedGroups.contains(group) else { return .process(pid) }
        return .group(group)
    }

    // MARK: This Mac

    static func parent(of pid: Int32) -> Int32? {
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
        #endif
    }

    static func children(of pid: Int32) -> [Int32] {
        #if os(macOS)
        guard pid > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 && $0 != pid }
        #else
        return []
        #endif
    }

    /// The process group of `pid`, or nil when it is gone.
    static func group(of pid: Int32) -> Int32? {
        let group = getpgid(pid)
        return group > 0 ? group : nil
    }

    /// Ends `target` politely (SIGTERM), so a dev server can write what it has to.
    static func stop(_ target: StopTarget) {
        switch target {
        case .group(let group): _ = killpg(group, SIGTERM)
        case .process(let pid): _ = kill(pid, SIGTERM)
        }
    }

    /// The groups no stop may take down: Nook's own and those of the agents it runs (`ProcessGroupLedger`).
    static func protectedGroups() -> Set<Int32> {
        var groups: Set<Int32> = [getpgrp()]
        for entry in ProcessGroupLedger.current?.entries() ?? [] { groups.insert(entry.groupID) }
        return groups
    }
}
