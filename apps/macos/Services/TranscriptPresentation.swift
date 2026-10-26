import Foundation

// How an agent's own transcript reads in Nook, as a thread: your messages in a bubble on the right,
// the agent's answers as plain text on the left, and the work in between as quiet one-line rows. Steps in a row become
// one line that says what they did ("Ran 3 commands and read 2 files"); a finished turn folds everything before its
// final answer into "Worked for 1m 3s", and the work after a message you sent while it ran into "Continued for 20s";
// the turn that still runs shows for how long it has been working and, at its end, what it thinks and does right now.
// A turn you stopped stays open, and a compaction, an error or a usage limit stays in sight when its turn folds.
// Everything in this file depends only on Foundation so tests can use it independently.

/// One row of a transcript as the conversation view shows it.
enum TranscriptRow: Identifiable, Equatable {
    case user(AgentChatMessage)
    /// `isFinal`: the last answer of a turn, which carries the copy button and its time.
    case assistant(AgentChatMessage, isFinal: Bool)
    case thinking(AgentChatMessage)
    /// A single step on its own.
    case step(AgentToolStep)
    /// Two or more steps in a row, behind one sentence.
    /// `thoughts`: what the agent thought between the steps, by the id of the step each came right before.
    case group(id: String, steps: [AgentToolStep], thoughts: [String: [AgentChatMessage]])
    /// The work of a finished turn before its answer, and the `seconds` the whole turn took (nil: the transcript has no
    /// times).
    case fold(id: String, seconds: Double?, rows: [TranscriptRow])
    /// The work of a finished turn after a message you sent while it ran, and the `seconds` since that message:
    /// "Continued for 20s".
    case continued(id: String, seconds: Double?, rows: [TranscriptRow])
    /// A compaction, an error or a usage limit: never folded away.
    case notice(AgentChatMessage)
    /// At the top of the turn that runs: "Working for 12s" since `since`.
    case working(since: Date?)
    /// At the end of the turn that runs: the step that runs now (nil while the agent thinks), and what the agent thought
    /// right before it, which says why.
    case live(AgentToolStep?, thought: AgentChatMessage?)
    /// At the end of a turn you stopped: "You stopped after 12s", after the message `id` it stopped at.
    case interrupted(id: String, seconds: Double?)

    var id: String {
        switch self {
        case .user(let message), .thinking(let message), .notice(let message): return message.id
        case .assistant(let message, _): return message.id
        case .step(let step): return "step:" + step.id
        case .group(let id, _, _): return "group:" + id
        case .fold(let id, _, _): return "fold:" + id
        case .continued(let id, _, _): return "continued:" + id
        case .working: return "working"
        case .live: return "live"
        case .interrupted(let id, _): return "interrupted:" + id
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
                if step.state != .failed, let changed = step.lines { lines = (lines ?? EditLines()) + changed }
            } else {
                counts[category, default: 0] += 1
            }
        }
        if files.count + edits > 0 { counts[.edit] = files.count + edits }
        checks = Verification.latest(steps.compactMap(Verification.check))
    }
}

extension Verification {
    /// A transcript step that checks the agent's work, and how it went.
    static func check(_ step: AgentToolStep) -> VerificationCheck? {
        guard ToolCategory.of(tool: step.name) == .command, let command = step.command ?? (step.summary.isEmpty ? nil : step.summary),
              let kind = kind(command: command) else { return nil }
        let outcome: VerificationCheck.Outcome = step.state == .failed ? .failed : step.state == .done ? .passed : .running
        return VerificationCheck(kind: kind, outcome: outcome, command: command)
    }
}

extension AgentActivity {
    /// A step of a transcript, which keeps the tool's name, what it was about and, for a command, its command line.
    static func of(_ step: AgentToolStep) -> AgentActivity {
        var input: [String: Any] = [:]
        switch ToolCategory.of(tool: step.name) {
        case .command:
            input["command"] = step.command ?? step.summary
            if step.command != nil, step.summary != step.command { input["description"] = step.summary }
        case .edit, .read:
            input["file_path"] = step.summary
        default:
            input["description"] = step.summary
        }
        if step.tasks != nil { return .planning }
        return of(tool: step.name, input: input, fallback: step.summary)
    }
}

