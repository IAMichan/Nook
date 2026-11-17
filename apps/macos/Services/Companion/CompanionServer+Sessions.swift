import Foundation

/// The Agents tab on the phone as on the Mac (`CompanionFeature.agentsTab`, `CompanionSessions.swift`): the row and
/// header menus, the list's shelves, "Always allow", several questions at once, the composer's choices and the messages
/// in line. Everything goes through what the Mac's own list, header and composer call (`InboxStore`,
/// `FinishedSessions`, `SessionVisits`, `WorkspaceManager`), after your tap on the phone; what does not apply right now
/// is not listed, and refused when a phone asks for it anyway.
extension CompanionServer {
    // MARK: What the phone may do

    /// The Agents tab's actions that apply to `run` now, as the Mac's row menu and header offer them.
    static func tabActions(_ run: WorkspaceRun, workspace: WorkspaceManager) -> [SessionAction] {
        let id = run.id
        let busy = run.status.isActive
        var actions: [SessionAction] = []
        actions.append(InboxStore.shared.state.pinned.contains(listID(run)) ? .unpin : .pin)
        // As in the header: settling waits until the agent stopped.
        if !busy { actions.append(settled(run) ? .reopen : .settle) }
        if run.status == .failed || run.status == .stopped { actions.append(.retry) }
        if workspace.canTransfer(id) { actions.append(.fork) }
        if workspace.canRestartAgent(id) { actions.append(.restartAgent) }
        actions += [.markUnread, .regenerateTitle]
        if !busy {
            actions.append(.delete)
            // The session's own worktree can go with it when no other session uses it, and only where "remove it when
            // its last session is deleted" is off (Delete then does it by itself). Git keeps a worktree with changes.
            if let worktree = workspace.orphanedWorktree(id), !workspace.settings.worktreeCleanupRules(for: worktree.repo).onDeletedSession {
                actions.append(.deleteWithWorktree)
            }
        }
        if let controls = controls(run, workspace: workspace) {
            if (controls.efforts?.count ?? 0) > 1 { actions.append(.setEffort) }
            if controls.mode != nil { actions.append(.setMode) }
            if (controls.models?.count ?? 0) > 1 { actions.append(.setModel) }
        }
        if let queue = workspace.queued[id]?.messages, !queue.isEmpty {
            // The queue tray's own actions: edit while no edit runs on the Mac, move with more than one, send now
            // where a message can go out at once.
            actions.append(.unqueue)
            if workspace.queued[id]?.editSession == nil { actions.append(.editQueued) }
            if queue.count > 1 { actions.append(.moveQueued) }
            if workspace.canSendQueuedNow(id) { actions.append(.sendQueuedNow) }
        }
        return actions
    }

    /// The session's id in the Agents list (`AgentListItem.id`): what pins and read marks are kept under.
    static func listID(_ run: WorkspaceRun) -> String { "run:" + run.id.uuidString }

    /// Settled as the list counts it: marked finished and not working.
    static func settled(_ run: WorkspaceRun) -> Bool {
        !run.status.isActive && FinishedSessions.shared.contains(FinishedSessions.key(run: run))
    }

    /// The composer's choices for the next turns: effort, mode and model, as the Mac's model picker offers them for the
    /// session's own agent and account. Nil when there is nothing to change.
    static func controls(_ run: WorkspaceRun, workspace: WorkspaceManager) -> SessionControls? {
        var controls = SessionControls()
        let levels = workspace.effortLevels(for: run.provider, profileID: run.profileID, model: run.model)
        if !levels.isEmpty {
            controls.effort = run.effort ?? ""
            controls.efforts = [LaunchOptions.Model(id: "", name: workspace.effortTitle(nil, for: run.provider, profileID: run.profileID))]
                + levels.map { LaunchOptions.Model(id: $0, name: workspace.effortTitle($0, for: run.provider, profileID: run.profileID)) }
        }
        if run.provider.capabilities.planMode { controls.mode = run.mode.rawValue }
        let app = AppModel.shared
        let models = app.models(for: run.provider, profileID: run.profileID).prefix(16)
        if models.count > 1 {
            controls.model = run.model
            controls.models = models.map {
                LaunchOptions.Model(id: $0, name: CompanionPolicy.clip(app.modelName($0, for: run.provider, profileID: run.profileID), limit: 80))
            }
        }
        return controls == SessionControls() ? nil : controls
    }

