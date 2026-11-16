//! Settings › Maintenance (`SettingsView+Maintenance` on the Mac): what can be tidied without losing anything you made.
//! Caches are files Nook fetches or writes again by itself (service icons, short-lived audio); settings can be exported
//! as a file and put back to their defaults. Secrets never live in the settings file, so an export holds no keys.

use std::path::{Path, PathBuf};

use crate::settings::Settings;

/// The folders under the data folder that only hold caches: service icons and short-lived audio files.
pub const CACHE_FOLDERS: [&str; 2] = ["icons", "tmp"];

/// The cache folders under `support`.
pub fn cache_folders(support: &Path) -> Vec<PathBuf> {
    CACHE_FOLDERS.iter().map(|name| support.join(name)).collect()
}

/// The size of a folder and everything in it, in bytes; 0 when it does not exist. Links are not followed.
pub fn folder_size(path: &Path) -> u64 {
    let Ok(meta) = std::fs::symlink_metadata(path) else { return 0 };
    if !meta.is_dir() {
        return meta.len();
    }
    std::fs::read_dir(path).map(|entries| entries.flatten().map(|e| folder_size(&e.path())).sum()).unwrap_or(0)
}

/// How much the caches under `support` take up, in bytes.
pub fn cache_size(support: &Path) -> u64 {
    cache_folders(support).iter().map(|p| folder_size(p)).sum()
}

/// Empties the caches under `support` (the folders stay); returns how many bytes were freed.
pub fn clear_caches(support: &Path) -> u64 {
    let mut freed = 0;
    for folder in cache_folders(support) {
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let size = folder_size(&path);
            let gone = match std::fs::symlink_metadata(&path) {
                Ok(m) if m.is_dir() => std::fs::remove_dir_all(&path),
                Ok(_) => std::fs::remove_file(&path),
                Err(e) => Err(e),
            };
            if gone.is_ok() {
                freed += size;
            }
        }
    }
    freed
}

/// The defaults, keeping what is about this computer and not a choice: the interface and answer language, that the
/// welcome was done, and where the main window was.
pub fn reset_settings(current: &Settings) -> Settings {
    Settings {
        app_language: current.app_language.clone(),
        language: current.language.clone(),
        onboarding_done: current.onboarding_done,
        tray_hint_shown: current.tray_hint_shown,
        main_window: current.main_window,
        ..Settings::default()
    }
}

/// The settings as the exported file holds them: pretty JSON with the same names as the settings file.
pub fn export_settings(settings: &Settings) -> String {
    serde_json::to_string_pretty(settings).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-maintenance-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn clearing_caches_leaves_everything_else() {
        let dir = temp();
        std::fs::create_dir_all(dir.join("icons")).unwrap();
        std::fs::create_dir_all(dir.join("tmp/nested")).unwrap();
        std::fs::write(dir.join("icons/github.com.img"), vec![0u8; 100]).unwrap();
        std::fs::write(dir.join("tmp/nested/a.wav"), vec![0u8; 50]).unwrap();
        std::fs::write(dir.join("settings.json"), b"{}").unwrap();
        std::fs::write(dir.join("nooks.json"), b"[]").unwrap();
        assert_eq!(cache_size(&dir), 150);
        assert_eq!(clear_caches(&dir), 150);
        assert_eq!(cache_size(&dir), 0);
        assert!(dir.join("icons").is_dir());
        assert!(dir.join("settings.json").exists() && dir.join("nooks.json").exists());
        // Nothing to clear is fine.
        assert_eq!(clear_caches(&dir.join("missing")), 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn reset_keeps_language_and_welcome() {
        let current = Settings {
            app_language: "de".into(),
            language: "auto".into(),
            onboarding_done: true,
            theme: "light".into(),
            instructions: "Call me Sam.".into(),
            accent_hex: 0x8b7bff,
            ..Default::default()
        };
        let reset = reset_settings(&current);
        assert_eq!(reset.app_language, "de");
        assert_eq!(reset.language, "auto");
        assert!(reset.onboarding_done);
        assert_eq!(reset.theme, "dark");
        assert!(reset.instructions.is_empty());
        assert_eq!(reset.accent_hex, Settings::default().accent_hex);
    }

    #[test]
    fn an_export_reads_back_as_the_same_settings() {
        let s = Settings { theme: "system".into(), density: "compact".into(), ..Default::default() };
        let back: Settings = serde_json::from_str(&export_settings(&s)).unwrap();
        assert_eq!(back, s);
    }
}
