import Foundation

enum ApprovalDecision {
    case allow
    case deny
}

struct ApprovalRequest {
    let agentName: String
    let project: String
    let command: String
    let assessment: CommandAssessment
    let reply: @MainActor (ApprovalDecision) -> Void
}

/// Zorgt dat een antwoord maar één keer wordt verstuurd, ook als gebruiker en time-out tegelijk afgaan.
private final class ReplyOnce {
    private let lock = NSLock()
    private var done = false
    private let send: (Data?) -> Void

    init(_ send: @escaping (Data?) -> Void) {
        self.send = send
    }

    @discardableResult
    func fire(_ data: Data?) -> Bool {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { send(data) }
        return first
    }
}

/// Houdt bij welke AI-agents er draaien, op basis van hun hooks. Kan ook (alleen voor Bash) om jouw goedkeuring vragen.
@MainActor
final class AgentHub: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Agents die als proces draaien maar (nog) niet via hooks melden.
    @Published private(set) var detected: [AgentSession] = []
    private var scanTimer: Timer?

    var onApproval: ((ApprovalRequest) -> Void)?
    var onAttention: ((AgentSession) -> Void)?

    private struct Record {
        var agent: String
        var project: String
        var cwd: String
        var status: AgentStatus
        var steps: [AgentStep]
        var file: String
        var lastMessage: String
        var updated: Date
    }

    private var records: [String: Record] = [:]
    private let server = UnixSocketServer(path: NookPaths.socketURL.path)
    private var pruneTimer: Timer?

    func start() {
        server.onMessage = { [weak self] data, send in
            let once = ReplyOnce(send)
            Task { @MainActor in
                if let self {
                    self.handle(data, reply: once)
                } else {
                    once.fire(nil)
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
                    diff: []
                )
            }
        }
    }

    // MARK: Berichten

    private func handle(_ data: Data, reply: ReplyOnce) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? [String: Any] else {
            reply.fire(nil)
            return
        }

        let agentID = (object["agent"] as? String) ?? "agent"
        let wait = (object["wait"] as? Bool) ?? false
        let kind = (event["hook_event_name"] as? String) ?? (event["type"] as? String) ?? ""
        let cwd = (event["cwd"] as? String) ?? ""
        let sessionID = (event["session_id"] as? String) ?? (event["thread-id"] as? String) ?? cwd
        let key = "\(agentID):\(sessionID)"
        let name = Self.displayName(agentID)

        if kind == "SessionEnd" {
            records[key] = nil
            rebuild()
            reply.fire(nil)
            return
        }

        var record = records[key] ?? Record(
            agent: name,
            project: Self.projectName(cwd),
            cwd: cwd,
            status: .running,
            steps: [],
            file: "",
            lastMessage: "",
            updated: Date()
        )
        if !cwd.isEmpty {
            record.cwd = cwd
            record.project = Self.projectName(cwd)
        }
        record.updated = Date()

        let tool = (event["tool_name"] as? String) ?? ""
        let input = (event["tool_input"] as? [String: Any]) ?? [:]
        var attention = false
        var pendingApproval = false

        switch kind {
        case "SessionStart":
            record.status = .running
        case "UserPromptSubmit":
            record.status = .running
            if let prompt = event["prompt"] as? String {
                Self.push(&record, .done, "opdracht: " + Self.shorten(prompt, 60))
            }
        case "PreToolUse":
            record.status = .running
            if let path = input["file_path"] as? String {
                record.file = Self.shortPath(path)
            }
            Self.push(&record, .running, Self.describe(tool: tool, input: input))

            if wait, tool == "Bash", let command = input["command"] as? String {
                let assessment = CommandRisk.assess(command)
                if assessment.level != .safe {
                    pendingApproval = true
                    record.status = .waiting
                    Self.replaceLast(&record, .blocked, "wacht op jou: " + Self.shorten(command, 50))
                    let project = record.project
                    let request = ApprovalRequest(
                        agentName: name,
                        project: project,
                        command: command,
                        assessment: assessment,
                        reply: { [weak self] decision in
                            reply.fire(Self.hookResponse(decision))
                            self?.resumed(key: key, allowed: decision == .allow)
                        }
                    )
                    onApproval?(request)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 90_000_000_000)
                        // Geen antwoord gekregen: de agent vraagt het dan zelf, zoals normaal.
                        if reply.fire(nil) {
                            self?.resumed(key: key, allowed: true)
                        }
                    }
                }
            }
        case "PostToolUse":
            Self.completeLast(&record)
        case "Notification":
            record.status = .waiting
            let message = (event["message"] as? String) ?? "wacht op je"
            record.lastMessage = message
            Self.push(&record, .blocked, Self.shorten(message, 70))
            attention = true
        case "Stop", "agent-turn-complete":
            record.status = .done
            if let last = event["last-assistant-message"] as? String { record.lastMessage = last }
            Self.completeLast(&record)
            Self.push(&record, .done, "klaar")
            attention = true
        default:
            break
        }

        records[key] = record
        rebuild()
        if attention, let session = sessions.first(where: { $0.id == key }) {
            onAttention?(session)
        }
        if !pendingApproval { reply.fire(nil) }
    }

    private func resumed(key: String, allowed: Bool) {
        guard var record = records[key], record.status == .waiting else { return }
        record.status = .running
        Self.replaceLast(&record, allowed ? .running : .failed, allowed ? "toegestaan via Nook" : "geweigerd via Nook")
        records[key] = record
        rebuild()
    }

    private func prune() {
        let now = Date()
        records = records.filter { _, record in
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
                if !record.cwd.isEmpty { diff.append(DiffLine(kind: .context, text: record.cwd)) }
                for line in record.lastMessage.split(separator: "\n").prefix(4) {
                    diff.append(DiffLine(kind: .context, text: String(line.prefix(90))))
                }
                return AgentSession(
                    id: key,
                    name: record.agent,
                    project: record.project,
                    status: record.status,
                    file: record.file.isEmpty ? "nog geen bestand geraakt" : record.file,
                    placeholder: "Typ in de terminal van \(record.agent) om verder te gaan",
                    steps: record.steps,
                    diff: diff
                )
            }
    }

    // MARK: Hulpfuncties

    private static func push(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        record.steps.append(AgentStep(mark: mark, text: text))
        if record.steps.count > 5 { record.steps.removeFirst(record.steps.count - 5) }
    }

    private static func replaceLast(_ record: inout Record, _ mark: AgentStep.Mark, _ text: String) {
        guard !record.steps.isEmpty else {
            push(&record, mark, text)
            return
        }
        record.steps[record.steps.count - 1] = AgentStep(mark: mark, text: text)
    }

    private static func completeLast(_ record: inout Record) {
        guard let last = record.steps.last, last.mark == .running else { return }
        record.steps[record.steps.count - 1] = AgentStep(mark: .done, text: last.text)
    }

    private static func hookResponse(_ decision: ApprovalDecision) -> Data? {
        let value: String
        let reason: String
        switch decision {
        case .allow:
            value = "allow"
            reason = "Goedgekeurd via Nook"
        case .deny:
            value = "deny"
            reason = "Geweigerd via Nook"
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": value,
                "permissionDecisionReason": reason
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func displayName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "onbekend" : name
    }

    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private static func shorten(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return "Bash: " + shorten((input["command"] as? String) ?? "", 55)
        case "Edit", "Write", "MultiEdit", "Read":
            let path = (input["file_path"] as? String) ?? ""
            return "\(tool) \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Grep", "Glob":
            return "\(tool) \(shorten((input["pattern"] as? String) ?? "", 40))"
        case "WebFetch":
            let host = URL(string: (input["url"] as? String) ?? "")?.host ?? ""
            return "WebFetch \(host)"
        default:
            return tool.isEmpty ? "bezig" : tool
        }
    }
}
