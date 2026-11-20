//! Your own rules for the main window's keys: `keybindings.json` in Nook's data folder (the Mac's
//! `~/.nook/keybindings.json`, docs/KEYBINDINGS.md). The interface weighs them (`lib/keybindings.ts`); Rust only reads
//! and writes the file and tells every window it changed. A file you edit by hand is read again at the next start or
//! the next change from Settings.

use std::path::PathBuf;

use serde_json::Value;
use tauri::{AppHandle, Emitter};

pub fn file() -> PathBuf {
    nook_core::paths::support_directory().join("keybindings.json")
}

/// The rules in the file as they are; an empty list when there is no file or it is not a list.
pub fn read_rules(text: Option<&str>) -> Vec<Value> {
    text.and_then(|t| serde_json::from_str::<Value>(t).ok())
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .filter(|r| r.is_object())
        .collect()
}

#[tauri::command]
pub fn keybindings_read() -> Vec<Value> {
    read_rules(std::fs::read_to_string(file()).ok().as_deref())
}

#[tauri::command]
pub fn keybindings_write(app: AppHandle, rules: Vec<Value>) -> Result<(), String> {
    let text = serde_json::to_string_pretty(&rules).map_err(|e| e.to_string())?;
    std::fs::write(file(), format!("{text}\n")).map_err(|e| e.to_string())?;
    let _ = app.emit("keybindings-changed", ());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_only_a_list_of_rules() {
        assert_eq!(read_rules(None).len(), 0);
        assert_eq!(read_rules(Some("not json")).len(), 0);
        assert_eq!(read_rules(Some(r#"{"key":"mod+k"}"#)).len(), 0);
        assert_eq!(read_rules(Some(r#"[{"key":"mod+k","command":"search.toggle"}, 3]"#)).len(), 1);
    }
}
