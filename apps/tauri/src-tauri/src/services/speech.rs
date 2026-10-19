//! Voorlezen: een antwoord op een gesproken vraag wordt zin voor zin uitgesproken terwijl het geschreven wordt, als
//! "Lees antwoorden voor als ik iets zeg" aanstaat (Instellingen › Stem en geluid).

use std::collections::HashMap;
use std::sync::Mutex;

use nook_core::services::spoken::{self, SpeechQueue};
use serde::Deserialize;
use tauri::{AppHandle, Listener, Manager};

use super::Services;
use crate::state::AppState;

#[derive(Default)]
pub struct SpeechState {
    /// Bericht-id → (Nook-id, wat er al gezegd is).
    replies: Mutex<HashMap<String, (String, SpeechQueue)>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stream {
    message_id: String,
    text: String,
}

/// Dit antwoord wordt voorgelezen (de vraag was gesproken).
pub fn follow(app: &AppHandle, nook_id: &str, message_id: &str) {
    let settings = app.state::<AppState>().settings();
    let services = app.state::<Services>();
    if !settings.speak_answers || !services.platform.speech.available() {
        return;
    }
    services.platform.speech.stop();
    services.speech.replies.lock().unwrap_or_else(|e| e.into_inner()).insert(message_id.into(), (nook_id.into(), SpeechQueue::default()));
}

fn language(app: &AppHandle, text: &str) -> &'static str {
    spoken::voice_language(&app.state::<AppState>().settings().language, text)
}

pub fn listen(app: &AppHandle) {
    let stream_app = app.clone();
    app.listen_any("nook-stream", move |event| {
        let Ok(stream) = serde_json::from_str::<Stream>(event.payload()) else { return };
        let services = stream_app.state::<Services>();
        let sentences = {
            let mut replies = services.speech.replies.lock().unwrap_or_else(|e| e.into_inner());
            let Some((_, queue)) = replies.get_mut(&stream.message_id) else { return };
            queue.feed(&stream.text)
        };
        for sentence in sentences {
            let _ = services.platform.speech.enqueue(&sentence, language(&stream_app, &sentence));
        }
    });
    let updated_app = app.clone();
    app.listen_any("nook-updated", move |event| {
        let Ok(nook_id) = serde_json::from_str::<String>(event.payload()) else { return };
        let services = updated_app.state::<Services>();
        let waiting: Vec<String> = services
            .speech
            .replies
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|(_, (n, _))| *n == nook_id)
            .map(|(id, _)| id.clone())
            .collect();
        for message_id in waiting {
            let done = updated_app.state::<AppState>().with_chat(|c| {
                c.get(&nook_id)
                    .and_then(|conv| conv.messages.iter().find(|m| m.id == message_id))
                    .filter(|m| !m.streaming)
                    .map(|m| m.text.clone())
            });
            let Some(text) = done else { continue };
            let rest =
                services.speech.replies.lock().unwrap_or_else(|e| e.into_inner()).remove(&message_id).map(|(_, mut q)| q.finish(&text));
            for sentence in rest.unwrap_or_default() {
                let _ = services.platform.speech.enqueue(&sentence, language(&updated_app, &sentence));
            }
        }
    });
}
