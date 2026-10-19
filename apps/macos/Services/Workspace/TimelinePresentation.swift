import Foundation

// How a session's timeline reads in the narrow notch: a finished turn folds into "Worked for
// 2m 13s" between your message and the agent's answer, consecutive tool calls become one line that says what they did
// ("Ran 3 commands and changed 2 files"), and while the agent works one live line shows what it is doing and thinking.
// Everything in this file depends only on Foundation so tests can use it independently.

/// What a tool call does, for the one-line summary of a group.
enum ToolCategory: Int, Comparable, Sendable {
    // Order is priority in the summary: what changed something comes first.
    case command, edit, read, search, other

    static func < (lhs: ToolCategory, rhs: ToolCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Claude Code, Codex, Gemini CLI and Nook's own tools by name.
    static func of(tool: String) -> ToolCategory {
        let name = tool.lowercased()
        if name.hasPrefix(BridgeTool.toolPrefix) {
            return BridgeTool.named(tool) == .terminalRun ? .command : .other
        }
        switch name {
        case "bash", "shell", "run_shell_command", "nook terminal", "killshell", "bashoutput":
            return .command
        case "edit", "multiedit", "write", "notebookedit", "write_file", "replace", "apply_patch":
            return .edit
        case "read", "read_file", "read_many_files", "ls", "list_directory", "notebookread":
            return .read
        case "grep", "glob", "search_file_content", "websearch", "webfetch", "web_search", "web_fetch", "google_web_search":
            return .search
        default:
            return .other
        }
    }
}

/// What a group of tool calls did, counted per category. Edits count files, not calls.
struct ToolTally: Equatable, Sendable {
    var counts: [ToolCategory: Int] = [:]
    var failed = false
    /// The tests, builds and linters among the calls: the latest outcome of each kind.
    var checks: [VerificationCheck] = []

    init(_ events: [RunEvent]) {
        var editedFiles: Set<String> = []
        var edits = 0
        for event in events {
            if event.state == .failed { failed = true }
            switch event.kind {
            case .fileChange:
                // A file change carries its path in `detail` (or the text).
                editedFiles.insert(event.detail ?? event.text)
            case .tool:
                let category = ToolCategory.of(tool: event.tool ?? "")
                if category == .edit {
                    if let path = Self.path(event.detail) { editedFiles.insert(path) } else { edits += 1 }
                } else {
                    counts[category, default: 0] += 1
                }
            default:
                continue
            }
        }
        let editCount = max(editedFiles.count, edits)
        if editCount > 0 { counts[.edit] = editCount }
        checks = Verification.checks(events)
    }

    /// The categories with a count, in summary order.
    var parts: [(category: ToolCategory, count: Int)] {
        counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { (category: $0.key, count: $0.value) }
    }

    /// The file path in a tool's JSON input, if it has one.
    private static func path(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ToolSummary.path(object)
    }
}

/// One block of the timeline as the notch shows it.
enum TimelineBlock: Identifiable, Equatable {
    case event(RunEvent)
    /// Two or more tool calls (and file changes) in a row.
    case tools(id: UUID, events: [RunEvent], tally: ToolTally)
    /// A finished turn's work between your message and the answer, and the `seconds` it took.
    case fold(id: UUID, seconds: Double, blocks: [TimelineBlock])

    var id: UUID {
        switch self {
        case .event(let event): return event.id
        case .tools(let id, _, _): return id
        case .fold(let id, _, _): return id
        }
    }
}

/// What the agent is doing right now: the running (or last) tool and the headline of its latest thinking.
struct LiveActivity: Equatable, Sendable {
    var tool: String?
    var thought: String?
}

enum TimelinePresentation {
    /// Groups the events of a session into blocks. `active`: the last turn is still running and never folds.
    static func blocks(_ events: [RunEvent], active: Bool) -> [TimelineBlock] {
        let turns = split(visible(events, active: active))
        var blocks: [TimelineBlock] = []
        for (index, turn) in turns.enumerated() {
            let isLast = index == turns.count - 1
            blocks += present(turn, open: isLast && active)
        }
        return blocks
    }

    /// One line per command: an approval you gave says nothing the tool call it let through does not, and the tool that
    /// runs right now is the live line under the timeline (with its time), so neither gets a row of its own.
    static func visible(_ events: [RunEvent], active: Bool) -> [RunEvent] {
        var hidden: Set<UUID> = []
        let turns = split(events)
        for turn in turns {
            let calls = Set(turn.filter { $0.kind == .tool }.map { key($0.tool, $0.text) })
            for approval in turn where approval.kind == .approval && approval.state == .allowed
                && calls.contains(key(approval.tool, approval.text)) {
                hidden.insert(approval.id)
            }
        }
        if active, let turn = turns.last, let running = turn.last(where: { $0.kind == .tool && $0.state == .running }) {
            hidden.insert(running.id)
        }
        return hidden.isEmpty ? events : events.filter { !hidden.contains($0.id) }
    }

