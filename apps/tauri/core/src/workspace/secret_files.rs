//! Temporary owner-only files that hold secrets a user hands to an agent (`SecretFiles.swift` on the Mac).
//!
//! Secrets passed via `request_secret` default to file delivery so the value never enters the model's conversation
//! history: the agent gets only the file path and reads it directly in its own shell. On Unix, directories are `0o700`
//! and files are `0o600` (with symlink and ownership checks). On Windows, `icacls` strips inherited permissions and
//! grants access only to the current user. Files expire automatically after 24 hours via [`SecretFiles::sweep`].

use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

/// How long a secret file stays on disk before [`SecretFiles::sweep`] removes it.
pub const LIFETIME: Duration = Duration::from_secs(24 * 60 * 60);

/// Scope used when the user hands a secret from the composer rather than a session.
pub const COMPOSER_SCOPE: &str = "composer";

/// Maximum length of a secret name (e.g. `OPENAI_API_KEY`).
pub const MAX_NAME_LEN: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretFileError {
    InvalidName(String),
    UnsafePath(String),
    Io(String),
}

impl fmt::Display for SecretFileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidName(name) => write!(f, "Invalid secret name: {name}"),
            Self::UnsafePath(msg) => write!(f, "Refused unsafe secret path: {msg}"),
            Self::Io(msg) => write!(f, "Could not write secret file: {msg}"),
        }
    }
}

impl std::error::Error for SecretFileError {}

/// Where temporary secret files live on disk.
#[derive(Debug, Clone)]
pub struct SecretFiles {
    pub root: PathBuf,
}

impl SecretFiles {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The standard folder inside Nook's support directory (`agent-secrets`).
    pub fn standard() -> Self {
        Self::new(crate::paths::support_directory().join("agent-secrets"))
    }

    /// Safe folder name for a session or scope: up to 80 ASCII alphanumeric, `-` or `_` characters.
    pub fn scope(raw: &str) -> String {
        let mut out = String::new();
        for ch in raw.chars().take(80) {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                out.push(ch);
            } else {
                out.push('_');
            }
        }
        if out.is_empty() || out.chars().all(|c| c == '_') {
            "_".into()
        } else {
            out
        }
    }

    /// Deterministic scope for a workspace directory when the caller is not a Nook-managed session
    /// (64-bit FNV-1a, matching `SecretFiles.folderScope` on the Mac).
    pub fn folder_scope(directory: &str) -> String {
        let mut hash: u64 = 0xcbf29ce484222325;
        for byte in directory.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("folder-{hash:x}")
    }

    /// Valid secret name: 1..=64 ASCII characters, no leading dot, no `..`, only letters, digits, `.`, `_`, `-`.
    pub fn is_valid_name(name: &str) -> bool {
        let len = name.len();
        (1..=MAX_NAME_LEN).contains(&len)
            && !name.starts_with('.')
            && !name.contains("..")
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    }

    /// Writes `value` (exact UTF-8 bytes, no trailing newline) to `<root>/<scope>/<name>` with owner-only
    /// permissions, replacing any previous file atomically.
    pub fn write(&self, value: &str, name: &str, scope: &str) -> Result<PathBuf, SecretFileError> {
        if !Self::is_valid_name(name) {
            return Err(SecretFileError::InvalidName(name.into()));
        }
        ensure_private_dir(&self.root)?;
        let scope_dir = self.root.join(Self::scope(scope));
        ensure_private_dir(&scope_dir)?;

        let final_path = scope_dir.join(name);
        if is_symlink(&final_path) {
            return Err(SecretFileError::UnsafePath("target file is a symbolic link".into()));
        }

        let partial = scope_dir.join(format!("{name}.partial"));
        if partial.symlink_metadata().is_ok() {
            let _ = fs::remove_file(&partial);
        }

        write_private_file(&partial, value.as_bytes())?;
        if let Err(e) = fs::rename(&partial, &final_path) {
            let _ = fs::remove_file(&partial);
            return Err(SecretFileError::Io(e.to_string()));
        }
        enforce_private_file(&final_path)?;
        Ok(final_path)
    }

    /// Removes all secret files for a single scope.
    pub fn remove(&self, scope: &str) {
        let dir = self.root.join(Self::scope(scope));
        if is_symlink(&dir) {
            let _ = fs::remove_file(&dir);
            return;
        }
        let _ = fs::remove_dir_all(&dir);
    }

    /// Removes the entire secret-file root directory.
    pub fn remove_all(&self) {
        if is_symlink(&self.root) {
            let _ = fs::remove_file(&self.root);
            return;
        }
        let _ = fs::remove_dir_all(&self.root);
    }

    /// Removes secret files older than [`LIFETIME`] and any now-empty scope directories.
    /// Returns the earliest expiry timestamp of the remaining files, if any.
    pub fn sweep(&self, now: SystemTime) -> Option<SystemTime> {
        let entries = fs::read_dir(&self.root).ok()?;
        let mut next_expiry: Option<SystemTime> = None;

        for scope_entry in entries.flatten() {
            let scope_path = scope_entry.path();
            if is_symlink(&scope_path) {
                let _ = fs::remove_file(&scope_path);
                continue;
            }
            let Ok(meta) = scope_path.symlink_metadata() else { continue };
            if !meta.is_dir() {
                let _ = fs::remove_file(&scope_path);
                continue;
            }
            let Ok(files) = fs::read_dir(&scope_path) else { continue };
            let mut remaining = 0usize;
            for file_entry in files.flatten() {
                let path = file_entry.path();
                if is_symlink(&path) {
                    let _ = fs::remove_file(&path);
                    continue;
                }
                let modified = path.symlink_metadata().ok().and_then(|m| m.modified().ok());
                let expired = match modified {
                    Some(ts) => now.duration_since(ts).is_ok_and(|age| age >= LIFETIME),
                    None => true,
                };
                if expired {
                    let _ = fs::remove_file(&path);
                } else {
                    remaining += 1;
                    if let Some(ts) = modified {
                        let exp = ts + LIFETIME;
                        next_expiry = Some(match next_expiry {
                            Some(cur) if cur <= exp => cur,
                            _ => exp,
                        });
                    }
                }
            }
            if remaining == 0 {
                let _ = fs::remove_dir(&scope_path);
            }
        }
        next_expiry
    }

    /// Instructions returned to the agent for a file-delivered secret: path only, never the value.
    pub fn instructions(name: &str, path: &Path) -> String {
        let shown = path.to_string_lossy();
        let posix_quoted = shown.replace('\'', "'\\''");
        let ps_quoted = shown.replace('\'', "''");
        format!(
            "The user provided {name} in a private owner-only file at:\n{shown}\n\n\
             Read it directly in your shell without printing it, for example:\n\
             - sh/bash/zsh: {name}=\"$(cat '{posix_quoted}')\"\n\
             - PowerShell:  $env:{name} = Get-Content -Raw -LiteralPath '{ps_quoted}'\n\n\
             Never echo, log, commit, or paste the secret value into files or your replies. \
             Nook deletes this file automatically after 24 hours."
        )
    }
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

