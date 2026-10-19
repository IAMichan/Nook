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

    /// Whether an agent process still runs for a session in `cwd`. The hook's folder can be a subfolder of where the
    /// agent started, and a process whose folder could not be read counts as a match.
    static func isRunning(agent: String, cwd: String, in processes: [(name: String, cwd: String)]) -> Bool {
        processes.contains { process in
            guard process.name == agent else { return false }
            return process.cwd.isEmpty || cwd.isEmpty || process.cwd == cwd || cwd.hasPrefix(process.cwd + "/")
        }
    }

    // MARK: Transcript

    /// The state of the last turn, from the end of a Claude Code or Codex transcript (JSONL).
    static func lastTurn(in tail: Data) -> Turn {
        // The first line may be cut off by the tail read; it simply fails to parse.
        let lines = tail.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let turn = claudeTurn(object) ?? codexTurn(object) { return turn }
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
        guard let stop = message["stop_reason"] as? String else { return .open }
        return stop == "tool_use" || stop == "pause_turn" ? .open : .ended
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
