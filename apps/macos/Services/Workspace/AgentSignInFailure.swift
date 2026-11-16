import Foundation

// A turn that failed because the agent's login ran out ("OAuth session expired and could not be refreshed", "Invalid API
// key · Please run /login"). The failed turn's banner then offers to sign in again: in your browser where the agent's
// login allows it, else in the Terminal window the account settings open. Pure decisions, Foundation only, so it is
// tested on its own.

enum AgentSignInFailure {
    /// Whether a failure's text says the agent needs you to sign in again (`FailureClassifier.signInPhrases`, the one
    /// list for every agent).
    static func needsSignIn(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return FailureClassifier.saysSignIn(text.lowercased())
    }

    /// Whether Nook can start the agent's sign-in for you. ACP agents you add sign in themselves, in their next session.
    static func canSignInAgain(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi: return true
        case .acp: return false
        }
    }
}
