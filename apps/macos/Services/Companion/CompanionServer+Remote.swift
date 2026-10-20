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
        let agents = launchableProviders(app).map {
            LaunchOptions.Agent(id: $0.rawValue, name: $0.displayName, canPlan: $0.capabilities.planMode)
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
              let task = CompanionPolicy.cleanMessage(launch.task) else {
            return .failure(request.id, .badRequest)
        }
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
        config.model = settings.model(for: provider)
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
            return CompanionResponse(id: request.id, ok: true, sessions: digests(workspace), created: id.uuidString)
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

    func timeline(_ request: CompanionRequest, workspace: WorkspaceManager) -> CompanionResponse {
        guard let runID = request.session.flatMap(UUID.init(uuidString:)), workspace.run(runID) != nil else {
            return .failure(request.id, .unknownSession)
        }
        let entries = workspace.timeline(runID).suffix(120).compactMap(Self.entry)
        return CompanionResponse(id: request.id, ok: true, timeline: CompanionPolicy.newestFitting(entries))
    }

    /// What the phone shows of one event; thinking, approvals (shown as items) and turn results are left out.
    private static func entry(_ event: RunEvent) -> TimelineEntry? {
        let kind: TimelineEntry.Kind
        var text = event.text
        var detail = event.tool
        switch event.kind {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .tool: kind = .tool
        case .fileChange:
            kind = .change
            if text.isEmpty { text = event.detail ?? "" }
            detail = event.tool
        case .error: kind = .error
        case .system: kind = .notice
        case .thinking, .approval, .result: return nil
        }
        let clipped = CompanionPolicy.clip(text)
        guard !clipped.isEmpty else { return nil }
        return TimelineEntry(id: event.id.uuidString, kind: kind, text: clipped, detail: detail.map { CompanionPolicy.clip($0, limit: 120) },
                             date: event.date.timeIntervalSince1970, failed: event.state == .failed)
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
