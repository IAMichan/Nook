import AppKit

/// An agent, account and model picked in the composer of a session Nook does not run yet. Sending continues the
/// conversation in Nook with this choice.
struct AgentChoice: Equatable {
    var provider: RunProvider
    var profileID: String
    var model: String
}

/// Controlling agents from the Agents tab, without a terminal: continue or take over a running session, resume an
/// earlier one, end a process, and start new sessions. Nook runs Claude Code and Codex itself (headless, as workspace
/// sessions), so every conversation can be continued here, with approvals, stop, and settings in the tab.
extension AppModel {
    /// The headless agent Nook can run for this kind, if it is installed.
    func nookProvider(for kind: AgentKind?) -> RunProvider? {
        // Antigravity's own conversations live in the Antigravity app (answered through agentapi); Nook's Antigravity
        // sessions run on the separate ACP server and cannot load them.
        guard let kind, kind != .antigravity, let provider = RunProvider(kind: kind), history.executables[kind] != nil else { return nil }
        return provider
    }

    /// The agent's own conversation id for a running session: from its hooks, or for a session Nook only sees as a
    /// process, the most recent transcript of that agent in the same folder.
    func conversationID(for session: AgentSession) -> String? {
        if !session.sessionID.isEmpty { return session.sessionID }
        if !session.isDetected {
            // The hub key is "<agent>:<session id>", with the folder as fallback when the agent sent no id.
            if let colon = session.id.firstIndex(of: ":") {
                let rest = String(session.id[session.id.index(after: colon)...])
                if !rest.isEmpty, rest != session.cwd { return rest }
            }
        }
        guard let kind = AgentKind(agentName: session.name), !session.cwd.isEmpty else { return nil }
        // The same agent and folder can run under another account: only a transcript of this session's own account counts.
        let account = profile(for: session)?.id
        return history.sessions.first { $0.agent == kind && $0.cwd == session.cwd && (account == nil || $0.profileID == account) }?.sessionID
    }

    /// You marked this chat as finished while it still read as busy (a turn that hangs): it is finished, not working.
    func isSettledWhileBusy(_ session: AgentSession) -> Bool {
        let key = FinishedSessions.key(agent: session.name, conversation: conversationID(for: session), fallback: session.id)
        return FinishedSessions.shared.isMarkedWhileBusy(key)
    }

    /// You marked this chat as finished.
    func isMarkedFinished(_ session: AgentSession) -> Bool {
        FinishedSessions.shared.contains(FinishedSessions.key(agent: session.name, conversation: conversationID(for: session), fallback: session.id))
    }

    /// Can Nook continue this running session's conversation itself?
    func canTakeOver(_ session: AgentSession) -> Bool {
        nookProvider(for: AgentKind(agentName: session.name)) != nil && !session.cwd.isEmpty && conversationID(for: session) != nil
    }

    /// Can Nook send a reply or follow-up message to this session (either directly or by adopting it)?
    func canReply(to session: AgentSession) -> Bool {
        if canTakeOver(session) { return true }
        if AgentKind(agentName: session.name) == .antigravity {
            return AntigravityClient.isAvailable && conversationID(for: session) != nil
        }
        return false
    }

    func canEnd(_ session: AgentSession) -> Bool {
        hub.processID(for: session) != nil
    }

    func canContinueInNook(_ session: PastSession) -> Bool {
        nookProvider(for: session.agent) != nil && !session.cwd.isEmpty
    }

    /// Can Nook resume or send a message to this past session?
    func canReply(to session: PastSession) -> Bool {
        if canContinueInNook(session) { return true }
        if session.agent == .antigravity {
            return AntigravityClient.isAvailable && !session.sessionID.isEmpty
        }
        return false
    }

    /// Sends a reply into an active agent session (or adopts it into Workspace if supported). `choice`: another agent,
    /// account or model picked in the composer; the conversation continues in Nook with that one.
    func reply(to session: AgentSession, message: String, choice: AgentChoice? = nil) async throws {
        if AgentKind(agentName: session.name) == .antigravity {
            guard let convID = conversationID(for: session) else {
                throw NookError(tr("agents.nook.noConversation"))
            }
            try await AntigravityClient.sendMessage(conversationID: convID, message: message)
            return
        }
        try await continueInNook(session, message: message, choice: choice)
    }

    /// Resumes an earlier session or sends a message to it.
    func reply(to session: PastSession, message: String, choice: AgentChoice? = nil) async throws {
        if session.agent == .antigravity {
            guard !session.sessionID.isEmpty else {
                throw NookError(tr("agents.nook.noConversation"))
            }
            try await AntigravityClient.sendMessage(conversationID: session.sessionID, message: message)
            return
        }
        try await continueInNook(session, message: message, choice: choice)
    }

