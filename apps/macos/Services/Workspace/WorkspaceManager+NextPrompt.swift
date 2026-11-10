import Foundation

/// The suggested next prompt (`NextPromptSuggestion`): after a turn of any agent ends, the message you will likely send
/// next, written by the generator chosen for it and shown as ghost text in the empty composer. Built from Nook's own
/// timeline, so every agent gets it the same way. The composer on screen asks for it; nothing runs while idle.
extension WorkspaceManager {
    /// The suggestion to show in a session's composer now, if any.
    func nextPrompt(_ id: UUID) -> String? {
        nextPrompts[id]?.shown(for: NextPromptSuggestion.turnKey(timeline(id)))
    }

    /// The session's composer is on screen: writes a suggestion for its finished turn when the gate allows it.
    func requestNextPrompt(_ id: UUID, composerEmpty: Bool) {
        let events = timeline(id)
        guard let run = run(id), let reply = NextPromptSuggestion.lastReply(events) else { return }
        let turn = reply.id
        let gate = NextPromptSuggestion.Gate(
            enabled: settings.suggestNextPrompt, turnCompleted: run.status == .completed, composerEmpty: composerEmpty,
            holds: !(approvals[id]?.isEmpty ?? true) || !(questions[id]?.isEmpty ?? true) || !(queued[id]?.isEmpty ?? true),
            delegated: run.delegation != nil, alreadyTried: nextPrompts[id]?.turn == turn,
            stale: Date().timeIntervalSince(reply.date) > NextPromptSuggestion.Gate.freshFor)
        guard gate.allows else { return }
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
                                                 cwd: run.isRemote ? NSHomeDirectory() : run.workingDirectory, timeout: 60)
            guard !Task.isCancelled, self.nextPrompts[id]?.turn == turn, self.nextPrompts[id]?.phase == .writing else { return }
            self.nextPromptTasks[id] = nil
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
