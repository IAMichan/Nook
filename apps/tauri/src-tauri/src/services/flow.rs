//! Flow, dicteren overal: houd de toets vast, spreek, laat los, en de woorden staan waar je typt. Twee keer tikken is
//! handsfree tot de volgende tik. Nook zet de woordenlijst, vervangingen en snippets erin en schoont de tekst op met
//! je eigen brein (niet in terminals en editors), en houdt een geschiedenis bij (`FlowDictation` op de Mac).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::services::flow::{self, cleanup, FlowAction, FlowKeyLogic, FlowStyle};
use nook_core::services::rewrite;
use tauri::{AppHandle, Manager};

use super::voice::{self, Purpose, VoiceEvent};
use super::Services;
use crate::state::AppState;

pub struct FlowState {
    logic: Mutex<FlowKeyLogic>,
    epoch: Instant,
    /// De app waarin geplakt wordt, vastgelegd bij het begin.
    target: Mutex<Option<(String, String)>>,
}

impl Default for FlowState {
    fn default() -> Self {
        Self { logic: Mutex::new(FlowKeyLogic::default()), epoch: Instant::now(), target: Mutex::new(None) }
    }
}

fn now(state: &FlowState) -> f64 {
    state.epoch.elapsed().as_secs_f64()
}

fn apply(app: &AppHandle, action: FlowAction) {
    let services = app.state::<Services>();
    match action {
        FlowAction::Start | FlowAction::Restart => {
            if action == FlowAction::Restart {
                voice::cancel(app);
            }
            let target = services.platform.screen.active_app().map(|a| (a.id, a.name));
            *services.flow_state.target.lock().unwrap_or_else(|e| e.into_inner()) = target;
            if let Err(e) = voice::start(app, Purpose::Flow) {
                services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).reset();
                voice::emit(app, Purpose::Flow, VoiceEvent { phase: "error".into(), error: Some(e), ..Default::default() });
            }
        }
        FlowAction::Finish => voice::request_finish(app),
        FlowAction::Cancel => voice::cancel(app),
        FlowAction::Lock | FlowAction::None => {}
    }
}

pub fn key_down(app: &AppHandle) {
    let services = app.state::<Services>();
    let action = services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).key_down(now(&services.flow_state));
    apply(app, action);
}

pub fn key_up(app: &AppHandle) {
    let services = app.state::<Services>();
    let action = services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).key_up(now(&services.flow_state));
    apply(app, action);
    // Een korte tik wacht op een tweede; komt die niet, dan vervalt hij.
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs_f64(flow::DOUBLE_TAP_WINDOW + 0.05));
        let services = app.state::<Services>();
        let action = services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).tick(now(&services.flow_state));
        apply(&app, action);
    });
}

/// Esc of de knop in de pil.
pub fn cancel(app: &AppHandle) {
    let services = app.state::<Services>();
    let action = services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).escape();
    apply(app, action);
    voice::cancel(app);
}

/// Handsfree beginnen vanuit de interface.
pub fn start_hands_free(app: &AppHandle) {
    let services = app.state::<Services>();
    let action = {
        let mut logic = services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner());
        let action = logic.key_down(now(&services.flow_state));
        logic.lock();
        action
    };
    apply(app, action);
}

/// Wat er gehoord is: in vorm brengen en plakken waar je typt.
pub async fn deliver(app: &AppHandle, heard: &str, seconds: f64) {
    let services = app.state::<Services>();
    services.flow_state.logic.lock().unwrap_or_else(|e| e.into_inner()).reset();
    if heard.trim().is_empty() {
        voice::emit(app, Purpose::Flow, VoiceEvent { phase: "idle".into(), result: Some(String::new()), ..Default::default() });
        return;
    }
    let target = services.flow_state.target.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let text = shape(app, heard, target.as_ref()).await;
    let system = services.platform.system.clone();
    let paste_text = text.clone();
    let pasted = tauri::async_runtime::spawn_blocking(move || system.paste_text(&paste_text)).await.unwrap_or_else(|e| Err(e.to_string()));
    services.flow.lock().unwrap_or_else(|e| e.into_inner()).record(
        &text,
        target.as_ref().map(|t| t.1.as_str()),
        seconds,
        chrono::Utc::now(),
    );
    match pasted {
        Ok(true) => voice::emit(app, Purpose::Flow, VoiceEvent { phase: "idle".into(), result: Some(text), seconds, ..Default::default() }),
        Ok(false) => voice::emit(
            app,
            Purpose::Flow,
            VoiceEvent {
                phase: "error".into(),
                error: Some("Gekopieerd: plak het zelf met Ctrl+V.".into()),
                result: Some(text),
                seconds,
                ..Default::default()
            },
        ),
        Err(e) => voice::emit(
            app,
            Purpose::Flow,
            VoiceEvent {
                phase: "error".into(),
                error: Some(format!("Plakken lukte niet: {e}")),
                result: Some(text),
                seconds,
                ..Default::default()
            },
        ),
    }
}

/// De woordenlijst erin, en opschonen met het brein als dat aanstaat en het geen terminal of editor is.
async fn shape(app: &AppHandle, heard: &str, target: Option<&(String, String)>) -> String {
    let services = app.state::<Services>();
    let (prepared, settings, style, words) = {
        let store = services.flow.lock().unwrap_or_else(|e| e.into_inner());
        (store.prepare(heard), store.settings.clone(), store.style(target.map(|t| t.0.as_str())), store.words.clone())
    };
    let transform = settings.prompt_mode || !settings.translate_to.is_empty();
    let body = prepared.text.clone();
    let wants = transform || (settings.cleanup && style != FlowStyle::Verbatim && flow::word_count(&body) >= 3);
    if wants && !body.is_empty() {
        let brain = app.state::<AppState>().settings();
        let key = app.state::<AppState>().key_for(brain.provider);
        let language = (!settings.translate_to.is_empty()).then_some(settings.translate_to.as_str());
        let system = cleanup::system(style, settings.prompt_mode, language, target.map(|t| t.1.as_str()), &words);
        let timeout = Duration::from_secs(if settings.prompt_mode { 15 } else { 6 });
        let reply = tokio::time::timeout(timeout, rewrite::complete(&brain, key, &system, &cleanup::prompt(&body), 2048)).await;
        if let Ok(Ok(reply)) = reply {
            let out = cleanup::clean(&reply);
            let plausible =
                if transform { cleanup::plausible_transform(&out, &body, settings.prompt_mode) } else { cleanup::plausible(&out, &body) };
            if plausible && flow::keeps_marks(&out, &prepared.snippets) {
                return flow::finish(&out, &prepared.snippets);
            }
        }
    }
    flow::finish(&body, &prepared.snippets)
}
