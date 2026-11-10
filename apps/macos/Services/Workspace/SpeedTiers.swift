import Foundation

/// Claude Code's Ultracode, a toggle beside the effort (`withUltracodeToggle`): the agent plans and checks its work
/// in a longer workflow at extra-high effort. Claude Code reads it as `ultracode` in the settings it starts with, the
/// key passes through the Agent SDK's `settings` (Nook's `--settings`). Claude's model catalog offers it on the
/// models below; the other agents have no such thing (`ProviderCapabilities.ultracode`).
enum Ultracode {
    /// The models whose effort levels include Ultracode in Claude's model catalog, without "claude-" and a date.
    static let models: Set<String> = ["fable-5", "opus-5-5", "opus-5", "opus-4-8", "sonnet-5-5", "haiku-5-5"]
    /// Claude Code's aliases resolve to the newest model of each family, which has it; empty is its default model.
    static let aliases: Set<String> = ["", "default", "best", "fable", "opus", "sonnet", "haiku", "opusplan"]

    static func offered(provider: RunProvider, model: String?) -> Bool {
        guard provider.capabilities.ultracode else { return false }
        switch provider {
        case .claude:
            let name = normalized(model ?? "")
            return aliases.contains(name) || models.contains(name)
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
            return false
        }
    }

    /// "claude-opus-5-5[1m]", "us.anthropic.claude-opus-4-8-20260101-v1:0" and "Opus-5-5" all read "opus-5-5".
    static func normalized(_ model: String) -> String {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let range = name.range(of: "claude-", options: .backwards) { name = String(name[range.upperBound...]) }
        if name.hasSuffix("[1m]") { name = String(name.dropLast(4)) }
        if let range = name.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { name.removeSubrange(range) }
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name
    }

    /// Claude Code's `--settings`: `ultracode` as you chose it; nothing when you did not, so your own setting holds.
    static func claudeSettings(_ on: Bool?) -> [String: Any] {
        on.map { ["ultracode": $0] } ?? [:]
    }
}

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
        case .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
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
