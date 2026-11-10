import Foundation

/// A faster (and dearer) way of serving the same model, picked beside the effort (`ProviderCapabilities.speedTiers`).
/// Codex lists the tiers per model in `model/list` (`serviceTiers`, before that `additionalSpeedTiers`) and takes the
/// chosen one as `serviceTier` on `turn/start` (`service_tier` in its config for `codex exec`). Claude Code has one,
/// fast mode, set with `fastMode` in the settings it starts with. The other agents' protocols have no such choice.
struct SpeedTier: Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var detail: String? = nil
}

enum SpeedTiers {
    /// Claude Code's fast mode. Claude Code applies it only where the model and your plan allow it.
    static let claudeFast = SpeedTier(id: "fast", name: "Fast")

    /// The tiers to offer for `model` beside the agent's standard speed (nil): Codex's listed ones for that model (its
    /// default model's when none is picked), Claude Code's fast mode, and none for the rest.
    static func tiers(for provider: RunProvider, model: String?, listed: [AgentModel]) -> [SpeedTier] {
        guard provider.capabilities.speedTiers else { return [] }
        switch provider {
        case .claude:
            return [claudeFast]
        case .codex:
            let entry = model.flatMap { id in id.isEmpty ? nil : listed.first { $0.id == id } } ?? listed.first { $0.isDefault }
            return entry?.tiers ?? []
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp:
            return []
        }
    }

    /// The tier of a Codex model in `model/list`: `serviceTiers` (id, name, description), else the older
    /// `additionalSpeedTiers` (ids only).
    static func codexTiers(_ item: [String: Any]) -> [SpeedTier]? {
        var seen = Set<String>()
        if let listed = item["serviceTiers"] as? [[String: Any]], !listed.isEmpty {
            let tiers = listed.compactMap { entry -> SpeedTier? in
                guard let id = entry["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
                let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? displayName(id)
                let detail = (entry["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return SpeedTier(id: id, name: name, detail: detail)
            }
            return tiers.isEmpty ? nil : tiers
        }
        let ids = ((item["additionalSpeedTiers"] as? [String]) ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
        return ids.isEmpty ? nil : ids.map { SpeedTier(id: $0, name: displayName($0)) }
    }

    /// "fast" reads "Fast", "ultrafast" reads "Ultrafast".
    static func displayName(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The chosen tier, if the model still offers it; otherwise the standard speed (nil).
    static func resolve(_ tier: String?, offered: [SpeedTier]) -> String? {
        guard let tier, offered.contains(where: { $0.id == tier }) else { return nil }
        return tier
    }

    // MARK: Encodings

    /// Codex `turn/start`: `serviceTier` with the tier, or null for the standard speed. Only when the model lists tiers,
    /// so a Codex that knows none never gets the field.
    static func codexTurnParam(tier: String?, offered: [SpeedTier]) -> [String: Any] {
        guard !offered.isEmpty else { return [:] }
        return ["serviceTier": resolve(tier, offered: offered).map { $0 as Any } ?? NSNull()]
    }

    /// `codex exec`: the tier as a config override; nothing for the standard speed.
    static func codexExecArguments(tier: String?) -> [String] {
        guard let tier, !tier.isEmpty, tier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return [] }
        return ["-c", "service_tier=\"\(tier)\""]
    }

    /// Claude Code's `--settings`: `fastMode` on for the fast tier; the standard speed leaves your own setting alone.
    static func claudeSettings(tier: String?) -> [String: Any] {
        tier == claudeFast.id ? ["fastMode": true] : [:]
    }
}
