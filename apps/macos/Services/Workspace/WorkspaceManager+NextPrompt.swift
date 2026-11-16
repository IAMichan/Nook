import Foundation

/// The suggested next prompt (`NextPromptSuggestion`): after a turn of any agent ends, the message you will likely send
/// next, shown as ghost text in the empty composer. The agent writes it itself where it can (`PromptSuggestionSource`):
/// Claude Code sends one after each turn, Codex is asked on its own thread; every other agent, and an agent that cannot
/// or stays silent, gets one from the generator chosen for it, built from Nook's own timeline. The composer on screen
/// asks for it.
extension WorkspaceManager {
    /// The suggestion to show in a session's composer now, if any.
    func nextPrompt(_ id: UUID) -> String? {
        nextPrompts[id]?.shown(for: NextPromptSuggestion.turnKey(timeline(id)))
    }

    /// What decides whether a suggestion can be written: the composer asks again whenever it changes, so one is written
    /// when the turn's last reply lands after the status flipped, and when an approval, question or queued message clears.
    struct NextPromptTrigger: Equatable {
        var status: RunStatus?
        var turn: UUID?
        var holds: Bool
    }

    func nextPromptTrigger(_ id: UUID) -> NextPromptTrigger {
        NextPromptTrigger(status: run(id)?.status, turn: NextPromptSuggestion.turnKey(timeline(id)), holds: nextPromptHolds(id))
    }

    private func nextPromptHolds(_ id: UUID) -> Bool {
        !(approvals[id]?.isEmpty ?? true) || !(questions[id]?.isEmpty ?? true) || !(queued[id]?.isEmpty ?? true)
    }

    /// The session's composer is on screen: writes a suggestion for its finished turn when the gate allows it.
    func requestNextPrompt(_ id: UUID, composerEmpty: Bool) {
        let events = timeline(id)
        guard let run = run(id), let reply = NextPromptSuggestion.lastReply(events) else { return }
        let turn = reply.id
        let gate = NextPromptSuggestion.Gate(
            enabled: settings.suggestNextPrompt, turnCompleted: run.status == .completed, composerEmpty: composerEmpty,
            holds: nextPromptHolds(id),
            delegated: run.delegation != nil, alreadyTried: nextPrompts[id]?.turn == turn,
            stale: Date().timeIntervalSince(reply.date) > NextPromptSuggestion.Gate.freshFor)
        guard gate.allows else { return }
        switch run.provider.capabilities.promptSuggestions {
        case .threadSample:
            if let client = codexServers[id], client.isRunning, let thread = client.threadID, let lastTurn = client.lastTurnID {
                nextPrompts[id] = NextPromptState(turn: turn, phase: .writing)
                sampleCodexNextPrompt(id, client, thread: thread, turnID: lastTurn, turn: turn)
                return
            }
        case .agentStream, .generator:
            // Claude Code sends its own after the turn (`offerAgentPrompt`), but often none at all: it skips early
            // conversations, a cold cache, plan mode, a plan near its limit, and whatever its own filters drop, and it
            // never says so. Waiting for it first made a suggestion take 8–10 s, so the generator (~3 s) starts at once:
            // the agent's own still takes over while the generator writes, and stops it.
            break
        }
        writeNextPrompt(id, run: run, events: events, turn: turn)
    }

    /// Claude Code's own prediction (`prompt_suggestion`), which arrives after its turn ended: shown for that turn unless
    /// the generator was quicker, you already typed, took or dismissed one, or the session is not waiting for you.
    func offerAgentPrompt(_ id: UUID, _ text: String) {
        guard settings.suggestNextPrompt, let run = run(id), run.status == .completed, run.delegation == nil,
              let turn = NextPromptSuggestion.turnKey(timeline(id)) else { return }
        if let state = nextPrompts[id], state.turn == turn, state.phase != .writing { return }
        // Nothing usable: the generator's fallback (`requestNextPrompt`) still writes one.
        guard let text = NextPromptSuggestion.clean(text) else { return }
        nextPromptTasks.removeValue(forKey: id)?.cancel()
        nextPrompts[id] = NextPromptState(turn: turn, phase: .ready(text))
    }

