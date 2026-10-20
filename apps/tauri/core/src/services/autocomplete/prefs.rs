//! Autocomplete's settings, stored in `settings.json` under `autocomplete`. Ported from `CompletionPreferences.swift`.
//! Every field has a default, so files written before a field existed still load.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::suggestion::AcceptOptions;

/// On, off, or what the general setting says.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TriState {
    #[default]
    Inherit,
    On,
    Off,
}

impl TriState {
    pub fn resolved(self, fallback: bool) -> bool {
        match self {
            Self::Inherit => fallback,
            Self::On => true,
            Self::Off => false,
        }
    }
}

/// What Escape does besides hiding the suggestion.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EscapeAction {
    /// Hide the suggestion only.
    #[default]
    Dismiss,
    /// Also pause for ten seconds.
    PauseBriefly,
    /// Also stop in this app until you switch apps.
    OffUntilAppSwitch,
}

/// Which model writes the suggestions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EngineChoice {
    /// A model on this computer (Ollama or LM Studio). Typed text never leaves the computer.
    #[default]
    Local,
    /// The brain chosen in Settings › Brain, also when that is an external service: typed text then goes there. Only
    /// when the user picks it explicitly.
    Brain,
}

/// Which local server runs the model.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LocalServer {
    /// The brain's server when that is local, otherwise Ollama.
    #[default]
    Auto,
    Ollama,
    Lmstudio,
}

/// Settings for one app, by its id (the exe name on Windows).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppRule {
    pub enabled: TriState,
    pub mid_line: TriState,
    /// Leave Tab to the app (indenting, moving between fields).
    pub leave_tab: bool,
    pub instructions: String,
}

impl AppRule {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

/// Settings for one website, by host name.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SiteRule {
    pub enabled: TriState,
    pub instructions: String,
}

/// All of autocomplete's settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutocompleteSettings {
    pub enabled: bool,
    /// Off: only in apps turned on one by one.
    pub enabled_by_default: bool,
    pub max_words: usize,
    /// Also while editing a sentence, with words after the cursor.
    pub mid_line: bool,
    /// 0 only very sure suggestions … 1 eager.
    pub eagerness: f64,
    pub trailing_space: bool,
    /// Punctuation after a word ("there,") comes with the word. Off: it waits for its own press of the accept key.
    pub punctuation_with_word: bool,
    pub escape: EscapeAction,
    /// Wait this long after the last key before the field is read, in milliseconds.
    pub delay_milliseconds: u64,

    pub engine: EngineChoice,
    pub local_server: LocalServer,
    /// The model on the local server; empty for an automatic choice.
    pub model: String,

    /// The app's name and the window title go into the prompt.
    pub window_context: bool,
    pub memory_context: bool,
    pub clipboard_context: bool,
    pub instructions: String,

    pub apps: BTreeMap<String, AppRule>,
    pub sites: BTreeMap<String, SiteRule>,

    /// Accelerator-style names ("Tab", "Shift+Tab", "Alt+Right"); empty turns the key off.
    pub accept_word: String,
    pub accept_all: String,
}

impl Default for AutocompleteSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            enabled_by_default: true,
            max_words: 8,
            mid_line: true,
            eagerness: 0.5,
            trailing_space: false,
            punctuation_with_word: false,
            escape: EscapeAction::Dismiss,
            delay_milliseconds: 40,
            engine: EngineChoice::Local,
            local_server: LocalServer::Auto,
            model: String::new(),
            window_context: true,
            memory_context: true,
            clipboard_context: false,
            instructions: String::new(),
            apps: BTreeMap::new(),
            sites: BTreeMap::new(),
            accept_word: "Tab".into(),
            accept_all: "Shift+Tab".into(),
        }
    }
}

/// Apps where suggestions are off unless turned on: terminals and code editors (they have their own completion) and
/// password managers. Windows exe names; a trailing `*` matches any rest of the name.
pub const OFF_BY_DEFAULT: [&str; 24] = [
    "WindowsTerminal.exe",
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "conhost.exe",
    "OpenConsole.exe",
    "wt.exe",
    "mintty.exe",
    "alacritty.exe",
    "wezterm-gui.exe",
    "Code.exe",
    "Code - Insiders.exe",
    "Cursor.exe",
    "Windsurf.exe",
    "devenv.exe",
    "idea64.exe",
    "pycharm64.exe",
    "rider64.exe",
    "sublime_text.exe",
    "Zed.exe",
    "1Password.exe",
    "KeePass*.exe",
    "Bitwarden.exe",
    "Dashlane.exe",
];

