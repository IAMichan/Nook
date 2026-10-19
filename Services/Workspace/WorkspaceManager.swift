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
    @Published private(set) var runs: [WorkspaceRun] = []
    @Published private(set) var events: [UUID: [RunEvent]] = [:]
    /// Settable within the module: the Codex app-server extension adds and answers requests too.
    @Published var approvals: [UUID: [PendingPermission]] = [:]
    /// Follow-up messages typed while the agent was working; the first goes out as soon as the turn has ended.
    @Published private(set) var queued: [UUID: [String]] = [:]
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
    /// Claude Code processes kept alive after a turn (T3Code's way): the next message goes to the same process, as long
    /// as model, mode and rights are unchanged. With the settings they were started with, and when they close.
    var claudeIdle: [UUID: (process: AgentProcess, key: String)] = [:]
    var claudeIdleClose: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose end-of-turn snapshot is still being made (see captureCheckpoint).
    var checkpointing: Set<UUID> = []
    /// ACP sessions (Gemini CLI, OpenCode, Cursor, Grok), kept alive between turns; their permission requests waiting
    /// for you; and Gemini executables that do not speak ACP (they use the headless mode).
    var acpClients: [UUID: AcpClient] = [:]
    var acpRequests: [String: (rpcID: RPCID, options: [AcpPermissionOption])] = [:]
    var acpFallback: Set<String> = []
    var acpIdleClose: [UUID: Task<Void, Never>] = [:]
    /// Codex reported new limits during a session: AppModel refreshes the usage shown.
    var onRateLimits: (() -> Void)?
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
    var pullRequestLookup: ((_ repo: String, _ branch: String) async -> URL?)?
    var pullRequestCreate: ((_ repo: String, _ title: String, _ body: String, _ head: String, _ base: String) async throws -> URL?)?
    var modelsRefreshed: [RunProvider: Date] = [:]
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
    /// When GitHub was last asked about a branch's pull request ("owner/repo branch"), so it is asked once a minute at most.
    var pullRequestChecked: [String: Date] = [:]
    /// Sessions whose Antigravity sign-in page already opened.
    var antigravitySignIns: Set<UUID> = []

    let settings = WorkspaceSettings.shared
    private let store: RunStore
    private(set) var gitService: GitService?

    /// Agent executable path (from AgentHistory) and account environment; configured by AppModel.
    var executable: (RunProvider) -> String? = { _ in nil }
    var accountEnvironment: (String) -> [String: String] = { _ in [:] }
    /// Runs a project script in a visible terminal (folder, command, title); configured by AppModel.
    var runScript: ((String, String, String) -> Void)?
    /// Nook's workspace bridge for the agent's command line; nil when agents may not use it.
    var bridgeLaunch: () -> BridgeLaunch? = { nil }
    /// A session is waiting for approval or has finished: AppModel displays it in the notch.
    var onApproval: ((WorkspaceRun, PendingPermission) -> Void)?
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
    private var gitRefreshes: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose next turn starts as a copy of the conversation (`--fork-session`), so the original keeps going untouched.
    var forkNext: Set<UUID> = []

    /// State tracked by Nook during a single turn.
    struct TurnState {
        var liveTextID: UUID?
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
    }

    init(store: RunStore = RunStore(directory: NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true))) {
        self.store = store
        runs = store.loadRuns()
        agentModels = AgentModelStore(url: Self.modelStoreURL).load()
        applyAutoArchive()
        // Sessions that were waiting for a usage limit to reset go on waiting.
        for run in runs where run.autoResume == true { armLimitResume(run.id) }
        Task.detached(priority: .utility) {
            let service = GitService.shared
            await MainActor.run { [weak self] in
                self?.gitService = service
                self?.gitAvailable = service != nil
            }
        }
    }

    // MARK: Reading

    func run(_ id: UUID?) -> WorkspaceRun? {
        guard let id else { return nil }
        return runs.first { $0.id == id }
    }

    func timeline(_ id: UUID) -> [RunEvent] {
        if let loaded = events[id] { return loaded }
        return []
    }

    /// Loads timeline from disk if not yet in memory.
    func loadTimeline(_ id: UUID) {
        guard events[id] == nil else { return }
        events[id] = store.loadEvents(id)
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
            info.defaultBase = git.defaultBaseBranch(root, localBranches: branchLists?.local, fallbackBranch: current)
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
                                                   slug: WorktreeNaming.slug(name.replacingOccurrences(of: "/", with: "-"), limit: 60),
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
        let run = WorkspaceRun(
            id: id,
            title: title.isEmpty ? WorktreeNaming.title(from: config.task) : title,
            task: config.task,
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
            changedFiles: nil
        )
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
            // The project's setup (nook.json / t3.json `runOnWorktreeCreate`), visible in a terminal next to the session.
            let setup = await Task.detached(priority: .userInitiated) { ProjectScripts.load(folder: worktreePath) }.value
            for script in setup where script.runOnWorktreeCreate {
                runScript?(worktreePath, script.command, script.name)
                append(id, RunEvent(kind: .system, text: tr("ws.event.setupScript", script.name)))
            }
        }
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
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return id
    }

    /// Changes how the next turn runs: mode, permissions, and model. Only between turns; a running turn keeps its settings.
    func configure(_ id: UUID, mode: ExecutionMode? = nil, permission: PermissionPolicy? = nil, model: String? = nil) {
        guard let run = run(id), !run.status.isActive else { return }
        update(id) {
            if let mode { $0.mode = mode }
            if let permission, run.provider.capabilities.policies.contains(permission) { $0.permission = permission }
            if let model { $0.model = model.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: Turns

    /// Follow-up message. Permitted only when prior turn has finished; concurrent processes for the same session are prevented.
    func send(_ id: UUID, text: String) {
        send(id, text: text, shown: false)
    }

    /// False when the message could not be taken (empty, the session cannot continue, or a turn is running).
    @discardableResult
    private func send(_ id: UUID, text: String, shown: Bool) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let run = run(id), run.canContinue, processes[id] == nil else { return false }
        // The previous turn's snapshot is still being made (a moment): your message shows at once, as in T3Code, and
        // goes out right after it, so this turn's edits stay out of that snapshot.
        if checkpointing.contains(id) {
            if awaitingCheckpoint[id] != nil {
                enqueue(id, text: clean)
            } else {
                loadTimeline(id)
                if !shown { append(id, RunEvent(kind: .user, text: clean)) }
                awaitingCheckpoint[id] = clean
            }
            return true
        }
        guard let executable = executable(run.provider) else {
            update(id) { $0.statusDetail = StartError.noExecutable(run.provider).errorDescription }
            return false
        }
        guard WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else {
            append(id, RunEvent(kind: .error, text: tr("ws.error.folderGone", run.workingDirectory)))
            return false
        }
        loadTimeline(id)
        launchTurn(id, prompt: clean, executable: executable, showPrompt: !shown)
        return true
    }

    /// A turn ended: tell the app, and snapshot the worktree so you can go back to before a later message.
    func turnDidFinish(_ id: UUID) {
        checkUsageLimit(id)
        guard let run = run(id) else { return }
        onTurnFinished?(run)
        captureCheckpoint(id)
    }

    /// Only for sessions in their own worktree (as T3Code): restoring there can never touch your own checkout.
    func captureCheckpoint(_ id: UUID) {
        guard let run = run(id), run.isolation == .worktree, let git = gitService, worktreeExists(run) else { return }
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
                queued[id, default: []].insert(waiting, at: 0)
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
        guard canRevert(id, before: date), let run = run(id), let git = gitService,
              let checkpoint = run.checkpoints?.last(where: { $0.date <= date }) else {
            throw StartError.git(tr("ws.revert.unavailable"))
        }
        let directory = run.workingDirectory
        try await Task.detached(priority: .userInitiated) { try git.restore(directory, to: checkpoint.ref) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.revert.done")))
        refreshGit(id)
    }

    /// Keeps a message for when the current turn is done (T3Code's queue): you keep typing while the agent works.
    func enqueue(_ id: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, run(id) != nil else { return }
        queued[id, default: []].append(clean)
    }

    /// Sends the first queued message now (after a stop or a failure, when the queue waits for you).
    func sendQueuedNow(_ id: UUID) {
        guard let run = run(id), !run.status.isActive, !checkpointing.contains(id), var list = queued[id], !list.isEmpty else { return }
        let next = list.removeFirst()
        queued[id] = list.isEmpty ? nil : list
        send(id, text: next)
    }

    func removeQueued(_ id: UUID, at index: Int) {
        guard var list = queued[id], list.indices.contains(index) else { return }
        list.remove(at: index)
        queued[id] = list.isEmpty ? nil : list
    }

    /// The turn ended well and the process is gone: send the next queued message. After a failure or a stop the queue
    /// waits for you, so nothing goes out on top of a problem.
    func sendQueued(_ id: UUID) {
        // Not while the snapshot of the finished turn is still being made: the next turn's edits must not end up in it.
        guard processes[id] == nil, !checkpointing.contains(id), let run = run(id), run.status == .completed,
              var list = queued[id], !list.isEmpty else { return }
        let next = list.removeFirst()
        queued[id] = list.isEmpty ? nil : list
        send(id, text: next)
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
        if stopCodexServerTurn(id) { return }
        if stopAcpTurn(id) { return }
        guard let process = processes[id] else {
            // No running process: update state only.
            update(id) { $0.move(to: .stopped) }
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
        guard var run = run(id) else { return }
        // Codex speaks app-server when it can (T3Code's way): approvals, questions, steering and live reasoning.
        if run.provider == .codex, settings.codexAppServer, !codexExecOnly.contains(executable) {
            launchCodexServerTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt)
            return
        }
        // Gemini CLI, OpenCode, Cursor and Grok speak ACP (T3Code's way); Gemini falls back to its headless mode.
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
            bridge: bridgeLaunch(),
            thinkingDisplay: run.provider == .claude && claudeThinkingDisplay[executable] == true
        )
        if run.provider == .claude, claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
        let spec = AgentCommand.spec(input)
        if showPrompt { append(id, RunEvent(kind: .user, text: prompt)) }
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
              run.providerSessionID != nil, !forkNext.contains(id), let executable = executable(run.provider),
              WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else { return }
        switch run.provider {
        case .claude:
            guard claudeIdle[id] == nil else { return }
            if claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
            var spec = AgentCommand.spec(AgentCommand.Input(
                provider: .claude, executable: executable, prompt: "", model: run.model, mode: run.mode, permission: run.permission,
                instructions: run.instructions, workingDirectory: run.workingDirectory, resumeSessionID: run.providerSessionID,
                accountEnvironment: accountEnvironment(run.profileID), runID: id, bridge: bridgeLaunch(),
                thinkingDisplay: claudeThinkingDisplay[executable] == true))
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
        case .gemini, .opencode, .cursor, .grok:
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
            for event in parsed { handleClaude(event, id: id) }
        case .codex:
            let parsed = CodexStreamParser.parse(line)
            for event in parsed { handleCodex(event, id: id) }
        case .gemini:
            let parsed = GeminiStreamParser.parse(line)
            for event in parsed { handleGemini(event, id: id) }
        case .opencode, .cursor, .grok, .antigravity:
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
            } else {
                append(id, RunEvent(kind: .assistant, text: text, state: .done))
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
            // A question is answered, not approved (T3Code's way): the answers go back as the tool's input.
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
            // A steering message cut this segment short: the turn goes on with the new message (T3Code's rule).
            if turns[id]?.steered == true, turns[id]?.stopping != true, result.endedBySteer {
                turns[id]?.steeredUsage.append(result.usage)
                // A thinking block the steer cut off gets no complete copy: start the pairing afresh.
                closeThinking(id)
                turns[id]?.streamedThinking.removeAll()
                return
            }
            turns[id]?.steered = false
            closeThinking(id)
            // Stopped by a usage limit (T3Code's test): remember when it resets, for "Resume at reset".
            if result.isError, turns[id]?.stopping != true,
               !(turns[id]?.limitWindows.isEmpty ?? true) || result.terminalReason == "blocking_limit" || result.apiErrorStatus == 429 {
                limitedTurns[id] = .some(UsageLimits.latestReset(turns[id]?.limitWindows ?? [:]))
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
                append(id, RunEvent(kind: .error, text: result.text.isEmpty ? tr("ws.event.failed", result.subtype) : result.text))
            }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: result.permissionDenials),
                                state: result.isError && !stopping ? .failed : .done))
            expireApprovals(id)
            questions[id] = nil
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
            // Turn finished: keep Claude Code waiting for the next message instead of closing it (T3Code's way).
            parkClaudeProcess(id, stopping: stopping)
        case .notice(let text):
            if text == "compact" { append(id, RunEvent(kind: .system, text: tr("ws.event.compacted"))) }
        case .rateLimits(let event):
            onRateLimits?()
            if let event { noteClaudeLimit(id, event) }
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
            if let eventID = turns[id]?.toolEvents[callID] {
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
        // Tools that were still running are marked finished/failed.
        if var list = events[id] {
            var changed = false
            for index in list.indices where list[index].state == .running {
                list[index].state = list[index].kind == .assistant || list[index].kind == .thinking ? .done : .failed
                changed = true
            }
            if changed { events[id] = list; scheduleEventSave(id) }
        }
        guard let state, !state.finished else {
            scheduleGitRefresh(id, delay: 0.2)
            sendQueued(id)
            return
        }
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
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
        let tokens = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0) + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0)
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

    /// Removes a session from Nook. The directory or worktree is preserved (removed separately); never allows deleting an active session.
    func delete(_ id: UUID) {
        guard let run = run(id), !run.status.isActive, processes[id] == nil else { return }
        if let root = run.repoRoot, let git = gitService, run.checkpoints != nil {
            Task.detached(priority: .utility) { git.removeCheckpoints(root, session: id) }
        }
        runs.removeAll { $0.id == id }
        events[id] = nil
        approvals[id] = nil
        queued[id] = nil
        questions[id] = nil
        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        limitResumes.removeValue(forKey: id)?.cancel()
        warmPrompts[id] = nil
        awaitingCheckpoint[id] = nil
        codexLimitSnapshots[id] = nil
        limitedTurns[id] = nil
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
        guard let run = run(id), let git = gitService, run.repoRoot != nil else { return }
        let directory = run.workingDirectory
        let base = run.baseBranch
        var snapshot = self.git[id] ?? GitSnapshot(status: nil, divergence: nil, error: nil, updated: Date(), loading: true)
        snapshot.loading = true
        self.git[id] = snapshot
        Task.detached(priority: .utility) {
            var status: GitStatus?
            var problem: String?
            var divergence: (ahead: Int, behind: Int)?
            if FileManager.default.fileExists(atPath: directory) {
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
        guard let run = run(id), let git = gitService else { throw StartError.noGit }
        let directory = run.workingDirectory
        return try await Task.detached(priority: .userInitiated) { try git.diff(directory, file: file) }.value
    }

    func commit(_ id: UUID, message: String, paths: [String]) async throws -> String {
        guard let run = run(id), let git = gitService else { throw StartError.noGit }
        guard !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let directory = run.workingDirectory
        let sha = try await Task.detached(priority: .userInitiated) { try git.commit(directory, message: message, paths: paths) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.committed", sha, ToolSummary.oneLine(message, 80))))
        markReviewed(id)
        refreshGit(id)
        return sha
    }

    func push(_ id: UUID) async throws {
        guard let run = run(id), let git = gitService else { throw StartError.noGit }
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
        guard let run = run(id), let git = gitService else { return nil }
        let directory = run.workingDirectory
        let url = await Task.detached(operation: { git.remoteURL(directory) }).value
        return url.flatMap(GitHubRemote.repository(from:))
    }

    func currentBranch(_ id: UUID) async -> String? {
        guard let run = run(id), let git = gitService else { return nil }
        let directory = run.workingDirectory
        return await Task.detached(operation: { git.currentBranch(directory) }).value
    }

    /// Deletes a session's worktree. Never while the session is running; uncommitted changes require `force`.
    func removeWorktree(_ id: UUID, force: Bool) async throws {
        guard let run = run(id), let worktree = run.worktreePath, let repo = run.repoRoot, let git = gitService else { return }
        guard processes[id] == nil, !run.status.isActive else { throw StartError.git(tr("ws.error.busy")) }
        let others = runs.filter { $0.id != id && $0.status.isActive && $0.workingDirectory == worktree }
        guard others.isEmpty else { throw StartError.git(tr("ws.error.busy")) }
        try await Task.detached(priority: .userInitiated) { try git.removeWorktree(repo: repo, path: worktree, force: force) }.value
        append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeRemoved", AgentPathFormat.tilde(worktree))))
        update(id) { $0.statusDetail = "worktreeRemoved" }
        self.git[id] = nil
        refreshWorktrees()
    }

    func worktreeExists(_ run: WorkspaceRun) -> Bool {
        guard let path = run.worktreePath else { return false }
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
            await MainActor.run { [weak self] in
                self?.worktreeRows = rows
                self?.worktreesLoading = false
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
        try? store.saveRuns(runs)
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
        if events[id] == nil { events[id] = store.loadEvents(id) }
        events[id]?.append(event)
        if event.kind != .system || event.tool != "launch" {
            update(id, save: false) { $0.updatedAt = Date() }
        }
        scheduleEventSave(id)
    }

    func mutateEvent(_ id: UUID, _ eventID: UUID, _ change: (inout RunEvent) -> Void) {
        guard var list = events[id], let index = list.lastIndex(where: { $0.id == eventID }) else { return }
        change(&list[index])
        events[id] = list
        scheduleEventSave(id)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            let runsSnapshot = self.runs
            self.store.saveRunsAsync(runsSnapshot)
        }
    }

    private func scheduleEventSave(_ id: UUID) {
        guard eventSaves[id] == nil else { return }
        eventSaves[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.eventSaves[id] = nil
            let runsSnapshot = self.runs
            if let list = self.events[id] {
                self.store.saveEventsAsync(id, list, runs: runsSnapshot)
            } else {
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
