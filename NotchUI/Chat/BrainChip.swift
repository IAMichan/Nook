import SwiftUI

/// Shows which model Nook thinks with, and whether that is on this Mac or with an external service.
/// Switching between local models happens right here; an external AI is chosen deliberately in Settings › Brain.
struct BrainChip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var local = EmbeddedModel.shared
    @State private var servers: [ServerModel] = []

    /// The maker's mark for the model in use: from the model's own name first ("claude-haiku", "Qwen 3"), else its provider.
    private var logo: BrandLogo? {
        if settings.useLocal {
            return BrandLogo.forName(settings.brainLabel)
        }
        return BrandLogo.forName(settings.activeProviderModel) ?? BrandLogo.forProvider(settings.provider)
    }

    var body: some View {
        Menu {
            Section(tr("brain.chip.installed")) {
                ForEach(ModelAdvisor.catalog.filter { local.installed.contains($0.id) }) { option in
                    Button {
                        settings.useLocal = true
                        settings.localModel = option.id
                    } label: {
                        item(mark(settings.useLocal && settings.localModel == option.id) + option.title,
                             logo: BrandLogo.forName(option.title) ?? BrandLogo.forName(option.id))
                    }
                }
                ForEach(servers, id: \.name) { model in
                    let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
                    Button {
                        settings.useLocal = false
                        settings.provider = provider
                        settings.setProviderModel(model.name)
                    } label: {
                        item(mark(!settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name)
                             + tr("brain.advice.server", model.name, provider.title.components(separatedBy: " (").first ?? provider.title),
                             logo: BrandLogo.forName(model.name) ?? BrandLogo.forProvider(provider))
                    }
                }
            }
            if !settings.isLocalBrain {
                Text(tr("brain.chip.externalNote"))
            }
            Divider()
            Button(tr("brain.chip.settings")) { app.openSettings(section: .brain) }
        } label: {
            ComposerPill(symbol: logo == nil ? (settings.isLocalBrain ? "cpu" : "cloud") : nil, brand: logo, text: settings.brainLabel)
        }
        .composerMenu()
        .help(tr("brain.chip.help"))
        .task { servers = await app.localServerModels() }
    }

    private func mark(_ on: Bool) -> String { on ? "✓ " : "" }

    /// A menu item with the maker's mark in front, when we know it.
    @ViewBuilder
    private func item(_ title: String, logo: BrandLogo?) -> some View {
        if let logo {
            Label { Text(title) } icon: { LogoImage.brand(logo) }
        } else {
            Text(title)
        }
    }
}
