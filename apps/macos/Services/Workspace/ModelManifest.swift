import Foundation

/// Which models Nook offers each agent and which agent version each one needs. A copy ships with the app
/// (`model-manifest.json` next to this file); a fresh copy is fetched from Nook's repository, so a new model shows up
/// between releases. A copy that fails validation never replaces a valid one, and a newer bundle wins over an older
/// fetched copy by `updatedAt`. See docs/MODEL-MANIFEST.md. Depends only on Foundation so tests can use it.
struct ModelManifest: Codable, Equatable, Sendable {
    /// The schema this build reads; a manifest with another version is refused and the copy in use stays.
    static let schemaVersion = 1
    /// A manifest is a few kilobytes: anything this large is not one.
    static let maxBytes = 256 * 1024
    static let maxModelsPerAgent = 100
    static let resourceName = "model-manifest"
    /// The copy on Nook's main branch: the bundled file itself, so a JSON edit there reaches every install.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/IAMichan/nook/main/apps/macos/Services/Workspace/model-manifest.json")!

    var version: Int
    /// When the file was last edited (ISO 8601, no fractions). Bump it on every change: it decides which copy wins.
    var updatedAt: Date
    /// Keyed by `RunProvider.rawValue`. A key this build does not know is kept but not used.
    var agents: [String: Agent]

    struct Agent: Codable, Equatable, Sendable {
        /// The model the agent runs when Nook passes none, when the manifest knows it.
        var defaultModel: String?
        var models: [Model]
    }

    enum Status: String, Codable, Sendable {
        case current, legacy
    }

