import Foundation

// Per-project defaults for new sessions on top of the global ones (Settings › Workspace). A project folder may set its own
// agent, model per agent, access level, worktree on or off, branch prefix and rules for session titles; whatever it leaves out comes from the global
// value. Built on `SettingsResolver`: the global values are its `.environment` layer ("all projects", see
// `ProjectScope.writeLayer`), a folder's overrides its `.project` layer. Foundation only, so it is tested on its own.

/// The settings a project can override. The model is kept per agent ("model.claude").
enum ProjectSettingKey: Hashable, Sendable {
    case provider
    case model(RunProvider)
    case permission
    case isolation
    case branchPrefix
    /// The user's own rules for written session titles.
    case titleInstructions
    /// Whether Nook's worktree cleanup rules apply to the project ("on") or not ("off").
    case worktreeCleanup
    /// Whether the project's browsers keep their sign-ins between launches ("on"), forget them ("off") or ask at the first
    /// sign-in ("ask"); see `BrowserSignInPolicy`.
    case browserSignIns

    var raw: String {
        switch self {
        case .provider: return "provider"
        case .model(let provider): return "model." + provider.rawValue
        case .permission: return "permission"
        case .isolation: return "isolation"
        case .branchPrefix: return "branchPrefix"
        case .titleInstructions: return "titleInstructions"
        case .worktreeCleanup: return "worktreeCleanup"
        case .browserSignIns: return "browserSignIns"
        }
    }
}

/// What a new session starts with, resolved for one folder (or the global values themselves).
struct SessionDefaults: Equatable, Sendable {
    var provider: RunProvider
    /// Model per agent (raw value → model id); absent or empty is the agent's own default.
    var models: [String: String]
    var permission: PermissionPolicy
    var isolation: IsolationMode
    var branchPrefix: String
    /// Added to the prompt that writes a session's title; empty: Nook's own rules only.
    var titleInstructions: String = ""
    /// The cleanup rules from Settings › Workspace apply to this project's worktrees; off: they stay until you remove them.
    var worktreeCleanup = true
    /// Whether the project's browsers remember sign-ins after Nook quits. Ask (the default): the first sign-in asks.
    var browserSignIns: BrowserSignInPolicy = .ask

    func model(for provider: RunProvider) -> String { models[provider.rawValue] ?? "" }

    /// The access level for this agent: the chosen one when the agent supports it, else a safe one it does.
    func permission(for provider: RunProvider) -> PermissionPolicy {
        provider.capabilities.policies.contains(permission) ? permission : .acceptEdits
    }
}

/// What Nook does with what a browser signed in to: keep it after Nook quits, forget it, or ask at the first sign-in.
/// Stored as "on", "off" and "ask" (a project's override has used "on" and "off" from the start).
enum BrowserSignInPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask, keep, forget

    var id: String { rawValue }

    init?(stored: String) {
        switch stored {
        case "on": self = .keep
        case "off": self = .forget
        case "ask": self = .ask
        default: return nil
        }
    }

    var stored: String {
        switch self {
        case .keep: return "on"
        case .forget: return "off"
        case .ask: return "ask"
        }
    }
}

/// Every folder's overrides, stored as one value (UserDefaults, JSON). A key a folder does not set inherits.
struct ProjectOverrides: Codable, Equatable, Sendable {
    /// Normalized folder path → raw key → value.
    var byProject: [String: [String: SettingValue]] = [:]

