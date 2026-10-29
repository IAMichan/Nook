import Foundation

/// What the iPhone companion can do beyond answering what waits: start a session, read a session's conversation, and
/// talk to Nook itself. Every request is already opened, fresh and admitted by `CompanionServer.respond`; what it may
/// touch is narrowed here (a folder the Mac already worked in, a connected agent, never "allow everything").
extension CompanionServer {
    // MARK: Starting a session

    /// The agents that can start here, the folders you worked in recently, and your defaults from the composer.
    func launchOptions(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        let workspace = app.workspace
        let settings = workspace.settings
        let agents = launchableProviders(app).map { provider in
            // The models of the composer's menu ("" is the agent's own default), so the phone picks from the same list.
            let models = app.models(for: provider).prefix(16).map {
                LaunchOptions.Model(id: $0, name: CompanionPolicy.clip(app.modelName($0, for: provider), limit: 80))
            }
            return LaunchOptions.Agent(id: provider.rawValue, name: provider.displayName, canPlan: provider.capabilities.planMode,
                                       models: Array(models), defaultModel: settings.model(for: provider))
        }
        let paths = recentProjects(settings)
        let infos = await withTaskGroup(of: ProjectInfo.self) { group in
            for path in paths { group.addTask { await workspace.inspectProject(path) } }
            var found: [String: ProjectInfo] = [:]
            for await info in group { found[info.path] = info }
            return found
        }
        let canGit = workspace.gitAvailable == true
        let projects = paths.compactMap { path -> LaunchOptions.Project? in
            guard let info = infos[WorkspacePathPolicy.normalize(path)], info.verdict == .ok else { return nil }
            return LaunchOptions.Project(path: info.path, name: info.name,
                                         canWorktree: canGit && info.repoRoot != nil && info.hasCommits)
        }
        let defaultAgent = agents.contains { $0.id == settings.defaultProvider.rawValue } ? settings.defaultProvider.rawValue : agents.first?.id
        let last = WorkspacePathPolicy.normalize(settings.lastProject)
        let options = LaunchOptions(agents: agents, projects: projects,
                                    defaultAgent: defaultAgent,
                                    defaultProject: projects.contains { $0.path == last } ? last : projects.first?.path,
                                    defaultPlan: settings.defaultMode == .plan,
                                    defaultWorktree: settings.defaultIsolation == .worktree)
        return CompanionResponse(id: request.id, ok: true, launch: options)
    }