    /// Codex app-server's `thread/sample`: the thread itself predicts the message, as t3code asks it. A Codex that does not
    /// know the call, a thread that moved on, or one that predicts nothing leaves it to the generator.
    private func sampleCodexNextPrompt(_ id: UUID, _ client: CodexAppServerClient, thread: String, turnID: String, turn: UUID) {
        client.request("thread/sample", CodexRPC.sampleParams(threadID: thread, turnID: turnID,
                                                              prompt: NextPromptSuggestion.agentInstruction)) { [weak self] result in
            Task { @MainActor in
                guard let self, self.nextPrompts[id]?.turn == turn, self.nextPrompts[id]?.phase == .writing else { return }
                if case .success(let reply) = result,
                   let text = (reply.dictionary["text"] as? String).flatMap(NextPromptSuggestion.clean) {
                    self.nextPrompts[id] = NextPromptState(turn: turn, phase: .ready(text))
                } else if let run = self.run(id) {
                    // Failed or empty: the thread said nothing, so the generator writes it, as for Claude Code.
                    self.writeNextPrompt(id, run: run, events: self.timeline(id), turn: turn)
                }
            }
        }
    }

    /// The generator chosen in Settings writes it from the timeline; on the agent route a Claude Code session's own
    /// model writes it, at low effort (`NextPromptSuggestion.agentModel`).
    private func writeNextPrompt(_ id: UUID, run: WorkspaceRun, events: [RunEvent], turn: UUID, retry: Bool = true) {
        guard let prompt = NextPromptSuggestion.prompt(NextPromptSuggestion.messages(events)) else {
            nextPrompts[id] = NextPromptState(turn: turn, phase: .done)
            return
        }
        nextPrompts[id] = NextPromptState(turn: turn, phase: .writing)
        nextPromptTasks[id]?.cancel()
        nextPromptTasks[id] = Task { [weak self] in
            guard let self else { return }
            let answer = await self.generateText(prompt, schema: NextPromptSuggestion.schema, task: .nextPrompt,
                                                 prefer: run.provider, profileID: run.profileID,
                                                 cwd: run.isRemote ? NSHomeDirectory() : run.workingDirectory,
                                                 model: NextPromptSuggestion.agentModel(run),
                                                 effort: NextPromptSuggestion.agentEffort, timeout: 60)
            guard !Task.isCancelled, self.nextPrompts[id]?.turn == turn, self.nextPrompts[id]?.phase == .writing else { return }
            self.nextPromptTasks[id] = nil
            // The request failed (a timeout, a busy generator): one more try before the turn goes without.
            if answer == nil, retry {
                self.writeNextPrompt(id, run: run, events: events, turn: turn, retry: false)
                return
            }
            let text = (answer?["prompt"] as? String).flatMap(NextPromptSuggestion.clean)
            self.nextPrompts[id] = NextPromptState(turn: turn, phase: text.map { .ready($0) } ?? .done)
        }
    }

    /// You typed, took the suggestion or dismissed it: no suggestion for this turn any more, and no request left running.
    func dismissNextPrompt(_ id: UUID) {
        nextPromptTasks.removeValue(forKey: id)?.cancel()
        guard let state = nextPrompts[id], state.phase != .done else { return }
        nextPrompts[id] = NextPromptState(turn: state.turn, phase: .done)
    }

    /// A turn starts, or the session goes: its suggestion and request are dropped.
    func dropNextPrompt(_ id: UUID) {
        nextPromptTasks.removeValue(forKey: id)?.cancel()
        if nextPrompts[id] != nil { nextPrompts[id] = nil }
    }
}
