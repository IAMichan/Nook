import Foundation

/// What the iPhone sees besides Workspace sessions: agents running in a terminal on the Mac (through their hooks) and
/// requests through Nook's workspace bridge. Their permission requests reach the phone as pushes and in its list, where
/// they can be denied, and the low-risk ones allowed (`CompanionPolicy`), like a Workspace session's. The phone reads
/// their conversation from the agent's own transcript, as the Mac does, and answers the ones the Mac can answer
/// (`AppModel.canReply`) the same way; it cannot stop them.
@MainActor
enum CompanionAgents {
    static let terminalPrefix = "terminal:"
    static let bridgePrefix = "bridge:"

    /// The phone's session id for a request that is not a Workspace session's (those use the run's id); nil for those.
    static func sessionID(_ approval: AgentApproval, hub: AgentHub) -> String? {
        switch approval.origin {
        case .hook(let requestID):
            guard let key = hub.approvals.first(where: { $0.id == requestID })?.sessionKey else { return nil }
            return terminalPrefix + key
        case .bridge(let requestID):
            return bridgePrefix + requestID
        case .run:
            return nil
        }
    }

    static func handles(_ session: String) -> Bool {
        session.hasPrefix(terminalPrefix) || session.hasPrefix(bridgePrefix)
    }

    /// Allowed from the phone only when it is low risk; a dangerous command never.
    static func canAllow(_ approval: AgentApproval) -> Bool {
        guard !approval.danger else { return false }
        return CompanionPolicy.canAllow(tool: approval.tool, commandIsSafe: CommandRisk.assess(approval.command).level == .safe)
    }

    /// The phone allows or denies a request; nil when it was decided, else why not.
    static func decide(_ app: AppModel, session: String, item: String, allow: Bool) -> CompanionError? {
        guard let approval = app.approvals.pending.first(where: { $0.id == item && sessionID($0, hub: app.hub) == session }) else {
            return .unknownItem
        }
        if allow, !canAllow(approval) { return .notAllowedFromPhone }
        app.approvals.decide(approval, allow ? .allow : .deny)
        return nil
    }

    /// Terminal sessions (newest first) and bridge requests, each with what waits on you.
    static func digests(_ app: AppModel) -> [SessionDigest] {
        let hub = app.hub
        var waiting: [String: [AgentApproval]] = [:]
        for approval in app.approvals.pending {
            guard let id = sessionID(approval, hub: hub) else { continue }
            waiting[id, default: []].append(approval)
        }
        var digests: [SessionDigest] = []
        let sessions = hub.sessions.filter { !$0.isDetected }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }.prefix(15)
        for session in sessions {
            let id = terminalPrefix + session.id
            let items = waiting.removeValue(forKey: id) ?? []
            let folder = session.cwd.isEmpty ? session.project : URL(fileURLWithPath: session.cwd).lastPathComponent
            digests.append(SessionDigest(
                id: id, title: CompanionPolicy.excerpt(session.project), agent: session.name,
                attention: attention(session.status, approvals: !items.isEmpty), folder: folder, branch: nil,
                updated: (session.updated ?? session.started ?? Date()).timeIntervalSince1970,
                excerpt: CompanionPolicy.excerpt(session.summary), items: items.map(item), canSend: app.canReply(to: session),
                actions: app.canEnd(session) ? [SessionAction.end.rawValue] : []
            ))
        }
        // Bridge requests, and any request whose terminal session is not in the list, newest first (a dictionary has no order).
        let rest = waiting.sorted { ($0.value.last?.created ?? .distantPast) > ($1.value.last?.created ?? .distantPast) }
        for (id, approvals) in rest {
            guard let first = approvals.first else { continue }
            digests.append(SessionDigest(
                id: id, title: CompanionPolicy.excerpt(first.project), agent: first.agentName, attention: "approval",
                folder: first.project, branch: nil, updated: first.created.timeIntervalSince1970, excerpt: "",
                items: approvals.map(item), canSend: false
            ))
        }
        return digests
    }

    /// The conversation of a terminal session from its transcript, as the Mac shows it (`AgentTranscript`): your
    /// messages, the agent's answers, and each step it took; its reasoning is left out, as for a Workspace session.
    /// Nil for a session that is gone or has no transcript.
    static func timeline(_ app: AppModel, session: String) async -> [TimelineEntry]? {
        guard session.hasPrefix(terminalPrefix) else { return nil }
        let key = String(session.dropFirst(terminalPrefix.count))
        guard let agent = app.hub.sessions.first(where: { $0.id == key }), !agent.transcriptPath.isEmpty else { return nil }
        let path = agent.transcriptPath
        let messages = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
        return entries(messages)
    }

    static func entries(_ messages: [AgentChatMessage]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        for message in messages {
            let date = (message.date ?? Date()).timeIntervalSince1970
            switch message.kind {
            case .user, .assistant:
                let text = CompanionPolicy.clip(message.text)
                guard !text.isEmpty else { continue }
                entries.append(TimelineEntry(id: message.id, kind: message.kind == .user ? .user : .assistant, text: text,
                                             detail: nil, date: date, failed: false))
            case .tools:
                for step in message.steps {
                    entries.append(TimelineEntry(id: message.id + ":" + step.id, kind: .tool,
                                                 text: CompanionPolicy.clip(step.summary, limit: 240),
                                                 detail: CompanionPolicy.clip(step.name, limit: 120), date: date,
                                                 failed: step.state == .failed))
                }
            case .thinking:
                continue
            }
        }
        return Array(entries.suffix(200))
    }

    /// Ends a terminal session's process, as the Mac's End session does; nil when it ended.
    static func end(_ app: AppModel, session: String) -> CompanionError? {
        guard session.hasPrefix(terminalPrefix) else { return .notAllowedFromPhone }
        let key = String(session.dropFirst(terminalPrefix.count))
        guard let agent = app.hub.sessions.first(where: { $0.id == key }) else { return .unknownSession }
        guard app.canEnd(agent) else { return .notAllowedFromPhone }
        do {
            try app.endSession(agent)
            return nil
        } catch {
            return .failed
        }
    }

    /// Sends a message to a terminal session the way the Mac answers it (`AppModel.reply`); nil when it went out.
    static func send(_ app: AppModel, session: String, text: String) async -> CompanionError? {
        guard session.hasPrefix(terminalPrefix) else { return .notAllowedFromPhone }
        let key = String(session.dropFirst(terminalPrefix.count))
        guard let agent = app.hub.sessions.first(where: { $0.id == key }) else { return .unknownSession }
        guard app.canReply(to: agent) else { return .notAllowedFromPhone }
        do {
            try await app.reply(to: agent, message: text)
            return nil
        } catch {
            return .notAllowedFromPhone
        }
    }

    private static func item(_ approval: AgentApproval) -> SessionDigest.Item {
        SessionDigest.Item(id: approval.id, kind: .approval, title: CompanionPolicy.excerpt(approval.command),
                           detail: CompanionPolicy.excerpt(approval.tool), canAllow: canAllow(approval), options: [])
    }

    /// `AgentAttention`'s words, which the phone shows.
    private static func attention(_ status: AgentStatus, approvals: Bool) -> String {
        if approvals { return "approval" }
        switch status {
        case .running: return "working"
        case .waiting: return "input"
        case .failed: return "failed"
        case .done: return "finished"
        case .detected: return "idle"
        }
    }
}
