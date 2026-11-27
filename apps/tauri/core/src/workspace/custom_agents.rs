//! Custom ACP agents (`CustomAgents`, `AcpRegistry`, and `AcpInstaller` on the Mac, AG-21): any agent speaking
//! ACP (Agent Client Protocol), picked from the ACP registry (`agentclientprotocol.com`) or entered manually. Each runs
//! as an account of [`crate::agents::AgentKind::Acp`] ("ACP · Kiro"), so sessions, accounts, and model menus work just
//! like every built-in agent.

use std::collections::{BTreeMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::i18n::{tr, trf};

/// One ACP agent added by the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomAgent {
    /// The account it runs as (`acp-kiro`).
    pub profile_id: String,
    pub name: String,
    /// Its ID and version in the ACP registry, or `None` when entered manually.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registry_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Program and arguments (`"npx"`, `["-y", "@kiro/acp@1.2.3"]`).
    pub command: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    /// Folder Nook downloaded the agent into (for a registry binary download); deleted when removed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_at: Option<String>,
}

impl CustomAgent {
    /// Human-readable full command line for display in Settings.
    pub fn command_line(&self) -> String {
        let mut parts = Vec::with_capacity(1 + self.arguments.len());
        parts.push(self.command.as_str());
        parts.extend(self.arguments.iter().map(String::as_str));
        parts.join(" ")
    }

    /// Quoted shell line (`exec ...`) for POSIX shells, matching macOS `CustomAgent.shellLine`.
    pub fn shell_line(&self) -> String {
        let parts: Vec<String> =
            std::iter::once(self.command.as_str()).chain(self.arguments.iter().map(String::as_str)).map(CustomAgents::quote).collect();
        format!("exec {}", parts.join(" "))
    }
}

/// Persistent store and command-line helpers for custom ACP agents.
pub struct CustomAgents;

impl CustomAgents {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("workspace").join("custom-acp-agents.json")
    }

    /// Loads custom agents lossily: a malformed entry is skipped instead of losing the whole list.
    pub fn load() -> Vec<CustomAgent> {
        Self::load_from(&Self::file())
    }

    pub fn load_from(path: &Path) -> Vec<CustomAgent> {
        let Ok(bytes) = std::fs::read(path) else {
            return Vec::new();
        };
        let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(&bytes) else {
            return Vec::new();
        };
        items.into_iter().filter_map(|v| serde_json::from_value::<CustomAgent>(v).ok()).collect()
    }

    pub fn save(agents: &[CustomAgent]) -> Result<(), String> {
        Self::save_to(&Self::file(), agents)
    }

    pub fn save_to(path: &Path, agents: &[CustomAgent]) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(agents).map_err(|e| e.to_string())?;
        crate::paths::write_atomic(path, &bytes).map_err(|e| e.to_string())
    }

    pub fn agent_for(profile_id: &str) -> Option<CustomAgent> {
        Self::agent_for_in(&Self::file(), profile_id)
    }

    pub fn agent_for_in(path: &Path, profile_id: &str) -> Option<CustomAgent> {
        Self::load_from(path).into_iter().find(|a| a.profile_id == profile_id)
    }

    pub fn upsert(agent: CustomAgent) -> Result<(), String> {
        Self::upsert_in(&Self::file(), agent)
    }

    pub fn upsert_in(path: &Path, agent: CustomAgent) -> Result<(), String> {
        let mut agents: Vec<CustomAgent> = Self::load_from(path).into_iter().filter(|a| a.profile_id != agent.profile_id).collect();
        agents.push(agent);
        Self::save_to(path, &agents)
    }

    pub fn remove(profile_id: &str) -> Result<(), String> {
        Self::remove_in(&Self::file(), profile_id)
    }

    pub fn remove_in(path: &Path, profile_id: &str) -> Result<(), String> {
        let agents: Vec<CustomAgent> = Self::load_from(path).into_iter().filter(|a| a.profile_id != profile_id).collect();
        Self::save_to(path, &agents)
    }

    /// Splits a typed command line (`"npx -y @kiro/acp@1.2.3 --acp"`) with shell-style quotes.
    /// Returns `None` when empty, when a quote is left open, or when it ends on a bare backslash.
    pub fn parse_command(line: &str) -> Option<(String, Vec<String>)> {
        let mut parts: Vec<String> = Vec::new();
        let mut current = String::new();
        let mut quote: Option<char> = None;
        let mut has_token = false;
        let mut escaped = false;
        for ch in line.chars() {
            if escaped {
                current.push(ch);
                escaped = false;
                has_token = true;
                continue;
            }
            if ch == '\\' && quote != Some('\'') {
                escaped = true;
                continue;
            }
            if let Some(open) = quote {
                if ch == open {
                    quote = None;
                } else {
                    current.push(ch);
                }
                continue;
            }
            if ch == '"' || ch == '\'' {
                quote = Some(ch);
                has_token = true;
                continue;
            }
            if ch.is_whitespace() {
                if has_token {
                    parts.push(std::mem::take(&mut current));
                    has_token = false;
                }
                continue;
            }
            current.push(ch);
            has_token = true;
        }
        if quote.is_some() || escaped {
            return None;
        }
        if has_token {
            parts.push(current);
        }
        let first = parts.first()?;
        if first.is_empty() {
            return None;
        }
        Some((first.clone(), parts[1..].to_vec()))
    }

    /// Valid POSIX shell variable name (`FOO_BAR`, up to 128 ASCII chars).
    pub fn is_environment_name(name: &str) -> bool {
        if name.is_empty() || name.len() > 128 {
            return false;
        }
        let mut bytes = name.bytes();
        let Some(first) = bytes.next() else {
            return false;
        };
        if !(first == b'_' || first.is_ascii_alphabetic()) {
            return false;
        }
        bytes.all(|b| b == b'_' || b.is_ascii_alphanumeric())
    }

    /// Quotes an argument safely for POSIX shells (`CustomAgents.quote`).
    pub fn quote(part: &str) -> String {
        if !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c)) {
            return part.to_string();
        }
        format!("'{}'", part.replace('\'', "'\\''"))
    }

    /// Resolves an executable name or path (`~` expanded) on the current platform, including `PATHEXT` on Windows.
    pub fn find_executable(program: &str) -> Option<String> {
        let trimmed = program.trim();
        if trimmed.is_empty() {
            return None;
        }
        let expanded = expand_tilde(trimmed);
        let direct = PathBuf::from(&expanded);
        if direct.components().count() > 1 || direct.is_absolute() {
            if direct.is_file() {
                return Some(direct.to_string_lossy().into_owned());
            }
            #[cfg(windows)]
            for ext in windows_pathext() {
                let candidate = PathBuf::from(format!("{expanded}{ext}"));
                if candidate.is_file() {
                    return Some(candidate.to_string_lossy().into_owned());
                }
            }
            return None;
        }
        let path_var = std::env::var_os("PATH")?;
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(&expanded);
            if candidate.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
            #[cfg(windows)]
            for ext in windows_pathext() {
                let with_ext = dir.join(format!("{expanded}{ext}"));
                if with_ext.is_file() {
                    return Some(with_ext.to_string_lossy().into_owned());
                }
            }
        }
        None
    }
}

