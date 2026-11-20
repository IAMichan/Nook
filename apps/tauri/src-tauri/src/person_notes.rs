//! A note and a birthday you keep about a person (`nook_core::chats::person_notes`), set in a chat's info and read by
//! Today ("It's Anna's birthday today").

use std::sync::Mutex;

use nook_core::chats::person_notes::{PersonNote, PersonNotes};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

static NOTES: Mutex<Option<PersonNotes>> = Mutex::new(None);

fn with<T>(f: impl FnOnce(&mut PersonNotes) -> T) -> T {
    let mut guard = NOTES.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(PersonNotes::load))
}

#[tauri::command]
pub fn person_note(key: String) -> PersonNote {
    with(|n| n.get(&key))
}

#[tauri::command]
pub fn person_note_set(app: AppHandle, key: String, note: String, birthday: Option<String>) -> Result<PersonNote, String> {
    let saved = with(|n| {
        n.set(&key, &note, birthday.as_deref());
        n.save().map(|_| n.get(&key))
    })
    .map_err(|e| e.to_string())?;
    let _ = app.emit("person-notes", ());
    Ok(saved)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Birthday {
    pub key: String,
    pub name: String,
    pub app: String,
}

/// Today's birthdays among the people you gave one, with their chat's name and app.
#[tauri::command]
pub fn birthdays_today(app: AppHandle) -> Vec<Birthday> {
    let keys = with(|n| n.birthdays_on(chrono::Local::now().date_naive()));
    let Some(connectors) = app.try_state::<crate::connectors::Connectors>() else { return vec![] };
    connectors.env.chats.read(|inbox| {
        keys.iter()
            .filter_map(|k| inbox.threads.get(k).map(|t| Birthday { key: k.clone(), name: t.name.clone(), app: t.app.clone() }))
            .collect()
    })
}
