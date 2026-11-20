//! Calling from a chat (`ChatCallCenter`, `AppModel+ChatCall`, `ChatCallDevices` on the Mac):
//! starts a voice or video call in the chat's app (via its direct call link, chat link, or web fallback), logs it to
//! the audit trail, and follows it while it lasts by watching which program holds the microphone every two seconds.
//! The interface hears of changes through `chat-call-changed`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use nook_core::chats::call::{self, CallKind, Launch, Person, Phase, Tracker};
use nook_core::chats::ChatKind;
use nook_core::connectors::whatsapp;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;

use crate::connectors::Connectors;
use crate::services::Services;
use crate::state::AppState;

type Res<T> = Result<T, String>;

/// The microphone, sound output and camera a call uses (`ChatCallDevices` on the Mac).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallDevices {
    pub microphone: Option<String>,
    pub speaker: Option<String>,
    /// The camera that is on, `None` while none is (or unreadable).
    pub camera: Option<String>,
}

/// Snapshot of the active call sent to the interface (`ChatCallCenter.Call`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallSnapshot {
    pub id: String,
    pub chat_key: String,
    pub chat_id: String,
    pub app: String,
    pub app_name: String,
    pub name: String,
    pub kind: CallKind,
    /// True when the link jumped straight into the call (Teams, Skype); false when you press call in the app.
    pub direct: bool,
    pub started: DateTime<Utc>,
    pub phase: Phase,
    pub devices: CallDevices,
}

struct ActiveCall {
    id: String,
    chat_key: String,
    chat_id: String,
    app: String,
    app_name: String,
    name: String,
    kind: CallKind,
    direct: bool,
    programs: Vec<&'static str>,
    tracker: Tracker,
    devices: CallDevices,
    polling: Arc<AtomicBool>,
}

impl ActiveCall {
    fn snapshot(&self) -> CallSnapshot {
        CallSnapshot {
            id: self.id.clone(),
            chat_key: self.chat_key.clone(),
            chat_id: self.chat_id.clone(),
            app: self.app.clone(),
            app_name: self.app_name.clone(),
            name: self.name.clone(),
            kind: self.kind,
            direct: self.direct,
            started: self.tracker.started,
            phase: self.tracker.phase,
            devices: self.devices.clone(),
        }
    }
}

static ACTIVE: Mutex<Option<ActiveCall>> = Mutex::new(None);

fn emit_changed(app: &AppHandle, snapshot: Option<&CallSnapshot>) {
    let _ = app.emit("chat-call-changed", snapshot);
}

/// Default microphone and speaker names, read off the main thread (`cpal` on desktop).
#[cfg(desktop)]
fn read_devices() -> CallDevices {
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    let microphone = host
        .default_input_device()
        .and_then(|d| d.description().ok())
        .map(|d| d.name().to_string())
        .filter(|n| !n.is_empty());
    let speaker = host
        .default_output_device()
        .and_then(|d| d.description().ok())
        .map(|d| d.name().to_string())
        .filter(|n| !n.is_empty());
    CallDevices { microphone, speaker, camera: None }
}

#[cfg(not(desktop))]
fn read_devices() -> CallDevices {
    CallDevices::default()
}

/// Resolves who a call goes to from the shared inbox (or WhatsApp's live conversations).
fn resolve_person(c: &Connectors, key: &str) -> Option<(Person, String)> {
    let from_inbox = c.env.chats.read(|inbox| {
        inbox.threads.get(key).map(|t| {
            let is_group = t.kind == Some(ChatKind::Group) || t.members.as_ref().is_some_and(|m| m.len() > 1);
            let chat_id = t.chat_id.clone().unwrap_or_else(|| key.split_once('#').map_or(key, |(_, id)| id).to_string());
            let raw_handle = t.handle.as_deref().or((!is_group && !chat_id.is_empty()).then_some(chat_id.as_str()));
            let person = person_from_handle(&t.app, &t.name, raw_handle, is_group);
            (person, chat_id)
        })
    });
    if from_inbox.is_some() {
        return from_inbox;
    }
    if let Some(jid) = key.strip_prefix("whatsapp#") {
        let conv = c.wa(jid).conversation(jid)?;
        let person = person_from_handle(whatsapp::APP, &conv.name, (!conv.is_group).then_some(conv.id.as_str()), conv.is_group);
        return Some((person, conv.id));
    }
    None
}

fn person_from_handle(app: &str, name: &str, handle: Option<&str>, is_group: bool) -> Person {
    let mut person = Person { app: app.to_string(), name: name.to_string(), is_group, ..Default::default() };
    if is_group {
        return person;
    }
    if let Some(h) = handle.map(str::trim).filter(|s| !s.is_empty()) {
        if call::phone_digits(h).is_some() {
            person.phone = Some(h.to_string());
        } else if h.contains('@') && !h.starts_with('@') {
            person.email = Some(h.to_string());
        } else {
            person.username = Some(h.to_string());
        }
    }
    person
}

