//! Where a session's folder opens (Settings › Sessions › Editor & browser, `editorBundleID` on the Mac): the file
//! manager, or an editor found on this computer. Editors are found by their command on the PATH. Also the rest of that
//! page: the terminal a folder opens in (`terminalBundleID`) and Nook's browser (`BrowserSearchEngine`,
//! `AgentLinkTarget`, `BrowserHistory.enabledKey`), kept in `open-in.json`.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};

/// An editor Nook can open a folder in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Editor {
    /// The command, also what is stored ("code").
    pub id: &'static str,
    pub name: &'static str,
}

/// The editors Nook knows, in the Mac's order where it has them.
pub const CANDIDATES: [Editor; 6] = [
    Editor { id: "code", name: "Visual Studio Code" },
    Editor { id: "cursor", name: "Cursor" },
    Editor { id: "windsurf", name: "Windsurf" },
    Editor { id: "zed", name: "Zed" },
    Editor { id: "idea", name: "IntelliJ IDEA" },
    Editor { id: "subl", name: "Sublime Text" },
];

/// The terminal inside Nook's main window (Agents › All terminals); always there (`builtInTerminal` on the Mac).
pub const BUILT_IN_TERMINAL: &str = "nook";

/// The terminals Nook knows, Nook's own first. On Windows: Windows Terminal, PowerShell 7, Windows PowerShell and the
/// Command Prompt; elsewhere the common Linux terminals.
pub const TERMINALS: [Editor; 5] = if cfg!(windows) {
    [
        Editor { id: BUILT_IN_TERMINAL, name: "Nook" },
        Editor { id: "wt", name: "Windows Terminal" },
        Editor { id: "pwsh", name: "PowerShell" },
        Editor { id: "powershell", name: "Windows PowerShell" },
        Editor { id: "cmd", name: "Command Prompt" },
    ]
} else {
    [
        Editor { id: BUILT_IN_TERMINAL, name: "Nook" },
        Editor { id: "gnome-terminal", name: "GNOME Terminal" },
        Editor { id: "konsole", name: "Konsole" },
        Editor { id: "kitty", name: "kitty" },
        Editor { id: "wezterm", name: "WezTerm" },
    ]
};

/// The full path of `command` on the PATH (with Windows' `.cmd`/`.exe`), if it is there.
pub fn find(command: &str, path_var: &str) -> Option<std::path::PathBuf> {
    let exts: &[&str] = if cfg!(windows) { &[".cmd", ".exe", ".bat"] } else { &[""] };
    std::env::split_paths(path_var).find_map(|dir| exts.iter().map(|e| dir.join(format!("{command}{e}"))).find(|p| p.is_file()))
}

/// The editors on this computer.
pub fn installed() -> Vec<Editor> {
    let path = std::env::var("PATH").unwrap_or_default();
    CANDIDATES.iter().filter(|e| find(e.id, &path).is_some()).cloned().collect()
}

/// The terminals on this computer: Nook's own, and the others found on the PATH.
pub fn installed_terminals() -> Vec<Editor> {
    terminals_on(&std::env::var("PATH").unwrap_or_default())
}

fn terminals_on(path_var: &str) -> Vec<Editor> {
    TERMINALS.iter().filter(|t| t.id == BUILT_IN_TERMINAL || find(t.id, path_var).is_some()).cloned().collect()
}

/// The program and arguments that open `folder` in terminal `id`; `None` for Nook's own terminal (or an unknown one,
/// which falls back to it).
pub fn terminal_command(id: &str, folder: &str) -> Option<(String, Vec<String>)> {
    let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    match id {
        "wt" => Some(("wt".into(), args(&["-d", folder]))),
        // `start` gives the shell a console window of its own; the folder is set as the working directory.
        "pwsh" | "powershell" => Some(("cmd".into(), args(&["/c", "start", "", id, "-NoExit"]))),
        "cmd" => Some(("cmd".into(), args(&["/c", "start", "", "cmd", "/k"]))),
        "gnome-terminal" => Some(("gnome-terminal".into(), vec![format!("--working-directory={folder}")])),
        "konsole" => Some(("konsole".into(), args(&["--workdir", folder]))),
        "kitty" => Some(("kitty".into(), args(&["--directory", folder]))),
        "wezterm" => Some(("wezterm".into(), args(&["start", "--cwd", folder]))),
        _ => None,
    }
}

/// The search engine of the browser's address bar (`BrowserSearchEngine` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SearchEngine {
    #[default]
    #[serde(rename = "duckduckgo")]
    DuckDuckGo,
    Google,
    Bing,
    Brave,
    Kagi,
    Startpage,
    Ecosia,
}

impl SearchEngine {
    pub const ALL: [SearchEngine; 7] = [
        SearchEngine::DuckDuckGo,
        SearchEngine::Google,
        SearchEngine::Bing,
        SearchEngine::Brave,
        SearchEngine::Kagi,
        SearchEngine::Startpage,
        SearchEngine::Ecosia,
    ];

