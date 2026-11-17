import Foundation

/// The choices of Nook's composer on the phone (`CompanionFeature.nookComposer`, `CompanionNookComposer.swift`): the model
/// Nook thinks with, what it may do by itself and the sources it reads, from the same settings the Mac's Nook tab
/// changes (`BrainChip`, `NookAccessMenu`, `ScopeMenu`). Every change is checked against what the Mac offers now and
/// logged; Nook's widest access is never set from a phone (as a new session from a phone is capped).
extension CompanionServer {
    /// The model ids the phone picks from: where the model runs, then what it is.
    private enum BrainID {
        static let agent = "agent|"
        static let mlx = "mlx|"
        static let ollama = "ollama|"
        static let lmstudio = "lmstudio|"
    }

    // MARK: Reading

    func nookComposer(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        var response = CompanionResponse(id: request.id, ok: true)
        response.nookComposer = await Self.composerDigest(conversation: request.conversation, app: app)
        return response
    }

    static func composerDigest(conversation: String?, app: AppModel) async -> NookComposerDigest {
        let settings = AppSettings.shared
        let servers = await app.localServerModels()
        let models = Array(brainChoices(app: app, servers: servers).prefix(NookComposerDigest.modelLimit))
        let access = settings.nookAccess
        let accesses = NookAccess.allCases.map { level in
            NookComposerDigest.Choice(id: level.rawValue, title: level.label, detail: level.detail, chosen: level == access,
                                      macOnly: level == .more ? true : nil)
        }
        let scope = app.scope(of: conversation.flatMap(UUID.init(uuidString:)))
        let sources = app.connectors.active.map(\.id) + [SourceCatalog.web]
        let only = sources.map { id in
            NookComposerDigest.Choice(id: id, title: sourceTitle(id, app: app),
                                      chosen: scope.mode == .only && scope.included.contains(id))
        }
        let never = [SourceCatalog.screen, SourceCatalog.web, "clipboard"].map { id in
            NookComposerDigest.Choice(id: id, title: sourceTitle(id, app: app), chosen: scope.excluded.contains(id))
        }
        return NookComposerDigest(model: CompanionPolicy.clip(settings.brainLabel, limit: 80), models: models,
                                  access: access.rawValue, accesses: accesses,
                                  scope: scope.isRestricted ? scope.label() : tr("scope.automaticShort"),
                                  restricted: scope.isRestricted, only: only, never: never)
    }

    /// The models of the Mac's brain picker: each connected agent Nook can think through, with its models, then the
    /// models on this Mac (Apple's, the installed ones, and a local server's).
    private static func brainChoices(app: AppModel, servers: [ServerModel]) -> [NookComposerDigest.Choice] {
        let settings = AppSettings.shared
        var choices: [NookComposerDigest.Choice] = []
        let inUse = !settings.isLocalBrain ? settings.provider.subscriptionAgent.flatMap(RunProvider.init(kind:)) : nil
        for agent in app.connectedProviders where AIProvider.brain(for: agent) != nil {
            let profile = app.profiles.preferredProfile(agent.kind)
            for model in app.models(for: agent, profileID: profile.id) {
                choices.append(.init(id: BrainID.agent + agent.rawValue + "|" + model,
                                     title: CompanionPolicy.clip(app.modelMenuName(model, for: agent, profileID: profile.id), limit: 80),
                                     group: agent.displayName,
                                     chosen: inUse == agent && settings.activeProviderModel == model))
            }
        }
        let mac = tr("brain.chip.installed")
        if AppleIntelligence.isAvailable {
            choices.append(.init(id: BrainID.mlx + AppleModel.id, title: AppleModel.title, group: mac,
                                 chosen: settings.useLocal && settings.localModel == AppleModel.id))
        }
        for option in ModelAdvisor.catalog where EmbeddedModel.shared.installed.contains(option.id) {
            choices.append(.init(id: BrainID.mlx + option.id, title: option.title, group: mac,
                                 chosen: settings.useLocal && settings.localModel == option.id))
        }
        for model in servers {
            let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
            choices.append(.init(id: (model.server == .ollama ? BrainID.ollama : BrainID.lmstudio) + model.name,
                                 title: CompanionPolicy.clip(model.name, limit: 80), group: mac,
                                 chosen: !settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name))
        }
        return choices
    }

