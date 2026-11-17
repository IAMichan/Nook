//! Signing in to OpenRouter instead of making a key: OpenRouter's own page asks you to log in and allow Nook (with a
//! spending limit if you like), sends a one-time code back to Nook on 127.0.0.1, and Nook trades that code, with the
//! PKCE verifier only it knows, for a key of your own. The key goes straight into the system's keychain like a pasted
//! one. Port of the Mac's `OpenRouterSignIn` (which comes back through `nook://`).

use std::time::Duration;

use serde_json::{json, Value};

use super::oauth::{Loopback, Pkce};
use crate::i18n::{tr, trf};
use crate::{NookError, Result};

const AUTH_PAGE: &str = "https://openrouter.ai/auth";
const KEYS: &str = "https://openrouter.ai/api/v1/auth/keys";

/// OpenRouter's sign-in page, coming back to `callback` with a code.
pub fn auth_url(callback: &str, challenge: &str) -> String {
    let mut url = url::Url::parse(AUTH_PAGE).expect("valid OpenRouter page");
    url.query_pairs_mut()
        .append_pair("callback_url", callback)
        .append_pair("code_challenge", challenge)
        .append_pair("code_challenge_method", "S256");
    url.into()
}

/// The one-time code in the address the browser came back to; `None` when the person declined.
pub fn code(callback: &str) -> Option<String> {
    let url = url::Url::parse(callback).ok()?;
    url.query_pairs().find(|(k, _)| k == "code").map(|(_, v)| v.into_owned()).filter(|c| !c.is_empty())
}

/// What Nook sends to trade the code for a key.
pub fn key_request(code: &str, verifier: &str) -> Value {
    json!({"code": code, "code_verifier": verifier, "code_challenge_method": "S256"})
}

/// The key in OpenRouter's answer.
pub fn key(answer: &Value) -> Option<String> {
    answer["key"].as_str().filter(|k| !k.is_empty()).map(str::to_string)
}

/// The whole sign-in: `open` shows OpenRouter's page in the system's browser; Nook waits up to five minutes. Errors
/// never hold the code, verifier or key: only what went wrong.
pub async fn sign_in(open: impl FnOnce(&str) -> std::result::Result<(), String>) -> Result<String> {
    let loopback = Loopback::bind().await.map_err(|e| NookError(e.to_string()))?;
    let pkce = Pkce::make();
    open(&auth_url(&loopback.redirect, &pkce.challenge))
        .map_err(|e| NookError(trf("De browser ging niet open: {error}", "The browser did not open: {error}", &[("error", &e)])))?;
    let callback = loopback
        .wait(Duration::from_secs(300))
        .await
        .map_err(|_| NookError::new(tr("Inloggen bij OpenRouter is gestopt.", "Signing in to OpenRouter stopped.")))?;
    let code =
        code(&callback).ok_or_else(|| NookError::new(tr("OpenRouter gaf Nook geen toegang.", "OpenRouter did not give Nook access.")))?;
    let failed = || NookError::new(tr("OpenRouter gaf geen sleutel. Probeer het opnieuw.", "OpenRouter gave no key. Try again."));
    let client = reqwest::Client::builder().timeout(Duration::from_secs(20)).build().map_err(|_| failed())?;
    let response = client.post(KEYS).json(&key_request(&code, &pkce.verifier)).send().await.map_err(|_| failed())?;
    if !response.status().is_success() {
        return Err(failed());
    }
    let answer: Value = response.json().await.map_err(|_| failed())?;
    key(&answer).ok_or_else(failed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_asks_for_a_code_with_the_challenge() {
        let pkce = Pkce::make();
        let page = url::Url::parse(&auth_url("http://127.0.0.1:33418/callback", &pkce.challenge)).unwrap();
        let query: std::collections::HashMap<_, _> = page.query_pairs().into_owned().collect();
        assert_eq!(page.host_str(), Some("openrouter.ai"));
        assert_eq!(query["callback_url"], "http://127.0.0.1:33418/callback");
        assert_eq!(query["code_challenge"], pkce.challenge);
        assert_eq!(query["code_challenge_method"], "S256");
        assert!(!page.as_str().contains(&pkce.verifier), "the verifier never leaves Nook before the trade");
    }

    #[test]
    fn the_code_is_traded_with_the_verifier() {
        assert_eq!(code("http://127.0.0.1:33418/callback?code=abc").as_deref(), Some("abc"));
        assert_eq!(code("http://127.0.0.1:33418/callback?error=access_denied"), None);
        assert_eq!(code("http://127.0.0.1:33418/callback?code="), None);
        assert_eq!(key_request("abc", "v"), json!({"code": "abc", "code_verifier": "v", "code_challenge_method": "S256"}));
        assert_eq!(key(&json!({"key": "sk-or-v1-x", "user_id": "u"})).as_deref(), Some("sk-or-v1-x"));
        assert_eq!(key(&json!({"error": "bad"})), None);
    }
}