enum TranscriptPresentation {
    /// The rows of a conversation. `working`: the agent works on the last turn, which shows its progress. Once it is done,
    /// the last turn folds into "Worked for …" over its answer like every earlier one.
    static func rows(_ messages: [AgentChatMessage], working: Bool) -> [TranscriptRow] {
        // Thinking the agent kept to itself says nothing in a timeline that already shows the work.
        let turns = split(messages.filter { !($0.isThinking && $0.text.isEmpty) })
        var rows: [TranscriptRow] = []
        for (index, turn) in turns.enumerated() {
            let isLast = index == turns.count - 1
            rows += present(turn, open: working && isLast)
        }
        return rows
    }

    /// A turn starts at each message of yours; anything before the first one is a turn of its own. A message you sent
    /// while the agent worked steers the turn it ran in rather than starting one.
    static func split(_ messages: [AgentChatMessage]) -> [[AgentChatMessage]] {
        var turns: [[AgentChatMessage]] = []
        for message in messages {
            if message.fromUser && !message.queued || turns.isEmpty { turns.append([message]) } else { turns[turns.count - 1].append(message) }
        }
        return turns
    }

    /// How long a turn took: from your message to the last thing that came in.
    static func seconds(_ turn: [AgentChatMessage]) -> Double? {
        guard let start = turn.first?.date else { return nil }
        return seconds(from: start, turn)
    }

    /// From `start` to the last thing in `messages` that came in.
    private static func seconds(from start: Date?, _ messages: [AgentChatMessage]) -> Double? {
        guard let start, let end = messages.compactMap({ $0.updated ?? $0.date }).max(), end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func present(_ turn: [AgentChatMessage], open: Bool) -> [TranscriptRow] {
        guard turn.first != nil else { return [] }
        if open { return presentOpen(turn) }
        // A turn you stopped stays open, so it shows how far it got, and says at its end for how long it ran, so it does
        // not read as if the agent finished.
        guard let stop = turn.last(where: \.interrupted) else { return presentClosed(turn) }
        let answer = turn.last { $0.kind == .assistant }?.id
        return group(turn, finalID: answer) + [.interrupted(id: stop.id, seconds: turn.first?.fromUser == true ? seconds(turn) : nil)]
    }

    /// A finished turn: your message, "Worked for …" over its work, and its final answer; the rest a click away. Each
    /// message you sent while it ran stays in sight with "Continued for …" over the work that came after it. A
    /// compaction, an error or a usage limit stays in sight too.
    private static func presentClosed(_ turn: [AgentChatMessage]) -> [TranscriptRow] {
        guard let first = turn.first else { return [] }
        let answer = turn.last { $0.kind == .assistant }
        guard first.fromUser, let answer else { return group(turn, finalID: answer?.id) }
        // The work between your messages: the first part after your prompt, then one after each message you sent.
        var segments: [(steer: AgentChatMessage?, messages: [AgentChatMessage])] = [(nil, [])]
        for message in turn.dropFirst() {
            if message.fromUser { segments.append((message, [])) } else { segments[segments.count - 1].messages.append(message) }
        }
        var rows: [TranscriptRow] = [.user(first)]
        for (index, segment) in segments.enumerated() {
            if let steer = segment.steer { rows.append(.user(steer)) }
            let work = segment.messages.filter { $0.id != answer.id && !$0.isNotice }
            if let firstWork = work.first {
                let inner = group(work, finalID: nil)
                rows.append(index == 0 ? .fold(id: firstWork.id, seconds: seconds(turn), rows: inner)
                                       : .continued(id: firstWork.id, seconds: seconds(from: segment.steer?.date, segment.messages), rows: inner))
            }
            for message in segment.messages where message.id == answer.id || message.isNotice {
                rows.append(message.isNotice ? .notice(message) : .assistant(message, isFinal: true))
            }
        }
        return rows
    }

    /// The turn that runs: how long it has been going right under your message, the work so far, and at the end the step
    /// that runs now (taken out of its group) with what the agent thought right before it, or what it thinks now.
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
        // The thought the work ends with goes with the live line: why the agent runs this step, or what it thinks now.
        var thought: AgentChatMessage?
        if let last = work.last, last.isThinking, !last.text.isEmpty {
            thought = last
            work.removeLast()
        }
        rows += group(work, finalID: nil)
        rows.append(.live(current, thought: thought))
        return rows
    }