fn expand_tilde(raw: &str) -> String {
    let Some(home) = dirs::home_dir() else {
        return raw.to_string();
    };
    if raw == "~" {
        return home.to_string_lossy().into_owned();
    }
    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        return home.join(rest).to_string_lossy().into_owned();
    }
    raw.to_string()
}

#[cfg(windows)]
fn windows_pathext() -> Vec<String> {
    std::env::var("PATHEXT")
        .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into())
        .split(';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

// MARK: ACP Registry (`agentclientprotocol.com`)

pub const REGISTRY_URL: &str = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
pub const REGISTRY_MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BinaryKind {
    Zip,
    Tar,
    Raw,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryBinary {
    pub archive: String,
    pub sha256: String,
    /// Relative to the unpacked folder (`"./bin/agent"`).
    pub command: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
}

impl RegistryBinary {
    pub fn kind(&self) -> BinaryKind {
        let path_part = self.archive.split('?').next().unwrap_or(&self.archive).to_lowercase();
        if path_part.ends_with(".zip") {
            return BinaryKind::Zip;
        }
        for ext in [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".tar"] {
            if path_part.ends_with(ext) {
                return BinaryKind::Tar;
            }
        }
        BinaryKind::Raw
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryEntry {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub website: Option<String>,
    /// How Nook starts it; `None` when the registry only offers a binary download.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    /// Download for this computer when there is no `npx` or `uvx` runner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<RegistryBinary>,
    /// Whether this computer can run or download this entry.
    #[serde(default)]
    pub supported: bool,
}

/// Update available for a registry-installed custom ACP agent (used by AG-21 & SV-04).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryUpdate {
    None,
    /// Its `npx` or `uvx` command at the newer version.
    Runner(CustomAgent),
    /// Newer binary download; caller runs `AcpInstaller::install` then `AcpRegistry::agent_from_installed`.
    Download(RegistryEntry),
}

pub struct AcpRegistry;

impl AcpRegistry {
    /// Registry platform key for `(os, arch)` (`std::env::consts` names).
    pub fn platform_for(os: &str, arch: &str) -> Option<&'static str> {
        match (os, arch) {
            ("macos", "aarch64") => Some("darwin-aarch64"),
            ("macos", "x86_64") => Some("darwin-x86_64"),
            ("windows", "x86_64") => Some("windows-x86_64"),
            ("windows", "aarch64") => Some("windows-aarch64"),
            ("linux", "x86_64") => Some("linux-x86_64"),
            ("linux", "aarch64") => Some("linux-aarch64"),
            _ => None,
        }
    }

    pub fn current_platform() -> Option<&'static str> {
        Self::platform_for(std::env::consts::OS, std::env::consts::ARCH)
    }

    /// Relative path inside an unpacked folder: no leading `/`, `~`, `\`, drive prefix, NUL, or `..` segments.
    pub fn is_safe_relative_path(path: &str) -> bool {
        if path.is_empty() || path.len() > 512 {
            return false;
        }
        if path.starts_with('/') || path.starts_with('~') || path.starts_with('\\') || path.contains('\0') {
            return false;
        }
        // Reject Windows drive letters like `C:...`
        if path.as_bytes().get(1) == Some(&b':') {
            return false;
        }
        !path.split(['/', '\\']).any(|seg| seg == "..")
    }

    pub fn parse(bytes: &[u8]) -> Vec<RegistryEntry> {
        Self::parse_for_platform(bytes, Self::current_platform())
    }

    pub fn parse_for_platform(bytes: &[u8], platform: Option<&str>) -> Vec<RegistryEntry> {
        if bytes.len() > REGISTRY_MAX_BYTES {
            return Vec::new();
        }
        let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
            return Vec::new();
        };
        let Some(Value::Array(agents)) = root.get("agents") else {
            return Vec::new();
        };
        agents.iter().take(512).filter_map(|raw| Self::parse_entry(raw, platform)).collect()
    }

    fn parse_entry(raw: &Value, platform: Option<&str>) -> Option<RegistryEntry> {
        let obj = raw.as_object()?;
        let id = obj.get("id")?.as_str()?;
        if !is_valid_agent_id(id) {
            return None;
        }
        let name = obj.get("name")?.as_str()?.trim();
        if name.is_empty() || name.chars().count() > 160 {
            return None;
        }
        let version = obj.get("version")?.as_str()?.trim();
        if version.is_empty() {
            return None;
        }
        let distribution = obj.get("distribution")?.as_object()?;
        let website = obj.get("website").and_then(Value::as_str).filter(|u| is_https(u)).map(str::to_string);
        let description: String = obj.get("description").and_then(Value::as_str).unwrap_or("").chars().take(1024).collect();

        let mut command = None;
        let mut arguments = Vec::new();
        let mut environment = BTreeMap::new();
        let mut binary = None;

        if let Some(npx) = distribution.get("npx").and_then(Value::as_object) {
            if let Some(pkg) = npx.get("package").and_then(Value::as_str).filter(|p| is_valid_npx_package(p)) {
                command = Some("npx".to_string());
                let mut args = vec!["-y".to_string(), pkg.to_string()];
                args.extend(parse_strings(npx.get("args")));
                arguments = args;
                environment = parse_environment(npx.get("env"));
            }
        }
        if command.is_none() {
            if let Some(uvx) = distribution.get("uvx").and_then(Value::as_object) {
                if let Some(pkg) = uvx.get("package").and_then(Value::as_str).filter(|p| is_valid_uvx_package(p)) {
                    command = Some("uvx".to_string());
                    let mut args = vec![pkg.to_string()];
                    args.extend(parse_strings(uvx.get("args")));
                    arguments = args;
                    environment = parse_environment(uvx.get("env"));
                }
            }
        }
        if command.is_none() {
            if let (Some(plat), Some(binaries)) = (platform, distribution.get("binary").and_then(Value::as_object)) {
                binary = binaries.get(plat).and_then(Self::parse_binary);
            }
        }

        let supported = command.is_some() || binary.is_some();
        Some(RegistryEntry {
            id: id.to_string(),
            name: name.to_string(),
            version: version.to_string(),
            description,
            website,
            command,
            arguments,
            environment,
            binary,
            supported,
        })
    }

    fn parse_binary(raw: &Value) -> Option<RegistryBinary> {
        let obj = raw.as_object()?;
        let archive = obj.get("archive")?.as_str()?;
        if !is_https(archive) {
            return None;
        }
        let sha = obj.get("sha256")?.as_str()?.to_lowercase();
        if sha.len() != 64 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let cmd = obj.get("cmd")?.as_str()?;
        if !Self::is_safe_relative_path(cmd) {
            return None;
        }
        Some(RegistryBinary {
            archive: archive.to_string(),
            sha256: sha,
            command: cmd.to_string(),
            arguments: parse_strings(obj.get("args")),
            environment: parse_environment(obj.get("env")),
        })
    }

    /// Converts an `npx`/`uvx` registry entry into a [`CustomAgent`] for `profile_id`.
    pub fn agent_from_entry(entry: &RegistryEntry, profile_id: &str) -> Option<CustomAgent> {
        let command = entry.command.as_ref()?.clone();
        Some(CustomAgent {
            profile_id: profile_id.to_string(),
            name: entry.name.clone(),
            registry_id: Some(entry.id.clone()),
            version: Some(entry.version.clone()),
            command,
            arguments: entry.arguments.clone(),
            environment: entry.environment.clone(),
            installed_at: None,
        })
    }

    /// Converts a downloaded & unpacked binary registry entry into a [`CustomAgent`] for `profile_id`.
    pub fn agent_from_installed(entry: &RegistryEntry, folder: &str, profile_id: &str) -> Option<CustomAgent> {
        let binary = entry.binary.as_ref()?;
        let relative = strip_dot_slash(&binary.command);
        let program = Path::new(folder).join(relative);
        Some(CustomAgent {
            profile_id: profile_id.to_string(),
            name: entry.name.clone(),
            registry_id: Some(entry.id.clone()),
            version: Some(entry.version.clone()),
            command: program.to_string_lossy().into_owned(),
            arguments: binary.arguments.clone(),
            environment: binary.environment.clone(),
            installed_at: Some(folder.to_string()),
        })
    }

    /// Checks whether a newer version of `agent` is available in `entries`.
    /// An agent keeps its distribution kind (download stays download; runner stays runner).
    pub fn update_for(agent: &CustomAgent, entries: &[RegistryEntry]) -> RegistryUpdate {
        let (Some(reg_id), Some(current)) = (&agent.registry_id, &agent.version) else {
            return RegistryUpdate::None;
        };
        let Some(entry) = entries.iter().find(|e| &e.id == reg_id) else {
            return RegistryUpdate::None;
        };
        if !Self::is_older(current, &entry.version) {
            return RegistryUpdate::None;
        }
        if agent.installed_at.is_some() {
            return if entry.command.is_none() && entry.binary.is_some() {
                RegistryUpdate::Download(entry.clone())
            } else {
                RegistryUpdate::None
            };
        }
        let Some(command) = entry.command.as_ref() else {
            return RegistryUpdate::None;
        };
        let mut updated = agent.clone();
        updated.version = Some(entry.version.clone());
        updated.command = command.clone();
        updated.arguments = entry.arguments.clone();
        updated.environment = entry.environment.clone();
        RegistryUpdate::Runner(updated)
    }

    /// Compares dotted version numbers (`"1.2.3"` < `"1.10.0"`), ignoring leading `"v"` and `"-prerelease"` suffixes.
    pub fn is_older(version: &str, other: &str) -> bool {
        fn numbers(text: &str) -> Vec<u64> {
            let plain = text.strip_prefix('v').unwrap_or(text);
            let core = plain.split('-').next().unwrap_or(plain);
            core.split('.')
                .map(|part| {
                    let digits: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
                    digits.parse::<u64>().unwrap_or(0)
                })
                .collect()
        }
        let a = numbers(version);
        let b = numbers(other);
        let len = a.len().max(b.len());
        for i in 0..len {
            let x = a.get(i).copied().unwrap_or(0);
            let y = b.get(i).copied().unwrap_or(0);
            if x != y {
                return x < y;
            }
        }
        false
    }

    /// Fetches and parses the ACP registry over HTTPS (30 s timeout, max 1 MB).
    pub async fn fetch() -> Result<Vec<RegistryEntry>, String> {
        let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().map_err(|e| e.to_string())?;
        let response = client.get(REGISTRY_URL).send().await.map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status().as_u16()));
        }
        let mut buf = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            if buf.len() + chunk.len() > REGISTRY_MAX_BYTES {
                return Err(tr("Het register is te groot.", "The registry is too large.").to_string());
            }
            buf.extend_from_slice(&chunk);
        }
        Ok(Self::parse(&buf))
    }
}

