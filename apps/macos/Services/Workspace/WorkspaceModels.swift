import Foundation

// The workspace for coding agents: sessions that Nook launches and tracks directly (not in a terminal).
// Everything in this file depends only on Foundation so tests can use it independently.

/// Which agent runs a workspace session. Only agents with a genuine headless mode that Nook can track.
enum RunProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, opencode, cursor, grok, antigravity, pi, acp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        case .pi: return "Pi"
        // An ACP agent you added; its own name is the account's (see CustomAgents).
        case .acp: return "ACP"
        }
    }

    /// Runs over ACP (Agent Client Protocol).
    var usesACP: Bool {
        switch self {
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp: return true
        // Pi speaks its own JSON lines over stdio (`PiRPC`).
        case .claude, .codex, .pi: return false
        }
    }

    /// Capabilities supported by this agent in headless mode. The UI presents missing features as unavailable.
    var capabilities: ProviderCapabilities {
        switch self {
        case .claude:
            // `--resume-session-at` with `--fork-session` also forks from an earlier turn. "Auto" is `--permission-mode auto`.
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .auto, .bypass], steering: true, nativeFork: true,
                                        canRollbackConversation: true, canForkFromTurn: true, liveSettings: true,
                                        reportsPromptCacheLifetime: true, denyReason: .inResponse, speedTiers: true,
                                        ultracode: true)
        case .codex:
            // Over app-server Codex asks for approval, streams its answer and reports its context window. "Auto" routes its
            // approval requests to Codex's own reviewer (`approvalsReviewer: auto_review`).
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: false, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .auto, .bypass], steering: true, canRollbackConversation: true,
                                        speedTiers: true)
        case .gemini:
            // Over ACP Gemini asks Nook for permission; its headless fallback cannot (auto_edit or yolo there).
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: false, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], liveSettings: true)
        case .antigravity:
            // ACP, with its conversations on disk in ~/.gemini/antigravity. It restarts its agent session to switch models,
            // which ends a running prompt, so its settings wait for the next message.
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass])
        case .cursor:
            // ACP, with its conversations on disk in ~/.cursor (its ACP server has no session/list).
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], liveSettings: true)
        case .pi:
            // Pi's RPC mode (`PiRPC`): streamed text and thoughts, `abort`, a prompt sent mid-turn steers it, usage with cost
            // per message. Approvals come from the extension Nook loads into Pi (`PiExtension`), through Pi's blocking
            // tool_call hook and its confirm dialog; Pi has no plan mode and no reviewer of its own, so no "auto". Its
            // sessions are files it resumes with `--session`.
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: false,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], steering: true)
        case .opencode, .grok, .acp:
            // No "auto" for any ACP agent (Gemini CLI, Antigravity and Cursor above too): none offers a reviewer that approves
            // routine actions itself. Gemini CLI's modes are default/auto_edit/yolo/plan, Antigravity's the same, Cursor's
            // agent/plan/ask, OpenCode's build/plan, and Grok only has --always-approve; Nook does not guess what is risky.
            // ACP: permission requests, cancel, streamed messages and thoughts, usage updates with context and cost. Their
            // earlier sessions come from the agent itself (`session/list`).
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], pastSessions: .agent, liveSettings: true)
        }
    }

    /// The well-known names, used only when neither the agent nor the model manifest (ModelManifest) lists any. Empty
    /// means: agent default. Custom names can also be typed.
    var suggestedModels: [String] {
        switch self {
        case .claude: return ["", "sonnet", "opus", "haiku"]
        case .codex: return ["", "gpt-5-codex", "gpt-5"]
        case .gemini: return ["", "gemini-2.5-pro", "gemini-2.5-flash"]
        // These agents choose their model in their own settings; Nook passes a name only when you type one.
        // Pi lists its own models ("provider/model", `get_available_models`).
        case .opencode, .cursor, .grok, .antigravity, .pi, .acp: return [""]
        }
    }
}

struct ProviderCapabilities: Equatable, Sendable {
    var approvals: Bool
    var interrupt: Bool
    var streamingText: Bool
    var planMode: Bool
    var reportsCost: Bool
    var reportsContextWindow: Bool
    var reportsCacheTokens: Bool
    var policies: [PermissionPolicy]
    /// A message sent during a turn changes that turn (Codex `turn/steer`, Claude Code's priority message); otherwise it queues.
    var steering = false
    /// The agent can fork its own conversation (Claude Code's `--fork-session`); otherwise a fork starts from a summary.
    var nativeFork = false
    /// Going back to before a message also rolls back the agent's own conversation (Codex `thread/rollback` over
    /// app-server, Claude Code `--resume-session-at`); otherwise only the files go back and the agent keeps remembering.
    var canRollbackConversation = false
    /// The agent can fork its conversation at an earlier turn, not only at its end.
    var canForkFromTurn = false
    /// An approval or question the agent asked survives a restart of Nook (or of the agent). No agent Nook runs keeps
    /// them: the process that asked is gone, so a session cut off while waiting on you stays yours to pick up.
    var pendingRequestsSurviveRestart = false
    /// How reliably the agent says a turn is over (see `TurnEndSignal`).
    var turnEndSignal: TurnEndSignal = .strong
    /// Without native steering, a message sent during a turn can still change it: Nook interrupts the turn and sends the
    /// message as the next prompt. Needs `interrupt` and ordinary follow-up turns.
    var supportsSteeringByInterruptRestart = true
    /// Where Nook finds the agent's earlier sessions: its transcripts on disk (`AgentHistory`), or the agent's own list
    /// (ACP `session/list`, when the agent offers it).
    var pastSessions: PastSessionSource = .disk
    /// A model, mode or effort picked during a turn reaches the agent at once, so the running turn goes on with it (Claude
    /// Code's control requests on stdin, ACP's `session/set_model` or `session/set_config_option`); otherwise it counts
    /// from the next message. Codex's app-server has no call that changes a running turn.
    var liveSettings = false
    /// The agent says how long its prompt cache lives (Claude Code's `usage.cache_creation`), so Nook can summarize a long
    /// idle session before the cache expires (`IdleCompaction`). Codex and the ACP agents report cached tokens but not
    /// the cache's lifetime.
    var reportsPromptCacheLifetime = false
    /// How the reason you give with a denial reaches the agent: in the answer to its request (Claude Code's
    /// `control_response` carries a `message`), or as a message of its own right after it (Codex's decline and ACP's
    /// reject outcome have no text, so the reason goes in as a steer, or as the next prompt).
    var denyReason: DenyReasonDelivery = .followUpMessage
    /// A faster tier of the same model beside the effort (`SpeedTiers`): Codex's service tiers, Claude Code's fast mode.
    /// The ACP agents (Gemini CLI, Antigravity, OpenCode, Cursor, Grok, the ones you add) offer none over ACP.
    var speedTiers = false
    /// Claude Code's Ultracode beside the effort (`Ultracode`). No other agent has the concept: Codex, Pi and the ACP
    /// agents offer only their effort levels (see docs/INTEGRATIONS.md).
    var ultracode = false
}

/// See `ProviderCapabilities.denyReason`.
enum DenyReasonDelivery: String, Sendable {
    case inResponse, followUpMessage
}

