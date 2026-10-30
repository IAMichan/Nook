import Foundation

/// One agent's model and effort controls, worked out in one place for every agent: the models it offers (its own list,
/// the model manifest, the ones you typed), how a model reads and which alias stands for it, which older ones stay out of
/// the menu, models listed once per thinking level (`ModelVariants`), and the effort levels. The composer, the new-session
/// box, the session settings and Settings all read it, so they cannot disagree.
///
/// What differs per agent stays where it is described once: the manifest's entry (`ModelManifest`), the agent's own list
/// (`AgentModelCatalog`), its effort levels (`EffortLevels.levels`), and an ACP agent you added keeps its own models and
/// levels (by its profile). Depends only on Foundation so tests can use it.
struct AgentModelMenu {
    let provider: RunProvider
    var manifest: ModelManifest?
    /// What the agent listed itself: Codex `model/list`, an ACP session's models (an agent you added: its own).
    var offered: [AgentModel] = []
    /// The thinking levels it listed itself (an ACP session's `thought_level` option), under its own names.
    var offeredEfforts: [AgentModel] = []
    /// The agent's version (`--version`), for models that need a newer one.
    var installed: String?
    /// The model ids you typed for it, and your favorites.
    var custom: [String] = []
    var favorites: [String] = []

    // MARK: Models

    /// The models to offer (see `ModelChoice.list`).
    var choices: [ModelChoice] {
        ModelChoice.list(manifest: manifest, provider: provider, offered: offered, installed: installed)
    }

    /// The menu entry `id` stands for, also under an alias ("opus").
    func choice(_ id: String) -> ModelChoice? {
        guard !id.isEmpty else { return nil }
        let all = choices
        if let exact = all.first(where: { $0.id == id }) { return exact }
        guard var alias = all.first(where: { same($0.id, id) }) else { return nil }
        // The agent resolves an alias itself, to the newest model it knows: a saved "opus" never waits on an update.
        alias.requiredVersion = nil
        return alias
    }

    /// Whether two names stand for one model ("opus" and "claude-opus-5-5").
    func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty, let manifest else { return false }
        return manifest.canonicalID(a, for: provider) == manifest.canonicalID(b, for: provider)
    }

    /// The menu: the agent's default (""), its models, the ones you typed and `extra` (the model in use, recent ones),
    /// each once even under another name, and your favorites first.
    func ids(extra: [String] = []) -> [String] {
        var list = [""]
        for id in choices.map(\.id) + custom + extra where !id.isEmpty && !list.contains(where: { same($0, id) }) {
            list.append(id)
        }
        return ModelOrdering.sorted(list, favorites: favorites)
    }

    /// An older model the menu leaves out until you search for it, unless it is in use or a favorite.
    func hidesLegacy(_ id: String, chosen: String) -> Bool {
        guard choice(id)?.isLegacy == true else { return false }
        return !same(id, chosen) && !favorites.contains(id)
    }

    /// How a model reads: the agent's own name, the manifest's, or the id itself; nil for the agent's default ("").
    func name(_ id: String) -> String? {
        id.isEmpty ? nil : choice(id)?.name ?? id
    }

    // MARK: Models per thinking level

    /// The models grouped by thinking level: those an agent over ACP lists itself. Claude Code and Codex take the level
    /// as a setting of its own (`--effort`, `effort`), so their names are never read as levels.
    private var levelled: [AgentModel] { provider.usesACP ? offered : [] }

    /// The family `id` belongs to when the agent lists one model per thinking level (Antigravity's "Gemini 3 Pro (High)"
    /// and "(Low)"): its level is then picked with the effort control.
    func family(of id: String) -> ModelVariants.Family? {
        ModelVariants.family(of: id, in: levelled)
    }

    /// `ids` with one entry per family.
    func collapsed(_ ids: [String]) -> [String] {
        ModelVariants.collapse(ids, in: levelled)
    }

    /// The model to run when you pick `id` while `current` is chosen: the same level in the new family when it has one.
    func pick(_ id: String, keeping current: String) -> String {
        ModelVariants.pick(id, keeping: current, in: levelled)
    }

    // MARK: Effort

    /// The effort levels for `model`: the agent's own (Claude Code, Codex), or the ones it offered (ACP agents).
    func effortLevels(model: String?) -> [String] {
        EffortLevels.levels(for: provider, model: model, advertised: offeredEfforts.isEmpty ? nil : offeredEfforts.map(\.id))
    }

    /// The key of how a level reads when Nook has a word for it (`effort.level.*`), else nil (see `effortName`).
    static func effortKey(_ level: String?) -> String? {
        guard let level else { return EffortLevels.label(nil) }
        return EffortLevels.known.contains(level.lowercased()) ? EffortLevels.label(level.lowercased()) : nil
    }

    /// A level Nook has no word for, under the agent's own name for it.
    func effortName(_ level: String) -> String {
        offeredEfforts.first { $0.id == level }?.name ?? level
    }
}