// MARK: ACP Binary Installer (`AcpInstaller` on the Mac)

pub const INSTALLER_MAX_BYTES: u64 = 1024 * 1024 * 1024;

pub struct AcpInstaller;

impl AcpInstaller {
    pub fn root() -> PathBuf {
        crate::paths::support_directory().join("acp-agents")
    }

    pub fn trash(root: &Path) -> PathBuf {
        root.join(".removing")
    }

    /// Downloads, verifies SHA-256, and unpacks a binary registry entry; returns its installed folder path.
    pub async fn install(entry: &RegistryEntry) -> Result<String, String> {
        Self::install_into(entry, &Self::root()).await
    }

    pub async fn install_into(entry: &RegistryEntry, root: &Path) -> Result<String, String> {
        let binary = entry.binary.as_ref().ok_or_else(|| {
            tr("Deze agent heeft geen download voor deze computer.", "This agent has no download for this computer.").to_string()
        })?;
        std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
        let download_path = root.join(format!(".download-{}", uuid::Uuid::new_v4()));
        let download_res = download_to_file(&binary.archive, &download_path).await;
        if let Err(err) = download_res {
            let _ = std::fs::remove_file(&download_path);
            return Err(err);
        }
        let dl = download_path.clone();
        let bin = binary.clone();
        let id = entry.id.clone();
        let version = entry.version.clone();
        let root_buf = root.to_path_buf();
        let placed = tokio::task::spawn_blocking(move || {
            let res = Self::place_downloaded(&dl, &bin, &id, &version, &root_buf);
            let _ = std::fs::remove_file(&dl);
            res
        })
        .await
        .map_err(|e| e.to_string())?;
        placed
    }

