import Foundation

/// A turn that failed because the API refused the agent's version (`AgentVersionRejection`). For every agent the failed
/// turn's banner offers the update (`AgentRunPanel.recovery`); when a custom endpoint sits in between and the installed
/// version already meets the requirement, the failure says the endpoint rewrote the version instead, since updating
/// would change nothing.
extension WorkspaceManager {
    /// The explanation that replaces the failure's text, or nil to leave the text as the agent wrote it.
    func versionRejectionNote(_ run: WorkspaceRun) -> String? {
        guard !run.isRemote, let rejection = AgentVersionRejection.parse(run.statusDetail) else { return nil }
        let installed = agentVersions[run.provider]
        guard case .endpointRewrote(let host, let reported, let version) = AgentVersionRejection.verdict(
            rejection, installed: installed, endpointHost: endpointHost(run)) else { return nil }
        let agent = run.provider.displayName
        return tr("ws.versionRejected.endpoint", host, agent, reported, agent + " " + version)
    }

    /// The custom API endpoint the session's agent talks to: its account's variables first, then its own settings
    /// files, then Nook's environment (which the agent inherits).
    private func endpointHost(_ run: WorkspaceRun) -> String? {
        let account = accountEnvironment(run.profileID)
        var environments = [account]
        switch run.provider {
        case .claude:
            let files = ClaudeToolSearch.settingsFiles(workingDirectory: run.workingDirectory,
                                                        configDirectory: account["CLAUDE_CONFIG_DIR"])
            environments.append(AgentVersionRejection.settingsEnvironment(files))
        // Their endpoint lives in their environment only, or in a config Nook does not read (Codex's config.toml).
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
            break
        }
        environments.append(ProcessInfo.processInfo.environment)
        return AgentVersionRejection.endpointHost(run.provider, environments: environments)
    }
}
