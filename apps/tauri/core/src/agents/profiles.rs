//! Accounts per agent (`AgentProfiles` op de Mac): "Claude · Privé", "Claude · Werk". Het hoofdaccount gebruikt de
//! standaardmap van de agent (`~/.claude`, `~/.codex`); extra accounts een eigen map (`~/.claude-werk`) waar
//! `CLAUDE_CONFIG_DIR` of `CODEX_HOME` naar wijst, zodat privé en werk naast elkaar kunnen.
//!
//! Een API-sleutel van een account staat alleen in de `SecretStore` (`agent.apikey.<id>`), nooit in een bestand.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{home_dir, tilde, AgentKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentAuthMethod {
    /// Via de agent zelf: abonnement (Claude Pro/Max, ChatGPT) of de inlog van de CLI.
    Cli,
    /// Met een API-sleutel. Claude Code: in Nooks kluis; Codex beheert hem zelf (`codex login --with-api-key`).
    ApiKey,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    /// "claude" voor het hoofdaccount, "claude-werk" voor extra accounts.
    pub id: String,
    pub kind: AgentKind,
    /// Zelfgekozen naam ("Werk"); leeg voor het hoofdaccount.
    pub label: String,
    /// `None`: de standaardmap van de agent.
    pub home: Option<String>,
    #[serde(default)]
    pub auth: Option<AgentAuthMethod>,
}

impl AgentProfile {
    pub fn default_profile(kind: AgentKind) -> Self {
        Self { id: kind.id().into(), kind, label: String::new(), home: None, auth: None }
    }

    pub fn is_default(&self) -> bool {
        self.home.is_none()
    }

    pub fn uses_api_key(&self) -> bool {
        self.auth == Some(AgentAuthMethod::ApiKey)
    }

    /// De kluisnaam van de API-sleutel van dit account.
    pub fn secret_account(&self) -> String {
        format!("agent.apikey.{}", self.id)
    }

    pub fn home_path(&self) -> PathBuf {
        self.home.as_ref().map(PathBuf::from).unwrap_or_else(|| self.kind.default_home())
    }

    /// De omgevingsvariabele die de agent naar deze map wijst; leeg voor het hoofdaccount.
    pub fn environment(&self) -> BTreeMap<String, String> {
        let mut env = BTreeMap::new();
        if let (Some(home), Some(variable)) = (&self.home, self.kind.home_variable()) {
            env.insert(variable.into(), home.clone());
        }
        env
    }

    /// "Claude Code · Werk"
    pub fn title(&self) -> String {
        if self.label.is_empty() {
            self.kind.name().into()
        } else {
            format!("{} · {}", self.kind.name(), self.label)
        }
    }

    pub fn display_home(&self) -> String {
        tilde(&self.home_path().to_string_lossy())
    }

    /// Het startcommando in een terminal. De sleutel zelf komt er nooit in; die zet Nook in de omgeving van het proces.
    pub fn launch_command(&self) -> String {
        self.with_prefix(self.kind.command())
    }

    /// Inloggen onder dit account, in een terminal.
    pub fn login_command(&self) -> String {
        self.with_prefix(self.kind.login_command())
    }

    fn with_prefix(&self, command: &str) -> String {
        let mut prefix = String::new();
        if let (Some(home), Some(variable)) = (&self.home, self.kind.home_variable()) {
            if cfg!(windows) {
                prefix = format!("$env:{variable}='{}'; ", home.replace('\'', "''"));
            } else {
                prefix = format!("{variable}={} ", shell_quote(home));
            }
        }
        format!("{prefix}{command}")
    }
}

/// Een pad of woord veilig voor een POSIX-shell.
pub fn shell_quote(text: &str) -> String {
    if !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:@%+".contains(c)) {
        return text.into();
    }
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// "Bettr Health" → "bettr-health".
pub fn slug(text: &str) -> String {
    let mut result = String::new();
    for c in fold(text).to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            result.push(c);
        } else if !result.is_empty() && !result.ends_with('-') {
            result.push('-');
        }
    }
    while result.ends_with('-') {
        result.pop();
    }
    if result.is_empty() {
        "werk".into()
    } else {
        result.chars().take(24).collect()
    }
}

/// Haalt accenten weg (é → e) voor de gangbare Latijnse letters.
pub fn fold(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' => 'A',
            'È' | 'É' | 'Ê' | 'Ë' => 'E',
            'Ì' | 'Í' | 'Î' | 'Ï' => 'I',
            'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' => 'O',
            'Ù' | 'Ú' | 'Û' | 'Ü' => 'U',
            other => other,
        })
        .collect()
}

