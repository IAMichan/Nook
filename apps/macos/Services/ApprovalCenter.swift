import Foundation

/// An agent asks permission, whichever way the request reached Nook: through a hook of a session running in a terminal,
/// or from a session Nook runs itself. Every place that shows or decides a request (the notch card, the Agents list,
/// the session view) works with this one type.
struct AgentApproval: Identifiable {
    enum Origin: Equatable {
        case hook(requestID: String)
        case run(runID: UUID, requestID: String)
        /// A command or pull request an agent asks for through Nook's workspace bridge.
        case bridge(requestID: String)
    }

    let origin: Origin
    let agentName: String
    let project: String
    let tool: String
    let title: String
    /// The whole command or description, never shortened: what is approved must be what is shown.
    let command: String
    /// For file edits: the change as a diff.
    let diff: [DiffLine]
    let note: String
    let danger: Bool
    let canAlways: Bool
    /// The agent can also ask in its own terminal (hook sessions only).
    let canTerminal: Bool
    let created: Date
    /// `command` is text for people (Markdown), not a command: drawn as prose.
    var prose = false
    /// A secret Nook does not keep yet: the request shows a secure field for its value.
    var secretName: String? = nil

    var id: String {
        switch origin {
        case .hook(let request): return "hook-" + request
        case .run(_, let request): return "run-" + request
        case .bridge(let request): return "bridge-" + request
        }
    }

    /// The id of the notch card for this request.
    var cardToken: String {
        switch origin {
        case .hook(let request): return "approval-" + request
        case .run(_, let request): return "wsapproval-" + request
        case .bridge(let request): return "bridge-" + request
        }
    }
}

/// The one place approvals are collected and decided. Every decision goes to the action log (`audit` in
/// `nook.sqlite`): who asked, for what, what was decided and where.
@MainActor
final class ApprovalCenter {
    private unowned let hub: AgentHub
    private unowned let workspace: WorkspaceManager
    private unowned let bridge: WorkspaceBridge
    /// Writes one entry to the action log (tool, arguments, result).
    private let audit: (String, String, String) -> Void

    init(hub: AgentHub, workspace: WorkspaceManager, bridge: WorkspaceBridge,
         audit: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        self.hub = hub
        self.workspace = workspace
        self.bridge = bridge
        self.audit = audit
    }

    /// The action log's line for a decision: the agent, its session, the tool and what it asked for.
    static func auditEntry(_ approval: AgentApproval, _ decision: ApprovalDecision,
                           source: ApprovalSource) -> (tool: String, args: String, result: String) {
        ApprovalAudit.entry(agent: approval.agentName, project: approval.project, tool: approval.tool,
                            asked: approval.command.isEmpty ? approval.title : approval.command, decision: decision.auditName,
                            source: source, danger: approval.danger)
    }

    static func make(_ request: ApprovalRequest) -> AgentApproval {
        AgentApproval(
            origin: .hook(requestID: request.id), agentName: request.agentName, project: request.project, tool: request.tool,
            title: request.title, command: request.summary, diff: request.diff, note: request.assessment.note,
            danger: request.assessment.level == .danger, canAlways: request.canAlways, canTerminal: true, created: request.created
        )
    }

    static func make(_ pending: PendingPermission, run: WorkspaceRun) -> AgentApproval {
        let input = pending.input.dictionary
        let command = ToolSummary.command(input)
        let assessment = command.map { CommandRisk.assess($0) }
            ?? CommandAssessment(level: .review, title: "", note: tr("ws.approval.note"))
        let edit = AgentHub.editDiff(tool: pending.tool, input: input)
        // An MCP tool by its readable name and server, with every argument it gets.
        let mcp = McpToolName(pending.tool)
        let title = mcp.map { tr("ws.approval.mcpTitle", run.provider.kind.shortName, $0.toolLabel, $0.serverLabel) }
            ?? tr("ws.approval.title", run.provider.kind.shortName, pending.tool)
        let arguments = mcp == nil ? "" : McpToolName.arguments(input)
        return AgentApproval(
            origin: .run(runID: run.id, requestID: pending.id), agentName: run.provider.displayName, project: run.title,
            tool: pending.tool, title: title,
            command: arguments.isEmpty ? command ?? pending.summary : arguments, diff: edit?.lines ?? [],
            note: mcp == nil || assessment.level == .danger ? assessment.note : tr("ws.approval.mcpNote"),
            danger: assessment.level == .danger, canAlways: pending.canAlways, canTerminal: false, created: pending.created
        )
    }

    static func make(_ request: BridgeRequest) -> AgentApproval {
        AgentApproval(
            origin: .bridge(requestID: request.id), agentName: request.caller.agent,
            project: URL(fileURLWithPath: request.caller.directory).lastPathComponent, tool: request.tool.rawValue,
            title: request.title, command: request.detail, diff: [], note: request.note, danger: request.danger,
            canAlways: false, canTerminal: false, created: request.created, prose: request.tool.approvalReadsAsProse,
            secretName: request.secretName
        )
    }

    /// Everything waiting for a decision, oldest first.
    var pending: [AgentApproval] {
        var all = hub.approvals.map(Self.make)
        for run in workspace.runs {
            for request in workspace.approvals[run.id] ?? [] { all.append(Self.make(request, run: run)) }
        }
        all += bridge.pending.map(Self.make)
        return all.sorted { $0.created < $1.created }
    }

    /// Allows a secret request with the value typed on it.
    func allow(_ approval: AgentApproval, secret: BridgeSecretAnswer) {
        if case .bridge(let request) = approval.origin { bridge.give(request, secret) }
        decide(approval, .allow)
    }

    /// Decides a request of a session Nook runs by its ids (the timeline's own buttons, the phone).
    func decide(run runID: UUID, requestID: String, _ decision: ApprovalDecision, source: ApprovalSource = .app) {
        guard let run = workspace.run(runID), let request = workspace.approvals[runID]?.first(where: { $0.id == requestID }) else {
            return
        }
        decide(Self.make(request, run: run), decision, source: source)
    }

    func decide(_ approval: AgentApproval, _ decision: ApprovalDecision, source: ApprovalSource = .app) {
        let entry = Self.auditEntry(approval, decision, source: source)
        audit(entry.tool, entry.args, entry.result)
        switch approval.origin {
        case .hook(let request):
            hub.decide(request, decision)
        case .run(let runID, let request):
            switch decision {
            case .allow: workspace.decide(runID, requestID: request, .allow)
            case .always: workspace.decide(runID, requestID: request, .always)
            case .deny, .terminal: workspace.decide(runID, requestID: request, .deny)
            }
        case .bridge(let request):
            bridge.decide(request, allow: decision == .allow || decision == .always)
        }
    }
}

extension ApprovalDecision {
    /// The decision as the action log writes it.
    var auditName: String {
        switch self {
        case .allow: return "allow"
        case .always: return "always"
        case .deny: return "deny"
        case .terminal: return "terminal"
        }
    }

    /// The same for a session Nook runs, whose own prompt has no terminal.
    init(_ decision: WorkspaceManager.Decision) {
        switch decision {
        case .allow: self = .allow
        case .always: self = .always
        case .deny: self = .deny
        }
    }
}