    /// Verifies size & SHA-256 of `file`, unpacks into a fresh staging folder, verifies the target binary stays inside
    /// staging, sets executable permissions on Unix, and atomically moves into `<root>/<id>/<safe_version>`.
    pub fn place_downloaded(file: &Path, binary: &RegistryBinary, id: &str, version: &str, root: &Path) -> Result<String, String> {
        let meta = std::fs::metadata(file).map_err(|e| e.to_string())?;
        let size = meta.len();
        if size == 0 || size > INSTALLER_MAX_BYTES {
            return Err(tr("De download is leeg of groter dan 1 GB.", "The download is empty or larger than 1 GB.").to_string());
        }
        let digest = sha256_file(file).map_err(|e| e.to_string())?;
        if digest != binary.sha256 {
            return Err(tr(
                "De download komt niet overeen met de controlesom uit het register: niet geïnstalleerd.",
                "The download does not match the registry's checksum: not installed.",
            )
            .to_string());
        }

        let safe_version: String = version.chars().map(|c| if matches!(c, '/' | '\\' | ':' | '\0') { '_' } else { c }).collect();
        let target = root.join(id).join(&safe_version);
        let staging = root.join(format!(".staging-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
        let result = (|| -> Result<String, String> {
            let relative = strip_dot_slash(&binary.command);
            match binary.kind() {
                BinaryKind::Zip => unpack_zip(file, &staging)?,
                BinaryKind::Tar => unpack_tar(file, &staging)?,
                BinaryKind::Raw => {
                    let dest = staging.join(relative);
                    if let Some(parent) = dest.parent() {
                        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                    }
                    std::fs::copy(file, &dest).map_err(|e| e.to_string())?;
                }
            }

            let program = staging.join(relative);
            let canonical_base = std::fs::canonicalize(&staging).map_err(|e| e.to_string())?;
            let canonical_program = std::fs::canonicalize(&program).map_err(|_| {
                tr("Het programma van de agent zit niet in de download.", "The agent's program is not in the download.").to_string()
            })?;
            if !canonical_program.starts_with(&canonical_base) || !canonical_program.is_file() {
                return Err(
                    tr("Het programma van de agent zit niet in de download.", "The agent's program is not in the download.").to_string()
                );
            }

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&canonical_program, std::fs::Permissions::from_mode(0o755));
            }

            if target.exists() {
                let _ = std::fs::remove_dir_all(&target);
            }
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            std::fs::rename(&staging, &target).map_err(|e| e.to_string())?;
            Ok(target.to_string_lossy().into_owned())
        })();

        if result.is_err() {
            let _ = std::fs::remove_dir_all(&staging);
        }
        result
    }

