import Foundation

// One way from an agent's output to a session's timeline, the same for every coding agent. Each provider speaks its own
// dialect (Claude Code's stream-json, Codex exec and app-server, Gemini CLI, the ACP agents); its handler only translates
// that into the few signals below, and `AgentTimeline` writes them as RunEvents by one set of rules:
//
// - One answer and one thought stream at a time. Starting one closes the other, and a tool call closes both, so the
//   timeline never shows two blocks "writing" at once and the live line always names what the agent does now.
// - A provider's item id keeps blocks apart: a delta for another item starts a new block, the complete copy of an item
//   replaces what streamed for it.
// - A tool call is one row from start to end, found by its call id: it starts, streams output, settles. A call that is
//   reported twice updates its row, and a call that is only reported when it finished gets a row that is already done.
//
// Foundation only, so the tests drive it without an agent.

/// A tool call as every provider reports it.
struct AgentToolCall: Equatable, Sendable {
    var id: String
    /// The tool's name, which the timeline groups by (see ToolCategory): "Bash", "shell", "edit", "web_search"…
    var name: String
    /// The row's one line: "Bash · npm test".
    var title: String
    /// The input as JSON, or the command line.
    var detail: String? = nil
    /// The input as received, for what it changed (see ToolSummary.fileChanges).
    var input: JSONBox? = nil
    var output: String? = nil
    var state: RunEvent.State = .running
    /// A subagent's call, shown under the call that started it.
    var nested = false
    /// Files the call changes, when the provider names them (ACP).
    var paths: [String] = []
}

/// What a provider's handler tells the timeline.
enum AgentSignal: Equatable, Sendable {
    /// More of the answer. `item` is the provider's id of the message (nil: the one being written).
    case textDelta(String, item: String? = nil)
    /// A whole answer block: replaces what streamed for the same item.
    case text(String, item: String? = nil)
    /// More of a thought.
    case thinkingDelta(String, item: String? = nil)
    /// A whole thought: replaces what streamed for the same item.
    case thinking(String, item: String? = nil)
    /// Claude Code opens and closes its thinking blocks; the complete copy of a closed block (`thinking`) comes later.
    case thinkingStarted
    case thinkingEnded
    /// A call starts (or is reported again: then it updates its row).
    case toolStarted(AgentToolCall)
    /// News about a call: a new title, output (added to what came, or in its place), a new state. Also finds a call of
    /// an earlier turn (work left running in the background); a call nobody knows is left alone.
    case toolUpdated(id: String, title: String? = nil, output: String? = nil, appending: Bool = false,
                     state: RunEvent.State? = nil, paths: [String] = [], input: JSONBox? = nil)
    /// A call settles: updated when it is known (this turn or before), else added as it ended.
    case toolFinished(AgentToolCall)
    /// The agent stops writing and thinking for now: before an approval, a plan, the end of a turn.
    case pause
}

/// What the session does next because of a signal, outside the timeline.
enum AgentTimelineEffect: Equatable, Sendable {
    /// A new call: counts toward the session's recap.
    case toolStarted(name: String)
    /// A call finished well: what it changed is recorded.
    case toolSucceeded(name: String, input: JSONBox?, paths: [String])
}

/// Where the timeline writes: the session's events.
protocol RunTimelineSink {
    func append(_ event: RunEvent)
    func mutate(_ eventID: UUID, _ change: (inout RunEvent) -> Void)
    /// The latest event of a tool call with this id, also of an earlier turn.
    func eventID(callID: String) -> UUID?
}

/// The open blocks and calls of one turn.
struct AgentTimeline: Equatable, Sendable {
    private struct Live: Equatable, Sendable {
        var eventID: UUID
        var item: String?
    }

    private struct Call: Equatable, Sendable {
        var eventID: UUID
        var name: String
        var input: JSONBox?
        var paths: [String]
        var state: RunEvent.State
    }

