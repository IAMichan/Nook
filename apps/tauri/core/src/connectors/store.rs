//! Wat de koppelingen bewaren zonder geheimen: aan/uit per koppeling, accounts, MCP-servers, GitLab-hosts, WhatsApp-
//! keuzes en welke accounts een chat mag gebruiken. Eén JSON-bestand in de gegevensmap (`connectors.json`); op de Mac
//! staat hetzelfde in UserDefaults. Geheimen staan nooit hierin, alleen in de kluis.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::RwLock;

use serde::{Deserialize, Serialize};

use super::accounts::ServiceAccount;
use super::mail::MailAccount;
use super::mcp::McpServerConfig;
use super::whatsapp::WhatsAppSettings;
use crate::paths;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConnectorConfig {
    /// `connector.<id>.on` op de Mac: aan zodra ingesteld, tenzij de gebruiker hem uitzette.
    pub toggles: BTreeMap<String, bool>,
    pub accounts: Vec<ServiceAccount>,
    /// Linked Microsoft / Google mail & calendar accounts (refresh tokens live in the keychain only).
    #[serde(default)]
    pub mail_accounts: Vec<MailAccount>,
    /// GitLab-hosts met een token in de kluis.
    pub gitlab_hosts: Vec<String>,
    /// Other code hosts (Gitea, Forgejo, Codeberg, GitCafe, Bitbucket, Azure DevOps) with a token in the keychain.
    #[serde(default)]
    pub forge_hosts: Vec<String>,
    pub mcp_servers: Vec<McpServerConfig>,
    pub whatsapp: WhatsAppSettings,
    /// Per Nook (chat-id) de accounts die die chat niet mag gebruiken ("github.werk").
    pub chat_accounts: BTreeMap<String, BTreeSet<String>>,
}

pub struct ConnectorStore {
    path: Option<PathBuf>,
    data: RwLock<ConnectorConfig>,
}

impl ConnectorStore {
    pub fn open_default() -> Self {
        Self::open(paths::support_directory().join("connectors.json"))
    }

    /// A file that cannot be read is set aside under a dated name with a notice and Nook starts empty, never silently
    /// overwriting it (`storage_recovery`).
    pub fn open(path: PathBuf) -> Self {
        let data = crate::storage_recovery::read_json(&path, |bytes| {
            serde_json::from_slice::<serde_json::Value>(bytes)
                .and_then(|mut value| {
                    super::whatsapp::migrate_beeper(&mut value);
                    serde_json::from_value(value)
                })
                .map_err(|e| e.to_string())
        });
        Self { path: Some(path), data: RwLock::new(data) }
    }

    pub fn in_memory() -> Self {
        Self { path: None, data: RwLock::new(ConnectorConfig::default()) }
    }

    pub fn read<T>(&self, f: impl FnOnce(&ConnectorConfig) -> T) -> T {
        f(&self.data.read().unwrap_or_else(|e| e.into_inner()))
    }

    pub fn update<T>(&self, f: impl FnOnce(&mut ConnectorConfig) -> T) -> T {
        let mut guard = self.data.write().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut guard);
        if let Some(path) = &self.path {
            if let Ok(bytes) = serde_json::to_vec_pretty(&*guard) {
                let _ = paths::write_atomic(path, &bytes);
            }
        }
        out
    }

    pub fn is_on(&self, id: &str) -> bool {
        self.read(|c| c.toggles.get(id).copied().unwrap_or(true))
    }

    pub fn set_on(&self, id: &str, on: bool) {
        self.update(|c| {
            c.toggles.insert(id.to_string(), on);
        });
    }

    /// De accounts die deze chat niet mag gebruiken.
    pub fn excluded_accounts(&self, nook: &str) -> BTreeSet<String> {
        self.read(|c| c.chat_accounts.get(nook).cloned().unwrap_or_default())
    }

    pub fn set_excluded_accounts(&self, nook: &str, excluded: BTreeSet<String>) {
        self.update(|c| {
            if excluded.is_empty() {
                c.chat_accounts.remove(nook);
            } else {
                c.chat_accounts.insert(nook.to_string(), excluded);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toggles_default_on_and_persist() {
        let dir = std::env::temp_dir().join(format!("nook-connectors-{}", uuid::Uuid::new_v4()));
        let file = dir.join("connectors.json");
        let store = ConnectorStore::open(file.clone());
        assert!(store.is_on("github"));
        store.set_on("github", false);
        store.set_excluded_accounts("n1", ["github.werk".to_string()].into());
        let again = ConnectorStore::open(file);
        assert!(!again.is_on("github"));
        assert!(again.excluded_accounts("n1").contains("github.werk"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unreadable_file_is_kept_aside() {
        let dir = std::env::temp_dir().join(format!("nook-connectors-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("connectors.json");
        std::fs::write(&file, b"{kapot").unwrap();
        let store = ConnectorStore::open(file.clone());
        assert!(store.is_on("x"));
        // Set aside under a dated name (`connectors.damaged-<date>.json`), never overwritten.
        let aside = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with("connectors.damaged-"));
        assert!(aside && !file.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_beeper_gateway_moves_to_gowa_and_keeps_the_rest() {
        let dir = std::env::temp_dir().join(format!("nook-connectors-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("connectors.json");
        let saved =
            r#"{"toggles":{"github":false},"whatsapp":{"enabled":true,"gateway":"beeper","url":"http://localhost:23373","notify":false}}"#;
        std::fs::write(&file, saved).unwrap();
        let store = ConnectorStore::open(file.clone());
        assert!(!store.is_on("github"), "the other settings stay");
        let whatsapp = store.read(|c| c.whatsapp.clone());
        assert_eq!(whatsapp.gateway, crate::connectors::whatsapp::GatewayKind::Gowa);
        assert!(whatsapp.url.is_empty());
        assert!(!whatsapp.enabled, "off until it is linked again");
        assert!(!whatsapp.notify);
        assert!(!file.with_extension("json.bak").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn mail_accounts_default_and_persist() {
        let dir = std::env::temp_dir().join(format!("nook-connectors-mail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("connectors.json");
        // Existing connectors.json without mailAccounts loads seamlessly.
        std::fs::write(&file, br#"{"toggles":{"github":true}}"#).unwrap();
        let store = ConnectorStore::open(file.clone());
        assert!(store.read(|c| c.mail_accounts.is_empty()));
        assert!(!file.with_extension("json.bak").exists());

        // Persisting mail_accounts survives reload.
        store.update(|c| {
            c.mail_accounts.push(MailAccount {
                id: "ms-work".into(),
                provider: super::super::mail::Provider::Microsoft,
                address: "work@example.com".into(),
                name: "Work".into(),
                calendar: true,
            });
        });
        let again = ConnectorStore::open(file);
        let accounts = again.read(|c| c.mail_accounts.clone());
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].address, "work@example.com");
        assert!(accounts[0].calendar);
        let _ = std::fs::remove_dir_all(dir);
    }
}
