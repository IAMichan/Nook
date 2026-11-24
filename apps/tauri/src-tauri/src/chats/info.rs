//! What a chat's info sheet needs beyond the thread (`ChatsInfoSheet`): the groups you share with a person and exporting
//! the chat as a text file. The same for every chat app.

use nook_core::chats::profile::common_groups;
use serde::Serialize;
use tauri::State;

use crate::connectors::Connectors;

/// A group you share with a person: enough for a row that opens it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommonGroup {
    key: String,
    app: String,
    name: String,
    /// The group's people by name.
    members: Vec<String>,
}

/// The groups of the chat's app that list this chat's person, newest first (`ChatCommonGroups`).
#[tauri::command]
pub fn chat_common_groups(c: State<'_, Connectors>, key: String) -> Vec<CommonGroup> {
    c.env.chats.read(|inbox| {
        let Some(thread) = inbox.threads.get(&key) else { return vec![] };
        if thread.is_group() {
            return vec![];
        }
        let others = inbox.threads.values().filter(|t| !t.archived);
        common_groups(&thread.name, &thread.app, others)
            .into_iter()
            .map(|g| CommonGroup {
                key: inbox.threads.iter().find(|(_, t)| std::ptr::eq(*t, g)).map(|(k, _)| k.clone()).unwrap_or_default(),
                app: g.app.clone(),
                name: g.name.clone(),
                members: g.members.clone().unwrap_or_default(),
            })
            .filter(|g| !g.key.is_empty())
            .collect()
    })
}

/// Writes a chat's exported text (made by the interface in the user's language) to the file picked in the save dialog:
/// a `.txt` file, at most 20 MB, so the command writes nothing else.
#[tauri::command]
pub fn chat_export(path: String, contents: String) -> Result<(), String> {
    let path = std::path::PathBuf::from(path);
    if path.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case("txt")) != Some(true) {
        return Err("A chat is exported as a .txt file.".into());
    }
    if contents.len() > 20_000_000 {
        return Err("This chat is too large to export.".into());
    }
    std::fs::write(&path, contents).map_err(|e| e.to_string())
}
