//! One list of the apps Nook knows by kind (the Mac's `AppCatalog`), by the names Windows and Linux give them: the exe
//! on Windows ("msedge.exe", "WindowsTerminal.exe"), the binary or WM_CLASS on Linux ("google-chrome-stable",
//! "gnome-terminal"), a Store package ("MSTeams_8wekyb3d8bbwe"). Quiet mode (a call with the microphone open, a
//! browser's sharing bar), Flow's style per app and autocomplete ask here, so an app added once is known everywhere.
//! An app can be more than one kind: WhatsApp is where you chat and where you call.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AppKind {
    Mail,
    Browser,
    Editor,
    Terminal,
    Chat,
    Call,
}

/// The program part of a name: lowercased, without its folder and ".exe".
pub fn program(name: &str) -> String {
    let lower = name.trim().to_lowercase();
    let file = lower.rsplit(['\\', '/']).next().unwrap_or(&lower).to_string();
    file.strip_suffix(".exe").map(str::to_string).unwrap_or(file)
}

/// Browsers by the start of their program name (after "google-" or "ms"): "chrome", "msedge", "firefox".
pub const BROWSERS: [&str; 12] =
    ["chrome", "chromium", "edge", "brave", "arc", "vivaldi", "opera", "firefox", "librewolf", "floorp", "zen", "epiphany"];

/// Apps you hold calls in; helpers and Store packages share the name as a prefix ("ms-teams", "MSTeams_8wekyb3d8bbwe").
pub const CALLS: [&str; 16] = [
    "zoom",
    "ms-teams",
    "msteams",
    "teams",
    "microsoft.teams",
    "webex",
    "ciscocollabhost",
    "atmgr",
    "discord",
    "slack",
    "skype",
    "whatsapp",
    "telegram",
    "signal",
    "gather",
    "around",
];

/// Chat apps: where people write to you.
pub const CHATS: [&str; 12] =
    ["whatsapp", "telegram", "signal", "slack", "discord", "ms-teams", "msteams", "teams", "messenger", "beeper", "element", "skype"];

/// Terminals.
pub const TERMINALS: [&str; 20] = [
    "windowsterminal",
    "wt",
    "cmd",
    "powershell",
    "pwsh",
    "conhost",
    "gnome-terminal",
    "kgx",
    "konsole",
    "xterm",
    "alacritty",
    "kitty",
    "wezterm",
    "wezterm-gui",
    "ghostty",
    "tilix",
    "terminator",
    "xfce4-terminal",
    "warp",
    "tabby",
];

/// Code editors.
pub const EDITORS: [&str; 15] = [
    "code",
    "code-insiders",
    "cursor",
    "windsurf",
    "zed",
    "idea",
    "idea64",
    "pycharm",
    "pycharm64",
    "webstorm",
    "rider",
    "clion",
    "sublime_text",
    "notepad++",
    "devenv",
];

/// Mail apps ("olk" is the new Outlook).
pub const MAIL: [&str; 7] = ["outlook", "olk", "thunderbird", "evolution", "geary", "mailspring", "hxoutlook"];

fn named(list: &[&str], program: &str) -> bool {
    list.iter().any(|n| program == *n || program.starts_with(&format!("{n}-")) || program.starts_with(&format!("{n}_")))
}

pub fn is_browser(name: &str) -> bool {
    let p = program(name);
    let bare = p.trim_start_matches("google-").trim_start_matches("ms");
    BROWSERS.iter().any(|b| bare.starts_with(b))
}

pub fn is_call_app(name: &str) -> bool {
    let p = program(name);
    CALLS.iter().any(|app| p.starts_with(app))
}

pub fn is_chat_app(name: &str) -> bool {
    let p = program(name);
    CHATS.iter().any(|app| p.starts_with(app))
}

pub fn is_terminal(name: &str) -> bool {
    named(&TERMINALS, &program(name))
}

pub fn is_editor(name: &str) -> bool {
    named(&EDITORS, &program(name))
}

pub fn is_mail_app(name: &str) -> bool {
    named(&MAIL, &program(name))
}

/// Every kind an app is.
pub fn kinds(name: &str) -> Vec<AppKind> {
    [
        (AppKind::Mail, is_mail_app(name)),
        (AppKind::Browser, is_browser(name)),
        (AppKind::Editor, is_editor(name)),
        (AppKind::Terminal, is_terminal(name)),
        (AppKind::Chat, is_chat_app(name)),
        (AppKind::Call, is_call_app(name)),
    ]
    .into_iter()
    .filter_map(|(k, yes)| yes.then_some(k))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_windows_and_linux_names() {
        assert_eq!(kinds(r"C:\Program Files\Google\Chrome\Application\chrome.exe"), vec![AppKind::Browser]);
        assert!(is_browser("msedge.exe") && is_browser("google-chrome-stable") && is_browser("firefox"));
        assert!(is_terminal("WindowsTerminal.exe") && is_terminal("gnome-terminal-server") && !is_terminal("cmdline-tool"));
        assert!(is_editor("Code.exe") && is_editor("cursor") && !is_editor("codex"));
        assert!(is_mail_app("olk.exe") && is_mail_app("thunderbird"));
        assert_eq!(kinds("WhatsApp.exe"), vec![AppKind::Chat, AppKind::Call]);
        assert!(is_call_app("MSTeams_8wekyb3d8bbwe") && is_call_app("Zoom.exe"));
        assert!(kinds("notepad.exe").is_empty());
    }
}
