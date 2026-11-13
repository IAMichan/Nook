import Foundation

/// Claude Code over stream-json: a process per turn that takes control requests on stdin (an interrupt, the answers to its
/// permission requests) and waits there between turns, parked (`WorkspaceManager+ClaudeSession`), so the next turn goes
/// into the same process.
struct ClaudeStreamTurnDriver: ProcessTurnDriver {
    unowned let workspace: WorkspaceManager

    func interruptRequest() -> String? {
        ClaudeStreamParser.interruptRequest(id: "nook-stop-" + UUID().uuidString.prefix(8))
    }

    func answer(requestID: String, _ pending: PendingPermission, _ decision: WorkspaceManager.Decision,
                reason: String) -> (line: String, notesReason: Bool) {
        (WorkspaceManager.streamJSONPermissionResponse(requestID: requestID, pending, decision, reason: reason), true)
    }

    func continueInProcess(_ id: UUID, prompt: String, showPrompt: Bool, rollingBack: Bool) -> Bool {
        // Claude Code still running from the previous turn, with the same settings: continue in it.
        if !rollingBack, workspace.continueClaudeProcess(id, prompt: prompt, showPrompt: showPrompt) { return true }
        if rollingBack { workspace.closeClaudeProcess(id) }
        return false
    }

    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String) {
        workspace.prewarmClaudeProcess(id, run: run, executable: executable)
    }
}