    init(byProject: [String: [String: SettingValue]] = [:]) { self.byProject = byProject }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byProject = (try? c.decode([String: [String: SettingValue]].self, forKey: .byProject)) ?? [:]
    }

    /// The folders that override anything, sorted.
    var projects: [String] { byProject.filter { !$0.value.isEmpty }.keys.sorted() }

    func values(for project: String) -> [String: SettingValue] { byProject[Self.normalize(project)] ?? [:] }

    func isOverridden(_ key: ProjectSettingKey, for project: String) -> Bool { values(for: project)[key.raw] != nil }

    mutating func set(_ key: ProjectSettingKey, _ value: SettingValue, for project: String) {
        let path = Self.normalize(project)
        guard !path.isEmpty else { return }
        byProject[path, default: [:]][key.raw] = value
    }

    /// Back to "inherited": the folder stops setting the key. A folder with nothing left is forgotten.
    mutating func reset(_ key: ProjectSettingKey, for project: String) {
        let path = Self.normalize(project)
        byProject[path]?[key.raw] = nil
        if byProject[path]?.isEmpty == true { byProject[path] = nil }
    }

    mutating func resetAll(for project: String) { byProject[Self.normalize(project)] = nil }

    /// The stored project a folder belongs to: the folder itself, else the closest folder above it that has overrides
    /// (a subfolder or a worktree path inside the repository gets its repository's settings).
    func project(containing folder: String) -> String? {
        let path = Self.normalize(folder)
        guard !path.isEmpty else { return nil }
        return projects.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    /// "/Users/me/app/" and "/Users/me/app" are the same project.
    static func normalize(_ path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.count > 1, clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }
}

/// What you last chose in the new-session composer for one folder. Values are raw strings, so one that a later version
/// no longer knows falls back on its own instead of losing the whole folder.
struct FolderChoices: Codable, Equatable, Sendable {
    /// What was chosen for one agent. Stored apart per agent, so going back to it in this folder finds them again.
    struct Agent: Codable, Equatable, Sendable {
        var profileID: String
        /// Empty: the agent's own default.
        var model: String
        /// Nil: the agent's own default, also when another folder has a level.
        var effort: String?
    }

    var provider: String
    var mode: String
    var permission: String
    var isolation: String
    /// Raw agent → what was chosen for it here.
    var agents: [String: Agent] = [:]
}

/// Every folder's `FolderChoices` (UserDefaults, JSON). Unlike `ProjectOverrides`, which you set in Settings and which a
/// subfolder inherits, these follow the composer and hold for exactly the folder they were made in.
struct FolderChoicesStore: Codable, Equatable, Sendable {
    /// Normalized folder path → its choices.
    var byFolder: [String: FolderChoices] = [:]

    func choices(for folder: String?) -> FolderChoices? {
        folder.flatMap { byFolder[WorkspacePathPolicy.normalize($0)] }
    }

    /// Keeps what `config` chose for its folder. A folder made for "No project" is used once, so it keeps nothing.
    mutating func remember(_ config: NewRunConfig) {
        let path = WorkspacePathPolicy.normalize(config.projectPath)
        guard !path.isEmpty, !ScratchProjects.isScratch(path) else { return }
        var choices = byFolder[path] ?? FolderChoices(provider: "", mode: "", permission: "", isolation: "")
        choices.provider = config.provider.rawValue
        choices.mode = config.mode.rawValue
        choices.permission = config.permission.rawValue
        choices.isolation = config.isolation.rawValue
        choices.agents[config.provider.rawValue] = .init(profileID: config.profileID, model: config.model, effort: config.effort)
        byFolder[path] = choices
    }

    mutating func forget(_ folder: String) { byFolder[WorkspacePathPolicy.normalize(folder)] = nil }
}

/// What the new-session composer starts with in a folder: what the folder sets in Settings, else what you last chose
/// there, else your last choices anywhere. The other ways to start a session read the same values.
struct ComposerDefaults: Equatable, Sendable {
    var session: SessionDefaults
    var mode: ExecutionMode
    /// The accounts last chosen per agent, in the order to try them: this folder's first.
    var profiles: [String: [String]]
    /// The effort for each agent this folder chose for; other agents use `globalEfforts`.
    var folderEfforts: [String: String?]
    var globalEfforts: [String: String]

    var provider: RunProvider { session.provider }
    var isolation: IsolationMode { session.isolation }

    func model(for provider: RunProvider) -> String { session.model(for: provider) }

    func permission(for provider: RunProvider) -> PermissionPolicy { session.permission(for: provider) }

    /// The account to use among the `connected` ones, nil when none of them is remembered or connected.
    func profile(for provider: RunProvider, connected: [String]) -> String? {
        (profiles[provider.rawValue] ?? []).first(where: connected.contains) ?? connected.first
    }

