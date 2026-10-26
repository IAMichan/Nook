import Foundation

// Per-project defaults for new sessions on top of the global ones (Settings › Workspace). A project folder may set its own
// agent, model per agent, access level, worktree on or off and branch prefix; whatever it leaves out comes from the global
// value. Built on `SettingsResolver`: the global values are its `.environment` layer ("all projects", see
// `ProjectScope.writeLayer`), a folder's overrides its `.project` layer. Foundation only, so it is tested on its own.

/// The settings a project can override. The model is kept per agent ("model.claude").
enum ProjectSettingKey: Hashable, Sendable {
    case provider
    case model(RunProvider)
    case permission
    case isolation
    case branchPrefix

    var raw: String {
        switch self {
        case .provider: return "provider"
        case .model(let provider): return "model." + provider.rawValue
        case .permission: return "permission"
        case .isolation: return "isolation"
        case .branchPrefix: return "branchPrefix"
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

    func model(for provider: RunProvider) -> String { models[provider.rawValue] ?? "" }

    /// The access level for this agent: the chosen one when the agent supports it, else a safe one it does.
    func permission(for provider: RunProvider) -> PermissionPolicy {
        provider.capabilities.policies.contains(permission) ? permission : .acceptEdits
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

enum ProjectSettings {
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

    /// The project folders the scope picker offers: the recent ones, then any other folder that still has overrides.
    static func scopeChoices(recent: [String], overrides: ProjectOverrides, limit: Int = 12) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in recent.map(ProjectOverrides.normalize) where !path.isEmpty && result.count < limit && seen.insert(path).inserted {
            result.append(path)
        }
        // A folder with overrides is never dropped, however long ago it was used.
        for path in overrides.projects where seen.insert(path).inserted { result.append(path) }
        return result
    }
}
