import Foundation

/// The decisions behind sessions that keep running while Nook is closed (`SessionKeeper`, `WorkspaceManager+Kept`): which
/// sessions stay with their keeper when Nook quits, how a launch takes each one up again, and what the quit confirmation
/// says. Pure, so the state machine is tested without processes.
enum KeptRuns {
    /// A session as quitting sees it.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var status: RunStatus
        /// It has a keeper folder (`WorkspaceRun.kept`).
        var hasKeeper: Bool
        /// Its keeper's process is still connected and running.
        var keeperRunning: Bool
        /// An approval or question waits for you: what it asked went with Nook, so it stops as before.
        var waitsForYou: Bool
    }

    /// What quitting does with each session.
    enum OnQuit: Equatable, Sendable {
        /// Nook lets go; the agent goes on.
        case keep
        /// Nook stops it, as without keepers (and forgets the keeper folder).
        case stop
        /// Not at work: nothing to do.
        case idle
    }

    static func onQuit(_ run: Candidate, enabled: Bool) -> OnQuit {
        guard run.status.isActive else { return .idle }
        guard enabled, run.hasKeeper, run.keeperRunning, run.status == .running, !run.waitsForYou else { return .stop }
        return .keep
    }

    /// What a launch does with a session it loaded.
    enum OnLaunch: Equatable, Sendable {
        /// Attach to its keeper, from this much of its output.
        case attach(offset: UInt64)
        /// Its keeper is gone (or it was not at work): cut off by the restart, as without a keeper.
        case gone
        /// No keeper: the default path, untouched.
        case none
    }

    /// `savedOffset` is how far the last Nook handled the output; nil after a crash, when Nook goes on from the spool's end
    /// (`spoolSize`) so nothing shows twice.
    static func onLaunch(status: RunStatus, hasKeeper: Bool, keeperAlive: Bool, savedOffset: UInt64?, spoolSize: UInt64?) -> OnLaunch {
        guard hasKeeper else { return .none }
        guard status.isActive, keeperAlive else { return .gone }
        return .attach(offset: savedOffset ?? spoolSize ?? 0)
    }

    /// The quit confirmation: how many sessions keep running and how many stop.
    struct QuitSummary: Equatable, Sendable {
        var keep: Int
        var stop: Int
        var isEmpty: Bool { keep == 0 && stop == 0 }
    }

    static func quitSummary(_ runs: [Candidate], enabled: Bool) -> QuitSummary {
        var summary = QuitSummary(keep: 0, stop: 0)
        for run in runs {
            switch onQuit(run, enabled: enabled) {
            case .keep: summary.keep += 1
            case .stop: summary.stop += 1
            case .idle: break
            }
        }
        return summary
    }

    /// Keeper folders that no session claims any more: left by a session that was deleted, or by a crash before Nook saved
    /// the folder's name. Settings stops them.
    static func orphans(folders: [String], claimed: Set<String>) -> [String] {
        folders.filter { !claimed.contains($0) }.sorted()
    }
}