    /// The effort for this agent, while the agent still offers it. An ACP agent's levels are the ones its session
    /// offered: the level stays, and a session that does not offer it skips it (see `AcpSessionSettings`).
    func effort(for provider: RunProvider) -> String? {
        let level = folderEfforts[provider.rawValue] ?? globalEfforts[provider.rawValue]
        return level.flatMap { provider.usesACP || EffortLevels.isOffered($0, for: provider, model: nil) ? $0 : nil }
    }
}

enum ProjectSettings {
    /// The composer's defaults for a folder: what it sets in `overrides` wins over `choices`, which win over the global
    /// values, so an explicit setting stays in charge of whatever the composer remembers.
    static func composerDefaults(global: SessionDefaults, mode: ExecutionMode, profiles: [String: String],
                                 efforts: [String: String], overrides: ProjectOverrides,
                                 choices: FolderChoices?, folder: String?) -> ComposerDefaults {
        var base = global
        var result = ComposerDefaults(session: global, mode: mode, profiles: profiles.mapValues { [$0] },
                                      folderEfforts: [:], globalEfforts: efforts)
        if let choices {
            base.provider = RunProvider(rawValue: choices.provider) ?? global.provider
            base.permission = PermissionPolicy(rawValue: choices.permission) ?? global.permission
            base.isolation = IsolationMode(rawValue: choices.isolation) ?? global.isolation
            result.mode = ExecutionMode(rawValue: choices.mode) ?? mode
            for (agent, chosen) in choices.agents {
                base.models[agent] = chosen.model
                result.profiles[agent] = [chosen.profileID] + (profiles[agent].map { [$0] } ?? [])
                result.folderEfforts[agent] = .some(chosen.effort)
            }
        }
        result.session = resolve(global: base, overrides: overrides, folder: folder)
        return result
    }

    /// The two layers the resolver reads: the global values and the folder's overrides.
    static func layers(global: SessionDefaults, overrides: [String: SettingValue]) -> SettingsResolver.Layers {
        var layers = SettingsResolver.Layers()
        layers.set(ProjectSettingKey.provider.raw, .string(global.provider.rawValue), in: .environment)
        for provider in RunProvider.allCases {
            layers.set(ProjectSettingKey.model(provider).raw, .string(global.model(for: provider)), in: .environment)
        }
        layers.set(ProjectSettingKey.permission.raw, .string(global.permission.rawValue), in: .environment)
        layers.set(ProjectSettingKey.isolation.raw, .string(global.isolation.rawValue), in: .environment)
        layers.set(ProjectSettingKey.branchPrefix.raw, .string(global.branchPrefix), in: .environment)
        layers.set(ProjectSettingKey.titleInstructions.raw, .string(global.titleInstructions), in: .environment)
        layers.set(ProjectSettingKey.worktreeCleanup.raw, .string(global.worktreeCleanup ? "on" : "off"), in: .environment)
        for (key, value) in overrides { layers.set(key, value, in: .project) }
        return layers
    }

    /// The defaults for a folder: each value from its overrides when it sets one (and the value is still valid), else
    /// the global one.
    static func resolve(global: SessionDefaults, overrides: ProjectOverrides, folder: String?) -> SessionDefaults {
        guard let folder, let project = overrides.project(containing: folder) else { return global }
        let layers = layers(global: global, overrides: overrides.values(for: project))
        func string(_ key: ProjectSettingKey) -> String? {
            if case .string(let value)? = SettingsResolver.resolve(key.raw, layers)?.value { return value }
            return nil
        }
        var result = global
        result.provider = string(.provider).flatMap(RunProvider.init(rawValue:)) ?? global.provider
        for provider in RunProvider.allCases {
            if let model = string(.model(provider)) { result.models[provider.rawValue] = model }
        }
        result.permission = string(.permission).flatMap(PermissionPolicy.init(rawValue:)) ?? global.permission
        result.isolation = string(.isolation).flatMap(IsolationMode.init(rawValue:)) ?? global.isolation
        result.branchPrefix = string(.branchPrefix).map(WorktreeNaming.normalizedBranchPrefix) ?? global.branchPrefix
        result.titleInstructions = string(.titleInstructions) ?? global.titleInstructions
        result.worktreeCleanup = string(.worktreeCleanup).map { $0 != "off" } ?? global.worktreeCleanup
        result.browserSignIns = string(.browserSignIns).flatMap(BrowserSignInPolicy.init(stored:)) ?? global.browserSignIns
        return result
    }

