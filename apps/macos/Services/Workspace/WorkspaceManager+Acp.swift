import Foundation

/// Gemini CLI, OpenCode, Cursor and Grok over ACP: one agent process per session, kept alive
/// between turns. A turn is `session/prompt`; its reply ends the turn. Messages and thoughts stream in as
/// `session/update`, tool calls show live, and the agent's permission requests are answered here (or right away when the
/// session's rights allow it). A continued conversation is `session/load` when the agent supports it.
extension WorkspaceManager {
    private static let acpIdleSeconds: UInt64 = 30 * 60

    // MARK: Turns

    func launchAcpTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        guard var run = run(id) else { return }
        acpIdleClose[id]?.cancel()
        acpIdleClose[id] = nil
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        // Your message starts over: whatever the agent sent by itself since is not a turn any more.
        acpWakeBuffer[id] = nil
        turns[id] = TurnState()
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)

        if let client = acpClients[id], client.isRunning {
            // Warmed up already: the prompt goes at once, or as soon as the session is open.
            if client.sessionID != nil { sendAcpPrompt(id, client, prompt: prompt) } else { warmPrompts[id] = prompt }
            return
        }
        connectAcp(id, executable: executable, prompt: prompt)
    }

    /// Starts the agent's ACP server and opens (or loads) its session. With a prompt it is sent right away; without one
    /// (warming up when you open the session) the session waits for your first message.
    func connectAcp(_ id: UUID, executable: String, prompt: String?) {
        guard let run = run(id) else { return }
        var input = AgentCommand.Input(provider: run.provider, executable: executable, prompt: prompt ?? "", model: run.model, mode: run.mode,
                                       permission: run.permission, instructions: run.instructions, workingDirectory: run.workingDirectory,
                                       resumeSessionID: run.providerSessionID, accountEnvironment: accountEnvironment(run.profileID), runID: id)
        // An ACP agent you added runs its own command line; without it (removed in Settings) there is nothing to start.
        if run.provider == .acp {
            guard let agent = CustomAgents.agent(for: run.profileID) else {
                if prompt != nil { failAcpTurn(id, tr("ws.acp.agentGone")) }
                return
            }
            input.customAgent = agent
        }
        var spec = AgentCommand.acpSpec(input)
        if run.provider == .antigravity {
            // Its own profile folder, harness and sign-in helper; your other Google settings stay out.
            guard let environment = prepareAntigravity(profileID: run.profileID, executable: executable) else {
                if prompt != nil { failAcpTurn(id, tr("ws.antigravity.notInstalled")) }
                return
            }
            spec.extraEnvironment.merge(environment) { $1 }
            spec.removedEnvironment = AntigravityAcp.removedEnvironment
        }
        spec = placed(spec, for: run)
        let client = AcpClient(spec: spec)
        client.onText = { [weak self] line in
            guard let url = AntigravityAcp.signInURL(inLine: line) else { return }
            Task { @MainActor in self?.openAntigravitySignIn(id, url) }
        }
        client.onMessage = { [weak self] message, events in
            Task { @MainActor in self?.handleAcp(id, client, message, events) }
        }
        client.onExit = { [weak self] status, stderr in
            Task { @MainActor in
                guard let self else { return }
                self.acpExited(id, client, status: status, stderr: stderr, prompt: prompt ?? self.warmPrompts[id] ?? "", executable: executable)
            }
        }
        do {
            try client.start()
        } catch {
            if prompt != nil { failAcpTurn(id, tr("ws.error.launch", error.localizedDescription)) }
            return
        }
        acpClients[id] = client
        if prompt != nil { append(id, RunEvent(kind: .system, text: spec.displayCommand, tool: "launch")) }

        let bridge = self.bridge(for: id).map { launch in
            (command: launch.script, args: ["--agent", run.provider.rawValue], env: ["NOOK_RUN_ID": id.uuidString])
        }
        let provider = run.provider
        client.request("initialize", AcpRPC.initializeParams()) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.acpFailed(id, client, error, prompt: prompt ?? self.warmPrompts[id], executable: executable)
                case .success(let response):
                    let capabilities = (response.dictionary["agentCapabilities"] as? [String: Any]) ?? [:]
                    client.canLoadSessions = (capabilities["loadSession"] as? Bool) ?? false
                    self.learnModels(provider, AgentModelCatalog.acp(response.dictionary))
                    guard provider == .antigravity else {
                        return self.openAcpSession(id, client, bridge: bridge, prompt: prompt, executable: executable)
                    }
                    // Antigravity signs in first: at once with a saved token, otherwise through Google in your browser.
                    client.request("authenticate", ["methodId": AntigravityAcp.authMethod]) { [weak self] result in
                        Task { @MainActor in
                            guard let self else { return }
                            if case .failure(let error) = result {
                                return self.acpFailed(id, client, error, prompt: prompt ?? self.warmPrompts[id], executable: executable)
                            }
                            self.onAntigravitySignedIn?()
                            self.openAcpSession(id, client, bridge: bridge, prompt: prompt, executable: executable)
                        }
                    }
                }
            }
        }
    }

    /// A new session, or the earlier one loaded again (its replay is dropped: Nook keeps the timeline itself).
    private func openAcpSession(_ id: UUID, _ client: AcpClient, bridge: (command: String, args: [String], env: [String: String])?,
                                prompt: String?, executable: String) {
        guard let run = run(id) else { return }
        let loadID = client.canLoadSessions ? run.providerSessionID : nil
        if run.providerSessionID != nil, loadID == nil {
            append(id, RunEvent(kind: .system, text: tr("ws.acp.noLoad", run.provider.displayName)))
        }
        client.replaying = loadID != nil
        client.request(loadID == nil ? "session/new" : "session/load",
                       AcpRPC.sessionParams(cwd: run.workingDirectory, bridge: bridge, loadID: loadID)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                client.replaying = false
                switch result {
                case .failure(let error):
                    self.acpFailed(id, client, error, prompt: prompt ?? self.warmPrompts[id], executable: executable)
                case .success(let response):
                    let session = (response.dictionary["sessionId"] as? String) ?? loadID
                    client.sessionID = session
                    client.freshSession = loadID == nil
                    if let session { self.update(id) { $0.providerSessionID = session } }
                    self.configureAcpSession(id, client, response.dictionary)
                    if let next = prompt ?? self.warmPrompts.removeValue(forKey: id) {
                        self.sendAcpPrompt(id, client, prompt: next)
                    } else {
                        self.scheduleAcpIdleClose(id)
                    }
                }
            }
        }
    }

    /// Plan mode and the model, when the agent offers them (`session/set_mode`, `session/set_model`).
    private func configureAcpSession(_ id: UUID, _ client: AcpClient, _ response: [String: Any]) {
        guard let run = run(id), let session = client.sessionID else { return }
        let modes = ((response["modes"] as? [String: Any])?["availableModes"] as? [[String: Any]]) ?? []
        if run.provider == .antigravity {
            setAcpMode(client, session: session, response: response, modes: modes,
                       to: AntigravityAcp.mode(run.mode, permission: run.permission))
        } else if run.mode == .plan, let plan = modes.first(where: { (($0["id"] as? String) ?? "").lowercased().contains("plan") })?["id"] as? String {
            client.request("session/set_mode", ["sessionId": session, "modeId": plan]) { _ in }
        }
        learnModels(run.provider, AgentModelCatalog.acp(response))
        if !run.model.isEmpty {
            // A model config option is set as one; otherwise `session/set_model`.
            if let option = AgentModelCatalog.acpModelOptionID(response) {
                client.request("session/set_config_option", ["sessionId": session, "configId": option, "value": run.model]) { _ in }
            } else {
                client.request("session/set_model", ["sessionId": session, "modelId": run.model]) { _ in }
            }
        }
    }

    private func sendAcpPrompt(_ id: UUID, _ client: AcpClient, prompt: String) {
        guard let run = run(id), let session = client.sessionID else { return }
        var text = prompt
        // Your instructions go with the first prompt of a newly created session; the plan line with every prompt in Plan mode.
        let instructions = run.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if client.freshSession, !instructions.isEmpty { text = instructions + "\n\n" + text }
        client.freshSession = false
        if run.mode == .plan { text = "Create a plan only; do not make any changes.\n\n" + text }
        client.request("session/prompt", AcpRPC.promptParams(sessionID: session, text: text)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.failAcpTurn(id, WorkspaceManager.cleanError(error.localizedDescription, status: 1))
                case .success(let response):
                    let stop = AcpRPC.stop(response.dictionary)
                    self.finishAcpTurn(id, reason: stop.reason, usage: stop.usage)
                }
            }
        }
    }

    func stopAcpTurn(_ id: UUID) -> Bool {
        guard let client = acpClients[id], run(id)?.status.isActive == true else { return false }
        turns[id]?.stopping = true
        expireApprovals(id)
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopping")))
        if let session = client.sessionID {
            // The prompt request then ends with stopReason "cancelled".
            client.notify("session/cancel", ["sessionId": session])
        } else {
            client.stop()
        }
        return true
    }

    func closeAcpClient(_ id: UUID) {
        acpIdleClose[id]?.cancel()
        acpIdleClose[id] = nil
        acpWakeFinish.removeValue(forKey: id)?.cancel()
        acpWakeBuffer[id] = nil
        acpClients.removeValue(forKey: id)?.stop()
    }

    func decideAcp(_ runID: UUID, requestID: String, _ decision: Decision) -> Bool {
        guard let request = acpRequests.removeValue(forKey: requestID) else { return false }
        let pending = approvals[runID]?.first { $0.id == requestID }
        acpClients[runID]?.respond(request.rpcID, AcpRPC.permissionOutcome(request.options, allow: decision != .deny, always: decision == .always))
        approvals[runID]?.removeAll { $0.id == requestID }
        recap?.decision(allowed: decision != .deny)
        if let pending { mutateEvent(runID, pending.eventID) { $0.state = decision == .deny ? .denied : .allowed } }
        if approvals[runID]?.isEmpty ?? true { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
        return true
    }

    // MARK: Updates

    private func handleAcp(_ id: UUID, _ client: AcpClient, _ message: CodexRPCMessage, _ events: [AcpEvent]) {
        guard acpClients[id] === client, !events.isEmpty else { return }
        if turns[id] == nil, client.sessionID != nil, !client.replaying, run(id)?.status.isActive != true {
            // After its turn: kept until the agent shows it is really working again.
            // A request needs its answer now, turn or not.
            for case .unsupportedRequest(let rpcID) in events { client.respondError(rpcID, message: "Nook does not provide this to agents.") }
            acpWakeBuffer[id, default: []] += events.filter { if case .unsupportedRequest = $0 { return false } else { return true } }
            guard events.contains(where: \.isWakeEvidence) else { return }
            wakeAcp(id)
            let buffered = acpWakeBuffer.removeValue(forKey: id) ?? []
            applyAcp(id, client, buffered)
        } else {
            applyAcp(id, client, events)
        }
        if turns[id]?.unprompted == true { armAcpWakeFinish(id) }
    }

    /// The agent carries on by itself (background work it waited for finished): its updates become a live turn. ACP has
    /// no reply that ends such a turn; it ends after three quiet seconds with nothing still running.
    private func wakeAcp(_ id: UUID) {
        guard var run = run(id) else { return }
        acpIdleClose[id]?.cancel()
        acpIdleClose[id] = nil
        var state = TurnState()
        state.unprompted = true
        turns[id] = state
        append(id, RunEvent(kind: .system, text: tr("ws.wake.background"), tool: "wake"))
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
    }

    private func armAcpWakeFinish(_ id: UUID) {
        acpWakeFinish[id]?.cancel()
        acpWakeFinish[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let state = self.turns[id], state.unprompted, !state.finished else { return }
            let running = state.toolEvents.values.contains { eventID in
                self.timeline(id).first { $0.id == eventID }?.state == .running
            }
            // Still a tool at work, or waiting on you: not over yet.
            if running || self.approvals[id]?.isEmpty == false { return self.armAcpWakeFinish(id) }
            self.acpWakeFinish[id] = nil
            self.finishAcpTurn(id, reason: "end_turn", usage: TurnUsage())
        }
    }

    private func applyAcp(_ id: UUID, _ client: AcpClient, _ events: [AcpEvent]) {
        for event in events {
            switch event {
            case .messageChunk(let text):
                finishAcpThought(id)
                if let live = turns[id]?.liveTextID {
                    mutateEvent(id, live) { $0.text += text }
                } else {
                    let event = RunEvent(kind: .assistant, text: text, state: .running)
                    turns[id]?.liveTextID = event.id
                    append(id, event)
                }
            case .thoughtChunk(let text):
                if let live = turns[id]?.liveReasoningID {
                    mutateEvent(id, live) { $0.text += text }
                } else {
                    finishLiveText(id)
                    let event = RunEvent(kind: .thinking, text: text, state: .running)
                    turns[id]?.liveReasoningID = event.id
                    append(id, event)
                }
            case .toolCall(let call):
                finishLiveText(id)
                finishAcpThought(id)
                let event = RunEvent(kind: .tool, text: call.title.isEmpty ? call.toolName : call.title, tool: call.toolName,
                                     callID: call.id, detail: call.input.map { ToolSummary.json($0.object) },
                                     output: call.output.isEmpty ? nil : RunEvent.clip(call.output), state: Self.state(call.status) ?? .running)
                turns[id]?.toolEvents[call.id] = event.id
                recap?.toolUse(call.toolName)
                append(id, event)
                if call.status == "completed" { for path in call.paths { recordFileChange(id, path: path, kind: "modified") } }
            case .toolCallUpdate(let call):
                // A call from an earlier turn (work it left running in the background) is found by its id.
                guard let eventID = turns[id]?.toolEvents[call.id] ?? timeline(id).last(where: { $0.callID == call.id })?.id else { continue }
                mutateEvent(id, eventID) { event in
                    if !call.title.isEmpty { event.text = call.title }
                    if !call.output.isEmpty { event.output = RunEvent.clip(call.output) }
                    if let state = Self.state(call.status) { event.state = state }
                }
                if call.status == "completed" { for path in call.paths { recordFileChange(id, path: path, kind: "modified") } }
            case .plan(let steps):
                setTasks(id, steps)
            case .usage(let used, let size, let cost):
                turns[id]?.lastContext = used
                if size > 0 { turns[id]?.contextWindow = size }
                if let cost { turns[id]?.acpCost = cost }
            case .permission(let rpcID, let call, let options):
                guard let run = run(id) else { continue }
                if AcpRPC.autoAllows(call, permission: run.permission, mode: run.mode) {
                    client.respond(rpcID, AcpRPC.permissionOutcome(options, allow: true, always: false))
                } else {
                    presentAcpPermission(id, rpcID: rpcID, call: call, options: options)
                }
            case .unsupportedRequest(let rpcID):
                client.respondError(rpcID, message: "Nook does not provide this to agents.")
            }
        }
    }

    private static func state(_ status: String?) -> RunEvent.State? {
        switch status {
        case "completed": return .done
        case "failed": return .failed
        case "pending", "in_progress": return .running
        default: return nil
        }
    }

    private func presentAcpPermission(_ id: UUID, rpcID: RPCID, call: AcpToolCall, options: [AcpPermissionOption]) {
        let requestID = "acp-" + rpcID.text
        var input = call.input?.dictionary ?? [:]
        if input["command"] == nil, call.kind == "execute", !call.title.isEmpty { input["command"] = call.title }
        let summary = call.title.isEmpty ? call.toolName : call.title
        let event = RunEvent(kind: .approval, text: summary, tool: call.toolName, callID: requestID, detail: ToolSummary.json(input), state: .pending)
        append(id, event)
        // "Always" only when the agent offers an allow-always option.
        let always = options.contains { $0.kind == "allow_always" }
        let pending = PendingPermission(id: requestID, runID: id, tool: call.toolName, summary: summary, input: JSONBox(input),
                                        suggestions: always ? JSONBox(["always"]) : nil, eventID: event.id, created: Date())
        acpRequests[requestID] = (rpcID, options)
        approvals[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        if let run = run(id) { onApproval?(run, pending) }
    }

    private func finishAcpThought(_ id: UUID) {
        guard let live = turns[id]?.liveReasoningID else { return }
        mutateEvent(id, live) { $0.state = .done }
        turns[id]?.liveReasoningID = nil
    }

    private func finishAcpTurn(_ id: UUID, reason: String, usage reported: TurnUsage) {
        finishLiveText(id)
        finishAcpThought(id)
        let state = turns[id]
        var usage = reported
        usage.contextTokens = state?.lastContext
        usage.contextWindow = state?.contextWindow
        if let cost = state?.acpCost { usage.reportedCostUSD = cost }
        if usage.durationSeconds == nil, let started = state?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
        turns[id] = nil
        let stopped = (state?.stopping ?? false) || reason == "cancelled"
        let failed = !stopped && reason == "refusal"
        update(id) { run in
            run.usage.add(usage)
            if stopped { run.move(to: .stopped) } else if failed { run.move(to: .failed, detail: reason) } else { run.move(to: .completed) }
        }
        if stopped { append(id, RunEvent(kind: .system, text: tr("ws.event.stopped"))) }
        if reason == "max_tokens" || reason == "max_turn_requests" { append(id, RunEvent(kind: .system, text: tr("ws.acp.limit"))) }
        if failed { append(id, RunEvent(kind: .error, text: tr("ws.acp.refused"))) }
        append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: failed ? .failed : .done))
        expireApprovals(id)
        turnDidFinish(id)
        scheduleGitRefresh(id, delay: 0.5)
        sendQueued(id)
        scheduleAcpIdleClose(id)
    }

    /// An idle session closes after a while; the next message loads it again in a new process.
    private func scheduleAcpIdleClose(_ id: UUID) {
        acpIdleClose[id]?.cancel()
        let seconds = idleSeconds(id, Self.acpIdleSeconds)
        acpIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.run(id)?.status.isActive != true else { return }
            self.closeAcpClient(id)
        }
    }

    // MARK: Failures

    /// Starting failed. Gemini CLI without ACP (an older version) uses its headless mode from now on.
    private func acpFailed(_ id: UUID, _ client: AcpClient, _ error: CodexAppServerError, prompt: String?, executable: String) {
        guard acpClients[id] === client else { return }
        acpClients[id] = nil
        client.stop()
        warmPrompts[id] = nil
        // Warming up failed with no message waiting: remember a Gemini without ACP, and the next message starts it again.
        guard let prompt else {
            if run(id)?.provider == .gemini, client.sessionID == nil { acpFallback.insert(executable) }
            return
        }
        if run(id)?.provider == .gemini, client.sessionID == nil {
            acpFallback.insert(executable)
            turns[id] = nil
            append(id, RunEvent(kind: .system, text: tr("ws.acp.fallback")))
            launchTurn(id, prompt: prompt, executable: executable, showPrompt: false)
            return
        }
        let text = error.localizedDescription
        let login = text.lowercased().contains("auth") ? " " + tr("ws.acp.login", run(id).map { $0.provider.kind.loginCommand } ?? "") : ""
        failAcpTurn(id, WorkspaceManager.cleanError(text, status: 1) + login)
    }

    private func acpExited(_ id: UUID, _ client: AcpClient, status: Int32, stderr: String, prompt: String, executable: String) {
        guard acpClients[id] === client else { return }
        acpClients[id] = nil
        acpIdleClose[id]?.cancel()
        acpIdleClose[id] = nil
        warmPrompts[id] = nil
        guard let state = turns[id], !state.finished else { return }
        if run(id)?.provider == .gemini, client.sessionID == nil, !state.stopping {
            acpFallback.insert(executable)
            turns[id] = nil
            append(id, RunEvent(kind: .system, text: tr("ws.acp.fallback")))
            launchTurn(id, prompt: prompt, executable: executable, showPrompt: false)
            return
        }
        finishLiveText(id)
        finishAcpThought(id)
        expireApprovals(id)
        turns[id] = nil
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
        } else {
            let detail = WorkspaceManager.cleanError(stderr, status: status)
            update(id) { $0.move(to: .failed, detail: detail) }
            append(id, RunEvent(kind: .error, text: detail))
            turnDidFinish(id)
        }
    }

    private func failAcpTurn(_ id: UUID, _ message: String) {
        finishLiveText(id)
        turns[id] = nil
        update(id) { $0.move(to: .failed, detail: message) }
        append(id, RunEvent(kind: .error, text: message))
        turnDidFinish(id)
    }
}