    /// What the Agents tab adds to a session's digest: where it sits in the list, its folder, its composer's choices
    /// and the messages in line.
    static func addTabFields(_ digest: inout SessionDigest, run: WorkspaceRun, workspace: WorkspaceManager, now: Date) {
        digest.pinned = InboxStore.shared.state.pinned.contains(listID(run)) ? true : nil
        digest.settled = settled(run) ? true : nil
        if let until = run.snoozedUntil, until > now { digest.snoozedUntil = until.timeIntervalSince1970 }
        digest.path = run.workingDirectory
        digest.controls = controls(run, workspace: workspace)
        let queue = workspace.queued[run.id]?.messages ?? []
        digest.queued = queue.isEmpty ? nil : queue.prefix(10).map { QueuedDigest.clipped(id: $0.id.uuidString, text: $0.text) }
        digest.nextPrompt = workspace.nextPrompt(run.id).map { String($0.prefix(SessionDigest.nextPromptLimit)) }
        digest.lineage = lineage(run.id, workspace: workspace)
        digest.suggestion = suggestion("agent:" + run.id.uuidString)
    }

    /// The Lineage control's rows for the phone, in its order: parent and forks, working tasks, ended tasks, side chats.
    static func lineage(_ id: UUID, workspace: WorkspaceManager) -> [LineageDigest]? {
        let groups = workspace.lineageGroups(of: id)
        guard !groups.isEmpty else { return nil }
        func digest(_ row: LineageGroups.Row, previous: Bool = false) -> LineageDigest {
            LineageDigest(id: row.node.id.uuidString, title: CompanionPolicy.clip(row.node.title, limit: 120),
                          role: role(row.role), status: status(row.node.status), previous: previous ? true : nil)
        }
        let rows = groups.related.map { digest($0) } + groups.active.map { digest($0) }
            + groups.previous.map { digest($0, previous: true) } + groups.sideChats.map { digest($0) }
        return Array(rows.prefix(LineageDigest.limit))
    }

    private static func role(_ role: LineageGroups.Row.Role) -> LineageDigest.Role {
        switch role {
        case .parent(.delegated): return .parentAgent
        case .parent: return .parentThread
        case .child(.fork): return .fork
        case .child(.comparison): return .comparison
        case .child(.delegated): return .subThread
        case .child(.side): return .sideChat
        }
    }