/// Programs whose microphone use counts as this call being live: the app's desktop binary plus browsers (for web calls).
fn watched_programs(app: &str) -> Vec<&'static str> {
    let mut list = call::programs(app).to_vec();
    list.extend_from_slice(call::BROWSERS);
    list
}

fn open_app_or_web(app: &AppHandle, app_id: &str) -> bool {
    if let Some(url) = call::web_url(app_id) {
        return app.opener().open_url(url, None::<&str>).is_ok();
    }
    false
}

/// Starts a voice or video call for a chat (`AppModel.startChatCall` on the Mac), audits it, and begins tracking it.
#[tauri::command]
pub async fn chat_call_start(
    app: AppHandle,
    state: State<'_, AppState>,
    c: State<'_, Connectors>,
    key: String,
    kind: CallKind,
) -> Res<CallSnapshot> {
    let (person, chat_id) = resolve_person(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    let launch = call::launch(kind, &person).ok_or_else(|| "This app does not support calls.".to_string())?;

    let mut opened = false;
    if let Some(url) = launch.url() {
        opened = app.opener().open_url(url, None::<&str>).is_ok();
    }
    if !opened {
        open_app_or_web(&app, &person.app);
    }

    let app_name = call::display_name(&person.app).to_string();
    state.store.audit("chat_call", &format!("{app_name}: {}", person.name), if kind == CallKind::Video { "video" } else { "voice" });

    let devices = tokio::task::spawn_blocking(read_devices).await.unwrap_or_default();
    let id = uuid::Uuid::new_v4().to_string();
    let polling = Arc::new(AtomicBool::new(true));
    let active = ActiveCall {
        id: id.clone(),
        chat_key: key,
        chat_id,
        app: person.app.clone(),
        app_name,
        name: person.name,
        kind,
        direct: opened && matches!(launch, Launch::Direct(_)),
        programs: watched_programs(&person.app),
        tracker: Tracker::new(Utc::now()),
        devices,
        polling: polling.clone(),
    };
    let snapshot = active.snapshot();

    {
        let mut guard = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = guard.replace(active) {
            previous.polling.store(false, Ordering::SeqCst);
        }
    }
    emit_changed(&app, Some(&snapshot));

    // Poll every 2 seconds while the call is tracked (`ChatCallCenter.interval = 2`).
    let app_handle = app.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        while polling.load(Ordering::SeqCst) {
            ticker.tick().await;
            if !polling.load(Ordering::SeqCst) {
                break;
            }
            let programs = {
                let guard = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
                match guard.as_ref() {
                    Some(a) if a.id == id => a.programs.clone(),
                    _ => break,
                }
            };
            let quiet = app_handle.state::<Services>().platform.quiet.clone();
            let (in_call, devices) = tokio::task::spawn_blocking(move || {
                let mic_apps = quiet.microphone_apps();
                let in_call = call::holds_microphone(&programs, &mic_apps);
                let devices = read_devices();
                (in_call, devices)
            })
            .await
            .unwrap_or((false, CallDevices::default()));

            let update = {
                let mut guard = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
                let Some(current) = guard.as_mut().filter(|a| a.id == id) else {
                    break;
                };
                let before_phase = current.tracker.phase;
                let before_devices = current.devices.clone();
                let still_showing = current.tracker.observe(in_call, Utc::now());
                if !still_showing {
                    current.polling.store(false, Ordering::SeqCst);
                    *guard = None;
                    Some(None)
                } else {
                    current.devices = devices;
                    if current.tracker.phase != before_phase || current.devices != before_devices {
                        Some(Some(current.snapshot()))
                    } else {
                        None
                    }
                }
            };
            if let Some(snap) = update {
                emit_changed(&app_handle, snap.as_ref());
                if snap.is_none() {
                    break;
                }
            }
        }
    });

    Ok(snapshot)
}

/// The currently tracked call, if any.
#[tauri::command]
pub fn chat_call_active() -> Option<CallSnapshot> {
    ACTIVE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(ActiveCall::snapshot)
}

/// Stops following the active call (`ChatCallCenter.dismiss`). The call itself continues in its app.
#[tauri::command]
pub fn chat_call_dismiss(app: AppHandle) {
    let mut guard = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(previous) = guard.take() {
        previous.polling.store(false, Ordering::SeqCst);
    }
    drop(guard);
    emit_changed(&app, None);
}

/// Opens the chat app for the active call or the given app id (`ChatCallCenter.showApp` / `openChatApp`).
#[tauri::command]
pub fn chat_call_open_app(app: AppHandle, app_id: Option<String>) -> Res<()> {
    let target = app_id.or_else(|| ACTIVE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|a| a.app.clone()));
    let Some(id) = target else {
        return Ok(());
    };
    if !open_app_or_web(&app, &id) {
        return Err(format!("Could not open {id}."));
    }
    Ok(())
}
