import Foundation

/// The bridge's tools for the user's other sessions: searching them (`session_search`), keeping the Agents list tidy
/// (`session_organize`) and the questions they wait on (`session_questions`). Arguments are checked in
/// `BridgeSessionArguments`, the rules in `BridgePolicy`; changes go through the same approval card and audit log as the
/// other tools, and use the same actions as the Agents list and the question panel.
extension WorkspaceBridge {
    /// How many sessions a search reads at most, most recent first: older ones are read from disk, off the main thread.
    static let searchScanLimit = 300

    // MARK: Start

    /// A new session, for a script (`nook start`) or an agent. It asks like any other session: you raise its rights yourself.
    func sessionStart(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let workspace = app.workspace
        let task = ((arguments["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return .error("Give the first message.") }
        let folder = WorkspacePathPolicy.normalize((arguments["folder"] as? String) ?? "")
        guard !folder.isEmpty, WorkspacePathPolicy.verdict(for: folder) == .ok else { return .error("That folder cannot be used: \(folder)") }
        let defaults = workspace.settings.sessionDefaults(for: folder)
        let name = ((arguments["agent"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let provider = name.isEmpty ? defaults.provider
            : RunProvider.allCases.first { $0.rawValue == name || $0.displayName.lowercased() == name }
        guard let provider else { return .error("Unknown agent \"\(name)\". Call orchestrator_capabilities for the list.") }
        guard workspace.executable(provider) != nil else { return .error("\(provider.displayName) is not installed.") }
        if case .refuse(let reason) = verdict(.sessionStart, caller) { return .error(Self.refusal(reason)) }
        if case .ask = verdict(.sessionStart, caller) {
            let allowed = await ask(caller, tool: .sessionStart, title: tr("bridge.approval.start", caller.agent, provider.displayName),
                                    detail: AgentPathFormat.tilde(folder) + "\n\n" + task, note: tr("bridge.approval.delegateNote"),
                                    danger: false, connection: context.connection)
            guard allowed else {
                audit(.sessionStart, caller, task, "niet toegestaan")
                return .error(Self.refusal(.delegation))
            }
        }
        var config = NewRunConfig()
        config.task = task
        config.provider = provider
        config.profileID = (app.connectedProfiles(for: provider).first ?? app.profiles.preferredProfile(provider.kind)).id
        let model = ((arguments["model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.isEmpty ? defaults.model(for: provider) : model
        config.permission = provider.capabilities.policies.contains(.ask) ? .ask : (provider.capabilities.policies.first ?? .ask)
        if let worktree = arguments["worktree"] as? Bool {
            config.isolation = worktree ? .worktree : .folder
        } else {
            config.isolation = defaults.isolation
        }
        config.projectPath = folder
        if config.isolation == .worktree {
            config.branchName = WorktreeNaming.branchName(task: task, id: UUID())
            let git = workspace.gitService
            config.baseBranch = await Task.detached(priority: .userInitiated) { git?.currentBranch(folder) ?? "" }.value
        }
        do {
            let id = try await workspace.start(config)
            audit(.sessionStart, caller, "\(provider.displayName) · \(task)", id.uuidString.lowercased())
            return BridgeRPC.ToolResult(text: id.uuidString)
        } catch {
            audit(.sessionStart, caller, task, "mislukt: \(error.localizedDescription)")
            return .error("Nook could not start the session: \(error.localizedDescription)")
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
