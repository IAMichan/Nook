import Foundation
import AppKit

/// A pending permission request from a workspace session awaiting confirmation.
struct PendingPermission: Identifiable, Equatable {
    let id: String
    let runID: UUID
    let tool: String
    let summary: String
    let input: JSONBox
    let suggestions: JSONBox?
    let eventID: UUID
    let created: Date
    /// Why the agent asks, in its own words, and what it says about the request (`PermissionAsk`).
    var ask = PermissionAsk()

    var canAlways: Bool {
        guard !ask.noAlways, let list = suggestions?.object as? [Any] else { return false }
        return !list.isEmpty
    }
}

/// A question from an agent in a session Nook runs (Codex `requestUserInput`, Claude Code's AskUserQuestion).
struct PendingQuestion: Identifiable, Equatable {
    enum Origin: Equatable {
        case codex(RPCID)
        case claude(requestID: String, input: JSONBox)
        /// A Pi extension's dialog (select, input, editor): answered with `extension_ui_response`.
        case pi(requestID: String)
        /// A form OpenCode's server asked (its `question` tool): answered with the form's reply.
        case openCode(OpenCodeForm)
        /// A question the agent asked without waiting for it (Codex's async message): the answer goes as a message.
        case message
        /// Asked before Nook restarted (`RestartRequests`): the process that waited for it is gone, so the answer goes as
        /// a message of yours and resumes the conversation.
        case restored
    }

    let id: String
    let runID: UUID
    let questions: [RunQuestion]
    let origin: Origin
    let created: Date

    /// Nothing waits for this answer: the agent goes on, and the answer reaches it as a message of yours.
    var answersAsMessage: Bool { origin == .message || origin == .restored }
    var isRestored: Bool { origin == .restored }

    /// As it is saved with its session, to show again after a restart.
    var saved: SavedQuestion? { RestartRequests.saved(id: id, questions: questions, created: created) }

    /// A question saved before a restart, back in the session it was asked in.
    init(restoring saved: SavedQuestion, runID: UUID) {
        self.init(id: saved.id, runID: runID, questions: saved.questions, origin: .restored, created: saved.created)
    }

    init(id: String, runID: UUID, questions: [RunQuestion], origin: Origin, created: Date) {
        self.id = id
        self.runID = runID
        self.questions = questions
        self.origin = origin
        self.created = created
    }
}

/// Latest Git snapshot observed by Nook for a session.
struct GitSnapshot: Equatable {
    var status: GitStatus?
    var divergence: (ahead: Int, behind: Int)?
    var error: String?
    var updated: Date
    var loading: Bool

    static func == (lhs: GitSnapshot, rhs: GitSnapshot) -> Bool {
        lhs.status == rhs.status && lhs.divergence?.ahead == rhs.divergence?.ahead
            && lhs.divergence?.behind == rhs.divergence?.behind && lhs.error == rhs.error
            && lhs.updated == rhs.updated && lhs.loading == rhs.loading
    }

    /// The same status, divergence and error: what git said, apart from when and whether it is being read.
    func sameContent(as other: GitSnapshot) -> Bool {
        status == other.status && divergence?.ahead == other.divergence?.ahead
            && divergence?.behind == other.divergence?.behind && error == other.error
    }
}

/// A single row in the worktree overview.
struct WorktreeRow: Identifiable, Equatable {
    var repoRoot: String
    var worktree: GitWorktree
    var runIDs: [UUID]
    var changedFiles: Int?
    var ahead: Int?
    var behind: Int?
    var baseBranch: String?
    /// Disk the worktree takes, its builds included; nil for the main checkout.
    var bytes: Int64?
    var id: String { worktree.path }
}

/// Workspace representation of a project: a directory, with Git metadata if it is a repository.
struct ProjectInfo: Equatable {
    var path: String
    var name: String
    var verdict: WorkspacePathPolicy.Verdict
    var repoRoot: String?
    var currentBranch: String?
    var branches: [String]
    var defaultBase: String?
    var hasCommits: Bool
    var dirtyFiles: Int
    var isWorktree: Bool
}

/// Launches and tracks coding agents in the workspace. The UI interacts solely with this object.
/// One process per turn: a follow-up message resumes the agent with `--resume` (Claude) or `exec resume` (Codex).
/// This ensures no orphaned processes linger, and resuming after relaunching Nook works identically.
@MainActor
final class WorkspaceManager: ObservableObject {
    /// Settable within the module: the stop and handoff extensions settle open work and add forked sessions.
    @Published var runs: [WorkspaceRun] = [] {
        didSet {
            runPositions = nil
            subThreadCounts = nil
        }
    }
    /// Where each session is in `runs`, made again on the first lookup after `runs` changed. Rows, panels and the
    /// handlers of every streamed line look a session up by id, many times per redraw: walking a few hundred sessions
    /// (and copying the one found) each time was a visible share of drawing the Agents list.
    private var runPositions: [UUID: Int]?
    /// How many delegated sub-threads still work under each session (`workingSubThreads(of:)`), made again on the first
    /// read after `runs` changed. `attention` asks it for every finished row on every redraw.
    var subThreadCounts: [UUID: Int]?

    /// The index of session `id` in `runs`; the first one when an id appears twice.
    func runIndex(_ id: UUID) -> Int? {
        if let runPositions { return runPositions[id] }
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(runs.count)
        for (index, run) in runs.enumerated() where positions[run.id] == nil { positions[run.id] = index }
        runPositions = positions
        return positions[id]
    }
    /// Each session's timeline. Not `@Published`: a streaming answer changes it for every token, and a published
    /// dictionary can only be replaced as a whole, which copied the session's entire timeline per token. Changed in place
    /// here, and the views that draw a timeline hear about it through `timelines`, at most every `eventsPublishInterval`
    /// (see `eventsDidChange`).
    var events: [UUID: [RunEvent]] = [:] {
        didSet {
            // A change that does not keep the byte counts right itself: which timeline it touched is not known here.
            if !timelineStore.countingBytes { timelineStore.bytes.forgetAll() }
            eventsDidChange(timelineStore.changing)
        }
    }
    /// What Nook keeps about the timelines besides their events: what is in memory and how big, what was released,
    /// what waits for a read, and the saves still to come (`WorkspaceManager+TimelineStore`).
    var timelineStore = TimelineStore()
    /// Announces a changed timeline. Apart from this manager's own change: a streaming answer changes a timeline up to 20
    /// times a second, and announcing that on the manager redrew every view that observes it (the session's frame, its
    /// side panels, git buttons, usage badges), which only read the sessions and not what they say.
    let timelines = TimelineChanges()
    /// The same per session: a view that draws one session's timeline observes only its own (`timelineChanges(for:)`), so
    /// five agents streaming elsewhere do not redraw the session you are reading twenty times a second each.
    var sessionTimelines: [UUID: TimelineChanges] = [:]

    /// What tells the views of session `id` that its timeline changed.
    func timelineChanges(for id: UUID) -> TimelineChanges {
        if let known = sessionTimelines[id] { return known }
        let made = TimelineChanges()
        sessionTimelines[id] = made
        return made
    }
    /// Settable within the module: the Codex app-server extension adds and answers requests too.
    @Published var approvals: [UUID: [PendingPermission]] = [:] {
        didSet { waitingChanged(approvals.keys, oldValue.keys) }
    }
    /// Follow-up messages typed while the agent was working; the first goes out as soon as the turn has ended.
    @Published private(set) var queued: [UUID: MessageQueue] = [:] {
        // Saved with the session list, so a restart keeps it (`RestartRequests`).
        didSet { if runsLoaded { scheduleSave() } }
    }
    /// Sessions whose next message of yours starts a new conversation (`/clear`, see `FreshConversation`). In memory only,
    /// as a draft is: "Keep this conversation" takes it back.
    @Published var freshArmed: Set<UUID> = []
    /// Questions an agent asked in a session and that wait for your answer.
    @Published var questions: [UUID: [PendingQuestion]] = [:] {
        didSet { waitingChanged(questions.keys, oldValue.keys) }
    }
    /// Connectors (MCP servers) each session's agent has but cannot use until you sign in (see ConnectorSignIn).
    @Published var connectorSignIns: [UUID: [ConnectorSignIn]] = [:]
    /// Sessions whose title is being written again on request (`regenerateTitle`): a second request waits for the first.
    /// Not published: nothing draws it.
    var regeneratingTitles: Set<UUID> = []
    /// The message you will likely send next, per session, shown as ghost text in its empty composer
    /// (`NextPromptSuggestion`, WorkspaceManager+NextPrompt).
    @Published var nextPrompts: [UUID: NextPromptState] = [:]
    /// The request writing a session's suggestion; cancelled when you type or a turn starts.
    var nextPromptTasks: [UUID: Task<Void, Never>] = [:]

