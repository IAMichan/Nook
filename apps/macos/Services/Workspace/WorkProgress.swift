import Foundation

// How far a running command or subagent is, so you can tell one that is nearly done from one that has just begun. Two
// sources, both from what Nook already has, nothing made up:
//
// - Reported: the command prints it itself ("[12/340] Compiling", "Receiving objects:  45%", pytest's "[ 45%]"). Read
//   from the end of what it printed so far: a call whose output streams (Codex, the ACP agents, Nook's terminal), and the
//   output file Claude Code writes for a command in the background.
// - Expected: the same work ran before in this session (the same command line, a subagent of the same kind) and Nook
//   knows how long it took (`RunEvent.ended`). The view fills a bar over that time, marked as an estimate.
//
// The same for every coding agent: it reads only RunEvents. Foundation only, so the tests use it directly.

/// How far a piece of running work is.
struct WorkProgress: Equatable, Sendable {
    /// The share done (0…1) the work printed itself; nil when it prints none.
    var reported: Double?
    /// When it started.
    var started: Date
    /// How long the same work took before (the median of its earlier runs); nil when it did not run before.
    var expected: TimeInterval?

    /// Below this a step is too quick for an estimate to tell you anything.
    static let shortestEstimate: TimeInterval = 5
    /// Subagents of one kind differ more than runs of one command: an estimate needs this many earlier ones.
    static let subagentSamples = 2

    /// "45": the reported share in whole percent.
    var percent: Int? { reported.map { Int(($0 * 100).rounded(.down)) } }

    /// When an estimated bar is full: a little after the expected end, so it does not sit full while the work goes on.
    var estimatedEnd: Date? { expected.map { started.addingTimeInterval($0 / 0.9) } }

    // MARK: What it printed

    /// The share done the last progress line in `text` reports, or nil when it has none. Only the end counts: that is
    /// where the newest line is, and a progress bar redraws itself on one line with carriage returns.
    static func reported(in text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let tail = text.suffix(4_000)
        let lines = tail.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" }
        for line in lines.reversed().prefix(12) {
            if let share = share(String(line)) { return share }
        }
        return nil
    }

    /// "[ 12/340]" (swift build, ninja, cargo's "] 120/340: "), else a percentage that is not about something else
    /// (CPU, memory, coverage, a ratio in a report).
    static func share(_ line: String) -> Double? {
        let lower = line.lowercased()
        if let match = lower.firstMatch(of: #/\[\s*(\d{1,7})\s*\/\s*(\d{1,7})\s*\]/#) ?? lower.firstMatch(of: #/\]\s*(\d{1,7})\/(\d{1,7}):/#),
           let done = Double(match.1), let total = Double(match.2), total > 1, done <= total {
            return done / total
        }
        let unrelated = ["cpu", "mem", "coverage", "covered", "branch", "stmts", "lines", "functions", "battery", "disk",
                         "similarity", "accuracy", "confidence", "discount"]
        guard !unrelated.contains(where: lower.contains) else { return nil }
        // The last percentage on the line: "45% (1200/2600)" and "Receiving objects:  45% (12/26)" both give 45.
        guard let match = lower.matches(of: #/(?:^|[^\d.])(\d{1,3}(?:\.\d+)?)\s?%/#).last,
              let value = Double(match.1), value <= 100 else { return nil }
        return value / 100
    }

    // MARK: Earlier runs

    /// What makes two runs the same work: the command line (spaces folded), or a subagent's kind. Nil for other steps.
    static func key(_ event: RunEvent) -> String? {
        guard event.kind == .tool, !event.text.hasPrefix("↳") else { return nil }
        if Subagents.isLaunch(event) {
            let input = AgentActivity.input(event.detail) ?? [:]
            let kind = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            return "agent:" + kind
        }
        let tool = event.tool ?? ""
        let isCommand = ToolCategory.of(tool: tool) == .command
            || tool.hasPrefix(BridgeTool.toolPrefix) && BridgeTool.named(tool) == .terminalRun
        guard isCommand, let command = AgentActivity.command(event) else { return nil }
        let folded = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : "command:" + folded
    }

    /// How long a finished run took, when Nook saw it end.
    static func duration(_ event: RunEvent) -> TimeInterval? {
        guard event.state == .done, let ended = event.ended else { return nil }
        let seconds = ended.timeIntervalSince(event.date)
        return seconds > 0 ? seconds : nil
    }

    /// How long the work `event` does took before in `events`: the median of its earlier finished runs. Nil when it did
    /// not run before (often enough, for a subagent), or it was quick.
    static func expected(for event: RunEvent, in events: [RunEvent]) -> TimeInterval? {
        guard let key = key(event) else { return nil }
        let durations = events.compactMap { other -> TimeInterval? in
            guard other.id != event.id, other.ended != nil, other.tool == event.tool, other.date < event.date,
                  let seconds = duration(other), Self.key(other) == key else { return nil }
            return seconds
        }.sorted()
        let needed = key.hasPrefix("agent:") ? subagentSamples : 1
        guard durations.count >= needed else { return nil }
        let middle = durations.count / 2
        let median = durations.count % 2 == 1 ? durations[middle] : (durations[middle - 1] + durations[middle]) / 2
        return median >= shortestEstimate ? median : nil
    }

    /// How far a running command or subagent in `events` is; nil when nothing says.
    static func of(_ event: RunEvent, in events: [RunEvent]) -> WorkProgress? {
        guard event.kind == .tool, event.state == .running || event.state == nil else { return nil }
        let reported = Subagents.isLaunch(event) ? nil : reported(in: event.output)
        let expected = expected(for: event, in: events)
        guard reported != nil || expected != nil else { return nil }
        return WorkProgress(reported: reported, started: event.date, expected: expected)
    }

    /// The progress of every running command and subagent in `events` that has one, by event id.
    static func running(in events: [RunEvent]) -> [UUID: WorkProgress] {
        var result: [UUID: WorkProgress] = [:]
        for event in events where event.kind == .tool && event.state == .running {
            if let progress = of(event, in: events) { result[event.id] = progress }
        }
        return result
    }
}

extension RunEvent {
    /// Notes when a tool call ended, as it settles: how long it took tells how long the same work will take next time
    /// (`WorkProgress.expected`). `wasRunning` is whether it ran before this change.
    mutating func noteEnd(wasRunning: Bool, at now: Date = Date()) {
        guard wasRunning, kind == .tool, ended == nil, state != .running, state != .pending, state != nil else { return }
        ended = now
    }
}
