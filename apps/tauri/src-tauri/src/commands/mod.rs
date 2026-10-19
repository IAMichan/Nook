//! De commando's die de interface aanroept (`invoke`). Lange taken (een vraag aan het brein) draaien op de
//! achtergrond en melden zich met events: `nook-stream` (tekst terwijl hij geschreven wordt) en `nook-updated`.

pub mod companion;

use std::time::{Duration, Instant};

use nook_core::brain::service::{self, BrainEnv, BrainRequest};
use nook_core::brain::PromptImage;
use nook_core::nooks::{ChatMessage, Conversation, ConversationSummary, PlanState, StepState};
use nook_core::platform::Capabilities;
use nook_core::provider::{AIProvider, ProviderInfo};
use nook_core::secrets::mask;
use nook_core::settings::Settings;
use nook_core::store::{AuditEntry, OpenLoop};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::state::AppState;
use crate::tools;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    version: String,
    capabilities: Capabilities,
    brain_label: String,
    brain_local: bool,
}

#[tauri::command]
pub fn app_info(app: AppHandle, state: State<'_, AppState>) -> AppInfo {
    let s = state.settings();
    AppInfo {
        version: app.package_info().version.to_string(),
        capabilities: crate::platform::capabilities(),
        brain_label: s.brain_label(),
        brain_local: s.is_local_brain(),
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

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamEvent<'a> {
    nook_id: &'a str,
    message_id: &'a str,
    text: String,
}

/// Stelt een vraag in deze Nook. Geeft meteen het id van het antwoordbericht terug; de rest komt via events.
#[tauri::command]
pub fn ask(app: AppHandle, state: State<'_, AppState>, nook_id: String, text: String, images: Option<Vec<PromptImage>>) -> Res<String> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err("Lege vraag".into());
    }
    let images = images.unwrap_or_default();
    let mut answer = ChatMessage::nook("");
    answer.streaming = true;
    answer.status = "Denkt na…".into();
    let message_id = answer.id.clone();
    let history = state.with_chat(|c| {
        let history = c.get(&nook_id).map(|conv| conv.history(12)).unwrap_or_default();
        let mut question = ChatMessage::user(&text);
        question.images = images.iter().map(|i| format!("data:{};base64,{}", i.media_type, i.base64)).collect();
        c.push(&nook_id, question);
        c.push(&nook_id, answer);
        if let Some(conv) = c.get_mut(&nook_id) {
            conv.busy = true;
        }
        history
    });
    updated(&app, &nook_id);

    let settings = state.settings();
    let ctx = tools::ToolCtx::new(&app, &text);
    let env = BrainEnv { key: state.key_for(settings.provider), memory_gb: 16, country: None, timezone: None };
    let task_app = app.clone();
    let (nid, mid) = (nook_id.clone(), message_id.clone());
    let handle = tauri::async_runtime::spawn(async move {
        let app = task_app;
        let request = BrainRequest {
            text: text.clone(),
            history,
            context: tools::context(&ctx).await,
            screen: None,
            images,
            tools: tools::tools(&ctx),
        };
        let last = std::sync::Mutex::new(Instant::now() - Duration::from_secs(1));
        let emit = |partial: String| {
            let mut guard = last.lock().unwrap_or_else(|e| e.into_inner());
            if guard.elapsed() < Duration::from_millis(40) {
                return;
            }
            *guard = Instant::now();
            let _ = app.emit("nook-stream", StreamEvent { nook_id: &nid, message_id: &mid, text: partial });
        };
        let result = service::run(&settings, &env, request, Some(&emit)).await;
        let state = app.state::<AppState>();
        state.with_chat(|c| {
            let is_active = c.active_id.as_deref() == Some(nid.as_str());
            let Some(conv) = c.get_mut(&nid) else { return };
            conv.busy = false;
            if !is_active {
                conv.unread = true;
            }
            let Some(msg) = conv.messages.iter_mut().find(|m| m.id == mid) else { return };
            msg.streaming = false;
            msg.status.clear();
            match result {
                Ok(plan) => {
                    let (body, offers) = service::split_offers(&plan.text);
                    msg.text = body;
                    msg.offers = offers;
                    if !plan.actions.is_empty() {
                        msg.action_included = vec![true; plan.actions.len()];
                        msg.action_states = vec![StepState::Pending; plan.actions.len()];
                        msg.plan_state = Some(PlanState::Pending);
                        msg.actions = plan.actions;
                        if msg.text.is_empty() {
                            msg.text = "Dit is mijn voorstel. Er gebeurt niets tot je op Uitvoeren klikt.".into();
                        }
                    }
                    if msg.text.is_empty() {
                        msg.text = "Ik heb hier geen antwoord op gekregen. Probeer het nog eens of kies een ander brein.".into();
                        msg.is_error = true;
                    }
                }
                Err(e) => {
                    msg.text = e.0;
                    msg.is_error = true;
                }
            }
        });
        state.running.lock().unwrap_or_else(|e| e.into_inner()).remove(&nid);
        state.save_chat();
        updated(&app, &nid);
    });
    state.running.lock().unwrap_or_else(|e| e.into_inner()).insert(nook_id, handle.inner().abort_handle());
    Ok(message_id)
}

