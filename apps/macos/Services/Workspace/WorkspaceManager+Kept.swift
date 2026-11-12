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

    /// The sessions as quitting sees them (`KeptRuns`).
    var keptCandidates: [KeptRuns.Candidate] {
        runs.map { run in
            KeptRuns.Candidate(id: run.id, status: run.status, hasKeeper: run.kept != nil,
                               keeperRunning: keptProcess(run.id) != nil,
                               waitsForYou: !(approvals[run.id] ?? []).isEmpty || !(questions[run.id] ?? []).isEmpty)
        }
    }

    /// Quitting: lets go of the agents at work. The sessions that stay running.
    func detachKeptRuns() -> Set<UUID> {
        var kept: Set<UUID> = []
        for candidate in keptCandidates where candidate.hasKeeper {
            guard KeptRuns.onQuit(candidate, enabled: settings.keepSessionsRunning) == .keep,
                  let process = keptProcess(candidate.id) else {
                update(candidate.id) { $0.kept = nil }
                continue
            }
            let id = candidate.id
            let turn = codexServers[id]?.turnID
            process.detach()
            processes[id] = nil
            codexServers[id] = nil
            acpClients[id] = nil
            update(id) {
                $0.kept?.offset = process.handledOffset
                $0.kept?.turnID = turn
            }
            kept.insert(id)
        }
        return kept
    }

    /// The launch: takes up what still runs. What is gone counts as cut off by the restart, as without a keeper.
    func reattachKeptRuns() {
        for run in runs where run.kept != nil {
            guard let kept = run.kept else { continue }
            let folder = NookPaths.keeperDirectory.appendingPathComponent(kept.folder)
            let spool = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("out").path))?[.size] as? UInt64
            // After a crash no offset was saved at quit: the progress written while it ran says how far Nook got.
            let progress = kept.offset == nil ? KeptRuns.readProgress(folder: folder) : nil
            let plan = KeptRuns.onLaunch(status: run.status, hasKeeper: true, keeperAlive: KeptTransport.isAlive(folder: folder),
                                         savedOffset: kept.offset, progress: progress?.offset, spoolSize: spool)
            guard case .attach(let offset) = plan else {
                keptAgentGone(run)
                continue
            }
            if let progress, let spool, offset < spool {
                // What the crashed Nook may already have shown is read again: it takes the place of what is there.
                if events[run.id] == nil { installTimeline(run.id, store.loadEvents(run.id)) }
                keptReplays[run.id] = KeptRuns.Replay(timeline: events[run.id] ?? [], since: progress.savedAt, until: spool)
            }
            let placement = KeeperPlacement(folder: folder.path, script: "", offset: offset)
            let spec = LaunchSpec(executable: "", arguments: [], extraEnvironment: [:], workingDirectory: NSHomeDirectory(),
                                  initialInput: [], keepsInputOpen: true, keeper: placement)
            turns[run.id] = TurnState()
            let attached: Bool
            switch run.provider {
            case .claude, .pi: attached = reattachClaude(run.id, spec, run.provider)
            case .codex: attached = reattachCodex(run, kept, spec)
            case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: attached = reattachAcp(run, spec)
            }
            guard attached else {
                turns[run.id] = nil
                keptReplays[run.id] = nil
                keptAgentGone(run)
                continue
            }
            update(run.id) { $0.kept?.offset = nil }
            append(run.id, RunEvent(kind: .system, text: tr("ws.event.kept")))
        }
    }

    /// A kept agent's progress is not written past a request that waits for you (`AgentProcess.holdForRequest`): after a
    /// crash its output is read again from there, the agent (which still waits too) asks again, and you can answer it.
    func syncKeptHold(_ id: UUID) {
        guard let process = keptProcess(id) else { return }
        if !(approvals[id] ?? []).isEmpty || waitsOnQuestion(id) {
            process.holdForRequest()
        } else {
            process.releaseHold()
        }
    }

    /// The turn ended: the next progress write of a kept agent goes in at once.
    func keptTurnEnded(_ id: UUID) {
        keptProcess(id)?.writeProgressSoon()
        keptReplays[id] = nil
    }

    /// An event read again after a crash (`KeptRuns.Replay`) takes the place of the one already in the timeline. True when
    /// it did, and the caller appends nothing.
    func replaceReplayed(_ id: UUID, _ event: RunEvent) -> Bool {
        guard keptReplays[id] != nil else { return false }
        if let process = keptProcess(id), process.handledOffset >= keptReplays[id]!.until { return false }
        guard let existing = keptReplays[id]!.match(event) else { return false }
        mutateEvent(id, existing) { old in
            let kept = (old.id, old.date)
            old = event
            old.id = kept.0
            old.date = kept.1
        }
        return true
    }

    /// Keepers that still answer, by folder name: what Settings shows.
    func liveKeepers() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NookPaths.keeperDirectory.path)) ?? []
        return names.filter { KeptTransport.isAlive(folder: NookPaths.keeperDirectory.appendingPathComponent($0)) }.sorted()
    }

    /// Stops the keepers no session claims (Settings), and returns how many.
    @discardableResult
    func stopOrphanKeepers() -> Int {
        let claimed = Set(runs.compactMap(\.kept?.folder))
        let orphans = KeptRuns.orphans(folders: liveKeepers(), claimed: claimed)
        for name in orphans { KeptTransport.stop(folder: NookPaths.keeperDirectory.appendingPathComponent(name)) }
        return orphans.count
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

    private func reattachClaude(_ id: UUID, _ spec: LaunchSpec, _ provider: RunProvider) -> Bool {
        let process = AgentProcess(spec: spec)
        bindTurn(process, id, provider: provider)
        guard (try? process.start()) != nil else { return false }
        processes[id] = process
        return true
    }

    private func reattachCodex(_ run: WorkspaceRun, _ kept: KeptSession, _ spec: LaunchSpec) -> Bool {
        let id = run.id
        let client = CodexAppServerClient(spec: spec)
        client.onMessage = { [weak self] message, events in
            let start = client.process.batchStart
            let end = client.process.consumed
            Task { @MainActor in
                client.process.beginHandling(from: start)
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
            let start = client.process.batchStart
            let end = client.process.consumed
            Task { @MainActor in
                client.process.beginHandling(from: start)
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
