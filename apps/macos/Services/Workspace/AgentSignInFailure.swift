import Foundation

// A turn that failed because the agent's login ran out ("OAuth session expired and could not be refreshed", "Invalid API
// key · Please run /login"). The failed turn's banner then offers to sign in again, in the same Terminal window the
// account settings open. Pure decisions, Foundation only, so it is tested on its own.

enum AgentSignInFailure {
    /// What agents say when their login no longer works, lowercased. Kept narrow: a word like "token" alone also
    /// appears in context-window errors.
    static let phrases = [
        "failed to authenticate", "authentication failed", "authentication_error", "authentication required",
        "not authenticated", "not logged in", "not signed in", "please log in", "please login", "please sign in",
        "run /login", "login required", "log in again", "sign in again", "oauth session expired", "oauth token",
        "token has expired", "token expired", "refresh token", "invalid_grant", "invalid api key", "invalid x-api-key",
        "unauthorized", "unauthenticated", "credentials have expired", "no credentials",
    ]

    /// Whether a failure's text says the agent needs you to sign in again.
    static func needsSignIn(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased()
        return phrases.contains { lower.contains($0) }
    }

    /// Whether Nook can start the agent's sign-in for you. ACP agents you add sign in themselves, in their next session.
    static func canSignInAgain(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok: return true
        case .acp: return false
        }
    }
}