    /// Steps in a row become one row, also across the agent's thinking between them: a thought that is followed by more
    /// steps is part of that work, not a line of its own, so a busy turn reads as one list instead of a zigzag. A thought
    /// that opens the work or ends it stands on its own, as do answers and notices.
    static func group(_ messages: [AgentChatMessage], finalID: String?) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var steps: [AgentToolStep] = []
        var groupID = ""
        // Thinking after the steps so far: moved into the group when more steps follow, else shown after it.
        var pending: [AgentChatMessage] = []
        // Absorbed thoughts stay a click away inside the group, by the step they came before.
        var thoughts: [String: [AgentChatMessage]] = [:]
        func flush() {
            defer { thoughts = [:] }
            if steps.count == 1 { rows.append(.step(steps[0])) }
            if steps.count > 1 { rows.append(.group(id: groupID, steps: steps, thoughts: thoughts)) }
            steps = []
            rows += pending.map { TranscriptRow.thinking($0) }
            pending = []
        }
        for message in messages {
            switch message.kind {
            case .tools:
                if steps.isEmpty { groupID = message.id }
                if let first = message.steps.first, !pending.isEmpty { thoughts[first.id, default: []] += pending }
                pending = []
                steps += message.steps
            case .user:
                flush()
                rows.append(.user(message))
            case .assistant:
                flush()
                rows.append(.assistant(message, isFinal: message.id == finalID))
            case .notice:
                flush()
                rows.append(.notice(message))
            case .thinking:
                if steps.isEmpty { rows.append(.thinking(message)) } else { pending.append(message) }
            }
        }
        flush()
        return rows
    }

    /// What the agent does now in the turn that runs: the step that runs, else what it did last.
    static func activity(_ messages: [AgentChatMessage]) -> AgentActivity {
        let turn = split(messages.filter { !($0.isThinking && $0.text.isEmpty) }).last ?? []
        guard let last = turn.last else { return .starting }
        switch last.kind {
        case .user:
            return .starting
        case .assistant:
            return .writing
        case .thinking:
            return .thinking(headline(last.text))
        case .tools:
            guard let step = last.steps.last else { return .reviewing }
            if step.state == .running { return AgentActivity.of(step) }
            return step.state == .failed ? .recovering : .reviewing
        case .notice:
            if case .compacted = last.notice { return .reviewing }
            return .recovering
        }
    }

    /// Every step inside rows, in order: what a fold holds.
    static func steps(_ rows: [TranscriptRow]) -> [AgentToolStep] {
        rows.flatMap { row -> [AgentToolStep] in
            switch row {
            case .step(let step): return [step]
            case .group(_, let steps, _): return steps
            case .fold(_, _, let inner), .continued(_, _, let inner): return self.steps(inner)
            case .live(let step, _): return step.map { [$0] } ?? []
            default: return []
            }
        }
    }

    /// The agent's latest task list in the conversation, nil when it kept none. A list an earlier turn finished is
    /// done with: only the turn that set it, or a list still open, shows (all of them with `includeFinished`).
    static func tasks(_ messages: [AgentChatMessage], includeFinished: Bool = false) -> [RunTaskStep]? {
        let turns = split(messages)
        for (index, turn) in turns.enumerated().reversed() {
            for message in turn.reversed() where message.isTools {
                guard let tasks = message.steps.last(where: { $0.tasks != nil })?.tasks else { continue }
                if tasks.isEmpty || !includeFinished && index != turns.count - 1 && RunTasks.isFinished(tasks) { return nil }
                return tasks
            }
        }
        return nil
    }

    /// The whole command line of a step, for when its line does not show it all: the line shows a description instead,
    /// or only the start of a long or multi-line command. Nil when the line says it all (or the step ran no command).
    static func fullCommand(_ step: AgentToolStep) -> String? {
        guard let command = step.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
              command != step.summary || command.count > 60 || command.contains("\n") else { return nil }
        return command
    }

    /// A thought on one line: its first bold heading or its first sentence, as reasoning shows in the work log.
    static func headline(_ text: String) -> String {
        TimelinePresentation.headline(text)
    }

    /// Where each of your messages sits in the conversation, from 0 (the top) to 1 (the end): the marks on the rail
    /// beside it, which take the place of a scroll bar. The conversation lays out only what is on screen, so the place
    /// is an estimate from how long each row reads; a message folded into "Worked for …" marks its fold.
    static func promptMarks(_ rows: [TranscriptRow]) -> [PromptMark] {
        let weights = rows.map(weight)
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var marks: [PromptMark] = []
        var above = 0.0
        for (row, weight) in zip(rows, weights) {
            let messages: [AgentChatMessage]
            switch row {
            case .user(let message): messages = [message]
            case .fold(_, _, let inner):
                messages = inner.compactMap { row -> AgentChatMessage? in
                    if case .user(let message) = row { return message }
                    return nil
                }
            default: messages = []
            }
            for message in messages {
                marks.append(PromptMark(id: message.id, row: row.id, position: above / total, text: message.text))
            }
            above += weight
        }
        return marks
    }

    /// Roughly how many lines a row takes: enough to tell a long answer from a one-line step.
    private static func weight(_ row: TranscriptRow) -> Double {
        func lines(_ text: String, width: Int) -> Double {
            Double(text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + width - 1) / width) })
        }
        switch row {
        // A long message folds to its first eight lines; the space above it starts the turn.
        case .user(let message): return 3 + min(8, lines(message.text, width: 60))
        case .assistant(let message, _): return 1 + lines(message.text, width: 90)
        default: return 1.5
        }
    }
}

