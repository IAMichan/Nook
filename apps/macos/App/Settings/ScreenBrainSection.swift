import SwiftUI

/// Settings › Brain › Screen work: while an external brain answers, who may read the screen. The external brain itself, no
/// one (screen work is off), or a model on this Mac (`ScreenBrain`), so Claude does the harder questions and the screen
/// never leaves the Mac.
struct ScreenBrainSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var embedded = EmbeddedModel.shared
    @State private var serverModels: [ServerModel] = []

    /// The picker's tag for "the external brain may read the screen".
    private static let external = "external"

    var body: some View {
        Section {
            Picker(tr("settings.screenBrain.picker"), selection: choice) {
                if !strict {
                    Text(tr("settings.screenBrain.external", providerName)).tag(Self.external)
                }
                Text(tr("settings.screenBrain.off")).tag("")
                ForEach(options, id: \.self) { stored in
                    if let option = ScreenBrain.parse(stored) {
                        Text(tr("settings.screenBrain.local", AppSettings.screenBrainName(option))).tag(stored)
                    }
                }
            }
            note
        } header: {
            SettingsSectionTitle(tr("settings.screenBrain.title"), info: tr("settings.screenBrain.info"))
        }
        .task { serverModels = await app.localServerModels() }
    }

    /// What the choice means right now, in one line.
    @ViewBuilder private var note: some View {
        if let worker = settings.screenWorker {
            SettingNote(tr("settings.screenBrain.localNote", AppSettings.screenBrainName(worker), providerName), tone: .success)
        } else if choice.wrappedValue == Self.external {
            SettingNote(tr("settings.screenBrain.externalNote", providerName), tone: .warning)
        } else if options.isEmpty {
            SettingNote(tr("settings.screenBrain.noModel"), tone: .warning)
        } else {
            SettingNote(tr("settings.screenBrain.offNote"))
        }
    }

    /// The strict privacy level keeps the screen on this Mac by itself: the external brain is no choice then.
    private var strict: Bool {
        settings.privacyLevel.localOnlySources.contains(SourceCatalog.screen)
    }

    /// "Claude", "OpenAI": the external brain, without what its title adds in brackets.
    private var providerName: String {
        let title = settings.chosenSelection.provider.title
        return title.components(separatedBy: " (").first ?? title
    }

    /// The screen is kept on this Mac (by hand or by the privacy level) with or without a screen brain, or it is not.
    private var choice: Binding<String> {
        Binding(
            get: {
                let screenPrivate = settings.localOnlySources.union(settings.privacyLevel.localOnlySources).contains(SourceCatalog.screen)
                guard screenPrivate else { return Self.external }
                return ScreenBrain.parse(settings.screenBrain) == nil ? "" : settings.screenBrain
            },
            set: { value in
                guard value != Self.external else {
                    settings.localOnlySources.remove(SourceCatalog.screen)
                    return
                }
                settings.localOnlySources.insert(SourceCatalog.screen)
                settings.screenBrain = value
            }
        )
    }

    /// The models on this Mac that can do screen work, stored as `ScreenBrain.parse` reads them: Apple Intelligence, the
    /// built-in models that are installed, and what Ollama and LM Studio serve. The one picked stays listed while its
    /// server is not running.
    private var options: [String] {
        var models: [BrainSelection] = []
        if AppleIntelligence.isAvailable { models.append(BrainSelection(runtime: .mlx, provider: .claude, model: AppleModel.id)) }
        models += embedded.installed.sorted().map { BrainSelection(runtime: .mlx, provider: .claude, model: $0) }
        models += serverModels.map { model in
            model.server == .ollama
                ? BrainSelection(runtime: .ollama, provider: .ollama, model: model.name)
                : BrainSelection(runtime: .lmstudio, provider: .lmstudio, model: model.name)
        }
        var stored = models.map(ScreenBrain.stored)
        if ScreenBrain.parse(settings.screenBrain) != nil, !stored.contains(settings.screenBrain) { stored.append(settings.screenBrain) }
        return stored
    }
}
