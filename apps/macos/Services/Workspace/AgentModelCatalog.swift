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

/// Some agents list one model per thinking level: Antigravity offers "Gemini 3 Pro (High)" and "Gemini 3 Pro (Low)", and
/// "Claude Sonnet 4.5 (Thinking)" next to "Claude Sonnet 4.5". The model menu shows such a family once, and its level is
/// picked with the effort control in the composer, as with Claude Code.
enum ModelVariants {
    /// The levels Nook recognises, in the order the effort control lists them; "" is the member without a level.
    static let order = ["", "minimal", "low", "medium", "high", "xhigh", "thinking"]

    struct Member: Equatable, Hashable, Sendable {
        var level: String
        var id: String
    }

    struct Family: Equatable, Sendable {
        /// The model's name without its level: "Gemini 3 Pro".
        var name: String
        /// Ordered by `order`.
        var members: [Member]

        func id(for level: String) -> String? { members.first { $0.level == level }?.id }
        func contains(_ id: String) -> Bool { members.contains { $0.id == id } }
    }

    /// A model's name without its level, and the level: "(High)" at the end of the name, else "-high" at the end of the id.
    static func split(_ model: AgentModel) -> (name: String, level: String) {
        let name = model.name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            let level = name[name.index(after: open)..<name.index(before: name.endIndex)].lowercased()
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            if order.contains(level), !level.isEmpty {
                return (name[..<open].trimmingCharacters(in: .whitespaces), level)
            }
        }
        let parts = model.id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        if parts.count > 1, let last = parts.last.map(String.init), order.contains(last) {
            let lowered = name.lowercased()
            for separator in ["-", "_", " "] where lowered.hasSuffix(separator + last) {
                return (String(name.dropLast(last.count + 1)), last)
            }
            return (name, last)
        }
        return (name, "")
    }

    /// The families among `models`: only names that come in two levels or more, in the order the agent lists them.
    static func families(_ models: [AgentModel]) -> [Family] {
        var keys: [String] = []
        var grouped: [String: Family] = [:]
        for model in models {
            let (name, level) = split(model)
            let key = name.lowercased()
            guard !key.isEmpty else { continue }
            if grouped[key] == nil { keys.append(key); grouped[key] = Family(name: name, members: []) }
            if grouped[key]?.members.contains(where: { $0.level == level }) == false {
                grouped[key]?.members.append(Member(level: level, id: model.id))
            }
        }
        return keys.compactMap { grouped[$0] }.filter { $0.members.count > 1 }.map { family -> Family in
            var sorted = family
            sorted.members.sort { (order.firstIndex(of: $0.level) ?? 0) < (order.firstIndex(of: $1.level) ?? 0) }
            return sorted
        }
    }

    /// The family `id` belongs to, nil when it has no siblings.
    static func family(of id: String, in models: [AgentModel]) -> Family? {
        guard !id.isEmpty else { return nil }
        return families(models).first { $0.contains(id) }
    }

    /// One entry per family, the first of its members in `ids`; models without siblings stay as they are.
    static func collapse(_ ids: [String], in models: [AgentModel]) -> [String] {
        let all = families(models)
        var seen = Set<String>()
        return ids.filter { id in
            guard let family = all.first(where: { $0.contains(id) }) else { return seen.insert("id:" + id).inserted }
            return seen.insert("family:" + family.name.lowercased()).inserted
        }
    }

    /// The model to run when you pick `id` in the menu while `current` is chosen: the same level in the new family when
    /// it has one, else the agent's default member, else `id`.
    static func pick(_ id: String, keeping current: String, in models: [AgentModel]) -> String {
        guard let family = Self.family(of: id, in: models) else { return id }
        if let level = Self.family(of: current, in: models)?.members.first(where: { $0.id == current })?.level,
           let same = family.id(for: level) {
            return same
        }
        let defaults = Set(models.filter(\.isDefault).map(\.id))
        return family.members.first { defaults.contains($0.id) }?.id ?? id
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
