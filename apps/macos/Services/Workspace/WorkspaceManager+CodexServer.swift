import Foundation

/// Codex sessions over `codex app-server`: one process per session that stays alive between
/// turns. A turn is `turn/start` on the session's thread; while it runs you can steer it (`turn/steer`), stop it
/// (`turn/interrupt`), and answer Codex's approval requests and questions here. When this Codex has no usable app-server
/// (too old), the session falls back to `codex exec` for good, and nothing is lost.
extension WorkspaceManager {
    /// Closes an idle Codex session after this long; the next message resumes the thread in a new process.
    private static let codexIdleSeconds: UInt64 = 30 * 60

    // MARK: Turns

    func launchCodexServerTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        guard var run = run(id) else { return }
        codexIdleClose[id]?.cancel()
        codexIdleClose[id] = nil
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        turns[id] = TurnState()
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)

        if let client = codexServers[id], client.isRunning {
            // Warmed up already: the turn starts at once, or as soon as the thread is open.
            if client.threadID != nil { startCodexTurn(id, client, prompt: prompt) } else { warmPrompts[id] = prompt }
            return
        }
        connectCodexServer(id, executable: executable, prompt: prompt)
    }

    /// Starts Codex's app-server for a session and opens its thread. With a prompt the turn follows right away; without
    /// one (warming up when you open the session, so your first message goes out at once) it waits for your message.
    func connectCodexServer(_ id: UUID, executable: String, prompt: String?) {
        guard let run = run(id) else { return }
        var environment = accountEnvironment(run.profileID)
        environment["NOOK_RUN_ID"] = id.uuidString
        let spec = placed(LaunchSpec(executable: executable, arguments: ["app-server"], extraEnvironment: environment,
                                     workingDirectory: run.workingDirectory, initialInput: [], keepsInputOpen: true), for: run)
        let client = CodexAppServerClient(spec: spec)
        client.onMessage = { [weak self] message, events in
            Task { @MainActor in self?.handleCodexServer(id, client, message, events) }
        }
        client.onExit = { [weak self] status, stderr in
            Task { @MainActor in
                guard let self else { return }
                self.codexServerExited(id, client, status: status, stderr: stderr, prompt: prompt ?? self.warmPrompts[id] ?? "", executable: executable)
            }
        }
        do {
            try client.start()
        } catch {
            if prompt != nil { failCodexTurn(id, tr("ws.error.launch", error.localizedDescription)) }
            return
        }
        codexServers[id] = client
        if prompt != nil { append(id, RunEvent(kind: .system, text: spec.displayCommand, tool: "launch")) }

        let instructions = [run.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                            bridge(for: id) == nil ? "" : BridgeLaunch.instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let thread = CodexRPC.threadParams(cwd: run.workingDirectory, model: run.model,
                                           mcpServers: bridge(for: id)?.codexMCPServers(runID: id),
                                           resumeID: run.providerSessionID, instructions: instructions.isEmpty ? nil : instructions)
        let method = run.providerSessionID == nil ? "thread/start" : "thread/resume"
        client.request("initialize", CodexRPC.initializeParams()) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.codexServerFailed(id, client, error, prompt: prompt ?? self.warmPrompts[id], executable: executable)
                    return
                }
                client.notify("initialized")
                client.request(method, thread) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        switch result {
                        case .failure(let error):
                            self.codexServerFailed(id, client, error, prompt: prompt ?? self.warmPrompts[id], executable: executable)
                        case .success(let response):
                            let threadID = (response.dictionary["thread"] as? [String: Any])?["id"] as? String ?? run.providerSessionID
                            client.threadID = threadID
                            self.update(id) {
                                if let threadID { $0.providerSessionID = threadID }
                                if let model = response.dictionary["model"] as? String, !model.isEmpty { $0.resolvedModel = model }
                            }
                            if let next = prompt ?? self.warmPrompts.removeValue(forKey: id) {
                                self.startCodexTurn(id, client, prompt: next)
                            } else {
                                self.scheduleCodexIdleClose(id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func startCodexTurn(_ id: UUID, _ client: CodexAppServerClient, prompt: String) {
        guard let run = run(id), let thread = client.threadID else { return }
        let planModel = run.model.isEmpty ? run.resolvedModel : run.model
        var text = prompt
        // Without a model name Codex's own plan mode is unavailable: the read-only sandbox and this line keep it to a plan.
        if run.mode == .plan, (planModel ?? "").isEmpty { text = "Create a plan only; do not make any changes.\n\n" + prompt }
        turns[id]?.codexBaseline = codexTotals[id]
        var params = CodexRPC.turnStartParams(threadID: thread, text: text, cwd: run.workingDirectory, model: run.model,
                                              mode: run.mode, permission: run.permission, planModel: planModel,
                                              effort: run.effort)
        // What MCP apps told the agent: text an MCP server wrote, so it goes in as untrusted context.
        let appContexts = takeMcpAppContexts(id)
        if !appContexts.isEmpty {
            params["additionalContext"] = Dictionary(uniqueKeysWithValues: appContexts.map { ($0.key, ["kind": "untrusted", "value": $0.text]) })
        }
        client.request("turn/start", params) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.failCodexTurn(id, error.localizedDescription)
                case .success(let response):
                    if let turn = (response.dictionary["turn"] as? [String: Any])?["id"] as? String { client.turnID = turn }
                }
            }
        }
    }

    /// Steers the running turn with a new message: `turn/steer` for Codex, a `priority: "now"` message for Claude Code.
    /// False when the session cannot be steered right now.
    @discardableResult
    func steer(_ id: UUID, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, canSteer(id) else { return false }
        if let process = processes[id], run(id)?.provider == .claude {
            append(id, RunEvent(kind: .user, text: ContextRefs.visible(clean)))
            turns[id]?.steered = true
            process.send(ClaudeStreamParser.userMessage(clean, steer: true))
            return true
        }
        guard let client = codexServers[id], let thread = client.threadID, let turn = client.turnID else { return false }
        append(id, RunEvent(kind: .user, text: ContextRefs.visible(clean)))
        client.request("turn/steer", CodexRPC.steerParams(threadID: thread, turnID: turn, text: clean)) { [weak self] result in
            guard case .failure(let error) = result else { return }
            Task { @MainActor in self?.append(id, RunEvent(kind: .error, text: tr("ws.steer.failed", error.localizedDescription))) }
        }
        return true
    }

    /// A running turn that can take a new message right away: Codex on app-server, or Claude Code on its live process
    /// (not while it waits for an answer to its question, or once it is being stopped).
    func canSteer(_ id: UUID) -> Bool {
        guard let run = run(id), run.status.isActive, turns[id]?.stopping != true, turns[id]?.finished != true else { return false }
        if run.provider == .claude {
            return processes[id]?.isRunning == true && questions[id] == nil
        }
        guard let client = codexServers[id] else { return false }
        return client.turnID != nil
    }

    /// Stops the running turn politely (`turn/interrupt`). False when this is not a Codex app-server session.
    func stopCodexServerTurn(_ id: UUID) -> Bool {
        guard let client = codexServers[id], run(id)?.status.isActive == true else { return false }
        turns[id]?.stopping = true
        expireApprovals(id)
        questions[id] = nil
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopping")))
        if let thread = client.threadID, let turn = client.turnID {
            client.request("turn/interrupt", CodexRPC.interruptParams(threadID: thread, turnID: turn)) { _ in }
        } else {
            // Still starting up: end the process; its exit marks the session stopped.
            client.stop()
        }
        return true
    }

    func closeCodexServer(_ id: UUID) {
        codexIdleClose[id]?.cancel()
        codexIdleClose[id] = nil
        codexServers.removeValue(forKey: id)?.stop()
    }

    // MARK: Decisions

    /// Answers a Codex approval request. False when the request is not one of Codex's.
    func decideCodex(_ runID: UUID, requestID: String, _ decision: Decision) -> Bool {
        guard let request = codexRequests.removeValue(forKey: requestID) else { return false }
        if decision == .always, let run = run(runID) {
            // Codex's own "for this session" only covers the exact command: Nook remembers the kind for this mode.
            var granted = sessionApprovals[runID] ?? SessionApprovals()
            granted.grant(kind: approvalKind(request), mode: run.permission)
            sessionApprovals[runID] = granted
        }
        let pending = approvals[runID]?.first { $0.id == requestID }
        codexServers[runID]?.respond(request.rpcID, CodexRPC.decision(request, allow: decision != .deny, always: decision == .always))
        approvals[runID]?.removeAll { $0.id == requestID }
        recap?.decision(allowed: decision != .deny)
        if let pending { mutateEvent(runID, pending.eventID) { $0.state = decision == .deny ? .denied : .allowed } }
        if (approvals[runID]?.isEmpty ?? true), (questions[runID]?.isEmpty ?? true) { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
        return true
    }

    /// Answers a question: per question id the chosen labels, or your own text.
    func answer(_ runID: UUID, questionID: String, answers: [String: [String]]) {
        guard let question = questions[runID]?.first(where: { $0.id == questionID }) else { return }
        // Nobody left to answer (the process ended): drop the question instead of pretending the agent works on.
        if case .claude = question.origin, processes[runID] == nil {
            questions[runID] = nil
            return
        }
        questions[runID]?.removeAll { $0.id == questionID }
        if questions[runID]?.isEmpty == true { questions[runID] = nil }
        switch question.origin {
        case .codex(let rpcID):
            codexServers[runID]?.respond(rpcID, CodexRPC.answers(answers))
        case .claude(let requestID, let input):
            processes[runID]?.send(ClaudeStreamParser.questionAnswer(requestID: requestID, input: input, questions: question.questions,
                                                                     answers: answers))
        }
        let shown = question.questions.map { item in
            "\(item.question) → \((answers[item.id] ?? []).joined(separator: ", "))"
        }.joined(separator: "\n")
        append(runID, RunEvent(kind: .user, text: shown))
        if (approvals[runID]?.isEmpty ?? true), (questions[runID]?.isEmpty ?? true) { update(runID) { $0.move(to: .running) } }
    }

    // MARK: Messages

    private func handleCodexServer(_ id: UUID, _ client: CodexAppServerClient, _ message: CodexRPCMessage, _ events: [CodexStreamEvent]) {
        guard codexServers[id] === client else { return }
        for event in events {
            switch event {
            case .turnStarted(let turn):
                client.turnID = turn
                // Codex started a turn on its own (background work it waited for finished): the session works again.
                if let run = run(id), !run.status.isActive, turns[id] == nil { wakeCodexServer(id) }
            case .approval(let request):
                presentCodexApproval(id, request)
            case .question(let rpcID, let items):
                let pending = PendingQuestion(id: "codexq-" + rpcID.text, runID: id, questions: items, origin: .codex(rpcID), created: Date())
                questions[id, default: []].append(pending)
                update(id) { $0.move(to: .waitingApproval) }
                if let run = run(id) { onQuestion?(run, pending) }
            case .unsupportedRequest(let rpcID):
                client.respondError(rpcID, message: "Nook does not support this request.")
            case .rateLimits(let limits):
                codexLimitSnapshots[id] = limits
                onRateLimits?()
            case .mcpApp(let callID, let server, let tool, let arguments, let result, let uri):
                captureMcpApp(id, client, callID: callID, server: server, tool: tool, arguments: arguments, result: result, resourceUri: uri)
            case .commandFinished(let callID, let command, let output, let exitCode)
                where turns[id] == nil && run(id)?.status.isActive != true:
                // A command left running in the background finished after the turn: its result goes to Codex as a new
                // turn, so Codex can act on it.
                handleCodex(event, id: id)
                append(id, RunEvent(kind: .system, text: tr("ws.wake.command", ToolSummary.oneLine(command, 80)), tool: "wake"))
                let message = BackgroundWork.codexMessage(command: command, exitCode: exitCode, output: output)
                if let run = run(id), run.canContinue, processes[id] == nil, !run.status.isActive {
                    sendHidden(id, text: message)
                } else {
                    enqueue(id, text: message)
                }
            default:
                handleCodex(event, id: id)
            }
        }
    }

    private func approvalKind(_ request: CodexApprovalRequest) -> ApprovalKind {
        request.kind == .command || request.kind == .legacyCommand ? .command : .fileChange
    }

    private func presentCodexApproval(_ id: UUID, _ request: CodexApprovalRequest) {
        // Allowed for this session before: answer without asking again (a dangerous command is never covered).
        if let run = run(id), sessionApprovals[id]?.isGranted(kind: approvalKind(request), mode: run.permission) == true,
           !(request.kind == .command || request.kind == .legacyCommand) || CommandRisk.assess(request.command).level != .danger {
            codexServers[id]?.respond(request.rpcID, CodexRPC.decision(request, allow: true, always: false))
            append(id, RunEvent(kind: .system, text: tr("ws.event.sessionAllowed", ToolSummary.oneLine(request.command.isEmpty ? request.reason : request.command, 80))))
            return
        }
        let requestID = "codex-" + request.rpcID.text
        let isCommand = request.kind == .command || request.kind == .legacyCommand
        let tool = isCommand ? "shell" : "apply_patch"
        var input: [String: Any] = [:]
        if isCommand { input["command"] = request.command }
        if !request.cwd.isEmpty { input[isCommand ? "cwd" : "path"] = request.cwd }
        if !request.reason.isEmpty { input["reason"] = request.reason }
        let summary = isCommand ? "shell · " + ToolSummary.oneLine(request.command, 120)
            : (request.reason.isEmpty ? tr("ws.codex.fileChange") : request.reason)
        let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID, detail: ToolSummary.json(input), state: .pending)
        append(id, event)
        // A non-empty suggestion list enables "Always", which Codex knows as "accept for this session".
        let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: JSONBox(input),
                                        suggestions: JSONBox(["session"]), eventID: event.id, created: Date())
        codexRequests[requestID] = request
        approvals[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        if let run = run(id) { onApproval?(run, pending) }
    }

    /// The events only app-server sends, routed here from `handleCodex`.
    func handleCodexServerEvent(_ event: CodexStreamEvent, id: UUID) {
        switch event {
        case .messageDelta(let item, let text):
            finishLiveReasoning(id)
            if let live = turns[id]?.liveTextID, turns[id]?.liveTextItem == item {
                mutateEvent(id, live) { $0.text += text }
            } else {
                finishLiveText(id)
                let event = RunEvent(kind: .assistant, text: text, state: .running)
                turns[id]?.liveTextID = event.id
                turns[id]?.liveTextItem = item
                append(id, event)
            }
        case .messageCompleted(let item, let text):
            if let live = turns[id]?.liveTextID, turns[id]?.liveTextItem == item {
                mutateEvent(id, live) { $0.text = text; $0.state = .done }
                turns[id]?.liveTextID = nil
                turns[id]?.liveTextItem = nil
            } else {
                finishLiveText(id)
                append(id, RunEvent(kind: .assistant, text: text, state: .done))
            }
        case .reasoningDelta(let item, let text):
            if let live = turns[id]?.liveReasoningID, turns[id]?.liveReasoningItem == item {
                mutateEvent(id, live) { $0.text += text }
            } else {
                finishLiveReasoning(id)
                let event = RunEvent(kind: .thinking, text: text, state: .running)
                turns[id]?.liveReasoningID = event.id
                turns[id]?.liveReasoningItem = item
                append(id, event)
            }
        case .reasoningCompleted(let item, let text):
            if let live = turns[id]?.liveReasoningID, turns[id]?.liveReasoningItem == item {
                mutateEvent(id, live) { $0.text = text; $0.state = .done }
                turns[id]?.liveReasoningID = nil
                turns[id]?.liveReasoningItem = nil
            } else {
                append(id, RunEvent(kind: .thinking, text: text, state: .done))
            }
        case .commandOutput(let item, let delta):
            if let eventID = turns[id]?.toolEvents[item] {
                mutateEvent(id, eventID) { $0.output = RunEvent.clip(($0.output ?? "") + delta) }
            }
        case .tokenUsage(let usage):
            codexTotals[id] = usage.total
            turns[id]?.lastContext = usage.last.context + usage.last.output
            if let window = usage.contextWindow { turns[id]?.contextWindow = window }
        case .turnFinished(let status, let error, let duration):
            finishCodexTurn(id, status: status, error: error, duration: duration)
        case .plan(let text):
            finishLiveText(id)
            append(id, RunEvent(kind: .assistant, text: text, tool: "plan", state: .done))
        case .tasks(let steps):
            setTasks(id, steps)
        case .subagentSpawned(let callID, let prompt, let model, let threads, let failed):
            // The same shape as Claude Code's Agent call, so the subagent bar shows Codex's subagents too.
            guard turns[id]?.toolEvents[callID] == nil else { return }
            finishLiveText(id)
            let input: [String: Any] = ["description": TimelinePresentation.headline(prompt, limit: 80), "prompt": prompt,
                                        "subagent_type": model ?? "codex"]
            let event = RunEvent(kind: .tool, text: "Agent · " + TimelinePresentation.headline(prompt, limit: 80), tool: "Agent",
                                 callID: callID, detail: ToolSummary.json(input), state: failed ? .failed : .running)
            turns[id]?.toolEvents[callID] = event.id
            for thread in threads { codexSubagents[id, default: [:]][thread] = event.id }
            append(id, event)
        case .subagentStates(let states):
            for (thread, state) in states where state.isFinished {
                guard let eventID = codexSubagents[id]?[thread] else { continue }
                mutateEvent(id, eventID) { event in
                    event.state = state.isFailure ? .failed : .done
                    if let message = state.message, !message.isEmpty { event.output = RunEvent.clip(message) }
                }
                codexSubagents[id]?[thread] = nil
            }
        case .notice(let text):
            append(id, RunEvent(kind: .system, text: text == "compact" ? tr("ws.event.compacted") : text))
        default:
            break
        }
    }

    private func finishLiveReasoning(_ id: UUID) {
        guard let live = turns[id]?.liveReasoningID else { return }
        mutateEvent(id, live) { $0.state = .done }
        turns[id]?.liveReasoningID = nil
        turns[id]?.liveReasoningItem = nil
    }

    private func finishCodexTurn(_ id: UUID, status: String, error: String?, duration: Double?) {
        finishLiveText(id)
        finishLiveReasoning(id)
        let state = turns[id]
        // This turn's own tokens: the thread's total now minus the total when it started.
        var usage = TurnUsage()
        if let total = codexTotals[id] {
            let base = state?.codexBaseline ?? TokenCounts()
            usage.inputTokens = max(0, total.input - base.input)
            usage.outputTokens = max(0, total.output - base.output)
            usage.cacheReadTokens = max(0, total.cacheRead - base.cacheRead)
            usage.cacheWriteTokens = max(0, total.cacheWrite - base.cacheWrite)
        }
        usage.contextTokens = state?.lastContext
        usage.contextWindow = state?.contextWindow
        usage.durationSeconds = duration ?? state.map { Date().timeIntervalSince($0.started) }
        turns[id]?.finished = true
        codexServers[id]?.turnID = nil
        let stopped = (state?.stopping ?? false) || status == "interrupted"
        let failed = !stopped && status == "failed"
        update(id) { run in
            run.usage.add(usage)
            if stopped { run.move(to: .stopped) } else if failed { run.move(to: .failed, detail: error) } else { run.move(to: .completed) }
        }
        if failed { append(id, RunEvent(kind: .error, text: error ?? tr("ws.event.failed", status))) }
        if stopped { append(id, RunEvent(kind: .system, text: tr("ws.event.stopped"))) }
        append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: failed ? .failed : .done))
        expireApprovals(id)
        questions[id] = nil
        turns[id] = nil
        turnDidFinish(id)
        scheduleGitRefresh(id, delay: 0.5)
        sendQueued(id)
        scheduleCodexIdleClose(id)
    }

    private func wakeCodexServer(_ id: UUID) {
        guard var run = run(id) else { return }
        codexIdleClose[id]?.cancel()
        codexIdleClose[id] = nil
        turns[id] = TurnState()
        append(id, RunEvent(kind: .system, text: tr("ws.wake.background"), tool: "wake"))
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
    }

    private func scheduleCodexIdleClose(_ id: UUID) {
        codexIdleClose[id]?.cancel()
        let seconds = idleSeconds(id, Self.codexIdleSeconds)
        codexIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.run(id)?.status.isActive != true else { return }
            self.closeCodexServer(id)
        }
    }

    // MARK: Failures

    /// The handshake or thread failed. A Codex without app-server support gets `codex exec` from now on.
    private func codexServerFailed(_ id: UUID, _ client: CodexAppServerClient, _ error: CodexAppServerError, prompt: String?, executable: String) {
        guard codexServers[id] === client else { return }
        codexServers[id] = nil
        client.stop()
        warmPrompts[id] = nil
        // Warming up failed with no message waiting: remember an old Codex, and the next message starts it again.
        guard let prompt else {
            if error.meansUnsupported { codexExecOnly.insert(executable) }
            return
        }
        if error.meansUnsupported {
            fallBackToExec(id, prompt: prompt, executable: executable)
        } else {
            failCodexTurn(id, WorkspaceManager.cleanError(error.localizedDescription, status: 1))
        }
    }

    private func fallBackToExec(_ id: UUID, prompt: String, executable: String) {
        codexExecOnly.insert(executable)
        turns[id] = nil
        append(id, RunEvent(kind: .system, text: tr("ws.codex.execFallback")))
        launchTurn(id, prompt: prompt, executable: executable, showPrompt: false)
    }

    private func codexServerExited(_ id: UUID, _ client: CodexAppServerClient, status: Int32, stderr: String, prompt: String, executable: String) {
        guard codexServers[id] === client else { return }
        codexServers[id] = nil
        codexIdleClose[id]?.cancel()
        codexIdleClose[id] = nil
        warmPrompts[id] = nil
        guard let state = turns[id], !state.finished else { return }
        if client.threadID == nil, CodexAppServerError.exited(stderr).meansUnsupported {
            fallBackToExec(id, prompt: prompt, executable: executable)
            return
        }
        finishLiveText(id)
        finishLiveReasoning(id)
        expireApprovals(id)
        questions[id] = nil
        turns[id] = nil
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
        } else {
            let detail = WorkspaceManager.cleanError(state.lastError ?? stderr, status: status)
            update(id) { $0.move(to: .failed, detail: detail) }
            append(id, RunEvent(kind: .error, text: detail))
            turnDidFinish(id)
        }
        scheduleGitRefresh(id, delay: 0.2)
    }

    private func failCodexTurn(_ id: UUID, _ message: String) {
        finishLiveText(id)
        turns[id] = nil
        update(id) { $0.move(to: .failed, detail: message) }
        append(id, RunEvent(kind: .error, text: message))
        turnDidFinish(id)
    }
}
