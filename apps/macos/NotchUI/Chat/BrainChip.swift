import SwiftUI

/// Shows which model Nook thinks with, and whether that is on this Mac or with an agent.
/// Opens the agents' own picker (`AgentModelPicker`), the same rail of agents and accounts with the same model rows; the
/// one difference is "On your Mac" in front of them. A service with an API key is set up in Settings › Brain.
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
            pill
        } content: {
            BrainPicker(servers: servers)
        }
        .help(tr("brain.chip.help"))
        .task { servers = await app.localServerModels() }
    }

    /// The agent's pill as the agents' composer draws it ("Claude Code · Work · Claude Opus 5.5"), else the brain's label.
    @ViewBuilder
    private var pill: some View {
        if let kind = settings.provider.subscriptionAgent, let agent = RunProvider(kind: kind), !settings.isLocalBrain {
            let profile = app.profiles.preferredProfile(kind)
            let model = settings.activeProviderModel
            let name = model.isEmpty ? nil : app.modelMenuName(model, for: agent, profileID: profile.id)
            ComposerPill(agent: agent.displayName, account: AccountTag.of(profile, app: app),
                         text: [agent.displayName, AccountLabel.name(profile, app: app), name].compactMap { $0 }.joined(separator: " · "),
                         short: name ?? agent.displayName)
        } else if settings.isLocalBrain {
            ComposerPill(symbol: localLogo == nil ? "cpu" : nil, brand: localLogo, text: settings.brainLabel)
        } else {
            ComposerPill(agent: BrainPicker.shortTitle(settings.provider), account: .apiKey, text: settings.brainLabel,
                         short: settings.activeProviderModel.isEmpty ? nil : settings.activeProviderModel)
        }
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

    private static let macID = "mac"

    /// The brain that thinks through an agent: Claude Code, Codex, Gemini CLI and Grok. OpenCode, Cursor, Antigravity and
    /// ACP agents have no such brain, so they stay out of this rail.
    private static func brain(for agent: RunProvider) -> AIProvider? {
        AIProvider.allCases.first { $0.subscriptionAgent.flatMap(RunProvider.init(kind:)) == agent }
    }

    /// The agent in use, when Nook thinks through one.
    private var agentInUse: (provider: RunProvider, kind: AgentKind)? {
        guard !settings.isLocalBrain, let kind = settings.provider.subscriptionAgent, let agent = RunProvider(kind: kind) else { return nil }
        return (agent, kind)
    }

    private var macPlace: ModelPickerPlace {
        ModelPickerPlace(id: Self.macID, name: tr("brain.chip.installed"), detail: tr("brain.chip.localDetail"), isLocal: true)
    }

    var body: some View {
        let agents = app.connectedProviders.filter { Self.brain(for: $0) != nil }
        let inUse = agentInUse
        AgentModelPicker(providers: agents, provider: inUse?.provider ?? agents.first ?? .claude,
                         profileID: inUse.map { app.profiles.preferredProfile($0.kind).id },
                         model: inUse == nil ? "" : settings.activeProviderModel,
                         local: ModelPickerLocal(place: macPlace, chosen: inUse == nil, list: macModels),
                         offersAuto: false) { agent, accountID, model in
            guard let provider = Self.brain(for: agent) else { return }
            // The brain thinks under the agent's preferred account: another account becomes that one.
            if let accountID, let profile = app.profiles.profile(id: accountID) { app.profiles.setPreferred(profile) }
            settings.selection = BrainSelection(runtime: .external, provider: provider,
                                                model: model ?? settings.providerModel(for: provider))
        }
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