fn ensure_private_dir(dir: &Path) -> Result<(), SecretFileError> {
    if is_symlink(dir) {
        return Err(SecretFileError::UnsafePath(format!("{} is a symbolic link", dir.display())));
    }
    if !dir.exists() {
        fs::create_dir_all(dir).map_err(|e| SecretFileError::Io(e.to_string()))?;
    }
    let meta = fs::symlink_metadata(dir).map_err(|e| SecretFileError::Io(e.to_string()))?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(SecretFileError::UnsafePath(format!("{} is not a real directory", dir.display())));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let my_uid = unsafe { libc_geteuid() };
        if meta.uid() != my_uid {
            return Err(SecretFileError::UnsafePath(format!("{} is owned by another user", dir.display())));
        }
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).map_err(|e| SecretFileError::Io(e.to_string()))?;
    }
    #[cfg(windows)]
    {
        apply_windows_user_only_acl(dir, true)?;
    }
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), SecretFileError> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut file = opts.open(path).map_err(|e| SecretFileError::Io(e.to_string()))?;
    file.write_all(bytes).map_err(|e| SecretFileError::Io(e.to_string()))?;
    file.sync_all().map_err(|e| SecretFileError::Io(e.to_string()))?;
    drop(file);
    enforce_private_file(path)?;
    Ok(())
}

fn enforce_private_file(path: &Path) -> Result<(), SecretFileError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|e| SecretFileError::Io(e.to_string()))?;
    }
    #[cfg(windows)]
    {
        apply_windows_user_only_acl(path, false)?;
    }
    Ok(())
}

#[cfg(unix)]
unsafe fn libc_geteuid() -> u32 {
    extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}

