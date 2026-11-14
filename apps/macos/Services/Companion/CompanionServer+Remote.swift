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
                                       models: Array(models), defaultModel: settings.model(for: provider),
                                       canMainThread: MainThread.offered(provider: provider, access: settings.bridgeAccess))
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
        let last = WorkspacePathPolicy.normalize(settings.lastProject)
        let defaultProject = projects.contains { $0.path == last } ? last : projects.first?.path
        // The phone's form opens on one project, with what you last chose there.
        let defaults = settings.composerDefaults(for: defaultProject)
        let defaultAgent = [defaults.provider, settings.defaultProvider].first { provider in agents.contains { $0.id == provider.rawValue } }?.rawValue
            ?? agents.first?.id
        let options = LaunchOptions(agents: agents, projects: projects,
                                    defaultAgent: defaultAgent,
                                    defaultProject: defaultProject,
                                    defaultPlan: defaults.mode == .plan,
                                    defaultWorktree: defaults.isolation == .worktree)
        return CompanionResponse(id: request.id, ok: true, launch: options)
    }

    /// Starts a session the way the composer would, with your remembered account, model and effort for that agent in that folder.
    func launch(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        let workspace = app.workspace
        let settings = workspace.settings
        // Started before (from the phone's outbox, after a restart of Nook): the same session, not a second one.
        let command = SessionCommand.phone(request.id)
        if let earlier = workspace.commandReceipt(command), let created = earlier.created {
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: created)
        }
        guard let launch = request.launch, let provider = RunProvider(rawValue: launch.agent),
              launchableProviders(app).contains(provider),
              let words = CompanionPolicy.cleanMessage(launch.task) else {
            return .failure(request.id, .badRequest)
        }
        // Pictures from the phone go to the agent as paths below the words, as from the composer.
        guard let pictured = CompanionImages.attach(request.images, to: words),
              let task = CompanionFiles.attach(request.attachments, images: request.images, to: pictured) else {
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
        let defaults = settings.composerDefaults(for: project)
        config.profileID = defaults.profile(for: provider, connected: app.connectedProfiles(for: provider).map(\.id))
            ?? app.profiles.preferredProfile(provider.kind).id
        // A model from the phone only when it is one the composer offers this agent; else your default.
        if let model = launch.model, app.models(for: provider).contains(model) {
            config.model = model
        } else {
            config.model = defaults.model(for: provider)
        }
        config.effort = defaults.effort(for: provider)
        if launch.mainThread == true, MainThread.offered(provider: provider, access: settings.bridgeAccess) { config.mainThread = true }
        config.mode = plan ? .plan : .agent
        config.permission = phonePermission(provider, preferred: defaults.permission(for: provider), plan: plan)
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
            workspace.recordCommand(command, .started, created: id.uuidString)
            audit("start", "\(provider.displayName) · \(workspace.run(id)?.title ?? "")")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: id.uuidString)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    /// Agents with a connected account and an executable on this Mac. ACP agents you added are started on the Mac.
    func launchableProviders(_ app: AppModel) -> [RunProvider] {
        app.connectedProviders.filter { $0 != .acp && app.workspace.executable($0) != nil }
    }

    private func recentProjects(_ settings: WorkspaceSettings) -> [String] {
        var seen = Set<String>()
        return (settings.favoriteProjects + settings.recentProjects).filter { path in
            let normalized = WorkspacePathPolicy.normalize(path)
            return !normalized.isEmpty && seen.insert(normalized).inserted && FileManager.default.fileExists(atPath: normalized)
        }
    }

    /// Your default for this agent, at most "allow edits": a session started from a phone always keeps asking. "Auto"
    /// steps down to "allow edits" too (`PermissionPolicy.isUnattendedSafe`): its reviewer would approve commands nobody
    /// at the Mac sees. Plan mode takes the safest policy, as the composer does.
    func phonePermission(_ provider: RunProvider, preferred: PermissionPolicy, plan: Bool) -> PermissionPolicy {
        let offered = provider.capabilities.policies.filter(\.isUnattendedSafe)
        if plan { return offered.first ?? .acceptEdits }
        return offered.contains(preferred) ? preferred : (offered.contains(.acceptEdits) ? .acceptEdits : (offered.first ?? .acceptEdits))
    }

    // MARK: A session's conversation

    /// A session's conversation: a Workspace session's timeline (read back from disk when it was released or never
    /// opened), or the transcript of an agent outside Nook (`CompanionAgents.timeline`).
    func timeline(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        // `item`: the oldest entry the phone has, and it wants the page before it.
        guard let session = request.session, let entries = await timelineEntries(session, before: request.item, app: app) else {
            return .failure(request.id, .unknownSession)
        }
        var response = CompanionResponse(id: request.id, ok: true, timeline: entries, timelineSession: session)
        response.timelineBefore = request.item
        return response
    }

    /// The recent conversation of a session as the phone gets it, within one answer; nil for a session that is gone.
    /// `before`: the page older than that entry instead, empty when there is none.
    func timelineEntries(_ session: String, before: String? = nil, app: AppModel) async -> [TimelineEntry]? {
        if CompanionAgents.handles(session) {
            return await CompanionAgents.timeline(app, session: session, before: before).map { CompanionPolicy.newestFitting($0) }
        }
        let workspace = app.workspace
        guard let runID = UUID(uuidString: session), workspace.run(runID) != nil else { return nil }
        // Off the main thread. The phone polls, so the next look finds it in memory; idle, it is released again.
        var events = await workspace.timelineForSearch(runID)[...]
        workspace.prefetchTimeline(runID)
        if let before {
            guard let index = events.firstIndex(where: { $0.id.uuidString == before }) else { return [] }
            events = events[..<index]
        }
        // Walk back until a page holds 160 entries the phone draws (thinking and results are left out).
        var page: [TimelineEntry] = []
        for event in events.reversed() {
            if let entry = Self.entry(event) { page.append(entry) }
            if page.count == 160 { break }
        }
        return CompanionPolicy.newestFitting(page.reversed())
    }

    /// One entry of a session's conversation in full, for an entry the timeline clipped (`CompanionOp.entry`).
    func entry(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let session = request.session, let id = request.item else { return .failure(request.id, .badRequest) }
        let text: String?
        if CompanionAgents.handles(session) {
            text = await CompanionAgents.fullText(app, session: session, entry: id)
        } else if let runID = UUID(uuidString: session), app.workspace.run(runID) != nil {
            text = await app.workspace.timelineForSearch(runID).first { $0.id.uuidString == id }?.text
        } else {
            return .failure(request.id, .unknownSession)
        }
        guard let text else { return .failure(request.id, .unknownItem) }
        var response = CompanionResponse(id: request.id, ok: true)
        response.entryText = CompanionPolicy.clip(text, limit: TimelineEntry.fullLimit)
        return response
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
    /// The terminals of a session's folder on this Mac, with their last lines.
    func terminals(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let session = request.session, let folder = sessionFolder(session, app: app), !folder.isEmpty else {
            return .failure(request.id, .unknownSession)
        }
        if let id = UUID(uuidString: session), app.workspace.run(id)?.isRemote == true { return .failure(request.id, .notAllowedFromPhone) }
        let path = WorkspacePathPolicy.normalize(folder)
        let list = TerminalStore.shared.sessions.filter { WorkspacePathPolicy.normalize($0.directory) == path }.map {
            TerminalDigest(id: $0.shortID, title: $0.title, running: $0.running, output: $0.output(lines: CompanionWorkspace.maxTerminalLines))
        }
        var response = CompanionResponse(id: request.id, ok: true)
        response.terminals = CompanionWorkspace.fitting(list)
        return response
    }

    /// One folder or file of a session's folder on this Mac (`CompanionWorkspace` decides what may go).
    func files(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let session = request.session, let folder = sessionFolder(session, app: app), !folder.isEmpty else {
            return .failure(request.id, .unknownSession)
        }
        if let id = UUID(uuidString: session), app.workspace.run(id)?.isRemote == true { return .failure(request.id, .notAllowedFromPhone) }
        let relative = request.item ?? ""
        let digest = await Task.detached(priority: .userInitiated) { () -> FolderDigest? in
            guard let path = CompanionWorkspace.path(relative, in: folder) else { return nil }
            let manager = FileManager.default
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isFolder) else { return nil }
            if isFolder.boolValue {
                let names = (try? manager.contentsOfDirectory(atPath: path)) ?? []
                // A folder of a million files must not cost a million lookups.
                let entries = names.sorted().prefix(CompanionWorkspace.maxEntries * 2).map { name -> FolderDigest.Entry in
                    var folder: ObjCBool = false
                    manager.fileExists(atPath: path + "/" + name, isDirectory: &folder)
                    let size = (try? manager.attributesOfItem(atPath: path + "/" + name))?[.size] as? Int
                    return FolderDigest.Entry(name: name, isFolder: folder.boolValue, size: folder.boolValue ? nil : size)
                }
                return CompanionWorkspace.listing(path: relative, entries: entries)
            }
            // Opening a named pipe or a device would wait forever.
            guard (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular,
                  let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: CompanionWorkspace.maxTextBytes + 1)) ?? Data()
            return CompanionWorkspace.digest(path: relative, data: data)
        }.value
        guard let digest else { return .failure(request.id, .notAllowedFromPhone) }
        var response = CompanionResponse(id: request.id, ok: true)
        response.folder = digest
        return response
    }

    /// A piece of one file of a session's folder, for the phone to preview it (`CompanionOp.fileData`). The same rules
    /// as `files` (inside the folder, no secrets, a regular file), and no file over `FileChunk.maxFileBytes`.
    func fileData(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let session = request.session, let folder = sessionFolder(session, app: app), !folder.isEmpty else {
            return .failure(request.id, .unknownSession)
        }
        if let id = UUID(uuidString: session), app.workspace.run(id)?.isRemote == true { return .failure(request.id, .notAllowedFromPhone) }
        let relative = request.item ?? ""
        let offset = Int(request.text ?? "0") ?? -1
        let read = await Task.detached(priority: .userInitiated) { () -> (FileChunk?, CompanionError?) in
            guard !relative.isEmpty, let path = CompanionWorkspace.path(relative, in: folder) else { return (nil, .notAllowedFromPhone) }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            // Opening a named pipe or a device would wait forever.
            guard attributes?[.type] as? FileAttributeType == .typeRegular, let total = attributes?[.size] as? Int else {
                return (nil, .notAllowedFromPhone)
            }
            guard let range = FileChunk.range(offset: offset, total: total) else { return (nil, .badRequest) }
            guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, .notAllowedFromPhone) }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                let data = try handle.read(upToCount: range.count) ?? Data()
                return (FileChunk(path: relative, offset: range.lowerBound, total: total, data: data.base64EncodedString()), nil)
            } catch {
                return (nil, .failed)
            }
        }.value
        guard let chunk = read.0 else {
            let error = read.1 ?? .failed
            // A file over the limit says so, so the phone can tell it from one it may not see.
            return .failure(request.id, error, message: error == .badRequest ? "tooLarge" : nil)
        }
        if chunk.offset == 0 { audit("file_preview", relative) }
        var response = CompanionResponse(id: request.id, ok: true)
        response.fileChunk = chunk
        return response
    }

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
        case .system where CompactionProgress.isCompaction(event):
            // A compaction reads as a terminal session's does on the phone; while it runs, or when it stopped, in words.
            kind = .notice
            switch event.state {
            case .running?: text = tr("ws.activity.compacting"); detail = nil
            case .failed?: text = tr("ws.event.compactionStopped"); detail = nil
            default: detail = TimelineEntry.compacted
            }
        case .system: kind = .notice
        case .page:
            // The phone draws no pages: it says which page the agent showed (the page itself stays on the Mac).
            kind = .notice
            detail = nil
        case .thinking, .approval, .result: return nil
        }
        let clipped = CompanionPolicy.clip(text)
        // A step can be about nothing in particular (a task list): its tool alone says what it was.
        guard !clipped.isEmpty || kind == .tool else { return nil }
        // A step opens to what it gave back on the phone, as on the Mac: the end of it, which says how it went.
        let output = kind == .tool || kind == .change ? TimelineEntry.outputTail(event.output) : nil
        return TimelineEntry(id: event.id.uuidString, kind: kind, text: clipped, detail: detail.map { CompanionPolicy.clip($0, limit: 120) },
                             date: event.date.timeIntervalSince1970, failed: event.state == .failed, output: output,
                             clipped: kind != .tool && CompanionPolicy.wasClipped(clipped) ? true : nil)
    }

    // MARK: Managing a session

    /// What the phone may do to a Workspace session, as the Agents list on the Mac offers it: rename it, archive it once
    /// it rests, snooze it (or wake it), and turn its main thread on or off as the composer's switch does.
    static func actions(_ run: WorkspaceRun, now: Date, access: BridgeAccess) -> [SessionAction] {
        var actions: [SessionAction] = [.rename]
        if MainThread.offered(provider: run.provider, access: access) {
            actions.append(run.mainThread == true ? .mainThreadOff : .mainThreadOn)
        }
        if !run.status.isActive { actions.append(.archive) }
        if let until = run.snoozedUntil, until > now {
            actions.append(.unsnooze)
        } else {
            actions += [.snoozeHour, .snoozeEvening, .snoozeTomorrow, .snoozeUntil]
            // "Until the usage limit resets" only while a limit stopped it and Nook knows when it resets.
            if SnoozePolicy.limitResetEnd(limitedAt: run.limitedAt, resetAt: run.limitResetAt, now: now) != nil {
                actions.append(.snoozeLimitReset)
            }
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
        guard Self.actions(run, now: Date(), access: workspace.settings.bridgeAccess).contains(action) else { return .failure(request.id, .notAllowedFromPhone) }
        switch action {
        case .rename:
            guard let title = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
            workspace.rename(runID, to: title)
        case .archive: workspace.setArchived(runID, true)
        case .snoozeHour: workspace.snooze(runID, .hour)
        case .snoozeEvening: workspace.snooze(runID, .evening)
        case .snoozeTomorrow: workspace.snooze(runID, .tomorrow)
        case .unsnooze: workspace.unsnooze(runID)
        case .snoozeUntil:
            guard let end = CompanionSnooze.end(request.text) else { return .failure(request.id, .badRequest) }
            workspace.snooze(runID, until: end)
        case .snoozeLimitReset:
            guard let end = SnoozePolicy.limitResetEnd(limitedAt: run.limitedAt, resetAt: run.limitResetAt) else {
                return .failure(request.id, .notAllowedFromPhone)
            }
            workspace.snooze(runID, until: end)
        case .mainThreadOn: workspace.setMainThread(runID, true)
        case .mainThreadOff: workspace.setMainThread(runID, false)
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

    /// The Nook conversation the phone has open (`CompanionOp.watchConversation`): read as `chat` reads it, and from now
    /// on its messages follow over the live connection (`pushConversations`). Nil `conversation` closes it.
    func watchConversation(_ request: CompanionRequest, deviceID: String, app: AppModel) -> CompanionResponse {
        let peer = streams.first { $0.deviceID == deviceID }
        guard request.conversation?.isEmpty == false else {
            peer?.watchConversation = nil
            peer?.sentMessages = nil
            return CompanionResponse(id: request.id, ok: true)
        }
        var response = chat(request, app: app)
        guard response.ok, let id = request.conversation else { return response }
        if let peer {
            peer.watchConversation = id
            peer.sentMessages = response.messages
        }
        response.messagesConversation = id
        return response
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

    func lines(_ conversation: Conversation) -> [ChatLine] {
        let lines = conversation.messages.suffix(60).map { message in
            ChatLine(id: message.id.uuidString, fromNook: message.role == .nook, text: CompanionPolicy.clip(message.text),
                     date: message.date.timeIntervalSince1970, streaming: message.streaming,
                     status: CompanionPolicy.clip(message.status, limit: 120), failed: message.isError,
                     onMac: !message.actions.isEmpty || !message.mails.isEmpty || !message.charts.isEmpty)
        }
        return CompanionPolicy.newestFitting(Array(lines))
    }
}
