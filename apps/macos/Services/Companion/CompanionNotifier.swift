import Foundation
import CoreGraphics

/// Turns what happens in the workspace (an approval, a question, a finished or failed turn) into pushes to the paired
/// phones, within the user's rules (`PushSettings`): which events, only when away, quiet hours, titles or not.
@MainActor
final class CompanionNotifier: ObservableObject {
    static let shared = CompanionNotifier()

    @Published private(set) var lastResult: String?
    private weak var app: AppModel?
    private var ledger = PushLedger()

    func attach(app: AppModel) { self.app = app }

    /// Idle for two minutes, or the screen is locked.
    static func userIsAway() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= 120 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    func approval(_ run: WorkspaceRun, _ pending: PendingPermission) {
        var safe: Bool?
        if let command = (pending.input.object as? [String: Any])?["command"] as? String { safe = CommandRisk.assess(command).level == .safe }
        notify(PushEvent(kind: .approval, session: run.id.uuidString, item: pending.id, agent: run.provider.displayName, title: run.title,
                         canAllow: CompanionPolicy.canAllow(tool: pending.tool, commandIsSafe: safe)))
    }

    func question(_ run: WorkspaceRun, _ pending: PendingQuestion) {
        notify(PushEvent(kind: .question, session: run.id.uuidString, item: pending.id, agent: run.provider.displayName, title: run.title,
                         canAllow: pending.questions.count == 1))
    }

    func turnFinished(_ run: WorkspaceRun) {
        let kind: PushEvent.Kind = run.status == .failed ? (run.limitedAt != nil ? .limited : .failed) : .finished
        notify(PushEvent(kind: kind, session: run.id.uuidString, item: nil, agent: run.provider.displayName, title: run.title),
               turn: Int(run.updatedAt.timeIntervalSince1970))
    }

    /// A permission request from an agent running in a terminal, or through the workspace bridge (`CompanionAgents`).
    func approval(_ approval: AgentApproval) {
        guard let hub = app?.hub, let session = CompanionAgents.sessionID(approval, hub: hub) else { return }
        notify(PushEvent(kind: .approval, session: session, item: approval.id, agent: approval.agentName, title: approval.project,
                         canAllow: CompanionAgents.canAllow(approval)))
    }

    /// A terminal agent asks a question: the phone is told, the answer is given on the Mac.
    func question(_ request: AgentQuestionRequest) {
        notify(PushEvent(kind: .question, session: CompanionAgents.terminalPrefix + request.sessionKey, item: request.id,
                         agent: request.agentName, title: request.project))
    }

    /// A terminal agent finished or failed. Waiting on you is told by its approval or question.
    func attention(_ session: AgentSession) {
        let kind: PushEvent.Kind
        switch session.status {
        case .done: kind = .finished
        case .failed: kind = .failed
        default: return
        }
        notify(PushEvent(kind: kind, session: CompanionAgents.terminalPrefix + session.id, item: nil, agent: session.name,
                         title: session.project), turn: Int((session.updated ?? Date()).timeIntervalSince1970))
    }

    private func notify(_ event: PushEvent, turn: Int = 0) {
        let store = CompanionStore.shared
        guard store.enabled, store.canPush else { return }
        let targets = store.devices.filter { $0.pushToken != nil }
        guard !targets.isEmpty else { return }
        guard PushPolicy.skipReason(event, settings: store.push, away: Self.userIsAway(), now: Date()) == nil else { return }
        guard ledger.admit(event, turn: turn) else { return }
        deliver(event, turn: turn, to: targets, test: false)
    }

    /// A test push to every paired phone, ignoring the rules, so the key and the setup can be checked.
    func sendTest() {
        let event = PushEvent(kind: .finished, session: "test", item: nil, agent: "Nook", title: "")
        deliver(event, turn: Int(Date().timeIntervalSince1970), to: CompanionStore.shared.devices.filter { $0.pushToken != nil }, test: true)
    }

    private func badge() -> Int {
        guard let app else { return 0 }
        let workspace = app.workspace
        let runs = workspace.runs.filter { !(workspace.approvals[$0.id] ?? []).isEmpty || !(workspace.questions[$0.id] ?? []).isEmpty }.count
        // Terminal sessions and bridge requests that wait on you.
        let others = Set(app.approvals.pending.compactMap { CompanionAgents.sessionID($0, hub: app.hub) })
        return runs + others.count
    }

    private func text(_ event: PushEvent, test: Bool) -> (title: String, body: String) {
        if test { return ("Nook", tr("push.test")) }
        let store = CompanionStore.shared
        let title = store.push.includeTitle && !event.title.isEmpty ? "\(event.agent) · \(event.title)" : event.agent
        switch event.kind {
        case .approval: return (title, tr("push.approval"))
        case .question: return (title, tr("push.question"))
        case .failed: return (title, tr("push.failed"))
        case .limited: return (title, tr("push.limited"))
        case .finished: return (title, tr("push.finished"))
        }
    }

    private func deliver(_ event: PushEvent, turn: Int, to devices: [PairedDevice], test: Bool) {
        let words = text(event, test: test)
        let payload = APNsPayload.make(event, title: words.title, body: words.body, badge: badge())
        let collapse = APNsPayload.collapseID(event, turn: turn)
        Task {
            var summary: [String] = []
            for device in devices {
                guard let token = device.pushToken else { continue }
                let result = await APNsClient.shared.send(payload: payload, to: token, production: device.pushProduction ?? true, collapseID: collapse)
                switch result.outcome {
                case .delivered: summary.append("\(device.name): ok")
                case .dropToken:
                    CompanionStore.shared.setPush(device: device.id, token: nil, production: nil)
                    summary.append("\(device.name): \(tr("push.tokenDropped"))")
                case .retryLater: summary.append("\(device.name): \(tr("push.retryLater"))")
                case .configuration: summary.append("\(device.name): \(result.reason ?? "\(result.status)")")
                }
            }
            lastResult = summary.joined(separator: " · ")
            app?.store.audit(tool: test ? "companion_push_test" : "companion_push", args: "\(event.kind.rawValue) · \(devices.count)", result: lastResult ?? "")
        }
    }
}
