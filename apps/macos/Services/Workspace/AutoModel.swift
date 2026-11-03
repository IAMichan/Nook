import Foundation

/// "Auto" in an agent's model menu: Nook picks the model for each turn itself, among the models you allow in
/// Settings › Workspace › Auto model choice, from what the turn asks for and how much room the account's usage limits
/// leave. A light question goes to a light model, heavy work to a strong one, and when a 5-hour or weekly window runs
/// full (or fills faster than it resets) Nook steps down to spare it. The same for every agent: a model's weight is read
/// from its name, so it also works for the models an ACP agent lists itself. Depends only on Foundation so tests can use it.
enum AutoModel {
    /// The value "Auto" is stored under, as a session's or Settings' model.
    static let id = "auto"

    /// How heavy a model is, or how heavy a turn is.
    enum Tier: Int, Comparable, CaseIterable, Sendable {
        case light, standard, strong

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        /// The key of how the tier reads (`auto.tier.*`).
        var key: String { "auto.tier.\(self)" }
    }

    /// How much room the usage limits leave.
    enum Pressure: Int, Comparable, Sendable {
        case relaxed, tight, critical

        static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
    }

    /// One usage window of the account: how full it is, and how far into the window we are (0...1, nil when unknown).
    struct Window: Equatable, Sendable {
        var percent: Double
        var elapsed: Double?
    }

    /// A model Nook may pick, in the order of the agent's menu.
    struct Candidate: Equatable, Sendable {
        var id: String
        var name: String
    }

    /// What Nook picked and why.
    struct Decision: Equatable, Sendable {
        var model: String
        /// The tier of the picked model.
        var tier: Tier
        /// What the turn asked for.
        var need: Tier
        var pressure: Pressure
        /// The fullest window, for the reason Nook gives.
        var fullest: Double
    }

    // MARK: Models

    private static let lightWords = ["haiku", "mini", "nano", "flash", "lite", "small", "fast", "spark", "instant"]
    private static let strongWords = ["opus", "fable", "max", "pro", "ultra", "large"]