enum PastSessionSource: Equatable, Sendable {
    case disk, agent
}

/// How a turn's end reaches Nook. Strong: the agent sends an explicit terminal message (Claude Code's `result`, Codex's
/// `turn/completed`, the reply to ACP's `session/prompt`). Weak: Nook has to infer it (the process went quiet or exited).
/// None: the agent never says.
enum TurnEndSignal: String, Codable, Sendable {
    case strong, weak, none
}

/// Agent: permitted to execute. Plan: read-only analysis and plan creation, no modifications.
enum ExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case agent, plan
    var id: String { rawValue }
}

/// What the agent is allowed to do without confirmation.
enum PermissionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Prompt before every edit and command (Claude Code only).
    case ask
    /// Editing files in the workspace directory is allowed; commands prompt first (Claude) or run sandboxed (Codex).
    case acceptEdits
    /// The agent's own reviewer approves routine actions and still asks you for risky ones (Claude Code's
    /// `--permission-mode auto`, Codex's `approvalsReviewer: auto_review`). Only where `ProviderCapabilities.policies`
    /// lists it.
    case auto
    /// Allow everything without prompts. Use only when explicitly desired.
    case bypass
    var id: String { rawValue }

    /// How much the agent may do without you, from least to most. "Auto" lets the agent approve commands you would
    /// otherwise have been asked about, so it ranks above "Allow edits"; it still asks for risky ones, so below "Allow
    /// everything".
    var rank: Int {
        switch self {
        case .ask: return 0
        case .acceptEdits: return 1
        case .auto: return 2
        case .bypass: return 3
        }
    }

    /// Whether a session nobody watches from this Mac may run with it (one started from the phone, a scheduled task): at
    /// most "Allow edits". "Auto" does not count: its reviewer is the agent's own model, and what it approves nobody sees
    /// until afterwards.
    var isUnattendedSafe: Bool { rank <= PermissionPolicy.acceptEdits.rank }

    /// This policy where an agent does not offer it: the most it offers that does not let the agent do more, so a move
    /// to another agent never widens what a session may do (and never falls back on a global "Allow everything").
    func steppedDown(within offered: [PermissionPolicy]) -> PermissionPolicy {
        if offered.contains(self) { return self }
        return offered.filter { $0.rank <= rank }.max { $0.rank < $1.rank } ?? .ask
    }
}

/// Work directly in the project folder, or in a separate Git worktree with its own branch.
enum IsolationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case folder, worktree
    var id: String { rawValue }
}

/// State of a session. All transitions must go through `RunStatus.canMove(to:)`.
enum RunStatus: String, Codable, CaseIterable, Sendable {
    /// Setting up folder or worktree, launching agent.
    case preparing
    /// The agent is running.
    case running
    /// The agent is waiting for your tool approval.
    case waitingApproval
    /// The turn has finished; you can proceed with a new message.
    case completed
    /// Something went wrong.
    case failed
    /// Stopped by user, or process terminated (for example, after relaunching Nook).
    case stopped

    /// Corresponds to an actively running process.
    var isActive: Bool {
        switch self {
        case .preparing, .running, .waitingApproval: return true
        case .completed, .failed, .stopped: return false
        }
    }

    func canMove(to next: RunStatus) -> Bool {
        if next == self { return true }
        switch self {
        case .preparing: return [.running, .failed, .stopped].contains(next)
        case .running: return [.waitingApproval, .completed, .failed, .stopped].contains(next)
        case .waitingApproval: return [.running, .completed, .failed, .stopped].contains(next)
        case .completed, .failed, .stopped: return [.preparing, .running].contains(next)
        }
    }

    /// After a restart no process is running: an "active" session is marked stopped.
    var afterRelaunch: RunStatus { isActive ? .stopped : self }
}

/// Tokens and costs. Nil means: the agent did not report this. Never guess.
struct RunUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    /// Cost as calculated by the agent itself (Claude Code: at API rates, even with a subscription).
    var reportedCostUSD: Double?
    /// Tokens in context during the latest model call.
    var contextTokens: Int?
    /// Maximum context window of the model, if reported by the agent.
    var contextWindow: Int?
    var turns = 0
    /// Total time the agent worked, in seconds (sum of turns).
    var activeSeconds: Double = 0

    var totalTokens: Int? {
        let parts = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    /// Adds a completed turn. Fields not present in the turn remain unchanged.
    mutating func add(_ turn: TurnUsage) {
        inputTokens = Self.sum(inputTokens, turn.inputTokens)
        outputTokens = Self.sum(outputTokens, turn.outputTokens)
        cacheReadTokens = Self.sum(cacheReadTokens, turn.cacheReadTokens)
        cacheWriteTokens = Self.sum(cacheWriteTokens, turn.cacheWriteTokens)
        if let cost = turn.reportedCostUSD { reportedCostUSD = (reportedCostUSD ?? 0) + cost }
        if let context = turn.contextTokens { contextTokens = context }
        if let window = turn.contextWindow { contextWindow = window }
        turns += 1
        activeSeconds += max(0, turn.durationSeconds ?? 0)
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        default: return (a ?? 0) + (b ?? 0)
        }
    }
}

/// Usage reported by a single turn (one process).
struct TurnUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reportedCostUSD: Double?
    var contextTokens: Int?
    var contextWindow: Int?
    var durationSeconds: Double?

    /// What this turn cost in tokens: new input, what went into the cache, and output. Cache reads are left out: every
    /// call in a turn reads the whole context again, so counting them shows hundreds of thousands for one short question.
    var ownTokens: Int {
        (inputTokens ?? 0) + (cacheWriteTokens ?? 0) + (outputTokens ?? 0)
    }
}

/// A single session in the workspace. Stored in `RunStore`, persisted across restarts.
/// Where a session's agent lives while Nook is away, and how far Nook read it.
struct KeptSession: Codable, Equatable, Sendable {
    /// The keeper's folder, under `NookPaths.keeperDirectory`.
    var folder: String
    /// How much of its output Nook handled; nil after a crash, when that was not saved.
    var offset: UInt64? = nil
    /// Codex: the turn that was running.
    var turnID: String? = nil
}

