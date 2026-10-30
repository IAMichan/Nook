import SwiftUI

/// Shows which model Nook thinks with, and whether that is on this Mac or with an external service.
/// Opens the agents' own picker (`AgentModelPicker`): "On your Mac" first, then the connected agents Nook can think
/// through (once per account, with the agents' model names), then the AI services with a key. Switching happens right
/// here; adding one (a key) still happens in Settings › Brain.
struct BrainChip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var servers: [ServerModel] = []

    /// The maker's mark for a local model: from the model's own name ("Qwen 3"), else its server.
    private var localLogo: BrandLogo? {
        if settings.useLocal { return BrandLogo.forName(settings.brainLabel) }
        return BrandLogo.forName(settings.activeProviderModel) ?? BrandLogo.forProvider(settings.provider)
    }

    var body: some View {
        ModelPickerDropdown {
            if settings.isLocalBrain {
                ComposerPill(symbol: localLogo == nil ? "cpu" : nil, brand: localLogo, text: settings.brainLabel)
            } else if let agent = BrainPicker.agent(of: settings.provider, app: app) {
                // As the agents' pill: agent, account, model.
                let profile = app.profiles.brainProfile(agent.kind)
                let model = settings.activeProviderModel.isEmpty ? nil
                    : app.modelMenuName(settings.activeProviderModel, for: agent, profileID: profile.id)
                ComposerPill(agent: agent.displayName, account: AccountKind.of(profile, app: app),
                             text: [agent.displayName, AccountLabel.name(profile, app: app), model].compactMap { $0 }
                                .joined(separator: " · "),
                             short: model ?? agent.displayName)
            } else {
                ComposerPill(agent: BrainPicker.shortTitle(settings.provider),
                             account: BrainPicker.account(of: settings.provider, app: app), text: settings.brainLabel,
                             short: settings.activeProviderModel.isEmpty ? nil : settings.activeProviderModel)
            }
        } content: {
            BrainPicker(servers: servers)
        }
        .help(tr("brain.chip.help"))
        .task { servers = await app.localServerModels() }
    }
}