#[cfg(windows)]
fn apply_windows_user_only_acl(path: &Path, is_dir: bool) -> Result<(), SecretFileError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let user = std::env::var("USERNAME").unwrap_or_default();
    if user.trim().is_empty() {
        return Err(SecretFileError::Io("USERNAME environment variable is missing".into()));
    }
    let principal = match std::env::var("USERDOMAIN") {
        Ok(domain) if !domain.trim().is_empty() => format!("{domain}\\{user}"),
        _ => user,
    };
    let grant = if is_dir { format!("{principal}:(OI)(CI)F") } else { format!("{principal}:F") };
    let status = Command::new("icacls")
        .arg(path)
        .args(["/inheritance:r", "/grant:r", &grant, "/Q"])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map_err(|e| SecretFileError::Io(format!("icacls failed to start: {e}")))?;
    if !status.success() {
        return Err(SecretFileError::Io(format!("icacls exited with status {status}")));
    }
    Ok(())
}

// MARK: request_secret argument parsing & formatting

/// How `request_secret` hands the secret to the calling agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecretDelivery {
    /// Owner-only temporary file (default): the value stays out of the model's conversation history.
    File,
    /// Returned inline in the tool response (only when the agent truly needs the literal value).
    Value,
}

/// Validates the secret `name` argument (1..=64 ASCII chars, `A-Za-z0-9._-`, no leading `.`, no `..`).
pub fn validate_secret_name(raw: Option<&str>) -> Result<String, String> {
    let name = raw.map(str::trim).unwrap_or("");
    if name.is_empty() {
        return Err("Give the secret a short name, such as OPENAI_API_KEY or NPM_TOKEN.".into());
    }
    if !SecretFiles::is_valid_name(name) {
        return Err(format!(
            "Secret name \"{name}\" must be 1-{MAX_NAME_LEN} ASCII letters, digits, dots, dashes or underscores, without leading dots or \"..\"."
        ));
    }
    Ok(name.into())
}

/// Parses the optional `delivery` argument (`"file"` default, or `"value"`).
pub fn parse_delivery(raw: Option<&Value>) -> Result<SecretDelivery, String> {
    let Some(s) = raw.and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(SecretDelivery::File);
    };
    match s.to_ascii_lowercase().as_str() {
        "file" => Ok(SecretDelivery::File),
        "value" => Ok(SecretDelivery::Value),
        _ => Err("delivery must be \"file\" (default) or \"value\".".into()),
    }
}

/// Validates an optional `sign_in_url` (only `https://` URLs with a non-empty host are accepted).
pub fn sign_in_url(raw: Option<&str>) -> Option<String> {
    let text = raw.map(str::trim).filter(|s| !s.is_empty())?;
    let parsed = url::Url::parse(text).ok()?;
    if parsed.scheme() != "https" || parsed.host_str().is_none_or(str::is_empty) {
        return None;
    }
    Some(parsed.to_string())
}

/// Account key used in Nook's [`crate::secrets::SecretStore`] for a remembered agent secret.
pub fn secret_account(name: &str) -> String {
    format!("agent-secret.{name}")
}

/// Builds the approval card detail text shown to the user: line 1 is the secret name, followed by the reason
/// and optional sign-in URL.
pub fn secret_detail(name: &str, reason: &str, sign_in: Option<&str>) -> String {
    let mut parts = vec![name.to_string()];
    let r = reason.trim();
    if !r.is_empty() {
        parts.push(r.to_string());
    }
    if let Some(url) = sign_in {
        parts.push(url.to_string());
    }
    parts.join("\n\n")
}