extension WorkspaceManager {
    /// Claude Code's answer to one of its permission requests. Also what a process without a channel of its own is sent
    /// (`ExecTurnDriver`), as before there were drivers.
    static func streamJSONPermissionResponse(requestID: String, _ pending: PendingPermission, _ decision: Decision,
                                             reason: String) -> String {
        // An MCP server's question: its answer is the elicitation's result, under Claude Code's own request id.
        if requestID.hasPrefix(ClaudeElicitation.pendingPrefix) {
            return ClaudeStreamParser.elicitationResponse(requestID: String(requestID.dropFirst(ClaudeElicitation.pendingPrefix.count)),
                                                          accept: decision != .deny)
        }
        switch decision {
        case .allow:
            return ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: pending.input)
        case .always:
            return ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: pending.input,
                                                         rules: pending.canAlways ? pending.suggestions : nil)
        case .deny:
            return ClaudeStreamParser.permissionResponse(requestID: requestID, allow: false, input: pending.input, message: reason)
        }
    }

    /// Starts Claude Code waiting on stdin with the conversation resumed (see `prewarm`).
    func prewarmClaudeProcess(_ id: UUID, run: WorkspaceRun, executable: String) {
        let capabilities = run.provider.capabilities
        guard claudeIdle[id] == nil else { return }
        if capabilities.probesLaunchFlags, !run.isRemote, claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
        var spec = placed(AgentCommand.spec(AgentCommand.Input(
            provider: run.provider, executable: executable, prompt: "", model: run.model, mode: run.mode, permission: run.permission,
            instructions: launchInstructions(run), workingDirectory: run.workingDirectory, resumeSessionID: run.providerSessionID,
            accountEnvironment: accountEnvironment(run.profileID), runID: id, bridge: bridge(for: id),
            thinkingDisplay: capabilities.probesLaunchFlags && claudeThinkingDisplay[executable] == true,
            promptSuggestions: launchesPromptSuggestions(run, executable: executable),
            toolSearch: claudeToolSearch(run), tuning: appliedTuning(run),
            effort: run.effort, speedTier: speedTier(run), ultracode: ultracode(run))), for: run)
        spec.initialInput = []
        let suggests = launchesPromptSuggestions(run, executable: executable)
        let process = AgentProcess(spec: spec)
        process.onLines = { [weak self, weak process] lines in
            let parsed = ParsedStreamLine.parse(lines, provider: run.provider)
            Task { @MainActor in
                // While it only waits, nothing it prints is a turn (a failed resume must not fail the session), apart
                // from the answers to Nook's own requests (a connector's sign-in page).
                guard let self, let process else { return }
                guard self.processes[id] === process else {
                    // Parked after a turn: its prediction of your next message still counts.
                    for case .claude(let events) in parsed {
                        for case .promptSuggestion(let text) in events { self.offerAgentPrompt(id, text) }
                    }
                    return self.handleClaudeReplies(lines, for: id)
                }
                for line in parsed { self.handle(parsed: line, for: id) }
            }
        }
        let token = ObjectIdentifier(process)
        process.onExit = { [weak self] status, stderr in
            Task { @MainActor in self?.processExited(id, status: status, stderr: stderr, process: token) }
        }
        guard (try? process.start()) != nil else { return }
        if suggests { agentSuggestsPrompts.insert(id) } else { agentSuggestsPrompts.remove(id) }
        parkWarmClaude(id, process, key: claudeKey(run))
    }

    func handleClaude(_ event: ClaudeStreamEvent, id: UUID) {
        switch event {
        case .initialized(let session, let model):
            if forkLaunched.remove(id) == nil { rememberEarlierSession(id, replacedBy: session) }
            update(id) {
                $0.providerSessionID = session
                if let model, !model.isEmpty { $0.resolvedModel = model }
            }
            noteConversationSession(id, session, keepsHistory: true)
        case .chainEntry(let uuid):
            noteConversationHead(id, uuid)
        case .connectorsNeedingSignIn(let names):
            noteConnectorsNeedingSignIn(id, names)
        case .controlReply(let requestID, let response, let error):
            claudeControlReplies.removeValue(forKey: requestID)?(response, error)
        case .textDelta(let text):
            feed(id, .textDelta(text))
        case .text(let text):
            feed(id, .text(text))
        case .thinkingDelta(let text, let starts):
            if starts { feed(id, .thinkingStarted) }
            feed(id, .thinkingDelta(text))
        case .blockStopped:
            feed(id, .thinkingEnded)
        case .requestStarted(let ttl):
            turns[id]?.lastRequestAt = Date()
            if let ttl { turns[id]?.cacheTTL = ttl }
        case .thinking(let text):
            feed(id, .thinking(text))
        case .toolUse(let callID, let name, let input, let nested):
            feed(id, .toolStarted(AgentToolCall(id: callID, name: name, title: ToolSummary.describe(tool: name, input: input.dictionary),
                                                detail: ToolSummary.json(input.object), input: input, nested: nested)))
            // Claude Code's own task list (not a subagent's) becomes the Tasks strip above the composer.
            if name == "TodoWrite", !nested, let steps = RunTasks.claude(input.dictionary) { setTasks(id, steps) }
        case .toolResult(let callID, let output, let isError):
            // A subagent started in the background answers at once that it started: it runs on until its notification.
            let call = timeline(id).last(where: { $0.callID == callID && $0.kind == .tool })
            let background = !isError && Subagents.isLaunchNote(output) && call.map(Subagents.isBackground) == true
            // So does a command started in the background (or one Claude Code already said it moved there), unless its
            // end came in first.
            let command = !isError && call.map { BackgroundCommands.asksBackground($0) || $0.background == true } == true
            let ended = call.map { $0.background == true && $0.state != .running } == true
            let state: RunEvent.State = isError ? .failed : (background || command ? .running : .done)
            feed(id, .toolUpdated(id: callID, output: output, state: ended ? (call?.state ?? .done) : state))
            if command, let call, call.background != true { mutateEvent(id, call.id) { $0.background = true } }
        case .backgroundTask(let update):
            noteBackgroundTask(id, update)
        case .goal(let update):
            noteGoal(id, update)
        case .subagentStep(let parent, let step):
            noteSubagentStep(id, parent: parent, step)
        case .usage(let messageID, let tokens, let model):
            if let ttl = tokens.cacheTTL { turns[id]?.cacheTTL = ttl }
            turns[id]?.messageUsage[messageID] = tokens
            turns[id]?.lastContext = tokens.context + tokens.output
            askContextWindowIfUnknown(id)
            if let model, !model.isEmpty, run(id)?.resolvedModel == nil { update(id) { $0.resolvedModel = model } }
        case .permissionRequest(let requestID, let tool, let input, let suggestions, _, let ask):
            pauseLive(id)
            // A question is answered, not approved: the answers go back as the tool's input.
            if tool == "AskUserQuestion" {
                let items = ClaudeStreamParser.questions(from: input)
                if !items.isEmpty {
                    let pending = PendingQuestion(id: requestID, runID: id, questions: items,
                                                  origin: .claude(requestID: requestID, input: input), created: Date())
                    questions[id, default: []].append(pending)
                    update(id) { $0.move(to: .waitingApproval) }
                    asked(id, pending)
                    return
                }
            }
            // In Plan mode the plan becomes a card with "Carry out"; Claude Code waits for your word instead of leaving plan mode.
            if tool == "ExitPlanMode", run(id)?.mode == .plan {
                let plan = ((input.dictionary["plan"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !plan.isEmpty { append(id, RunEvent(kind: .assistant, text: plan, tool: "plan", state: .done)) }
                processes[id]?.send(ClaudeStreamParser.permissionResponse(
                    requestID: requestID, allow: false, input: input,
                    message: "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."))
                return
            }
            // Rights you raised after Claude Code started (or that it could not take over live) still count.
            if let run = run(id), LiveRights.coversClaude(tool: tool, permission: run.permission, mode: run.mode) {
                processes[id]?.send(ClaudeStreamParser.permissionResponse(requestID: requestID, allow: true, input: input))
                return
            }
            let summary = ToolSummary.describe(tool: tool, input: input.dictionary)
            let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID,
                                 detail: ToolSummary.json(input.object), state: .pending)
            append(id, event)
            let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: input,
                                            suggestions: suggestions, eventID: event.id, created: Date(), ask: ask)
            approvals[id, default: []].append(pending)
            update(id) { $0.move(to: .waitingApproval) }
            if let run = run(id) { onApproval?(run, pending) }
        case .elicitation(let question):
            // A form with fields or a page to open: declined at once, so Claude Code and the server do not wait on it.
            guard question.isConfirmation else {
                processes[id]?.send(ClaudeStreamParser.elicitationResponse(requestID: question.requestID, accept: false))
                append(id, RunEvent(kind: .system, text: tr("ws.elicitation.declined", question.server.isEmpty ? "MCP" : question.server)))
                return
            }
            pauseLive(id)
            // No "Always": Claude Code keeps no standing answer to a server's question.
            presentMcpRequest(id, requestID: ClaudeElicitation.pendingPrefix + question.requestID, server: question.server,
                              tool: question.title, message: question.message, arguments: [:], suggestions: nil)
        case .result(let result):
            pauseLive(id)
            // A steering message cut this segment short: the turn goes on with the new message.
            if turns[id]?.steered == true, turns[id]?.stopping != true, result.endedBySteer {
                turns[id]?.steeredUsage.append(result.usage)
                // A thinking block the steer cut off gets no complete copy: start the pairing afresh.
                turns[id]?.timeline.forgetPendingCopies()
                return
            }
            turns[id]?.steered = false
            // Stopped by a usage limit: remember when it resets, for "Resume at reset".
            if turns[id]?.stopping != true {
                let evidence = FailureEvidence(terminalReason: result.terminalReason, apiErrorStatus: result.apiErrorStatus,
                                               isError: result.isError, rateLimitRejected: !(turns[id]?.limitWindows.isEmpty ?? true),
                                               rateLimitResets: turns[id]?.limitWindows ?? [:], messageText: result.text)
                if case .usageLimit(let resetAt) = FailureClassifier.classify(evidence), result.isError { limitedTurns[id] = .some(resetAt) }
            }
            var usage = result.usage
            let state = turns[id]
            // If turn completion reported no tokens, sum up individual message counts.
            if (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0) == 0, let messages = state?.messageUsage, !messages.isEmpty {
                usage.inputTokens = messages.values.reduce(0) { $0 + $1.input }
                usage.outputTokens = messages.values.reduce(0) { $0 + $1.output }
                usage.cacheReadTokens = messages.values.reduce(0) { $0 + $1.cacheRead }
                usage.cacheWriteTokens = messages.values.reduce(0) { $0 + $1.cacheWrite }
            }
            usage.contextTokens = state?.lastContext
            if usage.durationSeconds == nil, let started = state?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = state?.stopping ?? false
            update(id) { run in
                for segment in state?.steeredUsage ?? [] { run.usage.add(segment) }
                run.usage.add(usage)
                if let cache = Self.promptCache(after: state, previous: run.promptCache) { run.promptCache = cache }
                if let session = result.sessionID { run.providerSessionID = session }
                if stopping {
                    run.move(to: .stopped)
                } else if result.isError {
                    run.move(to: .failed, detail: result.text.isEmpty ? result.subtype : result.text)
                } else {
                    run.move(to: .completed)
                }
            }
            if let session = result.sessionID { noteConversationSession(id, session, keepsHistory: true) }
            if result.isError && !stopping {
                // Claude Code writes an API error as an answer first, then again as the result: show it once, as the error.
                let failure = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !failure.isEmpty, let echoed = state?.timeline.lastTextID,
                   events[id]?.last(where: { $0.id == echoed })?.text.trimmingCharacters(in: .whitespacesAndNewlines) == failure {
                    mutateEvent(id, echoed) { $0.kind = .error; $0.text = result.text; $0.state = nil }
                } else {
                    append(id, RunEvent(kind: .error, text: result.text.isEmpty ? tr("ws.event.failed", result.subtype) : result.text))
                }
            }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: result.permissionDenials),
                                state: result.isError && !stopping ? .failed : .done))
            expireApprovals(id)
            questions[id] = nil
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
            // Turn finished: keep Claude Code waiting for the next message instead of closing it.
            parkClaudeProcess(id, stopping: stopping)
        case .notice(let text):
            if text == "compact" { compactionFinished(id) }
        case .compaction(let phase):
            // Claude Code reports a compaction it gave up for your Stop as failed: that is stopped, not an error.
            if case .failed = phase, turns[id]?.stopping == true {
                compactionFailed(id, message: nil)
            } else {
                noteCompaction(id, phase)
            }
        case .rateLimits(let event):
            onRateLimits?()
            if let event { noteClaudeLimit(id, event) }
        case .planWindow(let reading):
            if let run = run(id) { onPlanWindow?(reading, run.profileID) }
        case .promptSuggestion(let text):
            offerAgentPrompt(id, text)
        }
    }
}
