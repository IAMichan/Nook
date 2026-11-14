import Foundation
import AppKit

/// Tracks running AI agents based on their hooks and surfaces their questions to the notch:
/// permissions (only when the agent would prompt the user directly) and multiple-choice questions (AskUserQuestion).
/// If answered in the terminal, the question card in the notch is dismissed immediately.
@MainActor
final class AgentHub: ObservableObject {
    @Published var sessions: [AgentSession] = []
    /// Agents running as OS processes that do not (yet) report via hooks.
    @Published private(set) var detected: [AgentSession] = []
    /// Pending permission requests, oldest first.
    @Published var approvals: [ApprovalRequest] = []
    /// Multiple-choice questions waiting for an answer, oldest first.
    @Published private(set) var questions: [AgentQuestionRequest] = []
    /// Claude subscription usage when the status line integration is connected.
    /// Persisted so it remains visible even when Claude Code is not currently running.
    @Published var planUsage: PlanUsage? = AgentHub.loadPlanUsage() {
        didSet { Self.savePlanUsage(planUsage) }
    }

    /// Same for additional Claude accounts, per directory (CLAUDE_CONFIG_DIR). Primary account is in `planUsage`.
    @Published var profilePlanUsage: [String: PlanUsage] = AgentHub.loadProfilePlanUsage() {
        didSet {
            if let data = try? JSONEncoder().encode(profilePlanUsage) { UserDefaults.standard.set(data, forKey: Self.profilePlanUsageKey) }
        }
    }

    private nonisolated static let planUsageKey = "planUsage"
    private nonisolated static let profilePlanUsageKey = "profilePlanUsage"

