import SwiftUI
import AppKit

/// The small menus in the box: agent and account, mode, the options, effort, and the usage limits.
extension NewSessionComposer {
    // MARK: Choices in the box

    /// Agent, account and model in one panel: agents in a rail, their models with a search.
    var agentMenu: some View {
        let profile = app.profiles.profile(id: config.profileID)
        // On Auto the agent is picked from the prompt as the session starts, so the pill shows Auto's own mark and word,
        // not the logo of the agent chosen last.
        let auto = config.model == AutoModel.id && comparing.isEmpty
        let model = config.model.isEmpty ? config.provider.displayName
            : ComposerModelLabel.compact(app.modelMenuName(config.model, for: config.provider, profileID: config.profileID),
                                         agent: config.provider.displayName)
        let plain = auto || !comparing.isEmpty
        return ModelPickerDropdown(holdsOptions: true, hasSideColumn: reasoning != nil) {
            ComposerPill(symbol: auto ? AutoModel.symbol : nil,
                         agent: auto ? nil : config.provider.displayName,
                         account: auto ? nil : profile.map { AccountTag.of($0, app: app) },
                         text: auto ? tr("auto.model") : comparing.isEmpty ? model : tr("compare.pill", comparing.count + 1),
                         detail: plain ? nil : effortWord,
                         badge: plain || !subThreadsOn ? nil : ("app.connected.to.app.below.fill", tr("compose.mainThread.on")),
                         showsChevron: false)
        } content: {
            let providers = app.connectedProviders(in: remoteMachine == nil ? config.projectPath : nil)
            if providers.isEmpty {
                DropdownHeader(title: tr(app.connectedProviders.isEmpty ? "agents.noneConnected" : "sc.agents.allOff"))
            } else {
                AgentModelPicker(providers: providers, provider: config.provider, profileID: config.profileID,
                                 model: config.model,
                                 footer: AnyView(options), trailing: reasoning.map { AnyView(ModelPickerReasoning(effort: $0)) }) { provider, account, model in
                    if provider != config.provider || (account != nil && account != config.profileID) {
                        choose(provider, account: account ?? rememberedProfile(for: provider) ?? config.profileID)
                    }
                    if let model { config.model = model }
                    remember()
                }
            }
        }
        .composerTip(tr("ws.new.accountPinned"))
    }

    var modeMenu: some View {
        ModeToggle(mode: Binding(get: { config.mode }, set: { config.mode = $0; remember() }))
    }

    /// Access, speed and sub-threads, in the footer of the model picker (the agent decides on Plan itself).
    private var options: some View {
        ModelPickerOptions(
            access: .init(provider: config.provider, chosen: config.permission, readOnly: config.mode == .plan,
                          pick: { config.permission = $0; remember() }),
            speedTiers: speedTiers, speed: config.speedTier, pickSpeed: { config.speedTier = $0 },
            ultracodeOffered: Ultracode.offered(provider: config.provider, model: config.model),
            ultracode: config.ultracode == true, setUltracode: { config.ultracode = $0 },
            mainThreadOffered: MainThread.offered(provider: config.provider, access: workspace.settings.bridgeAccess),
            mainThread: config.mainThread == true, setMainThread: { config.mainThread = $0 ? true : nil })
    }

    /// The chosen effort as the model pill says it ("High"); nil on the agent's default.
    private var effortWord: String? {
        if let family = app.modelFamily(config.model, for: config.provider, profileID: config.profileID) {
            guard let level = family.members.first(where: { $0.id == config.model })?.level, !level.isEmpty else { return nil }
            return tr(EffortLevels.label(variant: level))
        }
        return config.effort.map { workspace.effortTitle($0, for: config.provider, profileID: config.profileID) }
    }

    /// Main thread (or Ultracode, the same choice in the picker) is on for the new session.
    private var subThreadsOn: Bool {
        MainThread.offered(provider: config.provider, access: workspace.settings.bridgeAccess) ? config.mainThread == true
            : Ultracode.offered(provider: config.provider, model: config.model) && config.ultracode == true
    }

    /// The reasoning levels, in the column beside the models; nil when the agent has none for this model.
    private var reasoning: ModelPickerOptions.Effort? {
        let levels = workspace.effortLevels(for: config.provider, profileID: config.profileID,
                                            model: config.model.isEmpty ? nil : config.model)
        let effort = ModelPickerOptions.Effort(
            family: app.modelFamily(config.model, for: config.provider, profileID: config.profileID),
            model: config.model,
            modelName: config.model.isEmpty ? config.provider.displayName
                : app.modelMenuName(config.model, for: config.provider, profileID: config.profileID),
            levels: levels, chosen: config.effort,
            title: { workspace.effortTitle($0, for: config.provider, profileID: config.profileID) },
            pickLevel: { config.effort = $0; remember() },
            pickModel: { config.model = $0; remember() })
        return effort.family != nil || !levels.isEmpty ? effort : nil
    }

    /// The subscription limits of the chosen account, for every agent that reports them: you see how much room is left
    /// before you start. In the docked column beside the box when the window has room for it (`DockedUsagePanel`); in
    /// the box itself only without it (the notch, a narrow window, the panel closed).
    @ViewBuilder
    var usageLimits: some View {
        if !panelDocked {
            ComposerUsageRing.forAccount(app.profiles.profile(id: config.profileID), app: app)
        }
    }

    /// The faster tiers the chosen agent offers for the chosen model (`SpeedTiers`).
    private var speedTiers: [SpeedTier] {
        SpeedTiers.tiers(for: config.provider, model: config.model,
                         listed: workspace.offeredModels(config.provider, profileID: config.profileID))
    }

    /// `effort.increase` / `effort.decrease`: the next level up or down (`EffortStep`). An agent that lists one model per
    /// level steps through that family's models instead. False when the agent has no levels, so the key goes on.
    func stepEffort(_ direction: EffortStep.Direction) -> Bool {
        if let family = app.modelFamily(config.model, for: config.provider, profileID: config.profileID) {
            let ids = family.members.map(\.id)
            guard let index = ids.firstIndex(of: config.model) else { return false }
            let next = direction == .up ? min(index + 1, ids.count - 1) : max(index - 1, 0)
            config.model = ids[next]
        } else {
            let levels = workspace.effortLevels(for: config.provider, profileID: config.profileID,
                                                model: config.model.isEmpty ? nil : config.model)
            guard !levels.isEmpty else { return false }
            config.effort = EffortStep.next(current: config.effort, levels: levels, direction: direction)
        }
        remember()
        return true
    }
}