/// Stopt de lopende vraag in deze Nook.
#[tauri::command]
pub fn stop(app: AppHandle, state: State<'_, AppState>, nook_id: String) {
    if let Some(handle) = state.running.lock().unwrap_or_else(|e| e.into_inner()).remove(&nook_id) {
        handle.abort();
    }
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(&nook_id) {
            conv.busy = false;
            for m in conv.messages.iter_mut().filter(|m| m.streaming) {
                m.streaming = false;
                m.status.clear();
                if m.text.is_empty() {
                    m.text = "Gestopt.".into();
                }
            }
        }
    });
    state.save_chat();
    updated(&app, &nook_id);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanStep {
    tool: String,
    summary: String,
}

#[tauri::command]
pub fn plan_steps(state: State<'_, AppState>, nook_id: String, message_id: String) -> Vec<PlanStep> {
    state.with_chat(|c| {
        c.get(&nook_id)
            .and_then(|conv| conv.messages.iter().find(|m| m.id == message_id))
            .map(|m| m.actions.iter().map(|a| PlanStep { tool: a.tool.clone(), summary: tools::summarize(&a.tool, &a.input) }).collect())
            .unwrap_or_default()
    })
}

/// Voert de goedgekeurde stappen van een plan uit. Een stap die al eerder gelukt is, wordt niet herhaald.
#[tauri::command]
pub async fn execute_plan(
    app: AppHandle,
    state: State<'_, AppState>,
    nook_id: String,
    message_id: String,
    included: Vec<bool>,
    inputs: Option<Vec<Value>>,
) -> Res<()> {
    let actions = state.with_chat(|c| {
        let msg = c.get_mut(&nook_id)?.messages.iter_mut().find(|m| m.id == message_id)?;
        if let Some(inputs) = &inputs {
            for (a, input) in msg.actions.iter_mut().zip(inputs) {
                a.input = input.clone();
            }
        }
        msg.action_included = included.clone();
        msg.plan_state = Some(PlanState::Running);
        Some(msg.actions.clone())
    });
    let Some(actions) = actions else { return Err("Dit plan bestaat niet meer.".into()) };
    updated(&app, &nook_id);
    let store = state.store.clone();
    let ctx = tools::ToolCtx::new(&app, "");
    let mut failed = None;
    for (index, action) in actions.iter().enumerate() {
        let step = if !included.get(index).copied().unwrap_or(true) {
            StepState::Skipped
        } else {
            let key = format!("{}:{}", action.tool, action.input);
            if let Some(when) = store.executed_action(&key, 600) {
                StepState::Duplicate(when.with_timezone(&chrono::Local).format("%H:%M").to_string())
            } else {
                match tools::execute(&ctx, &action.tool, &action.input).await {
                    Ok(result) => {
                        store.record_executed(&key, &action.tool, &result);
                        store.audit(&action.tool, &action.input.to_string(), &result);
                        StepState::Done(result)
                    }
                    Err(e) => {
                        store.audit(&action.tool, &action.input.to_string(), &format!("fout: {e}"));
                        failed.get_or_insert(e.clone());
                        StepState::Failed(e)
                    }
                }
            }
        };
        state.with_chat(|c| {
            if let Some(m) = c.get_mut(&nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) {
                if m.action_states.len() < actions.len() {
                    m.action_states.resize(actions.len(), StepState::Pending);
                }
                m.action_states[index] = step;
            }
        });
        updated(&app, &nook_id);
    }
    state.with_chat(|c| {
        if let Some(m) = c.get_mut(&nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) {
            m.plan_state = Some(match &failed {
                Some(e) => PlanState::Failed(e.clone()),
                None => PlanState::Done("Klaar".into()),
            });
        }
    });
    state.save_chat();
    updated(&app, &nook_id);
    Ok(())
}

#[tauri::command]
pub fn cancel_plan(app: AppHandle, state: State<'_, AppState>, nook_id: String, message_id: String) {
    state.with_chat(|c| {
        if let Some(m) = c.get_mut(&nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) {
            m.plan_state = Some(PlanState::Cancelled);
        }
    });
    state.save_chat();
    updated(&app, &nook_id);
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