    private static func status(_ status: LineageStatus) -> LineageDigest.Status {
        switch status {
        case .working: return .working
        case .approval: return .approval
        case .question: return .question
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// Every question of an ask as the phone shows it, with its options, previews and multi-select.
    static func questions(_ pending: PendingQuestion) -> [SessionQuestion] {
        pending.questions.map { question in
            SessionQuestion(id: question.id, header: CompanionPolicy.excerpt(question.header),
                            question: CompanionPolicy.excerpt(question.question),
                            options: question.options.map(\.label),
                            previews: SessionDigest.Item.previews(question.options.map { QuestionPreview.display($0.preview) }),
                            multiSelect: question.multiSelect, allowsOther: question.allowsOther)
        }
    }

    // MARK: Doing it

    /// One of the Agents tab's actions on a session Nook runs (`SessionAction.agentsTab`).
    func manageTab(_ action: SessionAction, run: WorkspaceRun, request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let workspace = app.workspace
        guard Self.tabActions(run, workspace: workspace).contains(action) else { return .failure(request.id, .notAllowedFromPhone) }
        let id = run.id
        let listID = Self.listID(run)
        let key = FinishedSessions.key(run: run)
        let inbox = InboxStore.shared
        let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var created: String?
        switch action {
        case .pin:
            // As the list pins: a settled session comes back first.
            if FinishedSessions.shared.contains(key) { FinishedSessions.shared.reopenByUser(key) }
            inbox.pin(listID)
        case .unpin:
            inbox.unpin(listID)
        case .settle:
            inbox.unpin(listID, record: false)
            FinishedSessions.shared.mark(key)
            workspace.settled(id)
        case .reopen:
            FinishedSessions.shared.reopenByUser(key)
        case .markUnread:
            SessionVisits.shared.markUnread(listID)
        case .fork:
            guard let forked = workspace.fork(id) else { return .failure(request.id, .busy) }
            created = forked.uuidString
        case .retry:
            workspace.retry(id)
        case .restartAgent:
            guard workspace.restartAgent(id) else { return .failure(request.id, .busy) }
        case .regenerateTitle:
            workspace.regenerateTitle(id)
        case .delete:
            workspace.delete(id)
        case .deleteWithWorktree:
            workspace.deleteWithWorktree(id)
        case .setEffort:
            guard Self.controls(run, workspace: workspace)?.efforts?.contains(where: { $0.id == text }) == true else {
                return .failure(request.id, .badRequest)
            }
            workspace.setEffort(id, text.isEmpty ? nil : text)
        case .setMode:
            guard let mode = ExecutionMode(rawValue: text) else { return .failure(request.id, .badRequest) }
            workspace.configure(id, mode: mode)
        case .setModel:
            guard Self.controls(run, workspace: workspace)?.models?.contains(where: { $0.id == text }) == true else {
                return .failure(request.id, .badRequest)
            }
            workspace.applySelection(id, provider: run.provider, profileID: run.profileID, model: text)
        case .unqueue:
            guard let message = UUID(uuidString: text), workspace.queued[id]?.messages.contains(where: { $0.id == message }) == true else {
                return .failure(request.id, .unknownItem)
            }
            workspace.removeQueued(id, message: message)
        case .editQueued, .moveQueued, .sendQueuedNow:
            guard let message = request.items?.first.flatMap(UUID.init(uuidString:)),
                  let queue = workspace.queued[id]?.messages, queue.contains(where: { $0.id == message }) else {
                return .failure(request.id, .unknownItem)
            }
            switch action {
            case .editQueued:
                // The Mac's edit in one step: taken out of the line's text, written back with your words.
                guard !text.isEmpty,
                      workspace.beginEditQueued(id, message: message, currentDraft: "") != nil else {
                    return .failure(request.id, .badRequest)
                }
                workspace.endEditQueued(id, save: true, text: text)
            case .moveQueued:
                guard let index = Int(text), queue.indices.contains(index) else { return .failure(request.id, .badRequest) }
                workspace.moveQueued(id, message: message, toIndex: index)
            default:
                workspace.sendQueuedNow(id, message: message)
            }
        default:
            return .failure(request.id, .notAllowedFromPhone)
        }
        audit(action.rawValue, run.title)
        var response = CompanionResponse(id: request.id, ok: true, sessions: digests(app))
        response.created = created
        return response
    }

    /// An answer to every question of an ask at once (`CompanionRequest.answers`), checked against the ask as the Mac's
    /// question card would take it. Nil when the request has no such answers (a single answer in `text` instead).
    func answerAll(_ request: CompanionRequest, runID: UUID, pending: PendingQuestion, app: AppModel) -> CompanionResponse? {
        guard request.answers != nil else { return nil }
        let workspace = app.workspace
        // Checked against the full labels, not the cut ones the phone shows.
        let questions = Self.questions(pending).map { question -> SessionQuestion in
            var full = question
            full.options = pending.questions.first { $0.id == question.id }?.options.map(\.label) ?? question.options
            return full
        }
        guard let answers = SessionAnswers.validated(request.answers, for: questions) else { return .failure(request.id, .badRequest) }
        let command = SessionCommand.phone(request.id)
        _ = workspace.claimCommand(command, provisional: .answered)
        workspace.answer(runID, questionID: pending.id, answers: answers)
        workspace.recordCommand(command, .answered)
        audit("answer", workspace.run(runID)?.title ?? "")
        return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
    }

    // MARK: Starting a session

    /// The reasoning levels and access levels a phone may start `provider` with, as the composer offers them.
    func launchChoices(_ provider: RunProvider, app: AppModel) -> (efforts: [LaunchOptions.Model], defaultEffort: String?,
                                                                   permissions: [LaunchOptions.Model], defaultPermission: String?) {
        let workspace = app.workspace
        let settings = workspace.settings
        let model = settings.model(for: provider)
        let levels = workspace.effortLevels(for: provider, model: model)
        let efforts = levels.isEmpty ? [] : [LaunchOptions.Model(id: "", name: workspace.effortTitle(nil, for: provider))]
            + levels.map { LaunchOptions.Model(id: $0, name: workspace.effortTitle($0, for: provider)) }
        let offered = provider.capabilities.policies.filter(\.isUnattendedSafe)
        let preferred = phonePermission(provider, preferred: settings.permission(for: provider), plan: false)
        return (efforts, levels.isEmpty ? nil : (settings.effort(for: provider) ?? ""),
                offered.map { LaunchOptions.Model(id: $0.rawValue, name: $0.label) }, preferred.rawValue)
    }

    /// The access a phone asked for, when it is one a phone may start with; else the capped default.
    func phonePermission(_ provider: RunProvider, asked: String?, preferred: PermissionPolicy, plan: Bool) -> PermissionPolicy {
        if !plan, let asked, let policy = PermissionPolicy(rawValue: asked), policy.isUnattendedSafe,
           provider.capabilities.policies.contains(policy) {
            return policy
        }
        return phonePermission(provider, preferred: preferred, plan: plan)
    }
}
