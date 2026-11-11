//! Voorkeuren van de werkruimte (`WorkspaceSettings` op de Mac), in een eigen bestand `workspace-settings.json` naast
//! de andere gegevens van Nook. Geen geheimen: die staan alleen in de `SecretStore`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::models::{ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunProvider};

/// What was chosen for one agent in one folder.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderAgentChoice {
    pub profile_id: String,
    /// Empty: the agent's own default.
    pub model: String,
    /// `None`: the agent's own default, also when another folder has a level.
    pub effort: Option<String>,
}

/// What the new-session composer last chose in one folder (`FolderChoices` on the Mac).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderChoices {
    pub provider: RunProvider,
    pub mode: ExecutionMode,
    pub permission: PermissionPolicy,
    pub isolation: IsolationMode,
    /// Per agent, so going back to it in this folder finds its account, model and effort again.
    #[serde(default)]
    pub agents: BTreeMap<String, FolderAgentChoice>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceSettings {
    pub default_provider: RunProvider,
    /// Voorgesteld model per agent (leeg: de standaard van de agent).
    pub default_models: BTreeMap<String, String>,
    /// Reasoning effort per agent for new sessions (absent: the agent's own default).
    pub default_efforts: BTreeMap<String, String>,
    /// The account last chosen per agent, so a new session starts with it again.
    pub default_profiles: BTreeMap<String, String>,
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
    /// Favorite project folders: shown at the top of the project menu and never evicted.
    pub favorite_projects: Vec<String>,
    /// Eerder gekozen projecten, nieuwste eerst.
    pub recent_projects: Vec<String>,
    /// The composer's last choices per folder, on top of the `default_*` values above.
    pub folder_choices: BTreeMap<String, FolderChoices>,
}

impl Default for WorkspaceSettings {
    fn default() -> Self {
        Self {
            default_provider: RunProvider::Claude,
            default_models: BTreeMap::new(),
            default_efforts: BTreeMap::new(),
            default_profiles: BTreeMap::new(),
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
            favorite_projects: vec![],
            recent_projects: vec![],
            folder_choices: BTreeMap::new(),
        }
    }
}

pub fn standard_worktree_root() -> String {
    crate::paths::dot_nook().join("worktrees").to_string_lossy().into_owned()
}

fn clean_project_path(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.len() > 1 {
        trimmed.trim_end_matches(['/', '\\']).to_string()
    } else {
        trimmed.to_string()
    }
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
        let clean = clean_project_path(path);
        if clean.is_empty() {
            return;
        }
        self.last_project = clean.clone();
        self.recent_projects.retain(|p| clean_project_path(p) != clean);
        self.recent_projects.insert(0, clean);
        self.recent_projects.truncate(12);
    }

    /// Keeps what `config` chose for its folder. `permission` is the one you chose: a plan runs with a safer one.
    pub fn remember_folder_choices(&mut self, config: &NewRunConfig, permission: PermissionPolicy) {
        let path = clean_project_path(&config.project_path);
        if path.is_empty() {
            return;
        }
        let mut agents = self.folder_choices.remove(&path).map(|c| c.agents).unwrap_or_default();
        agents.insert(
            config.provider.id().into(),
            FolderAgentChoice {
                profile_id: config.profile_id.clone(),
                model: config.model.clone(),
                effort: config.effort.clone().filter(|e| !e.is_empty()),
            },
        );
        self.folder_choices
            .insert(path, FolderChoices { provider: config.provider, mode: config.mode, permission, isolation: config.isolation, agents });
    }

    pub fn forget_project(&mut self, path: &str) {
        let clean = clean_project_path(path);
        if clean.is_empty() {
            return;
        }
        self.folder_choices.remove(&clean);
        self.recent_projects.retain(|p| clean_project_path(p) != clean);
        self.favorite_projects.retain(|p| clean_project_path(p) != clean);
        if clean_project_path(&self.last_project) == clean {
            self.last_project.clear();
        }
    }

    pub fn toggle_favorite_project(&mut self, path: &str) {
        let clean = clean_project_path(path);
        if clean.is_empty() {
            return;
        }
        let mut next = Vec::with_capacity(self.favorite_projects.len() + 1);
        let mut removed = false;
        for existing in &self.favorite_projects {
            let item = clean_project_path(existing);
            if item.is_empty() {
                continue;
            }
            if item == clean {
                removed = true;
            } else if !next.contains(&item) {
                next.push(item);
            }
        }
        if !removed {
            next.push(clean);
        }
        self.favorite_projects = next;
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
        s.toggle_favorite_project("/p3/");
        s.toggle_favorite_project("/p5");
        assert_eq!(s.favorite_projects, vec!["/p3", "/p5"]);
        s.toggle_favorite_project("/p5/");
        assert_eq!(s.favorite_projects, vec!["/p3"]);
        s.forget_project("/p3/");
        assert!(s.last_project.is_empty());
        assert!(s.favorite_projects.is_empty());
        assert!(!s.recent_projects.contains(&"/p3".to_string()));
        let back: WorkspaceSettings = serde_json::from_str(r#"{"showCost":false,"unknown":1}"#).unwrap();
        assert!(!back.show_cost);
        assert!(back.default_efforts.is_empty() && back.default_profiles.is_empty(), "old files still load");
        assert!(back.worktree_root().ends_with("worktrees"));
        assert!(back.folder_choices.is_empty(), "old files still load");
    }

    #[test]
    fn folder_choices_stay_per_folder_and_per_agent() {
        let mut s = WorkspaceSettings::default();
        let mut config = NewRunConfig {
            provider: RunProvider::Claude,
            profile_id: "work".into(),
            model: "opus".into(),
            effort: Some("high".into()),
            project_path: "/app/".into(),
            ..Default::default()
        };
        s.remember_folder_choices(&config, PermissionPolicy::AcceptEdits);
        config.provider = RunProvider::Codex;
        config.model = "gpt".into();
        config.effort = None;
        s.remember_folder_choices(&config, PermissionPolicy::AcceptEdits);

        let app = &s.folder_choices["/app"];
        assert_eq!(app.provider, RunProvider::Codex);
        assert_eq!(app.agents["claude"].model, "opus", "the other agent's choices stay");
        assert_eq!(app.agents["codex"].effort, None);
        assert_eq!(s.folder_choices.len(), 1);

        let json = serde_json::to_string(&s).unwrap();
        let back: WorkspaceSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.folder_choices, s.folder_choices);

        s.forget_project("/app");
        assert!(s.folder_choices.is_empty());
    }
}
