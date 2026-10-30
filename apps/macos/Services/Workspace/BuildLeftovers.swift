import Foundation

/// Builds that coding agents leave behind: Xcode build folders (`-derivedDataPath`) and `scripts/core-tests.sh`
/// packages in temporary folders, agent scratchpads, and a worktree's `.scratch/`, and Xcode DerivedData of worktrees
/// that no longer exist. Each is several hundred MB to 5 GB, and nothing else removes them: macOS leaves `/private/tmp`,
/// scratchpads and DerivedData alone, and a worktree's `.scratch/` lives as long as the worktree, which can be weeks.
/// Settings › Workspace can turn this off.
enum BuildLeftovers {
    /// Untouched this long, a build in a temporary folder belongs to nobody any more.
    static let maxAge: TimeInterval = 2 * 86_400

    enum Kind: String, Equatable {
        /// A package `scripts/core-tests.sh` built.
        case testPackage
        /// An Xcode build folder in a temporary folder, scratchpad, or `.scratch/`.
        case xcodeBuild
        /// Xcode's own DerivedData for a worktree that is gone.
        case orphanedDerivedData
    }

    struct Leftover: Equatable {
        var url: URL
        var kind: Kind
    }

    struct Roots {
        /// Folders whose entries are looked at directly (the system's temporary folder, `/private/tmp`).
        var temporary: [URL]
        /// Folders holding `<project>/<session>/scratchpad/` (Claude Code's per-session temporary folders).
        var scratchpadParents: [URL]
        /// Xcode's DerivedData folder.
        var derivedData: URL
        /// Worktrees whose `.scratch/` is looked at (only things that went untouched, as everywhere else).
        var worktrees: [URL] = []

        static func standard(worktrees: [URL]) -> Roots {
            let manager = FileManager.default
            let home = manager.homeDirectoryForCurrentUser
            return Roots(
                temporary: [manager.temporaryDirectory, URL(fileURLWithPath: "/private/tmp")],
                scratchpadParents: [URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")],
                derivedData: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                worktrees: worktrees)
        }
    }

    static func find(in roots: Roots, now: Date = Date()) -> [Leftover] {
        var found: [Leftover] = []
        var scratchpads: [URL] = []
        for parent in roots.scratchpadParents {
            for project in children(parent) {
                for session in children(project) { scratchpads.append(session.appendingPathComponent("scratchpad")) }
            }
        }
        let worktreeScratch = roots.worktrees.map { $0.appendingPathComponent(".scratch") }
        for folder in roots.temporary + scratchpads + worktreeScratch {
            for entry in children(folder) where isStale(entry, now: now) {
                if isTestPackage(entry) {
                    found.append(Leftover(url: entry, kind: .testPackage))
                } else if workspacePath(entry) != nil {
                    found.append(Leftover(url: entry, kind: .xcodeBuild))
                }
            }
        }
        for entry in children(roots.derivedData) {
            // Only for worktrees: a project you moved or deleted yourself is not Nook's to judge.
            guard let workspace = workspacePath(entry), workspace.contains("/worktrees/"),
                  !FileManager.default.fileExists(atPath: workspace) else { continue }
            found.append(Leftover(url: entry, kind: .orphanedDerivedData))
        }
        return found
    }

    /// Removes what `find` reports. Returns each removed leftover with the bytes it took.
    static func sweep(_ roots: Roots, now: Date = Date()) -> [(leftover: Leftover, bytes: Int64)] {
        find(in: roots, now: now).compactMap { leftover in
            let bytes = DiskUsage.allocatedSize(of: leftover.url.path) ?? 0
            guard (try? FileManager.default.removeItem(at: leftover.url)) != nil else { return nil }
            return (leftover, bytes)
        }
    }

    /// The project an Xcode build folder belongs to (its `info.plist`), or nil when it is not one.
    static func workspacePath(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["WorkspacePath"] as? String
    }

    /// A package `scripts/core-tests.sh` generated: by its name, or by its layout when an agent named it itself
    /// (`NOOK_CORE_TESTS_DIR=.scratch/coretests`).
    static func isTestPackage(_ folder: URL) -> Bool {
        if folder.lastPathComponent.hasPrefix("nook-core-tests.") { return true }
        let manager = FileManager.default
        return manager.fileExists(atPath: folder.appendingPathComponent("Package.swift").path)
            && manager.fileExists(atPath: folder.appendingPathComponent("Tests/CoreTests").path)
    }

    /// Neither the folder nor anything directly in it changed within `maxAge` (a build touches `Build`, `Logs`, …).
    static func isStale(_ folder: URL, now: Date) -> Bool {
        let dates = ([folder] + children(folder)).compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        guard let newest = dates.max() else { return false }
        return now.timeIntervalSince(newest) > maxAge
    }

    private static func children(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [])) ?? []
    }
}
