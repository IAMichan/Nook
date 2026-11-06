import Foundation

/// A session's goal (see `SessionGoals`). Claude Code takes `/goal` as a message and answers in its output; Codex over
/// app-server takes it through calls of its own, outside and around its turns. An agent that only announces `/goal` as a
/// command gets it as a message, and reports nothing back.
extension WorkspaceManager {
    func noteGoal(_ id: UUID, _ goalUpdate: SessionGoalUpdate) {
        guard let run = run(id) else { return }
        let next = SessionGoals.apply(goalUpdate, to: run.goal)
        if next != run.goal { update(id) { $0.goal = next } }
    }

    /// Whether this session's agent takes a goal through calls instead of as a message.
    func takesGoalOutsideTurns(_ id: UUID) -> Bool {
        guard let run = run(id), let executable = launchExecutable(run) else { return false }
        return usesCodexServer(run, executable)
    }

    /// The goal strip's buttons: they work while the agent is at work too, where the agent allows that.
    func goalControl(_ id: UUID, _ command: SessionGoalCommand) {
        if takesGoalOutsideTurns(id) {
            switch command {
            case .show, .clear, .pause: runCodexGoalControl(id, command)
            case .resume, .set: submit(id, text: Self.goalText(command))
            }
        } else {
            submit(id, text: Self.goalText(command))
        }
    }

    private static func goalText(_ command: SessionGoalCommand) -> String {
        switch command {
        case .show: return "/goal"
        case .clear: return "/goal clear"
        case .pause: return "/goal pause"
        case .resume: return "/goal resume"
        case .set(let objective): return "/goal " + objective
        }
    }

    /// For a `/goal` message to Codex: nil when `message` is no goal command for a Codex over app-server, otherwise what the
    /// turn should say, with nil inside when the command needs no turn.
    func codexGoalTurn(_ id: UUID, message: String, executable: String) -> String?? {
        guard let run = run(id), usesCodexServer(run, executable), let command = SessionGoals.command(in: message) else { return nil }
        switch command {
        case .set(let objective):
            codexGoalStarting[id] = command
            return .some(SessionGoals.firstTurn(objective: objective))
        case .resume where run.goal != nil:
            codexGoalStarting[id] = command
            return .some(SessionGoals.resumeTurn)
        case .resume, .show, .clear, .pause:
            append(id, RunEvent(kind: .user, text: message))
            runCodexGoalControl(id, command == .resume ? .show : command)
            return .some(nil)
        }
    }

    /// Show, clear or pause: no turn needed. A session whose connection closed while idle connects first.
    private func runCodexGoalControl(_ id: UUID, _ command: SessionGoalCommand) {
        guard let run = run(id) else { return }
        if let client = codexServers[id], client.threadID != nil {
            performCodexGoalControl(id, client, command)
        } else if codexServers[id] != nil {
            // Still connecting: it runs once the thread is open, on that same server.
            codexGoalWaiting[id] = command
        } else if run.providerSessionID == nil {
            noteGoal(id, .cleared)
            if command == .show { append(id, RunEvent(kind: .system, text: tr("ws.goal.none"))) }
        } else if let executable = launchExecutable(run) {
            codexGoalWaiting[id] = command
            connectCodexServer(id, executable: executable, prompt: nil)
        }
    }

    /// The control that waited for the connection.
    func runWaitingGoalCommand(_ id: UUID, _ client: CodexAppServerClient) {
        guard let command = codexGoalWaiting.removeValue(forKey: id) else { return }
        performCodexGoalControl(id, client, command)
    }

    private func performCodexGoalControl(_ id: UUID, _ client: CodexAppServerClient, _ command: SessionGoalCommand) {
        guard let thread = client.threadID else { return }
        let method: String
        var params = CodexRPC.goalParams(threadID: thread)
        switch command {
        case .show: method = "thread/goal/get"
        case .clear: method = "thread/goal/clear"
        case .pause:
            method = "thread/goal/set"
            params = CodexRPC.goalParams(threadID: thread, status: .paused)
        case .resume, .set: return
        }
        client.request(method, params) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.append(id, RunEvent(kind: .error, text: tr("ws.goal.failed", error.localizedDescription)))
                case .success(let response):
                    if command == .clear { self.noteGoal(id, .cleared); return }
                    let reported = SessionGoals.codex(response.dictionary["goal"] as? [String: Any])
                    self.noteGoal(id, reported ?? .cleared)
                    if command == .show, reported == nil {
                        self.append(id, RunEvent(kind: .system, text: tr("ws.goal.none")))
                    }
                }
            }
        }
    }

    /// Before the first turn of a new goal: it is set paused, so Codex cannot start a turn of its own first.
    func prepareCodexGoal(_ id: UUID, _ client: CodexAppServerClient, thread: String, then done: @escaping @MainActor (String?) -> Void) {
        guard case .set(let objective)? = codexGoalStarting[id] else { done(nil); return }
        client.request("thread/goal/clear", CodexRPC.goalParams(threadID: thread)) { _ in
            client.request("thread/goal/set", CodexRPC.goalParams(threadID: thread, objective: objective, status: .paused)) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.codexGoalStarting[id] = nil
                        done(tr("ws.goal.failed", error.localizedDescription))
                    case .success(let response):
                        if let goal = SessionGoals.codex(response.dictionary["goal"] as? [String: Any]) { self.noteGoal(id, goal) }
                        done(nil)
                    }
                }
            }
        }
    }

    /// The goal's first turn is running, with this session's approvals and sandbox: from here on Codex carries on by itself.
    func activateCodexGoal(_ id: UUID, _ client: CodexAppServerClient, thread: String) {
        guard codexGoalStarting.removeValue(forKey: id) != nil else { return }
        client.request("thread/goal/set", CodexRPC.goalParams(threadID: thread, status: .active)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.append(id, RunEvent(kind: .error, text: tr("ws.goal.failed", error.localizedDescription)))
                case .success(let response):
                    if let goal = SessionGoals.codex(response.dictionary["goal"] as? [String: Any]) { self.noteGoal(id, goal) }
                }
            }
        }
    }
}
