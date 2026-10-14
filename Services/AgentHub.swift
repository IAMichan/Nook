import Foundation

/// Houdt bij welke AI-agents er draaien, op basis van hun hooks, en brengt hun vragen naar de notch:
/// toestemming (alleen als de agent het jou zelf ook zou vragen) en meerkeuzevragen (AskUserQuestion).
/// Antwoord je in de terminal, dan verdwijnt de vraag in de notch meteen.
@MainActor
final class AgentHub: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Agents die als proces draaien maar (nog) niet via hooks melden.
    @Published private(set) var detected: [AgentSession] = []
    /// Toestemmingsvragen die nu wachten, oudste eerst.
    @Published private(set) var approvals: [ApprovalRequest] = []
    /// Gebruik van je Claude-abonnement, als de statusregel gekoppeld is.
    @Published private(set) var planUsage: PlanUsage?

    var onApproval: ((ApprovalRequest) -> Void)?
    /// Een vraag is beantwoord (hier of elders) of verlopen: haal de kaart weg. De tekst is een bevestiging
    /// om te tonen als jij in Nook antwoordde, anders nil.
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
        var diff: [DiffLine]
        var linesAdded: Int
        var linesRemoved: Int
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

    private var records: [String: Record] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingQuestions: [String: PendingQuestion] = [:]
    private let server = UnixSocketServer(path: NookPaths.socketURL.path)
    private var pruneTimer: Timer?
    private var scanTimer: Timer?

    /// Na zoveel seconden zonder antwoord vraagt de agent het weer zelf (de hook-time-out is 120 s).
    private static let approvalTimeout: UInt64 = 110
    private static let questionTimeout: UInt64 = 120

    func start() {
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
            NSLog("Nook hub: \(error.localizedDescription)")
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        refreshDetected()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDetected() }
        }
    }

    /// Zoekt draaiende agents. Wat al via hooks binnenkomt, staat er niet dubbel in.
    func refreshDetected() {
        Task {
            let found = await LocalAgentScanner.scan()
            let hooked = Set(records.values.map { "\($0.agent)|\($0.cwd)" })
            var seen = Set<String>()
            detected = found.compactMap { agent in
                let key = "\(agent.name)|\(agent.cwd)"
                guard !hooked.contains(key), seen.insert(key).inserted else { return nil }
                return AgentSession(
                    id: "proc-\(agent.pid)",
                    name: agent.name,
                    project: Self.projectName(agent.cwd),
                    status: .detected,
                    file: agent.cwd.isEmpty ? "draait op deze Mac" : Self.shortPath(agent.cwd),
                    placeholder: "Typ in de terminal van \(agent.name) om verder te gaan",
                    steps: [
                        AgentStep(mark: .running, text: "\(agent.name) draait, maar Nook ziet nog niet wat hij doet"),
                        AgentStep(mark: .todo, text: "Wil je voortgang zien en iets kunnen goedkeuren? Klik op 'Koppel in Instellingen' hieronder"),
                        AgentStep(mark: .todo, text: "Daarna start je \(agent.name) opnieuw in de terminal")
                    ],
                    diff: [],
                    cwd: agent.cwd
                )
            }
        }
    }

    // MARK: Antwoorden vanuit Nook

    func approval(id: String) -> ApprovalRequest? {
        pendingApprovals[id]?.request
    }

    func decide(_ id: String, _ decision: ApprovalDecision) {
        guard let pending = pendingApprovals[id] else { return }
        let response = Self.response(for: decision, kind: pending.kind)
        switch decision {
        case .allow:
            recap?.decision(allowed: true)
            closeApproval(id, response: response, status: .running, step: (.running, "toegestaan via Nook"), message: "Toegestaan")
        case .always:
            recap?.decision(allowed: true)
            closeApproval(id, response: response, status: .running, step: (.running, "altijd toegestaan via Nook"), message: "Altijd toegestaan")
        case .deny:
            recap?.decision(allowed: false)
            closeApproval(id, response: response, status: .running, step: (.failed, "geweigerd via Nook"), message: "Geweigerd")
        case .terminal:
            closeApproval(id, response: nil, status: .waiting, step: (.blocked, "wacht op je in de terminal"))
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
                      step: (.done, "jij koos: " + Self.shorten(summary, 50)), message: "Antwoord verstuurd")
    }

    func answerQuestionInTerminal(_ id: String) {
        closeQuestion(id, response: nil, status: .waiting, step: (.blocked, "vraag staat in de terminal"))
    }

    // MARK: Berichten

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
            if let usage = PlanUsage.parse(event) { planUsage = usage }
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
        record.updated = Date()

        let tool = (event["tool_name"] as? String) ?? (event["toolName"] as? String) ?? ""
        let input = (event["tool_input"] as? [String: Any]) ?? (event["toolArgs"] as? [String: Any]) ?? [:]

        // Een meerkeuzevraag van de agent.
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

        // Toestemming: de agent wacht op ons antwoord.
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
                // Oude koppeling (vóór PermissionRequest): alleen commando's die niet duidelijk onschuldig zijn.
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
            record.diff = []
            if let prompt = event["prompt"] as? String {
                Self.push(&record, .done, "opdracht: " + Self.shorten(prompt, 60))
            }
            recap?.prompt(session: key, project: record.project, agent: name)
        case "PreToolUse":
            record.status = .running
            if let path = Self.filePath(input) { record.file = Self.shortPath(path) }
            if let edit = Self.editDiff(tool: tool, input: input) { record.diff = edit.lines }
            Self.push(&record, .running, Self.describe(tool: tool, input: input))
            recap?.toolUse(tool)
        case "PostToolUse":
            Self.complete(&record, as: .done)
            if let edit = Self.editDiff(tool: tool, input: input) {
                record.linesAdded += edit.added
                record.linesRemoved += edit.removed
                recap?.edit(added: edit.added, removed: edit.removed)
            }
        case "PostToolUseFailure":
            Self.complete(&record, as: .failed)
        case "Notification":
            let message = (event["message"] as? String) ?? "wacht op je"
            record.lastMessage = message
            // Staat de vraag al als kaart in de notch, dan niet nog een melding.
            let asking = pendingApprovals.values.contains { $0.request.sessionKey == key }
                || pendingQuestions.values.contains { $0.request.sessionKey == key }
            if !asking {
                record.status = .waiting
                Self.push(&record, .blocked, Self.shorten(message, 70))
                attention = true
            }
        case "Stop":
            record.status = .done
            if let last = (event["last-assistant-message"] as? String) ?? (event["last_assistant_message"] as? String) {
                record.lastMessage = last
            }
            Self.complete(&record, as: .done)
            Self.push(&record, .done, "klaar")
            attention = true
            recap?.turnEnded(session: key)
        case "StopFailure":
            record.status = .failed
            let error = (event["error"] as? String) ?? (event["message"] as? String) ?? "gestopt met een fout"
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, Self.shorten(error, 70))
            attention = true
            recap?.turnEnded(session: key)
        case "SubagentStart":
            let type = (event["agent_type"] as? String) ?? (event["subagent_type"] as? String) ?? ""
            Self.push(&record, .running, type.isEmpty ? "hulpagent gestart" : "hulpagent: \(type)")
        case "SubagentStop":
            Self.complete(&record, as: .done)
        case "Interrupt":
            record.status = .done
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, "onderbroken")
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

    // MARK: Toestemming

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
        Self.replaceLast(&record, .blocked, "wacht op jou: " + Self.shorten(summary, 50))

        connection.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeApproval(id, response: nil, status: .running, step: (.running, "beantwoord in de terminal"))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.approvalTimeout * 1_000_000_000)
            // Geen antwoord gekregen: de agent vraagt het dan zelf, zoals normaal.
            self?.closeApproval(id, response: nil, status: .waiting, step: (.blocked, "wacht op je in de terminal"))
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
                    "permissionDecisionReason": value == "allow" ? "Goedgekeurd via Nook" : "Geweigerd via Nook"
                ]
            ]
        case .permission(let suggestions, let canAlways):
            var result: [String: Any]
            switch decision {
            case .allow:
                result = ["behavior": "allow"]
            case .always:
                result = ["behavior": "allow"]
                // Claude Code onthoudt de regel dan zelf, net als bij "Yes, and don't ask again".
                if canAlways, let suggestions = suggestions as? [Any], !suggestions.isEmpty {
                    result["updatedPermissions"] = suggestions
                }
            case .deny:
                result = ["behavior": "deny", "message": "Geweigerd via Nook"]
            case .terminal:
                return nil
            }
            payload = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Vragen

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
        Self.push(&record, .blocked, "vraag: " + Self.shorten(items[0].question, 60))

        connection.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeQuestion(id, response: nil, status: .running, step: (.done, "beantwoord in de terminal"))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.questionTimeout * 1_000_000_000)
            self?.closeQuestion(id, response: nil, status: .waiting, step: (.blocked, "vraag staat in de terminal"))
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

    // MARK: Lijst

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
        sessions = records
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
                var file = record.file.isEmpty ? "nog geen bestand geraakt" : record.file
                if record.linesAdded + record.linesRemoved > 0 {
                    file += "  +\(record.linesAdded) −\(record.linesRemoved)"
                }
                return AgentSession(
                    id: key,
                    name: record.agent,
                    project: record.project,
                    status: record.status,
                    file: file,
                    placeholder: "Typ in de terminal van \(record.agent) om verder te gaan",
                    steps: record.steps,
                    diff: diff,
                    cwd: record.cwd,
                    hostBundleID: record.hostBundleID,
                    approvalID: approvals.first { $0.sessionKey == key }?.id,
                    linesAdded: record.linesAdded,
                    linesRemoved: record.linesRemoved
                )
            }
    }

    // MARK: Hulpfuncties

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

    /// De laatste stap die nog bezig was (of op jou wachtte), afsluiten.
    private static func complete(_ record: inout Record, as mark: AgentStep.Mark) {
        guard let last = record.steps.last, last.mark == .running || last.mark == .blocked else { return }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: last.text)
    }

    /// Gebeurtenisnamen van andere agents (Gemini CLI, Copilot, …) naar die van Claude Code.
    static func normalize(_ name: String) -> String {
        let map: [String: String] = [
            "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse",
            "BeforeAgent": "UserPromptSubmit", "AfterAgent": "Stop",
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
        case "copilot": return "Copilot CLI"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "amp": return "Amp"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || cwd.isEmpty ? "onbekend" : name
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// Het commando, ook als een agent het als lijst stuurt (Codex: ["bash", "-lc", "npm test"]).
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
        if let command = commandText(input) { return command }
        if let path = filePath(input) { return "\(tool) \(shortPath(path))" }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return "zoekt: \(query)" }
        if tool.hasPrefix("mcp__") {
            return tool.components(separatedBy: "__").dropFirst().joined(separator: " › ")
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != "{}" {
            return "\(tool) \(shorten(text, 140))"
        }
        return tool.isEmpty ? "iets op je Mac" : tool
    }

    private static func assess(
        tool: String,
        input: [String: Any],
        edit: (lines: [DiffLine], added: Int, removed: Int)?
    ) -> CommandAssessment {
        if let command = commandText(input) {
            let assessment = CommandRisk.assess(command)
            if assessment.level == .safe {
                return CommandAssessment(level: .review, title: "", note: "Leest alleen · lijkt onschuldig")
            }
            return assessment
        }
        if let edit {
            let file = filePath(input).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "een bestand"
            return CommandAssessment(level: .review, title: "", note: "Past \(file) aan · +\(edit.added) −\(edit.removed)")
        }
        if let url = input["url"] as? String {
            return CommandAssessment(level: .review, title: "", note: "Haalt iets op van \(URL(string: url)?.host ?? "internet")")
        }
        if tool.hasPrefix("mcp__") {
            return CommandAssessment(level: .review, title: "", note: "Gebruikt een externe koppeling (MCP)")
        }
        return CommandAssessment(level: .review, title: "", note: "Lees het even na")
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
            case "Read", "read_file": verb = "Leest"
            case "Write", "write_file": verb = "Schrijft"
            default: verb = "Past aan"
            }
            return "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Grep", "Glob", "search_file_content", "glob":
            return "Zoekt \(shorten((input["pattern"] as? String) ?? "", 40))"
        case "WebFetch", "web_fetch":
            let host = URL(string: (input["url"] as? String) ?? "")?.host ?? ""
            return "Haalt op: \(host)"
        case "WebSearch", "google_web_search":
            return "Zoekt online: \(shorten((input["query"] as? String) ?? "", 40))"
        case "Task", "Agent":
            return "Hulpagent: \(shorten((input["description"] as? String) ?? "", 40))"
        case "TodoWrite":
            return "Werkt de takenlijst bij"
        default:
            if tool.hasPrefix("mcp__") {
                return "Koppeling: " + tool.components(separatedBy: "__").dropFirst().joined(separator: " › ")
            }
            return tool.isEmpty ? "bezig" : tool
        }
    }
}
