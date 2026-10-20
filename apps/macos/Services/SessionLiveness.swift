import Foundation

/// Second opinion on a hooked session that still reads as busy. Hooks can go missing (Nook restarted mid-turn, a hook
/// timed out, an agent version that skips `Stop`), and then a session would show "working" for hours. Nook
/// treats "running" as a claim to verify: the transcript says whether the last turn ended, the process list says
/// whether the agent is still there at all.
enum SessionLiveness {
    enum Turn: Equatable { case ended, open, unknown }

    enum Verdict: Equatable {
        /// The transcript shows the turn finished, but no `Stop` arrived.
        case turnEnded
        /// No process of this agent is left in its folder.
        case processGone
    }

    /// How long the transcript and hooks must be quiet before the transcript is trusted over the hooks: Claude Code writes
    /// the final line just before it fires `Stop`, and a normal `Stop`, or a new prompt reaching the file, should win.
    static let settleDelay: TimeInterval = 15
    /// How long a session must be quiet, and missing from the process list, before it counts as closed.
    static let goneDelay: TimeInterval = 30
    /// Scans in a row (10 s apart) a process must be missing, so one odd `ps` or `lsof` result never ends a session.
    static let goneScans = 2
    /// Enough of the transcript to find the last message line; a reply with a big tool result can be longer, and then
    /// the turn stays unknown rather than guessed.
    static let tailBytes: UInt64 = 256 * 1024

    /// For a session that reads as busy: `working` when it runs, false when it waits for you.
    static func verdict(working: Bool, lastEvent: Date, turn: Turn, transcriptModified: Date?,
                        missingScans: Int, now: Date) -> Verdict? {
        let quiet = now.timeIntervalSince(max(lastEvent, transcriptModified ?? .distantPast))
        if missingScans >= goneScans, now.timeIntervalSince(lastEvent) >= goneDelay { return .processGone }
        // A waiting session asks something of you; only a vanished process settles it.
        if working, turn == .ended, quiet >= settleDelay { return .turnEnded }
        return nil
    }

    /// Whether the agent process of a session still runs. With `pid` (the process its hooks came from) only that process
    /// counts: another session of the same agent in the same folder must not keep a closed one alive. Without it, any
    /// process of the agent in `cwd` does; the hook's folder can be a subfolder of where the agent started, and a
    /// process whose folder could not be read counts as a match.
    static func isRunning(agent: String, cwd: String, pid: Int32? = nil,
                          in processes: [(pid: Int32, name: String, cwd: String)]) -> Bool {
        if let pid { return processes.contains { $0.pid == pid && $0.name == agent } }
        return processes.contains { process in
            guard process.name == agent else { return false }
            return process.cwd.isEmpty || cwd.isEmpty || process.cwd == cwd || cwd.hasPrefix(process.cwd + "/")
        }
    }

    /// The agent process among `lineage` (the hook's sender and the processes it was started from, nearest first):
    /// the first one the process scan knows as this agent.
    static func agentProcess(agent: String, lineage: [Int32], in processes: [(pid: Int32, name: String, cwd: String)]) -> Int32? {
        lineage.first { pid in processes.contains { $0.pid == pid && $0.name == agent } }
    }

    // MARK: Transcript

    /// The state of the last turn, from the end of a Claude Code or Codex transcript (JSONL).
    static func lastTurn(in tail: Data) -> Turn {
        // The first line may be cut off by the tail read; it simply fails to parse.
        let objects = tail.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        let commands = objects.map(localCommand)
        let turns = objects.map { claudeTurn($0) ?? codexTurn($0) }
        // The message line next to `index` in one direction, past bookkeeping lines.
        func neighbour(_ index: Int, _ step: Int) -> Int? {
            var next = index + step
            while objects.indices.contains(next) {
                if commands[next] != nil || turns[next] != nil { return next }
                next += step
            }
            return nil
        }
        for index in objects.indices.reversed() {
            switch commands[index] {
            case .output:
                continue
            case .name:
                // A command that printed something ran in Claude Code itself; one that did not may be a prompt of yours.
                let ranLocally = [neighbour(index, -1), neighbour(index, 1)].contains { side in
                    side.map { commands[$0] == .output } ?? false
                }
                if ranLocally { continue }
                return .open
            case nil:
                if let turn = turns[index] { return turn }
            }
        }
        return .unknown
    }

    /// Claude Code writes each block of a message as its own line, with `stop_reason` null on all but the last and
    /// `tool_use` when a tool call follows. Only a final assistant line ends the turn; any other message keeps it open.
    private static func claudeTurn(_ object: [String: Any]) -> Turn? {
        guard let type = object["type"] as? String, type == "assistant" || type == "user",
              let message = object["message"] as? [String: Any], message["content"] != nil else { return nil }
        // Subagent and bookkeeping lines (skill text, command echoes) say nothing about the main turn.
        if (object["isSidechain"] as? Bool) == true || (object["isMeta"] as? Bool) == true { return nil }
        guard type == "assistant" else { return isInterruption(message["content"]) ? .ended : .open }
        // An API error Claude Code gave up on (a usage limit, an overloaded API) ends the turn, whatever its stop reason.
        if (object["isApiErrorMessage"] as? Bool) == true { return .ended }
        guard let stop = message["stop_reason"] as? String else { return .open }
        return stop == "tool_use" || stop == "pause_turn" ? .open : .ended
    }

    private enum LocalCommand { case name, output }

    /// A slash command run in Claude Code itself (`/exit`, `/usage`, the menu after a usage limit) leaves two user lines,
    /// the command and what it printed, but starts no turn: the turn stands as it was before them.
    private static func localCommand(_ object: [String: Any]) -> LocalCommand? {
        guard (object["type"] as? String) == "user", (object["isSidechain"] as? Bool) != true,
              let message = object["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]], blocks.count == 1, let string = blocks[0]["text"] as? String {
            text = string
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<local-command-stdout>") || trimmed.hasPrefix("<local-command-stderr>") { return .output }
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") { return .name }
        return nil
    }

    /// Esc in Claude Code ends the turn without a `Stop` hook; the transcript gets this marker instead.
    private static func isInterruption(_ content: Any?) -> Bool {
        let marker = "[Request interrupted by user"
        if let text = content as? String { return text.hasPrefix(marker) }
        guard let blocks = content as? [[String: Any]], blocks.count == 1 else { return false }
        return (blocks[0]["text"] as? String)?.hasPrefix(marker) == true
    }

    private static func codexTurn(_ object: [String: Any]) -> Turn? {
        guard (object["type"] as? String) == "event_msg", let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        switch type {
        case "task_complete", "turn_aborted": return .ended
        case "task_started", "user_message": return .open
        default: return nil
        }
    }

    /// The last turn of the transcript at `path` and when it was last written; nil when it cannot be read.
    static func readTurn(path: String) -> (turn: Turn, modified: Date?)? {
        guard !path.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        // Asked every ten seconds per working session: the tail is only read again when the file changed.
        if let modified, let size {
            turnLock.lock()
            let hit = turnCache[path]
            turnLock.unlock()
            if let hit, hit.modified == modified, hit.size == size { return (hit.turn, modified) }
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let turn = lastTurn(in: data)
        if let modified, let size {
            turnLock.lock()
            if turnCache.count > 64 { turnCache.removeAll() }
            turnCache[path] = (modified, size, turn)
            turnLock.unlock()
        }
        return (turn, modified)
    }

    private static let turnLock = NSLock()
    private nonisolated(unsafe) static var turnCache: [String: (modified: Date, size: UInt64, turn: Turn)] = [:]
}
