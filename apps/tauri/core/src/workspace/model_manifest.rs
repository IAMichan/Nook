//! Which models Nook offers each agent (`ModelManifest` on the Mac): the same `model-manifest.json` the Mac ships,
//! read from its place in the repository so both apps offer the same list. A model's aliases ("opus") read as that
//! model, so a saved alias still shows its name. See docs/MODEL-MANIFEST.md.
//!
//! As on the Mac (`WorkspaceManager+ModelManifest`), a fresh copy comes from Nook's repository every six hours while
//! "Check for new models online" is on, so new models show up between releases. A copy that does not validate, or is
//! older than the one in use, is dropped; the last good one is kept in the data folder and wins over the bundled list
//! when it is newer (`updatedAt`).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, RwLock};

use serde::{Deserialize, Serialize};

const BUNDLED: &str = include_str!("../../../../macos/Services/Workspace/model-manifest.json");

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    version: u32,
    /// When the file was last edited; decides which copy wins.
    updated_at: chrono::DateTime<chrono::Utc>,
    agents: BTreeMap<String, Agent>,
}

/// Where the repository keeps the manifest (`ModelManifest.remoteURL`).
pub const REMOTE_URL: &str = "https://raw.githubusercontent.com/IAMichan/nook/main/apps/macos/Services/Workspace/model-manifest.json";
/// A manifest is a few kilobytes: anything this large is not one.
const MAX_BYTES: usize = 256 * 1024;
const MAX_MODELS_PER_AGENT: usize = 100;
/// Between two fetches (`ModelManifestRefresh.interval`).
pub const REFRESH_EVERY: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// An id the agents take on their command line: ASCII letters, digits and `._:/@[]-`, not starting with a dash.
fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len()) && !id.starts_with('-') && id.chars().all(|c| c.is_ascii_alphanumeric() || "._:/@[]-".contains(c))
}

/// A manifest this build reads, or None (`ModelManifest.parse`): schema 1, small, every id valid and unique per agent,
/// a badge only with a release date, and the default one of the models.
fn parse(bytes: &[u8]) -> Option<Manifest> {
    if bytes.len() > MAX_BYTES {
        return None;
    }
    let manifest: Manifest = serde_json::from_slice(bytes).ok()?;
    if manifest.version != 1 {
        return None;
    }
    for agent in manifest.agents.values() {
        if agent.models.is_empty() || agent.models.len() > MAX_MODELS_PER_AGENT {
            return None;
        }
        let mut names = std::collections::HashSet::new();
        for model in &agent.models {
            let ids = std::iter::once(&model.id).chain(model.aliases.iter().flatten());
            for id in ids {
                if !valid_id(id) || !names.insert(id.to_lowercase()) {
                    return None;
                }
            }
            if model.badge.is_some() && model.released.is_none() {
                return None;
            }
        }
        if let Some(default) = &agent.default_model {
            if !agent.models.iter().any(|m| &m.id == default) {
                return None;
            }
        }
    }
    Some(manifest)
}

fn cache_file() -> std::path::PathBuf {
    crate::paths::support_directory().join("workspace").join("model-manifest.json")
}

/// The copy in use: the bundled one, or the cached fetch when that is newer.
static ACTIVE: LazyLock<RwLock<Option<Manifest>>> = LazyLock::new(|| {
    let bundled = parse(BUNDLED.as_bytes());
    let cached = std::fs::read(cache_file()).ok().and_then(|b| parse(&b));
    RwLock::new(match (bundled, cached) {
        (Some(b), Some(c)) => Some(if c.updated_at > b.updated_at { c } else { b }),
        (b, c) => b.or(c),
    })
});
static ONLINE: AtomicBool = AtomicBool::new(true);

/// "Check for new models online" (Settings › Sessions › Model per agent); off keeps the list that came with the app.
pub fn set_online(on: bool) {
    ONLINE.store(on, Ordering::Relaxed);
}

pub fn online() -> bool {
    ONLINE.load(Ordering::Relaxed)
}

/// When the list in use was last edited.
pub fn updated_at() -> Option<chrono::DateTime<chrono::Utc>> {
    ACTIVE.read().ok()?.as_ref().map(|m| m.updated_at)
}

