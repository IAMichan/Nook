//! The storage notices in the main window (the Mac's `AppModel+StorageIncidents`): a database Nook could not open, or
//! set aside because it was damaged (`nook_core::storage_recovery`), until you dismiss it.

use nook_core::storage_recovery::{self, Incident};
use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
pub fn storage_incidents() -> Vec<Incident> {
    storage_recovery::incidents()
}

#[tauri::command]
pub fn storage_incident_dismiss(id: u64) {
    storage_recovery::dismiss(id);
}

/// Shows the copy (or the file) in Explorer or the file manager.
#[tauri::command]
pub fn storage_reveal(app: AppHandle, id: u64) -> Result<(), String> {
    let incident = storage_recovery::incidents().into_iter().find(|i| i.id == id).ok_or("gone")?;
    let path = incident.moved_to.unwrap_or(incident.file);
    app.opener().reveal_item_in_dir(path).map_err(|e| e.to_string())
}
