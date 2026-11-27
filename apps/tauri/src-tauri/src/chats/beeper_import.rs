//! Tauri commands for moving from Beeper Desktop (`BeeperImporter`, CH-20).

use nook_core::chats::beeper_import::{installed_executable, BeeperImportStatus};
use tauri::{AppHandle, State};
use tauri_plugin_opener::OpenerExt;

use crate::connectors::Connectors;

type Res<T> = Result<T, String>;

const BEEPER_API_DOCS: &str = "https://developers.beeper.com/desktop-api/";

#[tauri::command]
pub fn beeper_import_status(c: State<'_, Connectors>) -> BeeperImportStatus {
    c.beeper_import.status()
}

#[tauri::command]
pub fn beeper_import_save_token(c: State<'_, Connectors>, token: String) -> Res<BeeperImportStatus> {
    c.beeper_import.save_token(&token)
}

#[tauri::command]
pub async fn beeper_import_run(app: AppHandle, c: State<'_, Connectors>) -> Res<BeeperImportStatus> {
    let status = match c.beeper_import.run(&c.env.chats).await {
        Ok(status) => {
            if let Err(error) = c.env.chats.save() {
                log::warn!("Chats: could not save inbox after Beeper import: {error}");
            }
            super::inbox::changed(&app);
            status
        }
        Err(_) => c.beeper_import.status(),
    };
    Ok(status)
}

#[tauri::command]
pub fn beeper_import_finish(c: State<'_, Connectors>) -> BeeperImportStatus {
    c.beeper_import.finish()
}

/// Opens Beeper Desktop when installed on this computer, otherwise opens its Desktop API guide.
#[tauri::command]
pub fn beeper_import_open_app(app: AppHandle) -> Res<()> {
    if let Some(path) = installed_executable() {
        if app.opener().open_path(path.to_string_lossy(), None::<&str>).is_ok() {
            return Ok(());
        }
    }
    app.opener().open_url(BEEPER_API_DOCS, None::<&str>).map_err(|e| e.to_string())
}
