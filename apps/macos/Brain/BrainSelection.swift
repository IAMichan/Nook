import Foundation

/// Where Nook's thinking happens.
enum BrainRuntime: String, Codable, Equatable {
    /// The built-in model (MLX), on this Mac.
    case mlx
    /// Ollama on this Mac.
    case ollama
    /// LM Studio on this Mac.
    case lmstudio
    /// An external service the user chose on purpose (Claude, OpenAI, Claude Code, …).
    case external

    var isLocal: Bool { self != .external }
}

/// The one answer to "which brain is active": a runtime, the model on it, and for an external service which one.
///
/// It is derived from the stored settings (`useLocal`, `provider`, `localModel`, per-provider models), which stay as
/// they are so a downgrade keeps working. Everything that decides how to run a request reads this instead of
/// combining the separate settings itself.
struct BrainSelection: Equatable {
    var runtime: BrainRuntime
    /// Only for `.external` and the local servers: the provider the model belongs to.
    var provider: AIProvider
    var model: String

    var isLocal: Bool { runtime.isLocal }

    static func resolve(useLocal: Bool, provider: AIProvider, localModel: String, providerModel: String) -> BrainSelection {
        if useLocal { return BrainSelection(runtime: .mlx, provider: provider, model: localModel) }
        switch provider {
        case .ollama: return BrainSelection(runtime: .ollama, provider: provider, model: providerModel)
        case .lmstudio: return BrainSelection(runtime: .lmstudio, provider: provider, model: providerModel)
        default: return BrainSelection(runtime: .external, provider: provider, model: providerModel)
        }
    }

    /// The stored settings that express this selection.
    var storedValues: (useLocal: Bool, provider: AIProvider) {
        switch runtime {
        case .mlx: return (true, provider.isLocalServer ? .claude : provider)
        case .ollama: return (false, .ollama)
        case .lmstudio: return (false, .lmstudio)
        case .external: return (false, provider)
        }
    }

    /// First start of a version that knows about local-first: a new install thinks on the Mac itself; someone who already
    /// chose an external AI (a provider or an Anthropic key was set) keeps it. Nothing is switched without the user.
    static func initialUseLocal(stored: Bool?, storedProvider: String?, hasAnthropicKey: Bool) -> Bool {
        if let stored { return stored }
        let choseExternal = storedProvider != nil || hasAnthropicKey
        return !choseExternal
    }
}
