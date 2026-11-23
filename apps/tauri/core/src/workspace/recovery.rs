//! Which failed turns Nook can help on (`FreshConversation`, `AgentErrorText.contextFull`, `AgentSignInFailure` on the
//! Mac). The same for every agent: each one's error text is read the same way.

/// The failure a new conversation fixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recovery {
    /// The agent no longer has the conversation to continue (deleted, made on another machine, an older version).
    Gone,
    /// The conversation no longer fits the model's context window.
    Full,
}

/// The conversation no longer fits the model's context window (Claude Code's "Prompt is too long", OpenAI's
/// `context_length_exceeded`, Gemini's token limit).
pub fn context_full(message: &str) -> bool {
    let text = message.to_lowercase();
    [
        "prompt is too long",
        "context_length_exceeded",
        "context length exceeded",
        "exceeds the context window",
        "maximum context length",
        "context window exceeded",
        "exceeds the maximum number of tokens",
        "input is too long",
        "too many input tokens",
    ]
    .iter()
    .any(|p| text.contains(p))
}

/// The failure a new conversation fixes, read from the agent's error; `None` for every other failure. Strict: a wrong
/// guess would cost the agent a conversation it still has.
pub fn recovery(error: &str) -> Option<Recovery> {
    if context_full(error) {
        return Some(Recovery::Full);
    }
    let text = error.to_lowercase();
    const GONE: [&str; 8] = [
        "no conversation found",
        "conversation not found",
        "session not found",
        "thread not found",
        "no rollout found",
        "unknown session",
        "session does not exist",
        "no such session",
    ];
    GONE.iter().any(|p| text.contains(p)).then_some(Recovery::Gone)
}

/// Whether a failure's text says the agent needs you to sign in again (`FailureClassifier.signInPhrases`).
pub fn needs_sign_in(text: Option<&str>) -> bool {
    let Some(text) = text.filter(|t| !t.is_empty()) else { return false };
    let lower = text.to_lowercase();
    const PHRASES: [&str; 35] = [
        "failed to authenticate", "authentication failed", "authentication_failed", "authentication_error",
        "authentication required", "requires authentication", "please authenticate", "auth required", "auth_required",
        "not authenticated", "not logged in", "not signed in", "please log in", "please login", "please sign in",
        "/login", "login required", "log in again", "sign in again", "oauth session expired", "oauth token",
        "token has expired", "token expired", "refresh token", "invalid_grant", "invalid api key", "invalid x-api-key",
        "api error: 401", "unauthorized", "unauthenticated", "credentials have expired", "no credentials",
        "session expired", "expired token", "login expired",
    ];
    PHRASES.iter().any(|p| lower.contains(p))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_a_new_conversation_fixes() {
        assert_eq!(recovery("API Error: 400 Prompt is too long"), Some(Recovery::Full));
        assert_eq!(recovery("No conversation found with session ID: abc"), Some(Recovery::Gone));
        assert_eq!(recovery("network error"), None);
        assert!(needs_sign_in(Some("OAuth session expired and could not be refreshed")));
        assert!(needs_sign_in(Some("Invalid API key · Please run /login")));
        assert!(!needs_sign_in(Some("fetch failed")));
        assert!(!needs_sign_in(None));
    }
}
