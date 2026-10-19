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
        ComposerDropdown(width: 340) {
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
    @State private var shown: BrainPlace?
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
    private var current: BrainPlace { shown ?? active }

    var body: some View {
        HStack(spacing: 0) {
            rail
            VStack(alignment: .leading, spacing: 0) {
                switch current {
                case .mac: macModels
                case .external(let provider): externalModels(provider)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 360)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 4) {
            railButton(.mac, help: tr("brain.chip.installed")) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NookTheme.paper)
            }
            if !externals.isEmpty {
                Rectangle().fill(NookTheme.line2).frame(width: 18, height: 1).padding(.vertical, 2)
            }
            ForEach(externals) { provider in
                railButton(.external(provider), help: Self.shortTitle(provider)) {
                    BrandMark(logo: BrandLogo.forProvider(provider), size: 17)
                }
            }
            Spacer(minLength: 0)
            Button {
                close()
                app.openSettings(section: .brain)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("brain.chip.addExternal"))
        }
        .padding(6)
        .frame(width: 44)
        .background(NookTheme.paper.opacity(0.03))
        .overlay(alignment: .trailing) { Rectangle().fill(NookTheme.line2).frame(width: 1) }
    }

    private func railButton<Icon: View>(_ place: BrainPlace, help: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            shown = place
            query = ""
            fetchError = nil
        } label: {
            icon()
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(place == current ? DropdownStyle.chosen : .clear))
                .overlay(alignment: .bottomTrailing) {
                    // A dot on the place Nook thinks with now, while you look at another one.
                    if place == active && place != current {
                        Circle().fill(NookTheme.paper.opacity(0.7)).frame(width: 4, height: 4).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let installed = ModelAdvisor.catalog.filter { local.installed.contains($0.id) }
                if !AppleIntelligence.isAvailable && installed.isEmpty && servers.isEmpty {
                    emptyNote(tr("brain.chip.noLocal"))
                }
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
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shownModels = needle.isEmpty ? list : list.filter { $0.lowercased().contains(needle) }
                if shownModels.isEmpty { emptyNote(tr("compose.noModels")) }
                ForEach(shownModels, id: \.self) { id in
                    DropdownRow(brand: BrandLogo.forName(id) ?? BrandLogo.forProvider(provider), title: id,
                                chosen: !settings.isLocalBrain && settings.provider == provider && settings.activeProviderModel == id) {
                        settings.selection = BrainSelection(runtime: .external, provider: provider, model: id)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
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

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.font(12))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(10)
    }

    /// "Claude Code" instead of "Claude Code (je abonnement)", "Ollama" instead of "Ollama (op je Mac)".
    static func shortTitle(_ provider: AIProvider) -> String {
        provider.title.components(separatedBy: " (").first ?? provider.title
    }
}
