//! Coding-agents: de hub die hun hooks ontvangt, het koppelen (instellingenbestanden met diff en backup), het lezen
//! van hun transcripten en accounts, en de proceslijst. Zoals `AgentHub`, `AgentConfigInstaller`, `AgentHistory` en
//! `AgentProfiles` op de Mac.

pub mod history;
pub mod hook;
pub mod hub;
pub mod installer;
pub mod ipc;
pub mod line_diff;
pub mod liveness;
pub mod mcp_name;
pub mod models;
pub mod plugins;
pub mod profiles;
pub mod registry;
pub mod risk;
pub mod scanner;
pub mod sessions;
pub mod text;
pub mod transcript;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Bij welke agent een sessie of account hoort.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    Claude,
    Codex,
    Gemini,
    Antigravity,
    Opencode,
    Cursor,
    Grok,
}

impl AgentKind {
    pub const ALL: [AgentKind; 7] = [Self::Claude, Self::Codex, Self::Gemini, Self::Antigravity, Self::Opencode, Self::Cursor, Self::Grok];

    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Gemini => "gemini",
            Self::Antigravity => "antigravity",
            Self::Opencode => "opencode",
            Self::Cursor => "cursor",
            Self::Grok => "grok",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.id() == id)
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Gemini => "Gemini CLI",
            Self::Antigravity => "Antigravity",
            Self::Opencode => "OpenCode",
            Self::Cursor => "Cursor",
            Self::Grok => "Grok",
        }
    }

    pub fn short_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Gemini => "Gemini",
            other => other.name(),
        }
    }

    pub fn from_agent_name(name: &str) -> Option<Self> {
        match name {
            "Claude Code" | "Claude (app)" => Some(Self::Claude),
            "Codex" => Some(Self::Codex),
            "Gemini CLI" => Some(Self::Gemini),
            "Antigravity" => Some(Self::Antigravity),
            "OpenCode" => Some(Self::Opencode),
            "Cursor" => Some(Self::Cursor),
            "Grok" | "Grok Build" => Some(Self::Grok),
            _ => None,
        }
    }

    /// Het terminalcommando.
    pub fn command(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Gemini => "gemini",
            Self::Antigravity => "agy",
            Self::Opencode => "opencode",
            Self::Cursor => "cursor-agent",
            Self::Grok => "grok",
        }
    }

    pub fn color(self) -> u32 {
        match self {
            Self::Claude => 0xE08A5E,
            Self::Codex => 0x6FCFB3,
            Self::Gemini => 0x8AB4F8,
            Self::Antigravity => 0xEA4335,
            Self::Opencode => 0xF5A742,
            Self::Cursor => 0x9AA4B2,
            Self::Grok => 0xD9D9DE,
        }
    }

    /// De omgevingsvariabele die de agent naar een eigen accountmap wijst; `None` als hij geen accounts per map kent.
    pub fn home_variable(self) -> Option<&'static str> {
        match self {
            Self::Claude => Some("CLAUDE_CONFIG_DIR"),
            Self::Codex => Some("CODEX_HOME"),
            _ => None,
        }
    }

    pub fn supports_profiles(self) -> bool {
        self.home_variable().is_some()
    }

    /// Alles wat Nook voor deze agent met één klik koppelt.
    pub fn targets(self) -> Vec<installer::Target> {
        use installer::Target::*;
        match self {
            Self::Claude => vec![ClaudeHooks, ClaudeStatusLine],
            Self::Codex => vec![Codex],
            Self::Gemini => vec![Gemini],
            Self::Antigravity => vec![Antigravity],
            Self::Opencode => vec![OpenCode],
            Self::Cursor => vec![Cursor],
            Self::Grok => vec![],
        }
    }

    /// Hoe je de agent installeert als hij er nog niet is.
    pub fn install_command(self) -> &'static str {
        if cfg!(windows) {
            match self {
                Self::Claude => "irm https://claude.ai/install.ps1 | iex",
                Self::Codex => "npm install -g @openai/codex",
                Self::Gemini => "npm install -g @google/gemini-cli",
                Self::Antigravity => "winget install Google.Antigravity",
                Self::Opencode => "npm install -g opencode-ai",
                Self::Cursor => "irm 'https://cursor.com/install?win32=true' | iex",
                Self::Grok => "npm install -g @xai-official/grok",
            }
        } else {
            match self {
                Self::Claude => r#"curl -fsSL https://claude.ai/install.sh | bash && export PATH="$HOME/.local/bin:$PATH""#,
                Self::Codex => "npm install -g @openai/codex",
                Self::Gemini => "npm install -g @google/gemini-cli",
                Self::Antigravity => "Installeer Antigravity via antigravity.google",
                Self::Opencode => "curl -fsSL https://opencode.ai/install | bash",
                Self::Cursor => "curl https://cursor.com/install -fsS | bash",
                Self::Grok => "npm install -g @xai-official/grok",
            }
        }
    }

    /// Inloggen. Claude Code en Gemini CLI vragen het vanzelf bij de eerste start; Codex heeft een eigen commando.
    pub fn login_command(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex login",
            Self::Gemini => "gemini",
            Self::Antigravity => "agy",
            Self::Opencode => "opencode auth login",
            Self::Cursor => "cursor-agent login",
            Self::Grok => "grok",
        }
    }

    /// De standaardmap van de agent, waar het hoofdaccount staat.
    pub fn default_home(self) -> PathBuf {
        let home = home_dir();
        match self {
            Self::Claude => {
                std::env::var("CLAUDE_CONFIG_DIR").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or(home.join(".claude"))
            }
            Self::Codex => std::env::var("CODEX_HOME").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or(home.join(".codex")),
            Self::Gemini | Self::Antigravity => home.join(".gemini"),
            Self::Opencode => home.join(".local").join("share").join("opencode"),
            Self::Cursor => home.join(".cursor"),
            Self::Grok => home.join(".grok"),
        }
    }

    /// Mogelijke plekken van het programma, naast wat in `PATH` staat.
    pub fn executable_candidates(self) -> Vec<PathBuf> {
        let home = home_dir();
        let mut dirs: Vec<PathBuf> = vec![
            home.join(".local").join("bin"),
            home.join(".npm-global").join("bin"),
            home.join(".volta").join("bin"),
            home.join(".bun").join("bin"),
        ];
        if cfg!(windows) {
            if let Some(appdata) = std::env::var_os("APPDATA") {
                dirs.push(PathBuf::from(appdata).join("npm"));
            }
            if let Some(local) = std::env::var_os("LOCALAPPDATA") {
                let local = PathBuf::from(local);
                dirs.push(local.join("Programs").join(self.command()));
                dirs.push(local.join("pnpm"));
            }
        } else {
            dirs.extend([PathBuf::from("/usr/local/bin"), PathBuf::from("/usr/bin"), home.join(".local").join("share").join("pnpm")]);
        }
        match self {
            Self::Claude => dirs.insert(0, home.join(".claude").join("local")),
            Self::Opencode => dirs.insert(0, home.join(".opencode").join("bin")),
            Self::Antigravity => {
                dirs.insert(0, home.join(".gemini").join("antigravity").join("bin"));
                dirs.insert(0, home.join(".antigravity").join("antigravity").join("bin"));
            }
            _ => {}
        }
        let nvm = home.join(".nvm").join("versions").join("node");
        if let Ok(entries) = std::fs::read_dir(&nvm) {
            let mut versions: Vec<PathBuf> = entries.flatten().map(|e| e.path().join("bin")).collect();
            versions.sort();
            versions.reverse();
            dirs.extend(versions);
        }
        let mut result = vec![];
        for dir in dirs {
            for name in executable_names(self.command()) {
                result.push(dir.join(name));
            }
        }
        result
    }
}