    /// Continues a session that runs in a terminal (or ran there) in Nook.
    /// - By default the terminal session is left alone. A Claude Code session that still runs, or is busy, is copied
    ///   (`--fork-session`), so the original keeps working undisturbed and Nook continues in the copy; an idle one that
    ///   Nook knows only from hooks continues as is.
    /// - `endingTerminal`: only when asked for explicitly: ends the original process first and continues the same
    ///   conversation here.
    /// - `choice`: another agent, account or model to continue with (see `applyChoice`).
    @discardableResult
    func continueInNook(_ session: AgentSession, message: String? = nil, endingTerminal: Bool = false,
                        choice: AgentChoice? = nil) async throws -> UUID {
        guard let kind = AgentKind(agentName: session.name), let provider = nookProvider(for: kind) else {
            throw NookError(tr("agents.nook.unsupported", session.name))
        }
        guard let conversation = conversationID(for: session) else { throw NookError(tr("agents.nook.noConversation")) }
        let busy = !session.isDetected && (session.status == .running || session.status == .waiting)
        var fork = false
        if endingTerminal {
            guard hub.processID(for: session) != nil else { throw NookError(tr("agents.nook.processUnknown", session.name)) }
            guard hub.end(session) else { throw NookError(tr("agents.nook.endFailed", session.name)) }
            // Give the agent a moment to write the last of its conversation before Nook resumes it.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        } else if busy || session.isDetected {
            // The agent still runs in its terminal. Two processes must not write one conversation: continue in a copy.
            guard provider == .claude else { throw NookError(tr("agents.nook.busyElsewhere", session.name)) }
            fork = true
        }
        let profile = self.profile(for: session) ?? profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind)
        let path = session.transcriptPath.isEmpty
            ? (history.sessions.first { $0.isConversation(conversation) }?.path ?? "") : session.transcriptPath
        let earlier = await earlierConversation(path: path, prompt: session.lastPrompt, reply: session.lastReply)
        let id = try await workspace.adopt(provider: provider, sessionID: conversation, profileID: profile.id,
                                           directory: session.cwd, title: session.lastPrompt.isEmpty ? session.project : session.lastPrompt,
                                           history: earlier, fork: fork)
        try applyChoice(choice, to: id)
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.send(id, text: message) }
        viewModel.selectedAgentID = "run:" + id.uuidString
        return id
    }

    /// Resumes an earlier session in Nook, optionally with a first message.
    @discardableResult
    func continueInNook(_ session: PastSession, message: String? = nil, choice: AgentChoice? = nil) async throws -> UUID {
        guard let provider = nookProvider(for: session.agent) else {
            throw NookError(tr("agents.nook.unsupported", session.agent.name))
        }
        let folder = session.resumeFolder
        guard FileManager.default.fileExists(atPath: folder) else {
            throw NookError(tr("agents.nook.folderGone", folder))
        }
        let profile = self.profile(for: session) ?? profiles.preferredProfile(session.agent)
        let earlier = await earlierConversation(path: session.path, prompt: session.lastPrompt, reply: session.lastReply)
        let id = try await workspace.adopt(provider: provider, sessionID: session.sessionID, profileID: profile.id,
                                           directory: folder, title: session.title, history: earlier)
        try applyChoice(choice, to: id)
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.send(id, text: message) }
        viewModel.selectedAgentID = "run:" + id.uuidString
        return id
    }

    /// Moves a session Nook just took over to the agent, account or model picked in the composer: a model counts from
    /// the first turn, another agent or account starts from a summary of the conversation (see `applySelection`).
    private func applyChoice(_ choice: AgentChoice?, to id: UUID) throws {
        guard let choice else { return }
        if case .reject(let reason) = workspace.applySelection(id, provider: choice.provider, profileID: choice.profileID,
                                                               model: choice.model) {
            throw NookError(reason == "busy" ? tr("ws.error.busy") : tr("agents.switch.unavailable", choice.provider.displayName))
        }
    }

    /// The conversation so far, for a session Nook takes over: the whole transcript with the agent's thinking, or, when it
    /// cannot be read, the last prompt and reply.
    private func earlierConversation(path: String, prompt: String, reply: String) async -> [(kind: RunEvent.Kind, text: String)] {
        let messages = path.isEmpty ? [] : await Task.detached(priority: .userInitiated) { AgentTranscript.recent(path: path) }.value
        if !messages.isEmpty {
            // The steps and thinking without text are what happened, not what was said: the conversation goes along without them.
            return messages.compactMap { message -> (kind: RunEvent.Kind, text: String)? in
                switch message.kind {
                case .user: return (kind: .user, text: message.text)
                case .assistant: return (kind: .assistant, text: message.text)
                case .thinking: return message.text.isEmpty ? nil : (kind: .thinking, text: message.text)
                case .tools: return nil
                }
            }
        }
        var earlier: [(kind: RunEvent.Kind, text: String)] = []
        if !prompt.isEmpty { earlier.append((kind: .user, text: prompt)) }
        if !reply.isEmpty { earlier.append((kind: .assistant, text: reply)) }
        return earlier
    }

    /// Ends a running session's process (the agent saves its conversation, so it can be resumed in Nook afterwards).
    func endSession(_ session: AgentSession) throws {
        guard hub.end(session) else { throw NookError(tr("agents.nook.endFailed", session.name)) }
        history.refresh(minimumInterval: 0)
    }

    /// Starts a new session that Nook runs itself, in `folder`, with this account.
    @discardableResult
    func startInNook(_ profile: AgentProfile, folder: String, task: String, mode: ExecutionMode,
                     permission: PermissionPolicy, model: String) async throws -> UUID {
        guard let provider = nookProvider(for: profile.kind) else {
            throw NookError(tr("agents.nook.unsupported", profile.kind.name))
        }
        var config = NewRunConfig()
        config.task = task
        config.provider = provider
        config.profileID = profile.id
        config.model = model
        config.mode = mode
        config.permission = provider.capabilities.policies.contains(permission) ? permission : (provider.capabilities.policies.first ?? .acceptEdits)
        config.isolation = .folder
        config.projectPath = folder
        let id = try await workspace.start(config, allowSharedFolder: true)
        viewModel.selectedAgentID = "run:" + id.uuidString
        return id
    }

    /// Asks for a folder to start a session in.
    func chooseAgentFolder(_ kind: AgentKind) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("agents.nook.chooseHere")
        panel.message = tr("agents.nook.chooseMessage", kind.name)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
