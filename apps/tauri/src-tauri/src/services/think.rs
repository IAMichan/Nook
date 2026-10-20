//! Meekijken (Alt+Ctrl+N: het voorste venster lezen en een afspraak, belofte of taak voorstellen) en meedenken
//! (Instellingen › Assistent: als je een tijdje met iets bezig bent, biedt Nook zelf hulp aan als korte zin naast de
//! balk, met Doe maar, Nee en Niet in deze app). Zelfde voorbereiding als een gewone vraag; er gebeurt niets zonder
//! klik.

use std::time::Duration;

use nook_core::brain::service::{self, BrainEnv, BrainRequest};
use nook_core::brain::BrainPlan;
use nook_core::nooks::{ChatMessage, Conversation, PlanState, StepState};
use nook_core::services::screen::ScreenSnapshot;
use nook_core::services::think_along::{self, Nudge};
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;
use crate::tools;

/// Vraagt het brein wat het ziet. `None` als het niets zag of het brein niet bereikbaar is.
async fn ask_brain(app: &AppHandle, request: &str, snapshot: &ScreenSnapshot) -> Result<Option<(String, Vec<String>, BrainPlan)>, String> {
    let state = app.state::<AppState>();
    let settings = state.settings();
    let ctx = tools::ToolCtx::new(app, request);
    let env = BrainEnv { key: state.key_for(settings.provider), memory_gb: 16, country: None, timezone: None };
    let brain_request = BrainRequest {
        text: request.into(),
        history: vec![],
        context: tools::context(&ctx).await,
        screen: Some((format!("{} — {}", snapshot.app_name, snapshot.window_title), snapshot.text.clone())),
        images: vec![],
        tools: tools::tools(&ctx),
        own_request: true,
    };
    let plan = service::run(&settings, &env, brain_request, None).await.map_err(|e| e.0)?;
    let (mut body, offers) = service::split_offers(&plan.text);
    if think_along::is_none(&body) {
        body.clear();
    }
    if body.is_empty() && plan.actions.is_empty() {
        return Ok(None);
    }
    Ok(Some((body, offers, plan)))
}

/// Een voorstel gaat verder in een eigen Nook: het wordt Nooks bericht met de plankaart. `run`: meteen uitvoeren
/// (de klik op Doe maar is de toestemming).
pub async fn continue_in_chat(
    app: &AppHandle,
    text: &str,
    actions: Vec<nook_core::brain::PlannedAction>,
    sources: Vec<String>,
    offers: Vec<String>,
    run: bool,
) {
    let state = app.state::<AppState>();
    let id = state.with_chat(|c| c.new_conversation());
    let mut message = ChatMessage::nook(text);
    message.sources = sources;
    message.offers = offers;
    let count = actions.len();
    if count > 0 {
        message.action_included = vec![true; count];
        message.action_states = vec![StepState::Pending; count];
        message.plan_state = Some(PlanState::Pending);
        message.actions = actions;
    }
    let message_id = message.id.clone();
    state.with_chat(|c| {
        c.push(&id, message);
        if let Some(conv) = c.get_mut(&id) {
            conv.title = Conversation::title_from(&think_along::nudge_line(text, Some("Voorstel van Nook")));
        }
        c.active_id = Some(id.clone());
    });
    state.save_chat();
    super::emit(app, "nook-updated", id.clone());
    // De balk opent op deze Nook.
    #[cfg(desktop)]
    crate::platform::desktop::open_bar(app, &format!("nook:{id}"));
    if run && count > 0 {
        let _ = crate::commands::execute_plan(app.clone(), id, message_id, vec![true; count], None).await;
    }
}

/// Meekijken: leest het voorste venster en stelt iets voor. Altijd een antwoord in de chat, ook als er niets is.
pub async fn look_along(app: &AppHandle) -> Result<(), String> {
    if !super::screen::allowed(app) {
        return Err("Je scherm staat op ‘alleen op deze computer’, dus een externe AI kijkt niet mee. Kies een lokaal brein, of haal het scherm weg bij Instellingen › Privacy.".into());
    }
    let services = app.state::<Services>();
    let screen = services.platform.screen.clone();
    let front = tauri::async_runtime::spawn_blocking(move || screen.frontmost()).await.map_err(|e| e.to_string())?;
    let Some(front) = front.filter(|f| !f.text.trim().is_empty()) else {
        let status = services.platform.screen.status();
        return Err(if status.is_empty() { "Ik zie niets om te lezen.".into() } else { status });
    };
    let snapshot =
        ScreenSnapshot { app_name: front.app.clone(), window_title: front.title.clone(), text: front.text.chars().take(6000).collect() };
    let saw = front.app.clone();
    match ask_brain(app, think_along::LOOK_REQUEST, &snapshot).await? {
        Some((body, offers, plan)) => {
            let text = if body.is_empty() { "Dit is mijn voorstel. Er gebeurt niets tot je op Uitvoeren klikt.".to_string() } else { body };
            continue_in_chat(app, &text, plan.actions, vec![saw], offers, false).await;
        }
        None => continue_in_chat(app, "Ik zie niets waar je iets aan hebt.", vec![], vec![saw], vec![], false).await,
    }
    Ok(())
}

