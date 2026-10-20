//! Een persoonlijk toegangstoken per GitLab-host (gitlab.com of een eigen server), in de kluis. Het gaat alleen over
//! https naar die host, met de header `PRIVATE-TOKEN`, en komt nooit in een logboek of adres. De werkruimte gebruikt
//! het om merge requests te zoeken en te openen.

use serde::Serialize;

use super::{api_base, clean, CResult, ConnectorError, ConnectorStore, Http};
use crate::secrets::SecretStore;

pub fn account(host: &str) -> String {
    format!("gitlab.token.{}", host.to_lowercase())
}

/// Een host zoals getypt ("gitlab.com", "https://git.example.com/"): kleine letters, zonder schema, pad of inlog.
pub fn normalize(raw: &str) -> Option<String> {
    let mut text = raw.trim().to_lowercase();
    for prefix in ["https://", "http://"] {
        if let Some(rest) = text.strip_prefix(prefix) {
            text = rest.to_string();
        }
    }
    let text = text.split('/').next().unwrap_or("").to_string();
    let valid = !text.contains('@')
        && !text.is_empty()
        && text.chars().all(|c| c.is_alphanumeric() || "-.:".contains(c))
        && (text.contains('.') || text.starts_with("localhost"));
    valid.then_some(text)
}

pub fn token(secrets: &dyn SecretStore, host: &str) -> Option<String> {
    secrets.read(&account(host)).map(|t| clean(&t)).filter(|t| !t.is_empty())
}

/// De hosts met een token, voor de lijst in de instellingen.
pub fn hosts(store: &ConnectorStore, secrets: &dyn SecretStore) -> Vec<String> {
    store.read(|c| c.gitlab_hosts.clone()).into_iter().filter(|h| token(secrets, h).is_some()).collect()
}

pub fn save(store: &ConnectorStore, secrets: &dyn SecretStore, host: &str, value: &str) -> CResult<String> {
    let host = normalize(host).ok_or_else(|| ConnectorError::new("Dat is geen geldige host of het token is leeg."))?;
    let value = clean(value);
    if value.is_empty() {
        return Err(ConnectorError::new("Dat is geen geldige host of het token is leeg."));
    }
    secrets.write(&account(&host), &value).map_err(ConnectorError::new)?;
    store.update(|c| {
        if !c.gitlab_hosts.contains(&host) {
            c.gitlab_hosts.push(host.clone());
        }
    });
    Ok(host)
}

/// What a GitLab host says about a token: whose it is, that it is refused, or nothing (offline, VPN, not GitLab).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum TokenCheck {
    Valid { username: String },
    Rejected,
    Unreachable,
}

impl TokenCheck {
    pub fn from_response(status: u16, body: &[u8]) -> Self {
        if status == 401 || status == 403 {
            return Self::Rejected;
        }
        let username = (status == 200)
            .then(|| serde_json::from_slice::<serde_json::Value>(body).ok())
            .flatten()
            .and_then(|json| json["username"].as_str().map(str::to_string));
        match username {
            Some(username) => Self::Valid { username },
            None => Self::Unreachable,
        }
    }
}

/// Asks the host whose token this is (`GET /api/v4/user`), over https only, so Settings can say who is connected.
pub async fn check(http: &Http, host: &str, token: &str) -> TokenCheck {
    let token = clean(token);
    let Some(host) = normalize(host).filter(|_| !token.is_empty()) else { return TokenCheck::Unreachable };
    let base = api_base(&format!("https://{host}"), "NOOK_GITLAB_API_URL");
    match http.send("GET", &format!("{base}/api/v4/user"), &[("PRIVATE-TOKEN", token)], None, "GitLab").await {
        Ok((status, body)) => TokenCheck::from_response(status, &body),
        Err(_) => TokenCheck::Unreachable,
    }
}

/// Checks the token with GitLab first: a refused token is never stored; one Nook cannot check yet (offline, VPN) is.
pub async fn verify_and_save(
    http: &Http,
    store: &ConnectorStore,
    secrets: &dyn SecretStore,
    host: &str,
    value: &str,
) -> CResult<(String, TokenCheck)> {
    if normalize(host).is_none() || clean(value).is_empty() {
        return Err(ConnectorError::new("Dat is geen geldige host of het token is leeg."));
    }
    let result = check(http, host, value).await;
    if result == TokenCheck::Rejected {
        return Err(ConnectorError::new("GitLab weigert dit token. Controleer of het scope api heeft en niet verlopen is."));
    }
    Ok((save(store, secrets, host, value)?, result))
}

pub fn remove(store: &ConnectorStore, secrets: &dyn SecretStore, host: &str) {
    let _ = secrets.remove(&account(host));
    let host = host.to_lowercase();
    store.update(|c| c.gitlab_hosts.retain(|h| *h != host));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;

    #[test]
    fn token_check_reads_the_user() {
        assert_eq!(TokenCheck::from_response(200, br#"{"id":1,"username":"michan"}"#), TokenCheck::Valid { username: "michan".into() });
        assert_eq!(TokenCheck::from_response(401, br#"{"message":"401 Unauthorized"}"#), TokenCheck::Rejected);
        assert_eq!(TokenCheck::from_response(403, br#"{"error":"insufficient_scope"}"#), TokenCheck::Rejected);
        // Not GitLab, a login page in front of it, or a server error: Nook cannot tell, so it does not call the token bad.
        assert_eq!(TokenCheck::from_response(200, b"<html></html>"), TokenCheck::Unreachable);
        assert_eq!(TokenCheck::from_response(502, b""), TokenCheck::Unreachable);
    }

    #[tokio::test]
    async fn an_invalid_host_or_empty_token_is_never_saved() {
        let (store, secrets, http) = (ConnectorStore::in_memory(), MemorySecrets::default(), Http::new());
        assert!(verify_and_save(&http, &store, &secrets, "intranet", "glpat-x").await.is_err());
        assert!(verify_and_save(&http, &store, &secrets, "gitlab.com", " ").await.is_err());
        assert!(hosts(&store, &secrets).is_empty());
        assert_eq!(check(&http, "user@gitlab.com", "glpat-x").await, TokenCheck::Unreachable);
    }

    #[test]
    fn hosts_are_normalized_and_tokens_kept_in_the_vault() {
        assert_eq!(normalize("https://Git.Example.com/group/x").as_deref(), Some("git.example.com"));
        assert_eq!(normalize("gitlab.com").as_deref(), Some("gitlab.com"));
        assert_eq!(normalize("localhost:8080").as_deref(), Some("localhost:8080"));
        assert_eq!(normalize("user@gitlab.com"), None);
        assert_eq!(normalize("intranet"), None);
        let store = ConnectorStore::in_memory();
        let secrets = MemorySecrets::default();
        assert!(save(&store, &secrets, "gitlab.com", "  ").is_err());
        assert_eq!(save(&store, &secrets, "https://gitlab.com/", "glpat-x").unwrap(), "gitlab.com");
        assert_eq!(secrets.read("gitlab.token.gitlab.com").as_deref(), Some("glpat-x"));
        assert_eq!(hosts(&store, &secrets), ["gitlab.com"]);
        remove(&store, &secrets, "gitlab.com");
        assert!(hosts(&store, &secrets).is_empty());
    }
}