    fn base(self) -> &'static str {
        match self {
            SearchEngine::DuckDuckGo => "https://duckduckgo.com/",
            SearchEngine::Google => "https://www.google.com/search",
            SearchEngine::Bing => "https://www.bing.com/search",
            SearchEngine::Brave => "https://search.brave.com/search",
            SearchEngine::Kagi => "https://kagi.com/search",
            SearchEngine::Startpage => "https://www.startpage.com/do/search",
            SearchEngine::Ecosia => "https://www.ecosia.org/search",
        }
    }

    /// The search page for `query`.
    pub fn url(self, query: &str) -> String {
        format!("{}?q={}", self.base(), super::source_control::encode(query))
    }
}

/// Settings › Sessions › Editor & browser, apart from the editor (which lives in `WorkspaceSettings`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OpenInPrefs {
    /// A `TERMINALS` id; `BUILT_IN_TERMINAL` by default, as on the Mac.
    pub terminal: String,
    pub search_engine: SearchEngine,
    /// Where a web link in an agent's conversation opens: "app" (Nook's browser) or "system" (your own browser).
    pub link_target: String,
    /// Nook's browser keeps the pages you visit for the address bar's suggestions (`BrowserHistory.enabledKey`).
    pub remember_history: bool,
}

impl Default for OpenInPrefs {
    fn default() -> Self {
        Self { terminal: BUILT_IN_TERMINAL.into(), search_engine: SearchEngine::default(), link_target: "app".into(), remember_history: true }
    }
}

static CURRENT: Mutex<Option<OpenInPrefs>> = Mutex::new(None);

impl OpenInPrefs {
    pub fn file() -> std::path::PathBuf {
        crate::paths::support_directory().join("open-in.json")
    }

    pub fn load_from(file: &std::path::Path) -> Self {
        let mut prefs: Self = std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        prefs.clean();
        prefs
    }

    /// Unknown values back to their defaults.
    fn clean(&mut self) {
        if !TERMINALS.iter().any(|t| t.id == self.terminal) {
            self.terminal = BUILT_IN_TERMINAL.into();
        }
        if self.link_target != "system" {
            self.link_target = "app".into();
        }
    }

    /// The saved choices (read once, then kept in memory).
    pub fn current() -> Self {
        let mut slot = CURRENT.lock().unwrap_or_else(|e| e.into_inner());
        slot.get_or_insert_with(|| Self::load_from(&Self::file())).clone()
    }

    /// Saves `self` and makes it the current choice.
    pub fn save(mut self) -> Self {
        self.clean();
        if let Ok(bytes) = serde_json::to_vec_pretty(&self) {
            let _ = crate::paths::write_atomic(&Self::file(), &bytes);
        }
        *CURRENT.lock().unwrap_or_else(|e| e.into_inner()) = Some(self.clone());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_nothing_on_an_empty_path() {
        assert!(find("code", "").is_none());
        assert_eq!(CANDIDATES[0].id, "code");
    }

    #[test]
    fn nooks_own_terminal_is_always_there() {
        let found = terminals_on("");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, BUILT_IN_TERMINAL);
        assert!(terminal_command(BUILT_IN_TERMINAL, "C:\\repo").is_none());
        assert_eq!(terminal_command("wt", "C:\\repo").unwrap(), ("wt".to_string(), vec!["-d".to_string(), "C:\\repo".to_string()]));
    }

    #[test]
    fn search_engines_build_their_search_page() {
        assert_eq!(SearchEngine::DuckDuckGo.url("rust borrow"), "https://duckduckgo.com/?q=rust%20borrow");
        assert_eq!(SearchEngine::Google.url("a&b"), "https://www.google.com/search?q=a%26b");
        assert_eq!(SearchEngine::ALL.len(), 7);
        assert_eq!(serde_json::to_string(&SearchEngine::DuckDuckGo).unwrap(), "\"duckduckgo\"");
        assert_eq!(serde_json::from_str::<SearchEngine>("\"ecosia\"").unwrap(), SearchEngine::Ecosia);
    }

    #[test]
    fn prefs_default_and_clean_unknown_values() {
        let dir = std::env::temp_dir().join(format!("nook-open-in-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("open-in.json");
        assert_eq!(OpenInPrefs::load_from(&file), OpenInPrefs::default());
        std::fs::write(&file, r#"{"terminal":"nope","linkTarget":"elsewhere","searchEngine":"kagi","rememberHistory":false}"#).unwrap();
        let prefs = OpenInPrefs::load_from(&file);
        assert_eq!(prefs.terminal, BUILT_IN_TERMINAL);
        assert_eq!(prefs.link_target, "app");
        assert_eq!(prefs.search_engine, SearchEngine::Kagi);
        assert!(!prefs.remember_history);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