/// Elke paar seconden: is het tijd om mee te denken?
#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let settings = app.state::<AppState>().settings();
            if !settings.auto_watch || !super::screen::allowed(&app) {
                continue;
            }
            let services = app.state::<Services>();
            if !services.platform.screen.available() || super::voice::is_listening(&app) {
                continue;
            }
            // Een aanbod dat nog naast de balk staat: niet nog een.
            if services
                .nudge
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|n| n.still_fresh(chrono::Utc::now().timestamp()) && super::windows::aside_open(&app))
            {
                continue;
            }
            let Some((_, front)) = super::screen::cached(&app) else { continue };
            let Some(active) = services.platform.screen.active_app() else { continue };
            let (window, print) = match front {
                Some((_, title, print)) => (title, print),
                None => (active.title.clone(), (chrono::Utc::now().timestamp() / 300) as u64),
            };
            let muted = services.prefs().think_along_muted;
            let idle = services.platform.screen.idle_seconds();
            let now = services.now();
            let look = services.think.lock().unwrap_or_else(|e| e.into_inner()).should_look(&active.id, &window, print, idle, &muted, now);
            if !look {
                continue;
            }
            services.think.lock().unwrap_or_else(|e| e.into_inner()).did_look(&active.id, &window, print, now);
            run(&app, &active.id, &active.name, &window).await;
        }
    });
}

async fn run(app: &AppHandle, app_id: &str, app_name: &str, window: &str) {
    // A look every few minutes would otherwise keep a local model's gigabytes in memory most of the time: when this
    // run had to load it, it gives it back right after.
    let settings = app.state::<AppState>().settings();
    let local_model = (settings.provider == nook_core::provider::AIProvider::Ollama && !settings.active_model().is_empty())
        .then(|| (nook_core::brain::conversations::ollama_base_url(), settings.active_model()));
    let was_loaded = match &local_model {
        Some((base, model)) => nook_core::brain::conversations::ollama_is_loaded(base, model).await.unwrap_or(true),
        None => true,
    };
    look_and_offer(app, app_id, app_name, window).await;
    if let (false, Some((base, model))) = (was_loaded, &local_model) {
        nook_core::brain::conversations::ollama_unload(base, model).await;
    }
}

async fn look_and_offer(app: &AppHandle, app_id: &str, app_name: &str, window: &str) {
    let snap_app = app.clone();
    let Ok(Ok(snapshot)) = tauri::async_runtime::spawn_blocking(move || super::screen::snapshot(&snap_app, false)).await else { return };
    let services = app.state::<Services>();
    let earlier = services.think.lock().unwrap_or_else(|e| e.into_inner()).recent_offers(services.now());
    let request = think_along::request(app_name, window, &earlier);
    let Ok(Some((body, offers, plan))) = ask_brain(app, &request, &snapshot).await else { return };
    let fallback = plan.actions.first().map(|a| format!("Zal ik dit doen? {}", tools::summarize(&a.tool, &a.input)));
    let line = think_along::nudge_line(&body, fallback.as_deref());
    if line.is_empty() || services.think.lock().unwrap_or_else(|e| e.into_inner()).already_offered(&line, services.now()) {
        return;
    }
    services.think.lock().unwrap_or_else(|e| e.into_inner()).did_offer(&line, services.now());
    let nudge = Nudge {
        id: uuid::Uuid::new_v4().to_string(),
        line,
        body,
        app: app_name.into(),
        window: app_id.into(),
        steps: plan.actions.iter().map(|a| tools::summarize(&a.tool, &a.input)).collect(),
        actions: plan.actions,
        offers,
        date: chrono::Utc::now().timestamp(),
    };
    *services.nudge.lock().unwrap_or_else(|e| e.into_inner()) = Some(nudge.clone());
    super::emit(app, "nudge", Some(nudge));
    #[cfg(desktop)]
    super::windows::show_aside(app);
}

/// Het antwoord op een aanbod: "yes" (Doe maar), "no" (Nee), "mute" (Niet in deze app), "later" (weg, maar het blijft in
/// Vandaag staan).
pub async fn answer(app: &AppHandle, id: &str, answer: &str) -> Result<(), String> {
    let services = app.state::<Services>();
    let nudge = {
        let guard = services.nudge.lock().unwrap_or_else(|e| e.into_inner());
        guard.as_ref().filter(|n| n.id == id).cloned()
    };
    let Some(nudge) = nudge else { return Err("Dit aanbod is er niet meer.".into()) };
    if answer != "later" {
        *services.nudge.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
    super::emit(app, "nudge", None::<Nudge>);
    #[cfg(desktop)]
    super::windows::hide_aside(app);
    match answer {
        "yes" => {
            services.think.lock().unwrap_or_else(|e| e.into_inner()).accepted();
            let text = if nudge.body.is_empty() { "Zal ik dit voor je doen?".to_string() } else { nudge.body.clone() };
            continue_in_chat(app, &text, nudge.actions, vec![nudge.app], nudge.offers, true).await;
        }
        "open" => {
            services.think.lock().unwrap_or_else(|e| e.into_inner()).accepted();
            continue_in_chat(app, &nudge.body, nudge.actions, vec![nudge.app], nudge.offers, false).await;
        }
        "no" => services.think.lock().unwrap_or_else(|e| e.into_inner()).declined(),
        "mute" => {
            services.update_prefs(|p| {
                p.think_along_muted.insert(nudge.window.clone(), nudge.app.clone());
            });
        }
        _ => {}
    }
    Ok(())
}
