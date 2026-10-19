//! Systeem op Windows: apps uit het Startmenu (ook Store-apps via `shell:AppsFolder`), het klembord, plakken waar je
//! typt (`SendInput`), zoeken met Windows Search (`SystemIndex`) en de lijst recente bestanden.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::Duration;

use nook_core::platform::{InstalledApp, SystemControl};
use nook_core::services::{files, fuzzy};
use tauri::AppHandle;
use windows::core::{Interface, HSTRING, PCWSTR};
use windows::Win32::System::Com::{CoCreateInstance, IPersistFile, CLSCTX_INPROC_SERVER, STGM_READ};
use windows::Win32::System::DataExchange::{CloseClipboard, IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL,
};
use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};

use super::screen::com;
use crate::platform::process;

pub struct WindowsSystem {
    app: AppHandle,
    apps: Mutex<Option<Vec<InstalledApp>>>,
}

impl WindowsSystem {
    pub fn new(app: &AppHandle) -> Self {
        Self { app: app.clone(), apps: Mutex::new(None) }
    }

    fn apps(&self) -> Vec<InstalledApp> {
        let mut guard = self.apps.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            let mut list = start_apps();
            if list.is_empty() {
                list = shortcuts();
            }
            *guard = Some(list);
        }
        guard.clone().unwrap_or_default()
    }
}

/// De apps van het Startmenu met hun AppID (`Get-StartApps`), ook Store-apps.
fn start_apps() -> Vec<InstalledApp> {
    let script = "Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress";
    let Ok(out) = process::run_text("powershell", &["-NoProfile", "-NonInteractive", "-Command", script], Duration::from_secs(15)) else {
        return vec![];
    };
    let json: serde_json::Value = serde_json::from_str(out.trim()).unwrap_or_default();
    let items = match json {
        serde_json::Value::Array(items) => items,
        single @ serde_json::Value::Object(_) => vec![single],
        _ => vec![],
    };
    items
        .iter()
        .filter_map(|i| {
            let name = i.get("Name")?.as_str()?.to_string();
            let id = i.get("AppID")?.as_str()?.to_string();
            Some(InstalledApp { name, launch: format!("shell:AppsFolder\\{id}") })
        })
        .collect()
}

/// Snelkoppelingen in de Startmenu-mappen, als `Get-StartApps` niet werkt.
fn shortcuts() -> Vec<InstalledApp> {
    let mut roots = Vec::new();
    if let Some(data) = std::env::var_os("ProgramData") {
        roots.push(PathBuf::from(data).join("Microsoft\\Windows\\Start Menu\\Programs"));
    }
    if let Some(data) = std::env::var_os("APPDATA") {
        roots.push(PathBuf::from(data).join("Microsoft\\Windows\\Start Menu\\Programs"));
    }
    let mut out = Vec::new();
    let mut stack: Vec<(PathBuf, usize)> = roots.into_iter().map(|r| (r, 0)).collect();
    while let Some((dir, depth)) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() && depth < 3 {
                stack.push((path, depth + 1));
            } else if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("lnk")) {
                let name = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                if !name.to_lowercase().contains("uninstall") && !name.to_lowercase().contains("verwijder") {
                    out.push(InstalledApp { name, launch: path.display().to_string() });
                }
            }
        }
    }
    out
}

/// Of het klembord als geheim gemarkeerd is (wachtwoordbeheerders zetten deze formaten).
fn clipboard_is_secret() -> bool {
    unsafe {
        if OpenClipboard(None).is_err() {
            return false;
        }
        let secret = ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"].iter().any(|name| {
            let format = RegisterClipboardFormatW(&HSTRING::from(*name));
            format != 0 && IsClipboardFormatAvailable(format).is_ok()
        });
        let _ = CloseClipboard();
        secret
    }
}

fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: 0 },
        },
    }
}

/// Ctrl+V naar het venster dat de focus heeft.
fn paste_keys() -> Result<(), String> {
    let v = VIRTUAL_KEY(0x56);
    let inputs = [key(VK_CONTROL, false), key(v, false), key(v, true), key(VK_CONTROL, true)];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err("Windows liet Nook niet plakken (een app met meer rechten heeft de focus).".into())
    }
}

/// Waar een snelkoppeling naar wijst.
fn resolve_link(path: &Path) -> Option<PathBuf> {
    com();
    unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        let file: IPersistFile = link.cast().ok()?;
        file.Load(PCWSTR(HSTRING::from(path.as_os_str()).as_ptr()), STGM_READ).ok()?;
        let mut buf = vec![0u16; 1024];
        link.GetPath(&mut buf, std::ptr::null_mut(), 0).ok()?;
        let end = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
        let target = String::from_utf16_lossy(&buf[..end]);
        (!target.is_empty()).then(|| PathBuf::from(target))
    }
}

/// Alleen letters, cijfers en spaties: de zoekwoorden komen in een SQL-zin van Windows Search.
fn clean_words(query: &str) -> Vec<String> {
    files::words(query).into_iter().map(|w| w.chars().filter(|c| c.is_alphanumeric()).collect::<String>()).filter(|w| w.len() >= 2).collect()
}

