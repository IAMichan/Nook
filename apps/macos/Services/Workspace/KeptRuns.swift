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

    /// `savedOffset` is how far the last Nook handled the output when it quit. After a crash that is nil, and Nook goes on
    /// from the progress it wrote while it ran (`progress`, `Progress`): what the agent printed since is read again, so a
    /// request or the turn's end is not lost (`Replay` keeps the timeline from showing it twice). Without either, from the
    /// spool's end (`spoolSize`).
    static func onLaunch(status: RunStatus, hasKeeper: Bool, keeperAlive: Bool, savedOffset: UInt64?, progress: UInt64? = nil,
                         spoolSize: UInt64?) -> OnLaunch {
        guard hasKeeper else { return .none }
        guard status.isActive, keeperAlive else { return .gone }
        if let savedOffset { return .attach(offset: savedOffset) }
        if let progress { return .attach(offset: min(progress, spoolSize ?? progress)) }
        return .attach(offset: spoolSize ?? 0)
    }

    // MARK: Progress

    /// How far Nook handled a kept agent's output, written into the keeper's folder while it runs (`AgentProcess`), so a
    /// crash loses no output: the next launch reads on from there.
    struct Progress: Equatable, Sendable {
        var offset: UInt64
        var savedAt: Date
    }

    /// Written at most this often while output streams; at once when a request is answered or a turn ends.
    static let progressInterval: TimeInterval = 1
    static let progressFile = "handled"

    static func shouldWriteProgress(now: Date, lastWritten: Date?, force: Bool) -> Bool {
        force || lastWritten.map { now.timeIntervalSince($0) >= progressInterval } ?? true
    }

    /// How far it is safe to say the output was handled: never past a request (an approval, a question) that still waits
    /// for you, so a crash reads it again and the agent, which still waits too, can be answered.
    static func durableOffset(handled: UInt64, hold: UInt64?) -> UInt64 {
        min(hold ?? handled, handled)
    }

    static func encode(_ progress: Progress) -> Data {
        Data("\(progress.offset) \(progress.savedAt.timeIntervalSince1970)\n".utf8)
    }

    static func decode(_ data: Data) -> Progress? {
        let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, let offset = UInt64(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return Progress(offset: offset, savedAt: Date(timeIntervalSince1970: seconds))
    }

    /// Only into a folder that is still there: a keeper that ended removed it.
    static func writeProgress(_ progress: Progress, folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? encode(progress).write(to: folder.appendingPathComponent(progressFile), options: .atomic)
    }

    static func readProgress(folder: URL) -> Progress? {
        (try? Data(contentsOf: folder.appendingPathComponent(progressFile))).flatMap(decode)
    }

    // MARK: Replay

    /// After a crash Nook reads a kept agent's output again from its last progress (`Progress`). What it shows again (text,
    /// thinking, tool calls, approvals) was often already in the timeline: such an event takes the place of the one
    /// already there instead of showing twice, in the order they came. Only events from the time of that progress on
    /// are candidates; text that grew while streaming matches the start of it.
    struct Replay: Equatable, Sendable {
        /// The timeline's events that may be shown again, oldest first, by id.
        private(set) var candidates: [RunEvent]
        /// Events read again take the place of these: new id → the id already in the timeline.
        private(set) var aliases: [UUID: UUID] = [:]
        /// How far the output goes that the crashed Nook could have handled: past it, nothing is read again.
        let until: UInt64
        /// How many candidates a replayed event may skip to find its match.
        static let lookahead = 12

        init(timeline: [RunEvent], since: Date, until: UInt64) {
            // A second of slack: the progress is written a moment after the events of the output before it.
            candidates = timeline.filter { $0.date >= since.addingTimeInterval(-1) && Self.replayable($0) }
            self.until = until
        }

        var isDone: Bool { candidates.isEmpty }

        /// The event already in the timeline that `event` shows again, if any; it is used up.
        mutating func match(_ event: RunEvent) -> UUID? {
            guard Self.replayable(event) else { return nil }
            for (index, candidate) in candidates.prefix(Self.lookahead).enumerated() where Self.same(candidate, event) {
                candidates.removeFirst(index + 1)
                aliases[event.id] = candidate.id
                return candidate.id
            }
            return nil
        }

        /// The id an event read again is known by in the timeline.
        func resolve(_ id: UUID) -> UUID { aliases[id] ?? id }

        /// Only what comes from the agent's output: Nook's own notes and your messages are not read again.
        static func replayable(_ event: RunEvent) -> Bool {
            switch event.kind {
            case .assistant, .thinking, .tool, .fileChange, .approval, .result, .error, .page: return true
            case .user, .system: return false
            }
        }

        static func same(_ old: RunEvent, _ new: RunEvent) -> Bool {
            guard old.kind == new.kind else { return false }
            if let call = new.callID, !call.isEmpty { return old.callID == call }
            guard old.callID == nil || old.callID?.isEmpty == true else { return false }
            switch new.kind {
            case .assistant, .thinking:
                // Streamed: the replay starts with the first piece, the timeline may hold more (or, cut off, less).
                return old.text.hasPrefix(new.text) || new.text.hasPrefix(old.text)
            default:
                return old.text == new.text && old.tool == new.tool
            }
        }
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
