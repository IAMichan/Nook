import Foundation

// How an agent's own transcript reads in Nook, the way Code shows a thread: your messages in a bubble on the right,
// the agent's answers as plain text on the left, and the work in between as quiet one-line rows. Steps in a row become
// one line that says what they did ("Ran 3 commands and read 2 files"); a finished turn folds everything before its
// final answer into "Worked for 1m 3s"; the turn that still runs shows for how long it has been working and what it
// does right now at its end. Everything in this file depends only on Foundation so tests can use it independently.

/// One row of a transcript as the conversation view shows it.
enum TranscriptRow: Identifiable, Equatable {
    case user(AgentChatMessage)
    /// `isFinal`: the last answer of a turn, which carries the copy button and its time.
    case assistant(AgentChatMessage, isFinal: Bool)
    case thinking(AgentChatMessage)
    /// A single step on its own.
    case step(AgentToolStep)
    /// Two or more steps in a row, behind one sentence.
    case group(id: String, steps: [AgentToolStep])
    /// The work of a finished turn before its answer, and the `seconds` it took (nil: the transcript has no times).
    case fold(id: String, seconds: Double?, rows: [TranscriptRow])
    /// At the top of the turn that runs: "Working for 12s" since `since`.
    case working(since: Date?)
    /// At the end of the turn that runs: the step that runs now, or nil while the agent thinks.
    case live(AgentToolStep?)

    var id: String {
        switch self {
        case .user(let message), .thinking(let message): return message.id
        case .assistant(let message, _): return message.id
        case .step(let step): return "step:" + step.id
        case .group(let id, _): return "group:" + id
        case .fold(let id, _, _): return "fold:" + id
        case .working: return "working"
        case .live: return "live"
        }
    }
}

extension ToolTally {
    /// What a run of transcript steps did, counted per category. Edits count files, not calls.
    init(steps: [AgentToolStep]) {
        self.init([])
        var files: Set<String> = []
        var edits = 0
        for step in steps {
            if step.state == .failed { failed = true }
            let category = ToolCategory.of(tool: step.name)
            if category == .edit {
                if step.summary.isEmpty { edits += 1 } else { files.insert(step.summary) }
            } else {
                counts[category, default: 0] += 1
            }
        }
        if files.count + edits > 0 { counts[.edit] = files.count + edits }
    }
}

enum TranscriptPresentation {
    /// The rows of a conversation. `working`: the agent works on the last turn, which stays open and shows its progress.
    static func rows(_ messages: [AgentChatMessage], working: Bool) -> [TranscriptRow] {
        // Thinking the agent kept to itself says nothing in a timeline that already shows the work.
        let turns = split(messages.filter { !($0.isThinking && $0.text.isEmpty) })
        var rows: [TranscriptRow] = []
        for (index, turn) in turns.enumerated() {
            rows += present(turn, open: working && index == turns.count - 1)
        }
        return rows
    }

    /// A turn starts at each message of yours; anything before the first one is a turn of its own.
    static func split(_ messages: [AgentChatMessage]) -> [[AgentChatMessage]] {
        var turns: [[AgentChatMessage]] = []
        for message in messages {
            if message.fromUser || turns.isEmpty { turns.append([message]) } else { turns[turns.count - 1].append(message) }
        }
        return turns
    }

    /// How long a turn took: from your message to the last thing that came in.
    static func seconds(_ turn: [AgentChatMessage]) -> Double? {
        guard let start = turn.first?.date else { return nil }
        guard let end = turn.compactMap({ $0.updated ?? $0.date }).max(), end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func present(_ turn: [AgentChatMessage], open: Bool) -> [TranscriptRow] {
        guard let first = turn.first else { return [] }
        if open { return presentOpen(turn) }
        let answer = turn.lastIndex { $0.kind == .assistant }
        // Fold a finished turn: your message, "Worked for …", and its final answer; the rest a click away.
        guard first.fromUser, let answer else { return group(turn, finalID: answer.map { turn[$0].id }) }
        let work = turn.indices.filter { $0 != 0 && $0 != answer }.map { turn[$0] }
        guard let firstWork = work.first else { return [.user(first), .assistant(turn[answer], isFinal: true)] }
        return [.user(first),
                .fold(id: firstWork.id, seconds: seconds(turn), rows: group(work, finalID: nil)),
                .assistant(turn[answer], isFinal: true)]
    }

    /// The turn that runs: how long it has been going right under your message, the work so far, and at the end the step
    /// that runs now (taken out of its group) or that the agent is thinking.
    private static func presentOpen(_ turn: [AgentChatMessage]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var work = turn
        if let first = turn.first, first.fromUser {
            rows.append(.user(first))
            work.removeFirst()
        }
        rows.append(.working(since: turn.first?.fromUser == true ? turn.first?.date : nil))
        var current: AgentToolStep?
        if var last = work.last, last.isTools, let step = last.steps.last, step.state == .running {
            current = step
            last.steps.removeLast()
            if last.steps.isEmpty { work.removeLast() } else { work[work.count - 1] = last }
        }
        rows += group(work, finalID: nil)
        rows.append(.live(current))
        return rows
    }

    /// Steps in a row (also across lists the agent's thinking split) become one row; everything else stands on its own.
    static func group(_ messages: [AgentChatMessage], finalID: String?) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var steps: [AgentToolStep] = []
        var groupID = ""
        func flush() {
            if steps.count == 1 { rows.append(.step(steps[0])) }
            if steps.count > 1 { rows.append(.group(id: groupID, steps: steps)) }
            steps = []
        }
        for message in messages {
            switch message.kind {
            case .tools:
                if steps.isEmpty { groupID = message.id }
                steps += message.steps
            case .user:
                flush()
                rows.append(.user(message))
            case .assistant:
                flush()
                rows.append(.assistant(message, isFinal: message.id == finalID))
            case .thinking:
                flush()
                rows.append(.thinking(message))
            }
        }
        flush()
        return rows
    }

    /// A thought on one line: its first bold heading or its first sentence, as Code shows reasoning in the work log.
    static func headline(_ text: String) -> String {
        TimelinePresentation.headline(text)
    }
}
