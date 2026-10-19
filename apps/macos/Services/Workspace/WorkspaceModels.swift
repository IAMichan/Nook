import Foundation

// The workspace for coding agents: sessions that Nook launches and tracks directly (not in a terminal).
// Everything in this file depends only on Foundation so tests can use it independently.

/// Which agent runs a workspace session. Only agents with a genuine headless mode that Nook can track.
enum RunProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, opencode, cursor, grok, antigravity, acp

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
        // An ACP agent you added; its own name is the account's (see CustomAgents).
        case .acp: return "ACP"
        }
    }

    /// Runs over ACP (Agent Client Protocol).
    var usesACP: Bool {
        switch self {
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp: return true
        case .claude, .codex: return false
        }
    }

    /// Capabilities supported by this agent in headless mode. The UI presents missing features as unavailable.
    var capabilities: ProviderCapabilities {
        switch self {
        case .claude:
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], steering: true, nativeFork: true)
        case .codex:
            // Over app-server Codex asks for approval, streams its answer and reports its context window.
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: false, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass], steering: true)
        case .gemini:
            // Over ACP Gemini asks Nook for permission; its headless fallback cannot (auto_edit or yolo there).
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: false, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass])
        case .opencode, .cursor, .grok, .antigravity, .acp:
            // ACP: permission requests, cancel, streamed messages and thoughts, usage updates with context and cost.
            return ProviderCapabilities(approvals: true, interrupt: true, streamingText: true, planMode: true,
                                        reportsCost: true, reportsContextWindow: true, reportsCacheTokens: true,
                                        policies: [.ask, .acceptEdits, .bypass])
        }
    }

    /// Quick-select models. Empty means: agent default. Custom names can also be typed.
    var suggestedModels: [String] {
        switch self {
        case .claude: return ["", "sonnet", "opus", "haiku"]
        case .codex: return ["", "gpt-5-codex", "gpt-5"]
        case .gemini: return ["", "gemini-2.5-pro", "gemini-2.5-flash"]
        // These agents choose their model in their own settings; Nook passes a name only when you type one.
        case .opencode, .cursor, .grok, .antigravity, .acp: return [""]
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
    /// Allow everything without prompts. Use only when explicitly desired.
    case bypass
    var id: String { rawValue }
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
    /// Snapshots of the worktree, before the first turn and after every turn: "back to here".
    var checkpoints: [RunCheckpoint]? = nil
    /// Stopped on a usage limit: since when, when the limit resets (nil: unknown), and whether the session then goes
    /// on by itself.
    var limitedAt: Date? = nil
    var limitResetAt: Date? = nil
    var autoResume: Bool? = nil
    /// Times in a row Nook went on after a restart cut this session off; back to nil after a turn that ends normally.
    var continuations: Int? = nil
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
    /// The agent's own task list, as it last reported it.
    var tasks: [RunTaskStep]? = nil
    /// The pull request this session watches: what it last saw, so only news wakes it.
    var prWatch: PullRequestWatch? = nil
    /// Runs on another machine over SSH; `workingDirectory` is then a path on that machine.
    var remote: RemoteTarget? = nil

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
        if next == .running, turnStartedAt == nil { turnStartedAt = now }
        if !next.isActive { turnStartedAt = nil }
        return true
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
    /// A GitHub pull request or a GitLab merge request: the two Nook can read.
    static func canWatch(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        let github = url.host?.hasSuffix("github.com") == true && parts.count >= 4 && parts[2] == "pull" && Int(parts[3]) != nil
        return github || url.absoluteString.contains("/-/merge_requests/")
    }

    var url: String
    /// "open", "merged", "closed".
    var state: String = "open"
    /// "success", "failure", "pending", or empty when there are no checks.
    var checks: String = ""
    /// Reviews and comments seen so far.
    var reviewCount: Int = 0
    var commentCount: Int = 0
    /// Send news to the agent as a message (otherwise it only shows in the timeline).
    var wakeAgent: Bool = true
    var checkedAt: Date? = nil
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
}

/// What changed on a watched pull request since the last look: lines for the timeline, and the message for the agent.
enum PullRequestNews {
    static func lines(old: PullRequestWatch, new: PullRequestSnapshot) -> [String] {
        var lines: [String] = []
        if new.state != old.state {
            lines.append(new.state == "merged" ? "The pull request was merged." : new.state == "closed" ? "The pull request was closed." : "The pull request was reopened.")
        }
        if new.checks != old.checks {
            switch new.checks {
            case "failure":
                lines.append("CI failed" + (new.failedChecks.isEmpty ? "." : ": " + new.failedChecks.prefix(8).joined(separator: ", ") + "."))
            case "success" where !old.checks.isEmpty: lines.append("CI passed.")
            default: break
            }
        }
        for review in new.reviews.dropFirst(min(old.reviewCount, new.reviews.count)) {
            let text = review.text.isEmpty ? "" : ": " + ToolSummary.oneLine(review.text, 600)
            lines.append("Review from @\(review.author) (\(review.verdict.lowercased().replacingOccurrences(of: "_", with: " ")))" + text)
        }
        for comment in new.comments.dropFirst(min(old.commentCount, new.comments.count)) {
            lines.append("Comment from @\(comment.author): " + ToolSummary.oneLine(comment.text, 600))
        }
        return lines
    }

    /// Worth waking the agent for: something it can act on (failed CI, reviews, comments), not a merge or a pass.
    static func needsAgent(old: PullRequestWatch, new: PullRequestSnapshot) -> Bool {
        guard new.state == "open" else { return false }
        return (new.checks == "failure" && old.checks != "failure") || new.reviews.count > old.reviewCount
            || new.comments.count > old.commentCount
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
        next.checkedAt = date
        return next
    }
}

/// A single entry in a session's timeline.
struct RunEvent: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, assistant, thinking, tool, fileChange, approval, error, system, result
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

    static func clip(_ text: String, _ limit: Int = outputLimit) -> String {
        let limit = limit == outputLimit && text.contains(McpUI.fence) ? appOutputLimit : limit
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
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

    /// Problem description enum, or nil if valid. Only checks input; manager checks Git and paths.
    var problem: ConfigProblem? {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingTask }
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
        let clean = InjectedPrompt.title(task)
        guard !clean.isEmpty else { return "Nieuwe sessie" }
        if clean.count <= limit { return clean }
        let cut = clean.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// "nook/fix-login-bug-3fa2": recognizable and unique thanks to a slice of the UUID.
    static func branchName(task: String, id: UUID) -> String {
        "nook/" + slug(task, limit: 32) + "-" + String(id.uuidString.prefix(4)).lowercased()
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

/// Concise, language-neutral summary of a tool call: "Bash · npm test", "Edit · Login.swift".
enum ToolSummary {
    static func describe(tool: String, input: [String: Any]) -> String {
        // Nook's own workspace tools (`mcp__nook__terminal_run`): their label, and the command, address or title.
        if tool.hasPrefix(BridgeTool.toolPrefix), let bridge = BridgeTool.named(tool) {
            return BridgeTool.detail(input).map { "\(bridge.label) · \(oneLine($0, 120))" } ?? bridge.label
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
