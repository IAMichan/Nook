import SwiftUI

/// Shows which model Nook thinks with, and whether that is on this Mac or with an external service.
/// Switching between local models happens right here; an external AI is chosen deliberately in Settings › Brain.
struct BrainChip: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var local = EmbeddedModel.shared
    @State private var servers: [ServerModel] = []

    var body: some View {
        Menu {
            Section(tr("brain.chip.installed")) {
                ForEach(ModelAdvisor.catalog.filter { local.installed.contains($0.id) }) { option in
                    Button(mark(settings.useLocal && settings.localModel == option.id) + option.title) {
                        settings.useLocal = true
                        settings.localModel = option.id
                    }
                }
                ForEach(servers, id: \.name) { model in
                    let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
                    Button(mark(!settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name)
                           + tr("brain.advice.server", model.name, provider.title.components(separatedBy: " (").first ?? provider.title)) {
                        settings.useLocal = false
                        settings.provider = provider
                        settings.setProviderModel(model.name)
                    }
                }
            }
            if !settings.isLocalBrain {
                Text(tr("brain.chip.externalNote"))
            }
            Divider()
            Button(tr("brain.chip.settings")) { app.openSettings(section: .brain) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: settings.isLocalBrain ? "cpu" : "cloud")
                    .font(.system(size: 11, weight: .semibold))
                Text((settings.isLocalBrain ? tr("brain.chip.local") : tr("brain.chip.external")) + " · " + settings.brainLabel)
                    .font(NookTheme.font(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(settings.isLocalBrain ? NookTheme.mint : NookTheme.amber)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("brain.chip.help"))
        .task { servers = await app.localServerModels() }
    }

    private func mark(_ on: Bool) -> String { on ? "✓ " : "" }
}
