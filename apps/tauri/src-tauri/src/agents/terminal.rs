//! Het venster waarin een agent draait naar voren halen, of een nieuw terminalvenster openen (`TerminalLauncher` en
//! `WindowAttach` op de Mac).
//!
//! - Windows: het venster van Windows Terminal, VS Code, … via de Win32-API; een nieuw venster met `wt` (of
//!   PowerShell als Windows Terminal er niet is).
//! - Linux (X11): `xdotool` of `wmctrl` met het venster uit `WINDOWID`, anders op vensterklasse; een nieuw venster met de
//!   eerste terminal die er is. Op Wayland kan een app geen ander venster naar voren halen; dat zegt Nook dan.

use std::path::Path;
use std::process::Command;

/// "Windows Terminal", "VS Code", … voor op een knop.
pub fn name(host: &str) -> String {
    match host {
        "windows-terminal" => "Windows Terminal".into(),
        "vscode" => "VS Code".into(),
        "jetbrains" => "JetBrains".into(),
        "kitty" => "kitty".into(),
        "wezterm" => "WezTerm".into(),
        "konsole" => "Konsole".into(),
        "apple_terminal" => "Terminal".into(),
        "iterm.app" => "iTerm".into(),
        "ghostty" => "Ghostty".into(),
        h if h.starts_with("x11:") => "terminal".into(),
        _ => "terminal".into(),
    }
}

/// Haalt het venster van de agent naar voren. `Err` met een uitleg als dat niet kan.
pub fn activate(host: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        windows::activate(host)
    }
    #[cfg(target_os = "linux")]
    {
        linux::activate(host)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = host;
        Err("Dit kan Nook op dit platform niet.".into())
    }
}

/// Opent een nieuw terminalvenster dat `command` draait in `folder`, met je eigen shell.
pub fn run(command: &str, folder: &Path) -> Result<(), String> {
    if !folder.is_dir() {
        return Err(format!("De map {} bestaat niet.", folder.display()));
    }
    #[cfg(target_os = "windows")]
    {
        windows::run(command, folder)
    }
    #[cfg(target_os = "linux")]
    {
        linux::run(command, folder)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = command;
        Err("Dit kan Nook op dit platform niet.".into())
    }
}