/// De thuismap van de gebruiker.
pub fn home_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir)
}

/// `claude` → `claude` op Linux; `claude.exe`, `claude.cmd`, … op Windows.
pub fn executable_names(command: &str) -> Vec<String> {
    if cfg!(windows) {
        let pathext = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
        let mut names: Vec<String> =
            pathext.split(';').filter(|e| !e.is_empty()).map(|e| format!("{command}{}", e.to_lowercase())).collect();
        names.push(command.into());
        names
    } else {
        vec![command.into()]
    }
}

pub fn is_executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// Zoekt een programma in `PATH` en op de bekende plekken van de agent.
pub fn find_executable(kind: AgentKind) -> Option<PathBuf> {
    which(kind.command()).or_else(|| kind.executable_candidates().into_iter().find(|p| is_executable(p)))
}

/// Zoekt `command` in `PATH` (met `PATHEXT` op Windows).
pub fn which(command: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for name in executable_names(command) {
            let candidate = dir.join(name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

/// `~/x` als dat korter is, anders het volledige pad.
pub fn tilde(path: &str) -> String {
    let home = home_dir().to_string_lossy().into_owned();
    if !home.is_empty() && path.starts_with(&home) && path.len() > home.len() {
        format!("~{}", &path[home.len()..])
    } else {
        path.into()
    }
}