    private nonisolated static func loadProfilePlanUsage() -> [String: PlanUsage] {
        guard let data = UserDefaults.standard.data(forKey: profilePlanUsageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PlanUsage].self, from: data)) ?? [:]
    }

    /// Subscription usage of a Claude account.
    func subscriptionUsage(for profile: AgentProfile) -> PlanUsage? {
        guard let home = profile.home else { return planUsage }
        return profilePlanUsage[AgentProfile.normalize(home)]
    }

    /// One window as a session in Nook reported it (`rate_limit_event`); the other window keeps what it showed. Empty
    /// home is the default account.
    func applyPlanReading(_ reading: UsageLimits.PlanReading, home: String) {
        let known = home.isEmpty ? planUsage : profilePlanUsage[home]
        let usage = PlanUsage.merging(reading, into: known)
        // A session reports this with many of its turns, mostly unchanged: an unchanged reading is not redrawn and written
        // to UserDefaults each time.
        if let known, !usage.differs(from: known) { return }
        if home.isEmpty { planUsage = usage } else { profilePlanUsage[home] = usage }
    }

    /// Both windows as Claude Code's `get_usage` reported them: they replace what was shown, and a window it left out has
    /// not started. Empty home is the default account.
    func applyPlanReadings(_ readings: [UsageLimits.PlanReading], home: String) {
        var usage = PlanUsage(fiveHour: nil, sevenDay: nil, updated: Date())
        for reading in readings {
            let window = PlanWindow(usedPercent: reading.usedPercent, resetsAt: reading.resetsAt)
            if reading.window == "seven_day" { usage.sevenDay = window } else { usage.fiveHour = window }
        }
        if let known = home.isEmpty ? planUsage : profilePlanUsage[home], !usage.differs(from: known) { return }
        if home.isEmpty { planUsage = usage } else { profilePlanUsage[home] = usage }
    }

    /// Account directory from hook environment; empty if standard directory.
    nonisolated static func accountHome(_ env: [String: Any], agentID: String) -> String {
        guard let kind = AgentKind(hookAgentID: agentID), let variable = kind.homeVariable, let raw = env[variable] as? String, !raw.isEmpty else { return "" }
        let home = AgentProfile.normalize(kind.home(fromVariable: raw))
        return home == AgentProfile.normalize(kind.defaultHome.path) ? "" : home
    }

    private nonisolated static func loadPlanUsage() -> PlanUsage? {
        guard let data = UserDefaults.standard.data(forKey: planUsageKey) else { return nil }
        return try? JSONDecoder().decode(PlanUsage.self, from: data)
    }

    private nonisolated static func savePlanUsage(_ usage: PlanUsage?) {
        guard let usage, let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: planUsageKey)
    }

    var onApproval: ((ApprovalRequest) -> Void)?
    /// A question was answered (here or externally) or expired: remove the card. The text is a confirmation
    /// to display if answered from Nook, nil otherwise.
    var onApprovalGone: ((String, String?) -> Void)?
    var onQuestion: ((AgentQuestionRequest) -> Void)?
    var onQuestionGone: ((String, String?) -> Void)?
    var onAttention: ((AgentSession) -> Void)?
    var recap: RecapStore?

    struct Record {
        var agentID: String
        var agent: String
        var project: String
        var cwd: String
        var status: AgentStatus
        var steps: [AgentStep]
        var file: String
        var lastMessage: String
        var updated: Date
        var hostBundleID: String
        /// Account directory (CLAUDE_CONFIG_DIR or CODEX_HOME); empty for standard directory.
        var home: String = ""
        var diff: [DiffLine]
        var linesAdded: Int
        var linesRemoved: Int
        var sessionID: String = ""
        var transcriptPath: String = ""
        var lastPrompt: String = ""
        /// The first prompt Nook heard in this session: its title until the transcript names it, never replaced.
        var firstPrompt: String = ""
        /// When Nook first heard of this session.
        var started = Date()
        /// When the current turn began (your last prompt); nil between turns.
        var turnStarted: Date? = nil
        /// The processes the latest hook came from, nearest first (see `HookConnection.lineage`).
        var lineage: [Int32] = []
        /// The agent process among them, once the process scan has seen it.
        var pid: Int32? = nil
        /// When the agent started compacting the conversation (`HookCompaction`); nil when it does not.
        var compactingSince: Date? = nil
        /// The other projects it changed files in (`SessionProjects`).
        var otherProjects: [String] = []
        /// The files the tool call that is running will write, from its `PreToolUse`: OpenCode's plugin sends no input
        /// with `PostToolUse`, so what it wrote is read from here once it is done.
        var pendingWrites: [String] = []
    }

    enum PendingKind {
        case permission(suggestions: Any?, canAlways: Bool)
        /// A hook before the tool call (`PreToolGate`, or Claude Code's hooks before PermissionRequest). `grant`: what
        /// "Always" allows for the rest of the session; nil when the request offers no Always.
        case preToolUse(grant: String?)
        /// A prompt the agent's own app draws (`AppPrompt`): answered by pressing its button, not by a hook reply.
        case appPrompt(bundleIDs: [String])
    }

    struct PendingApproval {
        let request: ApprovalRequest
        /// The hook waiting for the answer; nil for an app prompt, whose hook has already returned.
        let connection: HookConnection?
        let kind: PendingKind
    }

    struct PendingQuestion {
        let request: AgentQuestionRequest
        let connection: HookConnection
        let rawQuestions: Any
    }

    /// Every change marks the records to be saved; one snapshot follows once the change is handled (`scheduleSave`), not
    /// one per write: a hook event writes its record several times.
    var records: [String: Record] = [:] {
        didSet { scheduleSave() }
    }
    var pendingApprovals: [String: PendingApproval] = [:]
    var pendingQuestions: [String: PendingQuestion] = [:] {
        didSet {
            let ids = Set(pendingQuestions.keys)
            questions.removeAll { !ids.contains($0.id) }
            for pending in pendingQuestions.values where !questions.contains(where: { $0.id == pending.request.id }) {
                questions.append(pending.request)
            }
        }
    }
    private let server = UnixSocketServer(path: NookPaths.socketURL.path)
    private var pruneTimer: Timer?
    /// Every agent process from the latest scan, including those reporting via hooks: to end a session from Nook.
    var processes: [DetectedAgent] = []
    private var scanTimer: Timer?

    /// After this many seconds without answer, agent prompts user directly (hook timeout is 120s).
    static let approvalTimeout: UInt64 = 110
    /// An app prompt waits in the app as long as you take; the card goes after this long, the app keeps asking.
    static let appPromptTimeout: UInt64 = 600
    /// App prompts Nook is pressing the button of right now, so a second click does not press again.
    var answering: Set<String> = []
    /// What you allowed "always" for a session in a gated agent (`PreToolGate.grant`), by session key.
    var sessionGrants: [String: Set<String>] = [:]
    static let questionTimeout: UInt64 = 120

    func start() {
        restoreRecords()
        // The JSON is read here, on the socket's queue: the status line alone sends several messages a second per Claude
        // session, and only the parsed message goes to the main thread.
        server.onMessage = { [weak self] data, connection in
            guard let message = HookMessage.parse(data) else {
                connection.reply(nil)
                return
            }
            // Sessions run directly by Nook workspace are tracked there (with their own approvals); don't duplicate here.
            if message.isWorkspaceRun {
                connection.reply(nil)
                return
            }
            Task { @MainActor in
                if let self {
                    self.handle(message, connection)
                } else {
                    connection.reply(nil)
                }
            }
        }
        do {
            try server.start()
        } catch {
            Log.agents.error("Hook socket: \(error.localizedDescription, privacy: .public)")
        }
        pruneTimer = Timer.scheduledCoalesced(withTimeInterval: 60) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        refreshDetected()
        scanTimer = Timer.scheduledCoalesced(withTimeInterval: 10) { [weak self] _ in
            Task { @MainActor in self?.scanTick() }
        }
    }

    private var lastScan: Date = .distantPast

    /// The timer's scan: every ten seconds while you work, less often while you are away or the Mac saves power, and only
    /// every few minutes while the screen is locked or asleep (nobody sees the list; a session that ended is still
    /// settled). An agent that reports through its hooks shows up at once either way; this only finds the ones started
    /// without Nook.
    private func scanTick() {
        let plan = EnergyMonitor.shared.plan
        let base: TimeInterval = plan.unseen ? 60 : 10
        guard Date().timeIntervalSince(lastScan) >= base * plan.slowdown - 2.5 else { return }
        lastScan = Date()
        refreshDetected()
    }

    private var linkedStateCache: [String: (linked: Bool, checkedAt: Date)] = [:]

    /// Discovers running agents. Ones already reporting via hooks are not duplicated.
    func refreshDetected() {
        Task {
            let found = await LocalAgentScanner.scan()
            processes = found
            settleEndedRestored(found)
            await settleStale(found)
            // A hooked session covers one process of its agent, not all of them: two sessions of the same agent in the same
            // folder stay two rows.
            let covered = SessionLiveness.claimed(Self.scanned(found),
                                                  by: records.values.map { (agent: $0.agent, cwd: $0.cwd, pid: $0.pid) })
            let now = Date()
            let uncovered = found.sorted { $0.pid < $1.pid }.filter { !covered.contains($0.pid) }
            // Each agent's account home, and the key its connected state is kept under.
            let accounts = Dictionary(uncovered.map { agent -> (Int32, (home: String, key: String)) in
                let kind = AgentKind(agentName: agent.name)
                let accountHome = kind.flatMap { kind in
                    kind.homeVariable.map { Self.accountHome([$0: kind.homeValue(agent.home)], agentID: kind.hookAgentID) }
                } ?? ""
                return (agent.pid, (home: accountHome, key: "\(agent.name)|\(accountHome)"))
            }, uniquingKeysWith: { first, _ in first })
            // Whether each agent is connected: its settings file is read and parsed, at most every 20 seconds per agent
            // and account, and off the main thread (this runs with every scan).
            var checks: [String: (target: AgentConfigInstaller.Target?, home: URL?)] = [:]
            for agent in uncovered {
                guard let account = accounts[agent.pid], checks[account.key] == nil else { continue }
                if let cached = linkedStateCache[account.key], now.timeIntervalSince(cached.checkedAt) < 20 { continue }
                let home = account.home.isEmpty || agent.home.isEmpty ? nil : URL(fileURLWithPath: agent.home, isDirectory: true)
                checks[account.key] = (AgentConfigInstaller.Target.forAgent(named: agent.name), home)
            }
            if !checks.isEmpty {
                let pending = checks.map { (key: $0.key, target: $0.value.target, home: $0.value.home) }
                let states = await Task.detached(priority: .utility) {
                    pending.map { check in
                        (check.key, check.target.map { AgentConfigInstaller.state(of: $0, home: check.home) == .installed } ?? false)
                    }
                }.value
                for (key, linked) in states { linkedStateCache[key] = (linked, now) }
            }
            let newDetected: [AgentSession] = uncovered.map { agent in
                // Already connected? If so, this session was started before integration and just needs a restart.
                let accountHome = accounts[agent.pid]?.home ?? ""
                let linked = accounts[agent.pid].flatMap { linkedStateCache[$0.key]?.linked } ?? false
                let steps: [AgentStep] = linked ? [
                    AgentStep(mark: .blocked, text: "Started before integration: Nook cannot monitor"),
                    AgentStep(mark: .todo, text: "Quit and restart \(agent.name)")
                ] : [
                    AgentStep(mark: .blocked, text: "Not connected yet: Nook cannot monitor"),
                    AgentStep(mark: .todo, text: "Connect \(agent.name) and restart it")
                ]
                return AgentSession(
                    id: "proc-\(agent.pid)",
                    name: agent.name,
                    project: Self.projectName(agent.cwd),
                    status: .detected,
                    file: agent.cwd.isEmpty ? "running on this Mac" : Self.shortPath(agent.cwd),
                    placeholder: "Type in the terminal of \(agent.name) to continue",
                    steps: steps,
                    diff: [],
                    cwd: agent.cwd,
                    home: accountHome,
                    isLinked: linked
                )
            }
            if detected != newDetected {
                detected = newDetected
            }
        }
    }

    /// When `sessions` was last published, and whether a later publish is waiting (see `rebuild`).
    var lastPublished: Date = .distantPast
    var publishPending = false
    /// Set while `handle` applies a hook event: `rebuild` then only notes that it is wanted.
    var deferringRebuild = false
    var rebuildRequested = false
    /// Keys restored at launch that no process has confirmed yet.
    var unconfirmed: Set<String> = []
    let launchedAt = Date()
    var saveWork: Task<Void, Never>?
    /// Whether `records` changed since the last snapshot; a save is then scheduled on the main queue.
    var recordsDirty = false
    /// Scans in a row each busy session's process was missing from the process list.
    var missingScans: [String: Int] = [:]
    // MARK: Answers from Nook

    func approval(id: String) -> ApprovalRequest? {
        pendingApprovals[id]?.request
    }

    /// `reason`: what you told the agent with a denial; the hook's answer carries it (`permissionDecisionReason`, `message`).
    func decide(_ id: String, _ decision: ApprovalDecision, reason: String = "") {
        guard let pending = pendingApprovals[id] else { return }
        if case .appPrompt(let bundleIDs) = pending.kind, decision != .terminal {
            answerAppPrompt(id, bundleIDs: bundleIDs, allow: decision != .deny)
            return
        }
        let response = Self.response(for: decision, kind: pending.kind, reason: reason)
        switch decision {
        case .allow:
            recap?.decision(allowed: true)
            closeApproval(id, response: response, status: .running, step: (.running, "allowed via Nook"), message: "Allowed")
        case .always:
            recap?.decision(allowed: true)
            if case .preToolUse(let grant?) = pending.kind {
                sessionGrants[pending.request.sessionKey, default: []].insert(grant)
            }
            closeApproval(id, response: response, status: .running, step: (.running, "always allowed via Nook"), message: "Always allowed")
        case .deny:
            recap?.decision(allowed: false)
            closeApproval(id, response: response, status: .running, step: (.failed, "denied via Nook"), message: "Denied")
        case .terminal:
            closeApproval(id, response: nil, status: .waiting, step: (.blocked, "waiting for you in the terminal"))
        }
    }

    func answerQuestion(_ id: String, selections: [[String]]) {
        guard let pending = pendingQuestions[id] else { return }
        let answers = AgentQuestionRequest.answers(items: pending.request.items, selections: selections)
        var updated: [String: Any] = ["questions": pending.rawQuestions, "answers": answers]
        // Which preview you picked, as Claude Code's own question dialog tells it.
        let annotations = AgentQuestionRequest.annotations(items: pending.request.items, selections: selections)
        if !annotations.isEmpty { updated["annotations"] = annotations }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated
            ]
        ]
        recap?.questionAnswered()
        let summary = selections.flatMap { $0 }.joined(separator: ", ")
        closeQuestion(id, response: try? JSONSerialization.data(withJSONObject: payload), status: .running,
                      step: (.done, "you chose: " + Self.shorten(summary, 50)), message: "Answer sent")
    }

    func answerQuestionInTerminal(_ id: String) {
        closeQuestion(id, response: nil, status: .waiting, step: (.blocked, "question is in the terminal"))
    }

    /// The multiple-choice question this session is waiting on, if any, so it can be answered in the Agents tab.
    func question(for sessionKey: String) -> AgentQuestionRequest? {
        pendingQuestions.values.first { $0.request.sessionKey == sessionKey }?.request
    }

    /// The process behind a session: from the process scan for detected sessions, otherwise matched on agent and folder.
    /// Nil when unknown or ambiguous (two of the same agent in one folder), so Nook never ends the wrong one.
    func processID(for session: AgentSession) -> Int32? {
        if session.id.hasPrefix("proc-") { return Int32(session.id.dropFirst(5)) }
        guard !session.cwd.isEmpty else { return nil }
        let matches = processes.filter { $0.name == session.name && $0.cwd == session.cwd }
        return matches.count == 1 ? matches[0].pid : nil
    }

    /// Ends a session's process: politely (SIGTERM, so the agent saves its conversation), forced after a few seconds.
    /// Pending questions and approvals are released and the session disappears from the list.
    @discardableResult
    func end(_ session: AgentSession) -> Bool {
        guard let pid = processID(for: session), pid > 1 else { return false }
        guard kill(pid, SIGTERM) == 0 else { return false }
        Task.detached {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if kill(pid, 0) != 0 { return }
            }
            _ = kill(pid, SIGKILL)
        }
        forget(session.id)
        processes.removeAll { $0.pid == pid }
        detected.removeAll { $0.id == session.id }
        return true
    }

    /// Removes a session from the list, releasing anything it was waiting on.
    func forget(_ key: String) {
        for (id, pending) in pendingApprovals where pending.request.sessionKey == key {
            closeApproval(id, response: nil, status: nil, step: nil)
        }
        for (id, pending) in pendingQuestions where pending.request.sessionKey == key {
            closeQuestion(id, response: nil, status: nil, step: nil)
        }
        guard records.removeValue(forKey: key) != nil else { return }
        rebuild()
    }

    // MARK: Helper Functions

    static func push(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        record.steps.append(AgentStep(mark: mark, text: text))
        if record.steps.count > 6 { record.steps.removeFirst(record.steps.count - 6) }
    }

    static func replaceLast(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        guard !record.steps.isEmpty else {
            push(&record, mark, text)
            return
        }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: text)
    }

    /// A tool finished while the session read as waiting: you answered its prompt in the terminal, so it works again.
    /// Without this it stayed amber ("waits for you") until the next tool started or the turn ended.
    static func resume(_ record: inout Record, asking: Bool) {
        guard record.status == .waiting, !asking else { return }
        record.status = .running
    }

    /// Is a card in the notch still asking you something for this session (an approval or a question)?
    func isAsking(_ key: String) -> Bool {
        pendingApprovals.values.contains { $0.request.sessionKey == key }
            || pendingQuestions.values.contains { $0.request.sessionKey == key }
    }

    /// Closes the last step that was running (or waiting for user input).
    static func complete(_ record: inout Record, as mark: AgentStep.Mark) {
        guard let last = record.steps.last, last.mark == .running || last.mark == .blocked else { return }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: last.text)
    }

    /// Normalizes event names from other agents (Gemini CLI, Antigravity, Copilot, Cursor, etc.) to Claude Code convention.
    nonisolated static func normalize(_ name: String) -> String {
        let map: [String: String] = [
            "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse",
            "BeforeAgent": "UserPromptSubmit", "AfterAgent": "Stop",
            "PreInvocation": "UserPromptSubmit", "PostInvocation": "PostToolUse",
            "beforeSubmitPrompt": "UserPromptSubmit", "postToolUseFailure": "PostToolUseFailure",
            "subagentStart": "SubagentStart", "subagentStop": "SubagentStop",
            "pre_tool_use": "PreToolUse", "post_tool_use": "PostToolUse",
            "preToolUse": "PreToolUse", "postToolUse": "PostToolUse",
            "user_prompt_submit": "UserPromptSubmit", "userPromptSubmitted": "UserPromptSubmit",
            "session_start": "SessionStart", "sessionStart": "SessionStart", "startup": "SessionStart",
            "session_end": "SessionEnd", "sessionEnd": "SessionEnd", "exit": "SessionEnd",
            "stop": "Stop", "agentStop": "Stop", "agent-turn-complete": "Stop",
            "notification": "Notification", "permissionRequest": "PermissionRequest"
        ]
        return map[name] ?? HookCompaction.canonical[name] ?? name
    }

    nonisolated static func cleanAgentID(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let clean = String(raw.lowercased().filter { allowed.contains($0) }.prefix(32))
        return clean.isEmpty ? "agent" : clean
    }

    static func displayName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "claude-desktop": return "Claude (app)"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "antigravity": return "Antigravity"
        case "copilot": return "Copilot CLI"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "amp": return "Amp"
        case "hermes": return "Hermes"
        case "muse": return "Muse Code"
        case "qwen": return "Qwen Code"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    /// The folder a session's row names: for an agent's own worktree, the repository it was made from (see `WorktreeOrigin`).
    static func projectName(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        guard !(name.isEmpty || cwd.isEmpty || name == "/") else { return "no folder" }
        return WorktreeOrigin.repositoryName(of: cwd) ?? name
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private static let markdownPrefixRegex = try? NSRegularExpression(pattern: #"^(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s*)"#)
    private static let markdownLinkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)

    /// Extracts the first useful paragraph of a Markdown reply as a plain sentence.
    static func oneLine(_ markdown: String, limit: Int = 220) -> String {
        guard !markdown.isEmpty else { return "" }
        var inCode = false
        var paragraph: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            var clean = line
            if let regex = markdownPrefixRegex {
                clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..<clean.endIndex, in: clean), withTemplate: "")
            }
            if clean.contains("]("), let regex = markdownLinkRegex {
                clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..<clean.endIndex, in: clean), withTemplate: "$1")
            }
            clean = clean.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !clean.isEmpty { paragraph.append(clean) }
        }
        return shorten(paragraph.joined(separator: " "), limit)
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// The command text, even when an agent provides it as an argument array (Codex: ["bash", "-lc", "npm test"]).
    static func commandText(_ input: [String: Any]) -> String? {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String], !parts.isEmpty {
            if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent),
               parts[1].hasPrefix("-") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    static func filePath(_ input: [String: Any]) -> String? {
        for key in ["file_path", "absolute_path", "notebook_path", "path"] {
            if let path = input[key] as? String, !path.isEmpty { return path }
        }
        return nil
    }

    static func editDiff(tool: String, input: [String: Any]) -> (lines: [DiffLine], added: Int, removed: Int)? {
        var ops: [LineDiff.Op] = []
        switch tool {
        case "Edit", "replace":
            let old = (input["old_string"] as? String) ?? ""
            let new = (input["new_string"] as? String) ?? ""
            ops = LineDiff.diff(LineDiff.lines(old), LineDiff.lines(new))
        case "MultiEdit":
            for edit in (input["edits"] as? [[String: Any]]) ?? [] {
                let old = (edit["old_string"] as? String) ?? ""
                let new = (edit["new_string"] as? String) ?? ""
                ops += LineDiff.diff(LineDiff.lines(old), LineDiff.lines(new))
            }
        case "Write", "write_file":
            ops = LineDiff.lines((input["content"] as? String) ?? "").map { LineDiff.Op.add($0) }
        default:
            return nil
        }
        guard !ops.isEmpty else { return nil }
        let counts = LineDiff.counts(ops)
        return (LineDiff.display(ops, context: 1, limit: 30), counts.added, counts.removed)
    }

    static func approvalSummary(tool: String, input: [String: Any]) -> String {
        // An MCP tool shows every argument it gets: the title names the tool and its server.
        if let mcp = McpToolName(tool) {
            let arguments = McpToolName.arguments(input)
            return arguments.isEmpty ? mcp.label : arguments
        }
        if let command = commandText(input) { return command }
        if let path = filePath(input) { return "\(tool) \(shortPath(path))" }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return "searching: \(query)" }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != "{}" {
            return "\(tool) \(shorten(text, 140))"
        }
        return tool.isEmpty ? "activity on your Mac" : tool
    }

    static func assess(
        tool: String,
        input: [String: Any],
        edit: (lines: [DiffLine], added: Int, removed: Int)?
    ) -> CommandAssessment {
        if let command = commandText(input) {
            let assessment = CommandRisk.assess(command)
            if assessment.level == .safe {
                return CommandAssessment(level: .review, title: "", note: "Read-only · looks harmless")
            }
            return assessment
        }
        if let edit {
            let file = filePath(input).map { ($0 as NSString).lastPathComponent } ?? "a file"
            return CommandAssessment(level: .review, title: "", note: "Modifies \(file) · +\(edit.added) −\(edit.removed)")
        }
        if let url = input["url"] as? String {
            return CommandAssessment(level: .review, title: "", note: "Fetches from \(URL(string: url)?.host ?? "the internet")")
        }
        if tool.hasPrefix("mcp__") {
            return CommandAssessment(level: .review, title: "", note: tr("ws.approval.mcpNote"))
        }
        return CommandAssessment(level: .review, title: "", note: "Please review")
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        if let command = commandText(input) {
            return "Bash: " + shorten(command, 55)
        }
        switch tool {
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit", "read_file", "write_file", "replace":
            let path = filePath(input) ?? ""
            let verb: String
            switch tool {
            case "Read", "read_file": verb = "Reads"
            case "Write", "write_file": verb = "Writes"
            default: verb = "Modifies"
            }
            return "\(verb) \((path as NSString).lastPathComponent)"
        case "Grep", "Glob", "search_file_content", "glob":
            return "Searches \(shorten((input["pattern"] as? String) ?? "", 40))"
        case "WebFetch", "web_fetch":
            let host = URL(string: (input["url"] as? String) ?? "")?.host ?? ""
            return "Fetches: \(host)"
        case "WebSearch", "google_web_search":
            return "Searches online: \(shorten((input["query"] as? String) ?? "", 40))"
        case "Task", "Agent":
            return "Subagent: \(shorten((input["description"] as? String) ?? "", 40))"
        case "TodoWrite":
            return "Updates task list"
        default:
            if let mcp = McpToolName(tool) { return mcp.label }
            return tool.isEmpty ? "busy" : tool
        }
    }
}
