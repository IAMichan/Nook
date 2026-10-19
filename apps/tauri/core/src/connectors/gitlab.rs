//! Een persoonlijk toegangstoken per GitLab-host (gitlab.com of een eigen server), in de kluis. Het gaat alleen over
//! https naar die host, met de header `PRIVATE-TOKEN`, en komt nooit in een logboek of adres. De werkruimte gebruikt
//! het om merge requests te zoeken en te openen.

use super::{clean, CResult, ConnectorError, ConnectorStore};
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
