import Foundation

// Reasoning effort per turn. Uses the levels a model advertises (Codex `effort` on turn/start, any non-empty
// string; an ACP agent's "thought_level" config option), passed as `advertised`.
enum EffortLevels {
    /// The levels Nook has a word for (`effort.level.*`); another level an agent offers reads under the agent's name.
    static let known: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "thinking"]

    /// Codex: low, medium, high are the safe common set; "minimal" and "xhigh" exist only on some models, so they
    /// appear only when `advertised` says so. Claude Code takes `--effort` at launch; low, medium and high are the
    /// levels every model accepts. Agents over ACP (Gemini CLI, Antigravity, OpenCode, Cursor, Grok, the ones you add)
    /// have exactly the levels their session offered, as the agent spells them (it is sent back as is), and none when
    /// it offered none.
    static func levels(for provider: RunProvider, model: String?, advertised: [String]? = nil) -> [String] {
        switch provider {
        case .codex:
            if let advertised, !advertised.isEmpty {
                var seen = Set<String>()
                return advertised.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            return ["low", "medium", "high"]
        case .claude:
            return ["low", "medium", "high"]
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp:
            var seen = Set<String>()
            return (advertised ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    static func isOffered(_ level: String, for provider: RunProvider, model: String?, advertised: [String]? = nil) -> Bool {
        levels(for: provider, model: model, advertised: advertised).contains(level.lowercased())
    }

    static func label(_ level: String?) -> String { "effort.level.\(level ?? "default")" }

    /// The label of a model's level (see `ModelVariants`): the member without a level reads "Default".
    static func label(variant level: String) -> String { label(level.isEmpty ? nil : level) }
}

enum EffortStep {
    enum Direction: Sendable { case up, down }

    /// nil is the agent's default and sits below the lowest level: up from default gives the first level, down from the
    /// first level gives default; the ends stay put.
    static func next(current: String?, levels: [String], direction: Direction) -> String? {
        guard !levels.isEmpty else { return nil }
        let index = current.flatMap { levels.firstIndex(of: $0) }
        switch direction {
        case .up:
            guard let index else { return levels[0] }
            return levels[min(index + 1, levels.count - 1)]
        case .down:
            guard let index, index > 0 else { return nil }
            return levels[index - 1]
        }
    }
}

/// A stored effort the live session does not offer is skipped, not failed.
struct EffortResolution: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case use, skip }
    var outcome: Outcome
    var effort: String?

    static func resolve(stored: String?, offered: [String]) -> EffortResolution {
        guard let stored, !stored.isEmpty else { return EffortResolution(outcome: .skip, effort: nil) }
        return offered.contains(stored) ? EffortResolution(outcome: .use, effort: stored) : EffortResolution(outcome: .skip, effort: nil)
    }
}

enum CodexTurnEffort {
    /// Merge into `CodexRPC.turnStartParams` result: Codex's `turn/start` takes a top-level `effort` string
    /// (CodexAdapterV2.ts: `...(effort === undefined ? {} : { effort })`). Empty when there is none.
    static func param(effort: String?) -> [String: Any] {
        guard let effort, !effort.isEmpty else { return [:] }
        return ["effort": effort]
    }
}
