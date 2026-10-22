import Foundation

/// Tracks running AI agents based on their hooks and surfaces their questions to the notch:
/// permissions (only when the agent would prompt the user directly) and multiple-choice questions (AskUserQuestion).
/// If answered in the terminal, the question card in the notch is dismissed immediately.
@MainActor
final class AgentHub: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Agents running as OS processes that do not (yet) report via hooks.
    @Published private(set) var detected: [AgentSession] = []
    /// Pending permission requests, oldest first.
    @Published private(set) var approvals: [ApprovalRequest] = []
    /// Multiple-choice questions waiting for an answer, oldest first.
    @Published private(set) var questions: [AgentQuestionRequest] = []
    /// Claude subscription usage when the status line integration is connected.
    /// Persisted so it remains visible even when Claude Code is not currently running.
    @Published private(set) var planUsage: PlanUsage? = AgentHub.loadPlanUsage() {
        didSet { Self.savePlanUsage(planUsage) }
    }

    /// Same for additional Claude accounts, per directory (CLAUDE_CONFIG_DIR). Primary account is in `planUsage`.
    @Published private(set) var profilePlanUsage: [String: PlanUsage] = AgentHub.loadProfilePlanUsage() {
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
        var usage = (home.isEmpty ? planUsage : profilePlanUsage[home]) ?? PlanUsage(fiveHour: nil, sevenDay: nil, updated: Date())
        let window = PlanWindow(usedPercent: reading.usedPercent, resetsAt: reading.resetsAt)
        if reading.window == "seven_day" { usage.sevenDay = window } else { usage.fiveHour = window }
        usage.updated = Date()
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
        if home.isEmpty { planUsage = usage } else { profilePlanUsage[home] = usage }
    }

    /// Account directory from hook environment; empty if standard directory.
    private static func accountHome(_ env: [String: Any], agentID: String) -> String {
        let kind: AgentKind = agentID == "codex" ? .codex : .claude
        guard agentID == "codex" || agentID.hasPrefix("claude"),
              let variable = kind.homeVariable, let raw = env[variable] as? String, !raw.isEmpty else { return "" }
        let home = AgentProfile.normalize(raw)
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

    private struct Record {
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
        /// When Nook first heard of this session.
        var started = Date()
        /// When the current turn began (your last prompt); nil between turns.
        var turnStarted: Date? = nil
        /// The processes the latest hook came from, nearest first (see `HookConnection.lineage`).
        var lineage: [Int32] = []
        /// The agent process among them, once the process scan has seen it.
        var pid: Int32? = nil
    }

    private enum PendingKind {
        case permission(suggestions: Any?, canAlways: Bool)
        case legacyPreToolUse
    }

    private struct PendingApproval {
        let request: ApprovalRequest
        let connection: HookConnection
        let kind: PendingKind
    }

    private struct PendingQuestion {
        let request: AgentQuestionRequest
        let connection: HookConnection
        let rawQuestions: Any
    }

    private var records: [String: Record] = [:] {
        didSet { saveRecords() }
    }
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingQuestions: [String: PendingQuestion] = [:] {
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
    private var processes: [DetectedAgent] = []
    private var scanTimer: Timer?

    /// After this many seconds without answer, agent prompts user directly (hook timeout is 120s).
    private static let approvalTimeout: UInt64 = 110
    private static let questionTimeout: UInt64 = 120

    func start() {
        restoreRecords()
        server.onMessage = { [weak self] data, connection in
            Task { @MainActor in
                if let self {
                    self.handle(data, connection)
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

    /// The timer's scan: every ten seconds while you work, less often while you are away or the Mac saves power. An agent
    /// that reports through its hooks shows up at once either way; this only finds the ones started without Nook.
    private func scanTick() {
        let slowdown = EnergyMonitor.shared.plan.slowdown
        guard Date().timeIntervalSince(lastScan) >= 10 * slowdown - 2.5 else { return }
        lastScan = Date()
        refreshDetected()
    }

    private var linkedStateCache: [String: (linked: Bool, checkedAt: Date)] = [:]

    /// Discovers running agents. Ones already reporting via hooks are not duplicated.
    func refreshDetected() {
        Task {
            let found = await LocalAgentScanner.scan()
            processes = found
            dropEndedRestored(found)
            await settleStale(found)
            // A hooked session covers one process of its agent and folder, not all of them: two sessions of the same agent in
            // the same folder stay two rows.
            var covered: [String: Int] = [:]
            for record in records.values { covered["\(record.agent)|\(record.cwd)", default: 0] += 1 }
            let now = Date()
            let newDetected: [AgentSession] = found.sorted { $0.pid < $1.pid }.compactMap { agent in
                let key = "\(agent.name)|\(agent.cwd)"
                if let count = covered[key], count > 0 {
                    covered[key] = count - 1
                    return nil
                }
                // Already connected? If so, this session was started before integration and just needs a restart.
                let home = agent.home.isEmpty ? nil : URL(fileURLWithPath: agent.home, isDirectory: true)
                let kind = AgentKind(agentName: agent.name)
                let accountHome = kind.flatMap { kind in
                    kind.homeVariable.map { Self.accountHome([$0: agent.home], agentID: kind == .codex ? "codex" : "claude-code") }
                } ?? ""
                let cacheKey = "\(agent.name)|\(accountHome)"
                let linked: Bool
                if let cached = linkedStateCache[cacheKey], now.timeIntervalSince(cached.checkedAt) < 20 {
                    linked = cached.linked
                } else {
                    let computed = AgentConfigInstaller.Target.forAgent(named: agent.name)
                        .map { AgentConfigInstaller.state(of: $0, home: accountHome.isEmpty ? nil : home) == .installed } ?? false
                    linkedStateCache[cacheKey] = (computed, now)
                    linked = computed
                }
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

    // MARK: Remembered sessions

    /// What survives a restart of Nook: agents keep running in their terminals, so the sessions known from their hooks
    /// are saved and put back, and listed again straight away instead of waiting for the next hook event.
    private struct SavedRecord: Codable {
        var key: String
        var agentID: String
        var agent: String
        var cwd: String
        var status: String
        var steps: [[String]]
        var file: String
        var lastMessage: String
        var updated: Date
        var started: Date
        var hostBundleID: String
        var home: String
        var sessionID: String
        var transcriptPath: String
        var lastPrompt: String
        var linesAdded: Int
        var linesRemoved: Int
        var turnStarted: Date?
    }

    private nonisolated static var recordsURL: URL { NookPaths.supportDirectory.appendingPathComponent("agent-sessions.json") }
    /// Keys restored at launch that no process has confirmed yet.
    private var unconfirmed: Set<String> = []
    private let launchedAt = Date()
    private var saveWork: Task<Void, Never>?

    private func saveRecords() {
        saveWork?.cancel()
        let snapshot = records.map { key, r in
            SavedRecord(key: key, agentID: r.agentID, agent: r.agent, cwd: r.cwd, status: "\(r.status)",
                        steps: r.steps.map { ["\($0.mark)", $0.text] }, file: r.file, lastMessage: r.lastMessage,
                        updated: r.updated, started: r.started, hostBundleID: r.hostBundleID, home: r.home,
                        sessionID: r.sessionID, transcriptPath: r.transcriptPath, lastPrompt: r.lastPrompt,
                        linesAdded: r.linesAdded, linesRemoved: r.linesRemoved, turnStarted: r.turnStarted)
        }
        // A burst of hook events becomes one write.
        saveWork = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: Self.recordsURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.recordsURL.path)
        }
    }

    private func restoreRecords() {
        guard records.isEmpty, let data = try? Data(contentsOf: Self.recordsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([SavedRecord].self, from: data) else { return }
        let now = Date()
        var restored: [String: Record] = [:]
        for item in saved {
            let age = now.timeIntervalSince(item.updated)
            let status: AgentStatus
            switch item.status {
            case "waiting": status = .waiting
            case "failed": status = .failed
            case "done": status = .done
            default: status = .running
            }
            // Same lifetime as `prune`.
            guard age < (status == .done ? 4 : 12) * 3600 else { continue }
            let marks: [String: AgentStep.Mark] = ["done": .done, "running": .running, "blocked": .blocked, "failed": .failed, "todo": .todo]
            var record = Record(agentID: item.agentID, agent: item.agent, project: Self.projectName(item.cwd), cwd: item.cwd,
                                status: status, steps: item.steps.compactMap { pair in
                                    guard pair.count == 2, let mark = marks[pair[0]] else { return nil }
                                    return AgentStep(mark: mark, text: pair[1])
                                }, file: item.file, lastMessage: item.lastMessage, updated: item.updated,
                                hostBundleID: item.hostBundleID, diff: [], linesAdded: item.linesAdded, linesRemoved: item.linesRemoved)
            record.home = item.home
            record.sessionID = item.sessionID
            record.transcriptPath = item.transcriptPath
            record.lastPrompt = item.lastPrompt
            record.started = item.started
            record.turnStarted = status == .done ? nil : item.turnStarted
            restored[item.key] = record
        }
        unconfirmed = Set(restored.keys)
        records = restored
        rebuild()
    }

    /// A restored session whose agent has ended while Nook was closed is dropped once the process list shows it is gone.
    /// Agents the scanner does not know (apps, custom tools) stay until the normal expiry.
    private func dropEndedRestored(_ found: [DetectedAgent]) {
        guard !unconfirmed.isEmpty else { return }
        let scannable = Set(LocalAgentScanner.agentNames)
        var running: [String: Int] = [:]
        for agent in found { running["\(agent.name)|\(agent.cwd)", default: 0] += 1 }
        var changed = false
        for key in unconfirmed.sorted() {
            // A hook event since launch already proves the session is alive.
            guard let record = records[key], record.updated < launchedAt else { continue }
            guard scannable.contains(record.agent) else { continue }
            let id = "\(record.agent)|\(record.cwd)"
            if let count = running[id], count > 0 {
                running[id] = count - 1
            } else {
                records[key] = nil
                changed = true
            }
        }
        unconfirmed = []
        if changed { rebuild() }
    }

    /// Scans in a row each busy session's process was missing from the process list.
    private var missingScans: [String: Int] = [:]

    private static func scanned(_ found: [DetectedAgent]) -> [(pid: Int32, name: String, cwd: String)] {
        found.map { (pid: $0.pid, name: $0.name, cwd: $0.cwd) }
    }

    /// Settles sessions that still read as busy while their turn has ended or their agent has quit, when the hook that
    /// should have said so never came (see `SessionLiveness`).
    private func settleStale(_ found: [DetectedAgent]) async {
        let scannable = Set(LocalAgentScanner.agentNames)
        let busy = records.filter { $0.value.status == .running || $0.value.status == .waiting }
        missingScans = missingScans.filter { busy[$0.key] != nil }
        let running = Self.scanned(found)
        for (key, record) in records where record.pid == nil && !record.lineage.isEmpty {
            // Assigning nil again would still trigger `records`' didSet, and with it a rewrite of the whole file.
            if let pid = SessionLiveness.agentProcess(agent: record.agent, lineage: record.lineage, in: running) {
                records[key]?.pid = pid
            }
        }
        guard !busy.isEmpty else { return }
        for key in busy.keys {
            guard let record = records[key] else { continue }
            let gone = scannable.contains(record.agent)
                && !SessionLiveness.isRunning(agent: record.agent, cwd: record.cwd, pid: record.pid, in: running)
            missingScans[key] = gone ? (missingScans[key] ?? 0) + 1 : 0
        }
        let paths = busy.filter { $0.value.status == .running }.mapValues(\.transcriptPath)
        let turns = await Task.detached(priority: .utility) {
            paths.compactMapValues { SessionLiveness.readTurn(path: $0) }
        }.value

        let now = Date()
        var changed = false
        for (key, seen) in busy {
            // A hook event while the transcript was read wins.
            guard var record = records[key], record.updated == seen.updated, record.status == seen.status else { continue }
            if pendingApprovals.values.contains(where: { $0.request.sessionKey == key })
                || pendingQuestions.values.contains(where: { $0.request.sessionKey == key }) { continue }
            let read = turns[key]
            guard let verdict = SessionLiveness.verdict(
                working: record.status == .running, lastEvent: record.updated, turn: read?.turn ?? .unknown,
                transcriptModified: read?.modified, missingScans: missingScans[key] ?? 0, now: now
            ) else { continue }
            record.status = .done
            Self.complete(&record, as: .done)
            Self.push(&record, .done, verdict == .processGone ? "session closed" : "done")
            records[key] = record
            missingScans[key] = nil
            changed = true
            Log.agents.info("Settled stale session \(key, privacy: .public): \(String(describing: verdict), privacy: .public)")
        }
        if changed { rebuild() }
    }

    /// You settled a session that still reads as busy: its turn hangs (a `Stop` that never came, a turn that stays open in
    /// the transcript), so Nook believes you and shows it as done, in the conversation and the notch alike. A question or
    /// approval still open in the notch keeps it waiting; the next prompt or tool call makes it work again.
    func settleByUser(_ key: String) {
        guard var record = records[key], record.status == .running || record.status == .waiting, !isAsking(key) else { return }
        record.status = .done
        record.turnStarted = nil
        Self.complete(&record, as: .done)
        Self.push(&record, .done, "settled by you")
        records[key] = record
        missingScans[key] = nil
        rebuild()
    }

    // MARK: Answers from Nook

    func approval(id: String) -> ApprovalRequest? {
        pendingApprovals[id]?.request
    }

    func decide(_ id: String, _ decision: ApprovalDecision) {
        guard let pending = pendingApprovals[id] else { return }
        let response = Self.response(for: decision, kind: pending.kind)
        switch decision {
        case .allow:
            recap?.decision(allowed: true)
            closeApproval(id, response: response, status: .running, step: (.running, "allowed via Nook"), message: "Allowed")
        case .always:
            recap?.decision(allowed: true)
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
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": ["questions": pending.rawQuestions, "answers": answers]
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

    // MARK: Messages

    private func handle(_ data: Data, _ connection: HookConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            connection.reply(nil)
            return
        }
        let event = (object["event"] as? [String: Any]) ?? [:]
        let env = (object["env"] as? [String: Any]) ?? [:]
        var agentID = Self.cleanAgentID((object["agent"] as? String) ?? "agent")
        if agentID == "claude-code", (env["CLAUDE_CODE_ENTRYPOINT"] as? String) == "claude-desktop" {
            agentID = "claude-desktop"
        }
        let mode = (object["mode"] as? String) ?? (((object["wait"] as? Bool) ?? false) ? "permission" : "event")
        let kind = Self.normalize((event["hook_event_name"] as? String) ?? (event["type"] as? String) ?? "")

        if mode == "statusline" {
            if let usage = PlanUsage.parse(event) {
                let home = Self.accountHome(env, agentID: agentID)
                // The status line runs on every message update, several times a second: a reading that shows nothing new
                // is only stored once a minute (to keep `updated` fresh), instead of redrawing every view and rewriting
                // UserDefaults each time.
                let known = home.isEmpty ? planUsage : profilePlanUsage[home]
                if let known, !usage.differs(from: known) { connection.reply(nil); return }
                if home.isEmpty { planUsage = usage } else { profilePlanUsage[home] = usage }
            }
            connection.reply(nil)
            return
        }

        // Sessions run directly by Nook workspace are tracked there (with their own approvals); don't duplicate here.
        if let run = env["NOOK_RUN_ID"] as? String, !run.isEmpty {
            connection.reply(nil)
            return
        }

        let cwd = (event["cwd"] as? String) ?? (event["workdir"] as? String) ?? ""
        let sessionID = (event["session_id"] as? String)
            ?? (event["thread-id"] as? String)
            ?? (event["thread_id"] as? String)
            ?? (event["conversation_id"] as? String)
            ?? cwd
        let key = "\(agentID):\(sessionID)"
        let name = Self.displayName(agentID)

        if kind == "SessionEnd" {
            records[key] = nil
            for (id, pending) in pendingApprovals where pending.request.sessionKey == key {
                closeApproval(id, response: nil, status: nil, step: nil)
            }
            for (id, pending) in pendingQuestions where pending.request.sessionKey == key {
                closeQuestion(id, response: nil, status: nil, step: nil)
            }
            rebuild()
            connection.reply(nil)
            return
        }

        var record = records[key] ?? Record(
            agentID: agentID,
            agent: name,
            project: Self.projectName(cwd),
            cwd: cwd,
            status: .running,
            steps: [],
            file: "",
            lastMessage: "",
            updated: Date(),
            hostBundleID: "",
            diff: [],
            linesAdded: 0,
            linesRemoved: 0
        )
        if !cwd.isEmpty {
            record.cwd = cwd
            record.project = Self.projectName(cwd)
        }
        if let host = env["__CFBundleIdentifier"] as? String, !host.isEmpty {
            record.hostBundleID = host
        }
        record.home = Self.accountHome(env, agentID: agentID)
        record.updated = Date()
        // Which process this session runs in; the same session resumed in a new process starts over.
        let sameProcess = record.pid.map { connection.lineage.contains($0) } ?? false
        if !connection.lineage.isEmpty, !sameProcess {
            record.lineage = connection.lineage
            record.pid = SessionLiveness.agentProcess(agent: name, lineage: connection.lineage, in: Self.scanned(processes))
        }
        if let id = event["session_id"] as? String, !id.isEmpty { record.sessionID = id }
        if let path = event["transcript_path"] as? String, !path.isEmpty { record.transcriptPath = path }
        if record.transcriptPath.isEmpty && name == "Antigravity" {
            let sessionID = !record.sessionID.isEmpty ? record.sessionID : (env["ANTIGRAVITY_CONVERSATION_ID"] as? String) ?? ""
            if !sessionID.isEmpty {
                record.sessionID = sessionID
                let appData = (env["ANTIGRAVITY_APP_DATA_DIR"] as? String) ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.gemini/antigravity"
                record.transcriptPath = "\(appData)/brain/\(sessionID)/.system_generated/logs/transcript.jsonl"
            }
        }

        let tool = (event["tool_name"] as? String) ?? (event["toolName"] as? String) ?? ""
        let input = (event["tool_input"] as? [String: Any]) ?? (event["toolArgs"] as? [String: Any]) ?? [:]

        // Multiple-choice question from agent.
        if mode == "ask" {
            guard kind == "PreToolUse", tool == "AskUserQuestion", let items = AgentQuestionRequest.parse(input) else {
                records[key] = record
                connection.reply(nil)
                return
            }
            askQuestion(key: key, record: &record, items: items, raw: input["questions"] ?? [], connection: connection)
            records[key] = record
            rebuild()
            return
        }

        // Permission: agent is waiting for our response.
        if mode == "permission" {
            if kind == "PermissionRequest" {
                guard tool != "AskUserQuestion" else {
                    connection.reply(nil)
                    return
                }
                let suggestions = event["permission_suggestions"]
                let canAlways = agentID.hasPrefix("claude") && ((suggestions as? [Any])?.isEmpty == false)
                requestApproval(key: key, record: &record, tool: tool, input: input,
                                kind: .permission(suggestions: suggestions, canAlways: canAlways), connection: connection)
                records[key] = record
                rebuild()
                return
            }
            if kind == "PreToolUse", tool == "Bash" {
                // Legacy integration (prior to PermissionRequest): only commands that are not clearly safe.
                Self.push(&record, .running, Self.describe(tool: tool, input: input))
                if let command = Self.commandText(input), CommandRisk.assess(command).level != .safe {
                    requestApproval(key: key, record: &record, tool: tool, input: input, kind: .legacyPreToolUse, connection: connection)
                    records[key] = record
                    rebuild()
                    return
                }
                records[key] = record
                rebuild()
                connection.reply(nil)
                return
            }
            connection.reply(nil)
        }

        var attention = false

        switch kind {
        case "SessionStart":
            record.status = .running
        case "UserPromptSubmit":
            record.status = .running
            record.turnStarted = Date()
            record.diff = []
            // What the agent injects itself (a finished background task …) is not your last prompt.
            if let prompt = event["prompt"] as? String, !InjectedPrompt.isInjected(prompt) {
                record.lastPrompt = prompt
                record.lastMessage = ""
                Self.push(&record, .done, "prompt: " + Self.shorten(prompt, 60))
            }
            recap?.prompt(session: key, project: record.project, agent: name)
        case "PreToolUse":
            record.status = .running
            if let path = Self.filePath(input) { record.file = Self.shortPath(path) }
            if let edit = Self.editDiff(tool: tool, input: input) { record.diff = edit.lines }
            Self.push(&record, .running, Self.describe(tool: tool, input: input))
            // The prompt was missed (Nook started mid-turn): this turn is at least this old.
            if record.turnStarted == nil { record.turnStarted = Date() }
            recap?.toolUse(tool)
        case "PostToolUse":
            Self.complete(&record, as: .done)
            Self.resume(&record, asking: isAsking(key))
            if let edit = Self.editDiff(tool: tool, input: input) {
                record.linesAdded += edit.added
                record.linesRemoved += edit.removed
                recap?.edit(added: edit.added, removed: edit.removed)
            }
        case "PostToolUseFailure":
            Self.complete(&record, as: .failed)
            Self.resume(&record, asking: isAsking(key))
        case "Notification":
            let message = (event["message"] as? String) ?? "waiting for you"
            record.lastMessage = message
            // If the question is already presented as a card in the notch, don't show another alert.
            let asking = isAsking(key)
            // "Claude is waiting for your input" is Claude Code's idle message after finishing a turn: not a prompt to you.
            let idle = message.lowercased().contains("waiting for your input")
            if idle && !asking {
                if record.status != .done { record.status = .done }
                record.turnStarted = nil
                Self.push(&record, .done, "done, waiting for your next prompt")
            } else if !asking {
                record.status = .waiting
                Self.push(&record, .blocked, Self.shorten(message, 70))
                attention = true
            }
        case "Stop":
            record.status = .done
            record.turnStarted = nil
            if let last = (event["last-assistant-message"] as? String) ?? (event["last_assistant_message"] as? String) {
                record.lastMessage = last
            }
            Self.complete(&record, as: .done)
            Self.push(&record, .done, "done")
            attention = true
            recap?.turnEnded(session: key)
        case "StopFailure":
            record.status = .failed
            record.turnStarted = nil
            let error = (event["error"] as? String) ?? (event["message"] as? String) ?? "stopped with an error"
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, Self.shorten(error, 70))
            attention = true
            recap?.turnEnded(session: key)
        case "SubagentStart":
            let type = (event["agent_type"] as? String) ?? (event["subagent_type"] as? String) ?? ""
            Self.push(&record, .running, type.isEmpty ? "subagent started" : "subagent: \(type)")
        case "SubagentStop":
            Self.complete(&record, as: .done)
        case "Interrupt":
            record.status = .done
            record.turnStarted = nil
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, "interrupted")
            recap?.turnEnded(session: key)
        default:
            break
        }

        records[key] = record
        rebuild()
        if attention, let session = sessions.first(where: { $0.id == key }) {
            onAttention?(session)
        }
        if mode != "permission" { connection.reply(nil) }
    }

    // MARK: Permissions

    private func requestApproval(
        key: String,
        record: inout Record,
        tool: String,
        input: [String: Any],
        kind: PendingKind,
        connection: HookConnection
    ) {
        let id = UUID().uuidString
        let summary = Self.approvalSummary(tool: tool, input: input)
        let edit = Self.editDiff(tool: tool, input: input)
        let assessment = Self.assess(tool: tool, input: input, edit: edit)
        var canAlways = false
        if case .permission(_, let always) = kind { canAlways = always }

        let request = ApprovalRequest(
            id: id,
            sessionKey: key,
            agentName: record.agent,
            project: record.project,
            tool: tool,
            summary: summary,
            diff: edit?.lines ?? [],
            assessment: assessment,
            canAlways: canAlways,
            created: Date()
        )
        pendingApprovals[id] = PendingApproval(request: request, connection: connection, kind: kind)
        approvals.append(request)

        record.status = .waiting
        if let edit { record.diff = edit.lines }
        Self.replaceLast(&record, .blocked, "waiting for you: " + Self.shorten(summary, 50))

        connection.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeApproval(id, response: nil, status: .running, step: (.running, "answered in the terminal"))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.approvalTimeout * 1_000_000_000)
            // No answer received: the agent will prompt directly, as normal.
            self?.closeApproval(id, response: nil, status: .waiting, step: (.blocked, "waiting for you in the terminal"))
        }
        onApproval?(request)
    }

    private func closeApproval(
        _ id: String,
        response: Data?,
        status: AgentStatus?,
        step: (AgentStep.Mark, String)?,
        message: String? = nil
    ) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        pending.connection.reply(response)
        approvals.removeAll { $0.id == id }
        let key = pending.request.sessionKey
        if var record = records[key] {
            if let status, record.status == .waiting { record.status = status }
            if let step { Self.replaceLast(&record, step.0, step.1) }
            records[key] = record
        }
        rebuild()
        onApprovalGone?(id, message)
    }

    private static func response(for decision: ApprovalDecision, kind: PendingKind) -> Data? {
        let payload: [String: Any]
        switch kind {
        case .legacyPreToolUse:
            let value: String
            switch decision {
            case .allow, .always: value = "allow"
            case .deny: value = "deny"
            case .terminal: return nil
            }
            payload = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": value,
                    "permissionDecisionReason": value == "allow" ? "Approved via Nook" : "Denied via Nook"
                ]
            ]
        case .permission(let suggestions, let canAlways):
            var result: [String: Any]
            switch decision {
            case .allow:
                result = ["behavior": "allow"]
            case .always:
                result = ["behavior": "allow"]
                // Claude Code persists rule itself, just like "Yes, and don't ask again".
                if canAlways, let suggestions = suggestions as? [Any], !suggestions.isEmpty {
                    result["updatedPermissions"] = suggestions
                }
            case .deny:
                result = ["behavior": "deny", "message": "Denied via Nook"]
            case .terminal:
                return nil
            }
            payload = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Questions

    private func askQuestion(
        key: String,
        record: inout Record,
        items: [AgentQuestionItem],
        raw: Any,
        connection: HookConnection
    ) {
        let id = UUID().uuidString
        let request = AgentQuestionRequest(id: id, sessionKey: key, agentName: record.agent, project: record.project, items: items)
        pendingQuestions[id] = PendingQuestion(request: request, connection: connection, rawQuestions: raw)
        record.status = .waiting
        Self.push(&record, .blocked, "question: " + Self.shorten(items[0].question, 60))

        connection.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeQuestion(id, response: nil, status: .running, step: (.done, "answered in the terminal"))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.questionTimeout * 1_000_000_000)
            self?.closeQuestion(id, response: nil, status: .waiting, step: (.blocked, "question is in the terminal"))
        }
        onQuestion?(request)
    }

    private func closeQuestion(
        _ id: String,
        response: Data?,
        status: AgentStatus?,
        step: (AgentStep.Mark, String)?,
        message: String? = nil
    ) {
        guard let pending = pendingQuestions.removeValue(forKey: id) else { return }
        pending.connection.reply(response)
        let key = pending.request.sessionKey
        if var record = records[key] {
            if let status, record.status == .waiting { record.status = status }
            if let step { Self.replaceLast(&record, step.0, step.1) }
            records[key] = record
        }
        rebuild()
        onQuestionGone?(id, message)
    }

    // MARK: Session List

    private func prune() {
        let now = Date()
        records = records.filter { key, record in
            if pendingApprovals.values.contains(where: { $0.request.sessionKey == key }) { return true }
            let age = now.timeIntervalSince(record.updated)
            return record.status == .done ? age < 4 * 3600 : age < 12 * 3600
        }
        rebuild()
    }

    private func rebuild() {
        let order: [AgentStatus: Int] = [.waiting: 0, .failed: 1, .running: 2, .done: 3]
        let newSessions = records
            .sorted { lhs, rhs in
                let l = order[lhs.value.status] ?? 9
                let r = order[rhs.value.status] ?? 9
                return l != r ? l < r : lhs.value.updated > rhs.value.updated
            }
            .map { key, record in
                var diff: [DiffLine] = []
                if record.status == .done || record.status == .failed || record.diff.isEmpty {
                    if !record.cwd.isEmpty { diff.append(DiffLine(kind: .context, text: record.cwd)) }
                    for line in record.lastMessage.split(separator: "\n").prefix(8) {
                        diff.append(DiffLine(kind: .context, text: String(line.prefix(110))))
                    }
                } else {
                    diff = record.diff
                }
                var file = record.file
                if record.linesAdded + record.linesRemoved > 0 {
                    file += "  +\(record.linesAdded) −\(record.linesRemoved)"
                }
                return AgentSession(
                    id: key,
                    name: record.agent,
                    project: record.project,
                    status: record.status,
                    file: file,
                    placeholder: "Type in the terminal of \(record.agent) to continue",
                    steps: record.steps,
                    diff: diff,
                    cwd: record.cwd,
                    hostBundleID: record.hostBundleID,
                    home: record.home,
                    approvalID: approvals.first { $0.sessionKey == key }?.id,
                    linesAdded: record.linesAdded,
                    linesRemoved: record.linesRemoved,
                    summary: Self.oneLine(record.lastMessage),
                    sessionID: record.sessionID,
                    transcriptPath: record.transcriptPath,
                    lastPrompt: record.lastPrompt,
                    lastReply: record.lastMessage,
                    started: record.started,
                    turnStarted: record.turnStarted,
                    updated: record.updated
                )
            }
        if sessions != newSessions {
            sessions = newSessions
        }
    }

    // MARK: Helper Functions

    private static func push(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        record.steps.append(AgentStep(mark: mark, text: text))
        if record.steps.count > 6 { record.steps.removeFirst(record.steps.count - 6) }
    }

    private static func replaceLast(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        guard !record.steps.isEmpty else {
            push(&record, mark, text)
            return
        }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: text)
    }

    /// A tool finished while the session read as waiting: you answered its prompt in the terminal, so it works again.
    /// Without this it stayed amber ("waits for you") until the next tool started or the turn ended.
    private static func resume(_ record: inout Record, asking: Bool) {
        guard record.status == .waiting, !asking else { return }
        record.status = .running
    }

    /// Is a card in the notch still asking you something for this session (an approval or a question)?
    private func isAsking(_ key: String) -> Bool {
        pendingApprovals.values.contains { $0.request.sessionKey == key }
            || pendingQuestions.values.contains { $0.request.sessionKey == key }
    }

    /// Closes the last step that was running (or waiting for user input).
    private static func complete(_ record: inout Record, as mark: AgentStep.Mark) {
        guard let last = record.steps.last, last.mark == .running || last.mark == .blocked else { return }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: last.text)
    }

    /// Normalizes event names from other agents (Gemini CLI, Antigravity, Copilot, Cursor, etc.) to Claude Code convention.
    static func normalize(_ name: String) -> String {
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
        return map[name] ?? name
    }

    private static func cleanAgentID(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let clean = String(raw.lowercased().filter { allowed.contains($0) }.prefix(32))
        return clean.isEmpty ? "agent" : clean
    }

    private static func displayName(_ id: String) -> String {
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

    static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || cwd.isEmpty || name == "/" ? "no folder" : name
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
            if parts.count >= 3, ["bash", "sh", "zsh"].contains(URL(fileURLWithPath: parts[0]).lastPathComponent),
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

    private static func approvalSummary(tool: String, input: [String: Any]) -> String {
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

    private static func assess(
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
            let file = filePath(input).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
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

    private static func describe(tool: String, input: [String: Any]) -> String {
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
            return "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)"
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
