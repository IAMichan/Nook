import Foundation

/// The models each agent offers, asked: Codex lists them over app-server (`model/list`, page by
/// page), Grok names them in its `initialize` reply, and the other ACP agents report them when a session opens.
/// The lists are kept on disk, so the menus show the agent's own models from the start.
extension WorkspaceManager {
    private static let modelRefreshSeconds: TimeInterval = 5 * 60
    static var modelStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("agent-models.json")
    }

    func learnModels(_ provider: RunProvider, _ models: [AgentModel]) {
        // ACP agents you added share one kind but not their models: a list from one would be wrong for the next.
        guard provider != .acp, !models.isEmpty, agentModels[provider] != models else { return }
        agentModels[provider] = models
        AgentModelStore(url: Self.modelStoreURL).save(agentModels)
    }

    /// Asks the connected agents for their models, at most every five minutes per agent.
    func refreshAgentModels(_ accounts: [(provider: RunProvider, profileID: String)]) {
        for (provider, profileID) in accounts where provider == .codex || provider == .grok {
            if let last = modelsRefreshed[provider], Date().timeIntervalSince(last) < Self.modelRefreshSeconds { continue }
            guard let executable = executable(provider) else { continue }
            modelsRefreshed[provider] = Date()
            let environment = accountEnvironment(profileID)
            if provider == .codex {
                probeCodexModels(executable, environment: environment)
            } else {
                probeAcpModels(provider, executable, environment: environment)
            }
        }
    }

    private func probeCodexModels(_ executable: String, environment: [String: String]) {
        let spec = LaunchSpec(executable: executable, arguments: ["app-server"], extraEnvironment: environment,
                              workingDirectory: NSHomeDirectory(), initialInput: [], keepsInputOpen: true)
        let client = CodexAppServerClient(spec: spec)
        do { try client.start() } catch { return }
        var collected: [AgentModel] = []
        func page(_ cursor: String?) {
            client.request("model/list", cursor.map { ["cursor": $0] } ?? [:]) { [weak self] result in
                guard case .success(let response) = result else { return client.stop() }
                let parsed = AgentModelCatalog.codexPage(response.dictionary)
                collected += parsed.models
                if let next = parsed.next, collected.count < 500 { return page(next) }
                client.stop()
                let models = collected
                Task { @MainActor in self?.learnModels(.codex, models) }
            }
        }
        client.request("initialize", CodexRPC.initializeParams()) { result in
            guard case .success = result else { return client.stop() }
            client.notify("initialized")
            page(nil)
        }
        closeProbe(after: 30) { client.stop() }
    }

    /// Only `initialize`: never `authenticate` or `session/new`.
    private func probeAcpModels(_ provider: RunProvider, _ executable: String, environment: [String: String]) {
        let spec = LaunchSpec(executable: executable, arguments: AcpLaunch.arguments(provider, permission: .ask),
                              extraEnvironment: environment, workingDirectory: NSHomeDirectory(), initialInput: [], keepsInputOpen: true)
        let client = AcpClient(spec: spec)
        do { try client.start() } catch { return }
        client.request("initialize", AcpRPC.initializeParams()) { [weak self] result in
            client.stop()
            guard case .success(let response) = result else { return }
            let models = AgentModelCatalog.acp(response.dictionary)
            Task { @MainActor in self?.learnModels(provider, models) }
        }
        closeProbe(after: 20) { client.stop() }
    }

    private func closeProbe(after seconds: UInt64, _ stop: @escaping @Sendable () -> Void) {
        Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            stop()
        }
    }
}