    /// Deletes a folder installed by this installer (and removes its parent agent folder once empty).
    pub fn uninstall(folder: &str) {
        Self::uninstall_in(folder, &Self::root());
    }

    pub fn uninstall_in(folder: &str, root: &Path) {
        let Ok(base) = std::fs::canonicalize(root) else { return };
        let Ok(path) = std::fs::canonicalize(folder) else { return };
        if !path.starts_with(&base) || path == base {
            return;
        }
        let _ = std::fs::remove_dir_all(&path);
        if let Some(parent) = path.parent() {
            if parent.starts_with(&base) && parent != base && std::fs::read_dir(parent).map(|mut it| it.next().is_none()).unwrap_or(false) {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }

    /// Returns installed version folders under `root` not referenced in `keeping`.
    pub fn stale_in(keeping: &[String], root: &Path) -> Vec<String> {
        let kept: HashSet<PathBuf> = keeping.iter().filter_map(|p| std::fs::canonicalize(p).ok()).collect();
        let mut stale = Vec::new();
        let Ok(agents) = std::fs::read_dir(root) else { return stale };
        for agent in agents.flatten() {
            let name = agent.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !agent.path().is_dir() {
                continue;
            }
            let Ok(versions) = std::fs::read_dir(agent.path()) else { continue };
            for ver in versions.flatten() {
                let vname = ver.file_name().to_string_lossy().into_owned();
                if vname.starts_with('.') {
                    continue;
                }
                let Ok(canon) = std::fs::canonicalize(ver.path()) else { continue };
                if !kept.contains(&canon) {
                    stale.push(ver.path().to_string_lossy().into_owned());
                }
            }
        }
        stale
    }

    /// Moves obsolete version folders into hidden `.removing` so background cleanup never races with a reinstall.
    pub fn set_aside_in(folders: &[String], root: &Path) {
        if folders.is_empty() {
            return;
        }
        let Ok(base) = std::fs::canonicalize(root) else { return };
        let trash = Self::trash(root);
        let _ = std::fs::create_dir_all(&trash);
        for folder in folders {
            let Ok(path) = std::fs::canonicalize(folder) else { continue };
            if !path.starts_with(&base) || path == base {
                continue;
            }
            let dest = trash.join(uuid::Uuid::new_v4().to_string());
            let _ = std::fs::rename(&path, &dest);
            if let Some(parent) = path.parent() {
                if parent.starts_with(&base)
                    && parent != base
                    && std::fs::read_dir(parent).map(|mut it| it.next().is_none()).unwrap_or(false)
                {
                    let _ = std::fs::remove_dir(parent);
                }
            }
        }
    }

    pub fn empty_trash_in(root: &Path) {
        let _ = std::fs::remove_dir_all(Self::trash(root));
    }
}

async fn download_to_file(url: &str, dest: &Path) -> Result<(), String> {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(120)).build().map_err(|e| e.to_string())?;
    let response = client.get(url).send().await.map_err(|e| e.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return Err(trf("Downloaden mislukt (HTTP {status}).", "Download failed (HTTP {status}).", &[("status", &status.as_u16())]));
    }
    let mut file = std::fs::File::create(dest).map_err(|e| e.to_string())?;
    let mut stream = response.bytes_stream();
    let mut total = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        total = total.saturating_add(chunk.len() as u64);
        if total > INSTALLER_MAX_BYTES {
            return Err(tr("De download is leeg of groter dan 1 GB.", "The download is empty or larger than 1 GB.").to_string());
        }
        file.write_all(&chunk).map_err(|e| e.to_string())?;
    }
    file.flush().map_err(|e| e.to_string())
}

fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn unpack_zip(archive: &Path, staging: &Path) -> Result<(), String> {
    let unpack_err =
        |detail: &dyn std::fmt::Display| trf("Uitpakken mislukt: {detail}", "Unpacking failed: {detail}", &[("detail", detail)]);
    let file = std::fs::File::open(archive).map_err(|e| unpack_err(&e))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| unpack_err(&e))?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| unpack_err(&e))?;
        let name = entry.name().map_err(|e| unpack_err(&e))?.to_string();
        if !AcpRegistry::is_safe_relative_path(&name) {
            return Err(unpack_err(&"unsafe archive path"));
        }
        let out_path = staging.join(&name);
        if entry.is_dir() {
            std::fs::create_dir_all(&out_path).map_err(|e| unpack_err(&e))?;
            continue;
        }
        if let Some(parent) = out_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| unpack_err(&e))?;
        }
        let mut out = std::fs::File::create(&out_path).map_err(|e| unpack_err(&e))?;
        std::io::copy(&mut entry, &mut out).map_err(|e| unpack_err(&e))?;
        #[cfg(unix)]
        if let Some(mode) = entry.unix_mode() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&out_path, std::fs::Permissions::from_mode(mode & 0o777));
        }
    }
    Ok(())
}

fn unpack_tar(archive: &Path, staging: &Path) -> Result<(), String> {
    let unpack_err =
        |detail: &dyn std::fmt::Display| trf("Uitpakken mislukt: {detail}", "Unpacking failed: {detail}", &[("detail", detail)]);
    let mut cmd = Command::new("tar");
    cmd.arg("-xf").arg(archive).arg("-C").arg(staging);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let output = cmd.output().map_err(|e| unpack_err(&e))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().chars().take(300).collect::<String>();
        return Err(unpack_err(&stderr));
    }
    Ok(())
}

// MARK: Validation helpers

fn strip_dot_slash(path: &str) -> &str {
    let mut cur = path;
    while let Some(rest) = cur.strip_prefix("./").or_else(|| cur.strip_prefix(".\\")) {
        cur = rest;
    }
    cur
}

fn is_https(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    !host.is_empty() && !host.chars().any(char::is_whitespace)
}

fn is_valid_agent_id(id: &str) -> bool {
    if id.is_empty() || id.len() > 128 {
        return false;
    }
    let mut bytes = id.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    if !first.is_ascii_lowercase() && !first.is_ascii_digit() {
        return false;
    }
    bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-'))
}

fn is_valid_runner_version(ver: &str) -> bool {
    let v = ver.strip_prefix('v').unwrap_or(ver);
    let (core, rest) = match v.split_once(['-', '+']) {
        Some((c, r)) => (c, Some(r)),
        None => (v, None),
    };
    let mut parts = core.split('.');
    let ok_core = matches!((parts.next(), parts.next(), parts.next(), parts.next()), (Some(a), Some(b), Some(c), None)
        if !a.is_empty() && a.bytes().all(|x| x.is_ascii_digit())
        && !b.is_empty() && b.bytes().all(|x| x.is_ascii_digit())
        && !c.is_empty() && c.bytes().all(|x| x.is_ascii_digit()));
    if !ok_core {
        return false;
    }
    if let Some(r) = rest {
        if r.is_empty() || !r.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'+')) {
            return false;
        }
    }
    true
}

fn is_valid_npx_package(pkg: &str) -> bool {
    let (name, ver) = if let Some(rest) = pkg.strip_prefix('@') {
        let Some((scope, after_scope)) = rest.split_once('/') else { return false };
        if scope.is_empty() || scope.chars().any(|c| c.is_whitespace() || c == '@' || c == '/') {
            return false;
        }
        let Some((n, v)) = after_scope.split_once('@') else { return false };
        if n.is_empty() || n.chars().any(|c| c.is_whitespace() || c == '@') {
            return false;
        }
        (n, v)
    } else {
        let Some((n, v)) = pkg.split_once('@') else { return false };
        let Some(first) = n.bytes().next() else { return false };
        if !first.is_ascii_alphanumeric() || !n.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) {
            return false;
        }
        (n, v)
    };
    let _ = name;
    is_valid_runner_version(ver)
}