    /// How a row reads in the editor of `scope`: inherited from the global value, or set for this project.
    static func provenance(_ key: ProjectSettingKey, global: SessionDefaults, overrides: ProjectOverrides,
                           scope: ProjectScope) -> SettingsResolver.Provenance? {
        let values: [String: SettingValue]
        switch scope {
        case .allProjects: values = [:]
        case .project(let path): values = overrides.values(for: path)
        }
        return SettingsResolver.provenance(key.raw, layers(global: global, overrides: values), at: scope.writeLayer)
    }

    /// A branch name made with the global prefix ("nook/fix-login-3fa2"), carried over to the project's own prefix
    /// ("team/fix-login-3fa2"). Any other name is left as it is.
    static func branchName(_ name: String, globalPrefix: String, projectPrefix: String) -> String {
        let from = WorktreeNaming.normalizedBranchPrefix(globalPrefix) + "/"
        let to = WorktreeNaming.normalizedBranchPrefix(projectPrefix) + "/"
        guard from != to, name.hasPrefix(from) else { return name }
        return to + name.dropFirst(from.count)
    }

    /// Whether `path` is among `favorites` once both are normalized.
    static func isFavorite(_ path: String, in favorites: [String],
                           normalize: (String) -> String = ProjectOverrides.normalize) -> Bool {
        let clean = normalize(path)
        guard !clean.isEmpty else { return false }
        return favorites.contains { normalize($0) == clean }
    }

    /// Adds `path` to `favorites`, or removes it when it is already one, keeping the order of the rest.
    static func togglingFavorite(_ path: String, in favorites: [String],
                                 normalize: (String) -> String = ProjectOverrides.normalize) -> [String] {
        let clean = normalize(path)
        guard !clean.isEmpty else { return favorites }
        let normalized = favorites.map(normalize).filter { !$0.isEmpty }
        if normalized.contains(clean) {
            return normalized.filter { $0 != clean }
        }
        return normalized + [clean]
    }

    /// The folders the new-session menu offers: your favorites on top (never dropped), then the recent ones that are not
    /// already favorites, up to `limit` in total (and at least three recent ones when there are more).
    static func projectMenu(favorites: [String], recent: [String],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            normalize: (String) -> String = WorkspacePathPolicy.normalize,
                            limit: Int = 10) -> (favorites: [String], recent: [String]) {
        var seen: Set<String> = []
        var starred: [String] = []
        for path in favorites where !path.isEmpty {
            let clean = normalize(path)
            guard !clean.isEmpty, seen.insert(clean).inserted, exists(clean) else { continue }
            starred.append(clean)
        }
        let recentLimit = max(3, limit - starred.count)
        var recents: [String] = []
        for path in recent where !path.isEmpty {
            let clean = normalize(path)
            guard !clean.isEmpty, seen.insert(clean).inserted, exists(clean) else { continue }
            recents.append(clean)
            if recents.count == recentLimit { break }
        }
        return (starred, recents)
    }

    /// The project folders the scope picker offers: the favorite and recent ones, then any other folder that still has overrides.
    static func scopeChoices(favorites: [String] = [], recent: [String], overrides: ProjectOverrides, limit: Int = 12) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in favorites.map(ProjectOverrides.normalize) where !path.isEmpty && seen.insert(path).inserted {
            result.append(path)
        }
        let recentLimit = max(limit, result.count)
        for path in recent.map(ProjectOverrides.normalize) where !path.isEmpty && result.count < recentLimit && seen.insert(path).inserted {
            result.append(path)
        }
        // A folder with overrides is never dropped, however long ago it was used.
        for path in overrides.projects where seen.insert(path).inserted { result.append(path) }
        return result
    }
}
