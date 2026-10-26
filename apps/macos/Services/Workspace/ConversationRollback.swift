import Foundation

// Going back to before a message rolls back the agent's own conversation together with the files: Codex drops the later
// turns from its thread (`thread/rollback`), Claude Code resumes a copy of its conversation at the last message that stays
// (`--resume <id> --resume-session-at <uuid> --fork-session`). Back to before the first message starts a new
// conversation. Everything here depends only on Foundation.

/// Where the agent's own conversation stood when a checkpoint was made.
struct ConversationMark: Codable, Equatable, Sendable {
    /// The agent's session or thread; nil: there was no conversation yet.
    var session: String?
    /// The agent that conversation belongs to.
    var provider: RunProvider? = nil
    /// Turns in that session so far (Codex counts them to roll back).
    var turns = 0
    /// Claude Code: the last entry of the conversation chain (a message uuid); nil when none was seen.
    var head: String? = nil
    /// Nook missed turns of this conversation (a turn over `codex exec`): its count cannot be trusted.
    var exact = true

    /// Before the first message of a new session.
    static let empty = ConversationMark(session: nil)
}

/// The conversation as Nook follows it live, kept on the session so a checkpoint can record where it stood.
struct ConversationLog: Codable, Equatable, Sendable {
    var session: String?
    var provider: RunProvider?
    /// Codex: the thread's turn ids in order (a turn without a known id counts in `turns` only).
    var turnIDs: [String] = []
    var turns = 0
    var head: String?
    var exact = true

    init(session: String? = nil, provider: RunProvider? = nil) {
        self.session = session
        self.provider = provider
    }

    /// The agent reported its session. Another thread (Codex) starts the count again; a copy of a Claude Code
    /// conversation (`--fork-session`) keeps what it copied.
    mutating func noteSession(_ session: String, provider: RunProvider, keepsHistory: Bool) {
        if let current = self.provider, current != provider {
            self = ConversationLog(session: session, provider: provider)
            return
        }
        self.provider = provider
        guard session != self.session else { return }
        if !keepsHistory, self.session != nil {
            turnIDs = []
            turns = 0
            head = nil
            exact = true
        }
        self.session = session
    }

    /// A turn started. Codex reports a turn id, sometimes twice (the `turn/start` reply and `turn/started`): counted once.
    mutating func startTurn(id: String? = nil) {
        if let id {
            guard !turnIDs.contains(id) else { return }
            turnIDs.append(id)
        }
        turns += 1
    }

    mutating func noteHead(_ uuid: String) { head = uuid }

    var mark: ConversationMark {
        ConversationMark(session: session, provider: provider, turns: turns, head: head, exact: exact)
    }

    /// After a rollback to `mark`: what is left of the conversation.
    mutating func rewind(to mark: ConversationMark) {
        let kept = max(0, min(mark.turns, turns))
        if turnIDs.count > kept { turnIDs = Array(turnIDs.prefix(kept)) }
        turns = kept
        head = mark.head
        if let session = mark.session { self.session = session }
    }
}

/// A rollback that waits for the next turn: the agent's conversation goes back right before that turn starts, so going
/// back needs no running agent.
struct PendingRollback: Codable, Equatable, Sendable {
    /// Codex: the thread, how many of its last turns go, and the first of them when its id is known (`thread/revert`).
    var threadID: String? = nil
    var numTurns = 0
    var beforeTurnID: String? = nil
    /// Claude Code: resume a copy of this conversation at this chain entry.
    var resumeSession: String? = nil
    var resumeAt: String? = nil

    var isCodex: Bool { threadID != nil }
}

enum ConversationRollback {
    enum Plan: Equatable, Sendable {
        /// The conversation already ends there.
        case nothing
        case codex(threadID: String, numTurns: Int, beforeTurnID: String?)
        case claudeResume(session: String, at: String)
        /// Back to before the first message: the next turn starts a new conversation.
        case fresh
        /// The conversation cannot follow (no mark, another agent or thread, turns Nook missed): files only.
        case unavailable
    }

    /// What it takes to bring the conversation back to `mark` (made with the checkpoint the files go back to).
    static func plan(provider: RunProvider, mark: ConversationMark?, log: ConversationLog?, currentSession: String?) -> Plan {
        guard provider.capabilities.canRollbackConversation, let mark else { return .unavailable }
        // Nothing yet at the mark: whatever came after goes, so a new conversation is exact.
        if mark.session == nil, mark.turns == 0 { return currentSession == nil ? .nothing : .fresh }
        guard mark.provider == provider, let session = mark.session else { return .unavailable }
        switch provider {
        case .codex:
            guard let log, log.exact, mark.exact, log.provider == provider, let thread = currentSession,
                  log.session == thread, session == thread else { return .unavailable }
            let dropped = log.turns - mark.turns
            guard dropped > 0 else { return dropped == 0 ? .nothing : .unavailable }
            let before = log.turnIDs.count == log.turns ? log.turnIDs[mark.turns] : nil
            return mark.turns == 0 ? .fresh : .codex(threadID: thread, numTurns: dropped, beforeTurnID: before)
        case .claude:
            if let log, log.provider == provider, log.session == session, log.head == mark.head { return .nothing }
            guard let head = mark.head else { return .unavailable }
            return .claudeResume(session: session, at: head)
        default:
            return .unavailable
        }
    }

    /// Adds a plan to a rollback that has not gone out yet. Codex still has every turn of the earlier one, so the counts add
    /// up and the earlier turn id wins; Claude Code's position is absolute, so the newest one replaces the old.
    static func merge(_ pending: PendingRollback?, with plan: Plan) -> PendingRollback? {
        switch plan {
        case .nothing, .unavailable:
            return pending
        case .codex(let thread, let numTurns, let before):
            var next = pending.flatMap { $0.threadID == thread ? $0 : nil } ?? PendingRollback(threadID: thread)
            next.numTurns += numTurns
            next.beforeTurnID = before
            return next
        case .claudeResume(let session, let at):
            return PendingRollback(resumeSession: session, resumeAt: at)
        case .fresh:
            // A new conversation replaces whatever was still waiting to go out.
            return nil
        }
    }

    /// The checkpoints that stay when the files go back to the one at `index`, and the refs of those that go.
    static func trim(_ checkpoints: [RunCheckpoint], keepingThrough index: Int) -> (kept: [RunCheckpoint], removedRefs: [String]) {
        guard index >= 0, index < checkpoints.count else { return (checkpoints, []) }
        return (Array(checkpoints.prefix(index + 1)), checkpoints.suffix(from: index + 1).map(\.ref))
    }

    /// Timeline entries that came after the point you went back to: the agent no longer remembers them.
    static func rolledBackIDs(_ events: [RunEvent], after date: Date) -> Set<UUID> {
        Set(events.filter { $0.date > date && $0.rolledBack != true }.map(\.id))
    }
}