    private var liveText: Live?
    private var liveThought: Live?
    /// Claude Code: a thinking block is open, and the closed blocks waiting for their complete copy (nil: it streamed no text).
    private var thinkingOpen = false
    private var awaitingCopies: [UUID?] = []
    private var calls: [String: Call] = [:]
    /// The last finished answer, which a failed turn's result may repeat word for word.
    private(set) var lastTextID: UUID?

    /// The event of a call of this turn.
    func eventID(forCall id: String) -> UUID? { calls[id]?.eventID }

    /// The events of this turn's calls that still run.
    var runningCalls: [UUID] { calls.values.filter { $0.state == .running }.map(\.eventID) }

    /// A thought or an answer is being written.
    var isStreaming: Bool { liveText != nil || liveThought != nil }

    /// Claude Code's steering message cut the turn short: a block it cut off gets no complete copy.
    mutating func forgetPendingCopies() { awaitingCopies.removeAll() }

    @discardableResult
    mutating func apply(_ signal: AgentSignal, to sink: some RunTimelineSink) -> [AgentTimelineEffect] {
        switch signal {
        case .textDelta(let text, let item):
            closeThought(sink)
            guard !text.isEmpty else { return [] }
            if let live = liveText, live.item == item {
                sink.mutate(live.eventID) { $0.text += text }
            } else {
                closeText(sink)
                let event = RunEvent(kind: .assistant, text: text, state: .running)
                liveText = Live(eventID: event.id, item: item)
                sink.append(event)
            }
        case .text(let text, let item):
            closeThought(sink)
            if let live = liveText, live.item == item {
                sink.mutate(live.eventID) { $0.text = text; $0.state = .done }
                liveText = nil
                lastTextID = live.eventID
            } else {
                closeText(sink)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                let event = RunEvent(kind: .assistant, text: text, state: .done)
                lastTextID = event.id
                sink.append(event)
            }
        case .thinkingStarted:
            closeText(sink)
            endThinkingBlock(sink)
            thinkingOpen = true
        case .thinkingEnded:
            endThinkingBlock(sink)
        case .thinkingDelta(let text, let item):
            closeText(sink)
            guard !text.isEmpty else { return [] }
            if let live = liveThought, live.item == item {
                sink.mutate(live.eventID) { $0.text += text }
            } else {
                closeThought(sink)
                let event = RunEvent(kind: .thinking, text: text, state: .running)
                liveThought = Live(eventID: event.id, item: item)
                sink.append(event)
            }
        case .thinking(let text, let item):
            closeText(sink)
            endThinkingBlock(sink)
            // The complete copy of a block that streamed: keep the streamed text unless this one has more to say.
            if !awaitingCopies.isEmpty {
                if let streamed = awaitingCopies.removeFirst(), !text.isEmpty { sink.mutate(streamed) { $0.text = text } }
                return []
            }
            if let live = liveThought, live.item == item {
                sink.mutate(live.eventID) { event in
                    if !text.isEmpty { event.text = text }
                    event.state = .done
                }
                liveThought = nil
            } else {
                closeThought(sink)
                if !text.isEmpty { sink.append(RunEvent(kind: .thinking, text: text, state: .done)) }
            }
        case .toolStarted(let call):
            pause(sink)
            if calls[call.id] != nil { return update(call, sink) }
            return add(call, sink)
        case .toolUpdated(let callID, let title, let output, let appending, let state, let paths, let input):
            // Input that arrives later (what an ACP edit changed) replaces the row's: it is what the call did.
            let detail = input.map { ToolSummary.json($0.object) }
            if calls[callID] == nil, let earlier = sink.eventID(callID: callID) {
                // A call of an earlier turn: its row changes, this turn does not take it over.
                sink.mutate(earlier) { event in
                    Self.change(&event, title: title, output: output, appending: appending, state: state)
                    if let detail { event.detail = detail }
                }
                return state == .done && !paths.isEmpty ? [.toolSucceeded(name: "", input: nil, paths: paths)] : []
            }
            guard var known = calls[callID] else { return [] }
            sink.mutate(known.eventID) { event in
                Self.change(&event, title: title, output: output, appending: appending, state: state)
                if let detail { event.detail = detail }
            }
            if let input { known.input = input }
            known.paths += paths.filter { !known.paths.contains($0) }
            return settle(&known, callID, state)
        case .toolFinished(let call):
            pause(sink)
            if calls[call.id] != nil { return update(call, sink) }
            if let earlier = sink.eventID(callID: call.id) {
                sink.mutate(earlier) { event in
                    Self.change(&event, title: nil, output: call.output, appending: false, state: call.state)
                }
                return []
            }
            return add(call, sink)
        case .pause:
            pause(sink)
        }
        return []
    }