    /// Codex sessions over `codex app-server` (see WorkspaceManager+CodexServer), kept alive between turns.
    var codexServers: [UUID: CodexAppServerClient] = [:]
    /// Codex executables without a usable app-server: their sessions use `codex exec`.
    var codexExecOnly: Set<String> = []
    /// Codex approval requests waiting for you, by Nook's request id.
    var codexRequests: [String: CodexApprovalRequest] = [:]
    /// The latest token totals per Codex session, so a turn's own usage is the difference.
    var codexTotals: [UUID: TokenCounts] = [:]
    var codexIdleClose: [UUID: Task<Void, Never>] = [:]
    /// Claude Code processes kept alive after a turn: the next message goes to the same process, as long
    /// as model, mode and rights are unchanged. With the settings they were started with, and when they close.
    var claudeIdle: [UUID: (process: AgentProcess, key: String)] = [:]
    var claudeIdleClose: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose end-of-turn snapshot is still being made (see captureCheckpoint).
    var checkpointing: Set<UUID> = []
    /// ACP sessions (Gemini CLI, OpenCode, Cursor, Grok), kept alive between turns; their permission requests waiting
    /// for you; and Gemini executables that do not speak ACP (they use the headless mode).
    var acpClients: [UUID: AcpClient] = [:]
    var acpRequests: [String: (rpcID: RPCID, options: [AcpPermissionOption], call: AcpToolCall)] = [:]
    var acpFallback: Set<String> = []
    var acpIdleClose: [UUID: Task<Void, Never>] = [:]
    /// OpenCode over its own server (`WorkspaceManager+OpenCodeServer`): the servers by account, each session's place on
    /// one, its idle close, the permission requests waiting for you, servers stopping for lack of sessions, and OpenCode
    /// executables that run over ACP (no server Nook speaks, or it did not start).
    var openCodeHosts: [String: OpenCodeServerHost] = [:]
    var openCodeLinks: [UUID: OpenCodeLink] = [:]
    var openCodeIdleClose: [UUID: Task<Void, Never>] = [:]
    var openCodeRequests: [String: (runID: UUID, permission: OpenCodePermission)] = [:]
    var openCodeHostStops: [String: Task<Void, Never>] = [:]
    var openCodeFallback: Set<String> = []
    /// ACP: what the agent sent after its turn ended, until it shows it is really working again (see wakeAcp).
    var acpWakeBuffer: [UUID: [AcpEvent]] = [:]
    /// ACP: the conversation a loaded session replays into a timeline that has none yet (a session the agent listed).
    var acpReplays: [UUID: AcpReplay] = [:]
    /// ACP: ends a turn the agent started by itself, once it has been quiet for a moment.
    var acpWakeFinish: [UUID: Task<Void, Never>] = [:]
    /// Sessions with work still running in the background: they stay open longer between turns (see BackgroundWork).
    var backgroundWork: Set<UUID> = []
    /// Kept agents whose output is read again after a crash of Nook (`KeptRuns.Replay`): events already in the timeline
    /// are not shown twice.
    var keptReplays: [UUID: KeptRuns.Replay] = [:]
    /// Sessions whose latest wake turn ended while a monitor still runs: its completion waits for the monitor
    /// (`WakeCompletion`), so you are told once instead of for every line the monitor printed.
    var heldWakeCompletions: Set<UUID> = []
    /// Sessions whose turn ended while their subagents or commands still work in the background: the list keeps showing
    /// them as working. Published, unlike the timelines it comes from: a list row has to change when the last one ends.
    @Published var subagentsWorking: Set<UUID> = []
    /// The line the next wake of a parked Claude Code shows, naming the subagent or command whose end it is for.
    var wakeLine: [UUID: String] = [:]
    /// What MCP apps want the agent to know on its next turn, per session and app (see McpApp).
    var mcpAppContexts: [UUID: [String: String]] = [:]
    /// Control requests sent to Claude Code that wait for its answer, by request id.
    var claudeControlReplies: [String: (JSONBox?, String?) -> Void] = [:]
    /// Checks back on connectors whose sign-in page is open, per session and connector.
    var connectorSignInChecks: [UUID: [String: Task<Void, Never>]] = [:]
    /// Claude Code reported a change in its limits during a session: AppModel refreshes the usage shown.
    var onRateLimits: (() -> Void)?
    /// Codex reported new limits during a session (the `account/rateLimits/updated` params), for the account
    /// (`AgentProfile.id`) the session runs with: they show right away.
    var onCodexRateLimits: ((JSONBox, String) -> Void)?
    /// A turn stopped on a usage limit: the limits shown are read again now, so they say why.
    var onLimitReached: (() -> Void)?
    /// When the account of this session is free again by its own limits (`QuotaService`), for a turn that did not say.
    var limitResetHint: ((WorkspaceRun) -> Date?)?
    /// Claude Code reported how full a subscription window is, for the account (`AgentProfile.id`) the session runs with.
    var onPlanWindow: ((UsageLimits.PlanReading, String) -> Void)?
    @Published var git: [UUID: GitSnapshot] = [:]
    @Published var worktreeRows: [WorktreeRow] = []
    @Published var worktreesLoading = false
    /// Whether a Worktrees list is on screen (`worktreesShown(_:)`). Its rows are refreshed only then: a removal or a
    /// cleanup with nobody looking walked every worktree and its build (minutes of a core with a hundred of them).
    var worktreesListShown = 0
    /// Read off the main thread by a running refresh, which stops once the list is closed.
    nonisolated let worktreesListOpen = WorktreeListFlag()
    @Published private(set) var gitAvailable: Bool?
    @Published var selectedRunID: UUID?
    /// The models each agent offers itself (Codex `model/list`, ACP sessions); see WorkspaceManager+Models.
    @Published var agentModels: [RunProvider: [AgentModel]] = [:]
    /// The models of each ACP agent you added, by its `AgentProfile.id`: each runs its own command line and models.
    @Published var customAgentModels: [String: [AgentModel]] = [:]
    /// The thinking levels each ACP agent offers (its "thought_level" config option), by `effortKey`.
    @Published var agentEfforts: [String: [AgentModel]] = [:]
    /// The `/` commands each ACP session announced (`available_commands_update`).
    @Published var acpCommands: [UUID: [AgentSlashCommand]] = [:]
    /// What fills each session's context window, as its agent last said it (`refreshContextUsage`), with the session's
    /// context size at that moment: an answer from before a later turn is not shown.
    @Published var contextUsages: [UUID: (usage: ContextUsage, contextTokens: Int?)] = [:]
    /// Sessions whose agent could not be asked what fills its window (no process runs, or it answered with an error), with
    /// the session's context size then: for that context the breakdown shows the estimate instead of a skeleton that never
    /// fills. A later turn changes the size, so the agent is waited for again.
    @Published var contextBreakdownMissing: [UUID: Int?] = [:]
    /// The open pull request of a session's branch, when GitHub says there is one (for the git button).
    @Published var openPullRequests: [UUID: URL] = [:]
    /// The same for sessions Nook only sees, by repository root.
    @Published var folderPullRequests: [String: URL] = [:]
    /// The git action the button is carrying out, by session (its id) or, for one Nook only sees, repository root: the
    /// tray above the composer and the session panel show its step until it is done, also when the panel was closed.
    @Published var quickGitProgress: [String: QuickGitProgress] = [:]
    /// GitHub through Nook's connector, configured by AppModel: the open pull request of a branch (and whether an earlier
    /// one was merged or closed), and opening one (nil while GitHub is not connected: the git button then opens GitHub's
    /// compare page with title and description filled in).
    var pullRequestLookup: ((_ repo: RemoteRepository, _ branch: String) async -> (open: URL?, landed: Bool))?
    var pullRequestCreate: ((_ repo: RemoteRepository, _ title: String, _ body: String, _ head: String, _ base: String) async throws -> URL?)?
    /// A session made a pull request (the agent's own `gh`, or one found on its branch after GitHub's page opened): it
    /// opens in the side panel.
    var pullRequestCreated: ((_ run: UUID?, _ url: URL) -> Void)?
    /// A watched pull request as it is now (GitHub, with your connected accounts).
    var pullRequestSnapshot: ((URL) async -> PullRequestSnapshot?)?
    /// The host's change feed of a watched pull request (GitHub's event stream): emits when it may have changed and once
    /// per (re)connect; nil where the host offers none. Set by AppModel.
    var pullRequestEvents: ((URL) -> AsyncStream<Void>?)?
    /// The pull request watches being read, their change feeds, and the link each session's last turn ended with
    /// (`WorkspaceManager+PullRequestWatch`).
    var pullRequestWatcher = PullRequestWatcher()
    /// Sessions whose queue waits for a fresh look at a pull request before its next message goes out.
    var queueLooks: Set<UUID> = []
    /// Codex's subagents per session: the thread each runs on, and the timeline event that stands for it.
    var codexSubagents: [UUID: [String: UUID]] = [:]
    /// Comments on a session's diff, waiting to go to the agent together.
    @Published var reviewComments: [UUID: [ReviewComment]] = [:]
    var modelsRefreshed: [String: Date] = [:]
    /// When each agent account was last asked for its sessions (see `listAgentSessions`).
    var sessionsListed: [String: Date] = [:]
    /// The model manifest in use: the bundled one, or a newer valid copy from Nook's repository (see
    /// WorkspaceManager+ModelManifest).
    @Published var modelManifest: ModelManifest?
    /// What `claude --version` and `codex --version` printed, for the models that need a newer agent.
    @Published var agentVersions: [RunProvider: String] = [:]
    /// Nook is quitting (`shutdown()` ran): agents are being stopped and nothing new starts.
    private(set) var quitting = false
    /// When the repository was last asked for the manifest, and when each agent's version was read (with its path).
    var manifestAttempted: Date?
    /// The model list of each agent (see `modelMenu`), by `effortKey`.
    var modelChoiceMemo: [String: ModelChoiceMemo] = [:]
    var versionsRead: [RunProvider: (path: String, at: Date)] = [:]
    /// Sessions waiting for a usage limit to reset, to go on then; and Codex's latest limits per session.
    var limitResumes: [UUID: Task<Void, Never>] = [:]
    var codexLimitSnapshots: [UUID: JSONBox] = [:]
    /// The turn that just ended stopped on a usage limit, with its reset when known. Kept apart from the turn state,
    /// which some paths clear before the end of the turn is handled.
    var limitedTurns: [UUID: Date?] = [:]
    /// Whether a Claude Code executable knows `--thinking-display` (asked once with `--help`, in the background).
    var claudeThinkingDisplay: [String: Bool] = [:]
    /// Whether a Claude Code knows `--prompt-suggestions` (from the same probe).
    var claudePromptSuggestionFlag: [String: Bool] = [:]
    /// The summary Nook sends a long idle session before its prompt cache expires, per session (`IdleCompaction`).
    var idleCompactionTimers: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose running turn is such a summary: it ends quietly, without a notification or a snapshot.
    var idleCompacting: Set<UUID> = []
    /// Sessions where you chose Keep on the "compact first" chip (`ReturnCompaction`): your next message goes with the
    /// whole history. Cleared once it went out.
    @Published var keepsHistory: Set<UUID> = []
    /// Claude Code's `autoCompactWindow` per settings folder and model, read at most once a minute (`AutoCompactMark`).
    var claudeCompactWindows: [String: (window: Int?, read: Date)] = [:]
    /// The part of `idleCompacting` that Nook started because the context grew past your limit (`SizeCompaction`).
    var sizeCompacting: Set<UUID> = []
    /// A message sent while the session was still warming up: it goes out as soon as the connection is open.
    var warmPrompts: [UUID: String] = [:]
    /// A message you sent while the previous turn's snapshot was still being made: shown at once, sent right after it.
    var awaitingCheckpoint: [UUID: String] = [:]
    /// A queued message sent right away while a turn was active: sent as soon as that turn ends.
    var pendingSendNow: [UUID: String] = [:]
    /// How the message in `pendingSendNow` came to interrupt the turn: it is marked so in the timeline once it goes out.
    var pendingSendNowSteer: [UUID: RunEvent.SteerKind] = [:]
    /// The message in `pendingSendNow` starts a new conversation (`/clear`).
    var pendingSendNowFresh: Set<UUID> = []
    /// Where the message in `pendingSendNow` comes from, when that is not you (`QueuedMessage.Origin`).
    var pendingSendNowOrigin: [UUID: QueuedMessage.Origin] = [:]
    /// When the work now going on began (`TurnTimer`): a new prompt sets it, the agent carrying on by itself keeps it.
    var workStartedAt: [UUID: Date] = [:]
    /// The turn about to start carries on the agent's own work (`TurnTimer`); taken by the turn's start.
    var continuingTurns: Set<UUID> = []
    /// The words of the turn that went out last, to send them again in a new conversation when the agent lost the old one or
    /// it no longer fits (`recoverConversation`).
    var turnPrompts: [UUID: String] = [:]
    /// Sessions whose running turn is that second try: when it fails too, it fails as it is.
    var recoveringConversation: Set<UUID> = []
    /// The worktree an agent made with `git worktree add` during its turn, which the session may follow at the turn's end
    /// (`followAddedWorktree`).
    var addedWorktrees: [UUID: String] = [:]
    /// A goal Codex takes with the turn that is starting, and a goal control that waits for the connection (`SessionGoals`).
    /// $HOME per machine where Nook's MCP server is in place, and each remote session's proof (see `RemoteBridge`).
    var remoteHomes: [String: String] = [:]
    var remoteBridgeInstalling: Set<String> = []
    var bridgeTokens: [UUID: String] = [:]
    /// Where each local session's token file goes (`BridgeTokenFiles`); tests point it at a folder of their own.
    var bridgeTokenDirectory: URL = NookPaths.bridgeTokenDirectory
    /// Receipts of session commands that may come more than once (`SessionCommandReceipts`), kept across a restart.
    lazy var commandReceipts = SessionCommandReceipts.load(from: commandReceiptsURL)
    var commandReceiptsURL: URL = NookPaths.supportDirectory.appendingPathComponent("command-receipts.json")
    var codexGoalStarting: [UUID: SessionGoalCommand] = [:]
    var codexGoalWaiting: [UUID: SessionGoalCommand] = [:]
    /// When GitHub was last asked about a branch's pull request ("owner/repo branch"), so it is asked once a minute at most.
    var pullRequestChecked: [String: Date] = [:]
    /// The pull request links Nook has seen in a conversation: the first sight of one is asked about at once.
    var linkedPullRequests: Set<URL> = []
    /// The open pull request those lookups found, by the same key, so every view of a branch gets the same answer.
    var pullRequestOpen: [String: URL] = [:]
    /// Branches ("owner/repo branch") whose pull request was merged or closed, from the same lookups.
    var pullRequestLanded: Set<String> = []
    /// Sessions whose Antigravity sign-in page already opened.
    var antigravitySignIns: Set<UUID> = []
    /// Antigravity sign-ins outside a session (when you link the account), per account: the server and what to call when done.
    var antigravityLogins: [String: (client: AcpClient, done: (String?) -> Void)] = [:]

