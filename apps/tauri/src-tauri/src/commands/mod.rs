//! De commando's die de interface aanroept (`invoke`). Lange taken (een vraag aan het brein) draaien op de
//! achtergrond en melden zich met events: `nook-stream` (tekst terwijl hij geschreven wordt) en `nook-updated`.

pub mod agents;
pub mod brain;
pub mod chat;
pub mod companion;
pub mod plans;
pub mod workspace;
pub mod workspace_tools;

use nook_core::brain::PromptImage;
use nook_core::nooks::{Conversation, ConversationSummary};
use nook_core::platform::Capabilities;
use nook_core::provider::{AIProvider, ProviderInfo};
use nook_core::secrets::mask;
use nook_core::settings::Settings;
use nook_core::store::{AuditEntry, OpenLoop};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::state::AppState;

pub mod connectors;
pub mod services;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    version: String,
    capabilities: Capabilities,
    brain_label: String,
    brain_local: bool,
    /// Het geheugen van deze computer in GB, voor het modeladvies.
    memory_gb: u64,
    /// Het gekozen brein kan denken (sleutel, model of programma aanwezig).
    brain_ready: bool,
}

#[tauri::command]
pub fn app_info(app: AppHandle, state: State<'_, AppState>) -> AppInfo {
    let s = state.settings();
    AppInfo {
        version: app.package_info().version.to_string(),
        capabilities: crate::platform::capabilities(),
        brain_label: s.brain_label(),
        brain_local: s.is_local_brain(),
        memory_gb: crate::brain::memory_gb(),
        brain_ready: nook_core::brain::service::brain_ready(&s, state.key_for(s.provider).is_some_and(|k| !k.is_empty())),
    }
}

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> Settings {
    state.settings()
}

#[tauri::command]
pub fn save_settings(app: AppHandle, state: State<'_, AppState>, settings: Settings) -> Settings {
    #[cfg(desktop)]
    let before = state.settings();
    let saved = state.update_settings(|s| *s = settings);
    #[cfg(desktop)]
    {
        if before.shortcuts != saved.shortcuts {
            crate::platform::desktop::register_shortcuts(&app);
        }
        if before.placement != saved.placement || before.panel_large != saved.panel_large {
            crate::platform::desktop::place_bar(&app, false);
        }
    }
    let _ = app.emit("settings-changed", &saved);
    saved
}

#[tauri::command]
pub fn providers() -> Vec<ProviderInfo> {
    AIProvider::ALL.into_iter().map(ProviderInfo::from).collect()
}

fn provider(id: &str) -> Res<AIProvider> {
    AIProvider::from_id(id).ok_or_else(|| format!("Onbekende dienst {id}"))
}

#[tauri::command]
pub async fn list_models(state: State<'_, AppState>, provider_id: String) -> Res<Vec<String>> {
    let p = provider(&provider_id)?;
    let key = state.key_for(p);
    p.list_models(key.as_deref()).await.map_err(|e| e.0)
}

/// De sleutel, gemaskeerd, of niets.
#[tauri::command]
pub fn key_status(state: State<'_, AppState>, provider_id: String) -> Res<Option<String>> {
    Ok(state.key_for(provider(&provider_id)?).map(|k| mask(&k)))
}

#[tauri::command]
pub fn set_key(app: AppHandle, state: State<'_, AppState>, provider_id: String, key: String) -> Res<Option<String>> {
    let p = provider(&provider_id)?;
    state.secrets.write(&p.key_account(), &key)?;
    let _ = app.emit("settings-changed", state.settings());
    Ok(state.key_for(p).map(|k| mask(&k)))
}

// Nooks

fn updated(app: &AppHandle, id: &str) {
    let _ = app.emit("nook-updated", id);
}

#[tauri::command]
pub fn nooks_list(state: State<'_, AppState>, archived: bool) -> Vec<ConversationSummary> {
    state.with_chat(|c| c.list(archived))
}

#[tauri::command]
pub fn nooks_search(state: State<'_, AppState>, query: String) -> Vec<ConversationSummary> {
    state.with_chat(|c| c.search(&query))
}

#[tauri::command]
pub fn nook_get(state: State<'_, AppState>, id: String) -> Option<Conversation> {
    state.with_chat(|c| {
        let found = c.get(&id).cloned();
        if found.is_some() {
            c.active_id = Some(id.clone());
            if let Some(conv) = c.get_mut(&id) {
                conv.unread = false;
            }
        }
        found
    })
}

