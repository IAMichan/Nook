import Foundation

/// What the button next to a chat error should do. A plain "Settings" button hides what is wrong; the action that fits the
/// error ("Choose a model", "Open Ollama", "Reconnect") gets the user out of it.
enum ChatRecoveryAction: Equatable {
    /// The built-in model is missing or not loaded: choose or install one in Settings › Brain.
    case chooseModel
    /// Ollama or LM Studio does not answer: open it (then try again).
    case openLocalServer(BrainRuntime)
    /// The external AI refused the key or has none: Settings › Brain.
    case reconnectBrain
    /// A connected service refused its credentials: Settings › Accounts & connections.
    case reconnectConnection
    case openSettings

    static func forError(_ text: String, selection: BrainSelection) -> ChatRecoveryAction {
        let lower = text.lowercased()
        func mentions(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        let credentials = mentions(["credentials were rejected", "inloggegevens", "api key", "api-sleutel", "no key", "rejected (401", "rejected (403", "unauthorized"])
        switch selection.runtime {
        case .mlx:
            return .chooseModel
        case .ollama, .lmstudio:
            // A local server that does not answer is the usual reason; a missing model is chosen in Settings.
            if mentions(["no model", "geen model", "model not found", "not found"]) { return .chooseModel }
            return .openLocalServer(selection.runtime)
        case .external:
            if mentions(["credentials were rejected"]) && !mentions(["api key", "api-sleutel"]) { return .reconnectConnection }
            return credentials ? .reconnectBrain : .openSettings
        }
    }
}