    /// A tool call and the approval that asked for it share tool and summary; a nested call carries "↳ " in front.
    private static func key(_ tool: String?, _ text: String) -> String {
        (tool ?? "") + "\u{0}" + (text.hasPrefix("↳ ") ? String(text.dropFirst(2)) : text)
    }

    /// The live line for the running turn: the tool that runs (or ran last) and what the agent last thought about.
    static func live(_ events: [RunEvent]) -> LiveActivity {
        let turn = split(events).last ?? []
        let tool = turn.last { $0.kind == .tool && $0.state == .running } ?? turn.last { $0.kind == .tool }
        let thought = turn.last { $0.kind == .thinking }.map { headline($0.text) }
        return LiveActivity(tool: tool?.text, thought: thought.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Every event inside blocks, in order: what a fold or a group holds.
    static func events(_ blocks: [TimelineBlock]) -> [RunEvent] {
        blocks.flatMap { block -> [RunEvent] in
            switch block {
            case .event(let event): return [event]
            case .tools(_, let events, _): return events
            case .fold(_, _, let inner): return events(inner)
            }
        }
    }

    /// The first bold heading of a thought ("**Checking the tests**"), or its first sentence.
    static func headline(_ text: String, limit: Int = 110) -> String {
        if let start = text.range(of: "**"), let end = text.range(of: "**", range: start.upperBound..<text.endIndex) {
            let bold = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !bold.isEmpty { return ToolSummary.oneLine(bold, limit) }
        }
        let flat = ToolSummary.oneLine(text, 400)
        if let stop = flat.firstIndex(where: { ".!?".contains($0) }) {
            let sentence = String(flat[...stop])
            if sentence.count >= 12 { return ToolSummary.oneLine(sentence, limit) }
        }
        return ToolSummary.oneLine(flat, limit)
    }

    // MARK: Turns

    /// A turn starts at each message of yours, and where the agent woke up by itself after background work; anything
    /// before the first one is a turn of its own.
    static func split(_ events: [RunEvent]) -> [[RunEvent]] {
        var turns: [[RunEvent]] = []
        for event in events {
            if event.kind == .user || event.kind == .system && event.tool == "wake" || turns.isEmpty { turns.append([event]) } else { turns[turns.count - 1].append(event) }
        }
        return turns
    }

    private static func present(_ turn: [RunEvent], open: Bool) -> [TimelineBlock] {
        guard let first = turn.first else { return [] }
        let finished = turn.last { $0.kind == .result }
        let troubled = turn.contains { $0.kind == .error || $0.kind == .approval && $0.state == .pending }
            || finished?.state == .failed
        // Fold only a turn that ended well: its answer stays, the work in between folds away.
        guard !open, first.kind == .user, let finished, !troubled,
              let answer = turn.lastIndex(where: { $0.kind == .assistant }) else {
            return group(turn)
        }
        let work = turn.enumerated().filter { $0.offset != 0 && $0.offset != answer && $0.element.kind != .result }.map(\.element)
        guard work.contains(where: { $0.kind != .assistant }) else { return group(turn) }
        let seconds = max(0, finished.date.timeIntervalSince(first.date))
        // The fold takes the id of the first work it hides: never the same as a block shown next to it.
        return [.event(first), .fold(id: work[0].id, seconds: seconds, blocks: group(work)),
                .event(turn[answer]), .event(finished)]
    }

    /// Two or more tool calls in a row become one block. Everything else stands on its own: the agent's thinking stays
    /// readable in the chat, and errors and approvals are never hidden inside a group.
    static func group(_ events: [RunEvent]) -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var run: [RunEvent] = []
        func isWork(_ event: RunEvent) -> Bool { event.kind == .tool || event.kind == .fileChange }
        func flush() {
            // Thinking after the last tool belongs to what comes next, not to the group.
            var trailing: [RunEvent] = []
            while let last = run.last, !isWork(last) { trailing.insert(run.removeLast(), at: 0) }
            if run.filter(isWork).count >= 2 {
                blocks.append(.tools(id: run[0].id, events: run, tally: ToolTally(run)))
            } else {
                blocks += run.map { TimelineBlock.event($0) }
            }
            blocks += trailing.map { TimelineBlock.event($0) }
            run = []
        }
        for event in events {
            if isWork(event) {
                run.append(event)
            } else {
                flush()
                blocks.append(.event(event))
            }
        }
        flush()
        return blocks
    }
}

/// A subagent the agent started (Claude Code's Task or Agent tool)'s subagent bar shows it.
struct SubagentInfo: Identifiable, Equatable, Sendable {
    var id: UUID
    /// "Explore", "general-purpose"…
    var kind: String
    var title: String
    var prompt: String
    var state: RunEvent.State?
    var output: String?