/// One of your messages on the rail beside the conversation. `row`: the row to scroll to, which is the message itself or
/// the fold it is in.
struct PromptMark: Identifiable, Equatable {
    let id: String
    let row: String
    let position: Double
    let text: String
}

extension SessionOutputs {
    /// The outputs of a conversation read from an agent's transcript: its latest task list, the plans it proposed and
    /// the files worth seeing it wrote. A transcript keeps no time for each step, so the time of its message stands in.
    static func collect(_ messages: [AgentChatMessage], directory: String) -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        var files: [String: Int] = [:]
        let fallback = Date(timeIntervalSince1970: 0)
        for (index, message) in messages.enumerated() where message.isTools {
            // Steps keep their order within a message; a fraction of a second apart keeps it in the sort.
            for (offset, step) in message.steps.enumerated() {
                let date = (message.updated ?? message.date ?? fallback.addingTimeInterval(Double(index)))
                    .addingTimeInterval(Double(offset) / 1000)
                if let plan = step.plan, !plan.isEmpty {
                    outputs.append(SessionOutput(id: "plan:" + step.id, kind: .plan(plan), title: PlanPreview.title(from: plan) ?? "",
                                                 path: nil, date: date))
                }
                guard let raw = step.path, step.state != .failed else { continue }
                let path = resolve(raw, in: directory)
                guard let kind = kind(path: path) else { continue }
                let output = SessionOutput(id: "file:" + path, kind: kind, title: URL(fileURLWithPath: path).lastPathComponent,
                                           path: path, date: date)
                if let at = files[path] { outputs[at] = output } else { files[path] = outputs.count; outputs.append(output) }
            }
        }
        if let tasks = TranscriptPresentation.tasks(messages, includeFinished: true) {
            let date = messages.last(where: { $0.steps.contains { $0.tasks != nil } }).flatMap { $0.updated ?? $0.date } ?? fallback
            outputs.append(SessionOutput(id: "tasks", kind: .tasks(tasks), title: "", path: nil, date: date))
        }
        return outputs.sorted { $0.date > $1.date }
    }
}
