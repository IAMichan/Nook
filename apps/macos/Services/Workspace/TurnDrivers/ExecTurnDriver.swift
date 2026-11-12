import Foundation

/// The agents that take the prompt as an argument and end on a signal: `codex exec` (Codex without a usable app-server)
/// and Gemini CLI's headless mode (its fallback when ACP fails). Nothing reaches them on stdin during a turn.
struct ExecTurnDriver: ProcessTurnDriver {
    unowned let workspace: WorkspaceManager

    func interruptRequest() -> String? { nil }

    func answer(requestID: String, _ pending: PendingPermission, _ decision: WorkspaceManager.Decision,
                reason: String) -> (line: String, notesReason: Bool) {
        (WorkspaceManager.streamJSONPermissionResponse(requestID: requestID, pending, decision, reason: reason), true)
    }
}

extension WorkspaceManager {
    func handleGemini(_ event: GeminiStreamEvent, id: UUID) {
        switch event {
        case .initialized(let session, let model):
            update(id) {
                $0.providerSessionID = session
                if let model, !model.isEmpty { $0.resolvedModel = model }
            }
        case .text(let text, let delta):
            feed(id, delta ? .textDelta(text) : .text(text))
        case .toolUse(let callID, let name, let input):
            feed(id, .toolStarted(AgentToolCall(id: callID, name: name, title: ToolSummary.describe(tool: name, input: input.dictionary),
                                                detail: ToolSummary.json(input.object), input: input)))
        case .toolResult(let callID, let output, let isError):
            feed(id, .toolUpdated(id: callID, output: output, state: isError ? .failed : .done))
        case .warning(let message):
            append(id, RunEvent(kind: .system, text: message))
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        case .result(let isError, let message, var usage):
            pauseLive(id)
            if usage.durationSeconds == nil, let started = turns[id]?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = turns[id]?.stopping ?? false
            update(id) { run in
                run.usage.add(usage)
                if stopping {
                    run.move(to: .stopped)
                } else if isError {
                    run.move(to: .failed, detail: message)
                } else {
                    run.move(to: .completed)
                }
            }
            if isError && !stopping { append(id, RunEvent(kind: .error, text: message ?? tr("ws.event.failed", "error"))) }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: isError && !stopping ? .failed : .done))
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
        }
    }

    func handleCodex(_ event: CodexStreamEvent, id: UUID) {
        switch event {
        case .threadStarted(let thread):
            update(id) { $0.providerSessionID = thread }
        case .message(let text):
            feed(id, .text(text))
        case .reasoning(let text):
            feed(id, .thinking(text))
        case .commandStarted(let callID, let command):
            feed(id, .toolStarted(Self.codexCommand(callID, command)))
        case .commandFinished(let callID, let command, let output, let exitCode):
            var call = Self.codexCommand(callID, command)
            call.output = output
            call.state = (exitCode ?? 0) != 0 ? .failed : .done
            feed(id, .toolFinished(call))
        case .fileChanges(_, let changes):
            for change in changes { recordFileChange(id, path: change.path, kind: change.kind) }
        case .toolCall(let callID, let name, let detail, let finished, let failed, let input, let output):
            let call = AgentToolCall(id: callID, name: name, title: detail.isEmpty ? name : "\(name) · \(detail)",
                                     detail: input.map { ToolSummary.json($0.object) }, input: input, output: output,
                                     state: finished ? (failed ? .failed : .done) : .running)
            feed(id, finished ? .toolFinished(call) : .toolStarted(call))
        case .turnCompleted(var usage):
            pauseLive(id)
            if let started = turns[id]?.started { usage.durationSeconds = Date().timeIntervalSince(started) }
            turns[id]?.finished = true
            let stopping = turns[id]?.stopping ?? false
            update(id) { run in
                run.usage.add(usage)
                run.move(to: stopping ? .stopped : .completed)
            }
            append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: .done))
            turnDidFinish(id)
            scheduleGitRefresh(id, delay: 0.5)
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        case .usageLimited:
            limitedTurns[id] = .some(nil)
        default:
            // Events only `codex app-server` sends: live text, reasoning, output, usage, the end of a turn.
            handleCodexServerEvent(event, id: id)
        }
    }
}
