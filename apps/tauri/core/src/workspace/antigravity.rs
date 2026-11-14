//! Antigravity over ACP (`Antigravity.swift` and `WorkspaceManager+Antigravity.swift` on the Mac): Google's
//! `agy_acp_server` with its `localharness_external` beside it, a profile folder per Nook account (`GEMINI_HOME`) with
//! file-based token storage, and Google sign-in through the server's own loopback port, opened in your browser.
//!
//! The Mac installs a pinned release of the server for macOS. There is no such release Nook can pin for Windows or
//! Linux yet, so here Nook uses a server you put in `<Nook's folder>/tools/antigravity-acp` (or on your `PATH`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::driver::is_program;
use super::models::{ExecutionMode, PermissionPolicy};
use crate::i18n::trf;

/// The line the server prints when it wants you to sign in.
pub const SIGN_IN_PREFIX: &str = "Open the following link to authenticate the ACP server: ";
pub const AUTH_METHOD: &str = "oauth-personal";

/// Variables that would steer the server to another account or project: never passed on.
pub const REMOVED_ENVIRONMENT: &[&str] = &[
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_CLOUD_LOCATION",
    "GOOGLE_CLOUD_QUOTA_PROJECT",
    "GOOGLE_GENAI_USE_VERTEXAI",
    "GCLOUD_PROJECT",
    "CLOUDSDK_CORE_PROJECT",
    "AGY_ACP_CCPA_PROJECT",
    "AGY_ACP_ENABLE_OAUTH",
    "GEMINI_HOME",
    "AGY_ACP_FORCE_FILE_STORAGE",
    "ANTIGRAVITY_HARNESS_PATH",
    "BROWSER",
    "PYTHONUNBUFFERED",
    "ELECTRON_RUN_AS_NODE",
];

/// `<GEMINI_HOME>/antigravity-acp/settings.json`: sign in with a personal Google account.
pub const PROFILE_SETTINGS: &str = r#"{"auth":{"type":"oauth-personal"}}"#;

const SERVER_NAMES: &[&str] = &["agy_acp_server", "agy_acp_server.par", "agy-acp-server"];
const HARNESS: &str = "localharness_external";

/// Where Nook keeps Antigravity's server and profiles.
pub struct Paths {
    pub support: PathBuf,
}

impl Paths {
    pub fn current() -> Self {
        let overridden = SUPPORT_OVERRIDE.lock().unwrap_or_else(|e| e.into_inner()).clone();
        Self { support: overridden.unwrap_or_else(crate::paths::support_directory) }
    }

    pub fn tools(&self) -> PathBuf {
        self.support.join("tools").join("antigravity-acp")
    }

    /// One profile folder per Nook account, so each signs in on its own.
    pub fn profile(&self, profile_id: &str) -> PathBuf {
        let safe: String = profile_id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
        self.support.join("providers").join("antigravity").join(if safe.is_empty() { "default".into() } else { safe })
    }

    pub fn browser_helper(&self) -> PathBuf {
        self.tools().join(if cfg!(windows) { "open-sign-in.cmd" } else { "open-sign-in.sh" })
    }

    pub fn temp(&self) -> PathBuf {
        self.tools().join("tmp")
    }
}

/// For tests: Nook's folder somewhere else.
pub static SUPPORT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

fn names() -> Vec<String> {
    SERVER_NAMES.iter().flat_map(|n| if cfg!(windows) { vec![format!("{n}.exe"), n.to_string()] } else { vec![n.to_string()] }).collect()
}

fn is_server(path: &Path) -> bool {
    let name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    names().iter().any(|n| *n == name) && is_program(path)
}

/// The ACP server: the program Nook found when it is the server itself, else one in Nook's tools folder (any release
/// folder below it), next to the program Nook found, or on your `PATH`.
pub fn server(found: &str) -> Option<String> {
    let found = Path::new(found);
    if is_server(found) {
        return Some(found.to_string_lossy().into_owned());
    }
    let mut dirs: Vec<PathBuf> = vec![];
    let tools = Paths::current().tools();
    collect_dirs(&tools, 3, &mut dirs);
    if let Some(parent) = found.parent() {
        dirs.push(parent.to_path_buf());
    }
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.iter().flat_map(|d| names().into_iter().map(move |n| d.join(n))).find(|p| is_server(p)).map(|p| p.to_string_lossy().into_owned())
}

