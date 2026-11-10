import Foundation

// A compaction of a session that runs in a terminal, as the agent's hooks report it (`AgentHub`), so its conversation
// shows "Compacting the conversation…" while the agent summarizes, like a session Nook runs (`CompactionProgress`).
//
// What each agent's hooks say (see the coding agent matrix in docs/INTEGRATIONS.md):
// - Claude Code: `PreCompact` (`trigger`: manual or auto) and `PostCompact`; after it also `SessionStart` with
//   `source: "compact"`, and the `compact_boundary` in the transcript.
// - Codex: `PreCompact` and `PostCompact` (`trigger`: manual or auto).
// - Gemini CLI: `PreCompress` (`trigger`: manual or auto), nothing when it is done.
// - Cursor and Copilot CLI: `preCompact`, nothing when it is done.
// - OpenCode (Nook's plugin): its `experimental.session.compacting` hook and the `session.compacted` event.
// Without an event for the end, the next event of the session ends it (the agent does nothing else while it compacts),
// the compacted notice in the transcript ends it on screen, and after `timeout` it is no longer believed.
//
// Foundation only, so the tests drive it without an agent.

enum HookCompaction {
    /// What a hook event means for a compaction that may run.
    enum Change: Equatable {
        /// The agent started compacting.
        case start
        /// Whatever ran is over: the compaction ended, or the agent went on with something else.
        case end
    }

    /// After this long a compaction no hook ended is no longer shown: an agent that says only when it starts and then
    /// goes quiet (a manual compaction in Gemini CLI, Cursor or Copilot CLI) does not compact forever.
    static let timeout: TimeInterval = 300

    /// The hook events Nook installs for a compaction, by the agent's own names (`AgentConfigInstaller`). The first is
    /// the one whose absence marks an install as made by an older Nook.
    static let claudeCodeEvents = ["PreCompact", "PostCompact"]
    static let codexEvents = ["PreCompact", "PostCompact"]
    static let geminiEvents = ["PreCompress"]
    static let cursorEvents = ["preCompact"]
    static let copilotEvents = ["preCompact"]

    /// Other agents' names for a compaction, as Claude Code's (`AgentHub.normalize`).
    static let canonical = ["PreCompress": "PreCompact", "preCompact": "PreCompact", "postCompact": "PostCompact"]

    /// `kind`: the event's name as `AgentHub.normalize` gives it.
    static func change(kind: String) -> Change {
        kind == "PreCompact" ? .start : .end
    }

    /// Whether a compaction that started at `since` still shows at `now`.
    static func isLive(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < timeout
    }

    /// Whether the transcript shows the compaction that started at `since` as done: a compacted notice from then on, or,
    /// without times, a compacted notice that is the last thing in it.
    static func finished(_ messages: [AgentChatMessage], since: Date) -> Bool {
        // A transcript's times are to the second or the millisecond, the hook's to the moment it came in.
        guard let index = messages.lastIndex(where: { if case .compacted = $0.notice { return true } else { return false } })
        else { return false }
        guard let date = messages[index].date else { return index == messages.count - 1 }
        return date >= since.addingTimeInterval(-2)
    }

    /// Whether a hooks object lacks Nook's hook for one of `events` (an install made before Nook showed compactions):
    /// `ours` tells Nook's own entries from the user's.
    static func lacks(_ events: [String], in hooks: [String: Any], ours: (Any) -> Bool) -> Bool {
        events.contains { event in hooks[event].map { !ours($0) } ?? true }
    }
}
