//! Updating a coding agent's command-line program (`AgentUpdates`, `AgentUpdater` on the Mac). The program is updated
//! by whatever installed it: a global npm/pnpm/Bun/Volta install, Scoop, Homebrew, mise, or the agent's own updater
//! (`claude update`). Which one is read from where the program really lives, never guessed from the agent alone:
//! `npm install -g` over another install leaves two copies, and the older one may stay first on PATH.
//!
//! Also here: reading a turn the API refused because the agent is too old for the model (`AgentVersionRejection`), so
//! the failed turn can offer the update.

use std::cmp::Ordering;
use std::path::Path;

use serde::Serialize;

use super::AgentKind;

/// What installed an agent's program, and so what updates it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum InstallOwner {
    Homebrew { brew: String, name: String, cask: bool },
    Npm { npm: String, package: String },
    Pnpm { package: String },
    Bun { bun: String, package: String },
    Volta { package: String },
    Scoop { name: String },
    Mise { tool: String },
    /// The agent updates itself (`claude update`, `opencode upgrade`).
    SelfUpdate { arguments: Vec<String> },
    /// Nook cannot tell; you update it the way you installed it.
    Unknown,
}

impl InstallOwner {
    /// The installer's name as Settings shows it.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Homebrew { .. } => "Homebrew",
            Self::Npm { .. } => "npm",
            Self::Pnpm { .. } => "pnpm",
            Self::Bun { .. } => "Bun",
            Self::Volta { .. } => "Volta",
            Self::Scoop { .. } => "Scoop",
            Self::Mise { .. } => "mise",
            Self::SelfUpdate { .. } => "self",
            Self::Unknown => "?",
        }
    }
}

/// A command Nook runs to update an agent: a program and its arguments, never a shell line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UpdateCommand {
    pub executable: String,
    pub arguments: Vec<String>,
}

impl UpdateCommand {
    /// As the confirmation shows it: "npm install -g @openai/codex@latest".
    pub fn display(&self) -> String {
        let name = Path::new(&self.executable).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        std::iter::once(name).chain(self.arguments.iter().cloned()).collect::<Vec<_>>().join(" ")
    }
}

/// The agents whose program Nook can update. Antigravity's ACP server is a release Nook downloads and checks itself.
pub fn updatable(kind: AgentKind) -> bool {
    match kind {
        AgentKind::Claude | AgentKind::Codex | AgentKind::Gemini | AgentKind::Opencode | AgentKind::Cursor | AgentKind::Grok => true,
        _ => false,
    }
}

/// The npm package an agent is published as, for its newest version.
pub fn npm_package(kind: AgentKind) -> Option<&'static str> {
    match kind {
        AgentKind::Claude => Some("@anthropic-ai/claude-code"),
        AgentKind::Codex => Some("@openai/codex"),
        AgentKind::Gemini => Some("@google/gemini-cli"),
        AgentKind::Opencode => Some("opencode-ai"),
        AgentKind::Grok => Some("@xai-official/grok"),
        _ => None,
    }
}

fn self_update_arguments(kind: AgentKind) -> Option<Vec<String>> {
    match kind {
        AgentKind::Claude => Some(vec!["update".into()]),
        AgentKind::Opencode => Some(vec!["upgrade".into()]),
        AgentKind::Cursor => Some(vec!["update".into()]),
        _ => None,
    }
}

/// Where an agent's own installer puts it (`resolved` with forward slashes).
fn own_install(kind: AgentKind, resolved: &str, home: &str) -> bool {
    match kind {
        AgentKind::Claude => {
            resolved.starts_with(&format!("{home}/.local/share/claude/"))
                || resolved.starts_with(&format!("{home}/.claude/local/"))
                || resolved.eq_ignore_ascii_case(&format!("{home}/.local/bin/claude.exe"))
        }
        AgentKind::Opencode => resolved.starts_with(&format!("{home}/.opencode/")),
        AgentKind::Cursor => resolved.contains("/cursor-agent/"),
        _ => false,
    }
}

