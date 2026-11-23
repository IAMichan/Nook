use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// De enige plek waar geheimen (API-sleutels, tokens) gelezen en geschreven worden.
/// Op Windows is dat Credential Manager, op Linux de Secret Service (GNOME Keyring/KWallet),
/// op Android de Keystore; de implementaties staan in `src-tauri/src/platform`.
pub trait SecretStore: Send + Sync {
    /// Het geheim, getrimd; `None` als het ontbreekt of leeg is.
    fn read(&self, account: &str) -> Option<String>;
    /// Bewaart het geheim; een lege waarde haalt het weg.
    fn write(&self, account: &str, value: &str) -> Result<(), String>;
    fn remove(&self, account: &str) -> Result<(), String>;
}

/// Gekopieerde sleutels hebben vaak een witregel of aanhalingstekens eromheen.
pub fn clean_secret(value: &str) -> String {
    value.trim().trim_matches(|c| c == '"' || c == '\'' || c == '`').trim().to_string()
}

/// Laat alleen het begin en eind van een sleutel zien: `sk-ant-…a1b2`.
pub fn mask(secret: &str) -> String {
    let chars: Vec<char> = secret.chars().collect();
    if chars.len() <= 10 {
        return "••••".into();
    }
    let head: String = chars[..7].iter().collect();
    let tail: String = chars[chars.len() - 4..].iter().collect();
    format!("{head}…{tail}")
}

/// Geheimen in het geheugen, voor tests en als laatste uitweg wanneer het systeem geen kluis heeft.
#[derive(Default)]
pub struct MemorySecrets(Mutex<HashMap<String, String>>);

impl SecretStore for MemorySecrets {
    fn read(&self, account: &str) -> Option<String> {
        self.0.lock().ok()?.get(account).cloned().filter(|v| !v.is_empty())
    }

    fn write(&self, account: &str, value: &str) -> Result<(), String> {
        let cleaned = clean_secret(value);
        if cleaned.is_empty() {
            return self.remove(account);
        }
        self.0.lock().map_err(|e| e.to_string())?.insert(account.into(), cleaned);
        Ok(())
    }

    fn remove(&self, account: &str) -> Result<(), String> {
        self.0.lock().map_err(|e| e.to_string())?.remove(account);
        Ok(())
    }
}

/// Keychain / settings account names for 1Password (`SecretProviders` on macOS, CH-97).
pub const OP_SERVICE_ACCOUNT_KEY: &str = "secrets.op.serviceAccountToken";
pub const OP_CONNECT_TOKEN_KEY: &str = "secrets.op.connectToken";
pub const OP_CONNECT_HOST_KEY: &str = "secrets.op.connectHost";
pub const OP_ENABLED_KEY: &str = "secrets.op.enabled";

/// A secret kept in 1Password, named by reference instead of by value: `op://vault/item/field` or
/// `op://vault/item/section/field`, optionally with `?attribute=otp` (`SecretReference` on macOS, CH-97).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretReference {
    pub vault: String,
    pub item: String,
    pub section: Option<String>,
    pub field: String,
    pub query: Option<String>,
}

impl SecretReference {
    /// Parses `raw` as a 1Password `op://` reference, or `None` if it is not a valid reference.
    /// Names may hold letters, digits, spaces, `.`, `_` and `-` (up to 128 chars, not starting/ending with space).
    pub fn parse(raw: &str) -> Option<Self> {
        let text = raw.trim();
        let rest = text.strip_prefix("op://")?;
        let (path_part, query) = if let Some((head, tail)) = rest.split_once('?') {
            if !Self::is_valid_query(tail) {
                return None;
            }
            (head, Some(tail.to_string()))
        } else {
            (rest, None)
        };
        let parts: Vec<&str> = path_part.split('/').collect();
        if !(3..=4).contains(&parts.len()) || !parts.iter().all(|p| Self::is_valid_name(p)) {
            return None;
        }
        Some(Self {
            vault: parts[0].to_string(),
            item: parts[1].to_string(),
            section: if parts.len() == 4 { Some(parts[2].to_string()) } else { None },
            field: parts[parts.len() - 1].to_string(),
            query,
        })
    }

    /// The canonical `op://...` string passed to `op read`.
    pub fn text(&self) -> String {
        let mut s = format!("op://{}/{}/", self.vault, self.item);
        if let Some(sec) = &self.section {
            s.push_str(sec);
            s.push('/');
        }
        s.push_str(&self.field);
        if let Some(q) = &self.query {
            s.push('?');
            s.push_str(q);
        }
        s
    }

