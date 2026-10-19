//! Voorkeuren van de werkruimte (`WorkspaceSettings` op de Mac), in een eigen bestand `workspace-settings.json` naast
//! de andere gegevens van Nook. Geen geheimen: die staan alleen in de `SecretStore`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::models::{ExecutionMode, IsolationMode, PermissionPolicy, RunProvider};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceSettings {
    pub default_provider: RunProvider,
    /// Voorgesteld model per agent (leeg: de standaard van de agent).
    pub default_models: BTreeMap<String, String>,
    pub default_mode: ExecutionMode,
    pub default_isolation: IsolationMode,
    pub default_permission: PermissionPolicy,
    /// Waar nieuwe worktrees komen: `<map>/<repository>/<branch>`. Leeg: `~/.nook/worktrees`.
    pub worktree_root: String,
    /// Sessies die zo lang niet gebruikt zijn, worden vanzelf gearchiveerd. 0 = nooit.
    pub auto_archive_days: u32,
    /// Kosten tonen die de agent zelf meldt.
    pub show_cost: bool,
    /// Coding-agents mogen Nooks terminal, browser en pull requests gebruiken via de werkruimte-brug.
    pub agent_tools: bool,
    /// Een bericht terwijl een agent werkt, stuurt de beurt bij (Ctrl+Enter zet het in de wachtrij); uit: andersom.
    pub steer_by_default: bool,
    /// Een sessie die op een gebruikslimiet stopte, gaat vanzelf verder zodra de limiet vrij is (standaard uit).
    pub auto_resume_limited: bool,
    pub last_project: String,
    /// Eerder gekozen projecten, nieuwste eerst.
    pub recent_projects: Vec<String>,
}

impl Default for WorkspaceSettings {
    fn default() -> Self {
        Self {
            default_provider: RunProvider::Claude,
            default_models: BTreeMap::new(),
            default_mode: ExecutionMode::Agent,
            default_isolation: IsolationMode::Worktree,
            default_permission: PermissionPolicy::AcceptEdits,
            worktree_root: String::new(),
            auto_archive_days: 0,
            show_cost: true,
            agent_tools: true,
            steer_by_default: true,
            auto_resume_limited: false,
            last_project: String::new(),
            recent_projects: vec![],
        }
    }
}

pub fn standard_worktree_root() -> String {
    crate::paths::dot_nook().join("worktrees").to_string_lossy().into_owned()
}

impl WorkspaceSettings {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("workspace-settings.json")
    }

    pub fn load_from(file: &std::path::Path) -> Self {
        std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save_to(&self, file: &std::path::Path) {
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    pub fn worktree_root(&self) -> String {
        if self.worktree_root.trim().is_empty() {
            standard_worktree_root()
        } else {
            self.worktree_root.clone()
        }
    }

    pub fn remember_project(&mut self, path: &str) {
        self.last_project = path.into();
        self.recent_projects.retain(|p| p != path);
        self.recent_projects.insert(0, path.into());
        self.recent_projects.truncate(12);
    }

    pub fn forget_project(&mut self, path: &str) {
        self.recent_projects.retain(|p| p != path);
        if self.last_project == path {
            self.last_project.clear();
        }
    }

    pub fn model(&self, provider: RunProvider) -> String {
        self.default_models.get(provider.id()).cloned().unwrap_or_default()
    }

    /// Een veilige standaard die de agent echt ondersteunt.
    pub fn permission(&self, provider: RunProvider) -> PermissionPolicy {
        if provider.capabilities().policies.contains(&self.default_permission) {
            self.default_permission
        } else {
            PermissionPolicy::AcceptEdits
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recent_projects_and_defaults() {
        let mut s = WorkspaceSettings::default();
        assert_eq!(s.default_isolation, IsolationMode::Worktree);
        assert!(s.agent_tools);
        for i in 0..15 {
            s.remember_project(&format!("/p{i}"));
        }
        s.remember_project("/p3");
        assert_eq!(s.recent_projects.len(), 12);
        assert_eq!(s.recent_projects[0], "/p3");
        assert_eq!(s.last_project, "/p3");
        s.forget_project("/p3");
        assert!(s.last_project.is_empty());
        assert!(!s.recent_projects.contains(&"/p3".to_string()));
        let back: WorkspaceSettings = serde_json::from_str(r#"{"showCost":false,"unknown":1}"#).unwrap();
        assert!(!back.show_cost);
        assert!(back.worktree_root().ends_with("worktrees"));
    }
}