    let settings = WorkspaceSettings.shared
    let store: RunStore
    private(set) var gitService: GitService?

    /// Agent executable path (from AgentHistory) and account environment; configured by AppModel.
    var executable: (RunProvider) -> String? = { _ in nil }
    var accountEnvironment: (String) -> [String: String] = { _ in [:] }
    /// The program an account runs instead of the agent's (Settings › Agents › account › Program), by profile id.
    var accountExecutable: (String) -> String? = { _ in nil }
    /// Arguments an account adds to every launch (Settings › Agents › account › Extra arguments), by profile id.
    var accountArguments: (String) -> [String] = { _ in [] }
    /// Models an account adds to its menus (Settings › Agents › account › Custom models), by profile id.
    var accountModels: (String) -> [String] = { _ in [] }

    /// The program for an agent under an account: the one that account names, else the agent's.
    func executable(_ provider: RunProvider, profileID: String?) -> String? {
        if let profileID, !profileID.isEmpty, let own = accountExecutable(profileID) { return own }
        return executable(provider)
    }
    /// The folder an account keeps its login in; two accounts with the same folder share conversations.
    var accountHome: (String) -> String? = { $0 }
    /// An account's name as Nook shows it ("Work"), by profile id; nil when it is unknown. Configured by AppModel.
    var accountName: (String) -> String? = { _ in nil }
    /// The usage windows of an account, for "Auto" to pick a model by (see `AutoModel`); configured by AppModel.
    var usageWindows: (String) -> [AutoModel.Window] = { _ in [] }
    /// The connected agents with their accounts, for "Auto" to pick among (see `AutoModel`); configured by AppModel.
    var autoAccounts: () -> [AutoModel.Account] = { [] }
    /// Runs a project script in a visible terminal (folder, command, title); configured by AppModel. Returns whether that
    /// terminal is still open, asked while a setup script holds the agent.
    var runScript: ((String, String, String) -> @MainActor () -> Bool)?
    /// Nook's workspace bridge for the agent's command line; nil when agents may not use it.
    var bridgeLaunch: () -> BridgeLaunch? = { nil }
    /// A session is waiting for approval or has finished: AppModel displays it in the notch.
    var onApproval: ((WorkspaceRun, PendingPermission) -> Void)?
    /// An Antigravity session signed in: AppModel reads the account's limits again.
    var onAntigravitySignedIn: (() -> Void)?
    var onApprovalGone: ((String) -> Void)?
    /// A session asks you a question (Codex requestUserInput, Claude Code AskUserQuestion).
    var onQuestion: ((WorkspaceRun, PendingQuestion) -> Void)?
    var onTurnFinished: ((WorkspaceRun) -> Void)?
    /// The week recap: sessions Nook runs itself count too, not only the ones in a terminal.
    var recap: RecapStore?

    /// Turns waiting for a free place (`SessionCapacity`), first come first served (`WorkspaceManager+Capacity`).
    var capacity = CapacityScheduler()
    var processes: [UUID: AgentProcess] = [:]
    var turns: [UUID: TurnState] = [:]
    /// Git reads in flight and what they keep between reads (`WorkspaceManager+Git`).
    var gitRefresh = GitRefreshState()
    /// Sessions whose next turn starts as a copy of the conversation (`--fork-session`), so the original keeps going untouched.
    var forkNext: Set<UUID> = []
    /// Sessions whose running turn is an independent copy (`forkNext` at launch): the id the agent reports is a new
    /// conversation, not a continuation, so the source's id is not an earlier id of it.
    var forkLaunched: Set<UUID> = []
    /// Whether an ACP agent copies its own sessions (`AcpSessionCapabilities.fork`), as its last `initialize` said, by
    /// `acpAgentKey`: Fork and side chats then keep the conversation (`forksNatively`).
    var acpForks: [String: Bool] = [:]
    /// The terminal sign-in of an agent you added whose session needed you to sign in (by `profileID`): its failed turn
    /// offers "Sign in again", which runs it (`signInAcpInTerminal`).
    @Published var acpTerminalSignIns: [String: AcpAuthMethod] = [:]
    /// Sessions whose settings changed during a turn: their Claude Code process is not reused afterwards, so the next turn
    /// surely starts with the new flags, even when this Claude Code could not take them over live.
    var claudeChangedDuringTurn: Set<UUID> = []
    /// What you typed, for a turn whose prompt starts with a handoff summary (the timeline shows your words only).
    var displayPrompt: [UUID: String] = [:]
    /// Stop in progress per session (see WorkspaceManager+Stop), the approvals you gave "for this session" (Codex only
    /// remembers the exact command, so Nook keeps its own), and the background work an agent still has running.
    var stopCoordinators: [UUID: StopCoordinator] = [:]
    /// Worktree or remote preparation still running before the first turn starts; cancelled if you press Stop.
    var prepareTasks: [UUID: Task<Void, Never>] = [:]
    /// A new worktree's steps (fetch, check out, setup script, agent) while it is being set up, shown as a checklist in
    /// the conversation; gone once the agent answers (see WorkspaceManager+WorktreeSetup).
    @Published var worktreeSetups: [UUID: WorktreeSetupProgress] = [:]
    /// Sessions whose removed worktree is being made again for a message (see `reopenWorktree`).
    var reopeningWorktrees: Set<UUID> = []
    /// Last inspected project metadata per normalized folder, so opening "New Session" or starting is instant.
    var projectCache: [String: ProjectInfo] = [:]
    /// When a repository's remote-tracking base (`repo\nbase`) was last fetched, so starting does not fetch again right away.
    var remoteBaseRefreshed: [String: Date] = [:]
    /// Next checkpoint index per session, claimed before async git work so concurrent checkpoints never share an index.
    var checkpointIndices: [UUID: Int] = [:]
    /// When the worktree cleanup rules last looked (see WorkspaceManager+WorktreeCleanup).
    var worktreeCleanupAt: Date?
    /// What the latest cleanup did (Settings › Workspace), kept across restarts.
    @Published var worktreeCleanupReport: WorktreeCleanupReport? = WorktreeCleanupReport.load()
    /// A cleanup runs now (by the clock or "Clean up now").
    @Published var worktreeCleanupRunning = false
    /// The folders terminals in Nook are open in; configured by AppModel. A worktree with one stays.
    var openTerminalFolders: (() -> [String])?
    var buildLeftoversAt: Date?
    /// When the free disk space was last read, and whether it counted as low then (see `watchDiskSpace`).
    var diskSpaceCheckedAt: Date?
    var diskSpaceLow = false
    /// The startup disk runs low: free bytes after Nook freed what it could, the bytes it freed, and what Nook's
    /// worktrees take; configured by AppModel.
    var onLowDiskSpace: ((Int64, Int64, Int64?) -> Void)?
    /// Opens a terminal in Nook's own window (set by the app). Used when the built-in terminal is chosen.
    var openBuiltInTerminal: ((_ folder: String) -> Void)?
    /// Writes an entry to the audit log (tool, arguments, result); configured by AppModel.
    var onAudit: ((String, String, String) -> Void)?
    var sessionApprovals: [UUID: SessionApprovals] = [:]
    var backgroundRoster: [UUID: BackgroundRoster] = [:]

