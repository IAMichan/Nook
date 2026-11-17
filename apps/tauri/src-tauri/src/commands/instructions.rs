//! Settings › Instructions beyond the answer style (`InstructionStore` on the Mac): the saved prompts, the spaces, and
//! the context of the last answer for the inspector. The logic is in `nook_core::prompt_library`; this keeps the files
//! (`prompts.json`, `spaces.json` in Nook's folder) and tells the interface (`instructions-changed`).

use std::path::PathBuf;
use std::sync::Mutex;

use nook_core::prompt_library::{self as library, ContextBreakdown, NookSpace, NookSpaceBook, PromptLibrary, SavedPrompt};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

pub struct InstructionsState {
    prompts: Mutex<PromptLibrary>,
    spaces: Mutex<NookSpaceBook>,
    last: Mutex<Option<ContextBreakdown>>,
}

fn prompts_file() -> PathBuf {
    nook_core::paths::support_directory().join("prompts.json")
}

fn spaces_file() -> PathBuf {
    nook_core::paths::support_directory().join("spaces.json")
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl InstructionsState {
    pub fn load() -> Self {
        Self {
            prompts: Mutex::new(library::load(&prompts_file())),
            spaces: Mutex::new(library::load(&spaces_file())),
            last: Mutex::new(None),
        }
    }

    /// The space's instruction block for a conversation, empty when it is in none or the space has no instructions.
    pub fn space_text(&self, conversation: &str) -> String {
        lock(&self.spaces).space_of(conversation).map(NookSpace::context_text).unwrap_or_default()
    }
}

/// Notes what the model read for the last answer, for the inspector.
pub fn note_context(app: &AppHandle, breakdown: ContextBreakdown) {
    let Some(state) = app.try_state::<InstructionsState>() else { return };
    let mut last = lock(&state.last);
    if last.as_ref() != Some(&breakdown) {
        *last = Some(breakdown);
        drop(last);
        let _ = app.emit("instructions-changed", ());
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceView {
    #[serde(flatten)]
    space: NookSpace,
    conversations: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstructionsView {
    prompts: Vec<SavedPrompt>,
    spaces: Vec<SpaceView>,
    last_context: Option<ContextBreakdown>,
}

#[tauri::command]
pub fn instructions_view(state: State<'_, InstructionsState>) -> InstructionsView {
    let book = lock(&state.spaces);
    InstructionsView {
        prompts: lock(&state.prompts).prompts.clone(),
        spaces: book.spaces.iter().map(|s| SpaceView { space: s.clone(), conversations: book.conversations_in(s.id) }).collect(),
        last_context: lock(&state.last).clone(),
    }
}

fn changed(app: &AppHandle) {
    let _ = app.emit("instructions-changed", ());
}

/// Saves a new prompt; false when it has no name or no text.
#[tauri::command]
pub fn prompt_save(
    app: AppHandle,
    state: State<'_, InstructionsState>,
    title: String,
    body: String,
    trigger: String,
) -> Result<bool, String> {
    let mut prompts = lock(&state.prompts);
    if !prompts.save(SavedPrompt::new(&title, &body, &trigger)) {
        return Ok(false);
    }
    library::save(&*prompts, &prompts_file()).map_err(|e| e.to_string())?;
    drop(prompts);
    changed(&app);
    Ok(true)
}

#[tauri::command]
pub fn prompt_remove(app: AppHandle, state: State<'_, InstructionsState>, id: Uuid) -> Result<(), String> {
    let mut prompts = lock(&state.prompts);
    prompts.remove(id);
    library::save(&*prompts, &prompts_file()).map_err(|e| e.to_string())?;
    drop(prompts);
    changed(&app);
    Ok(())
}

/// Adds a space (no id) or changes one (its name and instructions).
#[tauri::command]
pub fn space_save(
    app: AppHandle,
    state: State<'_, InstructionsState>,
    id: Option<Uuid>,
    name: String,
    instructions: String,
) -> Result<(), String> {
    let mut book = lock(&state.spaces);
    let mut space = id.and_then(|id| book.spaces.iter().find(|s| s.id == id).cloned()).unwrap_or_else(|| NookSpace::new(&name));
    space.name = name;
    space.instructions = instructions;
    book.save(space);
    library::save(&*book, &spaces_file()).map_err(|e| e.to_string())?;
    drop(book);
    changed(&app);
    Ok(())
}

#[tauri::command]
pub fn space_remove(app: AppHandle, state: State<'_, InstructionsState>, id: Uuid) -> Result<(), String> {
    let mut book = lock(&state.spaces);
    book.remove(id);
    library::save(&*book, &spaces_file()).map_err(|e| e.to_string())?;
    drop(book);
    changed(&app);
    Ok(())
}