    private static func sourceTitle(_ id: String, app: AppModel) -> String {
        CompanionPolicy.clip(app.connectors.source(id: id)?.title ?? SourceCatalog.title(id), limit: 60)
    }

    // MARK: Changing

    func setNookComposer(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let change = request.text.flatMap(NookComposerChange.init(rawValue:)) else { return .failure(request.id, .badRequest) }
        let item = request.item ?? ""
        let settings = AppSettings.shared
        switch change {
        case .model:
            // Only a model the picker offers now, applied as the picker applies it.
            let servers = await app.localServerModels()
            guard Self.brainChoices(app: app, servers: servers).contains(where: { $0.id == item }) else {
                return .failure(request.id, .badRequest)
            }
            let parts = item.split(separator: "|", maxSplits: 2).map(String.init)
            switch parts.first {
            case "agent":
                guard parts.count == 3, let agent = RunProvider(rawValue: parts[1]), let provider = AIProvider.brain(for: agent) else {
                    return .failure(request.id, .badRequest)
                }
                settings.selection = BrainSelection(runtime: .external, provider: provider, model: parts[2])
            case "mlx":
                guard parts.count == 2 else { return .failure(request.id, .badRequest) }
                settings.selection = BrainSelection(runtime: .mlx, provider: settings.provider, model: parts[1])
            case "ollama", "lmstudio":
                guard parts.count == 2 else { return .failure(request.id, .badRequest) }
                let ollama = parts[0] == "ollama"
                settings.selection = BrainSelection(runtime: ollama ? .ollama : .lmstudio, provider: ollama ? .ollama : .lmstudio,
                                                    model: parts[1])
            default:
                return .failure(request.id, .badRequest)
            }
        case .access:
            // Nook's widest access (it may take over the Mac's mouse and keyboard) is chosen at the Mac.
            guard let level = NookAccess(rawValue: item), level != .more else { return .failure(request.id, .notAllowedFromPhone) }
            settings.nookAccess = level
        case .automatic, .only, .never:
            let conversation = request.conversation.flatMap(UUID.init(uuidString:))
            var scope = app.scope(of: conversation)
            let on = request.allow == true
            switch change {
            case .automatic:
                scope = .automatic
            case .only:
                guard app.connectors.active.contains(where: { $0.id == item }) || item == SourceCatalog.web else {
                    return .failure(request.id, .badRequest)
                }
                // As the Mac's menu: the first "only" starts a fresh list, the last one off goes back to automatic.
                if on {
                    if scope.mode != .only { scope.included = [] }
                    scope.mode = .only
                    scope.included.insert(item)
                    scope.excluded.remove(item)
                } else {
                    scope.included.remove(item)
                }
                if scope.mode == .only && scope.included.isEmpty { scope.mode = .automatic }
            default:
                guard [SourceCatalog.screen, SourceCatalog.web, "clipboard"].contains(item) else { return .failure(request.id, .badRequest) }
                if on { scope.excluded.insert(item); scope.included.remove(item) } else { scope.excluded.remove(item) }
                if scope.mode == .only && scope.included.isEmpty { scope.mode = .automatic }
            }
            if let conversation, app.chat.conversation(conversation) != nil {
                app.chat.setScope(scope, conversation: conversation)
            } else {
                // A new chat starts with the last scope, as on the Mac.
                app.chat.setLastScope(scope)
            }
        }
        audit("nook_composer", change.rawValue + " " + item)
        var response = CompanionResponse(id: request.id, ok: true)
        response.nookComposer = await Self.composerDigest(conversation: request.conversation, app: app)
        return response
    }
}
