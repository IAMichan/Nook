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

/// One environment variable of an account (`AccountVariable` on the Mac). A sensitive value (such as a token) is stored
/// in the system keychain rather than in `agent-profiles.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountVariable {
    pub name: String,
    /// Empty on disk for a sensitive variable: its value lives in the `SecretStore`.
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub sensitive: bool,
}

impl AccountVariable {
    /// Letters, digits and underscores, not starting with a digit (the shell's rule).
    pub fn is_valid_name(name: &str) -> bool {
        let mut chars = name.chars();
        let Some(first) = chars.next() else { return false };
        if first != '_' && !first.is_ascii_alphabetic() {
            return false;
        }
        chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
    }
}

/// Keychain updates returned by `ProfileStore::set_variables` so `nook-core` stays decoupled from secret-store I/O.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VariableSecretPlan {
    /// `(secret_account, value)` pairs to write to the keychain.
    pub write: Vec<(String, String)>,
    /// `secret_account` keys to erase from the keychain.
    pub delete: Vec<String>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<AgentAuthMethod>,
    /// True once switched off: Nook omits this account from lists and Auto while keeping its login and settings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled: Option<bool>,
    /// Program this account starts instead of the one Nook found (`~` expanded on launch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executable_path: Option<String>,
    /// Extra arguments appended after Nook's own on every launch under this account.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_arguments: Option<Vec<String>>,
    /// Per-account environment variables (sensitive values live in the keychain).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variables: Option<Vec<AccountVariable>>,
    /// Additional model names offered in this account's model menus.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_models: Option<Vec<String>>,
}

/// The environment variable that points a CLI agent at a dedicated account directory (`None` for single-account agents).
pub fn profile_home_variable(kind: AgentKind) -> Option<&'static str> {
    if let Some(var) = kind.home_variable() {
        return Some(var);
    }
    match kind {
        AgentKind::Opencode => Some("OPENCODE_CONFIG_DIR"),
        AgentKind::Cursor => Some("CURSOR_CONFIG_DIR"),
        AgentKind::Grok => Some("GROK_HOME"),
        _ => None,
    }
}

/// The environment variable value for a profile stored at `home`.
pub fn profile_home_value(kind: AgentKind, home: &str) -> String {
    kind.home_value(home)
}

/// The account folder a running agent's `profile_home_variable` points at.
pub fn profile_home_from_variable(kind: AgentKind, value: &str) -> String {
    kind.home_from_variable(value)
}

/// Suggested folder for an extra account (`~/.claude-werk`, `~/.gemini-werk/.gemini`, `~/.opencode-werk`, etc.).
pub fn profile_suggested_home(kind: AgentKind, slug: &str) -> PathBuf {
    let home = home_dir();
    match kind {
        AgentKind::Claude => home.join(format!(".claude-{slug}")),
        AgentKind::Codex => home.join(format!(".codex-{slug}")),
        AgentKind::Gemini => home.join(format!(".gemini-{slug}")).join(".gemini"),
        AgentKind::Opencode => home.join(format!(".opencode-{slug}")),
        AgentKind::Cursor => home.join(format!(".cursor-{slug}")),
        AgentKind::Grok => home.join(format!(".grok-{slug}")),
        AgentKind::Antigravity => kind.default_home(),
        AgentKind::Acp => kind.default_home().join(slug),
    }
}

/// Whether `kind` supports multiple side-by-side account profiles via a dedicated config directory.
pub fn supports_multi_account_profiles(kind: AgentKind) -> bool {
    profile_home_variable(kind).is_some()
}

impl AgentProfile {
    pub fn default_profile(kind: AgentKind) -> Self {
        Self {
            id: kind.id().into(),
            kind,
            label: String::new(),
            home: None,
            auth: None,
            disabled: None,
            executable_path: None,
            extra_arguments: None,
            variables: None,
            custom_models: None,
        }
    }

    pub fn is_default(&self) -> bool {
        self.home.is_none()
    }

