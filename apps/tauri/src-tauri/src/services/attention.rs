//! The shared attention ranking's memory (`nook_core::services::attention`, the Mac's `AttentionFeedbackStore`): what
//! you did with a notice or an item on Today is recorded here, and the views ask how welcome a source, app or subject
//! is when they rank.

use nook_core::services::attention::{AttentionEvent, AttentionFeedbackStore};
use serde::Deserialize;
use tauri::State;

pub struct Attention(pub AttentionFeedbackStore);

impl Attention {
    pub fn load() -> Self {
        Self(AttentionFeedbackStore::open_default())
    }
}

#[tauri::command]
pub fn attention_record(state: State<'_, Attention>, event: AttentionEvent, source: String, app: Option<String>, subject: Option<String>) {
    state.0.record(event, &source, app.as_deref().unwrap_or(""), subject.as_deref());
}

#[derive(Deserialize)]
pub struct WeightKey {
    source: String,
    #[serde(default)]
    app: String,
    #[serde(default)]
    subject: String,
}

/// How welcome each (source, app, subject) is, -1…1, in the order asked.
#[tauri::command]
pub fn attention_weights(state: State<'_, Attention>, keys: Vec<WeightKey>) -> Vec<f64> {
    let feedback = state.0.feedback();
    let now = chrono::Utc::now();
    keys.iter().map(|k| feedback.weight(&k.source, &k.app, (!k.subject.is_empty()).then_some(k.subject.as_str()), now)).collect()
}
