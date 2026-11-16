//! Settings › Maintenance: the data folder, caches, exporting and resetting the settings, and the versions.

use nook_core::i18n::{tr, trf};
use nook_core::maintenance;
use nook_core::paths;
use nook_core::settings::Settings;
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::state::AppState;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaintenanceInfo {
    data_folder: String,
    cache_bytes: u64,
    version: String,
    tauri_version: String,
    webview_version: Option<String>,
    os: String,
    arch: String,
}

#[tauri::command]
pub fn maintenance_info(app: AppHandle) -> MaintenanceInfo {
    let support = paths::support_directory();
    MaintenanceInfo {
        data_folder: support.display().to_string(),
        cache_bytes: maintenance::cache_size(&support),
        version: app.package_info().version.to_string(),
        tauri_version: tauri::VERSION.to_string(),
        webview_version: tauri::webview_version().ok(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
    }
}

#[tauri::command]
pub fn open_data_folder(app: AppHandle) -> Res<String> {
    use tauri_plugin_opener::OpenerExt;
    let folder = paths::support_directory();
    app.opener()
        .open_path(folder.to_string_lossy(), None::<&str>)
        .map_err(|e| trf("Kon de map niet openen: {error}", "Could not open the folder: {error}", &[("error", &e)]))?;
    Ok(folder.display().to_string())
}

/// Empties the caches; returns the bytes freed.
#[tauri::command]
pub fn clear_caches() -> u64 {
    maintenance::clear_caches(&paths::support_directory())
}

/// Asks where to save, then writes the settings there; `None` when the dialog was cancelled.
#[tauri::command]
pub async fn export_settings(app: AppHandle, state: State<'_, AppState>) -> Res<Option<String>> {
    let text = maintenance::export_settings(&state.settings());
    #[cfg(desktop)]
    {
        use tauri_plugin_dialog::DialogExt;
        let name = format!("{} {}.json", tr("Nook-instellingen", "Nook settings"), chrono::Local::now().format("%Y-%m-%d"));
        let dialog = app.clone();
        let chosen = tauri::async_runtime::spawn_blocking(move || {
            dialog
                .dialog()
                .file()
                .set_title(tr("Instellingen exporteren", "Export settings"))
                .set_file_name(name)
                .add_filter("JSON", &["json"])
                .blocking_save_file()
        })
        .await
        .map_err(|e| e.to_string())?;
        let Some(path) = chosen.and_then(|p| p.into_path().ok()) else { return Ok(None) };
        paths::write_atomic(&path, text.as_bytes())
            .map_err(|e| trf("Kon het bestand niet schrijven: {error}", "Could not write the file: {error}", &[("error", &e)]))?;
        Ok(Some(path.display().to_string()))
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, text);
        Ok(None)
    }
}

/// Puts the settings back to their defaults (keeping the language and the welcome), through the same path as saving.
#[tauri::command]
pub fn reset_settings(app: AppHandle, state: State<'_, AppState>) -> Settings {
    let reset = maintenance::reset_settings(&state.settings());
    super::save_settings(app, state, reset)
}
