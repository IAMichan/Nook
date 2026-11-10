import Foundation

/// The bridge's tools for the user's other sessions: searching them (`session_search`), keeping the Agents list tidy
/// (`session_organize`) and the questions they wait on (`session_questions`). Arguments are checked in
/// `BridgeSessionArguments`, the rules in `BridgePolicy`; changes go through the same approval card and audit log as the
/// other tools, and use the same actions as the Agents list and the question panel.
extension WorkspaceBridge {
    /// How many sessions a search reads at most, most recent first: older ones are read from disk, off the main thread.
    static let searchScanLimit = 300

    // MARK: Start

    /// New sessions, for a script (`nook start`) or an agent: one, or up to 20 in one call `create_threads`
    /// and `thread_launch`. Without a folder they work beside the caller in its own folder or worktree; `worktree` or
    /// `base` gives each a worktree of its own, `scratch` a folder without a project; without a task one starts idle.
    /// They ask like any other session (you raise their rights yourself), and their timeline says who started them.
    func sessionStart(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let workspace = app.workspace
        let plan: BridgeSessionArguments.Start
        switch BridgeSessionArguments.start(arguments, callerFolder: caller.kind == .external ? "" : caller.directory) {
        case .success(let value): plan = value
        case .failure(let error): return .error(error.message)
        }
        var folder = ""
        if let path = plan.folderPath {
            folder = WorkspacePathPolicy.normalize((path as NSString).expandingTildeInPath)
            guard !folder.isEmpty, WorkspacePathPolicy.verdict(for: folder) == .ok else { return .error("That folder cannot be used: \(path)") }
        }
        let defaults = workspace.settings.sessionDefaults(for: folder)
        var providers: [RunProvider] = []
        for session in plan.sessions {
            let name = session.agent.lowercased()
            guard let provider = name.isEmpty ? defaults.provider
                    : RunProvider.allCases.first(where: { $0.rawValue == name || $0.displayName.lowercased() == name }) else {
                return .error("Unknown agent \"\(session.agent)\". Call orchestrator_capabilities for the list.")
            }
            guard workspace.executable(provider) != nil else { return .error("\(provider.displayName) is not installed.") }
            providers.append(provider)
        }
        if case .refuse(let reason) = verdict(.sessionStart, caller) { return .error(Self.refusal(reason)) }
        do {
            return try await once(.sessionStart, arguments, caller) {
                if case .ask = verdict(.sessionStart, caller) {
                    let names = Array(Set(providers.map(\.displayName))).sorted().joined(separator: ", ")
                    let title = plan.sessions.count == 1 ? tr("bridge.approval.start", caller.agent, providers[0].displayName)
                        : tr("bridge.approval.startMany", caller.agent, plan.sessions.count, names)
                    let items = plan.sessions.map { session in
                        "- " + (session.task.isEmpty ? session.title + " " + tr("bridge.approval.startIdle") : session.task)
                    }
                    let allowed = await ask(caller, tool: .sessionStart, title: title,
                                            detail: Self.placeLine(plan.place, folder: folder) + "\n\n" + items.joined(separator: "\n"),
                                            note: tr("bridge.approval.delegateNote"), danger: false, connection: context.connection)
                    guard allowed else {
                        audit(.sessionStart, caller, plan.sessions.map { $0.task.isEmpty ? $0.title : $0.task }.joined(separator: " · "), "niet toegestaan")
                        return .error(Self.refusal(.delegation))
                    }
                }
                var started: [[String: Any]] = []
                for (session, provider) in zip(plan.sessions, providers) {
                    started.append(await startOne(session, provider: provider, place: plan.place, folder: folder, caller: caller, app: app))
                }
                let ok = started.contains { $0["sessionId"] != nil }
                let data = try? JSONSerialization.data(withJSONObject: ["sessions": started],
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                return ok ? BridgeRPC.ToolResult(text: text) : .error(text)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// One session of a `session_start` call: its answer, with the id and link, or the error why it did not start.
    private func startOne(_ session: BridgeSessionArguments.Start.Session, provider: RunProvider,
                          place: BridgeSessionArguments.Start.Place, folder: String, caller: BridgeCaller,
                          app: AppModel) async -> [String: Any] {
        let workspace = app.workspace
        let name = session.task.isEmpty ? session.title : session.task
        var config = NewRunConfig()
        config.task = session.task
        config.title = session.title
        config.startsIdle = session.task.isEmpty
        config.provider = provider
        config.profileID = (app.connectedProfiles(for: provider).first ?? app.profiles.preferredProfile(provider.kind)).id
        config.permission = provider.capabilities.policies.contains(.ask) ? .ask : (provider.capabilities.policies.first ?? .ask)
        config.mode = session.plan && provider.capabilities.planMode ? .plan : .agent
        config.startedBy = Self.startedBy(caller)
        var projectPath = folder
        switch place {
        case .yours, .folder(_, worktree: false):
            config.isolation = .folder
        case .folder(_, worktree: nil):
            config.isolation = workspace.settings.sessionDefaults(for: folder).isolation
        case .folder(_, worktree: .some(true)), .worktree:
            config.isolation = .worktree
        case .scratch:
            config.isolation = .folder
            guard let made = try? ScratchProjects.create(prompt: name) else { return ["title": name, "error": "Nook could not make a folder for it."] }
            projectPath = made
        }
        config.projectPath = projectPath
        let defaults = workspace.settings.sessionDefaults(for: projectPath)
        config.model = session.model.isEmpty ? defaults.model(for: provider) : session.model
        if config.isolation == .worktree {
            config.branchName = WorktreeNaming.branchName(task: name, id: UUID())
            if case .worktree(_, let base?) = place {
                config.baseBranch = base
            } else {
                let git = workspace.gitService
                config.baseBranch = await Task.detached(priority: .userInitiated) { git?.currentBranch(projectPath) ?? "" }.value
            }
        }
        do {
            // The caller asked for this place, and you approved it: a second agent in a folder is the point here.
            let id = try await workspace.start(config, allowSharedFolder: true)
            let run = workspace.run(id)
            audit(.sessionStart, caller, "\(provider.displayName) · \(name)", id.uuidString.lowercased())
            var answer: [String: Any] = ["sessionId": id.uuidString.lowercased(), "title": run?.title ?? name,
                                         "agent": provider.displayName, "status": run?.status.rawValue ?? "preparing",
                                         "folder": run?.workingDirectory ?? projectPath]
            if let link = SessionLink.build(id: id.uuidString, title: run?.title ?? name) { answer["link"] = link.absoluteString }
            if let branch = run?.branch, config.isolation == .worktree { answer["branch"] = branch }
            return answer
        } catch {
            audit(.sessionStart, caller, name, "mislukt: \(error.localizedDescription)")
            return ["title": name, "agent": provider.displayName, "error": "Nook could not start it: \(error.localizedDescription)"]
        }
    }

    /// The first line of a session another agent or a script started.
    static func startedBy(_ caller: BridgeCaller) -> String {
        switch caller.kind {
        case .run: return caller.title.isEmpty ? tr("ws.event.startedBy", caller.agent) : tr("ws.event.startedByIn", caller.agent, caller.title)
        case .external: return tr("ws.event.startedBy", caller.agent)
        }
    }

    /// Where the sessions of an approval card will work.
    static func placeLine(_ place: BridgeSessionArguments.Start.Place, folder: String) -> String {
        switch place {
        case .yours: return tr("bridge.approval.placeYours", AgentPathFormat.tilde(folder))
        case .folder: return AgentPathFormat.tilde(folder)
        case .worktree(_, let base): return tr("bridge.approval.placeWorktree", AgentPathFormat.tilde(folder), base ?? "HEAD")
        case .scratch: return tr("bridge.approval.placeScratch")
        }
    }

    // MARK: Wait

    /// `session_wait`: until one (or all) of these sessions is done with its turn or asks you something, at most the
    /// timeout. Any session may be waited for: reading a session's state is a read, as `session_read` is.
    func sessionWait(_ arguments: [String: Any]) async -> BridgeRPC.ToolResult {
        guard let workspace = app?.workspace else { return .error("Nook is not ready.") }
        let ids: [UUID]
        switch BridgeSessionArguments.waitSessions(arguments["session_ids"]) {
        case .success(let value): ids = value
        case .failure(let error): return .error(error.message)
        }
        guard ids.allSatisfy({ workspace.run($0) != nil }) else { return .error("No such session among these ids. Use ids from session_list or session_start.") }
        let mode = DelegatedTask.WaitMode(rawValue: (arguments["mode"] as? String) ?? "") ?? .any
        let requested = BridgeArgs.int(arguments["timeout_seconds"]) ?? Self.defaultWait
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(requested, 1), Self.maxWait)))
        while true {
            let snapshots = ids.compactMap { workspace.run($0).map(workspace.snapshot(of:)) }
            let over = DelegatedTask.waitIsOver(snapshots, mode: mode)
            if over || Date() >= deadline || Task.isCancelled {
                return BridgeRPC.ToolResult(text: DelegatedTask.renderSessionWait(snapshots, waitTimedOut: !over))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Search

    func sessionSearch(_ arguments: [String: Any]) async -> BridgeRPC.ToolResult {
        guard let workspace = app?.workspace else { return .error("Nook is not ready.") }
        let search: BridgeSessionArguments.Search
        switch BridgeSessionArguments.search(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): search = value
        }
        var candidates = workspace.runs.filter { search.includeArchived || !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
        if let id = search.sessionID {
            candidates = workspace.runs.filter { $0.id == id }
            guard !candidates.isEmpty else { return .error("No such session. Use an id from session_list.") }
        }
        // The search index names the sessions that mention it, however many there are; the title is checked here, since
        // no event holds it. Without the index (or for a query under three characters) the newest sessions are read.
        if search.sessionID == nil, let indexed = await workspace.sessionsMentioning(search.query) {
            let hits = Set(indexed)
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            candidates = candidates.filter { hits.contains($0.id) || $0.title.range(of: search.query, options: options) != nil }
        }
        var found: [String] = []
        var scanned = 0
        for run in candidates.prefix(Self.searchScanLimit) {
            scanned += 1
            // The title is part of the session too, though no event holds it.
            let events = [RunEvent(kind: .system, text: "Title: " + run.title, date: run.createdAt)]
                + (await workspace.timelineForSearch(run.id))
            let result = TimelineSearch.search(events, query: search.query)
            guard result.state == .results else { continue }
            found.append(BridgeSessionArguments.renderMatches(sessionLine: workspace.sessionLine(run), events: events, result: result))
            if found.count >= search.limit { break }
        }
        guard !found.isEmpty else {
            return BridgeRPC.ToolResult(text: "No session mentions \"\(search.query)\" (searched \(scanned) session(s)).")
        }
        return BridgeRPC.ToolResult(text: "Sessions that mention \"\(search.query)\", most recent first (read one in full with session_read):\n\n"
            + found.joined(separator: "\n\n"))
    }

    // MARK: Organize

    func sessionOrganize(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let order: BridgeSessionArguments.Organize
        switch BridgeSessionArguments.organize(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): order = value
        }
        guard let run = app.workspace.run(order.sessionID) else { return .error("No such session. Use an id from session_list.") }
        if case .refuse(let reason) = verdict(.sessionOrganize, caller) { return .error(Self.refusal(reason)) }
        let busy = run.status.isActive || !(app.workspace.questions[run.id] ?? []).isEmpty || !(app.workspace.approvals[run.id] ?? []).isEmpty
        if busy, [.settle, .snooze, .archive].contains(order.action) {
            return .error("\"\(run.title)\" is working or waiting for the user; it can be \(order.action.rawValue)d once it is free.")
        }
        let what = Self.describe(order)
        if case .ask = verdict(.sessionOrganize, caller) {
            let allowed = await ask(caller, tool: .sessionOrganize, title: tr("bridge.approval.organize", caller.agent, run.title),
                                    detail: what, note: tr("bridge.approval.organizeNote"), danger: false,
                                    connection: context.connection)
            guard allowed else {
                audit(.sessionOrganize, caller, "\(run.title) · \(what)", "niet toegestaan")
                return .error(Self.refusal(.needsReview))
            }
        }
        // The session may have gone (or started working) while the card was open.
        guard let current = app.workspace.run(order.sessionID) else { return .error("The session is gone.") }
        let listID = "run:" + current.id.uuidString
        let finishKey = FinishedSessions.key(run: current)
        let inbox = InboxStore.shared
        switch order.action {
        case .pin:
            if FinishedSessions.shared.contains(finishKey) { FinishedSessions.shared.reopenByUser(finishKey) }
            inbox.pin(listID)
        case .unpin:
            inbox.unpin(listID)
        case .settle:
            inbox.unpin(listID, record: false)
            FinishedSessions.shared.mark(finishKey)
        case .reopen:
            FinishedSessions.shared.reopenByUser(finishKey)
        case .snooze:
            app.workspace.snooze(current.id, order.snooze ?? .hour)
            inbox.note(.snoozed, ids: [listID])
        case .wake:
            app.workspace.unsnooze(current.id)
        case .archive:
            guard !current.status.isActive else { return .error("\"\(current.title)\" is working; it cannot be archived now.") }
            app.workspace.setArchived(current.id, true)
            inbox.note(.archived, ids: [listID])
        case .unarchive:
            app.workspace.setArchived(current.id, false)
        case .markUnread:
            SessionVisits.shared.markUnread(listID)
        case .markRead:
            SessionVisits.shared.visit(listID)
        }
        audit(.sessionOrganize, caller, "\(current.title) · \(what)", "gedaan")
        return BridgeRPC.ToolResult(text: "Done: \(what) for \"\(current.title)\".")
    }

    /// The action in words, for the card, the audit log and the answer.
    private static func describe(_ order: BridgeSessionArguments.Organize) -> String {
        switch order.action {
        case .snooze: return "snooze until " + (order.snooze ?? .hour).rawValue
        case .markUnread: return "mark unread"
        case .markRead: return "mark read"
        default: return order.action.rawValue
        }
    }

    // MARK: Questions

    func sessionQuestions(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let workspace = app?.workspace else { return .error("Nook is not ready.") }
        let request: BridgeSessionArguments.Questions
        switch BridgeSessionArguments.questions(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): request = value
        }
        var own: UUID?
        if case .run(let id) = caller.kind { own = id }
        switch request.action {
        case .list:
            var lines: [String] = []
            let waiting = workspace.questions.filter { id, list in
                id != own && !list.isEmpty && (request.sessionID == nil || request.sessionID == id)
            }
            for (id, list) in waiting.sorted(by: { ($0.value.first?.created ?? .distantPast) < ($1.value.first?.created ?? .distantPast) }) {
                guard let run = workspace.run(id) else { continue }
                for pending in list {
                    let first = pending.questions.first?.question ?? ""
                    let more = pending.questions.count > 1 ? " (+\(pending.questions.count - 1) more)" : ""
                    let mine = run.delegation?.parentID == own && own != nil ? " · your task" : ""
                    lines.append("- session \(run.id.uuidString) · \(run.title) · \(run.provider.displayName)\(mine) · question \(pending.id): \(ToolSummary.oneLine(first, 160))\(more)")
                }
            }
            if lines.isEmpty { return BridgeRPC.ToolResult(text: "No session is waiting on a question.") }
            return BridgeRPC.ToolResult(text: "Questions sessions wait on (read one with action read):\n" + lines.joined(separator: "\n"))
        case .read, .answer:
            guard let id = request.sessionID, let questionID = request.questionID, let run = workspace.run(id) else {
                return .error("No such session. Use an id from session_questions.")
            }
            guard id != own else { return .error("That question is your own; the user answers it.") }
            guard let pending = workspace.questions[id]?.first(where: { $0.id == questionID }) else {
                return .error("That question is no longer waiting (answered, or the session stopped).")
            }
            if request.action == .read {
                return BridgeRPC.ToolResult(text: "Session \(run.id.uuidString) · \(run.title) · \(run.provider.displayName)\n"
                    + BridgeSessionArguments.render(questionID: pending.id, questions: pending.questions, asked: pending.created))
            }
            let answers: [String: [String]]
            switch BridgeSessionArguments.validate(request.answers, for: pending.questions) {
            case .failure(let error): return .error(error.message)
            case .success(let value): answers = value
            }
            let ownTask = own != nil && run.delegation?.parentID == own
            let shown = pending.questions.map { "\($0.question) → \((answers[$0.id] ?? []).joined(separator: ", "))" }
                .joined(separator: "\n")
            switch verdict(.sessionQuestions, caller, answers: true, ownTask: ownTask) {
            case .refuse(let reason):
                return .error(Self.refusal(reason))
            case .ask:
                let allowed = await ask(caller, tool: .sessionQuestions, title: tr("bridge.approval.answer", caller.agent, run.title),
                                        detail: shown, note: tr("bridge.approval.answerNote"), danger: false,
                                        connection: context.connection)
                guard allowed else {
                    audit(.sessionQuestions, caller, "\(run.title) · \(questionID)", "niet toegestaan")
                    return .error(Self.refusal(.delegation))
                }
            case .allow:
                break
            }
            // Answered in Nook while the card was open: the user's own answer stands.
            guard workspace.questions[id]?.contains(where: { $0.id == questionID }) == true else {
                return .error("The user answered that question in the meantime.")
            }
            workspace.append(id, RunEvent(kind: .system, text: tr("ws.question.answeredBy", caller.agent)))
            workspace.answer(id, questionID: questionID, answers: answers)
            audit(.sessionQuestions, caller, "\(run.title) · \(questionID)", "beantwoord")
            return BridgeRPC.ToolResult(text: "Answered. The session goes on with:\n" + shown)
        }
    }
}