struct WorkspaceRun: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    /// The initial task prompt.
    var task: String
    var provider: RunProvider
    /// Profile account (`AgentProfile.id`).
    var profileID: String
    /// Empty: agent default.
    var model: String
    /// Model actually used by the agent, as reported by itself.
    var resolvedModel: String?
    var mode: ExecutionMode
    var permission: PermissionPolicy
    var isolation: IsolationMode
    /// The folder or repository selected.
    var projectPath: String
    /// Where the agent actually works: directory itself, or the worktree.
    var workingDirectory: String
    /// The root of the Git repository; nil if not a repository.
    var repoRoot: String?
    var branch: String?
    var baseBranch: String?
    /// The branches the session worked on before `branch`, oldest first (see `SessionBranches`).
    var earlierBranches: [String]? = nil
    var worktreePath: String?
    /// Extra instructions for this session (alongside project CLAUDE.md / AGENTS.md).
    var instructions: String
    var status: RunStatus
    /// Status detail: an error message, or reason for stopping.
    var statusDetail: String?
    /// Agent provider session ID for resuming (`claude --resume`, `codex exec resume`).
    var providerSessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool
    var usage: RunUsage
    /// Start of the currently running turn.
    var turnStartedAt: Date?
    /// Last time changes were reviewed; modified afterwards = unreviewed.
    var reviewedAt: Date?
    /// Last time the agent made changes.
    var lastChangeAt: Date?
    /// Number of changed files at last Git check, for list display.
    var changedFiles: Int?
    /// Lines added and removed over those files at the last Git check: the list shows "+12 −3" like a hooked session.
    var changedLinesAdded: Int? = nil
    var changedLinesRemoved: Int? = nil
    /// Snapshots of the worktree, before the first turn and after every turn: "back to here".
    var checkpoints: [RunCheckpoint]? = nil
    /// The agent's own conversation as Nook follows it (turns, Claude Code's last message), and a rollback of it that
    /// goes out with the next turn (see `ConversationRollback`).
    var conversation: ConversationLog? = nil
    var pendingRollback: PendingRollback? = nil
    /// The agent's own conversation this session started from when it could not continue it (see
    /// `carryOverConversation`): taking that conversation over again opens this session, not a second one.
    var carriedOverFrom: String? = nil
    /// The agent's own conversation this session took over as a copy (`adopt(fork:)`, a chat still open in its own app):
    /// the copy gets a new session id, and the original is still this chat to you, so it is not listed a second time.
    var copiedFrom: String? = nil
    /// Stopped on a usage limit: since when, when the limit resets (nil: unknown), and whether the session then goes
    /// on by itself.
    var limitedAt: Date? = nil
    var limitResetAt: Date? = nil
    var autoResume: Bool? = nil
    /// Times in a row Nook went on by itself after a limit and the limit stopped the session again (nil: not resuming).
    /// Keeps "Resume at reset" on for the next limit, and spaces out the tries when the reset time is unknown or stale.
    var limitRetries: Int? = nil
    /// Times in a row Nook went on after a restart cut this session off; back to nil after a turn that ends normally.
    var continuations: Int? = nil
    /// When Nook last went on with it after a restart (see `RestartContinuation.loopWindow`).
    var lastContinuedAt: Date? = nil
    /// The restart cut it off while it waited for your approval: that approval is gone, so Nook does not go on by itself.
    var interruptedWhileWaiting: Bool? = nil
    /// Nook quit after this session's turn ended while it waited on work in the background (a subagent): that work
    /// stopped with it and will not report back (see `RestartContinuation`).
    var cutBackgroundWork: CutBackgroundWork? = nil
    /// Snoozed until this time, and since when (see `SnoozePolicy`).
    var snoozedUntil: Date? = nil
    var snoozedAt: Date? = nil
    /// Set when another session delegated this one as a task (see `Delegation`).
    var delegation: DelegationLink? = nil
    /// Each agent's own conversation in this session, by agent, and how much of the timeline it has taken part in: a switch
    /// back to an agent resumes its conversation and hands over only what it missed (see `ContextTransfer`).
    var providerSessions: [String: String]? = nil
    var handoffCursors: [String: Int]? = nil
    /// The summary the next turn starts with, after a fork or a switch to another agent.
    var pendingHandoff: String? = nil
    /// Set for a fork.
    var lineage: RunLineage? = nil
    /// Reasoning effort for the next turns ("low", "medium", "high"); nil is the agent's own default.
    var effort: String? = nil
    /// The speed tier for the next turns (`SpeedTiers`); nil is the agent's standard speed.
    var speedTier: String? = nil
    /// Claude Code's Ultracode for the next turns (`Ultracode`); nil leaves your own Claude setting alone.
    var ultracode: Bool? = nil
    /// "Auto": Nook picks `model` for each turn (see `AutoModel`); nil for a model you chose.
    var autoModel: Bool? = nil
    /// What the last turn on Auto asked for (`AutoModel.Tier` raw value), so a short follow-up does not drop a hard thread.
    var autoNeed: Int? = nil
    /// The agent's own task list, as it last reported it.
    var tasks: [RunTaskStep]? = nil
    /// The goal the agent works toward, as it reported it (see `SessionGoals`).
    var goal: SessionGoal? = nil
    /// Its agent runs through a keeper and can outlive Nook (see `SessionKeeper`).
    var kept: KeptSession? = nil
    /// The pull request this session watches: what it last saw, so only news wakes it.
    var prWatch: PullRequestWatch? = nil
    /// The pull requests watched besides `prWatch`, which stays the one the composer's tray shows.
    var extraPRWatches: [PullRequestWatch]? = nil
    /// Every pull request this session watches.
    var prWatches: [PullRequestWatch] { (prWatch.map { [$0] } ?? []) + (extraPRWatches ?? []) }
    /// Runs on another machine over SSH; `workingDirectory` is then a path on that machine.
    var remote: RemoteTarget? = nil
    /// Claude Code: how long the prompt cache of the session's last request stays warm (see `IdleCompaction`).
    var promptCache: PromptCacheWindow? = nil
    /// How much of the work this session's timeline shows; nil follows Settings (`WorkspaceSettings.timelineDetail`).
    var timelineDetail: TimelineDetail? = nil

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        let folder = name.isEmpty ? projectPath : name
        // A session on another machine says which: "buildbox:app".
        return remote.map { $0.name + ":" + folder } ?? folder
    }

    var isRemote: Bool { remote != nil }

    var hasUnreviewedChanges: Bool {
        guard let changed = lastChangeAt, (changedFiles ?? 1) > 0 else { return false }
        return reviewedAt.map { $0 < changed } ?? true
    }

    /// Can a new message be sent to this session? Only when previous turn has finished.
    var canContinue: Bool { !status.isActive }

    /// A session starts with an initial state; other transitions go through `move(to:)`.
    @discardableResult
    mutating func move(to next: RunStatus, detail: String? = nil, now: Date = Date()) -> Bool {
        guard status.canMove(to: next) else { return false }
        status = next
        statusDetail = detail
        updatedAt = now
        if (next == .preparing || next == .running), turnStartedAt == nil { turnStartedAt = now }
        if !next.isActive { turnStartedAt = nil }
        return true
    }

    /// Does `session` name this run's conversation: its current session id or an earlier one (a resumed chat gets a new id)?
    func isConversation(_ session: String) -> Bool {
        providerSessionID == session || earlierConversations.contains(session)
    }

    /// The agent's conversation ids this session stands for besides its current one: earlier ids of a resumed chat, and
    /// the chat it was carried over or copied from. The lists show those as this session, not as a chat of their own.
    var earlierConversations: [String] {
        (conversation?.earlierSessions ?? []) + [carriedOverFrom, copiedFrom].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

/// One step of the task list an agent keeps while it works: Claude Code's TodoWrite, Codex's `turn/plan/updated`,
/// an ACP `plan` update.
struct RunTaskStep: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case pending, active, done }
    var text: String
    var status: Status
}

enum RunTasks {
    static func status(_ raw: String?) -> RunTaskStep.Status {
        switch raw {
        case "completed", "done": return .done
        case "in_progress", "inProgress", "running", "active": return .active
        default: return .pending
        }
    }

