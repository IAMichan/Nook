import Foundation

extension AppModel {
    /// Sessions you (or auto-settle) just settled: their idle terminals close, `stopOnSettle` scripts stop and
    /// `runOnSettle` scripts run, by the project's `nook.json` (`SettleActions`). Only on this Mac: a remote session's
    /// terminals and scripts are not Nook's to touch.
    func applySettleActions(_ items: [AgentListItem]) {
        for id in items.compactMap({ Self.runID($0.id) }) { workspace.settled(id) }
        let settledIDs = Set(items.map(\.id))
        let local = items.filter { item in
            guard !item.path.isEmpty else { return false }
            if let id = Self.runID(item.id) { return workspace.run(id)?.isRemote != true }
            return true
        }
        guard !local.isEmpty else { return }
        let open = openSessionFolders(excluding: settledIDs, settledKeys: Set(items.map(\.finishKey)))
        let targets = local.map { (folder: $0.path, ownWorktree: $0.worktree, name: $0.title) }
        Task { [weak self] in
            for target in targets {
                let folder = target.folder
                let scripts = await Task.detached(priority: .utility) { ProjectScripts.load(folder: folder) }.value
                guard let self else { return }
                self.applySettlePlan(folder: folder, ownWorktree: target.ownWorktree, scripts: scripts, openFolders: open)
            }
        }
    }

    private func applySettlePlan(folder: String, ownWorktree: Bool, scripts: [ProjectScript], openFolders: [String]) {
        let store = TerminalStore.shared
        let terminals = store.sessions.map {
            SettleActions.Terminal(id: $0.id, origin: $0.origin, command: $0.command, running: $0.running,
                                   idleAtPrompt: $0.idleAtPrompt)
        }
        let plan = SettleActions.plan(folder: folder, ownWorktree: ownWorktree, terminals: terminals, scripts: scripts,
                                      openFolders: openFolders)
        guard !plan.isEmpty else { return }
        for id in plan.stop { store.stop(id) }
        for id in plan.close { store.close(id) }
        for script in plan.run {
            store.openClosingOnSuccess(in: folder, command: SettleActions.cleanupCommand(script.command), title: script.name)
        }
        Log.agents.info("Settle actions in \(folder, privacy: .private): closed \(plan.close.count), stopped \(plan.stop.count), ran \(plan.run.count)")
    }

    /// The folders of the sessions on this Mac that have not settled (nor are being settled now): their terminals are
    /// theirs too.
    private func openSessionFolders(excluding ids: Set<String>, settledKeys: Set<String>) -> [String] {
        let finished = FinishedSessions.shared
        var folders: [String] = []
        for run in workspace.runs where !run.archived && !run.isRemote && !ids.contains("run:" + run.id.uuidString) {
            let key = FinishedSessions.key(run: run)
            if !finished.contains(key), !settledKeys.contains(key) { folders.append(run.workingDirectory) }
        }
        for session in hub.sessions where !ids.contains(session.id) && !session.cwd.isEmpty {
            let key = FinishedSessions.key(session: session)
            if !finished.contains(key), !settledKeys.contains(key) { folders.append(session.cwd) }
        }
        return folders
    }

    private static func runID(_ listID: String) -> UUID? {
        listID.hasPrefix("run:") ? UUID(uuidString: String(listID.dropFirst(4))) : nil
    }
}