/// An app id as compared: lowercase, without ".exe" (the screen reader reports "WindowsTerminal", rules may say
/// "WindowsTerminal.exe").
pub fn normalize_app(id: &str) -> String {
    let lower = id.trim().to_lowercase();
    lower.strip_suffix(".exe").map(str::to_string).unwrap_or(lower)
}

/// Whether autocomplete is off by default in this app.
pub fn is_off_by_default(app: &str) -> bool {
    let app = normalize_app(app);
    if app.is_empty() {
        return false;
    }
    OFF_BY_DEFAULT.iter().any(|pattern| {
        let pattern = normalize_app(pattern);
        match pattern.strip_suffix('*') {
            Some(prefix) => app.starts_with(prefix),
            None => app == pattern,
        }
    })
}

impl AutocompleteSettings {
    /// The rule for an app, whatever spelling its id has in the map.
    pub fn app(&self, app: &str) -> AppRule {
        let wanted = normalize_app(app);
        self.apps.iter().find(|(id, _)| normalize_app(id) == wanted).map(|(_, rule)| rule.clone()).unwrap_or_default()
    }

    /// Changes the rule of an app; a rule back at its defaults is removed.
    pub fn set_app(&mut self, app: &str, rule: AppRule) {
        let wanted = normalize_app(app);
        self.apps.retain(|id, _| normalize_app(id) != wanted);
        if !rule.is_default() {
            self.apps.insert(app.to_string(), rule);
        }
    }

    /// On in this app: autocomplete is on, and the app is not turned off (by the user or by default).
    pub fn is_enabled_in_app(&self, app: &str) -> bool {
        self.enabled && self.app_on(app)
    }

    /// Whether the app's own switch is on: its rule, or the default for it when the rule says "Standard".
    pub fn app_on(&self, app: &str) -> bool {
        let rule = self.app(app);
        rule.enabled.resolved(self.enabled_by_default && !is_off_by_default(app))
    }

    pub fn is_enabled_on_site(&self, host: Option<&str>) -> bool {
        host.and_then(|h| self.sites.get(h)).map(|r| r.enabled.resolved(true)).unwrap_or(true)
    }

    pub fn mid_line_in_app(&self, app: &str) -> bool {
        self.app(app).mid_line.resolved(self.mid_line)
    }

    /// General, app and site instructions, in that order.
    pub fn instructions_for(&self, app: Option<&str>, site: Option<&str>) -> Vec<String> {
        vec![
            self.instructions.clone(),
            app.map(|a| self.app(a).instructions).unwrap_or_default(),
            site.and_then(|s| self.sites.get(s)).map(|r| r.instructions.clone()).unwrap_or_default(),
        ]
    }

    pub fn accept_options(&self) -> AcceptOptions {
        AcceptOptions { trailing_space: self.trailing_space, attached_punctuation: self.punctuation_with_word }
    }
}

/// A key with its modifiers, as the platform layer matches it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyChord {
    pub key: ChordKey,
    pub shift: bool,
    pub control: bool,
    pub alt: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChordKey {
    Tab,
    Right,
    End,
    Backtick,
    Enter,
}

/// The keys Settings offers for accepting (the platform layer knows these). Plain typing keys are not offered: they could
/// no longer be typed.
pub const ACCEPT_KEYS: [&str; 7] = ["Tab", "Shift+Tab", "Alt+Right", "Ctrl+Right", "Alt+End", "Ctrl+Enter", "`"];