    pub fn is_reference(raw: &str) -> bool {
        Self::parse(raw).is_some()
    }

    fn is_valid_name(part: &str) -> bool {
        let count = part.chars().count();
        if part.is_empty() || count > 128 || part.starts_with(' ') || part.ends_with(' ') {
            return false;
        }
        part.chars().all(|c| {
            (c.is_alphanumeric() || matches!(c, ' ' | '.' | '_' | '-')) && c != '\n' && c != '\r'
        })
    }

    fn is_valid_query(q: &str) -> bool {
        let Some((k, v)) = q.split_once('=') else {
            return false;
        };
        !k.is_empty()
            && !v.is_empty()
            && k.chars().all(|c| c.is_ascii_alphabetic())
            && v.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    }
}

/// How `op` signs in (`OnePassword.Config.Mode` on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OnePasswordMode {
    Desktop,
    ServiceAccount,
    Connect,
}

/// Configuration for invoking the 1Password `op` CLI (`OnePassword.Config` on macOS).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OnePasswordConfig {
    pub executable: Option<String>,
    pub service_account_token: Option<String>,
    pub connect_host: Option<String>,
    pub connect_token: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

impl OnePasswordConfig {
    /// Service account wins over Connect because `op` refuses both at once.
    pub fn mode(&self) -> OnePasswordMode {
        if self.service_account_token.as_deref().is_some_and(|s| !s.trim().is_empty()) {
            return OnePasswordMode::ServiceAccount;
        }
        if self.connect_host.as_deref().is_some_and(|s| !s.trim().is_empty())
            && self.connect_token.as_deref().is_some_and(|s| !s.trim().is_empty())
        {
            return OnePasswordMode::Connect;
        }
        OnePasswordMode::Desktop
    }

    /// Environment variables to set and remove when spawning `op`.
    pub fn environment(&self) -> (HashMap<String, String>, Vec<String>) {
        let all = [
            "OP_SERVICE_ACCOUNT_TOKEN".to_string(),
            "OP_CONNECT_HOST".to_string(),
            "OP_CONNECT_TOKEN".to_string(),
        ];
        match self.mode() {
            OnePasswordMode::ServiceAccount => {
                let mut set = HashMap::new();
                set.insert(
                    "OP_SERVICE_ACCOUNT_TOKEN".to_string(),
                    self.service_account_token.clone().unwrap_or_default(),
                );
                let removed = all.into_iter().filter(|k| k != "OP_SERVICE_ACCOUNT_TOKEN").collect();
                (set, removed)
            }
            OnePasswordMode::Connect => {
                let mut set = HashMap::new();
                set.insert(
                    "OP_CONNECT_HOST".to_string(),
                    self.connect_host.clone().unwrap_or_default(),
                );
                set.insert(
                    "OP_CONNECT_TOKEN".to_string(),
                    self.connect_token.clone().unwrap_or_default(),
                );
                (set, vec!["OP_SERVICE_ACCOUNT_TOKEN".to_string()])
            }
            OnePasswordMode::Desktop => (HashMap::new(), all.to_vec()),
        }
    }
}

/// Output of running `op`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OnePasswordOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: String,
}

/// Error from resolving or checking a 1Password reference (`OnePassword.Failure` on macOS).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum OnePasswordFailure {
    Disabled,
    NotReference,
    NotInstalled,
    TimedOut,
    Empty,
    Refused(String),
}

impl OnePasswordFailure {
    pub fn message(&self) -> String {
        match self {
            Self::Disabled => "1Password secret provider is turned off.".to_string(),
            Self::NotReference => "This is not a 1Password reference (op://vault/item/field).".to_string(),
            Self::NotInstalled => "The 1Password CLI (op) is not installed.".to_string(),
            Self::TimedOut => "1Password did not answer in time. Unlock it and try again.".to_string(),
            Self::Empty => "1Password returned an empty value.".to_string(),
            Self::Refused(reason) => format!("1Password could not read it: {reason}"),
        }
    }
}

/// Status returned to Settings › Connections › Secret providers (CH-97).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OnePasswordStatus {
    pub installed: bool,
    pub executable: Option<String>,
    pub version: Option<String>,
    pub enabled: bool,
    pub mode: OnePasswordMode,
    pub has_service_account_token: bool,
    pub has_connect_token: bool,
    pub connect_host: String,
    pub account: Option<String>,
}

