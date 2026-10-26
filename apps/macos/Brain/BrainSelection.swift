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

/// Screen work on this Mac while an external brain answers the rest (Settings › Brain › Screen work).
///
/// With Claude (or another external AI) as the brain and the screen kept on this Mac, everything that reads the screen
/// would otherwise stop: thinking along, looking at the screen, Double Tap, taking over a task, and questions about what is
/// on screen. With a screen brain picked, that work runs on a model on this Mac instead, so screen text never leaves it,
/// while every other question still goes to the stronger external brain.
enum ScreenBrain {
    /// The brain a run uses instead of the chosen one: set for screen work (`AppModel.onScreenBrain`), read by
    /// `AppSettings.selection`, so every step of that run (context, tools, privacy filter, model) follows it.
    @TaskLocal static var routed: BrainSelection?

    /// The stored choice: "" for none, otherwise the runtime and the model ("mlx:<id>", "ollama:<model>", "lmstudio:<model>").
    static func parse(_ stored: String) -> BrainSelection? {
        guard let colon = stored.firstIndex(of: ":") else { return nil }
        let model = String(stored[stored.index(after: colon)...])
        guard !model.isEmpty else { return nil }
        switch stored[..<colon] {
        case "mlx": return BrainSelection(runtime: .mlx, provider: .claude, model: model)
        case "ollama": return BrainSelection(runtime: .ollama, provider: .ollama, model: model)
        case "lmstudio": return BrainSelection(runtime: .lmstudio, provider: .lmstudio, model: model)
        default: return nil
        }
    }

    /// The value `parse` reads back; "" for a brain that is not on this Mac, which never does screen work.
    static func stored(_ selection: BrainSelection) -> String {
        selection.isLocal ? "\(selection.runtime.rawValue):\(selection.model)" : ""
    }

    /// The brain that does the screen work: only while the chosen brain is external and the screen is kept on this Mac.
    /// Nil otherwise: a brain on this Mac already does everything, and a screen the external brain may read needs no other.
    static func worker(chosen: BrainSelection, screenPrivate: Bool, stored: String) -> BrainSelection? {
        guard !chosen.isLocal, screenPrivate else { return nil }
        return parse(stored)
    }
}