/// Wraps an inline (`delivery: "value"`) secret with explicit handling instructions.
pub fn secret_envelope(name: &str, value: &str) -> String {
    format!(
        "The user approved sharing {name} directly:\n\n{value}\n\n\
         Use this value only for the requested task. Never echo, log, commit, or repeat it in your replies."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-secret-files-{label}-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn names_and_scopes() {
        assert!(SecretFiles::is_valid_name("OPENAI_API_KEY"));
        assert!(SecretFiles::is_valid_name("npm.token-1"));
        assert!(!SecretFiles::is_valid_name(""));
        assert!(!SecretFiles::is_valid_name(".hidden"));
        assert!(!SecretFiles::is_valid_name("a..b"));
        assert!(!SecretFiles::is_valid_name("a/b"));
        assert!(!SecretFiles::is_valid_name("with space"));
        assert!(!SecretFiles::is_valid_name(&"a".repeat(65)));

        assert_eq!(SecretFiles::scope("run:abc-123"), "run_abc-123");
        assert_eq!(SecretFiles::scope(""), "_");
        assert_eq!(SecretFiles::scope("///"), "_");
        assert_eq!(SecretFiles::scope(&"x".repeat(120)).len(), 80);

        let f1 = SecretFiles::folder_scope("/Users/test/repo");
        let f2 = SecretFiles::folder_scope("/Users/test/repo");
        let f3 = SecretFiles::folder_scope("/Users/test/other");
        assert!(f1.starts_with("folder-"));
        assert_eq!(f1, f2);
        assert_ne!(f1, f3);
    }

    #[test]
    fn write_permissions_and_overwrite() {
        let root = temp_dir("write");
        let store = SecretFiles::new(root.join("secrets"));
        let path = store.write("s3cr3t-value", "API_TOKEN", "run:1").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "s3cr3t-value");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let file_mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            let dir_mode = fs::metadata(path.parent().unwrap()).unwrap().permissions().mode() & 0o777;
            let root_mode = fs::metadata(&store.root).unwrap().permissions().mode() & 0o777;
            assert_eq!(file_mode, 0o600);
            assert_eq!(dir_mode, 0o700);
            assert_eq!(root_mode, 0o700);
        }

        // Overwriting replaces atomically without trailing newline.
        let path2 = store.write("updated", "API_TOKEN", "run:1").unwrap();
        assert_eq!(path, path2);
        assert_eq!(fs::read_to_string(&path2).unwrap(), "updated");

        // Invalid names are rejected before touching disk.
        assert!(matches!(store.write("x", "../evil", "run:1"), Err(SecretFileError::InvalidName(_))));

        store.remove("run:1");
        assert!(!path.exists());
        store.remove_all();
        assert!(!store.root.exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlink_targets() {
        use std::os::unix::fs::symlink;
        let root = temp_dir("symlink");
        let decoy = root.join("decoy");
        fs::create_dir_all(&decoy).unwrap();
        let link_root = root.join("link-root");
        symlink(&decoy, &link_root).unwrap();

        let store = SecretFiles::new(&link_root);
        assert!(matches!(store.write("abc", "TOKEN", "s1"), Err(SecretFileError::UnsafePath(_))));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sweep_removes_expired_and_keeps_fresh() {
        let root = temp_dir("sweep");
        let store = SecretFiles::new(root.join("secrets"));
        let path = store.write("fresh-val", "FRESH_KEY", "scope-a").unwrap();
        let now = SystemTime::now();

        // Not expired yet -> kept, returns next expiry ~24h from now.
        let next = store.sweep(now);
        assert!(path.exists());
        assert!(next.is_some());

        // Simulated 25h later -> expired file and its empty scope folder are removed.
        let later = now + Duration::from_secs(25 * 60 * 60);
        let after = store.sweep(later);
        assert!(!path.exists());
        assert!(!path.parent().unwrap().exists());
        assert!(after.is_none());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn secret_argument_helpers() {
        assert_eq!(validate_secret_name(Some("  STRIPE_KEY ")).unwrap(), "STRIPE_KEY");
        assert!(validate_secret_name(None).is_err());
        assert!(validate_secret_name(Some("../bad")).is_err());

        assert_eq!(parse_delivery(None).unwrap(), SecretDelivery::File);
        assert_eq!(parse_delivery(Some(&json!("file"))).unwrap(), SecretDelivery::File);
        assert_eq!(parse_delivery(Some(&json!("VALUE"))).unwrap(), SecretDelivery::Value);
        assert!(parse_delivery(Some(&json!("env"))).is_err());

        assert_eq!(sign_in_url(Some("https://dashboard.stripe.com/apikeys")).as_deref(), Some("https://dashboard.stripe.com/apikeys"));
        assert!(sign_in_url(Some("http://example.com")).is_none());
        assert!(sign_in_url(Some("javascript:alert(1)")).is_none());
        assert!(sign_in_url(Some("")).is_none());

        assert_eq!(secret_account("STRIPE_KEY"), "agent-secret.STRIPE_KEY");
        let detail = secret_detail("STRIPE_KEY", "Run Stripe integration tests", Some("https://stripe.com"));
        assert!(detail.starts_with("STRIPE_KEY\n\nRun Stripe integration tests\n\nhttps://stripe.com"));
        let env = secret_envelope("STRIPE_KEY", "sk_test_123");
        assert!(env.contains("sk_test_123") && env.contains("Never echo"));
        let instr = SecretFiles::instructions("STRIPE_KEY", Path::new("/tmp/s/STRIPE_KEY"));
        assert!(instr.contains("/tmp/s/STRIPE_KEY") && !instr.contains("sk_test_123"));
    }
}