pub fn normalize(path: &str) -> String {
    super::hub::normalize_home(path)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Stored {
    profiles: Vec<AgentProfile>,
    preferred: BTreeMap<String, String>,
    /// Mappen van accounts die je uit Nook haalde: nooit meer vanzelf opnemen.
    dismissed: BTreeSet<String>,
}

/// De accounts, bewaard in `agent-profiles.json` in Nooks map.
pub struct ProfileStore {
    file: Option<PathBuf>,
    stored: Stored,
}

impl ProfileStore {
    pub fn load(file: Option<PathBuf>) -> Self {
        let stored = file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file, stored }
    }

    fn save(&self) {
        if let (Some(file), Ok(bytes)) = (&self.file, serde_json::to_vec_pretty(&self.stored)) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// Alle accounts, het hoofdaccount van elke agent eerst.
    pub fn all(&self) -> Vec<AgentProfile> {
        let mut result = vec![];
        for kind in AgentKind::ALL {
            result.push(
                self.stored
                    .profiles
                    .iter()
                    .find(|p| p.kind == kind && p.is_default())
                    .cloned()
                    .unwrap_or_else(|| AgentProfile::default_profile(kind)),
            );
            result.extend(self.stored.profiles.iter().filter(|p| p.kind == kind && !p.is_default()).cloned());
        }
        result
    }

    pub fn profiles(&self, kind: AgentKind) -> Vec<AgentProfile> {
        self.all().into_iter().filter(|p| p.kind == kind).collect()
    }

    pub fn profile(&self, id: &str) -> Option<AgentProfile> {
        self.all().into_iter().find(|p| p.id == id)
    }

    pub fn preferred(&self, kind: AgentKind) -> AgentProfile {
        self.stored
            .preferred
            .get(kind.id())
            .and_then(|id| self.profile(id))
            .or_else(|| self.profile(kind.id()))
            .unwrap_or_else(|| AgentProfile::default_profile(kind))
    }

    pub fn set_preferred(&mut self, id: &str) {
        if let Some(p) = self.profile(id) {
            self.stored.preferred.insert(p.kind.id().into(), p.id);
            self.save();
        }
    }

    /// Het account bij een map (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Leeg = het hoofdaccount.
    pub fn profile_for_home(&self, kind: AgentKind, home: &str) -> Option<AgentProfile> {
        let wanted = normalize(home);
        if wanted.is_empty() || wanted == normalize(&kind.default_home().to_string_lossy()) {
            return self.profile(kind.id());
        }
        self.profiles(kind).into_iter().find(|p| normalize(&p.home_path().to_string_lossy()) == wanted)
    }

    /// Een extra account met een eigen map. Bestaat de map al, dan neemt Nook hem over.
    pub fn add(&mut self, kind: AgentKind, label: &str, home: Option<PathBuf>) -> AgentProfile {
        let name = label.trim();
        let slug = slug(if name.is_empty() { "werk" } else { name });
        let base = match kind {
            AgentKind::Claude => ".claude",
            AgentKind::Codex => ".codex",
            _ => ".gemini",
        };
        let suggested = |s: &str| home_dir().join(format!("{base}-{s}"));
        let mut folder = home.clone().unwrap_or_else(|| suggested(&slug));
        if home.is_none() {
            let mut counter = 2;
            while self.all().iter().any(|p| normalize(&p.home_path().to_string_lossy()) == normalize(&folder.to_string_lossy())) {
                folder = suggested(&format!("{slug}-{counter}"));
                counter += 1;
            }
        }
        if let Some(existing) = self.profile_for_home(kind, &folder.to_string_lossy()) {
            return existing;
        }
        self.stored.dismissed.remove(&normalize(&folder.to_string_lossy()));
        let mut id = format!("{}-{slug}", kind.id());
        let mut counter = 2;
        while self.all().iter().any(|p| p.id == id) {
            id = format!("{}-{slug}-{counter}", kind.id());
            counter += 1;
        }
        let _ = std::fs::create_dir_all(&folder);
        let profile = AgentProfile {
            id,
            kind,
            label: if name.is_empty() { "Werk".into() } else { name.chars().take(30).collect() },
            home: Some(folder.to_string_lossy().into_owned()),
            auth: None,
        };
        self.stored.profiles.push(profile.clone());
        self.save();
        profile
    }

    pub fn rename(&mut self, id: &str, label: &str) {
        let clean: String = label.trim().chars().take(30).collect();
        if let Some(p) = self.stored.profiles.iter_mut().find(|p| p.id == id) {
            if clean.is_empty() && !p.is_default() {
                return;
            }
            p.label = clean;
        } else if let Some(mut p) = self.profile(id).filter(|p| p.is_default()) {
            p.label = clean;
            self.stored.profiles.push(p);
        }
        self.save();
    }

    /// Haalt een account uit Nook. De map en de inlog op schijf blijven staan. Geeft de kluisnaam terug om te wissen.
    pub fn remove(&mut self, id: &str) -> Option<String> {
        let profile = self.profile(id).filter(|p| !p.is_default())?;
        self.stored.profiles.retain(|p| p.id != id);
        self.stored.dismissed.insert(normalize(&profile.home_path().to_string_lossy()));
        if self.stored.preferred.get(profile.kind.id()) == Some(&profile.id) {
            self.stored.preferred.remove(profile.kind.id());
        }
        self.save();
        Some(profile.secret_account())
    }

    pub fn set_auth(&mut self, id: &str, method: AgentAuthMethod) {
        let Some(mut profile) = self.profile(id) else { return };
        profile.auth = if method == AgentAuthMethod::Cli { None } else { Some(method) };
        self.stored.profiles.retain(|p| p.id != id);
        self.stored.profiles.push(profile);
        self.save();
    }

    /// Neemt accountmappen op die al op deze computer staan (`~/.claude-werk` met een inlog), en de map van een lopende
    /// sessie. Accounts die je weghaalde blijven weg.
    pub fn adopt_existing(&mut self, running: &[(AgentKind, String)]) -> bool {
        let mut folders = self.discover(&home_dir());
        for (kind, home) in running {
            if home.is_empty() || !kind.supports_profiles() {
                continue;
            }
            let path = PathBuf::from(normalize(home));
            if self.profile_for_home(*kind, home).is_none() && path.is_dir() && !folders.iter().any(|(_, f)| f == &path) {
                folders.push((*kind, path));
            }
        }
        let mut changed = false;
        for (kind, folder) in folders {
            if self.stored.dismissed.contains(&normalize(&folder.to_string_lossy())) {
                continue;
            }
            let label = label_for_folder(&folder);
            self.add(kind, &label, Some(folder));
            changed = true;
        }
        changed
    }

    /// Accountmappen (`~/.claude-werk`, `~/.codex-klant`) met een inlog die nog niet in Nook staan.
    pub fn discover(&self, home: &Path) -> Vec<(AgentKind, PathBuf)> {
        let Ok(entries) = std::fs::read_dir(home) else { return vec![] };
        let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        let mut found = vec![];
        for name in names {
            let (kind, marker) = if name.starts_with(".claude-") || name.starts_with(".claude_") {
                (AgentKind::Claude, ".claude.json")
            } else if name.starts_with(".codex-") || name.starts_with(".codex_") {
                (AgentKind::Codex, "auth.json")
            } else {
                continue;
            };
            let path = home.join(&name);
            if path.join(marker).exists() && self.profile_for_home(kind, &path.to_string_lossy()).is_none() {
                found.push((kind, path));
            }
        }
        found
    }
}

/// "~/.claude-werk" → "Werk"; een map zonder achtervoegsel heet naar zichzelf.
pub fn label_for_folder(path: &Path) -> String {
    let folder = path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let mut name: String = match folder.find(['-', '_']) {
        Some(i) => folder[i + 1..].to_string(),
        None => String::new(),
    };
    if name.is_empty() {
        name = folder.trim_matches('.').to_string();
    }
    if name.is_empty() {
        name = "Werk".into();
    }
    let mut chars = name.chars();
    let first = chars.next().map(|c| c.to_uppercase().collect::<String>()).unwrap_or_default();
    (first + chars.as_str()).chars().take(30).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_and_labels() {
        assert_eq!(slug("Bettr Health"), "bettr-health");
        assert_eq!(slug("Café!"), "cafe");
        assert_eq!(slug("   "), "werk");
        assert_eq!(label_for_folder(Path::new("/home/x/.claude-werk")), "Werk");
        assert_eq!(label_for_folder(Path::new("/home/x/.codex_klant-a")), "Klant-a");
    }

    #[test]
    fn add_find_and_remove() {
        let dir = std::env::temp_dir().join(format!("nook-profiles-{}", uuid::Uuid::new_v4()));
        let mut store = ProfileStore::load(Some(dir.join("p.json")));
        let folder = dir.join(".claude-werk");
        let p = store.add(AgentKind::Claude, "Werk", Some(folder.clone()));
        assert_eq!(p.id, "claude-werk");
        assert_eq!(store.profile_for_home(AgentKind::Claude, &folder.to_string_lossy()).unwrap().id, "claude-werk");
        assert_eq!(store.profile_for_home(AgentKind::Claude, "").unwrap().id, "claude");
        assert_eq!(p.environment().get("CLAUDE_CONFIG_DIR").map(String::as_str), Some(folder.to_string_lossy().as_ref()));
        store.set_preferred("claude-werk");
        let reloaded = ProfileStore::load(Some(dir.join("p.json")));
        assert_eq!(reloaded.preferred(AgentKind::Claude).id, "claude-werk");
        assert_eq!(store.remove("claude-werk").as_deref(), Some("agent.apikey.claude-werk"));
        assert!(store.remove("claude").is_none(), "het hoofdaccount blijft");
        std::fs::write(folder.join(".claude.json"), "{}").unwrap();
        assert!(store.discover(&dir).is_empty() || store.stored.dismissed.contains(&normalize(&folder.to_string_lossy())));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("/home/x/.claude-werk"), "/home/x/.claude-werk");
        assert_eq!(shell_quote("/home/x/My Projects"), "'/home/x/My Projects'");
    }
}
