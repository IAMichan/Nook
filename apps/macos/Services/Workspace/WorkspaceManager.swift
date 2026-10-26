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

    var canAlways: Bool {
        guard let list = suggestions?.object as? [Any] else { return false }
        return !list.isEmpty
    }
}

/// A question from an agent in a session Nook runs (Codex `requestUserInput`, Claude Code's AskUserQuestion).
struct PendingQuestion: Identifiable, Equatable {
    enum Origin: Equatable {
        case codex(RPCID)
        case claude(requestID: String, input: JSONBox)
    }

    let id: String
    let runID: UUID
    let questions: [RunQuestion]
    let origin: Origin
    let created: Date
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
    @Published var runs: [WorkspaceRun] = []
    /// Each session's timeline. Not `@Published`: a streaming answer changes it for every token, and a published
    /// dictionary can only be replaced as a whole, which copied the session's entire timeline per token. Changed in place
    /// here, and views hear about it at most every `eventsPublishInterval` (see `eventsDidChange`).
    var events: [UUID: [RunEvent]] = [:] {
        didSet { eventsDidChange() }
    }
    /// Settable within the module: the Codex app-server extension adds and answers requests too.
    @Published var approvals: [UUID: [PendingPermission]] = [:]
    /// Follow-up messages typed while the agent was working; the first goes out as soon as the turn has ended.
    @Published private(set) var queued: [UUID: MessageQueue] = [:]
    /// Questions an agent asked in a session and that wait for your answer.
    @Published var questions: [UUID: [PendingQuestion]] = [:]

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
    /// ACP: what the agent sent after its turn ended, until it shows it is really working again (see wakeAcp).
    var acpWakeBuffer: [UUID: [AcpEvent]] = [:]
    /// ACP: ends a turn the agent started by itself, once it has been quiet for a moment.
    var acpWakeFinish: [UUID: Task<Void, Never>] = [:]
    /// Sessions with work still running in the background: they stay open longer between turns (see BackgroundWork).
    var backgroundWork: Set<UUID> = []
    /// What MCP apps want the agent to know on its next turn, per session and app (see McpApp).
    var mcpAppContexts: [UUID: [String: String]] = [:]
    /// Codex reported new limits during a session: AppModel refreshes the usage shown.
    var onRateLimits: (() -> Void)?
    /// Claude Code reported how full a subscription window is, for the account (`AgentProfile.id`) the session runs with.
    var onPlanWindow: ((UsageLimits.PlanReading, String) -> Void)?
    @Published private(set) var git: [UUID: GitSnapshot] = [:]
    @Published private(set) var worktreeRows: [WorktreeRow] = []
    @Published private(set) var worktreesLoading = false
    @Published private(set) var gitAvailable: Bool?
    @Published var selectedRunID: UUID?
    /// The models each agent offers itself (Codex `model/list`, ACP sessions); see WorkspaceManager+Models.
    @Published var agentModels: [RunProvider: [AgentModel]] = [:]
    /// The open pull request of a session's branch, when GitHub says there is one (for the git button).
    @Published var openPullRequests: [UUID: URL] = [:]
    /// GitHub through Nook's connector, configured by AppModel: the open pull request of a branch, and opening one (nil
    /// while GitHub is not connected: the git button then opens GitHub's compare page with title and description filled in).
    var pullRequestLookup: ((_ repo: RemoteRepository, _ branch: String) async -> URL?)?
    var pullRequestCreate: ((_ repo: RemoteRepository, _ title: String, _ body: String, _ head: String, _ base: String) async throws -> URL?)?
    /// A watched pull request as it is now (GitHub, with your connected accounts).
    var pullRequestSnapshot: ((URL) async -> PullRequestSnapshot?)?
    var watchesInFlight: Set<UUID> = []
    /// Codex's subagents per session: the thread each runs on, and the timeline event that stands for it.
    var codexSubagents: [UUID: [String: UUID]] = [:]
    /// Comments on a session's diff, waiting to go to the agent together.
    @Published var reviewComments: [UUID: [ReviewComment]] = [:]
    var modelsRefreshed: [RunProvider: Date] = [:]
    /// The model manifest in use: the bundled one, or a newer valid copy from Nook's repository (see
    /// WorkspaceManager+ModelManifest).
    @Published var modelManifest: ModelManifest?
    /// What `claude --version` and `codex --version` printed, for the models that need a newer agent.
    @Published var agentVersions: [RunProvider: String] = [:]
    /// When the repository was last asked for the manifest, and when each agent's version was read (with its path).
    var manifestAttempted: Date?
    var versionsRead: [RunProvider: (path: String, at: Date)] = [:]
    /// Sessions waiting for a usage limit to reset, to go on then; and Codex's latest limits per session.
    var limitResumes: [UUID: Task<Void, Never>] = [:]
    var codexLimitSnapshots: [UUID: JSONBox] = [:]
    /// The turn that just ended stopped on a usage limit, with its reset when known. Kept apart from the turn state,
    /// which some paths clear before the end of the turn is handled.
    var limitedTurns: [UUID: Date?] = [:]
    /// Whether a Claude Code executable knows `--thinking-display` (asked once with `--help`, in the background).
    var claudeThinkingDisplay: [String: Bool] = [:]
    /// A message sent while the session was still warming up: it goes out as soon as the connection is open.
    var warmPrompts: [UUID: String] = [:]
    /// A message you sent while the previous turn's snapshot was still being made: shown at once, sent right after it.
    var awaitingCheckpoint: [UUID: String] = [:]
    /// A queued message sent right away while a turn was active: sent as soon as that turn ends.
    var pendingSendNow: [UUID: String] = [:]
    /// When GitHub was last asked about a branch's pull request ("owner/repo branch"), so it is asked once a minute at most.
    var pullRequestChecked: [String: Date] = [:]
    /// Sessions whose Antigravity sign-in page already opened.
    var antigravitySignIns: Set<UUID> = []
    /// Antigravity sign-ins outside a session (when you link the account), per account: the server and what to call when done.
    var antigravityLogins: [String: (client: AcpClient, done: (String?) -> Void)] = [:]

    let settings = WorkspaceSettings.shared
    private let store: RunStore
    private(set) var gitService: GitService?

    /// Agent executable path (from AgentHistory) and account environment; configured by AppModel.
    var executable: (RunProvider) -> String? = { _ in nil }
    var accountEnvironment: (String) -> [String: String] = { _ in [:] }
    /// The folder an account keeps its login in; two accounts with the same folder share conversations.
    var accountHome: (String) -> String? = { $0 }
    /// Runs a project script in a visible terminal (folder, command, title); configured by AppModel.
    var runScript: ((String, String, String) -> Void)?
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

    var processes: [UUID: AgentProcess] = [:]
    var turns: [UUID: TurnState] = [:]
    private var saveTask: Task<Void, Never>?
    private var eventSaves: [UUID: Task<Void, Never>] = [:]
    /// The session list as it was last handed to the store: a timeline save only rewrites `runs.json` when it changed.
    private var savedRuns: [WorkspaceRun]?
    /// A change to `events` was announced less than `eventsPublishInterval` ago; `eventsDirty` says another one followed.
    private var eventsThrottled = false
    private var eventsDirty = false
    /// At most this often a view redraws for a changing timeline: about 20 times a second, smooth for streaming text.
    private static let eventsPublishInterval: UInt64 = 50_000_000
    /// When each timeline in memory was last used. Every timeline ever opened used to stay in memory until Nook quit;
    /// beyond `timelineLimit` the longest unused ones of idle sessions are released (`evictTimelines`) and read back from
    /// disk when anything asks for them again (`evictedTimelines`).
    private var timelineUse: [UUID: Date] = [:]
    private var evictedTimelines: Set<UUID> = []
    /// The last answer of each released timeline, so a summary (the phone's session list) can show it without reading
    /// the whole timeline back from disk and keeping it in memory again.
    private var evictedAnswers: [UUID: String] = [:]
    private static let timelineLimit = 16
    private static let timelineIdleSeconds: TimeInterval = 300
    /// Set while an evicted timeline is read back for a view that is drawing it: no news for anyone.
    private var quietEvents = false
    /// Timelines being read off the main thread by `prefetchTimeline`.
    private var prefetching: Set<UUID> = []
    private var gitRefreshes: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose next turn starts as a copy of the conversation (`--fork-session`), so the original keeps going untouched.
    var forkNext: Set<UUID> = []
    /// Sessions whose settings changed during a turn: their Claude Code process is not reused afterwards, so the next turn
    /// surely starts with the new flags, even when this Claude Code could not take them over live.
    var claudeChangedDuringTurn: Set<UUID> = []
    /// What you typed, for a turn whose prompt starts with a handoff summary (the timeline shows your words only).
    var displayPrompt: [UUID: String] = [:]
    /// Stop in progress per session (see WorkspaceManager+Stop), the approvals you gave "for this session" (Codex only
    /// remembers the exact command, so Nook keeps its own), and the background work an agent still has running.
    var stopCoordinators: [UUID: StopCoordinator] = [:]
    var sessionApprovals: [UUID: SessionApprovals] = [:]
    var backgroundRoster: [UUID: BackgroundRoster] = [:]

    /// State tracked by Nook during a single turn.
    struct TurnState {
        var liveTextID: UUID?
        /// Claude Code: the last finished answer, which a failed turn's result may repeat word for word.
        var lastTextID: UUID?
        var toolEvents: [String: UUID] = [:]
        var toolNames: [String: String] = [:]
        var toolInputs: [String: JSONBox] = [:]
        var messageUsage: [String: TokenCounts] = [:]
        var lastContext: Int?
        var finished = false
        var stopping = false
        var lastError: String?
        var started = Date()
        /// codex app-server: the item the live answer belongs to, the thought being streamed, and token totals.
        var liveTextItem: String?
        var liveReasoningID: UUID?
        var liveReasoningItem: String?
        var codexBaseline: TokenCounts?
        var contextWindow: Int?
        /// ACP: the session's cost so far, as the agent reports it.
        var acpCost: Double?
        /// ACP: whether the agent wrote any text this turn, its tool calls, and how often Nook asked it to carry on.
        var acpReplied = false
        var acpToolCalls = 0
        var acpContinuations = 0
        /// Claude Code: a steering message went in, so a result that says "aborted" ends a segment, not the turn.
        var steered = false
        var steeredUsage: [TurnUsage] = []
        /// Claude Code's thinking as it streams: the block being written, whether a thinking block is open, and the
        /// finished streamed blocks waiting for their complete copy (nil: the block streamed no text).
        var liveThinkingID: UUID?
        var thinkingOpen = false
        var streamedThinking: [UUID?] = []
        /// Claude Code's blocked usage-limit windows during the turn, with their reset if known.
        var limitWindows: [String: Date?] = [:]
        /// A turn the agent started by itself after background work, with no message of yours to answer.
        var unprompted = false
    }

