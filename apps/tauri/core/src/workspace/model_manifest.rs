//! Which models Nook offers each agent (`ModelManifest` on the Mac): the same `model-manifest.json` the Mac ships,
//! read from its place in the repository so both apps offer the same list. A model's aliases ("opus") read as that
//! model, so a saved alias still shows its name. See docs/MODEL-MANIFEST.md.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

const BUNDLED: &str = include_str!("../../../../macos/Services/Workspace/model-manifest.json");

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    version: u32,
    agents: BTreeMap<String, Agent>,
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

static MANIFEST: LazyLock<Option<Manifest>> =
    LazyLock::new(|| serde_json::from_str::<Manifest>(BUNDLED).ok().filter(|m| m.version == 1));

/// The models of an agent (`RunProvider` id), in the manifest's order; empty for an agent it does not list.
pub fn models(agent: &str, now: chrono::DateTime<chrono::Utc>) -> Vec<CatalogModel> {
    let Some(entry) = MANIFEST.as_ref().and_then(|m| m.agents.get(agent)) else { return vec![] };
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
    MANIFEST.as_ref().map(|m| m.agents.keys().map(|k| (k.clone(), models(k, now))).collect()).unwrap_or_default()
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
}
