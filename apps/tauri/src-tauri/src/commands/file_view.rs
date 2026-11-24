//! The file viewer's read and save (`FileViewing`, AG-101): what a file link opens in the session's File tab.

use nook_core::workspace::file_view::{self, FileEditText, FileSaveResult, FileView};

/// What the viewer shows for `path`: its text and how to write it back, or that an app shows it better.
#[tauri::command]
pub async fn workspace_file_read(path: String) -> Result<FileView, String> {
    tokio::task::spawn_blocking(move || file_view::read(&path)).await.map_err(|e| e.to_string())
}

/// Writes edited text over a file the way it was written (encoding, byte order mark, line breaks).
#[tauri::command]
pub async fn workspace_file_save(path: String, text: String, file: FileEditText, overwrite: bool) -> Result<FileSaveResult, String> {
    tokio::task::spawn_blocking(move || file_view::save(&path, &text, &file, overwrite)).await.map_err(|e| e.to_string())
}