    /// State tracked by Nook during a single turn.
    struct TurnState {
        /// The turn's open answer, thought and tool calls (see AgentTimeline).
        var timeline = AgentTimeline()
        var messageUsage: [String: TokenCounts] = [:]
        var lastContext: Int?
        var finished = false
        var stopping = false
        var lastError: String?
        var started = Date()
        /// Which turn this is, as the phone sees it (`SessionDigest.turn`): a command meant for this turn leaves a later
        /// one alone (`SessionTurnCheck`).
        var identity = UUID().uuidString.lowercased()
        /// codex app-server: token totals when the turn started.
        var codexBaseline: TokenCounts?
        var contextWindow: Int?
        /// Claude Code: Nook asked for the window during the turn (`askContextWindowIfUnknown`).
        var windowAsked = false
        /// Pi: tokens and cost of the turn so far, and when its older end-of-run event came (see `handlePi`).
        var piUsage = TurnUsage()
        var piEndedAt: Date?
        /// ACP: the session's cost so far, as the agent reports it.
        var acpCost: Double?
        /// ACP: whether the agent wrote any text this turn, its tool calls, and how often Nook asked it to carry on.
        var acpReplied = false
        var acpToolCalls = 0
        var acpContinuations = 0
        /// ACP: what the agent thought this turn, kept for a turn whose only words went into its thinking.
        var acpThought = ""
        /// ACP: file reads still open, settled once the agent moves on (see AcpOpenReads).
        var acpOpenReads = AcpOpenReads()
        /// Claude Code: a steering message went in, so a result that says "aborted" ends a segment, not the turn.
        var steered = false
        var steeredUsage: [TurnUsage] = []
        /// Claude Code's blocked usage-limit windows during the turn, with their reset if known.
        var limitWindows: [String: Date?] = [:]
        /// A turn the agent started by itself after background work, with no message of yours to answer.
        var unprompted = false
        /// Claude Code: when the turn's latest request started, the cache lifetime it reported, and whether the
        /// conversation was compacted during the turn (see `PromptCacheWindow`).
        var lastRequestAt: Date?
        var cacheTTL: TimeInterval?
        var compacted = false
    }

