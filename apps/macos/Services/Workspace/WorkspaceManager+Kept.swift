import Foundation

/// Agents that go on while Nook is away (see `SessionKeeper`). Quitting lets go of the ones at work; the next launch takes them
/// up again from where Nook read. A session that waits for you is not kept: what it asked went with Nook.
extension WorkspaceManager {
    /// The turn's process goes through a keeper when you asked for that.
    func keptWhenAsked(_ spec: LaunchSpec, _ run: WorkspaceRun) -> LaunchSpec {
        guard settings.keepSessionsRunning, let script = try? SessionKeeper.install() else { return spec }
        let name = String(run.id.uuidString.prefix(8)).lowercased() + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        try? FileManager.default.createDirectory(at: NookPaths.keeperDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var spec = spec
        spec.keeper = KeeperPlacement(folder: NookPaths.keeperDirectory.appendingPathComponent(name).path, script: script.path)
        update(run.id) { $0.kept = KeptSession(folder: name) }
        return spec
    }

    private func keptProcess(_ id: UUID) -> AgentProcess? {
        [processes[id], codexServers[id]?.process, acpClients[id]?.process].compactMap { $0 }.first { $0.isKept && $0.isRunning }
    }

    /// Quitting: lets go of the agents at work. The sessions that stay running.
    func detachKeptRuns() -> Set<UUID> {
        var kept: Set<UUID> = []
        for run in runs where run.kept != nil {
            let waiting = run.status != .running || !(approvals[run.id] ?? []).isEmpty || !(questions[run.id] ?? []).isEmpty
            guard settings.keepSessionsRunning, !waiting, let process = keptProcess(run.id) else {
                update(run.id) { $0.kept = nil }
                continue
            }
            let turn = codexServers[run.id]?.turnID
            process.detach()
            processes[run.id] = nil
            codexServers[run.id] = nil
            acpClients[run.id] = nil
            update(run.id) {
                $0.kept?.offset = process.handledOffset
                $0.kept?.turnID = turn
            }
            kept.insert(run.id)
        }
        return kept
    }

    /// The launch: takes up what still runs. What is gone counts as cut off by the restart, as without a keeper.
    func reattachKeptRuns() {
        for run in runs where run.kept != nil {
            guard let kept = run.kept else { continue }
            let folder = NookPaths.keeperDirectory.appendingPathComponent(kept.folder)
            guard run.status.isActive, KeptTransport.isAlive(folder: folder) else {
                keptAgentGone(run)
                continue
            }
            // After a crash Nook does not know how far it read: it goes on from now, so nothing shows twice.
            let spool = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("out").path))?[.size] as? UInt64
            let placement = KeeperPlacement(folder: folder.path, script: "", offset: kept.offset ?? spool ?? 0)
            let spec = LaunchSpec(executable: "", arguments: [], extraEnvironment: [:], workingDirectory: NSHomeDirectory(),
                                  initialInput: [], keepsInputOpen: true, keeper: placement)
            turns[run.id] = TurnState()
            let attached: Bool
            switch run.provider {
            case .claude: attached = reattachClaude(run.id, spec)
            case .codex: attached = reattachCodex(run, kept, spec)
            case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: attached = reattachAcp(run, spec)
            }
            guard attached else {
                turns[run.id] = nil
                keptAgentGone(run)
                continue
            }
            update(run.id) { $0.kept?.offset = nil }
            append(run.id, RunEvent(kind: .system, text: tr("ws.event.kept")))
        }
    }

    private func keptAgentGone(_ run: WorkspaceRun) {
        update(run.id) {
            $0.kept = nil
            guard $0.status.isActive else { return }
            $0.interruptedWhileWaiting = $0.status == .waitingApproval ? true : nil
            $0.status = $0.status.afterRelaunch
            $0.statusDetail = "interrupted"
            $0.turnStartedAt = nil
        }
    }

    private func reattachClaude(_ id: UUID, _ spec: LaunchSpec) -> Bool {
        let process = AgentProcess(spec: spec)
        bindTurn(process, id)
        guard (try? process.start()) != nil else { return false }
        processes[id] = process
        return true
    }

    private func reattachCodex(_ run: WorkspaceRun, _ kept: KeptSession, _ spec: LaunchSpec) -> Bool {
        let id = run.id
        let client = CodexAppServerClient(spec: spec)
        client.onMessage = { [weak self] message, events in
            let end = client.process.consumed
            Task { @MainActor in
                self?.handleCodexServer(id, client, message, events)
                client.process.markHandled(end)
            }
        }
        client.onExit = { [weak self] status, stderr in
            Task { @MainActor in
                self?.codexServerExited(id, client, status: status, stderr: stderr, prompt: "", executable: run.provider.kind.command)
            }
        }
        client.threadID = run.providerSessionID
        client.turnID = kept.turnID
        guard (try? client.start()) != nil else { return false }
        codexServers[id] = client
        return true
    }

    private func reattachAcp(_ run: WorkspaceRun, _ spec: LaunchSpec) -> Bool {
        let id = run.id
        let client = AcpClient(spec: spec)
        client.onMessage = { [weak self] message, events in
            let end = client.process.consumed
            Task { @MainActor in
                self?.handleAcp(id, client, message, events)
                client.process.markHandled(end)
            }
        }
        client.onOrphanAnswer = { [weak self] answer in
            Task { @MainActor in self?.acpKeptTurnEnded(id, answer) }
        }
        client.onExit = { [weak self] status, stderr in
            Task { @MainActor in
                self?.acpExited(id, client, status: status, stderr: stderr, prompt: "", executable: run.provider.kind.command)
            }
        }
        client.sessionID = run.providerSessionID
        guard (try? client.start()) != nil else { return false }
        acpClients[id] = client
        return true
    }
}