    /// Starts a session the way the composer would, with your remembered account, model and effort for that agent.
    func launch(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        let workspace = app.workspace
        let settings = workspace.settings
        guard let launch = request.launch, let provider = RunProvider(rawValue: launch.agent),
              launchableProviders(app).contains(provider),
              let words = CompanionPolicy.cleanMessage(launch.task) else {
            return .failure(request.id, .badRequest)
        }
        // Pictures from the phone go to the agent as paths below the words, as from the composer.
        guard let task = CompanionImages.attach(request.images, to: words) else { return .failure(request.id, .badRequest) }
        // Only a folder the Mac already worked in: the phone cannot point an agent at an arbitrary path.
        let project = WorkspacePathPolicy.normalize(launch.project)
        guard recentProjects(settings).contains(where: { WorkspacePathPolicy.normalize($0) == project }) else {
            return .failure(request.id, .notAllowedFromPhone)
        }

        let plan = launch.plan && provider.capabilities.planMode
        var config = NewRunConfig()
        config.title = String((launch.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        config.task = task
        config.provider = provider
        let connected = app.connectedProfiles(for: provider)
        if let saved = settings.profile(for: provider), connected.contains(where: { $0.id == saved }) {
            config.profileID = saved
        } else {
            config.profileID = connected.first?.id ?? app.profiles.preferredProfile(provider.kind).id
        }
        // A model from the phone only when it is one the composer offers this agent; else your default.
        if let model = launch.model, app.models(for: provider).contains(model) {
            config.model = model
        } else {
            config.model = settings.model(for: provider)
        }
        config.effort = settings.effort(for: provider)
        config.mode = plan ? .plan : .agent
        config.permission = phonePermission(provider, preferred: settings.permission(for: provider), plan: plan)
        config.projectPath = project
        config.worktreeRoot = settings.worktreeRoot
        if launch.worktree {
            let info = await workspace.inspectProject(project)
            guard workspace.gitAvailable == true, info.repoRoot != nil, info.hasCommits else { return .failure(request.id, .badRequest) }
            config.isolation = .worktree
            if let base = info.defaultBase, info.branches.contains(base) {
                config.baseBranch = base
            } else {
                config.baseBranch = info.currentBranch ?? info.branches.first ?? ""
            }
            config.branchName = WorktreeNaming.branchName(task: task, id: UUID())
        } else {
            config.isolation = .folder
        }

        do {
            // A folder another session works in is refused, as in the composer; the phone can pick a worktree instead.
            let id = try await workspace.start(config, allowSharedFolder: false)
            audit("start", "\(provider.displayName) · \(workspace.run(id)?.title ?? "")")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: id.uuidString)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    /// Agents with a connected account and an executable on this Mac. ACP agents you added are started on the Mac.
    private func launchableProviders(_ app: AppModel) -> [RunProvider] {
        app.connectedProviders.filter { $0 != .acp && app.workspace.executable($0) != nil }
    }

    private func recentProjects(_ settings: WorkspaceSettings) -> [String] {
        settings.recentProjects.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Your default for this agent, except "allow everything": a session started from a phone always keeps asking.
    /// Plan mode takes the safest policy, as the composer does.
    private func phonePermission(_ provider: RunProvider, preferred: PermissionPolicy, plan: Bool) -> PermissionPolicy {
        let offered = provider.capabilities.policies.filter { $0 != .bypass }
        if plan { return offered.first ?? .acceptEdits }
        return offered.contains(preferred) ? preferred : (offered.contains(.acceptEdits) ? .acceptEdits : (offered.first ?? .acceptEdits))
    }

    // MARK: A session's conversation

    /// A session's conversation: a Workspace session's timeline (read back from disk when it was released or never
    /// opened), or the transcript of an agent outside Nook (`CompanionAgents.timeline`).
    func timeline(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let session = request.session, let entries = await timelineEntries(session, app: app) else {
            return .failure(request.id, .unknownSession)
        }
        return CompanionResponse(id: request.id, ok: true, timeline: entries, timelineSession: session)
    }

    /// The recent conversation of a session as the phone gets it, within one answer; nil for a session that is gone.
    func timelineEntries(_ session: String, app: AppModel) async -> [TimelineEntry]? {
        if CompanionAgents.handles(session) {
            return await CompanionAgents.timeline(app, session: session).map { CompanionPolicy.newestFitting($0) }
        }
        let workspace = app.workspace
        guard let runID = UUID(uuidString: session), workspace.run(runID) != nil else { return nil }
        workspace.loadTimeline(runID)
        return CompanionPolicy.newestFitting(workspace.timeline(runID).suffix(160).compactMap(Self.entry))
    }

    // MARK: What a session changed

    /// Every file a session changed in its folder, the most changed first, with its patch while they fit in one answer.
    /// A session on another machine, or in a folder without Git, has none to show.
    func diff(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let session = request.session, let folder = sessionFolder(session, app: app) else {
            return .failure(request.id, .unknownSession)
        }
        let git: GitService?
        if let runID = UUID(uuidString: session), let run = app.workspace.run(runID) {
            guard run.remote == nil else { return CompanionResponse(id: request.id, ok: true, diff: []) }
            git = app.workspace.sessionGit(for: run)
        } else {
            git = app.workspace.gitService
        }
        guard let git, !folder.isEmpty else { return CompanionResponse(id: request.id, ok: true, diff: []) }
        let files = await Task.detached(priority: .userInitiated) { () -> [DiffFileDigest] in
            guard let status = try? git.status(folder) else { return [] }
            let changed = status.files.sorted { ($0.added ?? 0) + ($0.removed ?? 0) > ($1.added ?? 0) + ($1.removed ?? 0) }
            var total = 0
            return changed.prefix(60).map { file in
                var patch = try? git.diff(folder, file: file)
                var truncated = false
                if let text = patch {
                    let room = min(DiffFileDigest.maxPatch, max(0, DiffFileDigest.maxTotal - total))
                    if text.utf8.count > room {
                        patch = room > 0 ? String(decoding: Data(text.utf8.prefix(room)), as: UTF8.self) : nil
                        truncated = true
                    }
                    total += patch?.utf8.count ?? 0
                }
                return DiffFileDigest(path: file.path, kind: String(describing: file.kind), added: file.added, removed: file.removed,
                                      patch: patch, truncated: truncated)
            }
        }.value
        return CompanionResponse(id: request.id, ok: true, diff: files)
    }

    /// The folder a session works in: a session Nook runs, or an agent in a terminal (its working directory).
    private func sessionFolder(_ session: String, app: AppModel) -> String? {
        if let runID = UUID(uuidString: session), let run = app.workspace.run(runID) { return run.workingDirectory }
        guard CompanionAgents.handles(session) else { return nil }
        let key = String(session.dropFirst(CompanionAgents.terminalPrefix.count))
        return app.hub.sessions.first { $0.id == key }?.cwd
    }

    /// What the phone shows of one event; thinking, approvals (shown as items) and turn results are left out.
    private static func entry(_ event: RunEvent) -> TimelineEntry? {
        let kind: TimelineEntry.Kind
        var text = event.text
        var detail = event.tool
        switch event.kind {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .tool:
            // What the step was about, as a terminal session's step says it ("npm test", not "Bash · npm test"), so the
            // phone reads both alike.
            kind = .tool
            text = AgentToolStep(event: event).summary
        case .fileChange:
            kind = .change
            if text.isEmpty { text = event.detail ?? "" }
            detail = event.tool
        case .error: kind = .error
        case .system: kind = .notice
        case .thinking, .approval, .result: return nil
        }
        let clipped = CompanionPolicy.clip(text)
        // A step can be about nothing in particular (a task list): its tool alone says what it was.
        guard !clipped.isEmpty || kind == .tool else { return nil }
        return TimelineEntry(id: event.id.uuidString, kind: kind, text: clipped, detail: detail.map { CompanionPolicy.clip($0, limit: 120) },
                             date: event.date.timeIntervalSince1970, failed: event.state == .failed)
    }

    // MARK: Managing a session

    /// What the phone may do to a Workspace session, as the Agents list on the Mac offers it: rename it, archive it once
    /// it rests, and snooze it (or wake it).
    static func actions(_ run: WorkspaceRun, now: Date) -> [SessionAction] {
        var actions: [SessionAction] = [.rename]
        if !run.status.isActive { actions.append(.archive) }
        if let until = run.snoozedUntil, until > now {
            actions.append(.unsnooze)
        } else {
            actions += [.snoozeHour, .snoozeEvening, .snoozeTomorrow]
        }
        return actions
    }

    func manage(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let session = request.session, let action = request.item.flatMap(SessionAction.init(rawValue:)) else {
            return .failure(request.id, .badRequest)
        }
        if CompanionAgents.handles(session) {
            guard action == .end else { return .failure(request.id, .notAllowedFromPhone) }
            if let error = CompanionAgents.end(app, session: session) { return .failure(request.id, error) }
            audit("end", session)
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
        }
        let workspace = app.workspace
        guard let runID = UUID(uuidString: session), let run = workspace.run(runID) else { return .failure(request.id, .unknownSession) }
        guard Self.actions(run, now: Date()).contains(action) else { return .failure(request.id, .notAllowedFromPhone) }
        switch action {
        case .rename:
            guard let title = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
            workspace.rename(runID, to: title)
        case .archive: workspace.setArchived(runID, true)
        case .snoozeHour: workspace.snooze(runID, .hour)
        case .snoozeEvening: workspace.snooze(runID, .evening)
        case .snoozeTomorrow: workspace.snooze(runID, .tomorrow)
        case .unsnooze: workspace.unsnooze(runID)
        case .end: return .failure(request.id, .notAllowedFromPhone)
        }
        audit(action.rawValue, run.title)
        return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
    }

    // MARK: Nook's own chats

    func chats(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let list = app.chat.history.prefix(40).map { conversation in
            ChatDigest(id: conversation.id.uuidString, title: CompanionPolicy.excerpt(conversation.title),
                       updated: conversation.updated.timeIntervalSince1970, busy: conversation.busy,
                       waiting: conversation.status == .waiting, preview: conversation.preview)
        }
        return CompanionResponse(id: request.id, ok: true, message: app.settings.brainReady ? nil : "nobrain", conversations: Array(list))
    }

    func chat(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let id = request.conversation.flatMap(UUID.init(uuidString:)), let conversation = app.chat.conversation(id) else {
            return .failure(request.id, .unknownSession)
        }
        // Read on the phone is read: the Mac does not mark it as new anymore.
        if conversation.unread, !conversation.busy { app.chat.setUnread(false, [id]) }
        return CompanionResponse(id: request.id, ok: true, messages: lines(conversation))
    }

    /// A question to Nook, answered by the same brain pipeline as on the Mac. Plans and drafts in the answer still wait
    /// for approval on the Mac. The notch stays as it is.
    func ask(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard app.settings.brainReady else { return .failure(request.id, .failed, message: "nobrain") }
        guard let text = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
        let id: UUID
        if let asked = request.conversation {
            guard let existing = UUID(uuidString: asked), app.chat.conversation(existing) != nil else {
                return .failure(request.id, .unknownSession)
            }
            id = existing
        } else {
            id = app.chat.startInBackground()
        }
        app.ask(text, in: id, reveal: false)
        audit("ask", app.chat.conversation(id)?.title ?? "")
        return CompanionResponse(id: request.id, ok: true, messages: app.chat.conversation(id).map(lines), created: id.uuidString)
    }

    func stopChat(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let id = request.conversation.flatMap(UUID.init(uuidString:)), let conversation = app.chat.conversation(id) else {
            return .failure(request.id, .unknownSession)
        }
        app.stop(conversation: id)
        audit("chat_stop", conversation.title)
        return CompanionResponse(id: request.id, ok: true, messages: app.chat.conversation(id).map(lines))
    }

    private func lines(_ conversation: Conversation) -> [ChatLine] {
        let lines = conversation.messages.suffix(60).map { message in
            ChatLine(id: message.id.uuidString, fromNook: message.role == .nook, text: CompanionPolicy.clip(message.text),
                     date: message.date.timeIntervalSince1970, streaming: message.streaming,
                     status: CompanionPolicy.clip(message.status, limit: 120), failed: message.isError,
                     onMac: !message.actions.isEmpty || !message.mails.isEmpty || !message.charts.isEmpty)
        }
        return CompanionPolicy.newestFitting(Array(lines))
    }
}