/// What a fetch leaves in use (`ModelManifest.accepting`): the fetched copy when it is valid and not older than the one
/// in use. True when the list changed.
fn accept(bytes: &[u8]) -> bool {
    let Some(fetched) = parse(bytes) else { return false };
    let mut active = ACTIVE.write().unwrap_or_else(|e| e.into_inner());
    if active.as_ref().is_some_and(|current| fetched.updated_at < current.updated_at) {
        return false;
    }
    let changed = active.as_ref().map(|c| c.updated_at) != Some(fetched.updated_at);
    *active = Some(fetched);
    changed
}

/// Fetches the repository's copy while the online list is on; true when the models changed.
pub async fn refresh() -> bool {
    if !online() {
        return false;
    }
    let Ok(client) = reqwest::Client::builder().timeout(std::time::Duration::from_secs(20)).build() else { return false };
    let Ok(response) = client.get(REMOTE_URL).send().await else { return false };
    if !response.status().is_success() {
        return false;
    }
    let Ok(bytes) = response.bytes().await else { return false };
    if !online() || parse(&bytes).is_none() {
        return false;
    }
    let changed = accept(&bytes);
    let file = cache_file();
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = crate::paths::write_atomic(&file, &bytes);
    changed
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Agent {
    default_model: Option<String>,
    models: Vec<Model>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Model {
    id: String,
    name: String,
    status: String,
    badge: Option<String>,
    released: Option<chrono::DateTime<chrono::Utc>>,
    aliases: Option<Vec<String>>,
}

/// A model as the picker lists it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogModel {
    pub id: String,
    pub name: String,
    /// Still offered (`current`), or only read back for sessions that use it (`legacy`).
    pub current: bool,
    /// Labeled New: it has the badge and came out less than 14 days ago.
    pub is_new: bool,
    pub aliases: Vec<String>,
    /// The model the agent runs when Nook passes none.
    pub default: bool,
}

/// The models of an agent (`RunProvider` id), in the manifest's order; empty for an agent it does not list.
pub fn models(agent: &str, now: chrono::DateTime<chrono::Utc>) -> Vec<CatalogModel> {
    let active = ACTIVE.read().unwrap_or_else(|e| e.into_inner());
    let Some(entry) = active.as_ref().and_then(|m| m.agents.get(agent)) else { return vec![] };
    entry
        .models
        .iter()
        .map(|m| CatalogModel {
            id: m.id.clone(),
            name: m.name.clone(),
            current: m.status == "current",
            is_new: m.badge.as_deref() == Some("new") && m.released.is_some_and(|r| now < r + chrono::Duration::days(14)),
            aliases: m.aliases.clone().unwrap_or_default(),
            default: entry.default_model.as_deref() == Some(m.id.as_str()),
        })
        .collect()
}

/// Every agent's models.
pub fn all(now: chrono::DateTime<chrono::Utc>) -> BTreeMap<String, Vec<CatalogModel>> {
    let agents: Vec<String> =
        ACTIVE.read().unwrap_or_else(|e| e.into_inner()).as_ref().map(|m| m.agents.keys().cloned().collect()).unwrap_or_default();
    agents
        .into_iter()
        .map(|k| {
            let list = models(&k, now);
            (k, list)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_shared_manifest() {
        let claude = models("claude", chrono::Utc::now());
        assert!(claude.iter().any(|m| m.current && m.aliases.iter().any(|a| a == "opus")), "{claude:?}");
        assert!(!models("codex", chrono::Utc::now()).is_empty());
        assert!(models("nobody", chrono::Utc::now()).is_empty());
    }

    #[test]
    fn refuses_a_broken_or_strange_manifest() {
        assert!(parse(BUNDLED.as_bytes()).is_some());
        let bad_id = BUNDLED.replacen("\"id\": \"", "\"id\": \"-", 1);
        assert!(parse(bad_id.as_bytes()).is_none());
        let other_version = BUNDLED.replacen("\"version\": 1", "\"version\": 2", 1);
        assert!(parse(other_version.as_bytes()).is_none());
        assert!(parse(&vec![b' '; MAX_BYTES + 1]).is_none());
        assert!(valid_id("claude-opus-4-1") && valid_id("openai/gpt-5") && !valid_id("a b") && !valid_id(""));
    }
}