/// The panel behind the brain chip.
private struct BrainPicker: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var local = EmbeddedModel.shared
    /// Favorites live with the agents' (`WorkspaceSettings`): a star redraws the menu at once.
    @ObservedObject private var ws = WorkspaceSettings.shared
    let servers: [ServerModel]
    @State private var fetched: [AIProvider: [String]] = [:]
    @State private var fetching = false
    @State private var fetchError: String?

    private static let macID = "mac"

    /// External services that can answer right now: a key is saved, or the coding agent of a subscription is installed.
    private var externals: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard !provider.isLocalServer else { return false }
            if provider.isSubscription { return SubscriptionBrain.executable(provider) != nil }
            return settings.hasKey(for: provider)
        }
    }

    private var macPlace: ModelPickerPlace {
        ModelPickerPlace(id: Self.macID, name: tr("brain.chip.installed"), detail: tr("brain.chip.localDetail"), isLocal: true)
    }

    private func place(_ provider: AIProvider) -> ModelPickerPlace {
        ModelPickerPlace(id: provider.rawValue, name: Self.shortTitle(provider), account: Self.account(of: provider, app: app))
    }

    /// The connected agents Nook can think through with their own login.
    private var agents: [RunProvider] {
        app.connectedProviders.filter { agent in
            AIProvider.subscription(for: agent.kind).map { SubscriptionBrain.executable($0) != nil } ?? false
        }
    }

    /// The agent the brain thinks through now, nil for this Mac or a service with a key.
    static func agent(of provider: AIProvider, app: AppModel) -> RunProvider? {
        guard let kind = provider.subscriptionAgent else { return nil }
        return app.connectedProviders.first { $0.kind == kind }
    }

    var body: some View {
        let agents = agents
        let current = settings.isLocalBrain ? nil : Self.agent(of: settings.provider, app: app).flatMap { agents.contains($0) ? $0 : nil }
        // Services with a key, and subscriptions whose agent Nook does not run (Kimi Code, Mistral Vibe).
        let services = externals.filter { provider in !agents.contains { $0.kind == provider.subscriptionAgent } }
        AgentModelPicker(providers: agents, provider: current ?? agents.first ?? .claude,
                         profileID: current.map { app.profiles.brainProfile($0.kind).id },
                         model: current == nil ? "" : settings.activeProviderModel, showsAccounts: true,
                         extraPlaces: [macPlace] + services.map(place),
                         chosenExtra: current != nil ? nil : (settings.isLocalBrain ? macPlace : place(settings.provider)),
                         extraList: { shown, query in
                             if let provider = AIProvider(rawValue: shown.id) { return externalModels(provider, query: query) }
                             return macModels(query: query)
                         },
                         addHelp: tr("brain.chip.addExternal"), settingsTitle: tr("brain.chip.settings"),
                         settingsSection: .brain) { agent, profileID, model in
            guard let provider = AIProvider.subscription(for: agent.kind) else { return }
            if let profileID, let profile = app.profiles.profile(id: profileID) { app.profiles.setBrainProfile(profile) }
            settings.selection = BrainSelection(runtime: .external, provider: provider,
                                                model: model ?? settings.providerModel(for: provider))
            // The agent's own default model: the selection keeps the one before it.
            if model == "" { settings.setProviderModel("") }
        }
    }

    /// How a service is reached: through your account (personal or work) for a subscription, else an API key.
    /// Tells apart the two marks of one maker in the rail (Claude Code and the Claude API, ChatGPT and the OpenAI API…).
    static func account(of provider: AIProvider, app: AppModel) -> AccountKind {
        guard let kind = provider.subscriptionAgent else { return .apiKey }
        return AccountKind.of(app.profiles.brainProfile(kind), app: app)
    }

    // MARK: On this Mac

    private func macModels(query: String) -> ModelPickerList {
        var models: [ModelPickerItem] = []
        if AppleIntelligence.isAvailable, ModelSearch.matches(query, AppleModel.title) {
            models.append(item(AppleModel.id, title: AppleModel.title, brand: BrandLogo.forName("Apple"), place: Self.macID,
                               chosen: settings.useLocal && settings.localModel == AppleModel.id) {
                settings.selection = BrainSelection(runtime: .mlx, provider: settings.provider, model: AppleModel.id)
            })
        }
        for option in ModelAdvisor.catalog where local.installed.contains(option.id) && ModelSearch.matches(query, option.title) {
            models.append(item(option.id, title: option.title, brand: BrandLogo.forName(option.title) ?? BrandLogo.forName(option.id),
                               place: Self.macID, chosen: settings.useLocal && settings.localModel == option.id) {
                settings.selection = BrainSelection(runtime: .mlx, provider: settings.provider, model: option.id)
            })
        }
        for model in servers where ModelSearch.matches(query, model.name) {
            let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
            models.append(item(model.name, title: model.name, brand: BrandLogo.forName(model.name) ?? BrandLogo.forProvider(provider),
                               trailing: Self.shortTitle(provider), place: Self.macID,
                               chosen: !settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name) {
                settings.selection = BrainSelection(runtime: model.server == .ollama ? .ollama : .lmstudio,
                                                    provider: provider, model: model.name)
            })
        }
        let nothingInstalled = !AppleIntelligence.isAvailable && servers.isEmpty
            && !ModelAdvisor.catalog.contains { local.installed.contains($0.id) }
        return ModelPickerList(models: favoritesFirst(models, place: Self.macID),
                               emptyNote: nothingInstalled ? tr("brain.chip.noLocal") : nil)
    }

    // MARK: External

    private func externalModels(_ provider: AIProvider, query: String) -> ModelPickerList {
        let list = models(for: provider)
        let models = list.filter { ModelSearch.matches(query, $0) }.map { id in
            item(id, title: id, brand: BrandLogo.forName(id) ?? BrandLogo.forProvider(provider), place: provider.rawValue,
                 chosen: !settings.isLocalBrain && settings.provider == provider && settings.activeProviderModel == id) {
                settings.selection = BrainSelection(runtime: .external, provider: provider, model: id)
            }
        }
        var actions: [ModelPickerItem] = []
        // The search text as a model id of your own, when no listed model goes by that name.
        if let custom = ModelPreferences.customID(query), !list.contains(where: { $0.caseInsensitiveCompare(custom) == .orderedSame }) {
            actions.append(ModelPickerItem(id: "custom:" + custom, title: tr("compose.useModel", custom), symbol: "plus",
                                           detail: tr("compose.useModelDetail")) {
                settings.selection = BrainSelection(runtime: .external, provider: provider, model: custom)
            })
        }
        if !provider.isSubscription && fetched[provider] == nil {
            actions.append(ModelPickerItem(id: "fetch", title: tr("button.fetchModels"),
                                           symbol: fetching ? "hourglass" : "arrow.clockwise", detail: fetchError,
                                           staysOpen: true) {
                Task { await fetchModels(provider) }
            })
        }
        return ModelPickerList(models: favoritesFirst(models, place: provider.rawValue), actions: actions)
    }

    /// The models to offer for a service: the one it uses now, then the fetched list or the well-known ones.
    private func models(for provider: AIProvider) -> [String] {
        let chosen = settings.providerModel(for: provider)
        var list = fetched[provider] ?? provider.suggestedModels
        if !chosen.isEmpty, !list.contains(chosen) { list.insert(chosen, at: 0) }
        return list
    }

    private func fetchModels(_ provider: AIProvider) async {
        guard !fetching else { return }
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let list = try await provider.listModels(key: settings.key(for: provider))
            fetched[provider] = list.isEmpty ? nil : list
            if list.isEmpty { fetchError = tr("settings.brain.noModelsFound") }
        } catch {
            fetchError = error.localizedDescription
        }
    }

    // MARK: Rows

    /// A model row, with the star the agents' rows have.
    private func item(_ id: String, title: String, brand: BrandLogo?, trailing: String? = nil, place: String, chosen: Bool,
                      pick: @escaping () -> Void) -> ModelPickerItem {
        let key = Self.favoritesKey(place)
        let favorite = Binding(get: { ws.favoriteModels(forKey: key).contains(id) },
                               set: { if $0 != ws.favoriteModels(forKey: key).contains(id) { ws.toggleFavoriteModel(id, forKey: key) } })
        return ModelPickerItem(id: id, title: title, brand: brand, trailing: trailing, chosen: chosen, favorite: favorite, pick: pick)
    }

    /// Favorites on top, as in the agents' lists; otherwise the order stays.
    private func favoritesFirst(_ items: [ModelPickerItem], place: String) -> [ModelPickerItem] {
        let favorites = ws.favoriteModels(forKey: Self.favoritesKey(place))
        return items.filter { favorites.contains($0.id) } + items.filter { !favorites.contains($0.id) }
    }

    private static func favoritesKey(_ place: String) -> String { "brain.\(place)" }

    /// "Claude Code" instead of "Claude Code (je abonnement)", "Ollama" instead of "Ollama (op je Mac)".
    static func shortTitle(_ provider: AIProvider) -> String {
        provider.title.components(separatedBy: " (").first ?? provider.title
    }
}