    init(store: RunStore = RunStore(directory: NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true))) {
        self.store = store
        // Agents' process groups are written down; the ones a crashed Nook left behind are stopped.
        ProcessGroupLedger.install()
        agentModels = AgentModelStore(url: Self.modelStoreURL).load()
        customAgentModels = AgentModelStore(url: Self.customModelStoreURL).loadRaw()
        agentEfforts = AgentModelStore(url: Self.effortStoreURL).loadRaw()
        modelManifest = ModelManifest.preferred(bundled: .bundled(), cached: ModelManifestStore(url: Self.manifestStoreURL).load())
        ModelRates.use(modelManifest)
        // The session list can be long: read it off the main thread so launching Nook does not wait for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = store.loadRuns()
            await self?.finishLoadingRuns(loaded)
        }
        // Watched pull requests are looked at every half minute (each at most every two minutes). Away from the Mac or
        // saving power the tick comes less often, as `PullRequestSync`'s.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30) * EnergyMonitor.shared.plan.slowdown)
                guard let self else { return }
                self.checkPullRequestWatches()
                self.applyWorktreeCleanup()
                // Opt-in per project; no project with it on costs nothing.
                self.autoPullDefaultBranches()
                self.sweepBuildLeftovers()
                self.watchDiskSpace()
                // Otherwise only opening another session frees one: sessions finish, and their timelines stay.
                self.evictTimelines()
            }
        }
        Task.detached(priority: .utility) {
            let service = GitService.shared
            await MainActor.run { [weak self] in
                self?.gitService = service
                self?.gitAvailable = service != nil
            }
        }
    }

    /// The saved sessions have been read. Until then the session list is never written, so it cannot be replaced.
    private(set) var runsLoaded = false

    private func finishLoadingRuns(_ loaded: [WorkspaceRun]) {
        var loaded = loaded
        // Sessions taken over before agents' tags were left out of titles were called "<task-notification>" and the like.
        for index in loaded.indices where loaded[index].title.hasPrefix("<") {
            let clean = InjectedPrompt.title(loaded[index].title)
            loaded[index].title = clean.isEmpty ? loaded[index].projectName : clean
        }
        // Sessions started in the meantime stay in front of the saved ones.
        let started = runs
        let known = Set(started.map(\.id))
        loaded.removeAll { known.contains($0.id) }
        // What waited on you (questions, approvals, queued messages) comes back once the sessions are in place.
        let waiting = RestartRequests.take(&loaded)
        runs = started + loaded
        runsLoaded = true
        applyAutoArchive()
        // Sessions that were waiting for a usage limit to reset go on waiting.
        for run in loaded where run.autoResume == true { armLimitResume(run.id) }
        reattachKeptRuns()
        restoreWaiting(waiting)
        // Guest links that still work connect again (within their 24 hours).
        GuestShares.shared.start(workspace: self)
        if !started.isEmpty { scheduleSave() }
    }

    // MARK: Reading

    func run(_ id: UUID?) -> WorkspaceRun? {
        guard let id, let index = runIndex(id) else { return nil }
        return runs[index]
    }

    var activeRuns: [WorkspaceRun] { runs.filter { $0.status.isActive } }
    var attentionCount: Int { runs.count(where: { ($0.status == .waitingApproval || $0.status == .failed) && !$0.archived }) }
    func isRunning(_ id: UUID) -> Bool { processes[id] != nil }

    /// Other active sessions working in the same directory: concurrent edits could collide.
    func activeRuns(sharing directory: String, except id: UUID? = nil) -> [WorkspaceRun] {
        let target = WorkspacePathPolicy.normalize(directory)
        return runs.filter { $0.id != id && $0.status.isActive && WorkspacePathPolicy.normalize($0.workingDirectory) == target }
    }

    // MARK: Turns

    /// Follow-up message. Permitted only when prior turn has finished; concurrent processes for the same session are prevented.
    @discardableResult
    func send(_ id: UUID, text: String, origin: QueuedMessage.Origin? = nil) -> Bool {
        send(id, text: text, shown: false, origin: origin)
    }

    /// A message from Nook rather than from you (the result of background work): it goes to the agent without a bubble
    /// of yours in the timeline.
    @discardableResult
    func sendHidden(_ id: UUID, text: String, origin: QueuedMessage.Origin? = nil) -> Bool {
        send(id, text: text, shown: true, origin: origin)
    }

    /// Sends the message you asked to go out right away once the turn ended; if it cannot go out now it waits
    /// first in the queue. False when nothing was waiting.
    @discardableResult
    func sendPendingNow(_ id: UUID) -> Bool {
        guard let next = pendingSendNow.removeValue(forKey: id) else { return false }
        let mark = pendingSendNowSteer.removeValue(forKey: id)
        let fresh = pendingSendNowFresh.remove(id) != nil
        let origin = pendingSendNowOrigin.removeValue(forKey: id)
        // A new conversation starts only between turns; while the snapshot is still being made it waits at the front.
        if fresh, !clearConversation(id, quietly: true) {
            queued[id, default: MessageQueue()].requeueFirst(next, fresh: true)
            return true
        }
        let before = timeline(id).last { $0.kind == .user }?.id
        if !send(id, text: next, shown: false, origin: origin) {
            queued[id, default: MessageQueue()].requeueFirst(next, fresh: fresh)
        } else if let mark, let sent = timeline(id).last(where: { $0.kind == .user }), sent.id != before {
            // It cut the turn off to go out: it reads as a steer, as a message taken into the turn does.
            mutateEvent(id, sent.id) { $0.steer = mark }
        }
        return true
    }

    /// Where the working timer of the turn starting now begins (`TurnTimer`). `continuing`: the agent carries on by itself
    /// (a wake for background work); otherwise whatever started the turn says so (`continuingTurns`, set by `send`). Every
    /// agent's turn start and wake goes through here.
    func turnStart(_ id: UUID, continuing: Bool = false) -> Date {
        let continuing = continuingTurns.remove(id) != nil || continuing
        let start = TurnTimer.start(continuing: continuing, previous: workStartedAt[id])
        workStartedAt[id] = start
        if NookTelemetry.shared.isExporting, let usage = run(id)?.usage { NookTelemetry.shared.turnStarted(id, usage: usage) }
        return start
    }

    /// Whether this turn goes to Codex over app-server (rather than `codex exec`, or another agent).
    func usesCodexServer(_ run: WorkspaceRun, _ executable: String) -> Bool {
        switch run.provider {
        case .codex: return settings.codexAppServer && !codexExecOnly.contains(executable)
        case .claude, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp: return false
        }
    }

    /// False when the message could not be taken (empty, the session cannot continue, or a turn is running).
    /// `origin`: who the message comes from when not you (`QueuedMessage.Origin`): whether the delegating parent hears of
    /// the turn it starts, and whether the working timer keeps the start of the work it carries on.
    @discardableResult
    private func send(_ id: UUID, text: String, shown: Bool, origin: QueuedMessage.Origin? = nil) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var run = run(id) else { return false }
        // Only for the turn this call starts: the mark never lingers for a later message of yours.
        if QueuedMessage.Origin.continuesWork(origin) { continuingTurns.insert(id) }
        defer { continuingTurns.remove(id) }
        // Anything but Nook's own summary ends a summary that never reported back (it failed to start, or stopped).
        let idleSummary = shown && clean == "/compact" && idleCompacting.contains(id)
        if !idleSummary {
            idleCompacting.remove(id)
            sizeCompacting.remove(id)
        }
        // You carry on yourself: whatever waited behind a failure or a stop goes on after this turn.
        if var held = queued[id], held.isHeld { held.resume(); queued[id] = held }
        // Its worktree is being made again for an earlier message: this one follows that turn.
        if reopeningWorktrees.contains(id) {
            enqueue(id, text: clean, origin: origin)
            return true
        }
        // Its timeline is read back for a message of yours whose turn starts right after: yours waits behind it, and a
        // hidden one is refused as it is while a turn runs (`processes` below), so its caller cleans up.
        if timelineStore.readingToSend.contains(id) {
            guard !shown else { return false }
            enqueue(id, text: clean, origin: origin)
            return true
        }
        if checkpointing.contains(id), awaitingCheckpoint[id] != nil {
            enqueue(id, text: clean, origin: origin)
            return true
        }
        guard run.canContinue || (shown && run.status == .preparing), processes[id] == nil else { return false }
        // A turn starts: a delegated task tells its parent again when it ends (`Origin.rearmsParent`). Not for Nook's
        // quiet summary, which reports to nobody.
        if !idleSummary, QueuedMessage.Origin.rearmsParent(origin) { rearmDelegation(id) }
        // "Auto" may move the session to another agent or account first (see `autoMove`); Nook's summary of an idle
        // session stays with the conversation it summarizes.
        if !idleSummary { autoMove(id, prompt: clean) }
        if let moved = self.run(id) { run = moved }
        guard let executable = launchExecutable(run) else {
            update(id) { $0.statusDetail = StartError.noExecutable(run.provider).errorDescription }
            return false
        }
        // Its worktree was removed (the pull request merged, the session settled, or by hand): it comes back first.
        if needsWorktreeReopen(run) {
            reopenWorktree(id, message: clean, shown: shown)
            return true
        }
        // A folder on another machine cannot be checked from here; ssh and the agent there report what is wrong.
        guard run.isRemote || WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else {
            append(id, RunEvent(kind: .error, text: tr("ws.error.folderGone", run.workingDirectory)))
            return false
        }
        // Its timeline was released while the session sat idle: it is read back off the main thread (a long one took the
        // main thread with it), and the turn starts once it is here. A message meanwhile waits in the queue behind it.
        // Only for a message you see: a hidden one (Nook's summary, a recovery, a notice) reads it here as before, so its
        // caller still hears false when it cannot go out and cleans up after it.
        if events[id] == nil, !shown {
            timelineStore.readingToSend.insert(id)
            let continues = QueuedMessage.Origin.continuesWork(origin)
            whenTimelineLoaded(id) { [weak self] in
                guard let self, self.timelineStore.readingToSend.remove(id) != nil, let run = self.run(id) else { return }
                // A turn started meanwhile: the message goes after it, as it would have had it come a moment later.
                guard self.processes[id] == nil else {
                    self.enqueue(id, text: clean, origin: origin)
                    return
                }
                if continues { self.continuingTurns.insert(id) }
                defer { self.continuingTurns.remove(id) }
                self.startTurn(id, sending: clean, shown: shown, run: run, executable: executable)
            }
            return true
        }
        return startTurn(id, sending: clean, shown: shown, run: run, executable: executable)
    }

    /// The end of `send`, once the timeline is in memory: the turn for the message `clean` starts.
    @discardableResult
    private func startTurn(_ id: UUID, sending clean: String, shown: Bool, run: WorkspaceRun, executable: String) -> Bool {
        // The previous turn's snapshot is still being made (a moment): your message shows at once, the session enters
        // its working state immediately, and the turn goes out right after the snapshot so its edits stay out of it.
        if checkpointing.contains(id) {
            loadTimeline(id)
            if !shown { append(id, RunEvent(kind: .user, text: shownMessage(id, clean))) }
            awaitingCheckpoint[id] = clean
            update(id) { $0.move(to: .preparing) }
            return true
        }
        loadTimeline(id)
        // Codex takes a goal through calls of its own, not as the words of a turn.
        if !shown, let turn = codexGoalTurn(id, message: clean, executable: executable) {
            guard let prompt = turn else {
                // No turn came of it: what waited behind it goes on.
                sendQueued(id)
                return true
            }
            displayPrompt[id] = clean
            turnPrompts[id] = clean
            launchTurn(id, prompt: ContextHandoff.compose(handoff: run.pendingHandoff, message: prompt), executable: executable, showPrompt: true)
            return true
        }
        // After a fork or a switch of agent the first turn starts with the summary; it stays until a turn ends well.
        // What the timeline shows: your words, without a handoff summary or the context envelope of references.
        let visible = shownMessage(id, clean)
        displayPrompt[id] = run.pendingHandoff == nil && visible == clean ? nil : visible
        // What MCP apps told the agent goes with this turn: Codex over app-server takes it as context of its own, every
        // other agent (Codex over `codex exec` too) ahead of the message.
        let appContext = usesCodexServer(run, executable) ? "" : McpApp.contextPreamble(takeMcpAppContexts(id))
        turnPrompts[id] = clean
        launchTurn(id, prompt: appContext + ContextHandoff.compose(handoff: run.pendingHandoff, message: clean), executable: executable,
                   showPrompt: !shown)
        return true
    }

    /// A turn ended: tell the app, and snapshot the worktree so you can go back to before a later message.
    func turnDidFinish(_ id: UUID) {
        keptTurnEnded(id)
        checkUsageLimit(id)
        guard let run = run(id) else { return }
        NookTelemetry.shared.turnFinished(run)
        // Before open work is settled: what still runs is what keeps the session open.
        if BackgroundWork.pending(after: timeline(id), before: backgroundWork.contains(id)) {
            backgroundWork.insert(id)
        } else {
            backgroundWork.remove(id)
        }
        displayPrompt[id] = nil
        stopCoordinators[id] = nil
        // A command Codex's app-server still runs when its turn completed goes on in the background: its
        // `commandFinished` settles it later (and wakes Codex), so it is not marked done here.
        if run.status == .completed, codexServers[id] != nil {
            for event in timeline(id) where event.kind == .tool && event.tool == "shell" && event.state == .running {
                mutateEvent(id, event.id) { $0.background = true }
            }
        }
        settleOpenWork(id, reason: run.status == .completed ? .completed : (run.status == .stopped ? .stopped : .failed))
        settleSteers(id, dropped: run.status != .completed)
        noteSubagentsWorking(id)
        if run.status == .failed || run.status == .stopped { holdQueue(id) }
        if run.status != .failed { recoveringConversation.remove(id) }
        if run.status == .completed {
            clearContinuations(id)
            if run.pendingHandoff != nil { update(id) { $0.pendingHandoff = nil } }
        }
        // A summary Nook asked for while you were away ends quietly: no notification, no result for a delegating
        // session, and no snapshot (it changed no files). What you sent meanwhile goes on.
        if idleCompacting.remove(id) != nil {
            sizeCompacting.remove(id)
            sendQueued(id)
            return
        }
        // The agent lost this conversation, or it no longer fits: the same words go out once more in a new one, with the
        // timeline so far as its summary (`FreshConversation`). The snapshot comes first, so the new turn waits for it.
        if run.status == .failed, let recovery = conversationRecovery(id, error: run.statusDetail) {
            captureCheckpoint(id)
            recoverConversation(id, recovery)
            return
        }
        // A wake for one line of a monitor that still runs: the alert (and a delegating session's result) waits for the
        // turn after its last line, or for the monitor to end.
        if run.status == .completed, WakeCompletion.holds(timeline(id)) {
            heldWakeCompletions.insert(id)
        } else {
            heldWakeCompletions.remove(id)
            onTurnFinished?(run)
            // Not while a message still waits to go out to it: then it reports after that turn (`sendQueued`).
            deliverDelegatedResult(id)
        }
        captureCheckpoint(id)
        scheduleIdleCompaction(id)
        compactForSize(id)
    }

    /// A snapshot after each turn, for every session in a repository: it shows what each turn changed. Putting files back
    /// stays for sessions in their own worktree (see canRevert): restoring there can never touch your own checkout.
    func captureCheckpoint(_ id: UUID) {
        guard let run = run(id), run.repoRoot != nil, let git = sessionGit(for: run), canSnapshot(run) else { return }
        let directory = run.workingDirectory
        let ref = GitService.checkpointRef(session: id, index: claimCheckpointIndex(id))
        // Dated when the turn ended, before any later message: "before this message" then picks the right snapshot.
        let date = Date()
        // Where the agent's conversation stood: going back here rolls it back too.
        let mark = conversationMark(run)
        let key = folderKey(run)
        checkpointing.insert(id)
        Task { [weak self] in
            // Never while a restore or removal of the same folder runs (FolderLease).
            let made = (try? await FolderLease.shared.run(key) { try git.checkpoint(directory, ref: ref) }) != nil
            self?.recordCheckpoint(id, made ? RunCheckpoint(ref: ref, date: date, conversation: mark) : nil)
        }
    }

    private func recordCheckpoint(_ id: UUID, _ checkpoint: RunCheckpoint?) {
        checkpointing.remove(id)
        if let checkpoint { update(id) { $0.checkpoints = ($0.checkpoints ?? []) + [checkpoint] } }
        if let waiting = awaitingCheckpoint.removeValue(forKey: id) {
            // Shown already: if it cannot go out now, it waits in the queue instead of getting lost.
            if !send(id, text: waiting, shown: true) {
                if run(id)?.status == .preparing { update(id) { $0.move(to: .stopped) } }
                queued[id, default: MessageQueue()].requeueFirst(waiting)
                sendQueued(id)
            }
        } else {
            sendQueued(id)
        }
    }

    /// Files can go back to how they were before a message: a worktree session that is idle, alone in its folder.
    func canRevert(_ id: UUID, before date: Date = .distantFuture) -> Bool {
        guard let run = run(id), run.isolation == .worktree, !run.status.isActive,
              (run.checkpoints ?? []).contains(where: { $0.date <= date }) else { return false }
        return activeRuns(sharing: run.workingDirectory, except: id).isEmpty
    }

    /// Puts the worktree's files back to the last snapshot before `date` (a message of yours). Where the agent can, its
    /// conversation goes back with them (see `rollBackConversation`); otherwise the conversation stays.
    func revertFiles(_ id: UUID, before date: Date) async throws {
        guard canRevert(id, before: date), let run = run(id), let git = sessionGit(for: run),
              let index = run.checkpoints?.lastIndex(where: { $0.date <= date }), let checkpoint = run.checkpoints?[index] else {
            throw StartError.git(tr("ws.revert.unavailable"))
        }
        let directory = run.workingDirectory
        try await FolderLease.shared.run(folderKey(run), priority: .userInitiated) { try git.restore(directory, to: checkpoint.ref) }
        let conversation = rollBackConversation(id, to: checkpoint, index: index)
        append(id, RunEvent(kind: .system, text: tr(conversation ? "ws.revert.doneConversation" : "ws.revert.done")))
        refreshGit(id)
    }

    /// A message you send yourself: it goes out now only when the agent is truly free, otherwise it waits in line.
    /// Busy covers more than a running status: the process of the turn that just ended can still be closing, its
    /// snapshot can still be made, or earlier messages can still be waiting; this one goes behind them. Nothing is
    /// dropped: a message that cannot go out waits in the queue. True when it went out now.
    /// `fromYou`: typed by you (the composer, the phone). Then `/clear` on its own does not go to the agent: it sets your
    /// next message to start a new conversation (`armFreshConversation`), and that message takes it. A message from
    /// another agent, a guest or a schedule never takes your `/clear`. A fresh message (or one with `fresh`) starts the
    /// new conversation right away when the agent is free, otherwise it waits in line marked so and never joins a turn.
    @discardableResult
    func submit(_ id: UUID, text: String, fresh: Bool = false, fromYou: Bool = false, origin: QueuedMessage.Origin? = nil) -> Bool {
        guard let run = run(id) else { return false }
        if fromYou, FreshConversation.isCommand(text) {
            armFreshConversation(id)
            return false
        }
        let fresh = (fromYou && takeFreshArm(id)) || fresh
        let text = fromYou ? withMainThreadNote(id, text) : text
        let waiting = queued[id].map { !$0.isEmpty && !$0.isHeld } ?? false
        let busy = run.status.isActive || processes[id] != nil || checkpointing.contains(id) || waiting
        var cleared = false
        if !busy {
            if fresh { cleared = clearConversation(id, quietly: true) }
            if !fresh || cleared, send(id, text: text, shown: false, origin: origin) { return true }
        }
        enqueue(id, text: text, fresh: fresh && !cleared, origin: origin)
        sendQueued(id)
        return false
    }

    enum Delivery: String, Sendable { case sent, queued, steered, restarted }

    /// A message another agent sends (`session_send`), the way it asks for it: `auto` steers a
    /// running turn the agent can take and otherwise goes as `submit`; `steer` only into the running turn (nil when it
    /// cannot take it); `restart` stops the running turn and goes out right after; `queue` is `submit`. It never takes
    /// your `/clear`, and never cuts into a turn that is starting a new conversation for you.
    /// `origin`: who sends it when that is not you (`DelegatedTask.origin`).
    func deliver(_ id: UUID, text: String, mode: BridgeSessionArguments.SendMode, origin: QueuedMessage.Origin? = nil) -> Delivery? {
        guard let run = run(id) else { return nil }
        let active = run.status.isActive
        switch mode {
        case .queue:
            return submit(id, text: text, origin: origin) ? .sent : .queued
        case .auto:
            if active, canSteer(id), steer(id, text: text) { return .steered }
            return submit(id, text: text, origin: origin) ? .sent : .queued
        case .steer:
            guard active else { return submit(id, text: text, origin: origin) ? .sent : .queued }
            return canSteer(id) && steer(id, text: text) ? .steered : nil
        case .restart:
            guard active else { return submit(id, text: text, origin: origin) ? .sent : .queued }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            // A message already waits to go out when this turn ends (yours, sent now): this one goes after it.
            guard pendingSendNow[id] == nil else {
                enqueue(id, text: clean, origin: origin)
                return .queued
            }
            pendingSendNow[id] = clean
            pendingSendNowSteer[id] = .steer
            pendingSendNowFresh.remove(id)
            pendingSendNowOrigin[id] = origin
            stop(id)
            return .restarted
        }
    }

    /// Puts back a session's queue as it was saved (`restoreWaiting`).
    func setQueue(_ id: UUID, _ queue: MessageQueue) {
        queued[id] = queue.isEmpty ? nil : queue
    }

    /// Keeps a message for when the current turn is done: you keep typing while the agent works.
    func enqueue(_ id: UUID, text: String, pullRequest: PullRequestNotice? = nil, fresh: Bool = false,
                 origin: QueuedMessage.Origin? = nil) {
        guard run(id) != nil else { return }
        var queue = queued[id] ?? MessageQueue()
        queue.enqueue(text, pullRequest: pullRequest, fresh: fresh, origin: origin)
        queued[id] = queue.isEmpty ? nil : queue
    }

    func setQueue(_ queue: MessageQueue, for id: UUID) {
        queued[id] = queue.isEmpty && !queue.isHeld ? nil : queue
    }

    /// A queued message can go out right away: into the running turn, or as a new turn when the agent is idle.
    func canSendQueuedNow(_ id: UUID) -> Bool {
        guard let run = run(id) else { return false }
        if run.status.isActive { return turns[id] != nil }
        return run.canContinue && processes[id] == nil && !checkpointing.contains(id)
    }

    /// Sends one queued message now, ahead of the rest: it steers a running turn, or starts the next turn when the
    /// agent is idle (also after a stop or a failure). It stays queued when it cannot go out.
    func sendQueuedNow(_ id: UUID, message: UUID) {
        guard canSendQueuedNow(id), let run = run(id) else { return }
        let fresh = queued[id]?.isFresh(message) == true
        if run.status.isActive {
            // A new conversation is never taken into the running turn: the turn ends and it goes next.
            if canSteer(id), !fresh {
                guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
                setQueue(queue, for: id)
                if steer(id, text: text, promoted: true) { return }
                queue.requeueFirst(text)
                setQueue(queue, for: id)
            }
            guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
            queue.resume()
            setQueue(queue, for: id)
            pendingSendNow[id] = text
            pendingSendNowSteer[id] = fresh ? nil : .promoted
            pendingSendNowOrigin[id] = nil
            if fresh { pendingSendNowFresh.insert(id) } else { pendingSendNowFresh.remove(id) }
            stop(id)
            return
        }
        guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
        queue.resume()
        setQueue(queue, for: id)
        if fresh, !clearConversation(id, quietly: true) {
            queued[id, default: MessageQueue()].requeueFirst(text, fresh: true)
            return
        }
        if !send(id, text: text, shown: false) { queued[id, default: MessageQueue()].requeueFirst(text, fresh: fresh) }
    }

    /// ⌘Return: a message you send now, past anything waiting in line. It steers a running turn when the agent can take it,
    /// otherwise it goes in front of the queue and out as `sendQueuedNow` sends it (interrupting the turn, or as the next
    /// turn when the agent is idle). It only waits when nothing can go out yet, at the front of the line. False when it waits.
    @discardableResult
    func sendNow(_ id: UUID, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let run = run(id) else { return false }
        if FreshConversation.isCommand(clean) {
            armFreshConversation(id)
            return false
        }
        // After `/clear` it starts a new conversation: right away when the agent is free, otherwise first in line, after
        // the running turn (a new conversation never cuts a turn off).
        let fresh = takeFreshArm(id)
        if fresh, run.status.isActive {
            var queue = queued[id] ?? MessageQueue()
            queue.requeueFirst(clean, fresh: true)
            setQueue(queue, for: id)
            return false
        }
        if !fresh, canSteer(id), steer(id, text: clean) { return true }
        var queue = queued[id] ?? MessageQueue()
        queue.requeueFirst(clean, fresh: fresh)
        setQueue(queue, for: id)
        guard let first = queued[id]?.messages.first, canSendQueuedNow(id) else { return false }
        sendQueuedNow(id, message: first.id)
        return true
    }

    func removeQueued(_ id: UUID, message: UUID) {
        guard var queue = queued[id] else { return }
        queue.remove(message)
        setQueue(queue, for: id)
        // A finished task whose result waited for this message reports now.
        deliverDelegatedResult(id)
    }

    func moveQueued(_ id: UUID, message: UUID, toIndex index: Int) {
        guard var queue = queued[id] else { return }
        queue.move(message, toIndex: index)
        setQueue(queue, for: id)
    }

    /// Takes a queued message into the running turn now. It stays queued when the turn cannot
    /// take it.
    func steerQueued(_ id: UUID, message: UUID) {
        guard var queue = queued[id], !queue.isFresh(message), let text = queue.promoteToSteer(message) else { return }
        setQueue(queue, for: id)
        if !steer(id, text: text, promoted: true) { enqueue(id, text: text) }
    }

    /// The text of a queued message for the composer; the draft you had is kept for `endEditQueued`.
    func beginEditQueued(_ id: UUID, message: UUID, currentDraft: String) -> String? {
        guard var queue = queued[id], let text = queue.beginEdit(message, currentDraft: currentDraft) else { return nil }
        queued[id] = queue
        return text
    }

    /// Ends the edit and returns the draft to put back in the composer.
    @discardableResult
    func endEditQueued(_ id: UUID, save: Bool, text: String = "") -> String? {
        guard var queue = queued[id] else { return nil }
        let draft = queue.endEdit(save: save, text: text)
        setQueue(queue, for: id)
        return draft
    }

    /// After a failure, a stop or a restart nothing goes out on top of the problem; you resume the queue yourself.
    func holdQueue(_ id: UUID) {
        guard var queue = queued[id], !queue.isEmpty else { return }
        queue.hold()
        queued[id] = queue
    }

    /// The turn ended well and the process is gone: send the next queued message. After a failure or a stop the queue
    /// waits for you, so nothing goes out on top of a problem. News about a pull request gets a fresh look first: the turn
    /// that just ended may well have fixed it. `looked` says that look was just taken.
    func sendQueued(_ id: UUID, looked: Bool = false) {
        // Not while the snapshot of the finished turn is still being made: the next turn's edits must not end up in it.
        guard processes[id] == nil, !checkpointing.contains(id), let run = run(id), run.status == .completed else { return }
        guard var queue = queued[id], let next = queue.next() else {
            // Nothing left to send: a delegated task whose result waited for its queue reports now.
            deliverDelegatedResult(id)
            return
        }
        if !looked, let notice = next.pullRequest, let fetch = pullRequestSnapshot, let url = URL(string: notice.url) {
            guard queueLooks.insert(id).inserted else { return }
            Task { [weak self] in
                let snapshot = await fetch(url)
                guard let self else { return }
                self.queueLooks.remove(id)
                if let snapshot {
                    if let watch = self.run(id)?.prWatches.first(where: { $0.url == notice.url }) {
                        // Through the watch, so that it remembers this look and a next failure still counts as news.
                        self.pullRequestChanged(id, old: watch, new: snapshot)
                    } else {
                        self.settleQueuedNews(id, url: notice.url, with: snapshot)
                    }
                }
                self.sendQueued(id, looked: true)
            }
            return
        }
        setQueue(queue, for: id)
        // A message after `/clear`: the conversation so far ends here (sendQueued only runs between turns).
        if next.fresh { clearConversation(id, quietly: true) }
        send(id, text: next.text, origin: next.origin)
    }

    /// Retries the previous task (after an error or when stopped).
    func retry(_ id: UUID) {
        guard let run = run(id), run.canContinue else { return }
        loadTimeline(id)
        let lastPrompt = timeline(id).last { $0.kind == .user }?.text ?? run.task
        if run.isolation == .worktree, !worktreeExists(run), !run.isRemote,
           let root = run.repoRoot, let branch = run.branch, let executable = launchExecutable(run) {
            let prefix = settings.sessionDefaults(for: root).branchPrefix
            let reserved = Set(runs.filter { $0.id != id }.compactMap(\.worktreePath))
            let path = WorktreeNaming.worktreePath(
                root: (settings.worktreeRoot as NSString).expandingTildeInPath,
                repoName: (root as NSString).lastPathComponent,
                slug: WorktreeNaming.directorySlug(branch: branch, prefix: prefix),
                exists: { reserved.contains($0) || FileManager.default.fileExists(atPath: $0) })
            update(id) {
                $0.workingDirectory = path
                $0.worktreePath = path
                $0.move(to: .preparing)
            }
            prepareWorktreeAndLaunch(id, root: root, path: path, branch: branch, base: run.baseBranch ?? "",
                                     prompt: lastPrompt, executable: executable)
            return
        }
        send(id, text: lastPrompt)
    }

    /// Stops the active turn. Claude Code receives a polite interrupt request first, followed by SIGINT.
    func stop(_ id: UUID) {
        stopDelegatedChildren(of: id)
        if cancelWaitingTurn(id) { return }
        if let task = prepareTasks.removeValue(forKey: id) {
            task.cancel()
            awaitingCheckpoint[id] = nil
            if let run = run(id), run.isolation == .worktree, !worktreeExists(run), let root = run.repoRoot {
                update(id) {
                    $0.worktreePath = nil
                    $0.workingDirectory = root
                }
            }
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
            holdQueue(id)
            sendPendingNow(id)
            return
        }
        beginStop(id)
        // Codex's app-server or an ACP agent stops its turn through its client; otherwise the turn's process is stopped.
        if connectedTurnDrivers.contains(where: { $0.stop(id) }) { return }
        guard processes[id] != nil else {
            // No running process: update state only.
            let wasWaitingCheckpoint = awaitingCheckpoint.removeValue(forKey: id) != nil
            update(id) { $0.move(to: .stopped) }
            if wasWaitingCheckpoint {
                append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
                holdQueue(id)
            }
            sendPendingNow(id)
            return
        }
        _ = processTurnDriver(id).stop(id)
    }

    func launchTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool = true) {
        guard !quitting else { return }
        dropFinishedSetup(id)
        cancelIdleCompaction(id)
        guard processes[id] == nil else { return }
        if waitForCapacity(id, prompt: prompt, executable: executable, showPrompt: showPrompt) { return }
        // A new turn brings a chat you settled back, also when the Agents list is not on screen to see it work.
        if let run = run(id) { FinishedSessions.shared.reopen(FinishedSessions.key(run: run)) }
        // A new turn ends any wait for a usage limit (yours or the automatic one).
        clearUsageLimit(id)
        // A task list that was all done belongs to the previous work; one still open stays until the agent updates it.
        if let tasks = self.run(id)?.tasks, RunTasks.isFinished(tasks) { update(id) { $0.tasks = nil } }
        applyAutoModel(id, prompt: prompt)
        guard let run = run(id) else { return }
        // Codex speaks app-server when it can: approvals, questions, steering and live reasoning. Gemini CLI, OpenCode,
        // Cursor and Grok speak ACP; Gemini falls back to its headless mode. Every other turn is a process of its own.
        turnDriver(for: run, executable: executable).launch(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
    }

    /// Opens the agent's connection when you open an idle session (an existing conversation), so your first message goes
    /// straight in instead of waiting for a process to start: Claude Code waits on stdin, Codex has its thread open, an
    /// ACP agent has its session loaded. Like a session parked after a turn, it closes when left alone.
    func prewarm(_ id: UUID) {
        guard !quitting, let run = run(id), run.canContinue, !run.status.isActive, !run.archived, processes[id] == nil,
              (run.providerSessionID != nil || run.pendingHandoff != nil), !forkNext.contains(id),
              let executable = launchExecutable(run),
              run.provider.capabilities.rollback != .resumeAt || run.pendingRollback == nil,
              run.isRemote || WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else { return }
        // What stays open between turns (`ProviderCapabilities.idleConnection`): Claude Code waits on stdin, Codex has its
        // thread open, an ACP agent its session. Pi runs a process per turn; Antigravity is not opened ahead of time.
        turnDriver(for: run, executable: executable).prewarm(id, run: run, executable: executable)
    }

    private static let ansiEscapeRegex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    /// Tail lines of error output, stripped of ANSI escapes. Detects "not logged in" and "limit reached".
    static func cleanError(_ raw: String, status: Int32) -> String {
        let stripped: String
        if raw.contains("\u{1B}"), let regex = ansiEscapeRegex {
            stripped = regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw), withTemplate: "")
        } else {
            stripped = raw
        }
        let lines = AgentLogLines.withoutLog(stripped.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let tail = lines.suffix(6).joined(separator: "\n")
        let lower = tail.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("authenticat") {
            return tr("ws.error.notLoggedIn")
        }
        if lower.contains("unknown option") || lower.contains("unexpected argument") {
            return tr("ws.error.outdated") + (tail.isEmpty ? "" : "\n" + String(tail.prefix(400)))
        }
        if tail.isEmpty { return tr("ws.error.exit", Int(status)) }
        return String(tail.prefix(800))
    }

    /// The line under a finished turn. Its cost is the one every agent's turn gets (`PriceTable.cost`): yours, the
    /// agent's own, or an estimate from its tokens for agents that report none (Codex, Gemini CLI), marked as such.
    func resultLine(_ usage: TurnUsage, denials: Int, for id: UUID? = nil) -> String {
        var parts: [String] = []
        if let seconds = usage.durationSeconds { parts.append(AgentPathFormat.duration(seconds)) }
        let tokens = usage.ownTokens
        if tokens > 0 { parts.append(TokenTally.format(tokens) + " tokens") }
        if settings.showCost {
            let cost = run(id).map { $0.cost(of: usage, prices: UsagePrices.current()) }
                ?? PriceTable().cost(for: usage, provider: "", model: "")
            if let label = CostFormat.label(cost) { parts.append(label) }
        }
        if denials > 0 { parts.append(tr("ws.event.denials", denials)) }
        return parts.joined(separator: " · ")
    }

    /// A Codex shell command as a tool call: "shell · npm test".
    static func codexCommand(_ callID: String, _ command: String) -> AgentToolCall {
        AgentToolCall(id: callID, name: "shell", title: "shell · " + ToolSummary.oneLine(command, 120), detail: command)
    }

    func recordFileChange(_ id: UUID, path: String, kind: String) {
        let base = run(id)?.workingDirectory ?? ""
        let shown = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        append(id, RunEvent(kind: .fileChange, text: shown, tool: kind, detail: path))
        update(id) { run in
            run.lastChangeAt = Date()
            // A file in another project than the session's own: the list names both (`SessionProjects`).
            if !run.isRemote, let projects = SessionProjects.adding(file: path, own: run.workingDirectory, to: run.otherProjects ?? []) {
                run.otherProjects = projects
            }
        }
        scheduleGitRefresh(id, delay: 1.5)
    }

    // MARK: Management

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { $0.title = String(clean.prefix(120)) }
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let run = run(id), !(archived && run.status.isActive) else { return }
        update(id) { $0.archived = archived }
        if archived {
            WorkspaceBridge.shared.forgetSecrets(run: id)
            store.compactSettled(id)
        }
    }

    /// A session was settled: its log keeps only what its timeline needs (`RunStore.compactSettled`).
    func settled(_ id: UUID) {
        guard let run = run(id), !run.status.isActive else { return }
        store.compactSettled(id)
    }

    func markReviewed(_ id: UUID) {
        update(id) { $0.reviewedAt = Date() }
    }

    /// The agent's latest task list. An empty list clears it.
    func setTasks(_ id: UUID, _ steps: [RunTaskStep]) {
        update(id) { $0.tasks = steps.isEmpty ? nil : steps }
    }

    // MARK: Review comments

    func addReviewComment(_ id: UUID, _ comment: ReviewComment) {
        reviewComments[id, default: []].append(comment)
    }

    func removeReviewComment(_ id: UUID, _ commentID: UUID) {
        reviewComments[id]?.removeAll { $0.id == commentID }
    }

    /// All comments in one message: now if the session is free, otherwise after the turn.
    func sendReviewComments(_ id: UUID) {
        guard let comments = reviewComments[id], !comments.isEmpty, let run = run(id) else { return }
        let message = ReviewComments.message(comments)
        reviewComments[id] = nil
        if run.canContinue && processes[id] == nil { send(id, text: message) } else { enqueue(id, text: message) }
    }

    /// Removes a session from Nook. The directory or worktree is preserved (removed separately); never allows deleting an active session.
    /// `cleanUpWorktree`: with "Remove the worktree when its last session is deleted" on, the worktree this leaves unused
    /// goes too (`cleanUpWorktreeAfterDelete`); **Delete with worktree** removes it itself.
    func delete(_ id: UUID, cleanUpWorktree: Bool = true) {
        guard let run = run(id), !run.status.isActive, processes[id] == nil else { return }
        let leftWorktree = cleanUpWorktree && run.isolation == .worktree ? orphanedWorktree(id) : nil
        if let root = run.repoRoot, let git = sessionGit(for: run), run.checkpoints != nil {
            Task.detached(priority: .utility) { git.removeCheckpoints(root, session: id) }
        }
        runs.removeAll { $0.id == id }
        SessionBrowsers.shared.discard(run: id)
        WorkspaceBridge.shared.forgetSecrets(run: id)
        forgetSessionState(id)
        store.deleteEventsAsync(id)
        if selectedRunID == id { selectedRunID = runs.first { !$0.archived }?.id }
        scheduleSave()
        if let leftWorktree {
            cleanUpWorktreeAfterDelete(repo: leftWorktree.repo, path: leftWorktree.path, branch: run.branch)
        }
    }

    /// What the agent is told at launch: the project's instructions for every agent, then the session's own. Read at every
    /// launch, so a change in Settings reaches a session from its next process on.
    func launchInstructions(_ run: WorkspaceRun) -> String {
        let folder = run.projectPath.isEmpty ? run.workingDirectory : run.projectPath
        return ProjectSettings.instructions(project: settings.sessionDefaults(for: folder).agentInstructions,
                                            session: run.instructions)
    }

    /// Everything Nook keeps for one session while it runs, gone at once: its processes and connections closed, its
    /// timers cancelled and every per-session entry removed. The one place for it, so a deleted session leaves nothing
    /// behind; `SessionStateCleanupTests` fails when a per-session property is added without being forgotten here.
    func forgetSessionState(_ id: UUID) {
        events[id] = nil
        timelineStore.forget(id)
        pullRequestWatcher.forget(id)
        // Per-session state that would otherwise stay for every session ever made, until Nook quits.
        gitRefresh.forget(id)
        sessionTimelines[id] = nil
        codexTotals[id] = nil
        codexSubagents[id] = nil
        openPullRequests[id] = nil
        contextUsages[id] = nil
        contextBreakdownMissing[id] = nil
        approvals[id] = nil
        queued[id] = nil
        questions[id] = nil
        worktreeSetups[id] = nil
        forgetConnectorSignIns(id)
        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        closeOpenCodeSession(id)
        limitResumes.removeValue(forKey: id)?.cancel()
        warmPrompts[id] = nil
        awaitingCheckpoint[id] = nil
        pendingSendNow[id] = nil
        pendingSendNowSteer[id] = nil
        pendingSendNowFresh.remove(id)
        pendingSendNowOrigin[id] = nil
        workStartedAt[id] = nil
        continuingTurns.remove(id)
        freshArmed.remove(id)
        turnPrompts[id] = nil
        addedWorktrees[id] = nil
        recoveringConversation.remove(id)
        codexLimitSnapshots[id] = nil
        limitedTurns[id] = nil
        backgroundWork.remove(id)
        subagentsWorking.remove(id)
        wakeLine[id] = nil
        heldWakeCompletions.remove(id)
        keepsHistory.remove(id)
        mcpAppContexts[id] = nil
        let appFolder = Self.mcpAppFolder(id)
        // The pages the agent showed (render_page) go with the session.
        let pageFolder = RenderedPage.file(in: NookPaths.supportDirectory, run: id, page: id).deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: appFolder)
            try? FileManager.default.removeItem(at: pageFolder)
        }
        prepareTasks.removeValue(forKey: id)?.cancel()
        checkpointIndices[id] = nil
        stopCoordinators[id] = nil
        sessionApprovals[id] = nil
        backgroundRoster[id] = nil
        claudeChangedDuringTurn.remove(id)
        git[id] = nil
        // State that only lives during a turn or while the session is open.
        turns[id] = nil
        regeneratingTitles.remove(id)
        dropNextPrompt(id)
        checkpointing.remove(id)
        acpCommands[id] = nil
        queueLooks.remove(id)
        reviewComments[id] = nil
        idleCompactionTimers.removeValue(forKey: id)?.cancel()
        idleCompacting.remove(id)
        sizeCompacting.remove(id)
        bridgeTokens[id] = nil
        BridgeTokenFiles.remove(id, in: bridgeTokenDirectory)
        codexGoalStarting[id] = nil
        codexGoalWaiting[id] = nil
        antigravitySignIns.remove(id)
        forkNext.remove(id)
        forkLaunched.remove(id)
        displayPrompt[id] = nil
        reopeningWorktrees.remove(id)
        keptReplays[id] = nil
        capacity.forget(id)
        runPositions = nil
        subThreadCounts = nil
    }

    private func applyAutoArchive() {
        let days = settings.autoArchiveDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var changed = false
        for index in runs.indices where !runs[index].archived && !runs[index].status.isActive && runs[index].updatedAt < cutoff {
            runs[index].archived = true
            store.compactSettled(runs[index].id)
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// On Nook shutdown: gracefully terminate running agents to prevent orphaned processes.
    func shutdown() {
        // Called again once the agents exited (`QuitShutdown`): what they wrote while Nook waited is saved too.
        guard !quitting else { return saveForQuit() }
        quitting = true
        let kept = detachKeptRuns()
        // Nothing is announced on the way out: a completion held for a monitor ends with Nook.
        heldWakeCompletions.removeAll()
        // A session whose turn ended while it waited on work in the background (a subagent) loses that work now: Nook
        // remembers what it was, so after the restart it can tell the agent and go on (`RestartContinuation`).
        let now = Date()
        for index in runs.indices where runs[index].status == .completed && !kept.contains(runs[index].id) {
            let id = runs[index].id
            guard backgroundWork.contains(id) || subagentsWorking.contains(id) else { continue }
            let labels = RestartContinuation.waitedOn(events[id] ?? [])
            if !labels.isEmpty {
                runs[index].cutBackgroundWork = CutBackgroundWork(labels: labels, at: now)
                runs[index].stoppedByQuit = true
            }
        }
        GuestShares.shared.suspend()
        for id in Array(codexServers.keys) { closeCodexServer(id) }
        for id in Array(claudeIdle.keys) { closeClaudeProcess(id) }
        for id in Array(acpClients.keys) { closeAcpClient(id) }
        closeOpenCodeServers()
        for (id, process) in processes {
            turns[id]?.stopping = true
            process.closeInput()
            process.stop(grace: 1)
        }
        for index in runs.indices where runs[index].status.isActive && !kept.contains(runs[index].id) {
            runs[index].interruptedWhileWaiting = runs[index].status == .waitingApproval ? true : nil
            runs[index].status = .stopped
            runs[index].statusDetail = "interrupted"
            runs[index].turnStartedAt = nil
            runs[index].stoppedByQuit = true
        }
        saveForQuit()
    }

    private func saveForQuit() {
        // Saves still queued go first: one that ran after these would write an older timeline over the newer one.
        store.flush()
        if runsLoaded { try? store.saveRuns(durableRuns(runs)) }
        for (id, list) in events { try? store.saveEvents(id, list) }
    }

    // MARK: Tracking and Persistence

    func replace(_ run: WorkspaceRun) {
        guard let index = runIndex(run.id) else { return }
        if !runs[index].status.isActive, run.status.isActive { dropNextPrompt(run.id) }
        runs[index] = run
        scheduleSave()
    }

    func update(_ id: UUID, save: Bool = true, _ change: (inout WorkspaceRun) -> Void) {
        guard let index = runIndex(id) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        // A version the API refused while a custom endpoint is in between: the failure says what really happened.
        if run.status == .failed, runs[index].status != .failed, let note = versionRejectionNote(run) { run.statusDetail = note }
        let freedPlace = runs[index].status.isActive && !run.status.isActive
        // A turn starts: the suggestion for the one before it no longer fits.
        if !runs[index].status.isActive, run.status.isActive { dropNextPrompt(id) }
        run.updatedAt = max(run.updatedAt, runs[index].updatedAt)
        // A summary Nook runs on its own is no activity of yours: the session keeps its place in the list, its "last
        // active" and its read state, instead of jumping up while it runs and landing first among the idle ones after.
        if idleCompacting.contains(id) { run.updatedAt = runs[index].updatedAt }
        runs[index] = run
        if save { scheduleSave() }
        // However a turn ended (done, failed, stopped, its process gone), a turn that waited for a free place may start.
        if freedPlace, !capacity.isEmpty {
            Task { @MainActor [weak self] in self?.startWaitingTurns() }
        }
    }
}

/// Tells the views that draw a session's timeline that one changed (`WorkspaceManager.timelines`). Observe it next to
/// the manager in a view that reads `timeline(_:)`.
@MainActor
final class TimelineChanges: ObservableObject {}