    struct Model: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var status: Status
        /// "new" shows a New label in the picker.
        var badge: String?
        /// Other names the agent accepts for this model ("opus"), so a saved alias still reads as this model.
        var aliases: [String]?
        /// Per agent, keyed like `agents`: what that agent needs to run the model.
        var adapter: [String: Adapter]?
    }

    struct Adapter: Codable, Equatable, Sendable {
        /// The oldest CLI version that runs the model ("2.1.280"); an older one shows the model as "update required".
        var minVersion: String?
    }

    // MARK: Reading

    /// Decodes and validates a manifest. Throws for anything Nook should not use.
    static func parse(_ data: Data) throws -> ModelManifest {
        guard data.count <= maxBytes else { throw ModelManifestError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The version first: a later schema may not decode as this one, and should read as "unsupported", not "broken".
        struct Header: Decodable { var version: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw ModelManifestError.unreadable }
        guard header.version == schemaVersion else { throw ModelManifestError.unsupportedVersion(header.version) }
        let manifest: ModelManifest
        do { manifest = try decoder.decode(ModelManifest.self, from: data) } catch { throw ModelManifestError.unreadable }
        try manifest.validate()
        return manifest
    }

    /// The copy that ships with the app.
    static func bundled(in bundle: Bundle = .main) -> ModelManifest? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? parse(data)
    }

    /// Checks what decoding cannot: every id is usable as a `--model` argument, no name is used twice within an agent,
    /// the default is one of the models, and every `minVersion` is a version for the agent that owns the entry.
    func validate() throws {
        guard version == Self.schemaVersion else { throw ModelManifestError.unsupportedVersion(version) }
        guard !agents.isEmpty else { throw ModelManifestError.invalid("no agents") }
        for (key, agent) in agents.sorted(by: { $0.key < $1.key }) {
            guard !agent.models.isEmpty, agent.models.count <= Self.maxModelsPerAgent else {
                throw ModelManifestError.invalid("\(key): \(agent.models.count) models")
            }
            var names = Set<String>()
            for model in agent.models {
                let title = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 80, !title.contains(where: \.isNewline) else {
                    throw ModelManifestError.invalid("\(key): name of \(model.id)")
                }
                for name in [model.id] + (model.aliases ?? []) {
                    guard Self.isValidID(name) else { throw ModelManifestError.invalid("\(key): id \"\(name)\"") }
                    guard names.insert(name.lowercased()).inserted else {
                        throw ModelManifestError.invalid("\(key): \"\(name)\" is used twice")
                    }
                }
                for (owner, adapter) in model.adapter ?? [:] {
                    // A provider reads only its own entry: settings for another agent are a mistake in the file.
                    guard owner == key else { throw ModelManifestError.invalid("\(key): \(model.id) has settings for \(owner)") }
                    if let minimum = adapter.minVersion, CLIVersion(minimum) == nil {
                        throw ModelManifestError.invalid("\(key): minVersion \"\(minimum)\" of \(model.id)")
                    }
                }
            }
            if let fallback = agent.defaultModel, !agent.models.contains(where: { $0.id == fallback }) {
                throw ModelManifestError.invalid("\(key): default \(fallback) is not listed")
            }
        }
    }

    /// A model id Nook may pass to an agent: 1 to 128 letters, digits and `._:/@[]-`, not starting with "-" (it would
    /// read as an option). Used for the manifest's ids and for the ones you type yourself.
    static func isValidID(_ id: String) -> Bool {
        guard (1...128).contains(id.count), !id.hasPrefix("-") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:/@[]-".unicodeScalars.contains(scalar))
        }
    }

    // MARK: Choosing a copy

    /// The copy to use: the fetched one, unless the bundled one is newer (a release can correct model data before the
    /// next successful fetch). The time of a fetch cannot tell which copy holds the newer edit; `updatedAt` can.
    static func preferred(bundled: ModelManifest?, cached: ModelManifest?) -> ModelManifest? {
        guard let cached else { return bundled }
        guard let bundled else { return cached }
        return cached.updatedAt > bundled.updatedAt ? cached : bundled
    }

    /// What a fetch leaves in use: the fetched copy when it is valid and not older than `current`, else nil (the copy in
    /// use stays, so a broken or stale file on the server never takes the models away).
    static func accepting(_ data: Data, over current: ModelManifest?) -> ModelManifest? {
        guard let fetched = try? parse(data) else { return nil }
        if let current, fetched.updatedAt < current.updatedAt { return nil }
        return fetched
    }

    // MARK: Looking up

    func entry(for provider: RunProvider) -> Agent? { agents[provider.rawValue] }

    /// The model `id` names for this agent, by id or alias, ignoring case.
    func model(_ id: String, for provider: RunProvider) -> Model? {
        guard !id.isEmpty, let models = entry(for: provider)?.models else { return nil }
        let lower = id.lowercased()
        return models.first { $0.id.lowercased() == lower }
            ?? models.first { ($0.aliases ?? []).contains { $0.lowercased() == lower } }
    }

    /// The id `id` stands for ("opus" → "claude-opus-5-5"); an id the manifest does not know stays as it is.
    func canonicalID(_ id: String, for provider: RunProvider) -> String {
        model(id, for: provider)?.id ?? id
    }

    /// The agent version the model needs when `installed` is older; nil when it runs, or when either version is unknown
    /// (Nook only says "update" when it is sure).
    func requiredVersion(_ id: String, for provider: RunProvider, installed: String?) -> String? {
        guard let minimum = model(id, for: provider)?.adapter?[provider.rawValue]?.minVersion,
              let needed = CLIVersion(minimum), let installed, let have = CLIVersion(installed), have < needed else { return nil }
        return minimum
    }
}

enum ModelManifestError: Error, Equatable {
    case tooLarge
    case unreadable
    case unsupportedVersion(Int)
    case invalid(String)
}

/// A version an agent CLI prints: "2.1.280 (Claude Code)", "codex-cli 0.153.0", "v1.2.3-beta.1". The first token that
/// starts with a digit (after an optional "v") counts; numeric parts compare as numbers, and a pre-release sorts before
/// its release.
struct CLIVersion: Comparable, Sendable, CustomStringConvertible {
    var parts: [Int]
    var prerelease: String?

