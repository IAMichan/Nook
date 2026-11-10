import Foundation

/// What settling a session does to the terminals and scripts in its folder, by the project's `nook.json`:
/// - a terminal that waits at a shell prompt closes (its output was only that session's);
/// - a terminal that runs a script with `stopOnSettle` stops, with everything it started;
/// - a script with `runOnSettle` runs once, but only for a session in a worktree of its own (the project's own checkout
///   is shared, so a cleanup there would hit work that goes on).
/// Any other terminal that still runs something (a dev server you started by hand) is left alone. When another session
/// that has not settled works in the same folder, nothing happens: those terminals are its as well.
enum SettleActions {
    /// A terminal as the plan sees it.
    struct Terminal: Equatable, Sendable {
        var id: UUID
        /// The folder it was opened in.
        var origin: String
        /// The command it was started with, if any.
        var command: String?
        /// Its shell still lives.
        var running: Bool
        /// The shell waits for input: nothing runs in the foreground or the background.
        var idleAtPrompt: Bool
    }

    struct Plan: Equatable, Sendable {
        /// Terminals to close: idle at a prompt.
        var close: [UUID] = []
        /// Terminals to stop with their processes: a `stopOnSettle` script runs in them.
        var stop: [UUID] = []
        /// Scripts to run in the folder (`runOnSettle`).
        var run: [ProjectScript] = []

        var isEmpty: Bool { close.isEmpty && stop.isEmpty && run.isEmpty }
    }

    /// - Parameters:
    ///   - folder: the settled session's working folder.
    ///   - ownWorktree: the folder is a worktree made for that session, not the project's own checkout.
    ///   - openFolders: the folders of sessions that have not settled.
    static func plan(folder: String, ownWorktree: Bool, terminals: [Terminal], scripts: [ProjectScript],
                     openFolders: [String]) -> Plan {
        let root = normalized(folder)
        guard !root.isEmpty, root != "/" else { return Plan() }
        // Another session at work here or around it (a session in the repository root sees this worktree's folder too).
        if openFolders.map(normalized).contains(where: { overlaps($0, root) }) { return Plan() }
        var plan = Plan()
        let stopping = Set(scripts.filter(\.stopOnSettle).map(\.command))
        for terminal in terminals where terminal.running && within(normalized(terminal.origin), root) {
            if let command = terminal.command, stopping.contains(command), !terminal.idleAtPrompt {
                plan.stop.append(terminal.id)
            } else if terminal.idleAtPrompt {
                plan.close.append(terminal.id)
            }
        }
        if ownWorktree { plan.run = scripts.filter(\.runOnSettle) }
        return plan
    }

    /// The command a `runOnSettle` script runs with: its terminal ends when it succeeds, and stays open with the error
    /// when it fails.
    static func cleanupCommand(_ command: String) -> String {
        "\(command) && exit 0"
    }

    static func normalized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    private static func within(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        within(a, b) || within(b, a)
    }
}
