import Foundation

// Settings inheritance: a value comes from the first layer that sets it, in the order
// Project -> Environment -> repository file -> Built-in. "Inherit" is simply "this layer does not set the key".

/// A JSON-ish setting value.
enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([SettingValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .list(try c.decode([SettingValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .list(let v): try c.encode(v)
        }
    }
}

enum SettingsResolver {
    /// Highest priority first in `precedence`.
    enum Layer: String, Codable, CaseIterable, Sendable {
        case builtIn, repositoryFile, environment, project

        static let precedence: [Layer] = [.project, .environment, .repositoryFile, .builtIn]
        /// Higher wins.
        var rank: Int { Layer.precedence.count - 1 - (Layer.precedence.firstIndex(of: self) ?? 0) }
    }

    struct Layers: Codable, Equatable, Sendable {
        var values: [Layer: [String: SettingValue]] = [:]

        init(_ values: [Layer: [String: SettingValue]] = [:]) { self.values = values }

        func value(_ key: String, in layer: Layer) -> SettingValue? { values[layer]?[key] }

        mutating func set(_ key: String, _ value: SettingValue, in layer: Layer) { values[layer, default: [:]][key] = value }

        /// Back to "inherit": the layer stops setting the key.
        mutating func reset(_ key: String, in layer: Layer) { values[layer]?[key] = nil }

        func resetting(_ key: String, in layer: Layer) -> Layers { var copy = self; copy.reset(key, in: layer); return copy }
    }

    struct Resolved: Equatable, Sendable {
        var value: SettingValue
        var source: Layer
        /// Lower layers that set the key too and lose to `source`.
        var overrides: [Layer]
        /// Set when resolving "as seen from" a layer: the higher layer that hides that layer's own value.
        var overriddenBy: Layer?
    }

    enum Provenance: Equatable, Sendable {
        case builtIn
        /// Not set here; the value comes from this lower layer.
        case inherited(from: Layer)
        /// Set here, replacing what the layers below say.
        case overridden
        /// Several selected scopes disagree.
        case mixed

        var key: String {
            switch self {
            case .builtIn: return "builtIn"
            case .inherited: return "inherited"
            case .overridden: return "overridden"
            case .mixed: return "mixed"
            }
        }
    }

    static func resolve(_ key: String, _ layers: Layers, viewing viewed: Layer? = nil) -> Resolved? {
        let setters = Layer.precedence.filter { layers.value(key, in: $0) != nil }
        guard let winner = setters.first, let value = layers.value(key, in: winner) else { return nil }
        var overriddenBy: Layer?
        if let viewed, viewed != winner, layers.value(key, in: viewed) != nil, winner.rank > viewed.rank {
            overriddenBy = winner
        }
        return Resolved(value: value, source: winner, overrides: Array(setters.dropFirst()), overriddenBy: overriddenBy)
    }

    /// How the setting shows in the editor of `layer`.
    static func provenance(_ key: String, _ layers: Layers, at layer: Layer) -> Provenance? {
        guard let resolved = resolve(key, layers) else { return nil }
        if layers.value(key, in: layer) != nil { return layer == .builtIn ? .builtIn : .overridden }
        // Only layers below `layer` can be inherited from.
        let below = Layer.precedence.first { $0.rank < layer.rank && layers.value(key, in: $0) != nil }
        guard let below else { return resolved.source == .builtIn ? .builtIn : .inherited(from: resolved.source) }
        return below == .builtIn ? .builtIn : .inherited(from: below)
    }

    enum Aggregate: Equatable, Sendable {
        case unset
        case uniform(Resolved)
        /// "Mixed across the selected scopes": one entry per scope, in the order given.
        case mixed([Resolved?])

        var provenance: Provenance? {
            switch self {
            case .unset: return nil
            case .uniform(let r): return r.source == .builtIn ? .builtIn : .inherited(from: r.source)
            case .mixed: return .mixed
            }
        }
    }

    /// Several projects selected at once: one value if they agree, otherwise mixed.
    static func resolveAcross(_ key: String, scopes: [Layers]) -> Aggregate {
        let all = scopes.map { resolve(key, $0) }
        guard let first = all.first else { return .unset }
        if all.allSatisfy({ $0?.value == first?.value }) {
            return first.map { .uniform($0) } ?? .unset
        }
        return .mixed(all)
    }
}

/// Which projects the settings page edits.
enum ProjectScope: Equatable, Sendable {
    case allProjects
    case project(path: String)

    /// Where an edit is written: one project -> its own layer, all projects -> the environment's.
    var writeLayer: SettingsResolver.Layer {
        switch self {
        case .allProjects: return .environment
        case .project: return .project
        }
    }
}

/// "Applying settings for <project> on|across <environment>".
struct ScopeDescription: Equatable, Sendable {
    enum Connector: String, Sendable { case on, across }

    var project: ProjectScope
    /// A single machine is chosen.
    var machineSelected: Bool
    /// The scope is one checkout, which lives on exactly one machine.
    var isCheckout: Bool

    var connector: Connector { machineSelected || isCheckout ? .on : .across }
}