    /// Claude Code's TodoWrite input: `todos` with `content`, `status` and, for the running one, `activeForm`.
    static func claude(_ input: [String: Any]) -> [RunTaskStep]? {
        guard let todos = input["todos"] as? [[String: Any]] else { return nil }
        return todos.compactMap { todo in
            let state = Self.status(todo["status"] as? String)
            let active = (todo["activeForm"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let text = (state == .active ? active : nil) ?? (todo["content"] as? String), !text.isEmpty else { return nil }
            return RunTaskStep(text: text, status: state)
        }
    }

    /// Codex's `turn/plan/updated`: `plan` with `step` and `status`.
    static func codex(_ params: [String: Any]) -> [RunTaskStep]? {
        guard let plan = params["plan"] as? [[String: Any]] else { return nil }
        return plan.enumerated().map { index, step in
            let text = ((step["step"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return RunTaskStep(text: text.isEmpty ? "Step \(index + 1)" : text, status: Self.status(step["status"] as? String))
        }
    }

    /// An ACP `plan` update: `entries` with `content` and `status`.
    static func acp(_ update: [String: Any]) -> [RunTaskStep] {
        ((update["entries"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let text = entry["content"] as? String, !text.isEmpty else { return nil }
            return RunTaskStep(text: text, status: Self.status(entry["status"] as? String))
        }
    }

    /// How far the list is, and the step that matters now: the running one, else the next, else the last.
    static func progress(_ steps: [RunTaskStep]) -> (done: Int, total: Int, current: String) {
        let current = steps.first { $0.status == .active } ?? steps.first { $0.status == .pending } ?? steps.last
        return (steps.filter { $0.status == .done }.count, steps.count, current?.text ?? "")
    }

    static func isFinished(_ steps: [RunTaskStep]?) -> Bool {
        guard let steps, !steps.isEmpty else { return true }
        return steps.allSatisfy { $0.status == .done }
    }
}

/// What a watched pull request last looked like. A change in it is news for the session.
struct PullRequestWatch: Codable, Equatable, Sendable {
    /// A GitHub pull request, a GitLab merge request, or a pull request on a forge with a token.
    static func canWatch(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        let github = url.host?.hasSuffix("github.com") == true && parts.count >= 4 && parts[2] == "pull" && Int(parts[3]) != nil
        if github || url.absoluteString.contains("/-/merge_requests/") { return true }
        // Every other forge once it has a token.
        return PullRequestRef.parse(url.absoluteString)?.forgeRepository.flatMap(PullRequestForges.client) != nil
    }

    var url: String
    /// "open", "merged", "closed".
    var state: String = "open"
    /// "success", "failure", "pending", or empty when there are no checks.
    var checks: String = ""
    /// Reviews and comments seen so far.
    var reviewCount: Int = 0
    var commentCount: Int = 0
    /// In conflict with its base branch at the last look; nil before the forge has said so (and in watches from before).
    var conflicted: Bool? = nil
    /// Send news to the agent as a message (otherwise it only shows in the timeline).
    var wakeAgent: Bool = true
    var checkedAt: Date? = nil

    /// A watch that ended (its pull request merged or closed) moves to a newer open pull request of the same branch: the
    /// session went on with a new pull request from that branch, which is the one to follow now. `links` are the branch's
    /// pull requests as the forge reads them. Returns the finished watch and the request to watch instead, or nil.
    static func carried(_ watches: [PullRequestWatch], links: [PullRequestLink]) -> (from: PullRequestWatch, to: URL)? {
        let watched = Set(watches.map(\.url))
        for watch in watches {
            guard let link = links.first(where: { $0.url == watch.url }),
                  watch.state != "open" || !link.state.isOpen else { continue }
            let next = links.filter { $0.state.isOpen && $0.number > link.number && !watched.contains($0.url)
                && $0.headBranch == link.headBranch && $0.repository == link.repository }
                .min { $0.number < $1.number }
            if let next, let url = URL(string: next.url), canWatch(url) { return (watch, url) }
        }
        return nil
    }
}

/// How a pull request looks right now, as fetched for a watch.
struct PullRequestSnapshot: Equatable, Sendable {
    struct Note: Equatable, Sendable {
        var author: String
        /// A review's verdict ("APPROVED", "CHANGES_REQUESTED", "COMMENTED"), empty for a comment.
        var verdict: String
        var text: String
    }
    var state: String
    var checks: String
    var failedChecks: [String]
    /// All reviews and comments, oldest first.
    var reviews: [Note]
    var comments: [Note]
    /// Open but marked as a draft; `state` still says "open", which is what a watch compares.
    var draft = false
    /// Open and in conflict with its base branch.
    var conflicted = false
    /// How merging stands; nil when this read does not say.
    var merge: PullRequestMergeFacts? = nil
    /// Whether `conflicted` is the forge's answer: GitHub works it out lazily after a push, and says nothing until then.
    var mergeabilityKnown = true
    /// Whether `checks` is the forge's answer. Empty `checks` then means there are none on this commit (yet, right after a
    /// push); without an answer they may as well still be failing.
    var checksKnown = true
}

/// News about a pull request that waits in the queue for the agent, line by line, so that what is no longer true can go
/// before it is sent (see `PullRequestNews.stillNeeded`).
struct PullRequestNotice: Codable, Equatable, Sendable {
    var url: String
    var lines: [PullRequestNews.Line]
}

/// What changed on a watched pull request since the last look: lines for the timeline, and the message for the agent.
enum PullRequestNews {
    /// One line of news, and what it is about: that decides whether it can go out of date.
    struct Line: Codable, Equatable, Sendable {
        enum Subject: String, Codable, Sendable {
            /// Failed checks: over once they stop failing.
            case failedChecks
            /// A merge conflict: over once it is gone.
            case conflict
            /// A review or comment: it stays to be read, whatever happens to the pull request's status.
            case note
            /// Something the agent has nothing to do for, such as passed checks.
            case status
        }

        var text: String
        var subject: Subject
    }

    static func lines(old: PullRequestWatch, new: PullRequestSnapshot) -> [Line] {
        var lines: [Line] = []
        if new.state != old.state {
            let text = new.state == "merged" ? "The pull request was merged." : new.state == "closed" ? "The pull request was closed." : "The pull request was reopened."
            lines.append(Line(text: text, subject: .status))
        }
        if new.checks != old.checks {
            switch new.checks {
            case "failure":
                lines.append(failedChecksLine(new))
            case "success" where !old.checks.isEmpty: lines.append(Line(text: "CI passed.", subject: .status))
            default: break
            }
        }
        if let conflict = conflictLine(old: old.conflicted, new: new) { lines.append(conflict) }
        for review in new.reviews.dropFirst(min(old.reviewCount, new.reviews.count)) {
            let body = plain(review.text)
            let text = body.isEmpty ? "" : ": " + body
            lines.append(Line(text: "Review from @\(review.author) (\(review.verdict.lowercased().replacingOccurrences(of: "_", with: " ")))" + text, subject: .note))
        }
        for comment in new.comments.dropFirst(min(old.commentCount, new.comments.count)) {
            let body = plain(comment.text)
            lines.append(Line(text: "Comment from @\(comment.author)" + (body.isEmpty ? "" : ": " + body), subject: .note))
        }
        return lines
    }

    /// The first look at a watch reports nothing that happened before, except what is still there to fix: failing
    /// checks and a conflict. Watching a pull request whose CI is already red sets the agent to work on it at once.
    static func firstLook(_ new: PullRequestSnapshot) -> [Line] {
        var lines: [Line] = []
        if new.state == "open", new.checks == "failure" { lines.append(failedChecksLine(new)) }
        if let conflict = conflictLine(old: false, new: new) { lines.append(conflict) }
        return lines
    }

    private static func failedChecksLine(_ new: PullRequestSnapshot) -> Line {
        Line(text: "CI failed" + (new.failedChecks.isEmpty ? "." : ": " + new.failedChecks.prefix(8).joined(separator: ", ") + "."),
             subject: .failedChecks)
    }

    private static func conflictLine(old: Bool?, new: PullRequestSnapshot) -> Line? {
        guard new.state == "open", new.mergeabilityKnown, let old, new.conflicted != old else { return nil }
        return new.conflicted ? Line(text: "The pull request has merge conflicts with its base branch.", subject: .conflict)
            : Line(text: "The merge conflicts are resolved.", subject: .status)
    }

    /// What is left of a waiting notice now that the pull request looks like this: a merged or closed one needs nothing,
    /// and checks or a conflict that were fixed in the meantime are gone. A check that fails again is new news, so checks
    /// that are running count as over. Nil when nothing is left for the agent to do.
    static func stillNeeded(_ notice: PullRequestNotice, new: PullRequestSnapshot) -> PullRequestNotice? {
        guard new.state == "open" else { return nil }
        var kept = notice
        kept.lines = notice.lines.filter { line in
            switch line.subject {
            case .failedChecks: return new.checks == "failure" || !new.checksKnown
            case .conflict: return new.conflicted || !new.mergeabilityKnown
            case .note, .status: return true
            }
        }
        return kept.lines.contains { $0.subject != .status } ? kept : nil
    }

    /// A review or comment as one readable line: a bot's HTML comments, tags, badges and images left out, links as their
    /// words. The agent can read the whole comment on GitHub; the line says what it is about.
    static func plain(_ text: String, limit: Int = 300) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"<!--[\s\S]*?(-->|$)"#, " "),                // HTML comments, also one cut off
            (#"<details>[\s\S]*?</details>"#, " "),        // folded sections
            (#"!\[[^\]]*\]\([^)]*\)"#, " "),             // images and badges
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),           // links: their words
            (#"<[^>]*>"#, " "),                             // other tags
            (#"(?m)^\s*(#+|>+|[-*_]{3,})\s*"#, " ")         // headings, quotes, rules
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        let words = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ToolSummary.oneLine(words, limit)
    }

    /// Worth waking the agent for: something it can act on (failed CI, a merge conflict, reviews, comments), not a merge
    /// or a pass.
    static func needsAgent(old: PullRequestWatch, new: PullRequestSnapshot) -> Bool {
        guard new.state == "open" else { return false }
        return (new.checks == "failure" && old.checks != "failure") || newConflict(old: old, new: new)
            || new.reviews.count > old.reviewCount || new.comments.count > old.commentCount
    }

    static func newConflict(old: PullRequestWatch, new: PullRequestSnapshot) -> Bool {
        new.state == "open" && new.mergeabilityKnown && new.conflicted && old.conflicted != true
    }

    static func message(url: String, lines: [String]) -> String {
        "Update on your pull request \(url):\n" + lines.map { "- " + $0 }.joined(separator: "\n")
            + "\n\nLook into this and fix what is needed; push when done."
    }

    static func updated(_ watch: PullRequestWatch, with snapshot: PullRequestSnapshot, at date: Date) -> PullRequestWatch {
        var next = watch
        next.state = snapshot.state
        next.checks = snapshot.checks
        next.reviewCount = snapshot.reviews.count
        next.commentCount = snapshot.comments.count
        if snapshot.mergeabilityKnown { next.conflicted = snapshot.conflicted }
        next.checkedAt = date
        return next
    }
}

/// A single entry in a session's timeline.
struct RunEvent: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, assistant, thinking, tool, fileChange, approval, error, system, result
        /// A page the agent showed inline (`render_page`, see `RenderedPage`): `text` its title, `detail` its file.
        case page
    }

    enum State: String, Codable, Sendable {
        case running, done, failed, pending, allowed, denied, expired
    }

    var id: UUID
    var date: Date
    var kind: Kind
    /// Primary text: message, tool summary, error message.
    var text: String
    /// Tool name, or type of change (added/modified/deleted).
    var tool: String?
    /// Tool call ID (or approval request ID), to match output.
    var callID: String?
    /// Tool input as JSON, or file path.
    var detail: String?
    /// Tool output, clipped.
    var output: String?
    var state: State?
    /// Undone by going back to before an earlier message: shown dimmed, the agent no longer remembers it.
    var rolledBack: Bool? = nil
    /// Taken from the agent's transcript, not written by a turn in Nook: the conversation went on outside Nook (see
    /// TranscriptFollow). The transcript message or step it stands for, so reading the transcript again updates it.
    var source: String? = nil
    /// For a subagent's launch: what the subagent itself thought, wrote and did while it worked, in order
    /// (`SubagentStep`). Nil for every other event.
    var subagentSteps: [SubagentStep]? = nil
    /// A command the agent left running in the background (`BackgroundCommands`): it outlives its turn and settles with
    /// its own end. Nil for every other event.
    var background: Bool? = nil
    /// For a message of yours that went into a turn while it ran: whether you steered it, or a queued message was taken
    /// into it. Nil for a message that started a turn, and for every other event.
    var steer: SteerKind? = nil
    /// For a switch of agent, model or effort (a `.system` event with tool "switch"): what the session ran before and
    /// after it. Nil for every other event.
    var change: ModelSwitch? = nil

    /// How a message of yours reached a turn that was running.
    enum SteerKind: String, Codable, Sendable {
        /// Sent into the running turn (Steer).
        case steer
        /// Queued first, then taken into the running turn.
        case promoted
    }

    init(kind: Kind, text: String, tool: String? = nil, callID: String? = nil, detail: String? = nil,
         output: String? = nil, state: State? = nil, date: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.tool = tool
        self.callID = callID
        self.detail = detail
        self.output = output
        self.state = state
    }

    /// Long tool output clipped; the full version is stored in the agent's own transcript.
    static let outputLimit = 16_000

    /// An MCP app's page (see McpUI) is shown, not read: it has to arrive whole.
    static let appOutputLimit = 256_000

    /// Also hides a secret the workspace bridge handed to the agent (request_secret): it is never stored or shown.
    static func clip(_ text: String, _ limit: Int = outputLimit) -> String {
        let text = BridgeSecret.redact(text)
        let limit = limit == outputLimit && text.contains(McpUI.fence) ? appOutputLimit : limit
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}

/// One step of a subagent's own work, kept on the event that started it: a thought, a message, or a tool it called.
struct SubagentStep: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case thinking, text, tool }

    var kind: Kind
    var text: String
    /// For a tool step: the tool's own name ("Bash", "Read"), so the step reads as the agent's own work does. Nil for
    /// thoughts and messages, and for steps kept before Nook stored it (`toolName` reads those from their text).
    var tool: String? = nil

    /// The steps kept per subagent, and the length of each: enough to follow its reasoning without the timeline
    /// growing without bound.
    static let limit = 400
    static let textLimit = 6_000

    /// `steps` with `step` added: a step clipped to its length, the oldest given up past the limit.
    static func appending(_ step: SubagentStep, to steps: [SubagentStep]?) -> [SubagentStep] {
        var steps = steps ?? []
        let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return steps }
        steps.append(SubagentStep(kind: step.kind, text: RunEvent.clip(text, textLimit), tool: step.tool))
        if steps.count > limit { steps.removeFirst(steps.count - limit) }
        return steps
    }

    /// The tool a tool step called: its stored name, else the word before " · " in its text ("Bash · ls").
    var toolName: String {
        if let tool, !tool.isEmpty { return tool }
        guard let range = text.range(of: " · ") else { return text }
        let head = String(text[..<range.lowerBound])
        return head.contains(" ") ? text : head
    }

    /// What a tool step was done to (the command, the file, the pattern): its text after the tool's name or label.
    var toolDetail: String {
        guard let range = text.range(of: " · ") else { return "" }
        return String(text[range.upperBound...])
    }
}

/// A subagent's steps as the agent's own work reads: each thought and message on its own, tool calls in a row together.
enum SubagentSteps {
    struct Block: Identifiable, Equatable, Sendable {
        /// The index of its first step, stable while steps join at the end.
        var id: Int
        var steps: [SubagentStep]
    }

    static func blocks(_ steps: [SubagentStep]) -> [Block] {
        var blocks: [Block] = []
        for (index, step) in steps.enumerated() {
            if step.kind == .tool, let last = blocks.last, last.steps.last?.kind == .tool {
                blocks[blocks.count - 1].steps.append(step)
            } else {
                blocks.append(Block(id: index, steps: [step]))
            }
        }
        return blocks
    }

    /// The tool steps as the events a `ToolTally` counts ("Ran 3 commands, read 2 files").
    static func tally(_ steps: [SubagentStep]) -> ToolTally {
        ToolTally(steps.filter { $0.kind == .tool }.map { RunEvent(kind: .tool, text: $0.text, tool: $0.toolName) })
    }
}

/// Form fields for "New Session". Validated before anything starts.
struct NewRunConfig: Equatable, Sendable {
    var title = ""
    var task = ""
    var provider: RunProvider = .claude
    var profileID = "claude"
    var model = ""
    var mode: ExecutionMode = .agent
    var permission: PermissionPolicy = .acceptEdits
    /// Reasoning effort for the session; nil is the agent's own default.
    var effort: String? = nil
    /// The speed tier for the session (`SpeedTiers`); nil is the agent's standard speed. Not remembered for the next
    /// session: a faster tier costs more.
    var speedTier: String? = nil
    /// Claude Code's Ultracode for the session (`Ultracode`); nil leaves your own Claude setting alone.
    var ultracode: Bool? = nil
    var isolation: IsolationMode = .folder
    var projectPath = ""
    var baseBranch = ""
    var branchName = ""
    var worktreeRoot = ""
    var instructions = ""
    /// Set for a task that another session delegated.
    var delegation: DelegationLink? = nil
    /// Run on another machine over SSH, in this folder there (or a new worktree of it there).
    var remote: RemoteTarget? = nil
    /// Set for a session of a model comparison after its first one (see `ModelComparison`).
    var lineage: RunLineage? = nil
    /// Who started it when it was not you in the composer ("Started by Claude Code in the session …"): the first line of
    /// its timeline. Set by `session_start`, `nook start` and Nook Chat marks a thread an agent created.
    var startedBy: String? = nil
    /// Starts without a first message (`session_start` with a title only): the session waits, ready, for yours.
    var startsIdle = false

    /// Problem description enum, or nil if valid. Only checks input; manager checks Git and paths.
    var problem: ConfigProblem? {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !startsIdle || title.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingTask
        }
        if let remote {
            guard RemoteMachines.isValidHost(remote.host), RemoteMachines.isValidDirectory(remote.directory),
                  provider != .antigravity else { return .invalidRemote }
            if !provider.capabilities.policies.contains(permission) { return .unsupportedPolicy }
            // A worktree there starts from the branch the folder is on unless you name one.
            if isolation == .worktree, !WorktreeNaming.isPlausibleBranchName(branchName) { return .invalidBranchName }
            return nil
        }
        if projectPath.isEmpty { return .missingWorkspace }
        if !provider.capabilities.policies.contains(permission) { return .unsupportedPolicy }
        if isolation == .worktree {
            if baseBranch.isEmpty { return .missingBaseBranch }
            if !WorktreeNaming.isPlausibleBranchName(branchName) { return .invalidBranchName }
        }
        return nil
    }
}

enum ConfigProblem: String, Equatable, Sendable {
    case missingTask, missingWorkspace, unsupportedPolicy, missingBaseBranch, invalidBranchName, invalidRemote
}

/// Names for sessions, branches, and worktree directories derived from the task prompt.
enum WorktreeNaming {
    /// "Fix de login-bug in Safari!" → "fix-de-login-bug-in-safari".
    static func slug(_ text: String, limit: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
            if result.count >= limit { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "sessie" : result
    }

    /// A short title from the first line of the task prompt.
    static func title(from task: String, limit: Int = 60) -> String {
        // The first line of your own words: an agent's tags (`<task-notification>` …) are no title.
        let clean = InjectedPrompt.title(task.split(whereSeparator: \.isNewline).filter { !isPathLine($0) }.joined(separator: "\n"))
        guard !clean.isEmpty else { return "Nieuwe sessie" }
        if clean.count <= limit { return clean }
        let cut = clean.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// The prefix Nook puts before the branches it creates, unless Settings › Workspace names another.
    static let defaultBranchPrefix = "nook"
    /// UserDefaults key of the branch prefix (written by `WorkspaceSettings`).
    static let branchPrefixKey = "ws.branchPrefix"

    /// The branch prefix from Settings, cleaned up; falls back to "nook".
    static var branchPrefix: String {
        normalizedBranchPrefix(UserDefaults.standard.string(forKey: branchPrefixKey) ?? defaultBranchPrefix)
    }

    /// " Team/Michan " → "team/michan": every path component slugged, without leading, trailing, or double slashes.
    /// An empty result falls back to "nook", so Nook's branches always carry a prefix.
    static func normalizedBranchPrefix(_ raw: String) -> String {
        let parts = raw.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }.map { slug($0, limit: 32) }
        return parts.isEmpty ? defaultBranchPrefix : parts.joined(separator: "/")
    }

    /// "nook/fix-login-bug-3fa2": recognizable and unique thanks to a slice of the UUID.
    static func branchName(task: String, id: UUID, prefix: String = WorktreeNaming.branchPrefix) -> String {
        normalizedBranchPrefix(prefix) + "/" + shortSlug(task) + "-" + String(id.uuidString.prefix(4)).lowercased()
    }

    /// The branch with the slug an agent wrote in place of the one from the prompt, keeping Nook's prefix and the
    /// slice of the UUID: ("nook/zorg-ervoor-branch-namen-a6f8", "clearer-branch-names") → "nook/clearer-branch-names-a6f8".
    /// Nil when the branch is not one Nook named this way, or nothing would change.
    static func renamedBranch(_ branch: String, slug: String) -> String? {
        guard let slash = branch.lastIndex(of: "/"), let dash = branch.lastIndex(of: "-"), slash < dash else { return nil }
        let suffix = branch[branch.index(after: dash)...]
        guard suffix.count == 4, suffix.allSatisfy(\.isHexDigit) else { return nil }
        let name = String(branch[...slash]) + slug + "-" + suffix
        return name == branch || !isPlausibleBranchName(name) ? nil : name
    }

    /// The directory of a branch's worktree: "nook/fix-login-bug-3fa2" → "fix-login-bug-3fa2". The repository's own
    /// directory already says where it belongs, so Nook's prefix (the configured one, or "nook") is left off.
    static func directorySlug(branch: String, prefix: String = WorktreeNaming.branchPrefix) -> String {
        var name = branch
        for candidate in [normalizedBranchPrefix(prefix) + "/", defaultBranchPrefix + "/"] where name.hasPrefix(candidate) {
            name = String(name.dropFirst(candidate.count))
            break
        }
        return slug(name.replacingOccurrences(of: "/", with: "-"), limit: 60)
    }

    /// Words that say little in a branch name, in the languages Nook speaks.
    private static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "for", "and", "or", "that", "this", "it", "is", "be", "you", "your",
        "i", "me", "my", "we", "can", "could", "please", "so", "with", "make", "sure", "should", "just", "really",
        "also", "now", "want", "would", "like", "let", "lets", "us",
        "de", "het", "een", "en", "dat", "die", "dit", "deze", "je", "jij", "u", "ik", "wij", "mijn", "kan",
        "kun", "kunnen", "wil", "graag", "zodat", "zo", "ook", "nog", "er", "te", "om", "van", "naar", "met", "voor",
        "zijn", "wordt", "moet", "moeten", "maar", "wat", "als", "dan", "aan", "bij", "uit", "op",
        "zorg", "ervoor", "echt", "even", "gewoon", "worden", "nu", "eens", "hier", "daar", "wel", "ze",
        "der", "das", "ein", "eine", "und", "le", "la", "les", "un", "une", "et", "el", "los", "las", "y"
    ]

    /// A short slug from the meaningful words of the task's first line: "Verwijder de button dat je het scherm kleiner
    /// kan maken" → "verwijder-button-scherm-kleiner". Pasted paths (pictures) are skipped; words are never cut in half.
    static func shortSlug(_ task: String, maxWords: Int = 4, limit: Int = 32) -> String {
        let lines = task.split(whereSeparator: \.isNewline).filter { !isPathLine($0) }
        let words = slug(InjectedPrompt.title(lines.joined(separator: "\n")), limit: 200)
            .split(separator: "-").map(String.init)
        let meaningful = words.filter { !fillerWords.contains($0) }
        var result: [String] = []
        for word in meaningful.isEmpty ? words : meaningful {
            let length = result.joined(separator: "-").count + (result.isEmpty ? 0 : 1) + word.count
            if result.count >= maxWords || (length > limit && !result.isEmpty) { break }
            result.append(String(word.prefix(limit)))
        }
        return result.isEmpty || result == ["sessie"] ? "sessie" : result.joined(separator: "-")
    }

    private static func isPathLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) && !trimmed.contains("  ")
    }

    /// Fast check without Git; `GitService.isValidBranchName` verifies via Git directly.
    static func isPlausibleBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"),
              !name.contains("@{"), name != "@" else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Location of the worktree: <root>/<repo>/<slug>. Appends a sequence number if directory exists.
    static func worktreePath(root: String, repoName: String, slug: String, exists: (String) -> Bool) -> String {
        let base = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(Self.slug(repoName, limit: 40), isDirectory: true)
        var candidate = base.appendingPathComponent(slug, isDirectory: true).path
        var counter = 2
        while exists(candidate) {
            candidate = base.appendingPathComponent("\(slug)-\(counter)", isDirectory: true).path
            counter += 1
        }
        return candidate
    }
}

/// Directories an agent is permitted to access. Never system directories or full root filesystem.
enum WorkspacePathPolicy {
    enum Verdict: Equatable {
        case ok
        case missing
        case notDirectory
        case unreadable
        case forbidden
    }

    private static let forbiddenRoots = ["/", "/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc",
                                         "/var", "/dev", "/cores", "/opt", "/Applications", "/Volumes"]

    static func verdict(for raw: String, fileManager: FileManager = .default, home: String = NSHomeDirectory()) -> Verdict {
        let path = normalize(raw)
        guard !path.isEmpty else { return .missing }
        if path == normalize(home) || forbiddenRoots.contains(path) { return .forbidden }
        // System directories themselves, and everything within them except /opt/… and /Volumes/… (external drives, Homebrew projects).
        for root in ["/System", "/bin", "/sbin", "/usr", "/etc", "/dev", "/private/etc", "/private/var/db"]
        where path.hasPrefix(root + "/") { return .forbidden }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notDirectory }
        guard fileManager.isReadableFile(atPath: path) else { return .unreadable }
        return .ok
    }

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The folder a session works in, for its branch and changes. An agent that steps out of its project for a moment (a
/// `cd` into a scratch folder or `/tmp`) still works on that project: the session keeps the folder in a repository
/// instead of following it into one that has no git. A move into another repository (a worktree it entered) counts.
enum SessionFolder {
    /// The folder to keep when the agent reports `reported` while the session had `current`.
    static func follow(current: String, reported: String, isRepository: (String) -> Bool = SessionFolder.isRepository) -> String {
        guard !reported.isEmpty else { return current }
        guard !current.isEmpty, current != reported else { return reported }
        return isRepository(reported) || !isRepository(current) ? reported : current
    }

    /// Whether `path` lies in a git repository or worktree: a `.git` folder or file in it or above it. No git process.
    static func isRepository(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<32 {
            if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return false
    }
}

/// An MCP tool as people read it: `mcp__bestanden-mappen__move_file` is "Move file" from "Bestanden mappen".
struct McpToolName: Equatable {
    var server: String
    var tool: String

    init(server: String, tool: String) {
        self.server = server
        self.tool = tool
    }

    /// The name an agent reports (`mcp__server__tool`); nil for any other tool.
    init?(_ raw: String) {
        guard raw.hasPrefix("mcp__") else { return nil }
        let parts = raw.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2, let tool = parts.last, !tool.isEmpty else { return nil }
        let server = parts.dropLast().joined(separator: "__")
        guard !server.isEmpty else { return nil }
        self.init(server: server, tool: tool)
    }

    /// The server's name; claude.ai connectors lose their `claude_ai_` prefix ("claude_ai_Google_Drive" is "Google Drive").
    var serverLabel: String {
        let bare = server.hasPrefix("claude_ai_") && server.count > 10 ? String(server.dropFirst(10)) : server
        return Self.readable(bare)
    }

    var toolLabel: String { Self.readable(tool) }

    /// "Bestanden mappen › Move file".
    var label: String { "\(serverLabel) › \(toolLabel)" }

    /// An identifier as words: "move_file", "move-file" and "moveFile" read as "Move file". Acronyms and words written
    /// with a capital after a separator keep their case ("get_URL" is "Get URL", "Google_Drive" is "Google Drive"); a
    /// name that already has spaces stays as it is.
    static func readable(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return trimmed }
        // Each word, and whether it started at a camelCase hump rather than after a separator.
        var words: [(text: String, hump: Bool)] = []
        var current = ""
        var hump = false
        for character in trimmed {
            if "_-./:".contains(character) {
                if !current.isEmpty { words.append((current, hump)) }
                current = ""
                hump = false
            } else if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append((current, hump))
                current = String(character)
                hump = true
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append((current, hump)) }
        guard !words.isEmpty else { return trimmed }
        let shaped = words.enumerated().map { index, word -> String in
            let text = word.text
            if text.count > 1, text == text.uppercased(), text.contains(where: \.isLetter) { return text }
            if index == 0 { return text.prefix(1).uppercased() + text.dropFirst().lowercased() }
            if !word.hump, text.first?.isUppercase == true { return text }
            return text.lowercased()
        }
        return shaped.joined(separator: " ")
    }

    /// Every argument of a call as "name: value" lines, sorted by name and never shortened: what is approved must be
    /// what is shown.
    static func arguments(_ input: [String: Any]) -> String {
        argumentLines(input).joined(separator: "\n")
    }

    static func argumentLines(_ input: [String: Any]) -> [String] {
        input.sorted { $0.key < $1.key }.map { key, value -> String in
            let text: String
            switch value {
            case let string as String: text = string
            case let number as Int: text = String(number)
            case let number as Double: text = String(number)
            default: text = ToolSummary.json(value)
            }
            return "\(readable(key)): \(text)"
        }
    }
}

/// Concise, language-neutral summary of a tool call: "Bash · npm test", "Edit · Login.swift".
enum ToolSummary {
    static func describe(tool: String, input: [String: Any]) -> String {
        // Nook's own workspace tools (`mcp__nook__terminal_run`): their label, and the command, address or title.
        if tool.hasPrefix(BridgeTool.toolPrefix), let bridge = BridgeTool.named(tool) {
            return BridgeTool.detail(input).map { "\(bridge.label) · \(oneLine($0, 120))" } ?? bridge.label
        }
        // Another MCP tool: "Bestanden mappen › Move file · Source: a.txt, Destination: b.txt".
        if let mcp = McpToolName(tool) {
            let detail = McpToolName.argumentLines(input).prefix(2).joined(separator: ", ")
            return detail.isEmpty ? mcp.label : "\(mcp.label) · \(oneLine(detail, 100))"
        }
        if let command = command(input) { return "\(tool) · \(oneLine(command, 120))" }
        if let path = path(input) { return "\(tool) · \(URL(fileURLWithPath: path).lastPathComponent)" }
        for key in ["pattern", "query", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return "\(tool) · \(oneLine(value, 100))" }
        }
        if tool == "TodoWrite", let todos = input["todos"] as? [Any] { return "\(tool) · \(todos.count)" }
        return tool
    }

    static func command(_ input: [String: Any]) -> String? {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String], !parts.isEmpty {
            if parts.count >= 3, ["bash", "sh", "zsh"].contains(URL(fileURLWithPath: parts[0]).lastPathComponent),
               parts[1].hasPrefix("-") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    static func path(_ input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "absolute_path", "path"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Files modified by this tool, along with the type of change.
    static func fileChanges(tool: String, input: [String: Any]) -> [(path: String, kind: String)] {
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit":
            return path(input).map { [($0, "modified")] } ?? []
        case "Write", "write_file":
            return path(input).map { [($0, "written")] } ?? []
        case "replace":
            // Gemini CLI's edit tool.
            return path(input).map { [($0, "modified")] } ?? []
        default:
            return []
        }
    }

    static func oneLine(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// Formatted, sorted JSON for timeline display.
    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "\(object)" }
        return text
    }
}


/// A switch of the agent, model or effort a session runs, as the timeline marks it between two turns:
/// "⇄ Context handoff  Claude Code Sonnet 5.5 → Codex GPT-5 (High)" when the agent changes, "Sonnet 5.5 → Opus 5.5 high"
/// when only the model or effort does. A switch to another account of the same agent names both sides with the
/// account's badge on the logo.
struct ModelSwitch: Codable, Equatable, Sendable {
    struct Endpoint: Codable, Equatable, Sendable {
        /// `RunProvider.rawValue`, for the agent's logo and color.
        var provider: String
        /// The agent's name ("Claude Code", "Codex").
        var agent: String
        /// The model's name as the menu shows it; nil for the agent's default model.
        var model: String?
        /// The reasoning effort's id ("high"); nil for the default.
        var effort: String?
        /// The account it runs under (`AgentProfile.id`), for the badge on the agent's logo; nil in switches recorded
        /// before accounts were noted.
        var profile: String? = nil
        /// The account's name when the switch happened ("Work"), for the badge and the words when the account is gone.
        var account: String? = nil

        func sameSetting(_ other: Endpoint) -> Bool { model == other.model && effort == other.effort }
    }

    var from: Endpoint
    var to: Endpoint
    /// The other account had its own conversation, so the context was handed over even though the agent stayed.
    /// Optional so switches saved before it still decode.
    var accountHandoff: Bool? = nil

    /// The session went on under another account of the same agent.
    var accountChanged: Bool {
        guard let before = from.profile, let after = to.profile else { return false }
        return from.provider == to.provider && before != after
    }
    /// Another agent (or another account of it with a conversation of its own) takes over: the context is handed over.
    var handoff: Bool { from.provider != to.provider || from.agent != to.agent || (accountHandoff == true && accountChanged) }
    /// Nothing changed after all (you went back to what it was before sending).
    var isNoChange: Bool { !handoff && !accountChanged && from.sameSetting(to) }
    var modelChanged: Bool { from.model != to.model }
    var effortChanged: Bool { from.effort != to.effort }
}

/// The words of a switch, for search, copy and the handoff summary (the divider draws its own).
enum ModelSwitchText {
    static func side(_ endpoint: ModelSwitch.Endpoint, model: Bool, effort: Bool) -> String {
        [model ? endpoint.model ?? "default" : nil, effort ? endpoint.effort : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// "Claude Code (Work)" when the account changed and has a name, else the agent alone.
    static func agent(_ endpoint: ModelSwitch.Endpoint, accounts: Bool) -> String {
        guard accounts, let account = endpoint.account, !account.isEmpty else { return endpoint.agent }
        return endpoint.agent + " (" + account + ")"
    }

    static func plain(_ change: ModelSwitch) -> String {
        if change.handoff || change.accountChanged {
            let accounts = change.accountChanged
            return agent(change.from, accounts: accounts) + " " + side(change.from, model: true, effort: change.from.effort != nil)
                + " → " + agent(change.to, accounts: accounts) + " " + side(change.to, model: true, effort: change.to.effort != nil)
        }
        let model = change.modelChanged, effort = change.effortChanged
        return side(change.from, model: model, effort: effort) + " → " + side(change.to, model: model, effort: effort)
    }
}
