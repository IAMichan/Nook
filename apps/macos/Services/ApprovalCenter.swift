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

/// The one place approvals are collected and decided.
@MainActor
final class ApprovalCenter {
    private unowned let hub: AgentHub
    private unowned let workspace: WorkspaceManager
    private unowned let bridge: WorkspaceBridge

    init(hub: AgentHub, workspace: WorkspaceManager, bridge: WorkspaceBridge) {
        self.hub = hub
        self.workspace = workspace
        self.bridge = bridge
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
        return AgentApproval(
            origin: .run(runID: run.id, requestID: pending.id), agentName: run.provider.displayName, project: run.title,
            tool: pending.tool, title: tr("ws.approval.title", run.provider.kind.shortName, pending.tool),
            command: command ?? pending.summary, diff: edit?.lines ?? [], note: assessment.note,
            danger: assessment.level == .danger, canAlways: pending.canAlways, canTerminal: false, created: pending.created
        )
    }

    static func make(_ request: BridgeRequest) -> AgentApproval {
        AgentApproval(
            origin: .bridge(requestID: request.id), agentName: request.caller.agent,
            project: URL(fileURLWithPath: request.caller.directory).lastPathComponent, tool: request.tool.rawValue,
            title: request.title, command: request.detail, diff: [], note: request.note, danger: request.danger,
            canAlways: false, canTerminal: false, created: request.created
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

    func decide(_ approval: AgentApproval, _ decision: ApprovalDecision) {
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
