//! Settings › Privacy › Permissions on Windows (`SystemPermission` on the Mac): what Windows lets Nook use, read from the
//! per-user privacy switches, and the Settings page that changes each. Read with `reg query`, so nothing is changed and
//! a missing value counts as allowed (Windows' own default).

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Permission {
    /// "microphone" or "notifications".
    pub id: &'static str,
    pub granted: bool,
}

/// One registry value under HKCU, or None when it (or `reg`) is not there.
#[cfg(windows)]
fn reg_value(key: &str, name: &str) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new("reg")
        .args(["query", &format!("HKCU\\{key}"), "/v", name])
        .creation_flags(0x0800_0000)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().find(|l| l.trim_start().starts_with(name)).and_then(|l| l.split_whitespace().last()).map(str::to_string)
}

/// Whether a consent switch allows desktop apps: the switch for all apps and the one for desktop apps both.
#[cfg(windows)]
fn consent(capability: &str) -> bool {
    let base = format!("Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\{capability}");
    let all = reg_value(&base, "Value").map(|v| v != "Deny").unwrap_or(true);
    let desktop = reg_value(&format!("{base}\\NonPackaged"), "Value").map(|v| v != "Deny").unwrap_or(true);
    all && desktop
}

#[cfg(windows)]
fn read() -> Vec<Permission> {
    let toasts = reg_value("Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", "ToastEnabled").map(|v| v != "0x0").unwrap_or(true);
    vec![Permission { id: "microphone", granted: consent("microphone") }, Permission { id: "notifications", granted: toasts }]
}

#[cfg(not(windows))]
fn read() -> Vec<Permission> {
    vec![]
}

#[tauri::command]
pub async fn permissions_overview() -> Vec<Permission> {
    tauri::async_runtime::spawn_blocking(read).await.unwrap_or_default()
}

/// Opens the Windows Settings page where `id` is switched on or off.
#[tauri::command]
pub fn permissions_open(app: tauri::AppHandle, id: String) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let page = match id.as_str() {
        "microphone" => "ms-settings:privacy-microphone",
        "notifications" => "ms-settings:notifications",
        _ => return Err("Unknown permission".into()),
    };
    app.opener().open_url(page, None::<&str>).map_err(|e| e.to_string())
}
