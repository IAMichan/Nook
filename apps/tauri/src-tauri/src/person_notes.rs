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
    let Some(connectors) = app.try_state::<crate::connectors::Connectors>() else { return vec![] };
    let people = connectors.env.chats.read(|inbox| nook_core::chats::ChatPeople::people(inbox.threads.values()));
    let keys = with(|n| {
        if n.has_name_keys() && n.carry_over(&people) {
            let _ = n.save();
        }
        n.birthdays_on(chrono::Local::now().date_naive())
    });
    connectors.env.chats.read(|inbox| {
        let mut seen = std::collections::HashSet::new();
        keys.iter()
            .filter_map(|k| {
                if let Some(t) = inbox.threads.get(k) {
                    return seen.insert(t.id.clone()).then(|| Birthday { key: t.id.clone(), name: t.name.clone(), app: t.app.clone() });
                }
                let person = people.iter().find(|p| p.id == *k)?;
                let chat = person.chats.first()?;
                seen.insert(chat.chat.clone()).then(|| Birthday {
                    key: chat.chat.clone(),
                    name: person.name.clone(),
                    app: chat.app.clone(),
                })
            })
            .collect()
    })
}
