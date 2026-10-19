import Foundation

// Forking a session and switching it to another agent. The new agent
// cannot read the old agent's conversation, so what happened is handed over as a short, readable summary at the start of
// its first turn. It is built from the timeline without a model, so it is deterministic, bounded, and visible to you in
// the timeline: nothing is slipped into a prompt unseen. A handoff is a summary, not native context parity.
// Foundation only, so tests can use it independently.

/// What a fork or a switch lets the new agent start from.
enum ContextTransfer {
    enum Strategy: Equatable, Sendable {
        /// The agent's own conversation is continued: no summary needed.
        case native
        /// A summary of everything.
        case fullSummary
        /// A summary of what happened since the agent last took part (it resumes its own earlier conversation).
        case delta(sinceEvent: Int)
    }

    /// Switching a session to another agent: resume its own earlier conversation and summarise only what it missed, or
    /// start fresh with a summary of everything.
    static func forSwitch(hasNativeSession: Bool, cursor: Int?) -> Strategy {
        if hasNativeSession, let cursor, cursor >= 0 { return .delta(sinceEvent: cursor) }
        return .fullSummary
    }

    /// Forking a session: the same agent forks its own conversation when it can; anything else gets a summary.
    static func forFork(nativeFork: Bool, hasNativeSession: Bool) -> Strategy {
        nativeFork && hasNativeSession ? .native : .fullSummary
    }
}

enum ContextHandoff {
    /// The most the summary may cost the new agent, in tokens.
    static let tokenBudget = 16_000
    /// What one item may say: a message, or a tool call / file change.
    static let messageLimit = 600
    static let lineLimit = 160

    struct Rendered: Equatable, Sendable {
        var text: String
        /// Items in the summary, and older items that no longer fit.
        var included: Int
        var omitted: Int
        /// The timeline length this summary covers: the next delta starts here.
        var coveredEvents: Int
    }

    static func approxTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    /// The summary of `events` from index `start` on, or nil when there is nothing to tell. The newest items are kept when
    /// the budget runs out; the summary says how many older ones are left out.
    static func render(events: [RunEvent], from start: Int = 0, source: String, budget: Int = tokenBudget, header customHeader: String? = nil,
                       footer customFooter: String? = nil) -> Rendered? {
        let slice = events.indices.contains(start) ? Array(events[start...]) : []
        let lines = slice.compactMap(line)
        guard !lines.isEmpty else { return nil }

        let header = customHeader ?? "[Context handoff] This session continues work that \(source) did before you. What happened (oldest first; you cannot see that conversation):"
        var kept: [String] = []
        var used = approxTokens(header) + 40
        for line in lines.reversed() {
            let cost = approxTokens(line) + 1
            if used + cost > budget, !kept.isEmpty { break }
            kept.append(line)
            used += cost
        }
        kept.reverse()
        let omitted = lines.count - kept.count
        var parts = [header]
        if omitted > 0 { parts.append("(\(omitted) earlier item\(omitted == 1 ? "" : "s") left out)") }
        parts += kept
        parts.append(customFooter ?? "[End of handoff] Continue from here. Check the files yourself before relying on any of this.")
        return Rendered(text: parts.joined(separator: "\n"), included: kept.count, omitted: omitted, coveredEvents: events.count)
    }

    /// One timeline entry as a line of the summary; nil for entries that say nothing about the work.
    static func line(_ event: RunEvent) -> String? {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.kind {
        case .user:
            return text.isEmpty ? nil : "- User: " + clip(text, messageLimit)
        case .assistant:
            return text.isEmpty ? nil : "- Agent: " + clip(text, messageLimit)
        case .tool:
            guard !text.isEmpty else { return nil }
            return "- Ran: " + clip(text, lineLimit) + (event.state == .failed ? " (failed)" : "")
        case .fileChange:
            let path = text.isEmpty ? (event.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : text
            guard !path.isEmpty else { return nil }
            return "- Changed: " + clip(path, lineLimit) + (event.tool.map { " (\($0))" } ?? "")
        case .error:
            return text.isEmpty ? nil : "- Error: " + clip(text, lineLimit)
        case .thinking, .approval, .system, .result:
            return nil
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// The first prompt of the new agent: the summary, then what you typed.
    static func compose(handoff: String?, message: String) -> String {
        guard let handoff, !handoff.isEmpty else { return message }
        return handoff + "\n\n" + message
    }
}

/// Where a session came from.
struct RunLineage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case fork }
    var kind: Kind
    var parentID: UUID
    /// How much of the parent's timeline the fork starts from.
    var atEvent: Int
}

/// One agent with one account is one instance: its conversation is its own.
/// Two accounts of one agent never share a session.
enum ProviderInstance {
    static func key(_ provider: RunProvider, _ profileID: String) -> String { provider.rawValue + "|" + profileID }
}

/// What changing the agent, account or model of a running session means.
enum SelectionTransition: Equatable, Sendable {
    /// Nothing changes.
    case reuse
    /// Same conversation; the new model or account label counts from the next turn.
    case applyOnNextTurn
    /// Another agent or account has its own conversation: the session moves there with a summary of what happened.
    case createWithHandoff
    case reject(String)

    static func decide(currentProvider: RunProvider, currentProfile: String, currentModel: String,
                       targetProvider: RunProvider, targetProfile: String, targetModel: String,
                       sameAccountHome: Bool, available: Bool) -> SelectionTransition {
        guard available else { return .reject("unavailable") }
        if currentProvider != targetProvider { return .createWithHandoff }
        if currentProfile != targetProfile { return sameAccountHome ? .applyOnNextTurn : .createWithHandoff }
        return currentModel == targetModel ? .reuse : .applyOnNextTurn
    }
}