/// What installed the program at `resolved` (its real path). `exists` checks for a file (an npm beside it, a package
/// folder beside a Windows npm shim).
pub fn owner(kind: AgentKind, resolved: &str, home: &str, exists: impl Fn(&str) -> bool) -> InstallOwner {
    let resolved = resolved.replace('\\', "/");
    let home = home.replace('\\', "/").trim_end_matches('/').to_string();
    let parts: Vec<&str> = resolved.split('/').collect();
    let after = |marker: &str| -> Option<String> {
        let i = parts.iter().position(|p| p.eq_ignore_ascii_case(marker))?;
        parts.get(i + 1).filter(|p| !p.is_empty()).map(|p| p.to_string())
    };
    let package = || -> Option<String> {
        let i = parts.iter().rposition(|p| *p == "node_modules")?;
        let first = *parts.get(i + 1)?;
        if first.starts_with('@') {
            Some(format!("{first}/{}", parts.get(i + 2)?))
        } else {
            (!first.is_empty()).then(|| first.to_string())
        }
    };
    for (marker, cask) in [("Caskroom", true), ("Cellar", false)] {
        if let (Some(name), Some(at)) = (after(marker), resolved.find(&format!("/{marker}/"))) {
            return InstallOwner::Homebrew { brew: format!("{}/bin/brew", &resolved[..at]), name, cask };
        }
    }
    if let Some(name) = after("apps").filter(|_| resolved.to_lowercase().contains("/scoop/apps/")) {
        return InstallOwner::Scoop { name };
    }
    if resolved.contains("/.bun/install/global/node_modules/") {
        if let Some(package) = package() {
            return InstallOwner::Bun { bun: format!("{home}/.bun/bin/bun"), package };
        }
    }
    if resolved.contains("/pnpm/global/") || resolved.contains("/Library/pnpm/") || resolved.to_lowercase().contains("/appdata/local/pnpm/") {
        if let Some(package) = package() {
            return InstallOwner::Pnpm { package };
        }
    }
    if resolved.contains("/.volta/tools/image/packages/") || resolved.to_lowercase().contains("/volta/tools/image/packages/") {
        if let Some(package) = package() {
            return InstallOwner::Volta { package };
        }
    }
    if let Some(at) = resolved.find("/lib/node_modules/") {
        if let Some(package) = package() {
            let npm = format!("{}/bin/npm", &resolved[..at]);
            return InstallOwner::Npm { npm: if exists(&npm) { npm } else { "npm".into() }, package };
        }
    }
    // Windows: npm's global folder (%APPDATA%\npm) holds the `.cmd` shim with the package under node_modules beside it.
    if let Some(at) = resolved.rfind('/') {
        let dir = &resolved[..at];
        if let Some(package) = npm_package(kind).filter(|p| exists(&format!("{dir}/node_modules/{p}/package.json"))) {
            return InstallOwner::Npm { npm: "npm".into(), package: package.into() };
        }
        if let Some(package) = package() {
            if resolved.to_lowercase().contains("/appdata/roaming/npm/") {
                return InstallOwner::Npm { npm: "npm".into(), package };
            }
        }
    }
    if let Some(at) = resolved.find("/mise/installs/") {
        let tool = resolved[at + "/mise/installs/".len()..].split('/').next().unwrap_or("").to_string();
        if tool.starts_with("npm-") {
            if let Some(p) = npm_package(kind) {
                return InstallOwner::Mise { tool: format!("npm:{p}") };
            }
        }
        if !tool.is_empty() {
            return InstallOwner::Mise { tool };
        }
    }
    if own_install(kind, &resolved, &home) {
        if let Some(arguments) = self_update_arguments(kind) {
            return InstallOwner::SelfUpdate { arguments };
        }
    }
    InstallOwner::Unknown
}

/// The command that updates the program `owner` installed; `executable` is the agent's program, for its own updater.
pub fn command(owner: &InstallOwner, executable: &str) -> Option<UpdateCommand> {
    let c = |exe: &str, args: &[&str]| Some(UpdateCommand { executable: exe.into(), arguments: args.iter().map(|a| a.to_string()).collect() });
    match owner {
        InstallOwner::Homebrew { brew, name, cask } => {
            let mut args = vec!["upgrade"];
            if *cask {
                args.push("--cask");
            }
            args.push(name);
            c(brew, &args)
        }
        InstallOwner::Npm { npm, package } => c(npm, &["install", "-g", &format!("{package}@latest")]),
        InstallOwner::Pnpm { package } => c("pnpm", &["add", "-g", &format!("{package}@latest")]),
        InstallOwner::Bun { bun, package } => c(bun, &["add", "-g", &format!("{package}@latest")]),
        InstallOwner::Volta { package } => c("volta", &["install", &format!("{package}@latest")]),
        InstallOwner::Scoop { name } => c("scoop", &["update", name]),
        InstallOwner::Mise { tool } => c("mise", &["upgrade", tool]),
        InstallOwner::SelfUpdate { arguments } => Some(UpdateCommand { executable: executable.into(), arguments: arguments.clone() }),
        InstallOwner::Unknown => None,
    }
}

/// A dotted version ("2.1.100"), compared part by part (`CLIVersion`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version(pub Vec<u64>);

impl Version {
    /// The first dotted number in `text` ("claude 2.1.100 (Claude Code)" → 2.1.100).
    pub fn find(text: &str) -> Option<Self> {
        let start = text.find(|c: char| c.is_ascii_digit())?;
        let run: String = text[start..].chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
        let parts: Vec<u64> = run.trim_end_matches('.').split('.').filter_map(|p| p.parse().ok()).collect();
        (parts.len() >= 2).then_some(Self(parts))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        let n = self.0.len().max(other.0.len());
        (0..n).map(|i| self.0.get(i).unwrap_or(&0).cmp(other.0.get(i).unwrap_or(&0))).find(|o| o.is_ne()).unwrap_or(Ordering::Equal)
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0.iter().map(u64::to_string).collect::<Vec<_>>().join("."))
    }
}