    init?(_ text: String) {
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," }) {
            var token = Substring(raw)
            if token.first == "v" || token.first == "V" { token = token.dropFirst() }
            guard token.first?.isNumber == true else { continue }
            let main = token.split(separator: "+", maxSplits: 1).first ?? token
            let pieces = main.split(separator: "-", maxSplits: 1)
            let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.count <= 6, numbers.allSatisfy({ $0 != nil }) else { continue }
            parts = numbers.compactMap { $0 }
            prerelease = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : nil
            return
        }
        return nil
    }

    var description: String { parts.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    static func == (a: CLIVersion, b: CLIVersion) -> Bool { !(a < b) && !(b < a) }

    static func < (a: CLIVersion, b: CLIVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

/// A model as the pickers show it.
struct ModelChoice: Equatable, Sendable {
    var id: String
    var name: String
    var isDefault = false
    /// An older model: the menu shows it only while it is chosen or a favorite, or when you search for it.
    var isLegacy = false
    var isNew = false
    /// The agent version this model needs when the installed one is older: the picker names the update that unlocks it.
    var requiredVersion: String?

    var needsUpdate: Bool { requiredVersion != nil }

    /// The models to offer an agent. What the agent lists itself (Codex `model/list`) comes first, in its own order and
    /// classified by the manifest; then the manifest's models it did not list. An agent that lists its own models cannot
    /// name ones released after its build, so of those only the ones waiting on an update are added. With neither, the
    /// agent's well-known names.
    static func list(manifest: ModelManifest?, provider: RunProvider, offered: [AgentModel], installed: String?) -> [ModelChoice] {
        let entry = manifest?.entry(for: provider)
        var result: [ModelChoice] = []
        var seen = Set<String>()
        for model in offered where seen.insert(model.id.lowercased()).inserted {
            let known = manifest?.model(model.id, for: provider)
            if let known { seen.insert(known.id.lowercased()) }
            result.append(ModelChoice(id: model.id, name: model.name, isDefault: model.isDefault,
                                      isLegacy: known?.status == .legacy, isNew: known?.badge == "new"))
        }
        for model in entry?.models ?? [] where !seen.contains(model.id.lowercased()) {
            let required = manifest?.requiredVersion(model.id, for: provider, installed: installed)
            guard offered.isEmpty || required != nil else { continue }
            seen.insert(model.id.lowercased())
            result.append(ModelChoice(id: model.id, name: model.name, isDefault: entry?.defaultModel == model.id,
                                      isLegacy: model.status == .legacy, isNew: model.badge == "new", requiredVersion: required))
        }
        if result.isEmpty {
            result = provider.suggestedModels.filter { !$0.isEmpty }.map { ModelChoice(id: $0, name: $0) }
        }
        return result
    }
}

/// The order of a model menu: the agent's default on top, then your favorites, then the rest, each in the order given.
enum ModelOrdering {
    static func sorted(_ ids: [String], favorites: [String]) -> [String] {
        let starred = Set(favorites)
        let top = ids.filter(\.isEmpty)
        return top + ids.filter { !$0.isEmpty && starred.contains($0) } + ids.filter { !$0.isEmpty && !starred.contains($0) }
    }
}

/// Your own additions to the model menus, per agent: favorites (listed first) and model ids you typed yourself.
enum ModelPreferences {
    /// Typed ids kept per agent, newest first.
    static let customLimit = 8

    /// Adds `id` to the favorites, or takes it out when it is one.
    static func toggling(_ id: String, in favorites: [String]) -> [String] {
        guard !id.isEmpty else { return favorites }
        return favorites.contains(id) ? favorites.filter { $0 != id } : favorites + [id]
    }

    /// A typed model id, cleaned up, or nil when it cannot be passed to the agent.
    static func customID(_ typed: String) -> String? {
        let id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelManifest.isValidID(id) ? id : nil
    }

    /// Remembers a typed id, newest first, at most `customLimit`.
    static func remembering(_ id: String, in custom: [String]) -> [String] {
        guard let id = customID(id) else { return custom }
        return Array(([id] + custom.filter { $0 != id }).prefix(customLimit))
    }
}

/// The last valid manifest fetched from the repository, kept between launches.
struct ModelManifestStore {
    let url: URL

    /// Nil when there is none, or when it no longer validates (a later build may read a newer schema).
    func load() -> ModelManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ModelManifest.parse(data)
    }

    /// Stores the bytes as fetched, only after `ModelManifest.accepting` took them.
    func save(_ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// When Nook asks the repository for a fresh manifest: at most every six hours, and never while you keep the model list
/// offline (Settings › Workspace). The fetch itself goes through `NetworkGuard`.
enum ModelManifestRefresh {
    static let interval: TimeInterval = 6 * 60 * 60

    static func isDue(online: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard online else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval || now < lastAttempt
    }
}
