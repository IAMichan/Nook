import Foundation

/// How far a new session's worktree is: the steps between "start" and the agent's first output, each with what it took.
/// Filled in by `prepareWorktreeAndLaunch` as each step really runs (nothing is timed for show), and shown in the
/// conversation as a checklist until the agent answers. Lives in memory only: once the agent runs, it is gone.
struct WorktreeSetupProgress: Equatable, Sendable {
    enum Step: String, CaseIterable, Sendable {
        /// `git fetch` of a remote-tracking base (`origin/main`), so the worktree starts from its latest commit.
        case fetchBase
        /// `git worktree add` (or a cached checkout), the index refresh and the submodules.
        case checkOut
        /// The project's `runOnWorktreeCreate` scripts from `nook.json`.
        case runSetup
        /// The agent's process, until its first output.
        case startAgent

        var titleKey: String { "ws.setup.step.\(rawValue)" }
    }

    enum State: Equatable, Sendable {
        case pending
        case running(since: Date)
        case done(TimeInterval)
        case skipped
        case failed(String)
    }

    /// A line under Details: what a step did, in words.
    struct Note: Equatable, Sendable, Identifiable {
        let id: Int
        let step: Step
        let text: String
    }

    private(set) var states: [Step: State] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    private(set) var notes: [Note] = []
    let startedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    func state(_ step: Step) -> State { states[step] ?? .pending }

    func isRunning(_ step: Step) -> Bool {
        if case .running = state(step) { return true }
        return false
    }

    /// The step that runs now, if any.
    var current: Step? { Step.allCases.first { isRunning($0) } }

    /// The step that failed and why, if one did.
    var failure: (step: Step, message: String)? {
        for step in Step.allCases {
            if case .failed(let message) = state(step) { return (step, message) }
        }
        return nil
    }

    /// Every step done or skipped.
    var isComplete: Bool {
        Step.allCases.allSatisfy {
            switch state($0) {
            case .done, .skipped: return true
            default: return false
            }
        }
    }

    mutating func begin(_ step: Step, now: Date = Date()) {
        states[step] = .running(since: now)
    }

    /// Ends a running step; a step that never began counts from when the previous one ended (at least zero).
    mutating func finish(_ step: Step, now: Date = Date()) {
        if case .running(let since) = state(step) {
            states[step] = .done(max(0, now.timeIntervalSince(since)))
        } else {
            states[step] = .done(0)
        }
    }

    mutating func skip(_ step: Step) {
        states[step] = .skipped
    }

    /// Fails `step`; the steps after it never run.
    mutating func fail(_ step: Step, _ message: String) {
        states[step] = .failed(message)
    }

    mutating func note(_ step: Step, _ text: String) {
        guard !text.isEmpty else { return }
        notes.append(Note(id: notes.count, step: step, text: text))
    }

    /// "774ms", "1.4s", "2m 05s": a step's time as t3code and an agent's own transcript show it.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %02ds", whole / 60, whole % 60)
    }
}

/// What fetching a remote-tracking base came to (see `GitService.refreshRemoteBase`).
enum RemoteBaseRefresh: Equatable, Sendable {
    /// Fetched just now.
    case fetched
    /// A local base, or a remote this repository does not have: nothing to fetch.
    case local
    /// The fetch failed (offline, no access): the worktree starts from the last fetched state.
    case failed(String)
}