fn is_valid_uvx_package(pkg: &str) -> bool {
    let (name, ver) = if let Some((n, v)) = pkg.split_once("==") {
        (n, v)
    } else if let Some((n, v)) = pkg.split_once('@') {
        (n, v)
    } else {
        return false;
    };
    let Some(first) = name.bytes().next() else { return false };
    if !first.is_ascii_alphanumeric() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) {
        return false;
    }
    is_valid_runner_version(ver)
}

fn parse_strings(val: Option<&Value>) -> Vec<String> {
    val.and_then(Value::as_array).map(|arr| arr.iter().take(64).filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default()
}

fn parse_environment(val: Option<&Value>) -> BTreeMap<String, String> {
    let Some(obj) = val.and_then(Value::as_object) else {
        return BTreeMap::new();
    };
    obj.iter()
        .take(64)
        .filter_map(|(k, v)| {
            if !CustomAgents::is_environment_name(k) {
                return None;
            }
            Some((k.clone(), v.as_str()?.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parse_command_splits_quotes_and_rejects_broken() {
        assert_eq!(
            CustomAgents::parse_command(r#"npx -y "@kiro/acp@1.2.3" --flag 'hello world'"#),
            Some(("npx".into(), vec!["-y".into(), "@kiro/acp@1.2.3".into(), "--flag".into(), "hello world".into()]))
        );
        assert_eq!(CustomAgents::parse_command("   "), None);
        assert_eq!(CustomAgents::parse_command(r#"npx "unclosed"#), None);
        assert_eq!(CustomAgents::parse_command(r#"npx trailing\"#), None);
    }

    #[test]
    fn environment_name_and_quoting() {
        assert!(CustomAgents::is_environment_name("FOO_BAR_1"));
        assert!(!CustomAgents::is_environment_name("1FOO"));
        assert!(!CustomAgents::is_environment_name("FOO-BAR"));
        assert_eq!(CustomAgents::quote("npx"), "npx");
        assert_eq!(CustomAgents::quote("a b"), "'a b'");
        assert_eq!(CustomAgents::quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn safe_relative_path_rejects_traversal_and_absolute() {
        assert!(AcpRegistry::is_safe_relative_path("./bin/agent"));
        assert!(AcpRegistry::is_safe_relative_path("agent.exe"));
        assert!(!AcpRegistry::is_safe_relative_path("/usr/bin/agent"));
        assert!(!AcpRegistry::is_safe_relative_path("~/agent"));
        assert!(!AcpRegistry::is_safe_relative_path("../escape"));
        assert!(!AcpRegistry::is_safe_relative_path("bin/../../escape"));
        assert!(!AcpRegistry::is_safe_relative_path("C:\\agent.exe"));
        assert!(!AcpRegistry::is_safe_relative_path(""));
    }

    #[test]
    fn registry_parses_npx_uvx_and_platform_binary() {
        let sha = "a".repeat(64);
        let json = serde_json::json!({
            "agents": [
                {
                    "id": "kiro",
                    "name": "Kiro",
                    "version": "1.2.3",
                    "description": "Kiro ACP",
                    "website": "https://kiro.dev",
                    "distribution": {
                        "npx": {
                            "package": "@kiro/acp@1.2.3",
                            "args": ["--acp"],
                            "env": { "KIRO_MODE": "1", "BAD-NAME": "ignored" }
                        }
                    }
                },
                {
                    "id": "pyagent",
                    "name": "PyAgent",
                    "version": "0.5.0",
                    "distribution": {
                        "uvx": { "package": "pyagent==0.5.0" }
                    }
                },
                {
                    "id": "native-bot",
                    "name": "Native Bot",
                    "version": "2.0.0",
                    "distribution": {
                        "binary": {
                            "windows-x86_64": {
                                "archive": "https://example.com/bot.zip",
                                "sha256": sha,
                                "cmd": "./bin/bot.exe",
                                "args": ["--stdio"]
                            }
                        }
                    }
                },
                {
                    "id": "unpinned",
                    "name": "Unpinned",
                    "version": "1.0.0",
                    "distribution": {
                        "npx": { "package": "@bad/pkg@latest" }
                    }
                }
            ]
        });
        let entries = AcpRegistry::parse_for_platform(json.to_string().as_bytes(), Some("windows-x86_64"));
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].command.as_deref(), Some("npx"));
        assert_eq!(entries[0].arguments, vec!["-y", "@kiro/acp@1.2.3", "--acp"]);
        assert_eq!(entries[0].environment.get("KIRO_MODE").map(String::as_str), Some("1"));
        assert!(!entries[0].environment.contains_key("BAD-NAME"));
        assert!(entries[0].supported);

        assert_eq!(entries[1].command.as_deref(), Some("uvx"));
        assert_eq!(entries[1].arguments, vec!["pyagent==0.5.0"]);
        assert!(entries[1].supported);

        assert!(entries[2].command.is_none());
        assert!(entries[2].binary.is_some());
        assert!(entries[2].supported);

        assert!(!entries[3].supported);
    }

    #[test]
    fn registry_version_comparison_and_updates() {
        assert!(AcpRegistry::is_older("1.2.3", "1.10.0"));
        assert!(AcpRegistry::is_older("v1.2.3-beta", "1.2.4"));
        assert!(!AcpRegistry::is_older("2.0.0", "1.9.9"));
        assert!(!AcpRegistry::is_older("1.2.3", "1.2.3"));

        let agent = CustomAgent {
            profile_id: "acp-kiro".into(),
            name: "Kiro".into(),
            registry_id: Some("kiro".into()),
            version: Some("1.0.0".into()),
            command: "npx".into(),
            arguments: vec!["-y".into(), "@kiro/acp@1.0.0".into()],
            environment: BTreeMap::new(),
            installed_at: None,
        };
        let entry = RegistryEntry {
            id: "kiro".into(),
            name: "Kiro".into(),
            version: "1.1.0".into(),
            description: String::new(),
            website: None,
            command: Some("npx".into()),
            arguments: vec!["-y".into(), "@kiro/acp@1.1.0".into()],
            environment: BTreeMap::new(),
            binary: None,
            supported: true,
        };
        match AcpRegistry::update_for(&agent, &[entry]) {
            RegistryUpdate::Runner(next) => {
                assert_eq!(next.version.as_deref(), Some("1.1.0"));
                assert_eq!(next.arguments, vec!["-y", "@kiro/acp@1.1.0"]);
            }
            other => panic!("expected Runner update, got {other:?}"),
        }
    }

    #[test]
    fn custom_agents_store_roundtrip_and_lossy_load() {
        let dir = std::env::temp_dir().join(format!("nook-custom-acp-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("custom-acp-agents.json");

        let a = CustomAgent {
            profile_id: "acp-kiro".into(),
            name: "Kiro".into(),
            registry_id: Some("kiro".into()),
            version: Some("1.0.0".into()),
            command: "npx".into(),
            arguments: vec!["-y".into(), "@kiro/acp@1.0.0".into()],
            environment: BTreeMap::new(),
            installed_at: None,
        };
        CustomAgents::upsert_in(&file, a.clone()).unwrap();
        assert_eq!(CustomAgents::agent_for_in(&file, "acp-kiro"), Some(a.clone()));

        // Inject a malformed entry beside a valid one: lossy load keeps the valid entry.
        let mixed = serde_json::json!([a, {"broken": true}]);
        std::fs::write(&file, mixed.to_string()).unwrap();
        assert_eq!(CustomAgents::load_from(&file).len(), 1);

        CustomAgents::remove_in(&file, "acp-kiro").unwrap();
        assert!(CustomAgents::load_from(&file).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn installer_verifies_checksum_unpacks_zip_and_cleans_up() {
        let dir = std::env::temp_dir().join(format!("nook-acp-inst-{}", uuid::Uuid::new_v4()));
        let root = dir.join("root");
        std::fs::create_dir_all(&root).unwrap();

        let zip_path = dir.join("agent.zip");
        {
            let f = std::fs::File::create(&zip_path).unwrap();
            let mut writer = zip::ZipWriter::new(f);
            writer.start_file("bin/my-agent", zip::write::SimpleFileOptions::default()).unwrap();
            writer.write_all(b"#!/bin/sh\necho ok\n").unwrap();
            writer.finish().unwrap();
        }
        let good_sha = sha256_file(&zip_path).unwrap();
        let bad_bin = RegistryBinary {
            archive: "https://example.com/agent.zip".into(),
            sha256: "0".repeat(64),
            command: "./bin/my-agent".into(),
            arguments: vec![],
            environment: BTreeMap::new(),
        };
        assert!(AcpInstaller::place_downloaded(&zip_path, &bad_bin, "demo", "1.0.0", &root).is_err());

        let good_bin = RegistryBinary { sha256: good_sha, ..bad_bin };
        let installed = AcpInstaller::place_downloaded(&zip_path, &good_bin, "demo", "1.0.0", &root).unwrap();
        assert!(Path::new(&installed).join("bin/my-agent").is_file());

        // Stale & trash cleanup
        let stale = AcpInstaller::stale_in(&[], &root);
        assert_eq!(stale.len(), 1);
        AcpInstaller::set_aside_in(&stale, &root);
        assert!(AcpInstaller::stale_in(&[], &root).is_empty());
        assert!(AcpInstaller::trash(&root).is_dir());
        AcpInstaller::empty_trash_in(&root);
        assert!(!AcpInstaller::trash(&root).exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