fn collect_dirs(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if !dir.is_dir() {
        return;
    }
    out.push(dir.to_path_buf());
    if depth == 0 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut children: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
    children.sort();
    for child in children {
        collect_dirs(&child, depth - 1, out);
    }
}

pub fn not_installed() -> String {
    trf(
        "Antigravity's ACP-server staat niet op deze computer. Zet agy_acp_server (met localharness_external ernaast) in {folder} of in je PATH.",
        "Antigravity's ACP server isn't on this computer. Put agy_acp_server (with localharness_external beside it) in {folder} or on your PATH.",
        &[("folder", &crate::agents::tilde(&Paths::current().tools().to_string_lossy()))],
    )
}

/// Makes the account's profile folder (private), its settings and the sign-in helper; the environment to launch with.
/// An account environment that names its own `GEMINI_HOME` keeps it as the profile folder.
pub fn prepare(profile_id: &str, server: &str, account: &BTreeMap<String, String>) -> Result<BTreeMap<String, String>, String> {
    let paths = Paths::current();
    let profile = account.get("GEMINI_HOME").filter(|h| !h.is_empty()).map(PathBuf::from).unwrap_or_else(|| paths.profile(profile_id));
    let settings = profile.join("antigravity-acp");
    let failed = |e: std::io::Error| trf("Antigravity klaarzetten lukte niet: {error}", "Couldn't prepare Antigravity: {error}", &[("error", &e)]);
    std::fs::create_dir_all(&settings).map_err(failed)?;
    crate::paths::restrict(&profile, 0o700);
    let file = settings.join("settings.json");
    if !file.exists() {
        std::fs::write(&file, PROFILE_SETTINGS).map_err(failed)?;
    }
    std::fs::create_dir_all(paths.temp()).map_err(failed)?;
    // The server calls BROWSER for its sign-in page; Nook opens that page itself once it checked the address.
    let helper = paths.browser_helper();
    std::fs::write(&helper, if cfg!(windows) { "@exit /b 0\r\n" } else { "#!/bin/sh\n# Nook opens Google's sign-in page itself.\nexit 0\n" })
        .map_err(failed)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755));
    }
    let temp = paths.temp().to_string_lossy().into_owned();
    let mut env: BTreeMap<String, String> = [
        ("GEMINI_HOME", profile.to_string_lossy().into_owned()),
        ("AGY_ACP_FORCE_FILE_STORAGE", "1".into()),
        // Python reads BROWSER as a command line: the quoted helper, then the address.
        ("BROWSER", format!("\"{}\" %s", helper.to_string_lossy().replace('"', ""))),
        ("PYTHONUNBUFFERED", "1".into()),
        ("TMPDIR", temp.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    if cfg!(windows) {
        env.insert("TEMP".into(), temp.clone());
        env.insert("TMP".into(), temp);
    }
    let harness = Path::new(server).parent().map(|p| p.join(HARNESS)).filter(|h| h.exists());
    if let Some(h) = harness {
        env.insert("ANTIGRAVITY_HARNESS_PATH".into(), h.to_string_lossy().into_owned());
    }
    Ok(env)
}

/// The mode for the session's rights.
pub fn mode(mode: ExecutionMode, permission: PermissionPolicy) -> &'static str {
    if mode == ExecutionMode::Plan {
        return "plan";
    }
    match permission {
        PermissionPolicy::Bypass => "yolo",
        PermissionPolicy::AcceptEdits => "auto_edit",
        PermissionPolicy::Ask => "default",
    }
}

/// The server sometimes ends a turn with `end_turn` before the model wrote a word: Nook asks it to carry on, at most
/// this often per message of yours.
pub const MAX_CONTINUATIONS: usize = 2;

pub fn should_continue(reason: &str, replied: bool, stopping: bool, continuations: usize) -> bool {
    reason == "end_turn" && !replied && !stopping && continuations < MAX_CONTINUATIONS
}

