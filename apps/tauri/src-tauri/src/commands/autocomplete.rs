//! The commands of Settings › Autocomplete: status, statistics, seen apps, pausing, the local models and the Playground.

use tauri::{AppHandle, State};

use crate::services::autocomplete::{self, Autocomplete, PlaygroundResult, View};

#[tauri::command]
pub fn autocomplete_view(state: State<'_, Autocomplete>) -> View {
    state.view()
}

#[tauri::command]
pub fn autocomplete_pause(app: AppHandle, state: State<'_, Autocomplete>, minutes: Option<u64>) -> View {
    state.pause(minutes);
    #[cfg(desktop)]
    crate::platform::tray_live::refresh(&app);
    #[cfg(not(desktop))]
    let _ = app;
    state.view()
}

#[tauri::command]
pub fn autocomplete_resume(app: AppHandle, state: State<'_, Autocomplete>) -> View {
    state.resume();
    #[cfg(desktop)]
    crate::platform::tray_live::refresh(&app);
    #[cfg(not(desktop))]
    let _ = app;
    state.view()
}

#[tauri::command]
pub fn autocomplete_reset_stats(app: AppHandle, state: State<'_, Autocomplete>) -> View {
    state.reset_stats();
    #[cfg(desktop)]
    crate::platform::tray_live::refresh(&app);
    #[cfg(not(desktop))]
    let _ = app;
    state.view()
}

#[tauri::command]
pub async fn autocomplete_models(app: AppHandle) -> Result<Vec<String>, String> {
    autocomplete::local_models(&app).await
}

#[tauri::command]
pub async fn autocomplete_playground(app: AppHandle, before: String, continuing: bool) -> Result<Option<PlaygroundResult>, String> {
    autocomplete::playground(&app, before, continuing).await
}

#[tauri::command]
pub fn autocomplete_playground_cancel(app: AppHandle) {
    autocomplete::cancel_playground(&app);
}

#[tauri::command]
pub fn autocomplete_emoji(app: AppHandle, text: String) -> Option<autocomplete::EmojiChoices> {
    autocomplete::playground_emoji(&app, &text)
}
