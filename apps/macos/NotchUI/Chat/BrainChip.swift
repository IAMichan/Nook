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
        ComposerDropdown(width: 340, takesRoom: true) {
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
    @Environment(\.closeDropdown) private var close

    /// External services that can answer right now: a key is saved, or Claude Code is installed.
    private var externals: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard !provider.isLocalServer else { return false }
            if provider == .claudeCode { return ClaudeCodeBrain.executable != nil }
            return settings.hasKey(for: provider)
        }
    }

    private var active: BrainPlace { settings.isLocalBrain ? .mac : .external(settings.provider) }

    var body: some View {
        RailDropdown(groups: [[BrainPlace.mac], externals.map(BrainPlace.external)], chosen: active, maxHeight: 360,
                     help: Self.title(of:), onShow: { _ in
                         query = ""
                         fetchError = nil
                     },
                     icon: placeIcon, footer: { addButton }) { place in
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
        }
    }

    private var addButton: some View {
        Button {
            close()
            app.openSettings(section: .brain)
        } label: {
            Image(systemName: "plus")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("brain.chip.addExternal"))
    }

    private static func title(of place: BrainPlace) -> String {
        switch place {
        case .mac: return tr("brain.chip.installed")
        case .external(let provider): return shortTitle(provider)
        }
    }

    // MARK: On this Mac

    @ViewBuilder
    private var macModels: some View {
        DropdownHeader(title: tr("brain.chip.installed"))
        Text(tr("brain.chip.localDetail"))
            .font(NookTheme.font(11))
            .foregroundStyle(NookTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        let installed = ModelAdvisor.catalog.filter { local.installed.contains($0.id) }
        let empty = !AppleIntelligence.isAvailable && installed.isEmpty && servers.isEmpty
        DropdownList(maxHeight: 240, emptyNote: empty ? tr("brain.chip.noLocal") : nil) {
            if AppleIntelligence.isAvailable {
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
            ForEach(servers, id: \.name) { model in
                let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
                DropdownRow(brand: BrandLogo.forName(model.name) ?? BrandLogo.forProvider(provider), title: model.name,
                            trailing: Self.shortTitle(provider),
                            chosen: !settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name) {
                    settings.selection = BrainSelection(runtime: model.server == .ollama ? .ollama : .lmstudio,
                                                        provider: provider, model: model.name)
                }
            }
        }
        settingsRow
    }

    // MARK: External

    @ViewBuilder
    private func externalModels(_ provider: AIProvider) -> some View {
        DropdownHeader(title: Self.shortTitle(provider))
        Text(tr("brain.chip.externalDetail", Self.shortTitle(provider)))
            .font(NookTheme.font(11))
            .foregroundStyle(NookTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        let list = models(for: provider)
        if list.count > 6 {
            DropdownSearch(placeholder: tr("compose.searchModels"), text: $query)
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shownModels = needle.isEmpty ? list : list.filter { $0.lowercased().contains(needle) }
        DropdownList(maxHeight: 220, emptyNote: shownModels.isEmpty ? tr("compose.noModels") : nil) {
            ForEach(shownModels, id: \.self) { id in
                DropdownRow(brand: BrandLogo.forName(id) ?? BrandLogo.forProvider(provider), title: id,
                            chosen: !settings.isLocalBrain && settings.provider == provider && settings.activeProviderModel == id) {
                    settings.selection = BrainSelection(runtime: .external, provider: provider, model: id)
                }
            }
        }
        if provider != .claudeCode && fetched[provider] == nil {
            DropdownRow(symbol: fetching ? "hourglass" : "arrow.clockwise", title: tr("button.fetchModels"),
                        detail: fetchError, staysOpen: true) {
                Task { await fetchModels(provider) }
            }
        }
        settingsRow
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

    // MARK: Shared

    private var settingsRow: some View {
        Group {
            DropdownDivider()
            DropdownRow(symbol: "gearshape", title: tr("brain.chip.settings")) { app.openSettings(section: .brain) }
        }
    }

    /// "Claude Code" instead of "Claude Code (je abonnement)", "Ollama" instead of "Ollama (op je Mac)".
    static func shortTitle(_ provider: AIProvider) -> String {
        provider.title.components(separatedBy: " (").first ?? provider.title
    }
}
