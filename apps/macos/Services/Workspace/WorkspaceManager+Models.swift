import Foundation

/// The models each agent offers, asked: Codex lists them over app-server (`model/list`, page by
/// page), Grok names them in its `initialize` reply, and the other ACP agents report them when a session opens.
/// The lists are kept on disk, so the menus show the agent's own models from the start.
extension WorkspaceManager {
    private static let modelRefreshSeconds: TimeInterval = 5 * 60
    static var modelStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("agent-models.json")
    }

    static var customModelStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("custom-agent-models.json")
    }
    static var effortStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("agent-efforts.json")
    }

    func learnModels(_ provider: RunProvider, _ models: [AgentModel], profileID: String? = nil) {
        guard !models.isEmpty else { return }
        // ACP agents you added share one kind but not their models: each keeps its own list, by its profile.
        if provider == .acp {
            guard let profileID, !profileID.isEmpty, customAgentModels[profileID] != models else { return }
            customAgentModels[profileID] = models
            AgentModelStore(url: Self.customModelStoreURL).saveRaw(customAgentModels)
            return
        }
        guard agentModels[provider] != models else { return }
        agentModels[provider] = models
        AgentModelStore(url: Self.modelStoreURL).save(agentModels)
    }

    /// The models an agent listed itself: an ACP agent you added by its profile, the others by kind.
    func offeredModels(_ provider: RunProvider, profileID: String? = nil) -> [AgentModel] {
        if provider == .acp { return profileID.flatMap { customAgentModels[$0] } ?? [] }
        return agentModels[provider] ?? []
    }

    /// Where an agent's thinking levels are kept: an ACP agent you added by its profile, the others by kind.
    static func effortKey(_ provider: RunProvider, profileID: String?) -> String {
        provider == .acp ? "acp:" + (profileID ?? "") : provider.rawValue
    }

    /// The thinking levels an ACP session offered (see `AcpSessionSettings.effortLevels`). An agent without them keeps
    /// what it had: one model can have levels where the next has none.
    func learnEfforts(_ provider: RunProvider, _ levels: [AgentModel], profileID: String? = nil) {
        let key = Self.effortKey(provider, profileID: profileID)
        guard !levels.isEmpty, agentEfforts[key] != levels else { return }
        agentEfforts[key] = levels
        AgentModelStore(url: Self.effortStoreURL).saveRaw(agentEfforts)
    }

    /// The effort levels to offer: Claude Code's and Codex's own, and for ACP agents the levels the agent offered.
    func effortLevels(for provider: RunProvider, profileID: String? = nil, model: String?) -> [String] {
        let offered = agentEfforts[Self.effortKey(provider, profileID: profileID)]?.map(\.id)
        return EffortLevels.levels(for: provider, model: model, advertised: offered)
    }

    /// How a level reads: Nook's word for a level it knows ("High"), else the agent's own name for it.
    func effortTitle(_ level: String?, for provider: RunProvider, profileID: String? = nil) -> String {
        guard let level, !EffortLevels.known.contains(level.lowercased()) else { return tr(EffortLevels.label(level?.lowercased())) }
        return agentEfforts[Self.effortKey(provider, profileID: profileID)]?.first { $0.id == level }?.name ?? level
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
                probeAcpModels(provider, profileID: profileID)
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
    private func probeAcpModels(_ provider: RunProvider, profileID: String) {
        guard let client = startAcpProbe(provider, profileID: profileID) else { return }
        client.request("initialize", AcpRPC.initializeParams()) { [weak self] result in
            client.stop()
            guard case .success(let response) = result else { return }
            let models = AgentModelCatalog.acp(response.dictionary)
            Task { @MainActor in self?.learnModels(provider, models, profileID: profileID) }
        }
        closeProbe(after: 20) { client.stop() }
    }

    /// Starts an ACP agent for a short question outside a session (its models, its sessions), with the command line a
    /// session of it uses: an agent you added runs its own. Nil when it cannot start. Antigravity, which needs its own
    /// profile folder first, is asked only in its sessions.
    func startAcpProbe(_ provider: RunProvider, profileID: String) -> AcpClient? {
        guard let executable = executable(provider) else { return nil }
        var input = AgentCommand.Input(provider: provider, executable: executable, prompt: "", model: "", mode: .agent, permission: .ask,
                                       instructions: "", workingDirectory: NSHomeDirectory(), resumeSessionID: nil,
                                       accountEnvironment: accountEnvironment(profileID), runID: UUID())
        if provider == .acp {
            guard let agent = CustomAgents.agent(for: profileID) else { return nil }
            input.customAgent = agent
        }
        let client = AcpClient(spec: AgentCommand.acpSpec(input))
        do { try client.start() } catch { return nil }
        return client
    }

    // MARK: Sessions the agent lists

    private static let sessionListSeconds: TimeInterval = 5 * 60
    private static let sessionListLimit = 300

    /// Asks an agent whose earlier sessions come from itself (`ProviderCapabilities.pastSessions`) for them over ACP
    /// `session/list`, at most every five minutes per account, page by page up to a few hundred. Calls `done` on the main
    /// actor with what it listed; not at all when the agent offers no list or cannot start.
    func listAgentSessions(_ provider: RunProvider, profileID: String, done: @escaping @MainActor ([AcpListedSession]) -> Void) {
        guard provider.capabilities.pastSessions == .agent, provider.usesACP else { return }
        let key = Self.effortKey(provider, profileID: profileID) + "|" + profileID
        if let last = sessionsListed[key], Date().timeIntervalSince(last) < Self.sessionListSeconds { return }
        guard let client = startAcpProbe(provider, profileID: profileID) else { return }
        sessionsListed[key] = Date()
        var collected: [AcpListedSession] = []
        func finish() {
            client.stop()
            let sessions = collected
            Task { @MainActor in done(sessions) }
        }
        func page(_ cursor: String?) {
            client.request("session/list", AcpRPC.listParams(cursor: cursor)) { result in
                guard case .success(let response) = result else { return finish() }
                let parsed = AcpListedSession.page(response.dictionary)
                collected += parsed.sessions
                if let next = parsed.next, collected.count < Self.sessionListLimit { return page(next) }
                finish()
            }
        }
        client.request("initialize", AcpRPC.initializeParams()) { result in
            guard case .success(let response) = result,
                  AcpSessionCapabilities(initialize: response.dictionary).list else { return client.stop() }
            page(nil)
        }
        closeProbe(after: 30) { client.stop() }
    }

    private func closeProbe(after seconds: UInt64, _ stop: @escaping @Sendable () -> Void) {
        Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            stop()
        }
    }
}
