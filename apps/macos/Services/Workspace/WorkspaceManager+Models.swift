import Foundation

/// The models each agent offers, asked of every agent outside a session, so a model released after Nook's build (and before
/// the model manifest names it) is in the menus as soon as the installed agent offers it: Claude Code lists them in the
/// reply to its `initialize` control request, Codex over app-server (`model/list`, page by page), Grok in its ACP
/// `initialize` reply, and the other ACP agents in a session Nook opens for it in an empty folder and removes again. Their
/// sessions report them too. The lists are kept on disk, so the menus show the agent's own models from the start.
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

    /// The effort levels to offer (see `AgentModelMenu.effortLevels`).
    func effortLevels(for provider: RunProvider, profileID: String? = nil, model: String?) -> [String] {
        modelMenu(for: provider, profileID: profileID).effortLevels(model: model)
    }

    /// How a level reads: Nook's word for a level it knows ("High"), else the agent's own name for it.
    func effortTitle(_ level: String?, for provider: RunProvider, profileID: String? = nil) -> String {
        if let key = AgentModelMenu.effortKey(level) { return tr(key) }
        return modelMenu(for: provider, profileID: profileID).effortName(level ?? "")
    }

    /// Asks the connected agents for their models, at most every five minutes per agent (an ACP agent you added: per
    /// agent, by its profile).
    func refreshAgentModels(_ accounts: [(provider: RunProvider, profileID: String)]) {
        for (provider, profileID) in accounts {
            let key = Self.effortKey(provider, profileID: profileID)
            if let last = modelsRefreshed[key], Date().timeIntervalSince(last) < Self.modelRefreshSeconds { continue }
            let environment = accountEnvironment(profileID)
            modelsRefreshed[key] = Date()
            switch provider {
            case .claude:
                guard let executable = executable(provider) else { continue }
                probeClaudeModels(executable, environment: environment)
            case .codex:
                guard let executable = executable(provider) else { continue }
                probeCodexModels(executable, environment: environment)
            case .gemini, .opencode, .cursor, .grok, .antigravity, .acp:
                probeAcpModels(provider, profileID: profileID)
            }
        }
    }

    /// Claude Code's `initialize` control request, outside a session (see `ClaudeControl`): its reply lists the models
    /// the installed version offers this account, a new one included before Nook's model manifest knows it.
    private func probeClaudeModels(_ executable: String, environment: [String: String]) {
        Task.detached(priority: .utility) { [weak self] in
            guard let reply = ClaudeControl.ask(["subtype": "initialize"], executable: executable, environment: environment,
                                                timeout: 30) else { return }
            let models = AgentModelCatalog.claude(reply)
            await self?.learnModels(.claude, models)
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

    /// What `initialize` names (Grok lists its models there); else, since the other ACP agents name them only in a session,
    /// a session opened for it in an empty folder of Nook's own (`NookPaths.modelProbeDirectory`), without Nook's tools,
    /// that is removed again (`session/delete`, else `session/close`) without a prompt: it costs no usage. Never
    /// `authenticate` with a sign-in page: an agent that needs you to sign in first is asked again later. Antigravity, which
    /// always authenticates, is asked only with the sign-in it saved.
    private func probeAcpModels(_ provider: RunProvider, profileID: String) {
        guard let client = startAcpProbe(provider, profileID: profileID, folder: NookPaths.modelProbeDirectory) else { return }
        let signIn = AcpModelProbe.signIn(provider, savedLogin: hasAntigravityLogin(profileID))
        let learn: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let models = AgentModelCatalog.acp(reply)
            let efforts = AcpSessionSettings.effortLevels(reply)
            Task { @MainActor in
                self?.learnModels(provider, models, profileID: profileID)
                self?.learnEfforts(provider, efforts, profileID: profileID)
            }
        }
        func openSession(_ capabilities: AcpSessionCapabilities) {
            let params = AcpRPC.sessionParams(cwd: NookPaths.modelProbeDirectory.path, bridge: nil, loadID: nil)
            client.request("session/new", params) { result in
                guard case .success(let response) = result else { return client.stop() }
                let reply = response.dictionary
                learn(reply)
                guard let session = reply["sessionId"] as? String, let method = AcpModelProbe.cleanup(capabilities) else {
                    return client.stop()
                }
                client.request(method, ["sessionId": session]) { _ in client.stop() }
            }
        }
        client.request("initialize", AcpRPC.initializeParams()) { result in
            guard case .success(let response) = result else { return client.stop() }
            let reply = response.dictionary
            let capabilities = AcpSessionCapabilities(initialize: reply)
            if !AgentModelCatalog.acp(reply).isEmpty {
                client.stop()
                return learn(reply)
            }
            switch signIn {
            case .direct:
                openSession(capabilities)
            case .skip:
                client.stop()
            case .savedLogin:
                client.request("authenticate", ["methodId": AntigravityAcp.authMethod]) { result in
                    guard case .success = result else { return client.stop() }
                    openSession(capabilities)
                }
            }
        }
        closeProbe(after: 45) { client.stop() }
    }

    /// Starts an ACP agent for a short question outside a session (its models, its sessions), with the command line a
    /// session of it uses: an agent you added runs its own, and Antigravity its own profile folder. Nil when it cannot
    /// start. It runs as Nook's own (`NOOK_INTERNAL`), so its hooks never show it as a session of yours.
    func startAcpProbe(_ provider: RunProvider, profileID: String, folder: URL? = nil) -> AcpClient? {
        guard let executable = executable(provider) else { return nil }
        var input = AgentCommand.Input(provider: provider, executable: executable, prompt: "", model: "", mode: .agent, permission: .ask,
                                       instructions: "", workingDirectory: folder?.path ?? NSHomeDirectory(), resumeSessionID: nil,
                                       accountEnvironment: accountEnvironment(profileID), runID: UUID())
        var prepared: [String: String] = [:]
        switch provider {
        case .acp:
            guard let agent = CustomAgents.agent(for: profileID) else { return nil }
            input.customAgent = agent
        case .antigravity:
            guard let environment = prepareAntigravity(profileID: profileID, executable: executable) else { return nil }
            prepared = environment
        case .claude, .codex, .gemini, .opencode, .cursor, .grok:
            break
        }
        var spec = AgentCommand.acpSpec(input)
        spec.extraEnvironment.merge(prepared) { $1 }
        if !prepared.isEmpty { spec.removedEnvironment = AntigravityAcp.removedEnvironment }
        spec.extraEnvironment["NOOK_INTERNAL"] = "1"
        let client = AcpClient(spec: spec)
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
        let probe = NookPaths.modelProbeDirectory.path
        func finish() {
            client.stop()
            let sessions = collected.filter { !AcpModelProbe.isProbe($0.cwd, folder: probe) }
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