    var isRunning: Bool { state == nil || state == .running || state == .pending }
}

enum Subagents {
    static let tools: Set<String> = ["Task", "Agent"]

    /// The subagents of the latest turn, in the order they started.
    static func latest(_ events: [RunEvent]) -> [SubagentInfo] {
        list(TimelinePresentation.split(events).last ?? [])
    }

    static func list(_ events: [RunEvent]) -> [SubagentInfo] {
        events.compactMap { event in
            guard event.kind == .tool, let tool = event.tool, tools.contains(tool), !event.text.hasPrefix("↳") else { return nil }
            let input = event.detail.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let kind = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            let title = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? event.text
            return SubagentInfo(id: event.id, kind: kind, title: title, prompt: (input["prompt"] as? String) ?? "",
                                state: event.state, output: event.output)
        }
    }
}

/// What one turn changed: the files, from the turn's own edits and file changes, and
/// the snapshots around it when the session has them.
enum TurnChanges {
    struct Turn: Equatable, Sendable {
        var start: Date
        var end: Date
        var files: [String]
    }

    /// Per finished turn, keyed by the id of the event that ends it (its result): when it ran and the files it touched,
    /// in order.
    static func byTurnEnd(_ events: [RunEvent]) -> [UUID: Turn] {
        var result: [UUID: Turn] = [:]
        for turn in TimelinePresentation.split(events) {
            guard let first = turn.first, let end = turn.last(where: { $0.kind == .result }) else { continue }
            let files = self.files(turn)
            if !files.isEmpty { result[end.id] = Turn(start: first.date, end: end.date, files: files) }
        }
        return result
    }

    /// The files of a turn: file changes by path, edit tools by the path in their input.
    static func files(_ turn: [RunEvent]) -> [String] {
        var seen: [String] = []
        for event in turn {
            var path: String?
            switch event.kind {
            case .fileChange:
                path = event.detail ?? event.text
            case .tool where ToolCategory.of(tool: event.tool ?? "") == .edit:
                path = event.detail.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap(ToolSummary.path)
            default:
                continue
            }
            if let path, !path.isEmpty, !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    /// The snapshots around a turn that started at `start` and ended at `end`: the last one made before it, and the first
    /// one made after it (nil: compare with the files as they are now).
    static func checkpoints(_ checkpoints: [RunCheckpoint], start: Date, end: Date) -> (before: RunCheckpoint, after: RunCheckpoint?)? {
        guard let before = checkpoints.last(where: { $0.date <= start }) else { return nil }
        return (before, checkpoints.first { $0.date >= end && $0.date > before.date })
    }
}

/// Work an agent left running in the background, finished after its turn.
enum BackgroundWork {
    /// The session still has work running in the background after its turn, so it should stay open (up to four hours
    /// instead of thirty minutes): from the latest turn, a tool still running when it ended, or one started
    /// to run in the background. It ends with a turn the agent woke up for by itself. `before` is what was known.
    static func pending(after events: [RunEvent], before: Bool) -> Bool {
        guard let turn = TimelinePresentation.split(events).last else { return before }
        let started = turn.contains { event in
            guard event.kind == .tool else { return false }
            if event.state == .running { return true }
            guard let detail = event.detail, detail.contains("run_in_background") else { return false }
            let input = detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (input?["run_in_background"] as? Bool) == true
        }
        if started { return true }
        if turn.first?.kind == .system, turn.first?.tool == "wake" { return false }
        return before
    }

    /// What Codex gets when a background command finished: the command, its exit code and the end of its output.
    static func codexMessage(command: String, exitCode: Int?, output: String) -> String {
        let exit = exitCode.map(String.init) ?? "unknown"
        var message = "Background command completed (exit \(exit)): \(command)"
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var tail = lines.suffix(40).joined(separator: "\n")
        if tail.count > 4000 { tail = String(tail.suffix(4000)) }
        if !tail.isEmpty { message += "\n\nOutput tail:\n" + tail }
        return message
    }
}