    /// A model's weight from its id and name: "Claude Haiku 5.5" and "gpt-5-mini" are light, "Claude Opus 5.5",
    /// "GPT-5.1-Codex-Max" and "Gemini 3 Pro" strong, anything else standard. A light word wins: "Gemini Flash Pro" is light.
    static func tier(of candidate: Candidate) -> Tier {
        let words = Set((candidate.id + " " + candidate.name).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if lightWords.contains(where: words.contains) { return .light }
        if strongWords.contains(where: words.contains) { return .strong }
        return .standard
    }

    // MARK: The turn

    /// Work that wants a strong model (English and Dutch, the languages most prompts here come in; others fall back on length).
    private static let heavyWords = [
        "architecture", "architect", "refactor", "redesign", "rewrite", "migrate", "migration", "debug", "investigate",
        "root cause", "race condition", "concurrency", "deadlock", "performance", "security", "vulnerability", "design",
        "implement", "feature", "algorithm", "optimize", "optimise", "plan", "complex", "across", "entire", "whole",
        "integration", "parity",
        "architectuur", "herschrijf", "herstructureer", "migreer", "onderzoek", "oorzaak", "ontwerp", "implementeer",
        "bouw", "optimaliseer", "ingewikkeld", "geheel", "hele", "overal", "slim", "slimmer",
    ]

    /// Work a light model does as well.
    private static let lightTaskWords = [
        "typo", "rename", "format", "lint", "comment", "commit", "push", "translate", "summarize", "summarise", "explain",
        "what is", "what does", "list", "bump", "version", "changelog", "readme", "status",
        "spelfout", "hernoem", "formatteer", "vertaal", "samenvatting", "vat samen", "leg uit", "wat is", "wat doet",
        "versie", "opsomming",
    ]

    /// What a turn asks for: its words, its length and the effort you set.
    static func need(prompt: String, effort: String? = nil) -> Tier {
        let text = " " + prompt.lowercased() + " "
        let length = prompt.trimmingCharacters(in: .whitespacesAndNewlines).count
        let heavy = heavyWords.filter { contains(text, $0) }.count
        let light = lightTaskWords.filter { contains(text, $0) }.count
        var tier: Tier = .standard
        if length > 1500 || heavy >= 2 || (heavy == 1 && length > 300) {
            tier = .strong
        } else if heavy == 0 && length < 300 && (light > 0 || length < 40) {
            tier = .light
        }
        switch effort?.lowercased() {
        case "high", "xhigh", "max", "thinking": return max(tier, .standard)
        case "low", "minimal": return min(tier, .standard)
        default: return tier
        }
    }

    /// `word` as a whole word or phrase in `text` (which starts and ends with a space).
    private static func contains(_ text: String, _ word: String) -> Bool {
        guard let range = text.range(of: word) else { return false }
        let before = text[text.index(before: range.lowerBound)]
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
        return !before.isLetter && !after.isLetter
    }

    // MARK: Limits

    /// The room the windows leave: critical from 90 % in any window, tight from 70 % or when a window fills clearly
    /// faster than it resets (well ahead of an even pace).
    static func pressure(_ windows: [Window]) -> Pressure {
        var result: Pressure = .relaxed
        for window in windows {
            if window.percent >= 90 { return .critical }
            let ahead = window.elapsed.map { window.percent >= 40 && window.percent > $0 * 100 + 20 } ?? false
            if window.percent >= 70 || ahead { result = .tight }
        }
        return result
    }

    // MARK: Picking

    /// The model for a turn: what it asks for, capped at standard when the limits are tight and light when they are
    /// critical; of the allowed models the one closest to that, a lighter one before a heavier one at equal distance
    /// under pressure, and the first in menu order among equals. Nil when nothing is allowed: the agent's own default runs.
    static func pick(_ candidates: [Candidate], need: Tier, windows: [Window]) -> Decision? {
        let pressure = pressure(windows)
        let target: Tier
        switch pressure {
        case .relaxed: target = need
        case .tight: target = min(need, .standard)
        case .critical: target = .light
        }
        let rated = candidates.enumerated().map { (index: $0.offset, candidate: $0.element, tier: tier(of: $0.element)) }
        let best = rated.min { a, b in
            let distanceA = abs(a.tier.rawValue - target.rawValue), distanceB = abs(b.tier.rawValue - target.rawValue)
            if distanceA != distanceB { return distanceA < distanceB }
            if a.tier != b.tier { return pressure == .relaxed ? a.tier > b.tier : a.tier < b.tier }
            return a.index < b.index
        }
        guard let best else { return nil }
        return Decision(model: best.candidate.id, tier: best.tier, need: need, pressure: pressure,
                        fullest: windows.map(\.percent).max() ?? 0)
    }

    /// The models Nook may pick from: the ones you allowed that the agent still offers, or, when you allowed none, every
    /// current model it offers. Models waiting on an agent update and older ones are never picked on their own.
    static func candidates(_ choices: [ModelChoice], allowed: [String], same: (String, String) -> Bool) -> [Candidate] {
        let usable = choices.filter { !$0.id.isEmpty && !$0.needsUpdate }
        let picked = allowed.isEmpty
            ? usable.filter { !$0.isLegacy }
            : usable.filter { choice in allowed.contains { same($0, choice.id) } }
        return picked.map { Candidate(id: $0.id, name: $0.name) }
    }

    /// The key of the reason Nook gives in the session (`auto.reason.*`).
    static func reasonKey(_ decision: Decision) -> String {
        switch decision.pressure {
        case .critical: return "auto.reason.critical"
        case .tight where decision.need > decision.tier: return "auto.reason.tight"
        default: return "auto.reason." + String(describing: decision.need)
        }
    }
}