/// Whether `latest` is newer than `installed`; false while either is unknown.
pub fn is_outdated(installed: Option<&str>, latest: Option<&str>) -> bool {
    match (installed.and_then(Version::find), latest.and_then(Version::find)) {
        (Some(have), Some(newest)) => have < newest,
        _ => false,
    }
}

/// The npm registry's `latest` of a package (`{"latest": "0.153.0", …}` from its dist-tags).
pub fn parse_npm_dist_tags(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    Version::find(v.get("latest")?.as_str()?).map(|v| v.to_string())
}

pub fn npm_dist_tags_url(package: &str) -> String {
    format!("https://registry.npmjs.org/-/package/{package}/dist-tags")
}

/// What a refusal of the agent's version said (`AgentVersionRejection.parse`): the version the API saw and the one it
/// requires, where it names them. `None` when the text is not such a refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rejection {
    pub reported: Option<String>,
    pub required: Option<String>,
}

/// How the other agents say it, lowercased: Codex's "requires a newer version of Codex. Please upgrade to the latest app
/// or CLI", and the same wording from Gemini CLI and gateways in front of other agents.
const REJECTION_PHRASES: [&str; 5] = [
    "requires a newer version of",
    "upgrade to the latest app or cli",
    "please upgrade to the latest version",
    "client version is too old",
    "this version of the cli is no longer supported",
];

pub fn parse_rejection(text: Option<&str>) -> Option<Rejection> {
    let text = text.filter(|t| !t.is_empty())?;
    const MARK: &str = " does not support this model; version ";
    if let (Some(at), Some(code)) = (text.find(MARK), text.find("Claude Code ")) {
        if code < at {
            let reported = Version::find(&text[code + "Claude Code ".len()..at]).map(|v| v.to_string());
            let rest = &text[at + MARK.len()..];
            if rest.contains("or newer is required") {
                return Some(Rejection { reported, required: Version::find(rest).map(|v| v.to_string()) });
            }
        }
    }
    let lower = text.to_lowercase();
    REJECTION_PHRASES.iter().any(|p| lower.contains(p)).then_some(Rejection { reported: None, required: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_who_installed_it() {
        let no = |_: &str| false;
        assert_eq!(
            owner(AgentKind::Codex, "/opt/homebrew/Caskroom/codex/0.1/codex", "/Users/me", no),
            InstallOwner::Homebrew { brew: "/opt/homebrew/bin/brew".into(), name: "codex".into(), cask: true }
        );
        assert_eq!(
            owner(AgentKind::Codex, "/usr/local/lib/node_modules/@openai/codex/bin/codex.js", "/Users/me", no),
            InstallOwner::Npm { npm: "npm".into(), package: "@openai/codex".into() }
        );
        // A Windows npm shim with the package beside it.
        let beside = |p: &str| p == "C:/Users/me/AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/package.json";
        assert_eq!(
            owner(AgentKind::Claude, r"C:\Users\me\AppData\Roaming\npm\claude.cmd", r"C:\Users\me", beside),
            InstallOwner::Npm { npm: "npm".into(), package: "@anthropic-ai/claude-code".into() }
        );
        assert_eq!(owner(AgentKind::Gemini, r"C:\Users\me\scoop\apps\gemini\current\gemini.exe", r"C:\Users\me", no), InstallOwner::Scoop { name: "gemini".into() });
        assert_eq!(
            owner(AgentKind::Claude, r"C:\Users\me\.local\bin\claude.exe", r"C:\Users\me", no),
            InstallOwner::SelfUpdate { arguments: vec!["update".into()] }
        );
        assert_eq!(owner(AgentKind::Grok, "/somewhere/grok", "/Users/me", no), InstallOwner::Unknown);
        let cmd = command(&InstallOwner::Npm { npm: "npm".into(), package: "@openai/codex".into() }, "codex").unwrap();
        assert_eq!(cmd.display(), "npm install -g @openai/codex@latest");
        assert!(command(&InstallOwner::Unknown, "x").is_none());
    }

    #[test]
    fn compares_versions_and_reads_npm() {
        assert!(is_outdated(Some("claude 2.1.100 (Claude Code)"), Some("2.1.200")));
        assert!(!is_outdated(Some("2.10.0"), Some("2.9.9")));
        assert!(!is_outdated(None, Some("1.0")));
        assert_eq!(parse_npm_dist_tags(r#"{"latest":"0.153.0","next":"0.154.0-alpha"}"#).as_deref(), Some("0.153.0"));
    }

    #[test]
    fn reads_a_version_refusal() {
        let claude = parse_rejection(Some(
            "API Error: 400 Claude Code 2.1.100 does not support this model; version 2.1.200 or newer is required. Run claude update.",
        ))
        .unwrap();
        assert_eq!(claude.reported.as_deref(), Some("2.1.100"));
        assert_eq!(claude.required.as_deref(), Some("2.1.200"));
        assert!(parse_rejection(Some("The 'gpt-5.5' model requires a newer version of Codex. Please upgrade to the latest app or CLI")).is_some());
        assert!(parse_rejection(Some("network error")).is_none());
    }
}
