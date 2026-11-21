//! Settings › Privacy › Permissions on Windows (`SystemPermission` on the Mac): what Windows lets Nook use, read from the
//! per-user privacy and system switches, and the Windows Settings (`ms-settings:`) page that changes each. Read with
//! `reg query`, so nothing is changed and a missing value counts as allowed (Windows' own default).

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionKind {
    /// Directly checked Windows privacy, notification, or system switch.
    Switch,
    /// Access note where Windows has a privacy pane and Nook also uses account sign-in or optional access.
    Note,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Permission {
    /// "microphone", "notifications", "screen", "location", "calendar", "mail", "background", or "startup".
    pub id: &'static str,
    /// Whether Nook can use this capability (`true` for informational notes so Overview only alerts on blocked switches).
    pub granted: bool,
    /// Raw Windows registry toggle state when available.
    pub windows_allowed: Option<bool>,
    /// Deep link URI opened in Windows Settings (`ms-settings:...`).
    pub settings_uri: &'static str,
    /// Recommended for Nook's core experience (matches macOS `SystemPermission.isRecommended`).
    pub recommended: bool,
    /// Direct switch vs access note.
    pub kind: PermissionKind,
}

/// Maps a permission id to its Windows Settings `ms-settings:` deep link URI.
pub fn settings_uri_for(id: &str) -> Option<&'static str> {
    match id {
        "microphone" => Some("ms-settings:privacy-microphone"),
        "notifications" => Some("ms-settings:notifications"),
        "screen" => Some("ms-settings:privacy-graphicscaptureprogrammatic"),
        "location" => Some("ms-settings:privacy-location"),
        "calendar" => Some("ms-settings:privacy-calendar"),
        "mail" => Some("ms-settings:privacy-email"),
        "background" => Some("ms-settings:privacy-backgroundapps"),
        "startup" => Some("ms-settings:startupapps"),
        "privacy" => Some("ms-settings:privacy"),
        _ => None,
    }
}

/// Extracts the value column from `reg query` stdout for `name`.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_reg_query_value(stdout: &str, name: &str) -> Option<String> {
    stdout
        .lines()
        .find(|l| l.trim_start().starts_with(name))
        .and_then(|l| l.split_whitespace().last())
        .map(str::to_string)
}

/// Windows `StartupApproved\Run` stores a hex REG_BINARY whose first byte is even (02/06) when enabled and odd (03/07)
/// when disabled by the user in Settings › Apps › Startup.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_startup_approved(hex: &str) -> bool {
    let trimmed = hex.trim().trim_start_matches("0x").trim_start_matches("0X");
    if trimmed.len() < 2 {
        return true;
    }
    u8::from_str_radix(&trimmed[..2], 16).map(|first| first % 2 == 0).unwrap_or(true)
}

#[cfg_attr(not(windows), allow(dead_code))]
struct WindowsChecks {
    microphone: bool,
    notifications: bool,
    screen: bool,
    location: bool,
    calendar: bool,
    mail: bool,
    background: bool,
    startup: bool,
}

#[cfg_attr(not(windows), allow(dead_code))]
fn build_overview(c: WindowsChecks) -> Vec<Permission> {
    vec![
        Permission {
            id: "microphone",
            granted: c.microphone,
            windows_allowed: Some(c.microphone),
            settings_uri: "ms-settings:privacy-microphone",
            recommended: true,
            kind: PermissionKind::Switch,
        },
        Permission {
            id: "notifications",
            granted: c.notifications,
            windows_allowed: Some(c.notifications),
            settings_uri: "ms-settings:notifications",
            recommended: true,
            kind: PermissionKind::Switch,
        },
        Permission {
            id: "screen",
            granted: c.screen,
            windows_allowed: Some(c.screen),
            settings_uri: "ms-settings:privacy-graphicscaptureprogrammatic",
            recommended: true,
            kind: PermissionKind::Switch,
        },
        Permission {
            id: "location",
            granted: true,
            windows_allowed: Some(c.location),
            settings_uri: "ms-settings:privacy-location",
            recommended: false,
            kind: PermissionKind::Note,
        },
        Permission {
            id: "calendar",
            granted: true,
            windows_allowed: Some(c.calendar),
            settings_uri: "ms-settings:privacy-calendar",
            recommended: false,
            kind: PermissionKind::Note,
        },
        Permission {
            id: "mail",
            granted: true,
            windows_allowed: Some(c.mail),
            settings_uri: "ms-settings:privacy-email",
            recommended: false,
            kind: PermissionKind::Note,
        },
        Permission {
            id: "background",
            granted: c.background,
            windows_allowed: Some(c.background),
            settings_uri: "ms-settings:privacy-backgroundapps",
            recommended: false,
            kind: PermissionKind::Switch,
        },
        Permission {
            id: "startup",
            granted: c.startup,
            windows_allowed: Some(c.startup),
            settings_uri: "ms-settings:startupapps",
            recommended: false,
            kind: PermissionKind::Switch,
        },
    ]
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
    parse_reg_query_value(&text, name)
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
    let toasts = reg_value("Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", "ToastEnabled")
        .map(|v| v != "0x0")
        .unwrap_or(true);
    let background = reg_value("Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications", "GlobalUserDisabled")
        .map(|v| v != "0x1")
        .unwrap_or(true);
    let startup = reg_value("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run", "Nook")
        .map(|v| parse_startup_approved(&v))
        .unwrap_or(true);
    build_overview(WindowsChecks {
        microphone: consent("microphone"),
        notifications: toasts,
        screen: consent("graphicsCaptureProgrammatic"),
        location: consent("location"),
        calendar: consent("appointments"),
        mail: consent("email"),
        background,
        startup,
    })
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
    let page = settings_uri_for(id.as_str()).ok_or_else(|| format!("Unknown permission: {id}"))?;
    app.opener().open_url(page, None::<&str>).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_windows_permission_has_real_ms_settings_deep_link() {
        let items = build_overview(WindowsChecks {
            microphone: true,
            notifications: false,
            screen: true,
            location: false,
            calendar: false,
            mail: true,
            background: true,
            startup: false,
        });
        assert_eq!(items.len(), 8);
        let ids: Vec<&str> = items.iter().map(|p| p.id).collect();
        assert_eq!(ids, vec!["microphone", "notifications", "screen", "location", "calendar", "mail", "background", "startup"]);
        for item in &items {
            assert!(item.settings_uri.starts_with("ms-settings:"), "bad uri for {}: {}", item.id, item.settings_uri);
            assert_eq!(settings_uri_for(item.id), Some(item.settings_uri));
        }
        assert_eq!(settings_uri_for("unknown"), None);
        // Core switch reflects registry state; informational access notes keep granted=true while exposing windows_allowed.
        assert!(!items.iter().find(|p| p.id == "notifications").unwrap().granted);
        let cal = items.iter().find(|p| p.id == "calendar").unwrap();
        assert!(cal.granted);
        assert_eq!(cal.windows_allowed, Some(false));
        assert_eq!(cal.kind, PermissionKind::Note);
    }

    #[test]
    fn parses_registry_output_and_startup_approved_bytes() {
        let out = "\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications\r\n    ToastEnabled    REG_DWORD    0x0\r\n";
        assert_eq!(parse_reg_query_value(out, "ToastEnabled").as_deref(), Some("0x0"));
        assert_eq!(parse_reg_query_value(out, "Missing"), None);

        assert!(parse_startup_approved("020000000000000000000000"));
        assert!(!parse_startup_approved("0300000090B5A4D701000000"));
        assert!(parse_startup_approved(""));
    }
}
