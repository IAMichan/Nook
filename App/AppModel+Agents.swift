import AppKit

/// Controlling agents from the Agents tab, without a terminal: continue or take over a running session, resume an
/// earlier one, end a process, and start new sessions. Nook runs Claude Code and Codex itself (headless, as workspace
/// sessions), so every conversation can be continued here, with approvals, stop, and settings in the tab.
extension AppModel {
    /// The headless agent Nook can run for this kind, if it is installed.
    func nookProvider(for kind: AgentKind?) -> RunProvider? {
        guard let kind, let provider = RunProvider(kind: kind), history.executables[kind] != nil else { return nil }
        return provider
    }

    /// The agent's own conversation id for a running session: from its hooks, or for a session Nook only sees as a
    /// process, the most recent transcript of that agent in the same folder.
    func conversationID(for session: AgentSession) -> String? {
        if !session.isDetected {
            if !session.sessionID.isEmpty { return session.sessionID }
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

    /// Can Nook continue this running session's conversation itself?
    func canTakeOver(_ session: AgentSession) -> Bool {
        nookProvider(for: AgentKind(agentName: session.name)) != nil && !session.cwd.isEmpty && conversationID(for: session) != nil
    }

    func canEnd(_ session: AgentSession) -> Bool {
        hub.processID(for: session) != nil
    }

    func canContinueInNook(_ session: PastSession) -> Bool {
        nookProvider(for: session.agent) != nil && !session.cwd.isEmpty
    }

    /// Continues a session that runs in a terminal (or ran there) in Nook.
    /// - By default the terminal session is left alone. A Claude Code session that still runs, or is busy, is copied
    ///   (`--fork-session`), so the original keeps working undisturbed and Nook continues in the copy; an idle one that
    ///   Nook knows only from hooks continues as is.
    /// - `endingTerminal`: only when asked for explicitly: ends the original process first and continues the same
    ///   conversation here.
    @discardableResult
    func continueInNook(_ session: AgentSession, message: String? = nil, endingTerminal: Bool = false) async throws -> UUID {
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
            guard provider == .claude else { throw NookError(tr("agents.nook.codexBusy")) }
            fork = true
        }
        let profile = self.profile(for: session) ?? profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind)
        var earlier: [(kind: RunEvent.Kind, text: String)] = []
        if !session.lastPrompt.isEmpty { earlier.append((kind: .user, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { earlier.append((kind: .assistant, text: session.lastReply)) }
        let id = try await workspace.adopt(provider: provider, sessionID: conversation, profileID: profile.id,
                                           directory: session.cwd, title: session.lastPrompt.isEmpty ? session.project : session.lastPrompt,
                                           history: earlier, fork: fork)
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.send(id, text: message) }
        viewModel.selectedAgentID = "run:" + id.uuidString
        return id
    }

    /// Resumes an earlier session in Nook, optionally with a first message.
    @discardableResult
    func continueInNook(_ session: PastSession, message: String? = nil) async throws -> UUID {
        guard let provider = nookProvider(for: session.agent) else {
            throw NookError(tr("agents.nook.unsupported", session.agent.name))
        }
        guard FileManager.default.fileExists(atPath: session.cwd) else {
            throw NookError(tr("agents.nook.folderGone", session.cwd))
        }
        let profile = self.profile(for: session) ?? profiles.preferredProfile(session.agent)
        var earlier: [(kind: RunEvent.Kind, text: String)] = []
        if !session.lastPrompt.isEmpty { earlier.append((kind: .user, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { earlier.append((kind: .assistant, text: session.lastReply)) }
        let id = try await workspace.adopt(provider: provider, sessionID: session.sessionID, profileID: profile.id,
                                           directory: session.cwd, title: session.title, history: earlier)
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.send(id, text: message) }
        viewModel.selectedAgentID = "run:" + id.uuidString
        return id
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