    init(store: RunStore = RunStore(directory: NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true))) {
        self.store = store
        agentModels = AgentModelStore(url: Self.modelStoreURL).load()
        modelManifest = ModelManifest.preferred(bundled: .bundled(), cached: ModelManifestStore(url: Self.manifestStoreURL).load())
        // The session list can be long: read it off the main thread so launching Nook does not wait for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = store.loadRuns()
            await self?.finishLoadingRuns(loaded)
        }
        // Watched pull requests are looked at every half minute (each at most every two minutes).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.checkPullRequestWatches()
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
    private var runsLoaded = false

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
        runs = started + loaded
        runsLoaded = true
        applyAutoArchive()
        // Sessions that were waiting for a usage limit to reset go on waiting.
        for run in loaded where run.autoResume == true { armLimitResume(run.id) }
        if !started.isEmpty { scheduleSave() }
    }

    // MARK: Reading

    func run(_ id: UUID?) -> WorkspaceRun? {
        guard let id else { return nil }
        return runs.first { $0.id == id }
    }

    func timeline(_ id: UUID) -> [RunEvent] {
        if let loaded = events[id] {
            timelineUse[id] = Date()
            return loaded
        }
        guard evictedTimelines.contains(id) else { return [] }
        // Released while unused: back from disk as if it had never left.
        evictedTimelines.remove(id)
        evictedAnswers[id] = nil
        quietEvents = true
        events[id] = store.loadEvents(id)
        quietEvents = false
        timelineUse[id] = Date()
        // Read back from a view, so not now: another one may go once this update is done, or the limit no longer holds.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.evictTimelines() } }
        return events[id] ?? []
    }

    /// The session's timeline for Search everything: from memory when it is loaded, else read from disk off the main
    /// thread without keeping it, so a search does not hold every timeline in memory.
    func timelineForSearch(_ id: UUID) async -> [RunEvent] {
        if let loaded = events[id] { return loaded }
        let store = store
        return await Task.detached(priority: .utility) { store.loadEvents(id) }.value
    }

    /// The text of the session's last answer, from memory only: a released timeline is not read back for it, and asking
    /// does not count as using the timeline (so polling summaries do not keep every timeline in memory).
    func lastAnswer(_ id: UUID) -> String {
        if let loaded = events[id] { return loaded.last(where: { $0.kind == .assistant })?.text ?? "" }
        return evictedAnswers[id] ?? ""
    }

    /// Reads a timeline that is not in memory off the main thread, so opening its session right after (a row under the
    /// pointer, the session the list is about to show) draws it at once instead of decoding up to `RunStore.eventLimit`
    /// events on the main thread first. Opening before this is done still reads it the plain way.
    func prefetchTimeline(_ id: UUID) {
        guard events[id] == nil, !prefetching.contains(id), runs.contains(where: { $0.id == id }) else { return }
        prefetching.insert(id)
        let store = store
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { store.loadEvents(id) }.value
            guard let self else { return }
            self.prefetching.remove(id)
            // Opened (or written to) meanwhile: what is in memory is newer than what was read.
            guard self.events[id] == nil else { return }
            self.evictedTimelines.remove(id)
            self.evictedAnswers[id] = nil
            self.timelineUse[id] = Date()
            self.quietEvents = true
            self.events[id] = loaded
            self.quietEvents = false
            self.evictTimelines()
        }
    }

    /// Loads timeline from disk if not yet in memory.
    func loadTimeline(_ id: UUID) {
        timelineUse[id] = Date()
        guard events[id] == nil else { return }
        evictedTimelines.remove(id)
        evictedAnswers[id] = nil
        events[id] = store.loadEvents(id)
        evictTimelines()
    }

    /// Releases the longest unused timelines beyond `timelineLimit`, of sessions with nothing running or left to save.
    private func evictTimelines() {
        guard events.count > Self.timelineLimit else { return }
        // Unused for minutes: a save scheduled for it has long been written, so reading it back gets everything.
        let unusedSince = Date().addingTimeInterval(-Self.timelineIdleSeconds)
        let idle = events.keys.filter { id in
            (timelineUse[id] ?? .distantPast) < unusedSince
                && eventSaves[id] == nil && processes[id] == nil && turns[id] == nil && codexServers[id] == nil
                && claudeIdle[id] == nil && acpClients[id] == nil && !(run(id)?.status.isActive ?? false)
        }
        .sorted { (timelineUse[$0] ?? .distantPast) < (timelineUse[$1] ?? .distantPast) }
        for id in idle.prefix(events.count - Self.timelineLimit) {
            // Only the start: a summary shows a short excerpt of it, and a long answer need not stay in memory whole.
            evictedAnswers[id] = events[id]?.last(where: { $0.kind == .assistant }).map { String($0.text.prefix(2_000)) }
            events[id] = nil
            timelineUse[id] = nil
            evictedTimelines.insert(id)
        }
    }

    var activeRuns: [WorkspaceRun] { runs.filter { $0.status.isActive } }
    var attentionCount: Int { runs.filter { ($0.status == .waitingApproval || $0.status == .failed) && !$0.archived }.count }
    func isRunning(_ id: UUID) -> Bool { processes[id] != nil }

    /// Other active sessions working in the same directory: concurrent edits could collide.
    func activeRuns(sharing directory: String, except id: UUID? = nil) -> [WorkspaceRun] {
        let target = WorkspacePathPolicy.normalize(directory)
        return runs.filter { $0.id != id && $0.status.isActive && WorkspacePathPolicy.normalize($0.workingDirectory) == target }
    }

    // MARK: Inspecting Project

    /// Information required by "New Session" for a directory. Evaluated off the main thread.
    func inspectProject(_ path: String) async -> ProjectInfo {
        let git = gitService
        return await Task.detached(priority: .userInitiated) {
            let normalized = WorkspacePathPolicy.normalize(path)
            var info = ProjectInfo(path: normalized, name: URL(fileURLWithPath: normalized).lastPathComponent,
                                   verdict: WorkspacePathPolicy.verdict(for: normalized), repoRoot: nil, currentBranch: nil,
                                   branches: [], defaultBase: nil, hasCommits: false, dirtyFiles: 0, isWorktree: false)
            guard info.verdict == .ok, let git, let root = git.repositoryRoot(for: normalized) else { return info }
            info.repoRoot = root
            let current = git.currentBranch(root)
            info.currentBranch = current
            info.hasCommits = git.hasCommits(root)
            let branchLists = try? git.branches(root)
            if let branchLists { info.branches = branchLists.local + branchLists.remote }
            info.defaultBase = git.worktreeBaseBranch(root, localBranches: branchLists?.local, fallbackBranch: current)
            info.dirtyFiles = git.changedFileCount(root) ?? 0
            if let common = git.commonDirectory(for: root) {
                info.isWorktree = WorkspacePathPolicy.normalize(URL(fileURLWithPath: common).deletingLastPathComponent().path)
                    != WorkspacePathPolicy.normalize(root)
            }
            return info
        }.value
    }

    /// Clones a repository, then selects it as the active project.
    func clone(url: String, into parent: String) async throws -> String {
        guard let git = gitService else { throw StartError.noGit }
        let path = try await Task.detached(priority: .userInitiated) { try git.clone(url: url, into: parent) }.value
        settings.rememberProject(path)
        return path
    }

    // MARK: New Session

    enum StartError: LocalizedError {
        case config(ConfigProblem)
        case workspace(WorkspacePathPolicy.Verdict)
        case noExecutable(RunProvider)
        case noGit
        case notRepository
        case shared(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .config(let problem): return tr("ws.error.config." + problem.rawValue)
            case .workspace(let verdict): return tr("ws.error.path." + String(describing: verdict))
            case .noExecutable(let provider): return tr("ws.error.noExecutable", provider.displayName)
            case .noGit: return tr("ws.error.noGit")
            case .notRepository: return tr("ws.error.notRepository")
            case .shared(let title): return tr("ws.error.shared", title)
            case .git(let message): return message
            }
        }
    }

    /// Validates configuration, prepares folder or worktree, and launches the agent. If worktree creation fails,
    /// no session is added so you can retry. If the agent subsequently fails, the session is marked "failed"
    /// and can be retried with "Retry" without duplicating the session.
    @discardableResult
    func start(_ config: NewRunConfig, allowSharedFolder: Bool = false) async throws -> UUID {
        if let problem = config.problem { throw StartError.config(problem) }
        // On another machine: no folder, git or worktree to prepare here.
        if let remote = config.remote { return try await startRemote(config, on: remote) }
        let projectPath = WorkspacePathPolicy.normalize(config.projectPath)
        let verdict = WorkspacePathPolicy.verdict(for: projectPath)
        guard verdict == .ok else { throw StartError.workspace(verdict) }
        guard let executable = executable(config.provider) else { throw StartError.noExecutable(config.provider) }

        let id = UUID()
        var workingDirectory = projectPath
        var repoRoot: String?
        var branch: String?
        var worktreePath: String?
        let git = gitService

        if let git { repoRoot = await Task.detached { git.repositoryRoot(for: projectPath) }.value }

        if config.isolation == .worktree {
            guard let git else { throw StartError.noGit }
            guard let root = repoRoot else { throw StartError.notRepository }
            let base = config.baseBranch
            let name = config.branchName
            let rootFolder = config.worktreeRoot.isEmpty ? settings.worktreeRoot : config.worktreeRoot
            let repoName = URL(fileURLWithPath: root).lastPathComponent
            let path = WorktreeNaming.worktreePath(root: (rootFolder as NSString).expandingTildeInPath, repoName: repoName,
                                                   slug: WorktreeNaming.directorySlug(branch: name),
                                                   exists: { FileManager.default.fileExists(atPath: $0) })
            do {
                try await Task.detached(priority: .userInitiated) {
                    try git.addWorktree(repo: root, path: path, branch: name, base: base)
                }.value
            } catch {
                throw StartError.git(error.localizedDescription)
            }
            workingDirectory = path
            worktreePath = path
            branch = name
        } else {
            if !allowSharedFolder, let other = activeRuns(sharing: projectPath).first {
                throw StartError.shared(other.title)
            }
            if let git, repoRoot != nil {
                branch = await Task.detached { git.currentBranch(projectPath) }.value
            }
        }

        let now = Date()
        let title = config.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var run = WorkspaceRun(
            id: id,
            title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title,
            task: ContextRefs.visible(config.task),
            provider: config.provider,
            profileID: config.profileID,
            model: config.model,
            mode: config.mode,
            permission: config.permission,
            isolation: config.isolation,
            projectPath: repoRoot ?? projectPath,
            workingDirectory: workingDirectory,
            repoRoot: repoRoot,
            branch: branch,
            baseBranch: config.isolation == .worktree ? config.baseBranch : nil,
            worktreePath: worktreePath,
            instructions: config.instructions,
            status: .preparing,
            statusDetail: nil,
            providerSessionID: nil,
            createdAt: now,
            updatedAt: now,
            archived: false,
            usage: RunUsage(),
            turnStartedAt: nil,
            reviewedAt: nil,
            lastChangeAt: nil,
            changedFiles: nil,
            delegation: config.delegation
        )
        run.effort = config.effort
        runs.insert(run, at: 0)
        events[id] = []
        settings.rememberProject(repoRoot ?? projectPath)
        selectedRunID = id
        if let worktreePath {
            append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeCreated", branch ?? "", AgentPathFormat.tilde(worktreePath))))
            // The first snapshot, before the agent does anything: "back to here" on the first message.
            if let git {
                let ref = GitService.checkpointRef(session: id, index: 0)
                // A new worktree is exactly its branch's HEAD: point the snapshot there instead of reading every file.
                if (try? await Task.detached(priority: .userInitiated) { try git.checkpointHead(worktreePath, ref: ref) }.value) != nil {
                    update(id) { $0.checkpoints = [RunCheckpoint(ref: ref, date: Date())] }
                }
            }
            // The project's setup (nook.json `runOnWorktreeCreate`), visible in a terminal next to the session.
            let setup = await Task.detached(priority: .userInitiated) { ProjectScripts.load(folder: worktreePath) }.value
            for script in setup where script.runOnWorktreeCreate {
                runScript?(worktreePath, script.command, script.name)
                append(id, RunEvent(kind: .system, text: tr("ws.event.setupScript", script.name)))
            }
        } else if repoRoot != nil, let git {
            // In your own folder too, a snapshot before the agent starts: what each turn changed can then be shown on
            // its own. Taking it changes nothing: not the files, the index or a branch.
            let ref = GitService.checkpointRef(session: id, index: 0)
            let directory = workingDirectory
            if (try? await Task.detached(priority: .userInitiated) { try git.checkpoint(directory, ref: ref) }.value) != nil {
                update(id) { $0.checkpoints = [RunCheckpoint(ref: ref, date: Date())] }
            }
        }
        let visibleTask = ContextRefs.visible(config.task)
        if visibleTask != config.task { displayPrompt[id] = visibleTask }
        launchTurn(id, prompt: config.task, executable: executable)
        if title.isEmpty { generateTitle(id) }
        return id
    }

    /// Takes over an existing agent conversation (running in a terminal, or an earlier session) as a Nook session.
    /// Nothing starts yet: the first message resumes the conversation (`--resume`, `exec resume`). `fork` makes that
    /// first turn a copy (Claude Code only), so a conversation that is still running elsewhere is never written to twice.
    /// Already taken over? Returns that session instead of adding a second one.
    @discardableResult
    func adopt(provider: RunProvider, sessionID: String, profileID: String, directory: String, title: String,
               history: [(kind: RunEvent.Kind, text: String)] = [], fork: Bool = false) async throws -> UUID {
        if !fork, let existing = runs.first(where: { $0.provider == provider && $0.providerSessionID == sessionID }) {
            if existing.archived { setArchived(existing.id, false) }
            selectedRunID = existing.id
            return existing.id
        }
        let projectPath = WorkspacePathPolicy.normalize(directory)
        let verdict = WorkspacePathPolicy.verdict(for: projectPath)
        guard verdict == .ok else { throw StartError.workspace(verdict) }
        guard executable(provider) != nil else { throw StartError.noExecutable(provider) }

        var repoRoot: String?
        var branch: String?
        if let git = gitService {
            repoRoot = await Task.detached { git.repositoryRoot(for: projectPath) }.value
            if repoRoot != nil { branch = await Task.detached { git.currentBranch(projectPath) }.value }
        }
        let id = UUID()
        let now = Date()
        let clean = InjectedPrompt.title(title)
        let permission = provider.capabilities.policies.contains(settings.defaultPermission)
            ? settings.defaultPermission : (provider.capabilities.policies.first ?? .acceptEdits)
        let run = WorkspaceRun(
            id: id,
            title: clean.isEmpty ? URL(fileURLWithPath: projectPath).lastPathComponent : WorktreeNaming.title(from: clean),
            task: clean,
            provider: provider,
            profileID: profileID,
            model: "",
            mode: .agent,
            permission: permission,
            isolation: .folder,
            projectPath: projectPath,
            workingDirectory: projectPath,
            repoRoot: repoRoot,
            branch: branch,
            baseBranch: nil,
            worktreePath: nil,
            instructions: "",
            status: .completed,
            statusDetail: nil,
            providerSessionID: sessionID,
            createdAt: now,
            updatedAt: now,
            archived: false,
            usage: RunUsage(),
            turnStartedAt: nil,
            reviewedAt: nil,
            lastChangeAt: nil,
            changedFiles: nil
        )
        runs.insert(run, at: 0)
        events[id] = []
        if fork { forkNext.insert(id) }
        settings.rememberProject(repoRoot ?? projectPath)
        selectedRunID = id
        for entry in history where !entry.text.isEmpty {
            append(id, RunEvent(kind: entry.kind, text: entry.text, state: entry.kind == .assistant ? .done : nil))
        }
        append(id, RunEvent(kind: .system, text: tr(fork ? "ws.event.adoptedFork" : "ws.event.adopted", provider.displayName)))
        scheduleSave()
        // The starting point for what the next turns change.
        captureCheckpoint(id)
        return id
    }

    /// Changes how the next turn runs: mode, permissions, and model. Also while a turn runs (a session Nook took over as
    /// much as one it started): a running Claude Code takes them over at once (see `applyLive`), other agents from their
    /// next turn. Rights count right away either way: Nook answers what they now cover itself (see `LiveRights`),
    /// the requests already waiting included.
    func configure(_ id: UUID, mode: ExecutionMode? = nil, permission: PermissionPolicy? = nil, model: String? = nil) {
        guard let run = run(id) else { return }
        update(id) {
            if let mode { $0.mode = mode }
            if let permission, run.provider.capabilities.policies.contains(permission) {
                $0.permission = permission
                if permission != run.permission { sessionApprovals[id]?.modeChanged(to: permission) }
            }
            if let model { $0.model = model.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if run.status.isActive, let updated = self.run(id) { applyLive(id, from: run, to: updated) }
        if let updated = self.run(id), updated.permission != run.permission || updated.mode != run.mode { allowCovered(id) }
    }

    /// Allows the waiting requests the session's current rights cover, as if you had pressed Allow on each.
    func allowCovered(_ id: UUID) {
        guard let run = run(id) else { return }
        for pending in approvals[id] ?? [] where coveredByRights(pending, run) { decide(id, requestID: pending.id, .allow) }
    }

    private func coveredByRights(_ pending: PendingPermission, _ run: WorkspaceRun) -> Bool {
        if let request = codexRequests[pending.id] {
            return LiveRights.coversCodex(request.kind, permission: run.permission, mode: run.mode)
        }
        if let request = acpRequests[pending.id] {
            return AcpRPC.autoAllows(request.call, permission: run.permission, mode: run.mode)
        }
        return run.provider == .claude && LiveRights.coversClaude(tool: pending.tool, permission: run.permission, mode: run.mode)
    }

    // MARK: Turns

    /// Follow-up message. Permitted only when prior turn has finished; concurrent processes for the same session are prevented.
    func send(_ id: UUID, text: String) {
        send(id, text: text, shown: false)
    }

    /// A message from Nook rather than from you (the result of background work): it goes to the agent without a bubble
    /// of yours in the timeline.
    @discardableResult
    func sendHidden(_ id: UUID, text: String) -> Bool {
        send(id, text: text, shown: true)
    }

    /// Sends the message you asked to go out right away once the turn ended; if it cannot go out now it waits
    /// first in the queue. False when nothing was waiting.
    @discardableResult
    func sendPendingNow(_ id: UUID) -> Bool {
        guard let next = pendingSendNow.removeValue(forKey: id) else { return false }
        if !send(id, text: next, shown: false) {
            queued[id, default: MessageQueue()].requeueFirst(next)
        }
        return true
    }

    /// False when the message could not be taken (empty, the session cannot continue, or a turn is running).
    @discardableResult
    private func send(_ id: UUID, text: String, shown: Bool) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // You carry on yourself: whatever waited behind a failure or a stop goes on after this turn.
        if var held = queued[id], held.isHeld { held.resume(); queued[id] = held }
        guard !clean.isEmpty, let run = run(id), run.canContinue, processes[id] == nil else { return false }
        // The previous turn's snapshot is still being made (a moment): your message shows at once, and
        // goes out right after it, so this turn's edits stay out of that snapshot.
        if checkpointing.contains(id) {
            if awaitingCheckpoint[id] != nil {
                enqueue(id, text: clean)
            } else {
                loadTimeline(id)
                if !shown { append(id, RunEvent(kind: .user, text: ContextRefs.visible(clean))) }
                awaitingCheckpoint[id] = clean
            }
            return true
        }
        guard let executable = launchExecutable(run) else {
            update(id) { $0.statusDetail = StartError.noExecutable(run.provider).errorDescription }
            return false
        }
        // A folder on another machine cannot be checked from here; ssh and the agent there report what is wrong.
        guard run.isRemote || WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else {
            append(id, RunEvent(kind: .error, text: tr("ws.error.folderGone", run.workingDirectory)))
            return false
        }
        loadTimeline(id)
        // After a fork or a switch of agent the first turn starts with the summary; it stays until a turn ends well.
        // What the timeline shows: your words, without a handoff summary or the context envelope of references.
        let visible = ContextRefs.visible(clean)
        displayPrompt[id] = run.pendingHandoff == nil && visible == clean ? nil : visible
        // What MCP apps told the agent goes with this turn: Codex takes it as context of its own, the others ahead of it.
        let appContext = run.provider == .codex ? "" : McpApp.contextPreamble(takeMcpAppContexts(id))
        launchTurn(id, prompt: appContext + ContextHandoff.compose(handoff: run.pendingHandoff, message: clean), executable: executable,
                   showPrompt: !shown)
        return true
    }

    /// A turn ended: tell the app, and snapshot the worktree so you can go back to before a later message.
    func turnDidFinish(_ id: UUID) {
        checkUsageLimit(id)
        guard let run = run(id) else { return }
        // Before open work is settled: what still runs is what keeps the session open.
        if BackgroundWork.pending(after: timeline(id), before: backgroundWork.contains(id)) {
            backgroundWork.insert(id)
        } else {
            backgroundWork.remove(id)
        }
        displayPrompt[id] = nil
        stopCoordinators[id] = nil
        settleOpenWork(id, reason: run.status == .completed ? .completed : (run.status == .stopped ? .stopped : .failed))
        if run.status == .failed || run.status == .stopped { holdQueue(id) }
        if run.status == .completed {
            clearContinuations(id)
            if run.pendingHandoff != nil { update(id) { $0.pendingHandoff = nil } }
        }
        onTurnFinished?(run)
        deliverDelegatedResult(id)
        captureCheckpoint(id)
    }

    /// A snapshot after each turn, for every session in a repository: it shows what each turn changed. Putting files back
    /// stays for sessions in their own worktree (see canRevert): restoring there can never touch your own checkout.
    func captureCheckpoint(_ id: UUID) {
        guard let run = run(id), run.repoRoot != nil, let git = sessionGit(for: run), canSnapshot(run) else { return }
        let directory = run.workingDirectory
        let ref = GitService.checkpointRef(session: id, index: run.checkpoints?.count ?? 0)
        // Dated when the turn ended, before any later message: "before this message" then picks the right snapshot.
        let date = Date()
        checkpointing.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let made = (try? git.checkpoint(directory, ref: ref)) != nil
            await self?.recordCheckpoint(id, made ? RunCheckpoint(ref: ref, date: date) : nil)
        }
    }

    private func recordCheckpoint(_ id: UUID, _ checkpoint: RunCheckpoint?) {
        checkpointing.remove(id)
        if let checkpoint { update(id) { $0.checkpoints = ($0.checkpoints ?? []) + [checkpoint] } }
        if let waiting = awaitingCheckpoint.removeValue(forKey: id) {
            // Shown already: if it cannot go out now, it waits in the queue instead of getting lost.
            if !send(id, text: waiting, shown: true) {
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

    /// Puts the worktree's files back to the last snapshot before `date` (a message of yours). The conversation stays.
    func revertFiles(_ id: UUID, before date: Date) async throws {
        guard canRevert(id, before: date), let run = run(id), let git = sessionGit(for: run),
              let checkpoint = run.checkpoints?.last(where: { $0.date <= date }) else {
            throw StartError.git(tr("ws.revert.unavailable"))
        }
        let directory = run.workingDirectory
        try await Task.detached(priority: .userInitiated) { try git.restore(directory, to: checkpoint.ref) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.revert.done")))
        refreshGit(id)
    }

    /// Keeps a message for when the current turn is done: you keep typing while the agent works.
    func enqueue(_ id: UUID, text: String) {
        guard run(id) != nil else { return }
        var queue = queued[id] ?? MessageQueue()
        queue.enqueue(text)
        queued[id] = queue.isEmpty ? nil : queue
    }

    private func store(_ queue: MessageQueue, for id: UUID) {
        queued[id] = queue.isEmpty && !queue.isHeld ? nil : queue
    }

    /// A queued message can go out right away: into the running turn, or as a new turn when the agent is idle.
    func canSendQueuedNow(_ id: UUID) -> Bool {
        guard let run = run(id) else { return false }
        if run.status.isActive { return true }
        return run.canContinue && processes[id] == nil && !checkpointing.contains(id)
    }

    /// Sends one queued message now, ahead of the rest: it steers a running turn, or starts the next turn when the
    /// agent is idle (also after a stop or a failure). It stays queued when it cannot go out.
    func sendQueuedNow(_ id: UUID, message: UUID) {
        guard canSendQueuedNow(id), let run = run(id) else { return }
        if run.status.isActive {
            if canSteer(id) {
                guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
                store(queue, for: id)
                if steer(id, text: text) { return }
                queue.requeueFirst(text)
                store(queue, for: id)
            }
            guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
            queue.resume()
            store(queue, for: id)
            pendingSendNow[id] = text
            stop(id)
            return
        }
        guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
        queue.resume()
        store(queue, for: id)
        if !send(id, text: text, shown: false) { queued[id, default: MessageQueue()].requeueFirst(text) }
    }

    func removeQueued(_ id: UUID, message: UUID) {
        guard var queue = queued[id] else { return }
        queue.remove(message)
        store(queue, for: id)
    }

    func moveQueued(_ id: UUID, message: UUID, toIndex index: Int) {
        guard var queue = queued[id] else { return }
        queue.move(message, toIndex: index)
        store(queue, for: id)
    }

    /// Takes a queued message into the running turn now. It stays queued when the turn cannot
    /// take it.
    func steerQueued(_ id: UUID, message: UUID) {
        guard var queue = queued[id], let text = queue.promoteToSteer(message) else { return }
        store(queue, for: id)
        if !steer(id, text: text) { enqueue(id, text: text) }
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
        store(queue, for: id)
        return draft
    }

    /// After a failure, a stop or a restart nothing goes out on top of the problem; you resume the queue yourself.
    func holdQueue(_ id: UUID) {
        guard var queue = queued[id], !queue.isEmpty else { return }
        queue.hold()
        queued[id] = queue
    }

    /// The turn ended well and the process is gone: send the next queued message. After a failure or a stop the queue
    /// waits for you, so nothing goes out on top of a problem.
    func sendQueued(_ id: UUID) {
        // Not while the snapshot of the finished turn is still being made: the next turn's edits must not end up in it.
        guard processes[id] == nil, !checkpointing.contains(id), let run = run(id), run.status == .completed,
              var queue = queued[id], let next = queue.next() else { return }
        store(queue, for: id)
        send(id, text: next.text)
    }

    /// Retries the previous task (after an error or when stopped).
    func retry(_ id: UUID) {
        guard let run = run(id), run.canContinue else { return }
        loadTimeline(id)
        let lastPrompt = timeline(id).last { $0.kind == .user }?.text ?? run.task
        send(id, text: lastPrompt)
    }

    /// Stops the active turn. Claude Code receives a polite interrupt request first, followed by SIGINT.
    func stop(_ id: UUID) {
        stopDelegatedChildren(of: id)
        beginStop(id)
        if stopCodexServerTurn(id) { return }
        if stopAcpTurn(id) { return }
        guard let process = processes[id] else {
            // No running process: update state only.
            update(id) { $0.move(to: .stopped) }
            sendPendingNow(id)
            return
        }
        turns[id]?.stopping = true
        if run(id)?.provider == .claude {
            process.send(ClaudeStreamParser.interruptRequest(id: "nook-stop-" + UUID().uuidString.prefix(8)))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.processes[id] === process else { return }
                process.closeInput()
                process.stop()
            }
        } else {
            process.stop()
        }
        expireApprovals(id)
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopping")))
    }

    func launchTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool = true) {
        guard processes[id] == nil else { return }
        // A new turn ends any wait for a usage limit (yours or the automatic one).
        clearUsageLimit(id)
        // A task list that was all done belongs to the previous work; one still open stays until the agent updates it.
        if let tasks = self.run(id)?.tasks, RunTasks.isFinished(tasks) { update(id) { $0.tasks = nil } }
        guard var run = run(id) else { return }
        // Codex speaks app-server when it can: approvals, questions, steering and live reasoning.
        if run.provider == .codex, settings.codexAppServer, !codexExecOnly.contains(executable) {
            launchCodexServerTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
            return
        }
        // Gemini CLI, OpenCode, Cursor and Grok speak ACP; Gemini falls back to its headless mode.
        if run.provider.usesACP, !acpFallback.contains(executable) {
            launchAcpTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
            return
        }
        // Claude Code still running from the previous turn, with the same settings: continue in it.
        if run.provider == .claude, continueClaudeProcess(id, prompt: prompt, showPrompt: showPrompt) { return }
        let input = AgentCommand.Input(
            provider: run.provider,
            executable: executable,
            prompt: prompt,
            model: run.model,
            mode: run.mode,
            permission: run.permission,
            instructions: run.instructions,
            workingDirectory: run.workingDirectory,
            resumeSessionID: run.providerSessionID,
            forkSession: forkNext.contains(id),
            accountEnvironment: accountEnvironment(run.profileID),
            runID: id,
            bridge: bridge(for: id),
            thinkingDisplay: run.provider == .claude && claudeThinkingDisplay[executable] == true,
            effort: run.provider == .claude ? run.effort : nil
        )
        // The flag probe runs Claude Code on this Mac: not for a session on another machine.
        if run.provider == .claude, !run.isRemote, claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
        let spec = placed(AgentCommand.spec(input), for: run)
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        let process = AgentProcess(spec: spec)
        turns[id] = TurnState()
        process.onLines = { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines {
                    self.handle(line: line, for: id)
                }
            }
        }
        process.onExit = { [weak self, weak process] status, stderr in
            Task { @MainActor in self?.processExited(id, status: status, stderr: stderr, process: process) }
        }
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        do {
            try process.start()
        } catch {
            turns[id] = nil
            replace(run)
            update(id) { $0.move(to: .failed, detail: tr("ws.error.launch", error.localizedDescription)) }
            append(id, RunEvent(kind: .error, text: tr("ws.error.launch", error.localizedDescription)))
            return
        }
        processes[id] = process
        forkNext.remove(id)
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)
        append(id, RunEvent(kind: .system, text: spec.displayCommand, tool: "launch"))
    }

    /// Opens the agent's connection when you open an idle session (an existing conversation), so your first message goes
    /// straight in instead of waiting for a process to start: Claude Code waits on stdin, Codex has its thread open, an
    /// ACP agent has its session loaded. Like a session parked after a turn, it closes when left alone.
    func prewarm(_ id: UUID) {
        guard let run = run(id), run.canContinue, !run.status.isActive, !run.archived, processes[id] == nil,
              run.providerSessionID != nil, !forkNext.contains(id), let executable = launchExecutable(run),
              run.isRemote || WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else { return }
        switch run.provider {
        case .claude:
            guard claudeIdle[id] == nil else { return }
            if !run.isRemote, claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
            var spec = placed(AgentCommand.spec(AgentCommand.Input(
                provider: .claude, executable: executable, prompt: "", model: run.model, mode: run.mode, permission: run.permission,
                instructions: run.instructions, workingDirectory: run.workingDirectory, resumeSessionID: run.providerSessionID,
                accountEnvironment: accountEnvironment(run.profileID), runID: id, bridge: bridge(for: id),
                thinkingDisplay: claudeThinkingDisplay[executable] == true, effort: run.effort)), for: run)
            spec.initialInput = []
            let process = AgentProcess(spec: spec)
            process.onLines = { [weak self, weak process] lines in
                Task { @MainActor in
                    // While it only waits, nothing it prints is a turn (a failed resume must not fail the session).
                    guard let self, let process, self.processes[id] === process else { return }
                    for line in lines { self.handle(line: line, for: id) }
                }
            }
            process.onExit = { [weak self, weak process] status, stderr in
                Task { @MainActor in self?.processExited(id, status: status, stderr: stderr, process: process) }
            }
            guard (try? process.start()) != nil else { return }
            parkWarmClaude(id, process, key: claudeKey(run))
        case .codex:
            guard settings.codexAppServer, !codexExecOnly.contains(executable), codexServers[id] == nil else { return }
            connectCodexServer(id, executable: executable, prompt: nil)
        case .gemini, .opencode, .cursor, .grok, .acp:
            guard !acpFallback.contains(executable), acpClients[id] == nil else { return }
            connectAcp(id, executable: executable, prompt: nil)
        case .antigravity:
            // Not ahead of time: signing in could open Google's page just because you looked at the session.
            return
        }
    }

    // MARK: Agent Output

    private func handle(line: String, for id: UUID) {
        guard let run = run(id) else { return }
        switch run.provider {
        case .claude:
            let parsed = ClaudeStreamParser.parse(line)
            if processes[id] == nil, claudeIdle[id] != nil, parsed.contains(where: ClaudeStreamEvent.isWork) { wakeParkedClaude(id) }
            for event in parsed { handleClaude(event, id: id) }
        case .codex:
            let parsed = CodexStreamParser.parse(line)
            for event in parsed { handleCodex(event, id: id) }
        case .gemini:
            let parsed = GeminiStreamParser.parse(line)
            for event in parsed { handleGemini(event, id: id) }
        case .opencode, .cursor, .grok, .antigravity, .acp:
            break // ACP sessions read their own messages (WorkspaceManager+Acp).
        }
    }

    private func handleGemini(_ event: GeminiStreamEvent, id: UUID) {
        switch event {
        case .initialized(let session, let model):
            update(id) {
                $0.providerSessionID = session
                if let model, !model.isEmpty { $0.resolvedModel = model }
            }
        case .text(let text, let delta):
            if let live = turns[id]?.liveTextID {
                mutateEvent(id, live) { $0.text = delta ? $0.text + text : text }
            } else {
                let event = RunEvent(kind: .assistant, text: text, state: .running)
                turns[id]?.liveTextID = event.id
                append(id, event)
            }
            if !delta { finishLiveText(id) }
        case .toolUse(let callID, let name, let input):
            finishLiveText(id)
            let event = RunEvent(kind: .tool, text: ToolSummary.describe(tool: name, input: input.dictionary), tool: name,
                                 callID: callID, detail: ToolSummary.json(input.object), state: .running)
            turns[id]?.toolEvents[callID] = event.id
            turns[id]?.toolNames[callID] = name
            turns[id]?.toolInputs[callID] = input
            recap?.toolUse(name)
            append(id, event)
        case .toolResult(let callID, let output, let isError):
            if let eventID = turns[id]?.toolEvents[callID] {
                mutateEvent(id, eventID) {
                    $0.output = RunEvent.clip(output)
                    $0.state = isError ? .failed : .done
                }
            }
            if !isError, let name = turns[id]?.toolNames[callID], let input = turns[id]?.toolInputs[callID] {
                for change in ToolSummary.fileChanges(tool: name, input: input.dictionary) {
                    recordFileChange(id, path: change.path, kind: change.kind)
                }
            }
        case .warning(let message):
            append(id, RunEvent(kind: .system, text: message))
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        case .result(let isError, let message, var usage):
            finishLiveText(id)
            if usage.durationSeconds == nil, let started = turns[id]?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = turns[id]?.stopping ?? false
            update(id) { run in
                run.usage.add(usage)
                if stopping {
                    run.move(to: .stopped)
                } else if isError {
                    run.move(to: .failed, detail: message)
                } else {
                    run.move(to: .completed)
                }
            }
            if isError && !stopping { append(id, RunEvent(kind: .error, text: message ?? tr("ws.event.failed", "error"))) }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: isError && !stopping ? .failed : .done))
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
        }
    }

    private func handleClaude(_ event: ClaudeStreamEvent, id: UUID) {
        switch event {
        case .initialized(let session, let model):
            update(id) {
                $0.providerSessionID = session
                if let model, !model.isEmpty { $0.resolvedModel = model }
            }
        case .textDelta(let text):
            if let live = turns[id]?.liveTextID {
                mutateEvent(id, live) { $0.text += text }
            } else {
                let event = RunEvent(kind: .assistant, text: text, state: .running)
                turns[id]?.liveTextID = event.id
                append(id, event)
            }
        case .text(let text):
            if let live = turns[id]?.liveTextID {
                mutateEvent(id, live) { $0.text = text; $0.state = .done }
                turns[id]?.liveTextID = nil
                turns[id]?.lastTextID = live
            } else {
                let event = RunEvent(kind: .assistant, text: text, state: .done)
                turns[id]?.lastTextID = event.id
                append(id, event)
            }
        case .thinkingDelta(let text, let starts):
            if starts {
                closeThinking(id)
                turns[id]?.thinkingOpen = true
            }
            guard !text.isEmpty else { return }
            if let live = turns[id]?.liveThinkingID {
                mutateEvent(id, live) { $0.text += text }
            } else {
                let event = RunEvent(kind: .thinking, text: text, state: .running)
                turns[id]?.liveThinkingID = event.id
                append(id, event)
            }
        case .blockStopped:
            closeThinking(id)
        case .thinking(let text):
            closeThinking(id)
            // The complete copy of a block that streamed: keep the streamed text unless this one has more to say.
            if let state = turns[id], !state.streamedThinking.isEmpty {
                let streamed = turns[id]?.streamedThinking.removeFirst()
                if let streamed = streamed ?? nil {
                    if !text.isEmpty { mutateEvent(id, streamed) { $0.text = text } }
                    return
                }
            }
            if !text.isEmpty { append(id, RunEvent(kind: .thinking, text: text)) }
        case .toolUse(let callID, let name, let input, let nested):
            finishLiveText(id)
            let summary = ToolSummary.describe(tool: name, input: input.dictionary)
            let event = RunEvent(kind: .tool, text: nested ? "↳ " + summary : summary, tool: name, callID: callID,
                                 detail: ToolSummary.json(input.object), state: .running)
            turns[id]?.toolEvents[callID] = event.id
            turns[id]?.toolNames[callID] = name
            turns[id]?.toolInputs[callID] = input
            recap?.toolUse(name)
            append(id, event)
            // Claude Code's own task list (not a subagent's) becomes the Tasks strip above the composer.
            if name == "TodoWrite", !nested, let steps = RunTasks.claude(input.dictionary) { setTasks(id, steps) }
        case .toolResult(let callID, let output, let isError):
            if let eventID = turns[id]?.toolEvents[callID] {
                mutateEvent(id, eventID) {
                    $0.output = RunEvent.clip(output)
                    $0.state = isError ? .failed : .done
                }
            }
            if !isError, let name = turns[id]?.toolNames[callID], let input = turns[id]?.toolInputs[callID] {
                for change in ToolSummary.fileChanges(tool: name, input: input.dictionary) {
                    recordFileChange(id, path: change.path, kind: change.kind)
                }
            }
        case .usage(let messageID, let tokens, let model):
            turns[id]?.messageUsage[messageID] = tokens
            turns[id]?.lastContext = tokens.context + tokens.output
            if let model, !model.isEmpty, run(id)?.resolvedModel == nil { update(id) { $0.resolvedModel = model } }
        case .permissionRequest(let requestID, let tool, let input, let suggestions, _):
            finishLiveText(id)
            // A question is answered, not approved: the answers go back as the tool's input.
            if tool == "AskUserQuestion" {
                let items = ClaudeStreamParser.questions(from: input)
                if !items.isEmpty {
                    let pending = PendingQuestion(id: requestID, runID: id, questions: items,
                                                  origin: .claude(requestID: requestID, input: input), created: Date())
                    questions[id, default: []].append(pending)
                    update(id) { $0.move(to: .waitingApproval) }
                    if let run = run(id) { onQuestion?(run, pending) }
                    return
                }
            }
            // In Plan mode the plan becomes a card with "Carry out"; Claude Code waits for your word instead of leaving plan mode.
            if tool == "ExitPlanMode", run(id)?.mode == .plan {
                let plan = ((input.dictionary["plan"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !plan.isEmpty { append(id, RunEvent(kind: .assistant, text: plan, tool: "plan", state: .done)) }
                processes[id]?.send(ClaudeStreamParser.permissionResponse(
                    requestID: requestID, allow: false, input: input,
                    message: "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."))
                return
            }
            // Rights you raised after Claude Code started (or that it could not take over live) still count.
            if let run = run(id), LiveRights.coversClaude(tool: tool, permission: run.permission, mode: run.mode) {
                processes[id]?.send(ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: input))
                return
            }
            let summary = ToolSummary.describe(tool: tool, input: input.dictionary)
            let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID,
                                 detail: ToolSummary.json(input.object), state: .pending)
            append(id, event)
            let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: input,
                                            suggestions: suggestions, eventID: event.id, created: Date())
            approvals[id, default: []].append(pending)
            update(id) { $0.move(to: .waitingApproval) }
            if let run = run(id) { onApproval?(run, pending) }
        case .result(let result):
            finishLiveText(id)
            // A steering message cut this segment short: the turn goes on with the new message.
            if turns[id]?.steered == true, turns[id]?.stopping != true, result.endedBySteer {
                turns[id]?.steeredUsage.append(result.usage)
                // A thinking block the steer cut off gets no complete copy: start the pairing afresh.
                closeThinking(id)
                turns[id]?.streamedThinking.removeAll()
                return
            }
            turns[id]?.steered = false
            closeThinking(id)
            // Stopped by a usage limit: remember when it resets, for "Resume at reset".
            if turns[id]?.stopping != true {
                let evidence = FailureEvidence(terminalReason: result.terminalReason, apiErrorStatus: result.apiErrorStatus,
                                               isError: result.isError, rateLimitRejected: !(turns[id]?.limitWindows.isEmpty ?? true),
                                               rateLimitResets: turns[id]?.limitWindows ?? [:], messageText: result.text)
                if case .usageLimit(let resetAt) = FailureClassifier.classify(evidence), result.isError { limitedTurns[id] = .some(resetAt) }
            }
            var usage = result.usage
            let state = turns[id]
            // If turn completion reported no tokens, sum up individual message counts.
            if (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0) == 0, let messages = state?.messageUsage, !messages.isEmpty {
                usage.inputTokens = messages.values.reduce(0) { $0 + $1.input }
                usage.outputTokens = messages.values.reduce(0) { $0 + $1.output }
                usage.cacheReadTokens = messages.values.reduce(0) { $0 + $1.cacheRead }
                usage.cacheWriteTokens = messages.values.reduce(0) { $0 + $1.cacheWrite }
            }
            usage.contextTokens = state?.lastContext
            if usage.durationSeconds == nil, let started = state?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = state?.stopping ?? false
            update(id) { run in
                for segment in state?.steeredUsage ?? [] { run.usage.add(segment) }
                run.usage.add(usage)
                if let session = result.sessionID { run.providerSessionID = session }
                if stopping {
                    run.move(to: .stopped)
                } else if result.isError {
                    run.move(to: .failed, detail: result.text.isEmpty ? result.subtype : result.text)
                } else {
                    run.move(to: .completed)
                }
            }
            if result.isError && !stopping {
                // Claude Code writes an API error as an answer first, then again as the result: show it once, as the error.
                let failure = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !failure.isEmpty, let echoed = state?.lastTextID,
                   events[id]?.last(where: { $0.id == echoed })?.text.trimmingCharacters(in: .whitespacesAndNewlines) == failure {
                    mutateEvent(id, echoed) { $0.kind = .error; $0.text = result.text; $0.state = nil }
                } else {
                    append(id, RunEvent(kind: .error, text: result.text.isEmpty ? tr("ws.event.failed", result.subtype) : result.text))
                }
            }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: result.permissionDenials),
                                state: result.isError && !stopping ? .failed : .done))
            expireApprovals(id)
            questions[id] = nil
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
            // Turn finished: keep Claude Code waiting for the next message instead of closing it.
            parkClaudeProcess(id, stopping: stopping)
        case .notice(let text):
            if text == "compact" { append(id, RunEvent(kind: .system, text: tr("ws.event.compacted"))) }
        case .rateLimits(let event):
            onRateLimits?()
            if let event { noteClaudeLimit(id, event) }
        case .planWindow(let reading):
            if let run = run(id) { onPlanWindow?(reading, run.profileID) }
        }
    }

    func handleCodex(_ event: CodexStreamEvent, id: UUID) {
        switch event {
        case .threadStarted(let thread):
            update(id) { $0.providerSessionID = thread }
        case .message(let text):
            append(id, RunEvent(kind: .assistant, text: text, state: .done))
        case .reasoning(let text):
            append(id, RunEvent(kind: .thinking, text: text))
        case .commandStarted(let callID, let command):
            let event = RunEvent(kind: .tool, text: "shell · " + ToolSummary.oneLine(command, 120), tool: "shell",
                                 callID: callID, detail: command, state: .running)
            turns[id]?.toolEvents[callID] = event.id
            append(id, event)
        case .commandFinished(let callID, let command, let output, let exitCode):
            let failed = (exitCode ?? 0) != 0
            if let eventID = turns[id]?.toolEvents[callID] ?? timeline(id).last(where: { $0.callID == callID && $0.kind == .tool })?.id {
                mutateEvent(id, eventID) {
                    $0.output = RunEvent.clip(output)
                    $0.state = failed ? .failed : .done
                }
            } else {
                append(id, RunEvent(kind: .tool, text: "shell · " + ToolSummary.oneLine(command, 120), tool: "shell",
                                    callID: callID, detail: command, output: RunEvent.clip(output), state: failed ? .failed : .done))
            }
        case .fileChanges(_, let changes):
            for change in changes { recordFileChange(id, path: change.path, kind: change.kind) }
        case .toolCall(let callID, let name, let detail, let finished, let failed):
            if let eventID = turns[id]?.toolEvents[callID] {
                if finished { mutateEvent(id, eventID) { $0.state = failed ? .failed : .done } }
            } else {
                let event = RunEvent(kind: .tool, text: detail.isEmpty ? name : "\(name) · \(detail)", tool: name, callID: callID,
                                     state: finished ? (failed ? .failed : .done) : .running)
                turns[id]?.toolEvents[callID] = event.id
                append(id, event)
            }
        case .turnCompleted(var usage):
            if let started = turns[id]?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = turns[id]?.stopping ?? false
            update(id) { run in
                run.usage.add(usage)
                run.move(to: stopping ? .stopped : .completed)
            }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: .done))
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        case .usageLimited:
            limitedTurns[id] = .some(nil)
        default:
            // Events only `codex app-server` sends: live text, reasoning, output, usage, the end of a turn.
            handleCodexServerEvent(event, id: id)
        }
    }

    private func processExited(_ id: UUID, status: Int32, stderr: String, process: AgentProcess? = nil) {
        // A Claude Code process that waited between turns ended (closed when idle, or gone): nothing else to do.
        if let process, claudeIdle[id]?.process === process {
            claudeIdle[id] = nil
            return
        }
        if let process, let current = processes[id], current !== process { return }
        processes[id] = nil
        // A question can no longer be answered once the process is gone.
        questions[id] = nil
        let state = turns[id]
        turns[id] = nil
        finishLiveText(id)
        expireApprovals(id)
        // Whatever was still running is settled: nothing may stay open after the process is gone.
        settleOpenWork(id, reason: state?.stopping == true ? .stopped : .processExited)
        guard let state, !state.finished else {
            scheduleGitRefresh(id, delay: 0.2)
            sendQueued(id)
            return
        }
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
            scheduleGitRefresh(id, delay: 0.2)
            sendPendingNow(id)
            return
        } else {
            let detail = Self.cleanError(state.lastError ?? stderr, status: status)
            update(id) { $0.move(to: .failed, detail: detail) }
            append(id, RunEvent(kind: .error, text: detail))
            turnDidFinish(id)
        }
        scheduleGitRefresh(id, delay: 0.2)
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
        let lines = stripped.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

    func resultLine(_ usage: TurnUsage, denials: Int) -> String {
        var parts: [String] = []
        if let seconds = usage.durationSeconds { parts.append(AgentPathFormat.duration(seconds)) }
        let tokens = usage.ownTokens
        if tokens > 0 { parts.append(TokenTally.format(tokens) + " tokens") }
        if let cost = usage.reportedCostUSD, settings.showCost { parts.append(AgentPathFormat.cost(cost)) }
        if denials > 0 { parts.append(tr("ws.event.denials", denials)) }
        return parts.joined(separator: " · ")
    }

    /// Ends the thinking block being streamed; it then waits for its complete copy (see `.thinking`).
    func closeThinking(_ id: UUID) {
        guard turns[id]?.thinkingOpen == true else { return }
        turns[id]?.thinkingOpen = false
        let live = turns[id]?.liveThinkingID
        if let live { mutateEvent(id, live) { $0.state = .done } }
        turns[id]?.liveThinkingID = nil
        turns[id]?.streamedThinking.append(live)
    }

    func finishLiveText(_ id: UUID) {
        guard let live = turns[id]?.liveTextID else { return }
        mutateEvent(id, live) { $0.state = .done }
        turns[id]?.liveTextID = nil
    }

    func recordFileChange(_ id: UUID, path: String, kind: String) {
        let base = run(id)?.workingDirectory ?? ""
        let shown = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        append(id, RunEvent(kind: .fileChange, text: shown, tool: kind, detail: path))
        update(id) { $0.lastChangeAt = Date() }
        scheduleGitRefresh(id, delay: 1.5)
    }

    // MARK: Approvals

    enum Decision { case allow, always, deny }

    func decide(_ runID: UUID, requestID: String, _ decision: Decision) {
        if decideCodex(runID, requestID: requestID, decision) { return }
        if decideAcp(runID, requestID: requestID, decision) { return }
        guard let pending = approvals[runID]?.first(where: { $0.id == requestID }), let process = processes[runID] else {
            expireApproval(runID, requestID: requestID)
            return
        }
        let line: String
        switch decision {
        case .allow:
            line = ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: pending.input)
        case .always:
            line = ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: pending.input,
                                                         rules: pending.canAlways ? pending.suggestions : nil)
        case .deny:
            line = ClaudeStreamParser.permissionResponse(requestID: requestID, allow: false, input: pending.input)
        }
        process.send(line)
        approvals[runID]?.removeAll { $0.id == requestID }
        recap?.decision(allowed: decision != .deny)
        mutateEvent(runID, pending.eventID) { $0.state = decision == .deny ? .denied : .allowed }
        if (approvals[runID]?.isEmpty ?? true), (questions[runID]?.isEmpty ?? true) { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
    }

    func expireApproval(_ runID: UUID, requestID: String) {
        guard let pending = approvals[runID]?.first(where: { $0.id == requestID }) else { return }
        approvals[runID]?.removeAll { $0.id == requestID }
        mutateEvent(runID, pending.eventID) { $0.state = .expired }
        onApprovalGone?(requestID)
    }

    func expireApprovals(_ runID: UUID) {
        for pending in approvals[runID] ?? [] { expireApproval(runID, requestID: pending.id) }
        approvals[runID] = nil
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

    // MARK: Watching pull requests

    /// Watches this pull request for the session: CI, reviews, comments and the merge become news in the timeline, and
    /// what the agent can act on goes to it as a message.
    func watchPullRequest(_ id: UUID, url: URL?, wakeAgent: Bool = true) {
        update(id) { $0.prWatch = url.map { PullRequestWatch(url: $0.absoluteString, wakeAgent: wakeAgent) } }
        if url != nil { checkPullRequestWatches(force: true) }
    }

    /// Looks at each watched pull request at most every two minutes.
    func checkPullRequestWatches(force: Bool = false) {
        guard let fetch = pullRequestSnapshot else { return }
        let now = Date()
        for run in runs {
            guard let watch = run.prWatch, watch.state == "open", !run.archived, !watchesInFlight.contains(run.id),
                  force || watch.checkedAt.map({ now.timeIntervalSince($0) >= 120 }) ?? true,
                  let url = URL(string: watch.url) else { continue }
            let id = run.id
            watchesInFlight.insert(id)
            Task { [weak self] in
                let snapshot = await fetch(url)
                self?.watchesInFlight.remove(id)
                guard let self, let snapshot, let current = self.run(id)?.prWatch, current.url == watch.url else { return }
                self.pullRequestChanged(id, old: current, new: snapshot)
            }
        }
    }

    private func pullRequestChanged(_ id: UUID, old: PullRequestWatch, new: PullRequestSnapshot) {
        let now = Date()
        // The first look only sets what counts as seen.
        guard old.checkedAt != nil else {
            update(id) { $0.prWatch = PullRequestNews.updated(old, with: new, at: now) }
            return
        }
        let lines = PullRequestNews.lines(old: old, new: new)
        let wake = old.wakeAgent && PullRequestNews.needsAgent(old: old, new: new)
        update(id) { $0.prWatch = PullRequestNews.updated(old, with: new, at: now) }
        guard !lines.isEmpty else { return }
        append(id, RunEvent(kind: .system, text: tr("ws.prwatch.news") + "\n" + lines.joined(separator: "\n"), tool: "prwatch"))
        guard wake, let run = run(id) else { return }
        let message = PullRequestNews.message(url: old.url, lines: lines)
        // The news line above already shows it: the agent gets it without a bubble of yours.
        if run.canContinue && processes[id] == nil { sendHidden(id, text: message) } else { enqueue(id, text: message) }
    }

    /// Removes a session from Nook. The directory or worktree is preserved (removed separately); never allows deleting an active session.
    func delete(_ id: UUID) {
        guard let run = run(id), !run.status.isActive, processes[id] == nil else { return }
        if let root = run.repoRoot, let git = sessionGit(for: run), run.checkpoints != nil {
            Task.detached(priority: .utility) { git.removeCheckpoints(root, session: id) }
        }
        runs.removeAll { $0.id == id }
        events[id] = nil
        timelineUse[id] = nil
        evictedTimelines.remove(id)
        evictedAnswers[id] = nil
        // Per-session state that would otherwise stay for every session ever made, until Nook quits.
        gitRefreshes.removeValue(forKey: id)?.cancel()
        codexTotals[id] = nil
        codexSubagents[id] = nil
        openPullRequests[id] = nil
        approvals[id] = nil
        queued[id] = nil
        questions[id] = nil
        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        limitResumes.removeValue(forKey: id)?.cancel()
        warmPrompts[id] = nil
        awaitingCheckpoint[id] = nil
        pendingSendNow[id] = nil
        codexLimitSnapshots[id] = nil
        limitedTurns[id] = nil
        backgroundWork.remove(id)
        mcpAppContexts[id] = nil
        let appFolder = Self.mcpAppFolder(id)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: appFolder) }
        stopCoordinators[id] = nil
        sessionApprovals[id] = nil
        backgroundRoster[id] = nil
        claudeChangedDuringTurn.remove(id)
        git[id] = nil
        store.deleteEvents(id)
        if selectedRunID == id { selectedRunID = runs.first { !$0.archived }?.id }
        scheduleSave()
    }

    private func applyAutoArchive() {
        let days = settings.autoArchiveDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var changed = false
        for index in runs.indices where !runs[index].archived && !runs[index].status.isActive && runs[index].updatedAt < cutoff {
            runs[index].archived = true
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: Git

    func refreshGit(_ id: UUID) {
        guard let run = run(id), let git = sessionGit(for: run), run.repoRoot != nil else { return }
        let directory = run.workingDirectory
        let base = run.baseBranch
        var snapshot = self.git[id] ?? GitSnapshot(status: nil, divergence: nil, error: nil, updated: Date(), loading: true)
        snapshot.loading = true
        self.git[id] = snapshot
        Task.detached(priority: .utility) {
            var status: GitStatus?
            var problem: String?
            var divergence: (ahead: Int, behind: Int)?
            if git.remote != nil || FileManager.default.fileExists(atPath: directory) {
                do { status = try git.status(directory) } catch let failure { problem = failure.localizedDescription }
                if let base { divergence = git.divergence(directory, base: base) }
            } else {
                problem = tr("ws.error.folderGone", directory)
            }
            let result = (status: status, divergence: divergence, problem: problem)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.git[id] = GitSnapshot(status: result.status, divergence: result.divergence, error: result.problem,
                                           updated: Date(), loading: false)
                if let status = result.status { self.update(id, save: false) { $0.changedFiles = status.files.count } }
            }
        }
    }

    func scheduleGitRefresh(_ id: UUID, delay: TimeInterval) {
        gitRefreshes[id]?.cancel()
        gitRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshGit(id)
        }
    }

    func diff(_ id: UUID, file: GitFileChange) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        return try await Task.detached(priority: .userInitiated) { try git.diff(directory, file: file) }.value
    }

    /// What one turn (from `start` to `end`) did to a file: between the snapshots around it when the session has them,
    /// otherwise the file against its last commit.
    func turnDiff(_ id: UUID, path: String, start: Date, end: Date) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        let around = TurnChanges.checkpoints(run.checkpoints ?? [], start: start, end: end)
        let from = around?.before.ref ?? "HEAD"
        let to = around?.after?.ref
        return try await Task.detached(priority: .userInitiated) { try git.diff(directory, path: path, from: from, to: to) }.value
    }

    /// The lines one turn added and removed per file (between the same snapshots as `turnDiff`), keyed by the path
    /// relative to the session's folder. Binary files count as nothing.
    func turnLines(_ id: UUID, paths: [String], start: Date, end: Date) async throws -> [String: EditLines] {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        let around = TurnChanges.checkpoints(run.checkpoints ?? [], start: start, end: end)
        let from = around?.before.ref ?? "HEAD"
        let to = around?.after?.ref
        // A file outside the folder (the agent's own settings, say) would make git refuse the whole list.
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        let inside = paths.filter { !$0.hasPrefix("/") || $0.hasPrefix(root) }
        let counts = try await Task.detached(priority: .utility) { try git.lineCounts(directory, paths: inside, from: from, to: to) }.value
        return counts.mapValues { EditLines(added: $0.added ?? 0, removed: $0.removed ?? 0) }
    }

    func commit(_ id: UUID, message: String, paths: [String]) async throws -> String {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        guard !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let directory = run.workingDirectory
        let sha = try await Task.detached(priority: .userInitiated) { try git.commit(directory, message: message, paths: paths) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.committed", sha, ToolSummary.oneLine(message, 80))))
        markReviewed(id)
        refreshGit(id)
        return sha
    }

    func push(_ id: UUID) async throws {
        guard let run = run(id), let git = sessionGit(for: run) else { throw StartError.noGit }
        let directory = run.workingDirectory
        guard let branch = await Task.detached(operation: { git.currentBranch(directory) }).value else {
            throw StartError.git(tr("ws.error.detached"))
        }
        let remote = await Task.detached(operation: { git.remotes(directory).contains("origin") ? "origin" : (git.remotes(directory).first ?? "origin") }).value
        try await Task.detached(priority: .userInitiated) { try git.push(directory, remote: remote, branch: branch) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.pushed", branch, remote)))
        refreshGit(id)
    }

    /// owner/repo from remote URL if it is a GitHub repository.
    func githubRepository(_ id: UUID) async -> String? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        let url = await Task.detached(operation: { git.remoteURL(directory) }).value
        return url.flatMap(GitHubRemote.repository(from:))
    }

    /// The forge of the session's folder (GitHub, GitLab, Bitbucket…), from its remote; nil without a recognisable remote.
    func remoteRepository(_ id: UUID) async -> RemoteRepository? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        let url = await Task.detached(operation: { git.remoteURL(directory) }).value
        return SourceForge.repository(remoteURL: url)
    }

    func currentBranch(_ id: UUID) async -> String? {
        guard let run = run(id), let git = sessionGit(for: run) else { return nil }
        let directory = run.workingDirectory
        return await Task.detached(operation: { git.currentBranch(directory) }).value
    }

    /// Deletes a session's worktree. Never while the session is running; uncommitted changes require `force`.
    func removeWorktree(_ id: UUID, force: Bool) async throws {
        guard let run = run(id), let worktree = run.worktreePath, let repo = run.repoRoot, let git = sessionGit(for: run) else { return }
        guard processes[id] == nil, !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let others = runs.filter { $0.id != id && $0.status.isActive && $0.workingDirectory == worktree }
        guard others.isEmpty else { throw StartError.git(tr("ws.error.busy")) }
        try await Task.detached(priority: .userInitiated) { try git.removeWorktree(repo: repo, path: worktree, force: force) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeRemoved", AgentPathFormat.tilde(worktree))))
        update(id) { $0.statusDetail = "worktreeRemoved" }
        self.git[id] = nil
        refreshWorktrees()
    }

    /// The session's files are there to snapshot: its worktree, or its folder.
    func canSnapshot(_ run: WorkspaceRun) -> Bool {
        // On another machine git there answers for itself (a folder that is gone fails the snapshot, nothing more).
        if run.isRemote { return true }
        return run.isolation == .worktree ? worktreeExists(run) : FileManager.default.fileExists(atPath: run.workingDirectory)
    }

    func worktreeExists(_ run: WorkspaceRun) -> Bool {
        guard let path = run.worktreePath else { return false }
        if run.isRemote { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// All worktrees across repositories containing sessions, with linked sessions and change statuses.
    func refreshWorktrees() {
        guard let git = gitService else { return }
        let repos = Array(Set(runs.compactMap(\.repoRoot))).sorted()
        let snapshot = runs
        worktreesLoading = true
        Task.detached(priority: .utility) {
            var rows: [WorktreeRow] = []
            for repo in repos where FileManager.default.fileExists(atPath: repo) {
                guard let list = try? git.worktrees(repo) else { continue }
                for worktree in list {
                    let path = WorkspacePathPolicy.normalize(worktree.path)
                    let linked = snapshot.filter { WorkspacePathPolicy.normalize($0.workingDirectory) == path }
                    // Only show root workspace if a session is actively using it.
                    if worktree.isMain && linked.isEmpty { continue }
                    var row = WorktreeRow(repoRoot: repo, worktree: worktree, runIDs: linked.map(\.id))
                    if FileManager.default.fileExists(atPath: worktree.path) {
                        row.changedFiles = git.changedFileCount(worktree.path)
                        let base = linked.compactMap(\.baseBranch).first
                        row.baseBranch = base
                        if let base, let divergence = git.divergence(worktree.path, base: base) {
                            row.ahead = divergence.ahead
                            row.behind = divergence.behind
                        }
                    }
                    rows.append(row)
                }
            }
            await MainActor.run { [weak self, rows] in
                self?.worktreeRows = rows
                self?.worktreesLoading = false
            }
        }
    }

    /// The worktree deleting this session would leave unused (`WorktreeCleanup`), offered to remove along with it.
    func orphanedWorktree(_ id: UUID) -> (repo: String, path: String)? {
        guard let run = run(id), !run.isRemote, let repo = run.repoRoot else { return nil }
        let others = runs.filter { $0.id != id }.flatMap { [$0.workingDirectory] + ($0.worktreePath.map { [$0] } ?? []) }
        guard let path = WorktreeCleanup.orphaned(worktree: run.worktreePath, otherFolders: others),
              WorkspacePathPolicy.normalize(path) != WorkspacePathPolicy.normalize(repo) else { return nil }
        return (repo, path)
    }

    /// Deletes a session and then its worktree. Git refuses a worktree with changes that were never committed; that is
    /// reported and the worktree stays, so nothing you did not commit is lost.
    func deleteWithWorktree(_ id: UUID) {
        guard let worktree = orphanedWorktree(id) else { delete(id); return }
        guard run(id)?.status.isActive == false else { return }
        delete(id)
        // `delete` leaves a session whose process is still there; its worktree stays with it.
        guard run(id) == nil else { return }
        Task {
            do {
                try await removeWorktree(repo: worktree.repo, path: worktree.path, force: false)
                ToastCenter.shared.success(tr("ws.worktree.removed"))
            } catch {
                ToastCenter.shared.error(error, title: tr("ws.worktree.removeFailed"))
            }
        }
    }

    /// Removes a worktree that is not linked to any active session (from the overview).
    func removeWorktree(repo: String, path: String, force: Bool) async throws {
        guard let git = gitService else { throw StartError.noGit }
        let target = WorkspacePathPolicy.normalize(path)
        guard !runs.contains(where: { $0.status.isActive && WorkspacePathPolicy.normalize($0.workingDirectory) == target }) else {
            throw StartError.git(tr("ws.error.busy"))
        }
        try await Task.detached(priority: .userInitiated) { try git.removeWorktree(repo: repo, path: path, force: force) }.value
        for run in runs where WorkspacePathPolicy.normalize(run.workingDirectory) == target {
            append(run.id, RunEvent(kind: .system, text: tr("ws.event.worktreeRemoved", AgentPathFormat.tilde(path))))
            update(run.id) { $0.statusDetail = "worktreeRemoved" }
        }
        refreshWorktrees()
    }

    // MARK: Opening

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if !settings.editorBundleID.isEmpty,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.editorBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Opens a file in your editor with the cursor on its line (`EditorLaunch`): the editor from Settings › Workspace, else
    /// the first known editor on this Mac, else the file is shown in Finder. A file is never handed to its default app,
    /// since an agent's link could point at something that runs.
    func openFile(_ target: FileTarget) {
        let url = URL(fileURLWithPath: target.path)
        guard FileManager.default.fileExists(atPath: target.path) else {
            ToastCenter.shared.info(tr("ws.file.missing", AgentPathFormat.tilde(target.path)))
            return
        }
        let chosen = settings.editorBundleID.isEmpty ? nil : settings.editorBundleID
        let bundleID = chosen ?? WorkspaceSettings.installed(WorkspaceSettings.editorCandidates).first?.bundleID
        guard !target.path.hasSuffix(".app"), let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            revealInFinder(target.path)
            return
        }
        let executable = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        if case .process(let tool, let arguments) = EditorLaunch.plan(bundleID: bundleID, appPath: app.path, executable: executable, target: target),
           FileManager.default.isExecutableFile(atPath: tool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return }
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A changed file of a session, by its path in the repository, at an absolute path (nil for a remote session).
    func absolutePath(_ id: UUID, repositoryPath: String) -> String? {
        guard let run = run(id), !run.isRemote else { return nil }
        let root = run.worktreePath ?? run.repoRoot ?? run.workingDirectory
        return ((root as NSString).appendingPathComponent(repositoryPath) as NSString).standardizingPath
    }

    /// Opens a terminal in Nook's own window (set by the app). Used when the built-in terminal is chosen.
    var openBuiltInTerminal: ((_ folder: String) -> Void)?

    func openTerminal(_ path: String) {
        if settings.terminalBundleID == WorkspaceSettings.builtInTerminal, let openBuiltInTerminal {
            openBuiltInTerminal(path)
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let bundle = settings.terminalBundleID.isEmpty || settings.terminalBundleID == WorkspaceSettings.builtInTerminal
            ? "com.apple.Terminal" : settings.terminalBundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// On Nook shutdown: gracefully terminate running agents to prevent orphaned processes.
    func shutdown() {
        for id in Array(codexServers.keys) { closeCodexServer(id) }
        for id in Array(claudeIdle.keys) { closeClaudeProcess(id) }
        for id in Array(acpClients.keys) { closeAcpClient(id) }
        for (id, process) in processes {
            turns[id]?.stopping = true
            process.closeInput()
            process.stop(grace: 1)
        }
        for index in runs.indices where runs[index].status.isActive {
            runs[index].status = .stopped
            runs[index].statusDetail = "interrupted"
            runs[index].turnStartedAt = nil
        }
        if runsLoaded { try? store.saveRuns(runs) }
        for (id, list) in events { try? store.saveEvents(id, list) }
    }

    // MARK: Tracking and Persistence

    func replace(_ run: WorkspaceRun) {
        guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
        runs[index] = run
        scheduleSave()
    }

    func update(_ id: UUID, save: Bool = true, _ change: (inout WorkspaceRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        run.updatedAt = max(run.updatedAt, runs[index].updatedAt)
        runs[index] = run
        if save { scheduleSave() }
    }

    func append(_ id: UUID, _ event: RunEvent) {
        timelineUse[id] = Date()
        if events[id] == nil {
            evictedTimelines.remove(id)
            evictedAnswers[id] = nil
            events[id] = store.loadEvents(id)
        }
        events[id]?.append(event)
        if event.kind != .system || event.tool != "launch" {
            // Every bump republishes `runs` (and redraws what observes it) outside the 50 ms events throttle. A streaming
            // agent appends many events a second, so in between turn boundaries the time moves on at most every 2 s.
            let boundary = event.kind == .user || event.kind == .result || event.kind == .error || event.kind == .approval
            let now = Date()
            if boundary || runs.first(where: { $0.id == id }).map({ now.timeIntervalSince($0.updatedAt) >= 2 }) ?? false {
                update(id, save: false) { $0.updatedAt = now }
            }
        }
        scheduleEventSave(id)
    }

    func mutateEvent(_ id: UUID, _ eventID: UUID, _ change: (inout RunEvent) -> Void) {
        // In place: this runs for every streamed token, and a copy of the list would copy the whole timeline each time.
        guard let index = events[id]?.lastIndex(where: { $0.id == eventID }) else { return }
        change(&events[id]![index])
        scheduleEventSave(id)
    }

    /// Announces a changed timeline: the first change at once, later ones within the same short window together.
    private func eventsDidChange() {
        guard !quietEvents else { return }
        if eventsThrottled {
            eventsDirty = true
            return
        }
        objectWillChange.send()
        eventsThrottled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.eventsPublishInterval)
            guard let self else { return }
            self.eventsThrottled = false
            if self.eventsDirty {
                self.eventsDirty = false
                self.eventsDidChange()
            }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.runsLoaded else { return }
            let runsSnapshot = self.runs
            self.savedRuns = runsSnapshot
            self.store.saveRunsAsync(runsSnapshot)
        }
    }

    func scheduleEventSave(_ id: UUID) {
        guard eventSaves[id] == nil else { return }
        eventSaves[id] = Task { [weak self] in
            // Each save encodes and rewrites the whole timeline (up to RunStore.eventLimit events); while an answer streams,
            // every two seconds is plenty: a crash loses at most the last two seconds of text.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.eventSaves[id] = nil
            // The session list only when it changed since it was last written (a new event bumps `updatedAt`).
            var runsSnapshot: [WorkspaceRun]?
            if self.runsLoaded, self.savedRuns != self.runs {
                runsSnapshot = self.runs
                self.savedRuns = self.runs
            }
            if let list = self.events[id] {
                self.store.saveEventsAsync(id, list, runs: runsSnapshot)
            } else if let runsSnapshot {
                self.store.saveRunsAsync(runsSnapshot)
            }
        }
    }
}

/// owner/repo from a GitHub remote (https or ssh).
enum GitHubRemote {
    static func repository(from url: String) -> String? {
        var rest: Substring
        if let range = url.range(of: "github.com/") {
            rest = url[range.upperBound...]
        } else if let range = url.range(of: "github.com:") {
            rest = url[range.upperBound...]
        } else {
            return nil
        }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        let parts = rest.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else {
            return nil
        }
        return parts.joined(separator: "/")
    }

    /// GitHub comparison page to open a pull request, pre-filled with the branch.
    static func compareURL(repo: String, base: String, head: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let base = base.addingPercentEncoding(withAllowedCharacters: allowed),
              let head = head.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/\(repo)/compare/\(base)...\(head)?expand=1")
    }
}

/// Workspace formatting helpers.
enum AgentPathFormat {
    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func cost(_ usd: Double) -> String {
        usd < 0.01 && usd > 0 ? "< $0.01" : String(format: "$%.2f", usd)
    }
}
