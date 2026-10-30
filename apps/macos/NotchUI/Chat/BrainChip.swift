import SwiftUI

/// Shows which model Nook thinks with, and whether that is on this Mac or with an external service.
/// Opens Nook's own dropdown: on the left a rail with "On your Mac" and every external AI that is set up, on the right
/// its models. Switching to an external AI happens right here; adding one (a key) still happens in Settings › Brain.
struct BrainChip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var servers: [ServerModel] = []

    /// The maker's mark for the model in use: from the model's own name first ("claude-haiku", "Qwen 3"), else its provider.
    private var logo: BrandLogo? {
        if settings.useLocal {
            return BrandLogo.forName(settings.brainLabel)
        }
        return BrandLogo.forName(settings.activeProviderModel) ?? BrandLogo.forProvider(settings.provider)
    }

    var body: some View {
        ModelPickerDropdown {
            ComposerPill(symbol: logo == nil ? (settings.isLocalBrain ? "cpu" : "cloud") : nil, brand: logo, text: settings.brainLabel)
        } content: {
            BrainPicker(servers: servers)
        }
        .help(tr("brain.chip.help"))
        .task { servers = await app.localServerModels() }
    }
}

/// A place a brain can live: this Mac, or one external service.
private enum BrainPlace: Hashable {
    case mac
    case external(AIProvider)
}

/// The panel behind the brain chip.
private struct BrainPicker: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var local = EmbeddedModel.shared
    let servers: [ServerModel]
    @State private var query = ""
    @State private var fetched: [AIProvider: [String]] = [:]
    @State private var fetching = false
    @State private var fetchError: String?

    /// External services that can answer right now: a key is saved, or the coding agent of a subscription is installed.
    private var externals: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard !provider.isLocalServer else { return false }
            if provider.isSubscription { return SubscriptionBrain.executable(provider) != nil }
            return settings.hasKey(for: provider)
        }
    }

    private var active: BrainPlace { settings.isLocalBrain ? .mac : .external(settings.provider) }

    var body: some View {
        ModelPickerPanel(groups: [[BrainPlace.mac], externals.map(BrainPlace.external)], chosen: active,
                         help: Self.title(of:), addHelp: tr("brain.chip.addExternal"),
                         add: { app.openSettings(section: .brain) },
                         onShow: { _ in
                             query = ""
                             fetchError = nil
                         },
                         icon: placeIcon) { place in
            switch place {
            case .mac: macModels
            case .external(let provider): externalModels(provider)
            }
        }
    }

    // MARK: Rail

    @ViewBuilder
    private func placeIcon(_ place: BrainPlace) -> some View {
        switch place {
        case .mac:
            Image(systemName: "laptopcomputer")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.paper)
        case .external(let provider):
            BrandMark(logo: BrandLogo.forProvider(provider), size: 17)
                .accountBadge(account(of: provider), size: 17, ring: DropdownStyle.panel)
        }
    }

    /// How a service is reached: through your account (personal or work) for a subscription, else an API key.
    /// Tells apart the two marks of one maker in the rail (Claude Code and the Claude API, ChatGPT and the OpenAI API…).
    private func account(of provider: AIProvider) -> AccountKind {
        guard let kind = provider.subscriptionAgent else { return .apiKey }
        return AccountKind.of(app.profiles.preferredProfile(kind), app: app)
    }

    private static func title(of place: BrainPlace) -> String {
        switch place {
        case .mac: return tr("brain.chip.installed")
        case .external(let provider): return shortTitle(provider)
        }
    }

    // MARK: On this Mac

    private var macModels: some View {
        let apple = AppleIntelligence.isAvailable && matches(AppleModel.title)
        let installed = ModelAdvisor.catalog.filter { local.installed.contains($0.id) && matches($0.title) }
        let shownServers = servers.filter { matches($0.name) }
        return ModelPickerColumn(title: tr("brain.chip.installed"), detail: tr("brain.chip.localDetail"), query: $query,
                                 emptyNote: emptyMacNote(shown: apple || !installed.isEmpty || !shownServers.isEmpty),
                                 settingsTitle: tr("brain.chip.settings"),
                                 openSettings: { app.openSettings(section: .brain) }) {
            if apple {
                DropdownRow(brand: BrandLogo.forName("Apple"), title: AppleModel.title,
                            chosen: settings.useLocal && settings.localModel == AppleModel.id) {
                    settings.selection = BrainSelection(runtime: .mlx, provider: settings.provider, model: AppleModel.id)
                }
            }
            ForEach(installed) { option in
                DropdownRow(brand: BrandLogo.forName(option.title) ?? BrandLogo.forName(option.id),
                            title: option.title, chosen: settings.useLocal && settings.localModel == option.id) {
                    settings.selection = BrainSelection(runtime: .mlx, provider: settings.provider, model: option.id)
                }
            }
            ForEach(shownServers, id: \.name) { model in
                let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
                DropdownRow(brand: BrandLogo.forName(model.name) ?? BrandLogo.forProvider(provider), title: model.name,
                            trailing: Self.shortTitle(provider),
                            chosen: !settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name) {
                    settings.selection = BrainSelection(runtime: model.server == .ollama ? .ollama : .lmstudio,
                                                        provider: provider, model: model.name)
                }
            }
        }
    }

    /// Nothing on this Mac at all, or nothing that matches the search.
    private func emptyMacNote(shown: Bool) -> String? {
        guard !shown else { return nil }
        let nothingInstalled = !AppleIntelligence.isAvailable && servers.isEmpty
            && !ModelAdvisor.catalog.contains { local.installed.contains($0.id) }
        return nothingInstalled ? tr("brain.chip.noLocal") : tr("compose.noModels")
    }

    private func matches(_ name: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || name.lowercased().contains(needle)
    }

    // MARK: External

    private func externalModels(_ provider: AIProvider) -> some View {
        let shownModels = models(for: provider).filter(matches)
        return ModelPickerColumn(title: Self.shortTitle(provider), detail: tr("brain.chip.externalDetail", Self.shortTitle(provider)),
                                 query: $query, emptyNote: shownModels.isEmpty ? tr("compose.noModels") : nil,
                                 settingsTitle: tr("brain.chip.settings"),
                                 openSettings: { app.openSettings(section: .brain) }) {
            ForEach(shownModels, id: \.self) { id in
                DropdownRow(brand: BrandLogo.forName(id) ?? BrandLogo.forProvider(provider), title: id,
                            chosen: !settings.isLocalBrain && settings.provider == provider && settings.activeProviderModel == id) {
                    settings.selection = BrainSelection(runtime: .external, provider: provider, model: id)
                }
            }
            if !provider.isSubscription && fetched[provider] == nil {
                DropdownRow(symbol: fetching ? "hourglass" : "arrow.clockwise", title: tr("button.fetchModels"),
                            detail: fetchError, staysOpen: true) {
                    Task { await fetchModels(provider) }
                }
            }
        }
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

    /// "Claude Code" instead of "Claude Code (je abonnement)", "Ollama" instead of "Ollama (op je Mac)".
    static func shortTitle(_ provider: AIProvider) -> String {
        provider.title.components(separatedBy: " (").first ?? provider.title
    }
}
