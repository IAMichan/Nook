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
    @Published private(set) var approvals: [UUID: [PendingPermission]] = [:]
    @Published private(set) var git: [UUID: GitSnapshot] = [:]
    @Published private(set) var worktreeRows: [WorktreeRow] = []
    @Published private(set) var worktreesLoading = false
    @Published private(set) var gitAvailable: Bool?
    @Published var selectedRunID: UUID?

    let settings = WorkspaceSettings.shared
    private let store: RunStore
    private var gitService: GitService?

    /// Agent executable path (from AgentHistory) and account environment; configured by AppModel.
    var executable: (RunProvider) -> String? = { _ in nil }
    var accountEnvironment: (String) -> [String: String] = { _ in [:] }
    /// A session is waiting for approval or has finished: AppModel displays it in the notch.
    var onApproval: ((WorkspaceRun, PendingPermission) -> Void)?
    var onApprovalGone: ((String) -> Void)?
    var onTurnFinished: ((WorkspaceRun) -> Void)?
    /// The week recap: sessions Nook runs itself count too, not only the ones in a terminal.
    var recap: RecapStore?

    private var processes: [UUID: AgentProcess] = [:]
    private var turns: [UUID: TurnState] = [:]
    private var saveTask: Task<Void, Never>?
    private var eventSaves: [UUID: Task<Void, Never>] = [:]
    private var gitRefreshes: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose next turn starts as a copy of the conversation (`--fork-session`), so the original keeps going untouched.
    private var forkNext: Set<UUID> = []

    /// State tracked by Nook during a single turn.
    private struct TurnState {
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
    }

    init(store: RunStore = RunStore(directory: NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true))) {
        self.store = store
        runs = store.loadRuns()
        applyAutoArchive()
        Task.detached(priority: .utility) {
            let service = GitService.locate()
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
        }
        launchTurn(id, prompt: config.task, executable: executable)
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
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let run = run(id), run.canContinue, processes[id] == nil else { return }
        guard let executable = executable(run.provider) else {
            update(id) { $0.statusDetail = StartError.noExecutable(run.provider).errorDescription }
            return
        }
        guard WorkspacePathPolicy.verdict(for: run.workingDirectory) == .ok else {
            append(id, RunEvent(kind: .error, text: tr("ws.error.folderGone", run.workingDirectory)))
            return
        }
        loadTimeline(id)
        launchTurn(id, prompt: clean, executable: executable)
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

    private func launchTurn(_ id: UUID, prompt: String, executable: String) {
        guard var run = run(id), processes[id] == nil else { return }
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
            runID: id
        )
        let spec = AgentCommand.spec(input)
        append(id, RunEvent(kind: .user, text: prompt))
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
        process.onExit = { [weak self] status, stderr in
            Task { @MainActor in self?.processExited(id, status: status, stderr: stderr) }
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
        case .thinking(let text):
            append(id, RunEvent(kind: .thinking, text: text))
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
            // Turn finished: close stdin, allowing Claude Code to exit.
            processes[id]?.closeInput()
            if let run = run(id) { onTurnFinished?(run) }
            scheduleGitRefresh(id, delay: 0.5)
        case .notice(let text):
            if text == "compact" { append(id, RunEvent(kind: .system, text: tr("ws.event.compacted"))) }
        }
    }

    private func handleCodex(_ event: CodexStreamEvent, id: UUID) {
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
            if let run = run(id) { onTurnFinished?(run) }
            scheduleGitRefresh(id, delay: 0.5)
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        }
    }

    private func processExited(_ id: UUID, status: Int32, stderr: String) {
        processes[id] = nil
        let state = turns[id]
        turns[id] = nil
        finishLiveText(id)
        expireApprovals(id)
        // Tools that were still running are marked finished/failed.
        if var list = events[id] {
            var changed = false
            for index in list.indices where list[index].state == .running {
                list[index].state = list[index].kind == .assistant ? .done : .failed
                changed = true
            }
            if changed { events[id] = list; scheduleEventSave(id) }
        }
        guard let state, !state.finished else {
            scheduleGitRefresh(id, delay: 0.2)
            return
        }
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
        } else {
            let detail = Self.cleanError(state.lastError ?? stderr, status: status)
            update(id) { $0.move(to: .failed, detail: detail) }
            append(id, RunEvent(kind: .error, text: detail))
            if let run = run(id) { onTurnFinished?(run) }
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

    private func resultLine(_ usage: TurnUsage, denials: Int) -> String {
        var parts: [String] = []
        if let seconds = usage.durationSeconds { parts.append(AgentPathFormat.duration(seconds)) }
        let tokens = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0) + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0)
        if tokens > 0 { parts.append(TokenTally.format(tokens) + " tokens") }
        if let cost = usage.reportedCostUSD, settings.showCost { parts.append(AgentPathFormat.cost(cost)) }
        if denials > 0 { parts.append(tr("ws.event.denials", denials)) }
        return parts.joined(separator: " · ")
    }

    private func finishLiveText(_ id: UUID) {
        guard let live = turns[id]?.liveTextID else { return }
        mutateEvent(id, live) { $0.state = .done }
        turns[id]?.liveTextID = nil
    }

    private func recordFileChange(_ id: UUID, path: String, kind: String) {
        let base = run(id)?.workingDirectory ?? ""
        let shown = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        append(id, RunEvent(kind: .fileChange, text: shown, tool: kind, detail: path))
        update(id) { $0.lastChangeAt = Date() }
        scheduleGitRefresh(id, delay: 1.5)
    }

    // MARK: Approvals

    enum Decision { case allow, always, deny }

    func decide(_ runID: UUID, requestID: String, _ decision: Decision) {
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
        if approvals[runID]?.isEmpty ?? true { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
    }

    private func expireApproval(_ runID: UUID, requestID: String) {
        guard let pending = approvals[runID]?.first(where: { $0.id == requestID }) else { return }
        approvals[runID]?.removeAll { $0.id == requestID }
        mutateEvent(runID, pending.eventID) { $0.state = .expired }
        onApprovalGone?(requestID)
    }

    private func expireApprovals(_ runID: UUID) {
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
        runs.removeAll { $0.id == id }
        events[id] = nil
        approvals[id] = nil
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

    private func scheduleGitRefresh(_ id: UUID, delay: TimeInterval) {
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

    private func replace(_ run: WorkspaceRun) {
        guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
        runs[index] = run
        scheduleSave()
    }

    private func update(_ id: UUID, save: Bool = true, _ change: (inout WorkspaceRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        run.updatedAt = max(run.updatedAt, runs[index].updatedAt)
        runs[index] = run
        if save { scheduleSave() }
    }

    private func append(_ id: UUID, _ event: RunEvent) {
        if events[id] == nil { events[id] = store.loadEvents(id) }
        events[id]?.append(event)
        if event.kind != .system || event.tool != "launch" {
            update(id, save: false) { $0.updatedAt = Date() }
        }
        scheduleEventSave(id)
    }

    private func mutateEvent(_ id: UUID, _ eventID: UUID, _ change: (inout RunEvent) -> Void) {
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