pub type OpRunner = Arc<
    dyn Fn(&str, &[String], &HashMap<String, String>, &[String]) -> Option<OnePasswordOutput>
        + Send
        + Sync,
>;

/// 1Password CLI (`op`) secret provider (`OnePassword` / `SecretProviders` on macOS, CH-97).
pub struct OnePasswordProvider {
    runner: OpRunner,
}

impl Default for OnePasswordProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl OnePasswordProvider {
    pub fn new() -> Self {
        Self {
            runner: Arc::new(Self::process_runner),
        }
    }

    pub fn with_runner(runner: OpRunner) -> Self {
        Self { runner }
    }

    /// Locates the `op` binary on Windows, macOS, and Linux.
    pub fn locate_op() -> Option<String> {
        let mut candidates: Vec<String> = Vec::new();
        if let Ok(home) = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")) {
            candidates.push(format!("{home}/.local/bin/op"));
            candidates.push(format!("{home}/bin/op"));
            candidates.push(format!(
                "{home}\\AppData\\Local\\Microsoft\\WinGet\\Links\\op.exe"
            ));
            candidates.push(format!(
                "{home}\\AppData\\Local\\Programs\\1Password CLI\\op.exe"
            ));
            candidates.push(format!("{home}\\scoop\\shims\\op.exe"));
        }
        candidates.extend([
            "C:\\Program Files\\1Password CLI\\op.exe".to_string(),
            "C:\\ProgramData\\chocolatey\\bin\\op.exe".to_string(),
            "/opt/homebrew/bin/op".to_string(),
            "/usr/local/bin/op".to_string(),
            "/usr/bin/op".to_string(),
        ]);
        for path in candidates {
            if Path::new(&path).is_file() {
                return Some(path);
            }
        }
        // Fallback: check if `op` is on PATH by running `op --version`
        let cmd = if cfg!(windows) { "op.exe" } else { "op" };
        if Command::new(cmd)
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
        {
            return Some(cmd.to_string());
        }
        None
    }

    /// Builds a config from a `SecretStore` (reading tokens and enabled state).
    pub fn config_from_store(store: &dyn SecretStore) -> OnePasswordConfig {
        let enabled = store
            .read(OP_ENABLED_KEY)
            .map(|v| v != "false" && v != "0")
            .unwrap_or(true);
        OnePasswordConfig {
            executable: Self::locate_op(),
            service_account_token: store.read(OP_SERVICE_ACCOUNT_KEY),
            connect_host: store.read(OP_CONNECT_HOST_KEY),
            connect_token: store.read(OP_CONNECT_TOKEN_KEY),
            enabled,
        }
    }

    /// Queries CLI availability, version (`op --version`), and configuration status.
    pub fn status(&self, config: &OnePasswordConfig) -> OnePasswordStatus {
        let version = config.executable.as_deref().and_then(|exe| {
            let (set, removed) = config.environment();
            let out = (self.runner)(exe, &["--version".to_string()], &set, &removed)?;
            if out.status == 0 {
                let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
                (!v.is_empty()).then_some(v)
            } else {
                None
            }
        });
        let installed = config.executable.is_some() && version.is_some();
        OnePasswordStatus {
            installed,
            executable: config.executable.clone(),
            version,
            enabled: config.enabled,
            mode: config.mode(),
            has_service_account_token: config
                .service_account_token
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty()),
            has_connect_token: config
                .connect_token
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty()),
            connect_host: config.connect_host.clone().unwrap_or_default(),
            account: None,
        }
    }

    /// Reads the secret behind `reference` via `op read --no-newline <ref>`.
    pub fn read(
        &self,
        reference: &SecretReference,
        config: &OnePasswordConfig,
    ) -> Result<String, OnePasswordFailure> {
        if !config.enabled {
            return Err(OnePasswordFailure::Disabled);
        }
        let Some(exe) = config.executable.as_deref() else {
            return Err(OnePasswordFailure::NotInstalled);
        };
        let (set, removed) = config.environment();
        let args = vec![
            "read".to_string(),
            "--no-newline".to_string(),
            reference.text(),
        ];
        let Some(output) = (self.runner)(exe, &args, &set, &removed) else {
            return Err(OnePasswordFailure::TimedOut);
        };
        if output.status != 0 {
            return Err(OnePasswordFailure::Refused(Self::reason(&output.stderr)));
        }
        let value = String::from_utf8_lossy(&output.stdout).to_string();
        if value.is_empty() {
            return Err(OnePasswordFailure::Empty);
        }
        Ok(value)
    }

    /// Resolves `value`: if it is an `op://` reference, reads it from 1Password; if it starts with `op://`
    /// but is malformed, returns `Err(OnePasswordFailure::NotReference)`; otherwise returns `value` unchanged.
    pub fn resolve(&self, value: &str, config: &OnePasswordConfig) -> Result<String, OnePasswordFailure> {
        let trimmed = value.trim();
        if let Some(reference) = SecretReference::parse(trimmed) {
            self.read(&reference, config)
        } else if trimmed.starts_with("op://") {
            Err(OnePasswordFailure::NotReference)
        } else {
            Ok(value.to_string())
        }
    }

    /// Resolves a map of key-value pairs where any `op://` reference is replaced by its resolved secret.
    pub fn resolve_all(
        &self,
        values: &HashMap<String, String>,
        config: &OnePasswordConfig,
    ) -> Result<HashMap<String, String>, String> {
        if !values.values().any(|v| v.trim().starts_with("op://")) {
            return Ok(values.clone());
        }
        let mut out = HashMap::with_capacity(values.len());
        for (k, v) in values {
            match self.resolve(v, config) {
                Ok(resolved) => {
                    out.insert(k.clone(), resolved);
                }
                Err(failure) => {
                    return Err(format!("{k}: {}", failure.message()));
                }
            }
        }
        Ok(out)
    }

    /// Checks that `op` can sign in (`op whoami`, or `op read` when a `probe` reference is given).
    pub fn check(
        &self,
        config: &OnePasswordConfig,
        probe: Option<&SecretReference>,
    ) -> Result<String, OnePasswordFailure> {
        if !config.enabled {
            return Err(OnePasswordFailure::Disabled);
        }
        let Some(exe) = config.executable.as_deref() else {
            return Err(OnePasswordFailure::NotInstalled);
        };
        if let Some(p) = probe {
            let _ = self.read(p, config)?;
            return Ok(String::new());
        }
        let (set, removed) = config.environment();
        let Some(output) = (self.runner)(exe, &["whoami".to_string()], &set, &removed) else {
            return Err(OnePasswordFailure::TimedOut);
        };
        if output.status != 0 {
            return Err(OnePasswordFailure::Refused(Self::reason(&output.stderr)));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let account = stdout
            .lines()
            .find(|line| {
                let l = line.trim();
                l.starts_with("Email:") || l.starts_with("URL:") || l.starts_with("User Type:")
            })
            .map(|l| l.trim().to_string())
            .unwrap_or_default();
        Ok(account)
    }

    /// Strips `[ERROR] YYYY/MM/DD HH:MM:SS` prefix from `op` stderr and truncates to 200 chars.
    pub fn reason(stderr: &str) -> String {
        let line = stderr
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("");
        let mut rest = line.strip_prefix("[ERROR]").unwrap_or(line).trim_start();
        // Strip optional date `YYYY/MM/DD` and time `HH:MM:SS`
        if rest.len() >= 10
            && rest.as_bytes()[4] == b'/'
            && rest.as_bytes()[7] == b'/'
            && rest[..4].chars().all(|c| c.is_ascii_digit())
        {
            rest = rest[10..].trim_start();
        }
        if rest.len() >= 8
            && rest.as_bytes()[2] == b':'
            && rest.as_bytes()[5] == b':'
            && rest[..2].chars().all(|c| c.is_ascii_digit())
        {
            rest = rest[8..].trim_start();
        }
        if rest.is_empty() {
            return "op stopped without saying why.".to_string();
        }
        let chars: Vec<char> = rest.chars().collect();
        if chars.len() > 200 {
            let prefix: String = chars[..200].iter().collect();
            format!("{prefix}…")
        } else {
            rest.to_string()
        }
    }

    fn process_runner(
        executable: &str,
        arguments: &[String],
        environment: &HashMap<String, String>,
        removed: &[String],
    ) -> Option<OnePasswordOutput> {
        let mut cmd = Command::new(executable);
        cmd.args(arguments);
        for key in removed {
            cmd.env_remove(key);
        }
        for (k, v) in environment {
            cmd.env(k, v);
        }
        let output = cmd.output().ok()?;
        Some(OnePasswordOutput {
            status: output.status.code().unwrap_or(1),
            stdout: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_pasted_keys() {
        assert_eq!(clean_secret(" \"sk-abc\"\n"), "sk-abc");
    }

    #[test]
    fn empty_write_removes() {
        let s = MemorySecrets::default();
        s.write("a", "x").unwrap();
        assert_eq!(s.read("a").as_deref(), Some("x"));
        s.write("a", "  ").unwrap();
        assert_eq!(s.read("a"), None);
    }

    #[test]
    fn masks() {
        assert_eq!(mask("sk-ant-1234567890abcd"), "sk-ant-…abcd");
    }

    #[test]
    fn references_are_parsed_strictly() {
        let plain = SecretReference::parse("op://Private/Stripe/credential").unwrap();
        assert_eq!(plain.vault, "Private");
        assert_eq!(plain.item, "Stripe");
        assert_eq!(plain.section, None);
        assert_eq!(plain.field, "credential");

        let full = SecretReference::parse(" op://Work Vault/GitHub/Tokens/ci token?attribute=otp ").unwrap();
        assert_eq!(full.section.as_deref(), Some("Tokens"));
        assert_eq!(full.text(), "op://Work Vault/GitHub/Tokens/ci token?attribute=otp");

        for bad in [
            "op://vault/item",
            "op://a/b/c/d/e",
            "op://a//c",
            "op://a/b/$(rm -rf ~)",
            "op://a/b/c?x",
            "sk-123",
            "op://a/b/c\"",
            "op:/a/b/c",
            "op:// a/b/c",
            "op://a/b /c",
        ] {
            assert!(SecretReference::parse(bad).is_none(), "expected None for {bad}");
        }
    }

    #[test]
    fn reference_is_read_with_op_read_and_modes_configure_env() {
        let calls: Arc<Mutex<Vec<(Vec<String>, HashMap<String, String>, Vec<String>)>>> =
            Arc::new(Mutex::new(Vec::new()));
        let calls_clone = calls.clone();
        let provider = OnePasswordProvider::with_runner(Arc::new(move |_, args, env, removed| {
            calls_clone
                .lock()
                .unwrap()
                .push((args.to_vec(), env.clone(), removed.to_vec()));
            Some(OnePasswordOutput {
                status: 0,
                stdout: b"s3cret".to_vec(),
                stderr: String::new(),
            })
        }));

        let config = OnePasswordConfig {
            executable: Some("/opt/homebrew/bin/op".to_string()),
            enabled: true,
            ..Default::default()
        };
        let value = provider.resolve("op://Private/Stripe/credential", &config).unwrap();
        assert_eq!(value, "s3cret");
        {
            let recorded = calls.lock().unwrap();
            assert_eq!(
                recorded[0].0,
                vec!["read", "--no-newline", "op://Private/Stripe/credential"]
            );
            assert!(recorded[0].1.is_empty());
            assert_eq!(recorded[0].2.len(), 3);
        }

        // Plain value never invokes `op`
        let literal = provider.resolve("plain-value", &config).unwrap();
        assert_eq!(literal, "plain-value");
        assert_eq!(calls.lock().unwrap().len(), 1);

        // Mode precedence: service account wins over Connect
        let service_cfg = OnePasswordConfig {
            executable: Some("op".to_string()),
            service_account_token: Some("ops_x".to_string()),
            connect_host: Some("https://c".to_string()),
            connect_token: Some("t".to_string()),
            enabled: true,
        };
        assert_eq!(service_cfg.mode(), OnePasswordMode::ServiceAccount);
        assert_eq!(
            service_cfg.environment().0.get("OP_SERVICE_ACCOUNT_TOKEN").map(String::as_str),
            Some("ops_x")
        );

        let connect_cfg = OnePasswordConfig {
            executable: Some("op".to_string()),
            service_account_token: None,
            connect_host: Some("https://c".to_string()),
            connect_token: Some("t".to_string()),
            enabled: true,
        };
        assert_eq!(connect_cfg.mode(), OnePasswordMode::Connect);
    }

    #[test]
    fn op_failures_strip_error_header_without_leaking_values() {
        let provider = OnePasswordProvider::with_runner(Arc::new(|_, _, _, _| {
            Some(OnePasswordOutput {
                status: 1,
                stdout: Vec::new(),
                stderr: "[ERROR] 2026/11/10 10:00:00 \"Stripe\" isn't an item in the \"Private\" vault\n"
                    .to_string(),
            })
        }));
        let config = OnePasswordConfig {
            executable: Some("op".to_string()),
            enabled: true,
            ..Default::default()
        };
        let err = provider.resolve("op://Private/Stripe/credential", &config).unwrap_err();
        assert_eq!(
            err,
            OnePasswordFailure::Refused("\"Stripe\" isn't an item in the \"Private\" vault".to_string())
        );
    }
}
