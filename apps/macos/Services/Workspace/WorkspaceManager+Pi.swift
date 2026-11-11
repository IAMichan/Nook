import Foundation

// Pi sessions: one `pi --mode rpc` process per turn (see `PiRPC`, `AgentCommand.piSpec`), resumed from Pi's session file.
extension WorkspaceManager {
    /// Applies one event of Pi's output to the session.
    func handlePi(_ event: PiStreamEvent, id: UUID) {
        // Anything but the older end-of-run event shows the run goes on (a retry, a compaction, a queued message).
        if event != .ended { turns[id]?.piEndedAt = nil }
        switch event {
        case .session(let file, let model, let window):
            update(id) {
                if let file, !file.isEmpty { $0.providerSessionID = file }
                if let model, !model.isEmpty { $0.resolvedModel = model }
            }
            if let window { turns[id]?.contextWindow = window }
        case .started:
            break
        case .userMessage(let text):
            // Pi took a message of yours into the conversation: a steer it had not read yet is read now.
            steerEchoed(id, text: text)
        case .textDelta(let text):
            feed(id, .textDelta(text))
        case .text(let text):
            feed(id, .text(text))
        case .thinkingDelta(let text):
            feed(id, .thinkingDelta(text))
        case .thinking(let text):
            feed(id, .thinking(text))
        case .toolStarted(let callID, let name, let input):
            feed(id, .toolStarted(AgentToolCall(id: callID, name: name, title: ToolSummary.describe(tool: name, input: input.dictionary),
                                                detail: ToolSummary.json(input.object), input: input)))
        case .toolUpdated(let callID, let output):
            feed(id, .toolUpdated(id: callID, output: output, state: .running))
        case .toolFinished(let callID, _, let output, let isError):
            feed(id, .toolUpdated(id: callID, output: output.isEmpty ? nil : output, state: isError ? .failed : .done))
        case .usage(let usage):
            guard var state = turns[id] else { break }
            state.piUsage.add(usage, contextWindow: state.contextWindow)
            turns[id] = state
        case .confirm(let requestID, let title, let message):
            requestPiApproval(id, requestID: requestID, title: title, message: message)
        case .dialog(let requestID, let question):
            // An extension asks something: the same question panel as every agent's questions, in place of the composer.
            pauseLive(id)
            let pending = PendingQuestion(id: "pidialog-" + requestID, runID: id, questions: [question],
                                          origin: .pi(requestID: requestID), created: Date())
            guard !(questions[id] ?? []).contains(where: { $0.id == pending.id }) else { break }
            questions[id, default: []].append(pending)
            update(id) { $0.move(to: .waitingApproval) }
            asked(id, pending)
        case .notice(let message):
            append(id, RunEvent(kind: .system, text: message))
        case .compactionStarted:
            compactionStarted(id)
        case .compactionEnded(let failed):
            // An aborted compaction (`failed` empty) is stopped, not an error.
            if let failed { compactionFailed(id, message: failed.isEmpty ? nil : failed) } else { compactionFinished(id) }
        case .retrying(let reason):
            append(id, RunEvent(kind: .system, text: reason.isEmpty ? tr("pi.event.retrying") : reason))
        case .failed(let message):
            turns[id]?.lastError = message
            append(id, RunEvent(kind: .error, text: message))
        case .commandDone(_, let error):
            // `compact` answered without a run behind it: this turn is over.
            if let error { turns[id]?.lastError = error; append(id, RunEvent(kind: .error, text: error)) }
            finishPiTurn(id)
        case .settled:
            finishPiTurn(id)
        case .ended:
            // A Pi that has no `agent_settled` says nothing more: settle if nothing else came in a moment.
            let marker = Date()
            turns[id]?.piEndedAt = marker
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.turns[id]?.piEndedAt == marker else { return }
                self.finishPiTurn(id)
            }
        }
    }

    private func requestPiApproval(_ id: UUID, requestID: String, title: String, message: String) {
        pauseLive(id)
        let tool = title.hasPrefix("Allow ") ? String(title.dropFirst(6).dropLast(title.hasSuffix("?") ? 1 : 0)) : title
        let input = JSONBox(["detail": message])
        let summary = message.isEmpty ? title : title + "\n" + String(message.prefix(300))
        let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID, detail: message, state: .pending)
        append(id, event)
        let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: input,
                                        suggestions: nil, eventID: event.id, created: Date())
        approvals[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        if let run = run(id) { onApproval?(run, pending) }
    }

    /// The turn is over: its usage and result are recorded and Pi's input closes so the process ends.
    private func finishPiTurn(_ id: UUID) {
        guard let state = turns[id], !state.finished else { return }
        pauseLive(id)
        var usage = state.piUsage
        usage.durationSeconds = Date().timeIntervalSince(state.started)
        turns[id]?.finished = true
        turns[id]?.piEndedAt = nil
        let failed = state.lastError != nil && !state.stopping
        let stopping = state.stopping
        update(id) { run in
            run.usage.add(usage)
            if stopping {
                run.move(to: .stopped)
            } else if failed {
                run.move(to: .failed, detail: state.lastError)
            } else {
                run.move(to: .completed)
            }
        }
        append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0), state: failed ? .failed : .done))
        processes[id]?.closeInput()
        turnDidFinish(id)
        scheduleGitRefresh(id, delay: 0.5)
    }
}
