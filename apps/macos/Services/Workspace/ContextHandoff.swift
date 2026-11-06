import Foundation

// Forking a session and switching it to another agent. The new agent
// cannot read the old agent's conversation, so what happened is handed over at the start of its first turn: a budgeted
// selection of the timeline, not a summary a model wrote. Messages keep their own words; commands and changed files take a
// line. It is deterministic, bounded, and visible to you in the timeline: nothing is slipped into a prompt unseen.
// What did not fit stays readable through `session_read` for an agent with Nook's tools.
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
    /// What one message may say, in its own words; a longer one is cut with a note where the rest is.
    static let messageLimit = 6_000
    /// What one tool call or file change may say.
    static let lineLimit = 160
    /// How many events `session_read` reads back in one go (`before_event`).
    static let pageEvents = 300

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
    /// `session` is where the rest can be read (`session_read`); nil for an agent without Nook's tools.
    static func render(events: [RunEvent], from start: Int = 0, source: String, budget: Int = tokenBudget, header customHeader: String? = nil,
                       footer customFooter: String? = nil, session: UUID? = nil) -> Rendered? {
        let slice = events.indices.contains(start) ? Array(events[start...]) : []
        let lines = slice.compactMap(line)
        guard !lines.isEmpty else { return nil }

        let header = customHeader ?? "[Context handoff] This session continues work that \(source) did before you. What happened (oldest first; you cannot see that conversation):"
        // The request that started it all stays, whatever else has to go.
        let original = slice.first { $0.kind == .user }.flatMap(line)
        let originalIndex = original.flatMap { lines.firstIndex(of: $0) }
        var chosen: [Int] = originalIndex.map { [$0] } ?? []
        var used = approxTokens(header) + 40 + (original.map { approxTokens($0) + 1 } ?? 0)
        for (index, line) in lines.enumerated().reversed() where index != originalIndex {
            let cost = approxTokens(line) + 1
            if used + cost > budget, !chosen.isEmpty { break }
            chosen.append(index)
            used += cost
        }
        chosen.sort()
        let included = chosen.count
        let omitted = lines.count - included
        var parts = [header]
        if omitted > 0 {
            let more = session.map { " Read them with session_read, session \($0.uuidString), before_event \(max(0, events.count)), if you need them" } ?? ""
            parts.append("(\(omitted) earlier item\(omitted == 1 ? "" : "s") left out.\(more))")
        }
        // In their own order, with a mark where something went.
        for (position, index) in chosen.enumerated() {
            if position > 0, index != chosen[position - 1] + 1 { parts.append("(…)") }
            parts.append(lines[index])
        }
        parts.append(customFooter ?? "[End of handoff] Continue from here. Check the files yourself before relying on any of this.")
        return Rendered(text: parts.joined(separator: "\n"), included: included, omitted: omitted, coveredEvents: events.count)
    }

    /// One timeline entry as a line of the summary; nil for entries that say nothing about the work.
    static func line(_ event: RunEvent) -> String? {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.kind {
        case .user:
            return text.isEmpty ? nil : "- User: " + whole(text)
        case .assistant:
            return text.isEmpty ? nil : "- Agent: " + whole(text)
        case .tool:
            guard !text.isEmpty else { return nil }
            return "- Ran: " + clip(text, lineLimit) + (event.state == .failed ? " (failed)" : "")
        case .fileChange:
            let path = text.isEmpty ? (event.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : text
            guard !path.isEmpty else { return nil }
            return "- Changed: " + clip(path, lineLimit) + (event.tool.map { " (\($0))" } ?? "")
        case .error:
            return text.isEmpty ? nil : "- Error: " + clip(text, lineLimit)
        case .page:
            // The page itself stays out: only that the agent showed one.
            return "- Showed a page: " + clip(text.isEmpty ? "Page" : text, lineLimit)
        case .thinking, .approval, .system, .result:
            return nil
        }
    }

    /// A message in its own words, line breaks included.
    private static func whole(_ text: String) -> String {
        text.count > messageLimit ? String(text.prefix(messageLimit)) + "… (cut here)" : text
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
    /// `fork`: a copy of the parent's conversation (/fork). `comparison`: started from the same prompt as the parent with
    /// another model (`ModelComparison`); the parent is the group's first session. `side`: a side chat (/btw, /side)
    /// that starts from the parent's last finished turn while the parent keeps working (see `SideChat`).
    enum Kind: String, Codable, Sendable { case fork, comparison, side }
    var kind: Kind
    var parentID: UUID
    /// How much of the parent's timeline the fork starts from.
    var atEvent: Int

    /// The line in the session's header that leads to the parent ("Forked from %@", "Same prompt as %@").
    var labelKey: String {
        switch kind {
        case .fork: return "lineage.forkedFrom"
        case .comparison: return "lineage.samePromptAs"
        case .side: return "lineage.sideOf"
        }
    }
    /// The mark of such a session in the Agents list and its header.
    var symbol: String {
        switch kind {
        case .fork: return "arrow.triangle.branch"
        case .comparison: return "square.stack.3d.up"
        case .side: return "bubble.left.and.bubble.right"
        }
    }
    /// Its result can go back to the parent ("Bring back", `mergeBack`): a fork and a side chat; a comparison runs the
    /// same prompt next to it instead.
    var bringsBack: Bool {
        switch kind {
        case .fork, .side: return true
        case .comparison: return false
        }
    }
}

/// Ending a session's agent process so the next message starts it again (new skills, plugins or MCP servers are
/// picked up), in the same conversation where the agent can resume it.
enum AgentRestart {
    enum Plan: Equatable, Sendable {
        /// No conversation yet: the next message starts one, as it would anyway.
        case fresh
        /// The next message resumes the agent's own conversation (Claude Code `--resume`, Codex `thread/resume`, ACP
        /// `session/load` or `session/resume`).
        case resume
        /// The agent cannot take its conversation up again: the next message starts a new one from a summary of the
        /// timeline (`ContextHandoff`).
        case summary
    }

    /// `canResume`: whether this agent can continue a conversation it no longer has open; nil when Nook does not know
    /// yet (an ACP agent says so only once it runs), and then it tries, as an idle session does after a restart of Nook.
    static func plan(hasConversation: Bool, canResume: Bool?) -> Plan {
        guard hasConversation else { return .fresh }
        return canResume == false ? .summary : .resume
    }

    /// Whether an agent can resume a conversation natively, as far as the agent alone says. ACP agents tell it in their
    /// `initialize` answer (`AcpSessionCapabilities.continues`), so they answer nil here.
    static func resumesNatively(_ provider: RunProvider) -> Bool? {
        switch provider {
        case .claude, .codex: return true
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp: return nil
        }
    }
}

/// A side chat: a question beside a session's work (`/btw`, `/side`), in a session of its own that starts from the
/// parent's last finished turn while the parent keeps running. It is listed with its parent, not as a session of its
/// own, its first turn always asks before it changes anything, and "Bring back" hands its result to the parent.
enum SideChat {
    static let commands = ["btw", "side"]

    /// The question after `/btw` or `/side` ("" for the command alone), or nil when the message is not a side chat.
    static func question(in message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard commands.contains(name.lowercased()) else { return nil }
        return body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How much of the parent's timeline the side chat starts from: all of it when the parent is idle; while a turn
    /// runs, what came before the message that started that turn (the turn is not finished, so it is left out).
    static func cutoff(events: [RunEvent], turnRunning: Bool) -> Int {
        guard turnRunning else { return events.count }
        return events.lastIndex { $0.kind == .user } ?? 0
    }

    enum Start: Equatable, Sendable {
        /// The agent copies its own conversation as it is (an idle parent: its last turn is finished).
        case nativeCopy
        /// The agent copies its own conversation up to the end of the last finished turn (Claude Code `--resume
        /// --resume-session-at --fork-session`), the parent still working on the next.
        case nativeCopyAt(session: String, head: String)
        /// A summary of the timeline up to the cutoff (`ContextHandoff.render`).
        case summary
    }

    /// How the side chat gets the parent's conversation. `lastFinished`: where the conversation stood after the last
    /// finished turn (the newest checkpoint's mark).
    static func start(provider: RunProvider, session: String?, turnRunning: Bool, lastFinished: ConversationMark?) -> Start {
        let capabilities = provider.capabilities
        guard capabilities.nativeFork, session != nil else { return .summary }
        if !turnRunning { return .nativeCopy }
        guard capabilities.canForkFromTurn, let mark = lastFinished, mark.provider == provider,
              let markSession = mark.session, let head = mark.head else { return .summary }
        return .nativeCopyAt(session: markSession, head: head)
    }

    /// The sessions the list shows: a side chat only together with its parent (nested under it), never on its own.
    static func listed(_ runs: [WorkspaceRun]) -> [WorkspaceRun] {
        let ids = Set(runs.map(\.id))
        return runs.filter { run in
            guard let lineage = run.lineage, lineage.kind == .side else { return true }
            return ids.contains(lineage.parentID)
        }
    }

    /// The side chats of a session, newest first.
    static func children(of parent: UUID, in runs: [WorkspaceRun]) -> [WorkspaceRun] {
        runs.filter { $0.lineage?.kind == .side && $0.lineage?.parentID == parent && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

extension WorkspaceRun {
    /// The session this one was forked from (/fork) or started next to (a model comparison); nil for one of its own.
    /// Stored as `lineage`, which older sessions simply do not have.
    var forkedFrom: UUID? { lineage?.parentID }
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