    pub fn is_enabled(&self) -> bool {
        self.disabled != Some(true)
    }

    pub fn uses_api_key(&self) -> bool {
        self.auth == Some(AgentAuthMethod::ApiKey)
    }

    /// De kluisnaam van de API-sleutel van dit account.
    pub fn secret_account(&self) -> String {
        format!("agent.apikey.{}", self.id)
    }

    /// Keychain account name for a sensitive environment variable of this account.
    pub fn variable_secret_account(&self, name: &str) -> String {
        format!("agent.env.{}.{name}", self.id)
    }

    /// Variables configured on this account, in order.
    pub fn active_variables(&self) -> &[AccountVariable] {
        self.variables.as_deref().unwrap_or(&[])
    }

    /// Program override for this account with leading `~` expanded, or `None` to use the one Nook detected.
    pub fn executable_override(&self) -> Option<String> {
        let raw = self.executable_path.as_deref()?.trim();
        if raw.is_empty() {
            return None;
        }
        if raw == "~" {
            return Some(home_dir().to_string_lossy().into_owned());
        }
        if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
            return Some(home_dir().join(rest).to_string_lossy().into_owned());
        }
        Some(raw.to_string())
    }

    /// Trimmed non-empty extra arguments appended on every launch under this account.
    pub fn launch_arguments(&self) -> Vec<String> {
        self.extra_arguments.as_deref().unwrap_or(&[]).iter().map(|a| a.trim()).filter(|a| !a.is_empty()).map(str::to_string).collect()
    }

    /// Custom model names configured on this account.
    pub fn custom_models_list(&self) -> &[String] {
        self.custom_models.as_deref().unwrap_or(&[])
    }

    /// Full launch environment for this account: user variables first, then Nook's home directory variable and API key
    /// so user variables can never override the account's folder or key.
    pub fn launch_environment(&self, read_secret: impl Fn(&str) -> Option<String>) -> BTreeMap<String, String> {
        let mut env = BTreeMap::new();
        for variable in self.active_variables() {
            let value = if variable.sensitive {
                read_secret(&self.variable_secret_account(&variable.name)).unwrap_or_default()
            } else {
                variable.value.clone()
            };
            env.insert(variable.name.clone(), value);
        }
        for (k, v) in self.environment() {
            env.insert(k, v);
        }
        if self.kind == AgentKind::Claude && self.uses_api_key() {
            if let Some(key) = read_secret(&self.secret_account()).filter(|k| !k.trim().is_empty()) {
                env.insert("ANTHROPIC_API_KEY".into(), key.trim().to_string());
            }
        }
        env
    }

    pub fn home_path(&self) -> PathBuf {
        self.home.as_ref().map(PathBuf::from).unwrap_or_else(|| self.kind.default_home())
    }

    /// De omgevingsvariabele die de agent naar deze map wijst; leeg voor het hoofdaccount.
    pub fn environment(&self) -> BTreeMap<String, String> {
        let mut env = BTreeMap::new();
        if let (Some(home), Some(variable)) = (&self.home, profile_home_variable(self.kind)) {
            env.insert(variable.into(), profile_home_value(self.kind, home));
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
        if let (Some(home), Some(variable)) = (&self.home, profile_home_variable(self.kind)) {
            let val = profile_home_value(self.kind, home);
            if cfg!(windows) {
                prefix = format!("$env:{variable}='{}'; ", val.replace('\'', "''"));
            } else {
                prefix = format!("{variable}={} ", shell_quote(&val));
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
            if kind != AgentKind::Acp {
                result.push(
                    self.stored
                        .profiles
                        .iter()
                        .find(|p| p.kind == kind && p.is_default())
                        .cloned()
                        .unwrap_or_else(|| AgentProfile::default_profile(kind)),
                );
            }
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
            .or_else(|| self.profiles(kind).into_iter().next())
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
        let suggested = |s: &str| profile_suggested_home(kind, s);
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
            disabled: None,
            executable_path: None,
            extra_arguments: None,
            variables: None,
            custom_models: None,
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

    /// Haalt een account uit Nook. De map en de inlog op schijf blijven staan. Geeft alle kluissleutels terug om te
    /// wissen (API-sleutel + gevoelige omgevingsvariabelen).
    pub fn remove(&mut self, id: &str) -> Option<Vec<String>> {
        let profile = self.profile(id).filter(|p| !p.is_default())?;
        self.stored.profiles.retain(|p| p.id != id);
        self.stored.dismissed.insert(normalize(&profile.home_path().to_string_lossy()));
        if self.stored.preferred.get(profile.kind.id()) == Some(&profile.id) {
            self.stored.preferred.remove(profile.kind.id());
        }
        self.save();
        let mut secrets = vec![profile.secret_account()];
        for variable in profile.active_variables().iter().filter(|v| v.sensitive) {
            secrets.push(profile.variable_secret_account(&variable.name));
        }
        Some(secrets)
    }

    fn update_profile(&mut self, id: &str, change: impl FnOnce(&mut AgentProfile)) {
        let Some(mut profile) = self.profile(id) else { return };
        let before = profile.clone();
        change(&mut profile);
        if profile == before {
            return;
        }
        if let Some(existing) = self.stored.profiles.iter_mut().find(|p| p.id == id) {
            *existing = profile;
        } else {
            self.stored.profiles.push(profile);
        }
        self.save();
    }

    pub fn set_auth(&mut self, id: &str, method: AgentAuthMethod) {
        self.update_profile(id, |p| p.auth = if method == AgentAuthMethod::Cli { None } else { Some(method) });
    }

    /// Switches an account on or off (`setEnabled` on the Mac). Primary accounts can be switched off too; if the
    /// preferred account is disabled and another enabled account exists for the same agent, preference moves there.
    pub fn set_enabled(&mut self, id: &str, enabled: bool) {
        self.update_profile(id, |p| p.disabled = if enabled { None } else { Some(true) });
        if !enabled {
            if let Some(profile) = self.profile(id) {
                if self.stored.preferred.get(profile.kind.id()).map(String::as_str) == Some(id) {
                    if let Some(other) = self.profiles(profile.kind).into_iter().find(|p| p.is_enabled()) {
                        self.stored.preferred.insert(profile.kind.id().into(), other.id);
                        self.save();
                    }
                }
            }
        }
    }

    /// Sets a custom program path for an account, or clears it when blank (`setExecutablePath` on the Mac).
    pub fn set_executable_path(&mut self, id: &str, path: &str) {
        let clean = path.trim();
        self.update_profile(id, |p| p.executable_path = if clean.is_empty() { None } else { Some(clean.to_string()) });
    }

    /// Sets extra arguments appended on every launch of an account (`setExtraArguments` on the Mac).
    pub fn set_extra_arguments(&mut self, id: &str, arguments: Vec<String>) {
        let clean: Vec<String> = arguments.into_iter().map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).collect();
        self.update_profile(id, |p| p.extra_arguments = if clean.is_empty() { None } else { Some(clean) });
    }

    /// Sets custom model names offered in this account's model menus (`setCustomModels` on the Mac).
    pub fn set_custom_models(&mut self, id: &str, models: Vec<String>) {
        let mut seen = BTreeSet::new();
        let clean: Vec<String> =
            models.into_iter().map(|m| m.trim().to_string()).filter(|m| !m.is_empty() && seen.insert(m.clone())).collect();
        self.update_profile(id, |p| p.custom_models = if clean.is_empty() { None } else { Some(clean) });
    }

    /// Replaces an account's environment variables (`setVariables` on the Mac). Invalid or duplicate names are dropped.
    /// Sensitive values are never stored on disk; returns a [`VariableSecretPlan`] for the caller to apply to the
    /// system keychain (an empty sensitive value keeps the previously stored keychain secret intact).
    pub fn set_variables(&mut self, id: &str, variables: Vec<AccountVariable>) -> VariableSecretPlan {
        let Some(profile) = self.profile(id) else { return VariableSecretPlan::default() };
        let mut seen = BTreeSet::new();
        let clean: Vec<AccountVariable> = variables
            .into_iter()
            .filter_map(|v| {
                let name = v.name.trim().to_string();
                if !AccountVariable::is_valid_name(&name) || !seen.insert(name.clone()) {
                    return None;
                }
                Some(AccountVariable { name, value: v.value, sensitive: v.sensitive })
            })
            .collect();

        let mut plan = VariableSecretPlan::default();
        for old in profile.active_variables() {
            if old.sensitive && !clean.iter().any(|v| v.name == old.name && v.sensitive) {
                plan.delete.push(profile.variable_secret_account(&old.name));
            }
        }
        let mut stored = Vec::with_capacity(clean.len());
        for variable in clean {
            if variable.sensitive {
                if !variable.value.is_empty() {
                    plan.write.push((profile.variable_secret_account(&variable.name), variable.value));
                }
                stored.push(AccountVariable { name: variable.name, value: String::new(), sensitive: true });
            } else {
                stored.push(variable);
            }
        }
        self.update_profile(id, |p| p.variables = if stored.is_empty() { None } else { Some(stored) });
        plan
    }

    /// Neemt accountmappen op die al op deze computer staan (`~/.claude-werk` met een inlog), en de map van een lopende
    /// sessie. Accounts die je weghaalde blijven weg.
    pub fn adopt_existing(&mut self, running: &[(AgentKind, String)]) -> bool {
        let mut folders = self.discover(&home_dir());
        for (kind, home) in running {
            if home.is_empty() || !supports_multi_account_profiles(*kind) {
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

    /// Accountmappen (`~/.claude-werk`, `~/.codex-klant`, `~/.opencode-werk`, `~/.cursor-werk`, `~/.grok-werk`) met een
    /// inlog die nog niet in Nook staan.
    pub fn discover(&self, home: &Path) -> Vec<(AgentKind, PathBuf)> {
        let Ok(entries) = std::fs::read_dir(home) else { return vec![] };
        let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        let mut found = vec![];
        for name in names {
            let (kind, markers): (AgentKind, &[&str]) = if name.starts_with(".claude-") || name.starts_with(".claude_") {
                (AgentKind::Claude, &[".claude.json"])
            } else if name.starts_with(".codex-") || name.starts_with(".codex_") {
                (AgentKind::Codex, &["auth.json"])
            } else if name.starts_with(".opencode-") || name.starts_with(".opencode_") {
                (AgentKind::Opencode, &["auth.json", "opencode.json"])
            } else if name.starts_with(".cursor-") || name.starts_with(".cursor_") {
                (AgentKind::Cursor, &["cli-config.json", "auth.json"])
            } else if name.starts_with(".grok-") || name.starts_with(".grok_") {
                (AgentKind::Grok, &["auth.json", "config.json", "settings.json"])
            } else if name.starts_with(".gemini-") || name.starts_with(".gemini_") {
                // GEMINI_CLI_HOME stands in for the home folder: the account's data is in its `.gemini`.
                let data = home.join(&name).join(".gemini");
                let signed_in = ["oauth_creds.json", "google_accounts.json"].iter().any(|f| data.join(f).exists());
                if signed_in && self.profile_for_home(AgentKind::Gemini, &data.to_string_lossy()).is_none() {
                    found.push((AgentKind::Gemini, data));
                }
                continue;
            } else {
                continue;
            };
            let path = home.join(&name);
            let signed_in = markers.iter().any(|m| path.join(m).exists());
            if signed_in && self.profile_for_home(kind, &path.to_string_lossy()).is_none() {
                found.push((kind, path));
            }
        }
        found
    }
}

/// "~/.claude-werk" → "Werk"; een map zonder achtervoegsel heet naar zichzelf.
pub fn label_for_folder(path: &Path) -> String {
    // ~/.gemini-werk/.gemini is named after the folder around it.
    let path = if path.file_name().is_some_and(|n| n == ".gemini") { path.parent().unwrap_or(path) } else { path };
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
        assert_eq!(label_for_folder(Path::new("/home/x/.gemini-werk/.gemini")), "Werk");
    }

    #[test]
    fn gemini_accounts_point_the_variable_at_the_folder_around_dot_gemini() {
        assert_eq!(AgentKind::Gemini.home_variable(), Some("GEMINI_CLI_HOME"));
        assert_eq!(AgentKind::Gemini.home_value("/h/.gemini-werk/.gemini"), "/h/.gemini-werk");
        assert_eq!(AgentKind::Gemini.home_value("/h/other"), "/h/other");
        assert_eq!(
            AgentKind::Gemini.home_from_variable("/h/.gemini-werk"),
            std::path::Path::new("/h/.gemini-werk").join(".gemini").to_string_lossy()
        );
        assert_eq!(AgentKind::Claude.home_value("/h/.claude-werk"), "/h/.claude-werk");
        let profile = AgentProfile {
            id: "gemini-werk".into(),
            kind: AgentKind::Gemini,
            label: "Werk".into(),
            home: Some("/h/.gemini-werk/.gemini".into()),
            ..AgentProfile::default_profile(AgentKind::Gemini)
        };
        assert_eq!(profile.environment().get("GEMINI_CLI_HOME").map(String::as_str), Some("/h/.gemini-werk"));
        assert!(AgentKind::Gemini.suggested_home("werk").ends_with(".gemini"));
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
        assert_eq!(store.remove("claude-werk"), Some(vec!["agent.apikey.claude-werk".into()]));
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

    #[test]
    fn multi_account_profiles_and_discovery_for_all_cli_agents() {
        let dir = std::env::temp_dir().join(format!("nook-profiles-all-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = ProfileStore::load(Some(dir.join("p.json")));

        for (kind, folder_name, marker, var) in [
            (AgentKind::Opencode, ".opencode-werk", "auth.json", "OPENCODE_CONFIG_DIR"),
            (AgentKind::Cursor, ".cursor-klant", "cli-config.json", "CURSOR_CONFIG_DIR"),
            (AgentKind::Grok, ".grok-prive", "auth.json", "GROK_HOME"),
        ] {
            assert_eq!(profile_home_variable(kind), Some(var));
            assert!(supports_multi_account_profiles(kind));
            let folder = dir.join(folder_name);
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join(marker), "{}").unwrap();
            let p = AgentProfile {
                id: format!("{}-werk", kind.id()),
                kind,
                label: "Werk".into(),
                home: Some(folder.to_string_lossy().into_owned()),
                ..AgentProfile::default_profile(kind)
            };
            assert_eq!(p.environment().get(var).map(String::as_str), Some(folder.to_string_lossy().as_ref()));
            assert!(p.launch_command().contains(var));
        }

        let discovered = store.discover(&dir);
        assert_eq!(discovered.len(), 3);
        assert!(discovered.iter().any(|(k, p)| *k == AgentKind::Opencode && p.ends_with(".opencode-werk")));
        assert!(discovered.iter().any(|(k, p)| *k == AgentKind::Cursor && p.ends_with(".cursor-klant")));
        assert!(discovered.iter().any(|(k, p)| *k == AgentKind::Grok && p.ends_with(".grok-prive")));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn account_options_and_variables_lifecycle() {
        assert!(AccountVariable::is_valid_name("HTTPS_PROXY"));
        assert!(AccountVariable::is_valid_name("_x1"));
        assert!(!AccountVariable::is_valid_name("1X"));
        assert!(!AccountVariable::is_valid_name("A-B"));
        assert!(!AccountVariable::is_valid_name(""));

        let dir = std::env::temp_dir().join(format!("nook-profiles-opts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("profiles.json");
        let mut store = ProfileStore::load(Some(file.clone()));
        let work = store.add(AgentKind::Claude, "Work", Some(dir.join(".claude-work")));

        // Switching off the preferred account shifts preference to an enabled account.
        store.set_preferred(&work.id);
        assert_eq!(store.preferred(AgentKind::Claude).id, work.id);
        store.set_enabled(&work.id, false);
        assert!(!store.profile(&work.id).unwrap().is_enabled());
        assert_eq!(store.preferred(AgentKind::Claude).id, "claude");
        store.set_enabled(&work.id, true);
        assert!(store.profile(&work.id).unwrap().is_enabled());

        // Executable path expands `~`, extra arguments trim/filter, custom models deduplicate.
        store.set_executable_path(&work.id, "  ~/bin/claude-custom  ");
        assert!(store.profile(&work.id).unwrap().executable_override().unwrap().ends_with("bin/claude-custom"));
        store.set_extra_arguments(&work.id, vec![" --verbose ".into(), "".into(), "--max-turns=5".into()]);
        assert_eq!(store.profile(&work.id).unwrap().launch_arguments(), vec!["--verbose", "--max-turns=5"]);
        store.set_custom_models(&work.id, vec!["claude-gateway-1".into(), " ".into(), "claude-gateway-1".into(), "claude-beta".into()]);
        assert_eq!(store.profile(&work.id).unwrap().custom_models_list(), &["claude-gateway-1", "claude-beta"]);

        // Variables: invalid/duplicate names dropped; sensitive values stored in keychain plan, never on disk.
        let plan = store.set_variables(
            &work.id,
            vec![
                AccountVariable { name: "HTTPS_PROXY".into(), value: "http://proxy:8080".into(), sensitive: false },
                AccountVariable { name: "1BAD".into(), value: "no".into(), sensitive: false },
                AccountVariable { name: "GATEWAY_TOKEN".into(), value: "secret-123".into(), sensitive: true },
                AccountVariable { name: "CLAUDE_CONFIG_DIR".into(), value: "/evil".into(), sensitive: false },
            ],
        );
        assert_eq!(plan.write, vec![(format!("agent.env.{}.GATEWAY_TOKEN", work.id), "secret-123".into())]);
        assert!(plan.delete.is_empty());

        // Disk JSON never contains the secret value.
        let disk = std::fs::read_to_string(&file).unwrap();
        assert!(!disk.contains("secret-123"));

        // Saving again with empty sensitive value keeps the existing keychain secret untouched.
        let plan2 = store.set_variables(
            &work.id,
            vec![
                AccountVariable { name: "HTTPS_PROXY".into(), value: "http://proxy:8080".into(), sensitive: false },
                AccountVariable { name: "GATEWAY_TOKEN".into(), value: String::new(), sensitive: true },
                AccountVariable { name: "CLAUDE_CONFIG_DIR".into(), value: "/evil".into(), sensitive: false },
            ],
        );
        assert!(plan2.write.is_empty());
        assert!(plan2.delete.is_empty());

        // Launch environment: user vars included, sensitive read from keychain, account home variable wins over clash!
        let reloaded = ProfileStore::load(Some(file));
        let p = reloaded.profile(&work.id).unwrap();
        let env =
            p.launch_environment(
                |key| {
                    if key == format!("agent.env.{}.GATEWAY_TOKEN", work.id) {
                        Some("secret-123".into())
                    } else {
                        None
                    }
                },
            );
        assert_eq!(env.get("HTTPS_PROXY").map(String::as_str), Some("http://proxy:8080"));
        assert_eq!(env.get("GATEWAY_TOKEN").map(String::as_str), Some("secret-123"));
        assert_eq!(env.get("CLAUDE_CONFIG_DIR").map(String::as_str), Some(dir.join(".claude-work").to_string_lossy().as_ref()));

        // Removing the account returns both its API key and sensitive variable keychain entries.
        let removed = store.remove(&work.id).unwrap();
        assert!(removed.contains(&format!("agent.apikey.{}", work.id)));
        assert!(removed.contains(&format!("agent.env.{}.GATEWAY_TOKEN", work.id)));
        let _ = std::fs::remove_dir_all(dir);
    }
}
