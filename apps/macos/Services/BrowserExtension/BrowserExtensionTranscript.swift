import Foundation

/// The side panel draws an answer as Nook's own window does: where Nook looked (one quiet line that opens), the plan it
/// keeps while it works, and the numbered references. These are the same facts as `SourcesDisclosure` and the plan's
/// checklist on the Mac, already in the user's language, so the panel only lays them out.
enum BrowserExtensionTranscript {
    /// The most sources and references one answer sends; more never fit a side panel.
    static let maxItems = 12

    /// What Nook used for this answer, grouped per source as on the Mac; nil when it looked nowhere.
    static func sources(_ message: ChatMessage) -> [String: Any]? {
        guard !message.retrieval.isEmpty || !message.references.isEmpty else { return nil }
        var order: [String] = []
        var grouped: [String: [RetrievalStep]] = [:]
        for step in message.retrieval {
            if grouped[step.sourceTitle] == nil { order.append(step.sourceTitle) }
            grouped[step.sourceTitle, default: []].append(step)
        }
        var items: [[String: Any]] = []
        var running = false
        var used = 0
        for title in order {
            let steps = grouped[title] ?? []
            let queries = steps.map(\.query).filter { !$0.isEmpty }
            var state = "found"
            var detail = queries.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            if steps.contains(where: { $0.outcome == .running }) {
                if message.streaming {
                    state = "running"
                    running = true
                } else {
                    state = "failed"
                    detail = tr("chat.sources.interrupted")
                }
            } else if !steps.contains(where: { if case .found = $0.outcome { return true }; return false }),
                      let error = steps.compactMap({ step -> String? in if case .failed(let error) = step.outcome { return error }; return nil }).first {
                state = "failed"
                detail = tr("chat.sources.failed", error)
            } else if steps.allSatisfy({ $0.outcome == .empty }) {
                state = "empty"
                detail = [detail, tr("chat.sources.nothing")].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if state == "found" { used += 1 }
            items.append(["title": TextKit.clip(title, to: 60), "detail": TextKit.clip(detail, to: 160), "state": state])
        }
        let references: [[String: Any]] = message.references.prefix(maxItems).map { reference in
            var entry: [String: Any] = ["number": reference.number, "title": TextKit.clip(reference.title, to: 120)]
            // Only a web address goes along: a Mail or file link means nothing in the browser.
            if let url = reference.url, url.hasPrefix("https://") { entry["url"] = url }
            return entry
        }
        if used == 0, !references.isEmpty { used = Set(message.references.map(\.sourceID)).count }
        let summary: String
        if running { summary = tr("chat.sources.searchingShort") }
        else if used == 0 {
            let nothing = tr("chat.sources.nothing")
            summary = nothing.prefix(1).uppercased() + nothing.dropFirst()
        }
        else { summary = used == 1 ? tr("chat.sources.usedOne") : tr("chat.sources.used", used) }
        return ["summary": summary, "running": running, "items": Array(items.prefix(maxItems)), "references": references]
    }

    /// The plan Nook keeps while it works through a request, as the checklist on the Mac.
    static func tasks(_ message: ChatMessage) -> [[String: Any]] {
        message.tasks.prefix(maxItems).map { ["text": TextKit.clip($0.text, to: 160), "status": $0.status.rawValue] }
    }
}

/// The brain chip of the side panel's composer: the same choices as the chip in Nook's own composer (`BrainChip`): every
/// connected agent that can think for Nook with its models, and the models on this Mac. Picking one changes Nook's brain
/// everywhere, as picking it on the Mac does.
@MainActor
enum BrowserExtensionBrain {
    struct Choice {
        let id: String
        let title: String
        let group: String
        let chosen: Bool
        let selection: BrainSelection
    }

    static func choices(app: AppModel, servers: [ServerModel]) -> [Choice] {
        let settings = app.settings
        var choices: [Choice] = []
        for agent in app.connectedProviders {
            guard let provider = AIProvider.brain(for: agent) else { continue }
            let profile = app.profiles.preferredProfile(agent.kind).id
            let active = !settings.isLocalBrain && settings.provider == provider
                ? app.modelMenuName(settings.activeProviderModel, for: agent, profileID: profile) : nil
            for model in app.menuModels(for: agent, profileID: profile) where !model.isEmpty && model != AutoModel.id {
                let name = app.modelMenuName(model, for: agent, profileID: profile)
                choices.append(Choice(id: "agent|\(provider.rawValue)|\(model)", title: name, group: agent.displayName,
                                      chosen: name == active,
                                      selection: BrainSelection(runtime: .external, provider: provider, model: model)))
            }
        }
        let mac = tr("brain.chip.installed")
        if AppleIntelligence.isAvailable {
            choices.append(Choice(id: "mlx|" + AppleModel.id, title: AppleModel.title, group: mac,
                                  chosen: settings.useLocal && settings.localModel == AppleModel.id,
                                  selection: BrainSelection(runtime: .mlx, provider: settings.provider, model: AppleModel.id)))
        }
        for option in ModelAdvisor.catalog where EmbeddedModel.shared.installed.contains(option.id) {
            choices.append(Choice(id: "mlx|" + option.id, title: option.title, group: mac,
                                  chosen: settings.useLocal && settings.localModel == option.id,
                                  selection: BrainSelection(runtime: .mlx, provider: settings.provider, model: option.id)))
        }
        for model in servers {
            let provider: AIProvider = model.server == .ollama ? .ollama : .lmstudio
            choices.append(Choice(id: "\(model.server.rawValue)|\(model.name)", title: model.name, group: mac,
                                  chosen: !settings.useLocal && settings.provider == provider && settings.activeProviderModel == model.name,
                                  selection: BrainSelection(runtime: model.server == .ollama ? .ollama : .lmstudio,
                                                            provider: provider, model: model.name)))
        }
        return choices
    }

    /// The chip and its menu for the side panel.
    static func payload(app: AppModel, servers: [ServerModel]) -> [String: Any] {
        let list = choices(app: app, servers: servers)
        let chosen = list.first(where: \.chosen)
        return [
            "ok": true,
            "label": chosen?.title ?? app.settings.brainLabel,
            "group": chosen?.group ?? "",
            "choices": list.map { ["id": $0.id, "title": $0.title, "group": $0.group, "chosen": $0.chosen] }
        ]
    }

    /// Makes the choice with this id Nook's brain. Only an id from the list counts, so the browser can never pick
    /// something the Mac would not offer.
    static func choose(_ id: String, app: AppModel, servers: [ServerModel]) -> Bool {
        guard let choice = choices(app: app, servers: servers).first(where: { $0.id == id }) else { return false }
        app.settings.selection = choice.selection
        return true
    }
}