impl SystemControl for WindowsSystem {
    fn open_app(&self, name: &str) -> Result<(), String> {
        let clean = name.trim();
        if clean.is_empty() || clean.starts_with('-') || clean.contains(['/', '\\', '"']) {
            return Err("Ongeldige appnaam.".into());
        }
        let apps = self.apps();
        let names: Vec<String> = apps.iter().map(|a| a.name.clone()).collect();
        let found = fuzzy::best(clean, &names).ok_or_else(|| format!("Geen app met de naam {clean} gevonden op deze computer."))?;
        let app = apps.iter().find(|a| a.name == found).ok_or_else(|| format!("Geen app met de naam {clean} gevonden."))?;
        Command::new("explorer.exe").arg(&app.launch).spawn().map(|_| ()).map_err(|e| format!("{found} kon niet starten: {e}"))
    }

    fn open_url(&self, url: &str) -> Result<(), String> {
        use tauri_plugin_opener::OpenerExt;
        self.app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
    }

    fn notify(&self, title: &str, body: &str) {
        crate::platform::notify(&self.app, title, body);
    }

    fn installed_apps(&self) -> Vec<InstalledApp> {
        self.apps()
    }

    fn clipboard_text(&self) -> Result<Option<String>, String> {
        if clipboard_is_secret() {
            return Ok(None);
        }
        let mut board = arboard::Clipboard::new().map_err(|e| format!("Het klembord is niet bereikbaar: {e}"))?;
        Ok(board.get_text().ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()))
    }

    fn paste_text(&self, text: &str) -> Result<bool, String> {
        let mut board = arboard::Clipboard::new().map_err(|e| format!("Het klembord is niet bereikbaar: {e}"))?;
        let previous = board.get_text().ok();
        board.set_text(text.to_string()).map_err(|e| e.to_string())?;
        std::thread::sleep(Duration::from_millis(60));
        paste_keys()?;
        if let Some(previous) = previous {
            std::thread::sleep(Duration::from_millis(1500));
            if board.get_text().ok().as_deref() == Some(text) {
                let _ = board.set_text(previous);
            }
        }
        Ok(true)
    }

    fn copy_image(&self, png: &[u8]) -> Result<(), String> {
        let image = image::load_from_memory(png).map_err(|e| e.to_string())?.to_rgba8();
        let (w, h) = image.dimensions();
        let mut board = arboard::Clipboard::new().map_err(|e| e.to_string())?;
        board.set_image(arboard::ImageData { width: w as usize, height: h as usize, bytes: image.into_raw().into() }).map_err(|e| e.to_string())
    }

    fn search_index(&self, query: &str, limit: usize) -> Option<Vec<PathBuf>> {
        let home = dirs::home_dir()?;
        let words = clean_words(query);
        if words.is_empty() {
            return Some(vec![]);
        }
        let scope = home.display().to_string().replace('\\', "/").replace('\'', "");
        let names = words.iter().map(|w| format!("System.FileName LIKE '%{w}%'")).collect::<Vec<_>>().join(" AND ");
        let contents = words.iter().map(|w| format!("\"{w}*\"")).collect::<Vec<_>>().join(" AND ");
        let sql = format!("SELECT TOP {} System.ItemPathDisplay FROM SYSTEMINDEX WHERE SCOPE='file:{scope}' AND (({names}) OR CONTAINS(*, '{contents}'))", limit.max(10) * 2);
        let script = format!(
            "$c=New-Object -ComObject ADODB.Connection; $c.Open(\"Provider=Search.CollatorDSO;Extended Properties='Application=Windows';\"); $r=$c.Execute(\"{}\"); while(-not $r.EOF){{ $r.Fields.Item(0).Value; $r.MoveNext() }}",
            sql.replace('"', "`\"")
        );
        let out = process::run_text("powershell", &["-NoProfile", "-NonInteractive", "-Command", &script], Duration::from_secs(10)).ok()?;
        Some(out.lines().map(|l| PathBuf::from(l.trim())).filter(|p| p.is_file() && files::is_allowed(p, &home)).take(limit).collect())
    }

    fn recent_files(&self, limit: usize) -> Vec<PathBuf> {
        let (Some(home), Some(data)) = (dirs::home_dir(), std::env::var_os("APPDATA")) else { return vec![] };
        let recent = PathBuf::from(data).join("Microsoft\\Windows\\Recent");
        let links: Vec<PathBuf> = std::fs::read_dir(recent)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("lnk")))
            .collect();
        files::newest(links, limit * 3)
            .into_iter()
            .filter_map(|l| resolve_link(&l))
            .filter(|p| p.is_file() && files::is_allowed(p, &home))
            .take(limit)
            .collect()
    }

    fn pdf_text(&self, path: &Path) -> Result<String, String> {
        if !process::which("pdftotext") {
            return Err("PDF's lezen kan op deze computer niet: zet pdftotext (Poppler voor Windows) op het PATH.".into());
        }
        let path = path.to_string_lossy().to_string();
        process::run_text("pdftotext", &["-layout", "-enc", "UTF-8", &path, "-"], Duration::from_secs(20))
    }
}