    // MARK: Calls

    private mutating func add(_ call: AgentToolCall, _ sink: some RunTimelineSink) -> [AgentTimelineEffect] {
        let event = RunEvent(kind: .tool, text: call.nested ? "↳ " + call.title : call.title, tool: call.name, callID: call.id,
                             detail: call.detail, output: call.output.flatMap { $0.isEmpty ? nil : RunEvent.clip($0) },
                             state: call.state)
        var known = Call(eventID: event.id, name: call.name, input: call.input, paths: call.paths, state: .running)
        sink.append(event)
        return [.toolStarted(name: call.name)] + settle(&known, call.id, call.state)
    }

    private mutating func update(_ call: AgentToolCall, _ sink: some RunTimelineSink) -> [AgentTimelineEffect] {
        guard var known = calls[call.id] else { return [] }
        sink.mutate(known.eventID) { event in
            Self.change(&event, title: call.title.isEmpty ? nil : (call.nested ? "↳ " + call.title : call.title),
                        output: call.output, appending: false, state: call.state)
            if event.detail == nil { event.detail = call.detail }
        }
        if known.input == nil { known.input = call.input }
        known.paths += call.paths.filter { !known.paths.contains($0) }
        return settle(&known, call.id, call.state)
    }

    /// Remembers the call's new state; a call that just finished well says so once.
    private mutating func settle(_ known: inout Call, _ callID: String, _ state: RunEvent.State?) -> [AgentTimelineEffect] {
        let wasRunning = known.state == .running
        if let state { known.state = state }
        calls[callID] = known
        guard wasRunning, known.state == .done else { return [] }
        return [.toolSucceeded(name: known.name, input: known.input, paths: known.paths)]
    }

    private static func change(_ event: inout RunEvent, title: String?, output: String?, appending: Bool, state: RunEvent.State?) {
        if let title, !title.isEmpty { event.text = title }
        if let output, !output.isEmpty || appending {
            event.output = RunEvent.clip(appending ? (event.output ?? "") + output : output)
        }
        if let state { event.state = state }
    }

    // MARK: Streams

    private mutating func pause(_ sink: some RunTimelineSink) {
        closeText(sink)
        endThinkingBlock(sink)
        closeThought(sink)
    }

    private mutating func closeText(_ sink: some RunTimelineSink) {
        guard let live = liveText else { return }
        sink.mutate(live.eventID) { $0.state = .done }
        liveText = nil
        lastTextID = live.eventID
    }

    private mutating func closeThought(_ sink: some RunTimelineSink) {
        guard let live = liveThought else { return }
        sink.mutate(live.eventID) { $0.state = .done }
        liveThought = nil
    }

    /// Ends Claude Code's open thinking block; it then waits for its complete copy (see `.thinking`).
    private mutating func endThinkingBlock(_ sink: some RunTimelineSink) {
        guard thinkingOpen else { return }
        thinkingOpen = false
        let live = liveThought?.eventID
        closeThought(sink)
        awaitingCopies.append(live)
    }
}