fn spawn(mut command: Command) -> Result<(), String> {
    command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;

    fn wayland_only() -> bool {
        std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_some()
    }

    fn ok(mut c: Command) -> bool {
        c.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        c.status().map(|s| s.success()).unwrap_or(false)
    }

    pub fn activate(host: &str) -> Result<(), String> {
        if wayland_only() {
            return Err("Op Wayland kan Nook geen ander venster naar voren halen. Ga zelf naar je terminal.".into());
        }
        if let Some(id) = host.strip_prefix("x11:").and_then(|i| i.parse::<u64>().ok()) {
            let mut x = Command::new("xdotool");
            x.args(["windowactivate", &id.to_string()]);
            if ok(x) {
                return Ok(());
            }
            let mut w = Command::new("wmctrl");
            w.args(["-i", "-a", &format!("0x{id:08x}")]);
            if ok(w) {
                return Ok(());
            }
        }
        let classes: &[&str] = match host {
            "vscode" => &["code", "cursor"],
            "kitty" => &["kitty"],
            "wezterm" => &["org.wezfurlong.wezterm"],
            "konsole" => &["konsole"],
            "jetbrains" => &["jetbrains"],
            _ => &[
                "gnome-terminal-server",
                "konsole",
                "kitty",
                "alacritty",
                "org.wezfurlong.wezterm",
                "xfce4-terminal",
                "tilix",
                "xterm",
                "code",
            ],
        };
        for class in classes {
            let mut x = Command::new("xdotool");
            x.args(["search", "--onlyvisible", "--class", class, "windowactivate"]);
            if ok(x) {
                return Ok(());
            }
        }
        Err("Nook vond het venster van de agent niet (installeer xdotool of wmctrl voor deze functie).".into())
    }

    pub fn run(command: &str, folder: &Path) -> Result<(), String> {
        if wayland_only() && std::env::var_os("XDG_CURRENT_DESKTOP").is_none() {
            return Err("Geen terminal gevonden om te openen.".into());
        }
        let script = format!(
            "cd {} || exit 1; {command}; exec \"${{SHELL:-sh}}\" -i",
            nook_core::agents::profiles::shell_quote(&folder.to_string_lossy())
        );
        let preferred = std::env::var("TERMINAL").ok().filter(|t| !t.is_empty());
        let candidates = preferred.iter().map(String::as_str).chain([
            "x-terminal-emulator",
            "gnome-terminal",
            "konsole",
            "xfce4-terminal",
            "kitty",
            "alacritty",
            "wezterm",
            "tilix",
            "xterm",
        ]);
        for terminal in candidates {
            if nook_core::agents::which(terminal).is_none() {
                continue;
            }
            let mut c = Command::new(terminal);
            match terminal {
                "gnome-terminal" => {
                    c.arg(format!("--working-directory={}", folder.display())).args(["--", "sh", "-c", &script]);
                }
                "konsole" => {
                    c.args(["--workdir", &folder.to_string_lossy(), "-e", "sh", "-c", &script]);
                }
                "kitty" => {
                    c.args(["--directory", &folder.to_string_lossy(), "sh", "-c", &script]);
                }
                "wezterm" => {
                    c.args(["start", "--cwd", &folder.to_string_lossy(), "--", "sh", "-c", &script]);
                }
                "tilix" | "xfce4-terminal" => {
                    c.args(["-x", "sh", "-c", &script]);
                }
                _ => {
                    c.args(["-e", "sh", "-c", &script]);
                }
            }
            c.current_dir(folder);
            if spawn(c).is_ok() {
                return Ok(());
            }
        }
        Err("Geen terminal gevonden. Installeer er een (bijvoorbeeld GNOME Terminal of Konsole), of zet TERMINAL.".into())
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use super::*;
    use std::os::windows::process::CommandExt;

    use windows_sys::core::BOOL;
    use windows_sys::Win32::Foundation::{CloseHandle, HWND, LPARAM};
    use windows_sys::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowThreadProcessId, IsIconic, IsWindowVisible, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    struct Search {
        names: Vec<String>,
        found: HWND,
    }

    fn image_name(pid: u32) -> Option<String> {
        // SAFETY: een handle met beperkte rechten, met een buffer van vaste lengte; de handle wordt gesloten.
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return None;
            }
            let mut buffer = [0u16; 1024];
            let mut size = buffer.len() as u32;
            let ok = QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut size);
            CloseHandle(handle);
            if ok == 0 {
                return None;
            }
            let path = String::from_utf16_lossy(&buffer[..size as usize]);
            path.rsplit('\\').next().map(|n| n.to_lowercase())
        }
    }

    unsafe extern "system" fn visit(hwnd: HWND, data: LPARAM) -> BOOL {
        // SAFETY: `data` wijst naar de `Search` die `activate` zolang leeft.
        let search = &mut *(data as *mut Search);
        if IsWindowVisible(hwnd) == 0 {
            return 1;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if let Some(name) = image_name(pid) {
            if search.names.iter().any(|n| *n == name) {
                search.found = hwnd;
                return 0;
            }
        }
        1
    }

    pub fn activate(host: &str) -> Result<(), String> {
        let names: Vec<&str> = match host {
            "windows-terminal" => vec!["windowsterminal.exe"],
            "vscode" => vec!["code.exe", "cursor.exe"],
            "jetbrains" => vec!["idea64.exe", "pycharm64.exe", "webstorm64.exe", "rider64.exe", "goland64.exe", "clion64.exe"],
            "wezterm" => vec!["wezterm-gui.exe"],
            _ => {
                vec!["windowsterminal.exe", "code.exe", "cursor.exe", "wezterm-gui.exe", "alacritty.exe", "conhost.exe", "openconsole.exe"]
            }
        };
        let mut search = Search { names: names.into_iter().map(String::from).collect(), found: std::ptr::null_mut() };
        // SAFETY: EnumWindows roept `visit` synchroon aan met een pointer naar `search`.
        unsafe {
            EnumWindows(Some(visit), &mut search as *mut Search as LPARAM);
            if search.found.is_null() {
                return Err("Nook vond het venster van de agent niet.".into());
            }
            if IsIconic(search.found) != 0 {
                ShowWindow(search.found, SW_RESTORE);
            }
            SetForegroundWindow(search.found);
        }
        Ok(())
    }

    pub fn run(command: &str, folder: &Path) -> Result<(), String> {
        let folder_text = folder.to_string_lossy().into_owned();
        if nook_core::agents::which("wt").is_some() {
            let mut c = Command::new("wt");
            c.args(["-d", &folder_text, "powershell", "-NoExit", "-Command", command]);
            return spawn(c);
        }
        let script = format!("Set-Location -LiteralPath '{}'; {command}", folder_text.replace('\'', "''"));
        let mut c = Command::new("cmd");
        c.creation_flags(CREATE_NO_WINDOW);
        c.args(["/C", "start", "\"Nook\"", "powershell", "-NoExit", "-Command", &script]);
        spawn(c)
    }
}
