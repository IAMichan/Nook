import Foundation

/// Updating the agents' programs from Settings › Agents (see `AgentUpdater`, `AgentUpdates`). An update runs a command on
/// this Mac, so it waits for your confirmation, which also names the sessions of that agent that are running; each one
/// is in the audit log. Afterwards the version is read again and the agent is asked again for its models.
extension AppModel {
    /// The agents that have a program to update, with its path.
    var updatableAgentPrograms: [(RunProvider, String)] {
        RunProvider.allCases.filter(AgentUpdates.updatable).compactMap { provider in
            workspace.executable(provider).map { (provider, $0) }
        }
    }

    /// Settings › Agents shows the list: who installed each program, its version and the newest one (looked up at most
    /// every half hour; `force` looks again now).
    func refreshAgentUpdates(force: Bool = false) {
        let programs = updatableAgentPrograms
        workspace.readAgentVersions(programs.map(\.0), every: true)
        AgentUpdater.shared.scan(programs, force: force)
    }

    /// Asks before updating: Settings › Agents opens on the question.
    /// Agents Nook has no command for (an app, an install it does not recognise) are left out; their row in Settings says
    /// how to update them.
    func requestAgentUpdate(_ providers: [RunProvider]) {
        refreshAgentUpdates()
        let runnable = providers.filter { AgentUpdater.shared.entries[$0]?.command != nil }
        if !runnable.isEmpty { AgentUpdater.shared.pending = runnable }
        openSettings(section: .agents)
    }

    /// The sessions of these agents that run now; an update may change the program under them.
    func activeSessions(of providers: [RunProvider]) -> [WorkspaceRun] {
        workspace.runs.filter { providers.contains($0.provider) && $0.status.isActive }
    }

    /// You confirmed: the updates run one after another, each in the audit log.
    func confirmAgentUpdate() {
        guard let providers = AgentUpdater.shared.pending else { return }
        AgentUpdater.shared.pending = nil
        let updater = AgentUpdater.shared
        for provider in providers {
            guard let command = updater.entries[provider]?.command else { continue }
            store.audit(tool: "agent_update", args: provider.displayName + ": " + command.display,
                        result: "started" + (activeSessions(of: [provider]).isEmpty ? "" : " (sessions running)"))
        }
        updater.update(providers)
    }

    /// Connects the updater to the audit log, the versions and the models. Run once at startup.
    func startAgentUpdates() {
        AgentUpdater.shared.onFinished = { [weak self] provider, ok, last in
            guard let self else { return }
            self.store.audit(tool: "agent_update", args: provider.displayName, result: (ok ? "updated" : "failed") + (last.isEmpty ? "" : ": " + last))
            self.workspace.agentWasUpdated(provider)
            self.refreshAgentModels()
            self.refreshAgentUpdates()
            if ok {
                ToastCenter.shared.success(tr("agentUpdate.done", provider.displayName))
            } else {
                ToastCenter.shared.error(tr("agentUpdate.failed", provider.displayName), detail: last.isEmpty ? nil : last)
            }
        }
    }
}