impl KeyChord {
    /// Parses "Shift+Tab", "Alt+Right", "`"; `None` for an empty or unknown name.
    pub fn parse(text: &str) -> Option<Self> {
        let mut chord = KeyChord { key: ChordKey::Tab, shift: false, control: false, alt: false };
        let mut key = None;
        for part in text.split('+').map(str::trim).filter(|p| !p.is_empty()) {
            match part.to_lowercase().as_str() {
                "shift" => chord.shift = true,
                "ctrl" | "control" => chord.control = true,
                "alt" | "option" => chord.alt = true,
                "tab" => key = Some(ChordKey::Tab),
                "right" | "arrowright" => key = Some(ChordKey::Right),
                "end" => key = Some(ChordKey::End),
                "`" | "backtick" | "backquote" => key = Some(ChordKey::Backtick),
                "enter" | "return" => key = Some(ChordKey::Enter),
                _ => return None,
            }
        }
        chord.key = key?;
        Some(chord)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_off_and_local() {
        let s = AutocompleteSettings::default();
        assert!(!s.enabled);
        assert_eq!(s.engine, EngineChoice::Local);
        assert!(!s.is_enabled_in_app("notepad"));
    }

    #[test]
    fn old_files_load() {
        let s: AutocompleteSettings = serde_json::from_str(r#"{"enabled":true,"apps":{"Slack.exe":{"leaveTab":true}}}"#).unwrap();
        assert!(s.enabled);
        assert_eq!(s.max_words, 8);
        assert!(s.app("slack").leave_tab);
        assert_eq!(s.app("slack").enabled, TriState::Inherit);
    }

    #[test]
    fn default_off_apps() {
        assert!(is_off_by_default("WindowsTerminal"));
        assert!(is_off_by_default("WindowsTerminal.exe"));
        assert!(is_off_by_default("CMD.EXE"));
        assert!(is_off_by_default("Code"));
        assert!(is_off_by_default("KeePassXC.exe"));
        assert!(is_off_by_default("KeePass"));
        assert!(is_off_by_default("1Password"));
        assert!(!is_off_by_default("notepad"));
        assert!(!is_off_by_default(""));
    }

    #[test]
    fn app_rules() {
        let mut s = AutocompleteSettings { enabled: true, ..Default::default() };
        assert!(s.is_enabled_in_app("notepad.exe"));
        assert!(!s.is_enabled_in_app("Code.exe"));
        s.set_app("Code.exe", AppRule { enabled: TriState::On, ..Default::default() });
        assert!(s.is_enabled_in_app("code"));
        s.set_app("notepad", AppRule { enabled: TriState::Off, ..Default::default() });
        assert!(!s.is_enabled_in_app("Notepad.exe"));
        // Back to defaults: the rule goes.
        s.set_app("NOTEPAD.EXE", AppRule::default());
        assert!(!s.apps.keys().any(|k| normalize_app(k) == "notepad"));
        s.enabled_by_default = false;
        assert!(!s.is_enabled_in_app("notepad"));
        assert!(s.is_enabled_in_app("code"));
        s.enabled = false;
        assert!(!s.is_enabled_in_app("code"));
    }

    #[test]
    fn mid_line_and_instructions() {
        let mut s = AutocompleteSettings { instructions: "I am Anna".into(), ..Default::default() };
        s.set_app("slack", AppRule { mid_line: TriState::Off, instructions: "Short and loose".into(), ..Default::default() });
        s.sites.insert("mail.example.com".into(), SiteRule { enabled: TriState::Off, instructions: "Formal".into() });
        assert!(!s.mid_line_in_app("Slack.exe"));
        assert!(s.mid_line_in_app("notepad"));
        assert_eq!(s.instructions_for(Some("slack"), Some("mail.example.com")), vec!["I am Anna", "Short and loose", "Formal"]);
        assert!(!s.is_enabled_on_site(Some("mail.example.com")));
        assert!(s.is_enabled_on_site(Some("other.example")));
        assert!(s.is_enabled_on_site(None));
    }

    #[test]
    fn chords() {
        assert_eq!(KeyChord::parse("Tab"), Some(KeyChord { key: ChordKey::Tab, shift: false, control: false, alt: false }));
        assert_eq!(KeyChord::parse("Shift+Tab").map(|c| c.shift), Some(true));
        assert_eq!(KeyChord::parse("Alt+Right").map(|c| (c.key, c.alt)), Some((ChordKey::Right, true)));
        assert_eq!(KeyChord::parse("`").map(|c| c.key), Some(ChordKey::Backtick));
        assert_eq!(KeyChord::parse(""), None);
        assert_eq!(KeyChord::parse("Shift"), None);
        assert_eq!(KeyChord::parse("Ctrl+Q"), None);
        assert!(ACCEPT_KEYS.iter().all(|k| KeyChord::parse(k).is_some()));
    }
}
