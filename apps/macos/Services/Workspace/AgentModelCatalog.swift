import Foundation

/// A model an agent offers itself: Codex from `model/list`, ACP agents from what
/// `session/new` (or Grok's `initialize`) reports. Nook shows these instead of a fixed list once it has seen them.
struct AgentModel: Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool = false
}

enum AgentModelCatalog {
    /// One page of Codex `model/list`: the visible models in Codex's own order, and the cursor of the next page.
    static func codexPage(_ response: [String: Any]) -> (models: [AgentModel], next: String?) {
        let data = (response["data"] as? [[String: Any]]) ?? []
        let models = data.compactMap { item -> AgentModel? in
            guard (item["hidden"] as? Bool) != true,
                  let slug = nonEmpty(item["model"]) ?? nonEmpty(item["id"]) else { return nil }
            return AgentModel(id: slug, name: codexName(nonEmpty(item["displayName"]) ?? slug),
                              isDefault: (item["isDefault"] as? Bool) ?? false)
        }
        return (models, nonEmpty(response["nextCursor"]))
    }

    /// "gpt-5.1-codex-max" reads "GPT-5.1-Codex-Max".
    static func codexName(_ name: String) -> String {
        var text = name
        if text.lowercased().hasPrefix("gpt") { text = "GPT" + text.dropFirst(3) }
        var result = ""
        var afterDash = false
        for character in text {
            result.append(afterDash && character.isLowercase ? Character(character.uppercased()) : character)
            afterDash = character == "-"
        }
        return result
    }

    /// The models of an ACP session: the model config option (id or category "model", groups flattened), else
    /// `models.availableModels`, else Grok's `_meta.modelState` from `initialize`. The current one is the default.
    static func acp(_ result: [String: Any]) -> [AgentModel] {
        if let option = modelOption(result) {
            let current = option["currentValue"] as? String
            let flat = ((option["options"] as? [[String: Any]]) ?? []).flatMap { entry -> [[String: Any]] in
                (entry["options"] as? [[String: Any]]) ?? [entry]
            }
            let models = flat.compactMap { entry -> AgentModel? in
                guard let value = nonEmpty(entry["value"]) else { return nil }
                return AgentModel(id: value, name: nonEmpty(entry["name"]) ?? value, isDefault: value == current)
            }
            if !models.isEmpty { return models }
        }
        let state = (result["models"] as? [String: Any])
            ?? ((result["_meta"] as? [String: Any])?["modelState"] as? [String: Any])
        guard let state else { return [] }
        let current = state["currentModelId"] as? String
        return ((state["availableModels"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let id = nonEmpty(entry["modelId"]) else { return nil }
            return AgentModel(id: id, name: nonEmpty(entry["name"]) ?? id, isDefault: id == current)
        }
    }

    /// The config option that picks the model, when the agent has one: the model is then set with
    /// `session/set_config_option`, otherwise with `session/set_model`.
    static func acpModelOptionID(_ result: [String: Any]) -> String? {
        modelOption(result).flatMap { nonEmpty($0["id"]) }
    }

    private static func modelOption(_ result: [String: Any]) -> [String: Any]? {
        let options = (result["configOptions"] as? [[String: Any]]) ?? []
        return options.first { ($0["category"] as? String) == "model" && ($0["type"] as? String ?? "select") == "select" }
            ?? options.first { ($0["id"] as? String) == "model" }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// The models each agent offered last, kept between launches so the menus are right from the start.
struct AgentModelStore {
    let url: URL

    func load() -> [RunProvider: [AgentModel]] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [AgentModel]].self, from: data) else { return [:] }
        var result: [RunProvider: [AgentModel]] = [:]
        for (key, models) in raw { if let provider = RunProvider(rawValue: key) { result[provider] = models } }
        return result
    }

    func save(_ models: [RunProvider: [AgentModel]]) {
        let raw = Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
