import Foundation

/// A session Nook runs whose conversation went on outside Nook: in the agent's own app (the Claude desktop app), its
/// terminal, or a resumed copy. Without this the Nook session stopped at your message and showed none of the agent's
/// work or answers, while the agent's own app showed everything. The turns written there are taken over from the
/// agent's transcript as the same events a turn in Nook writes: your messages, the agent's thinking and answers, each
/// step with how it went, and the end of each turn, so it folds into "Worked for …" like any other.
///
/// Foundation only: the decisions are tested without a session.
enum TranscriptFollow {
    enum Change: Equatable {
        case append(RunEvent)
        /// The event with this id becomes `event` (its id and date stay).
        case update(UUID, RunEvent)
    }

    /// What to add to or change in a session's `events` so it shows `messages` (the conversation as its transcript
    /// reads now). Only what came after the last thing Nook itself ran is taken: the turns before are the session's own.
    /// Nothing when the transcript shares nothing with the session (it is not this conversation). `finished`: the agent
    /// is not working on the conversation outside Nook right now, so its last turn is over.
    static func changes(events: [RunEvent], messages: [AgentChatMessage], finished: Bool) -> [Change] {
        let own = events.filter { $0.source == nil }
        let ownTexts = Set(own.filter { $0.kind == .user || $0.kind == .assistant }.map { trimmed($0.text) })
        // The transcript joins answer blocks in a row into one message, where a turn in Nook wrote one event per block.
        let ownAnswers = own.filter { $0.kind == .assistant }.map { trimmed($0.text) }.filter { $0.count >= 12 }
        let ownCalls = Set(own.compactMap(\.callID))
        guard let anchor = messages.lastIndex(where: { message in
            switch message.kind {
            case .user:
                return ownTexts.contains(trimmed(message.text))
            case .assistant:
                let text = trimmed(message.text)
                return ownTexts.contains(text) || ownAnswers.contains { text.contains($0) }
            case .tools:
                return message.steps.contains { ownCalls.contains($0.id) }
            case .thinking, .notice:
                return false
            }
        }) else { return [] }

        var bySource: [String: RunEvent] = [:]
        var byCall: [String: RunEvent] = [:]
        for event in events {
            if let source = event.source { bySource[source] = event }
            if event.kind == .tool, let call = event.callID { byCall[call] = event }
        }
        var changes: [Change] = []
        // The turn being taken over: the message of yours it started with, when that came from outside Nook.
        var turn: [AgentChatMessage] = []
        func close(_ turn: [AgentChatMessage]) {
            guard let start = turn.first, start.kind == .user, bySource[resultKey(start)] == nil,
                  let end = turn.compactMap({ $0.updated ?? $0.date }).max() else { return }
            // The fold above it says how long the turn took (from the dates); the end itself says nothing.
            var result = RunEvent(kind: .result, text: "", state: .done, date: end)
            result.source = resultKey(start)
            changes.append(.append(result))
        }

        for message in messages[messages.index(after: anchor)...] {
            if message.kind == .user && !message.queued {
                // A turn ends where the next one starts; one already taken over has its end already.
                if bySource[key(message)] == nil { close(turn) }
                turn = [message]
            } else if !turn.isEmpty {
                turn.append(message)
            }
            if message.kind == .tools {
                for step in message.steps {
                    let event = toolEvent(step, date: message.date)
                    if let known = byCall[step.id] {
                        if known.state != event.state || known.output != event.output { changes.append(.update(known.id, event)) }
                    } else {
                        changes.append(.append(event))
                    }
                }
                continue
            }
            guard let event = event(message) else { continue }
            if let known = bySource[key(message)] {
                if known.text != event.text || known.kind != event.kind { changes.append(.update(known.id, event)) }
            } else {
                changes.append(.append(event))
            }
        }
        if finished { close(turn) }
        return changes
    }

    /// A message as the event a turn in Nook writes for it; nil for what a session does not show (thinking the agent
    /// kept to itself, a compaction).
    private static func event(_ message: AgentChatMessage) -> RunEvent? {
        let text = trimmed(message.text)
        var event: RunEvent
        switch message.kind {
        case .user:
            event = RunEvent(kind: .user, text: text, date: message.date ?? Date())
        case .assistant:
            event = RunEvent(kind: .assistant, text: text, state: .done, date: message.date ?? Date())
        case .thinking:
            guard !text.isEmpty else { return nil }
            event = RunEvent(kind: .thinking, text: text, state: .done, date: message.date ?? Date())
        case .notice:
            switch message.notice {
            case .error, .limit: event = RunEvent(kind: .error, text: text, date: message.date ?? Date())
            case .compacted, nil: return nil
            }
        case .tools:
            return nil
        }
        guard !event.text.isEmpty else { return nil }
        event.source = key(message)
        return event
    }

    /// A step as the tool call a turn in Nook shows: the same line, input and output.
    static func toolEvent(_ step: AgentToolStep, date: Date?) -> RunEvent {
        let input = step.input.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let title = input.map { ToolSummary.describe(tool: step.name, input: $0) }
            ?? (step.summary.isEmpty ? step.name : "\(step.name) · \(step.summary)")
        let state: RunEvent.State
        switch step.state {
        case .running: state = .running
        case .done: state = .done
        case .failed: state = .failed
        }
        var event = RunEvent(kind: .tool, text: title, tool: step.name, callID: step.id, detail: step.input ?? step.command,
                             output: (step.state == .failed ? step.error ?? step.output : step.output).map { RunEvent.clip($0) },
                             state: state, date: date ?? Date())
        event.source = "transcript-step:" + step.id
        return event
    }

    private static func key(_ message: AgentChatMessage) -> String { "transcript:" + message.id }
    private static func resultKey(_ message: AgentChatMessage) -> String { "transcript-end:" + message.id }
    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