/// The prompt that asks the model to finish what it started and report back.
pub fn continuation(tool_calls: usize) -> String {
    if tool_calls > 0 {
        let plural = if tool_calls == 1 { "" } else { "s" };
        return format!(
            "You ran {tool_calls} tool call{plural} but stopped without replying. Summarize what you did, then continue with the task until it is done, and end with a short reply to the user."
        );
    }
    "You stopped without replying. Answer the previous message from the user now.".into()
}

/// The sign-in address in a line of the server's output, when it is a real Google sign-in page that returns to the
/// server's own loopback port.
pub fn sign_in_url(line: &str) -> Option<String> {
    let at = line.find(SIGN_IN_PREFIX)?;
    valid_sign_in_url(line[at + SIGN_IN_PREFIX.len()..].trim())
}

pub fn valid_sign_in_url(text: &str) -> Option<String> {
    if text.len() > 16_384 || text.chars().any(char::is_whitespace) {
        return None;
    }
    let url = url::Url::parse(text).ok()?;
    if url.scheme() != "https"
        || url.host_str() != Some("accounts.google.com")
        || url.path() != "/o/oauth2/v2/auth"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let values = |name: &str| url.query_pairs().filter(|(k, _)| k == name).map(|(_, v)| v.into_owned()).collect::<Vec<_>>();
    let state = values("state");
    if state.len() != 1 || state[0].is_empty() || state[0].len() > 512 || values("response_type") != ["code"] {
        return None;
    }
    let redirect = values("redirect_uri");
    let [redirect] = redirect.as_slice() else { return None };
    let back = url::Url::parse(redirect).ok()?;
    if back.scheme() != "http" || back.host_str() != Some("127.0.0.1") || back.path() != "/" || back.port().is_none_or(|p| p < 1024) {
        return None;
    }
    Some(url.to_string())
}

/// Opens Google's sign-in page in your browser (only an address [`valid_sign_in_url`] let through).
pub fn open_sign_in(url: &str) {
    if cfg!(test) || valid_sign_in_url(url).is_none() {
        return;
    }
    #[cfg(windows)]
    let mut cmd = {
        let mut c = std::process::Command::new("rundll32");
        c.args(["url.dll,FileProtocolHandler", url]);
        c
    };
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(url);
        c
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(url);
        c
    };
    let _ = cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_in_addresses() {
        let good = "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&state=abc&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2F";
        assert!(sign_in_url(&format!("{SIGN_IN_PREFIX}{good}")).is_some());
        assert!(valid_sign_in_url(&good.replace("accounts.google.com", "evil.example")).is_none());
        assert!(valid_sign_in_url(&good.replace("127.0.0.1", "example.com")).is_none());
        assert!(valid_sign_in_url(&good.replace("response_type=code", "response_type=token")).is_none());
        assert!(valid_sign_in_url(&good.replace("50123", "80")).is_none());
        assert!(sign_in_url("Starting server").is_none());
    }

    #[test]
    fn modes_and_continuation() {
        assert_eq!(mode(ExecutionMode::Plan, PermissionPolicy::Bypass), "plan");
        assert_eq!(mode(ExecutionMode::Agent, PermissionPolicy::Bypass), "yolo");
        assert_eq!(mode(ExecutionMode::Agent, PermissionPolicy::AcceptEdits), "auto_edit");
        assert_eq!(mode(ExecutionMode::Agent, PermissionPolicy::Ask), "default");
        assert!(should_continue("end_turn", false, false, 1));
        assert!(!should_continue("end_turn", false, false, MAX_CONTINUATIONS));
        assert!(!should_continue("end_turn", true, false, 0));
        assert!(!should_continue("cancelled", false, false, 0));
        assert!(continuation(2).contains("2 tool calls"));
        assert!(continuation(1).contains("1 tool call but"));
    }

    #[test]
    fn profile_folders() {
        let p = Paths { support: PathBuf::from("/s") };
        assert_eq!(p.profile("a/b"), PathBuf::from("/s/providers/antigravity/a_b"));
        assert_eq!(p.profile(""), PathBuf::from("/s/providers/antigravity/default"));
    }
}