#[tauri::command]
pub fn nook_active(state: State<'_, AppState>) -> String {
    state.with_chat(|c| c.active_or_new())
}

#[tauri::command]
pub fn nook_new(app: AppHandle, state: State<'_, AppState>) -> String {
    let id = state.with_chat(|c| c.new_conversation());
    updated(&app, &id);
    id
}

#[tauri::command]
pub fn nook_delete(app: AppHandle, state: State<'_, AppState>, id: String) {
    state.with_chat(|c| c.remove(&id));
    state.save_chat();
    updated(&app, &id);
}

#[tauri::command]
pub fn nook_set_flags(app: AppHandle, state: State<'_, AppState>, id: String, pinned: Option<bool>, archived: Option<bool>) {
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(&id) {
            if let Some(p) = pinned {
                conv.pinned = p;
            }
            if let Some(a) = archived {
                conv.archived = a;
            }
        }
    });
    state.save_chat();
    updated(&app, &id);
}

/// Stelt een vraag in deze Nook. Geeft meteen het id van het antwoord terug (niets bij een snelle opdracht); de rest
/// komt via events.
#[tauri::command]
pub fn ask(
    app: AppHandle,
    nook_id: String,
    text: String,
    images: Option<Vec<PromptImage>>,
    attachment: Option<chat::Attachment>,
) -> Res<Option<String>> {
    chat::ask(&app, &nook_id, &text, images.unwrap_or_default(), attachment)
}

/// Stopt de lopende vraag in deze Nook.
#[tauri::command]
pub fn stop(app: AppHandle, nook_id: String) {
    chat::stop(&app, &nook_id);
}

#[tauri::command]
pub fn plan_steps(app: AppHandle, nook_id: String, message_id: String) -> Vec<plans::PlanStep> {
    plans::plan_steps(&app, &nook_id, &message_id)
}

/// Voert de goedgekeurde stappen van een plan uit. Een stap die al eerder gelukt is, wordt niet herhaald.
#[tauri::command]
pub async fn execute_plan(app: AppHandle, nook_id: String, message_id: String, included: Vec<bool>, inputs: Option<Vec<Value>>) -> Res<()> {
    plans::run_plan(&app, &nook_id, &message_id, &included, inputs, &[]).await
}

#[tauri::command]
pub fn cancel_plan(app: AppHandle, nook_id: String, message_id: String) {
    plans::cancel(&app, &nook_id, &message_id);
}

#[tauri::command]
pub fn open_loops(state: State<'_, AppState>) -> Vec<OpenLoop> {
    state.store.open_loops()
}

#[tauri::command]
pub fn complete_loop(state: State<'_, AppState>, id: String) {
    state.store.complete_loop(&id);
}

#[tauri::command]
pub fn audit_entries(state: State<'_, AppState>, query: String) -> Vec<AuditEntry> {
    state.store.audit_entries(200, &query)
}

#[tauri::command]
pub fn clear_audit(state: State<'_, AppState>) {
    state.store.clear_audit();
}

// Vensters

#[tauri::command]
pub fn bar_expand(app: AppHandle, expanded: bool) {
    #[cfg(desktop)]
    crate::platform::desktop::place_bar(&app, expanded);
    #[cfg(not(desktop))]
    let _ = (app, expanded);
}

#[tauri::command]
pub fn show_main(app: AppHandle, route: String) {
    #[cfg(desktop)]
    crate::platform::desktop::show_main(&app, &route);
    #[cfg(not(desktop))]
    let _ = (app, route);
}

/// De route die het hoofdvenster moet tonen, één keer.
#[tauri::command]
pub fn take_route(state: State<'_, AppState>) -> Option<String> {
    state.pending_route.lock().unwrap_or_else(|e| e.into_inner()).take()
}

/// Zwevende stand: onthoud waar de gebruiker de balk neerzette, als afstand tot het midden van het scherm.
#[tauri::command]
pub fn bar_moved(app: AppHandle, state: State<'_, AppState>) {
    let Some(window) = app.get_webview_window("bar") else { return };
    let (Ok(pos), Ok(size), Ok(Some(monitor))) = (window.outer_position(), window.outer_size(), window.current_monitor()) else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let center = (area.position.x as f64 + area.size.width as f64 / 2.0) / scale;
    let x = pos.x as f64 / scale + size.width as f64 / scale / 2.0 - center;
    let y = (pos.y - area.position.y) as f64 / scale;
    state.update_settings(|s| {
        s.float_x = Some(x);
        s.float_y = Some(y.max(0.0));
    });
}
