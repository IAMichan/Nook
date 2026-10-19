//! Het scherm voor het brein: live bijhouden (Instellingen › Assistent › Houd al mijn schermen bij), of op verzoek
//! lezen. Een vraag krijgt de tekst mee als hij "hier/dit/daar" zegt of als "Gebruik mijn schermen bij elke vraag"
//! aanstaat; boven het antwoord staat dan waar Nook keek.

use std::collections::HashMap;
use std::time::Duration;

use nook_core::services::screen::{self, ScreenSnapshot};
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;

/// Hooguit zo oud mag het voorste venster zijn als een vraag het gebruikt.
const MAX_AGE: f64 = 2.5;
/// Weg van de computer: niets meer lezen.
const IDLE_LIMIT: f64 = 180.0;

/// Of het scherm voor dit brein gelezen mag worden (een extern brein krijgt het niet als het scherm "alleen op deze
/// computer" staat).
pub fn allowed(app: &AppHandle) -> bool {
    !app.state::<AppState>().settings().private_sources().contains("screen")
}

/// Leest de vensters die aan de beurt zijn en werkt het live beeld bij.
fn refresh(services: &Services, front_only: bool) {
    let platform = &services.platform;
    let seen = platform.screen.windows();
    let now = services.now();
    let (due, olds): (Vec<String>, HashMap<String, String>) = {
        let live = services.live.lock().unwrap_or_else(|e| e.into_inner());
        let due = live.due(&seen, front_only, now);
        let olds = live.windows().into_iter().map(|w| (w.id.clone(), w.text.clone())).collect();
        (due, olds)
    };
    let mut read = HashMap::new();
    for id in due {
        if let Some(print) = platform.screen.fingerprint(&id) {
            let unchanged = !services.live.lock().unwrap_or_else(|e| e.into_inner()).needs_text(&id, print);
            if let (true, Some(old)) = (unchanged, olds.get(&id)) {
                read.insert(id, (old.clone(), print));
                continue;
            }
        }
        if let Some((text, print)) = platform.screen.read_window(&id) {
            let text = if text.trim().is_empty() { olds.get(&id).cloned().unwrap_or_default() } else { text };
            read.insert(id, (text, print));
        }
    }
    services.live.lock().unwrap_or_else(|e| e.into_inner()).update(&seen, read, now);
}

/// De draad die het scherm bijhoudt: elke 7 seconden alles wat aan de beurt is, en meteen het voorste venster als je
/// van app wisselt. Rust als het uit staat of je weg bent.
#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::Builder::new()
        .name("nook-scherm".into())
        .spawn(move || {
            let services = app.state::<Services>();
            let mut last_front = String::new();
            let mut tick = 0u64;
            loop {
                std::thread::sleep(Duration::from_secs(1));
                tick += 1;
                let settings = app.state::<AppState>().settings();
                if !(settings.live_screen || settings.auto_watch) || !services.platform.screen.available() {
                    if tick.is_multiple_of(30) {
                        services.live.lock().unwrap_or_else(|e| e.into_inner()).clear();
                    }
                    continue;
                }
                if services.platform.screen.idle_seconds() > IDLE_LIMIT {
                    continue;
                }
                let front = services.platform.screen.windows().into_iter().find(|w| w.frontmost).map(|w| w.id).unwrap_or_default();
                if front != last_front {
                    last_front = front;
                    std::thread::sleep(Duration::from_millis(600));
                    refresh(&services, true);
                } else if tick.is_multiple_of(screen::INTERVAL as u64) {
                    refresh(&services, false);
                }
            }
        })
        .ok();
}

/// Alle zichtbare vensters als tekst: uit het live beeld als dat aanstaat, anders nu gelezen. `small`: een klein
/// lokaal model krijgt minder.
pub fn snapshot(app: &AppHandle, small: bool) -> Result<ScreenSnapshot, String> {
    let services = app.state::<Services>();
    let screen = &services.platform.screen;
    if !screen.available() {
        let status = screen.status();
        return Err(if status.is_empty() { "Nook kan op dit platform niet meekijken.".into() } else { status });
    }
    let limit = if small { 3500 } else { 12_000 };
    let settings = app.state::<AppState>().settings();
    if settings.live_screen {
        let stale = {
            let live = services.live.lock().unwrap_or_else(|e| e.into_inner());
            live.front().map(|f| services.now() - f.captured > MAX_AGE).unwrap_or(true)
        };
        if stale {
            refresh(&services, false);
        }
        let live = services.live.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(snap) = live.snapshot(limit, services.now()) {
            return Ok(snap);
        }
    }
    let windows = screen.all_windows();
    screen::format_all(&windows, if small { 3500 } else { 9000 }).ok_or_else(|| nothing(&services))
}

fn nothing(services: &Services) -> String {
    match services.platform.screen.active_app() {
        Some(app) if screen::is_excluded(&app.id) || screen::is_excluded(&app.name) => format!("In {} kijk ik niet.", app.name),
        _ => {
            let status = services.platform.screen.status();
            if status.is_empty() {
                "Ik zie niets om te lezen.".into()
            } else {
                status
            }
        }
    }
}

/// Het live beeld, zonder te wachten (voor meedenken en de instellingen).
pub fn cached(app: &AppHandle) -> Option<(LiveSummary, Option<Front>)> {
    let services = app.state::<Services>();
    let live = services.live.lock().unwrap_or_else(|e| e.into_inner());
    let windows = live.windows();
    let front = live.front().map(|f| (f.app.clone(), f.title.clone(), f.fingerprint));
    Some((
        LiveSummary { windows: windows.iter().map(|w| format!("{} — {}", w.app, w.title)).collect(), displays: live.display_count() },
        front,
    ))
}

/// Het voorste venster uit het live beeld: app, titel en vingerafdruk.
pub type Front = (String, String, u64);

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveSummary {
    pub windows: Vec<String>,
    pub displays: usize,
}

/// Het scherm voor een vraag in de chat, of niets. Zet onderweg de status en daarna "Nook keek in …" boven het
/// antwoord; als de vraag naar het scherm verwijst en lezen mislukt, staat de reden erbij.
pub async fn for_question(app: &AppHandle, nook_id: &str, message_id: &str, text: &str) -> Option<(String, String)> {
    let settings = app.state::<AppState>().settings();
    let explicit = screen::refers_to_screen(text);
    let small = settings.provider.is_local_server() && nook_core::brain::service::profile_for(&settings, crate::brain::memory_gb()).max_tools <= 16;
    let services = app.state::<Services>();
    if !services.platform.screen.available() || !allowed(app) {
        return None;
    }
    if !(explicit || (settings.screen_with_every_question && !small)) {
        return None;
    }
    set_message(app, nook_id, message_id, |m| m.status = "Ik kijk even mee…".into());
    let task_app = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || snapshot(&task_app, small)).await.unwrap_or_else(|e| Err(e.to_string()));
    match result {
        Ok(snap) => {
            let label = screen::looked_label(&snap);
            set_message(app, nook_id, message_id, |m| {
                m.sources = vec![label.clone()];
                m.status = "Denkt na…".into();
            });
            Some((format!("{} — {}", snap.app_name, snap.window_title), snap.text))
        }
        Err(e) => {
            if explicit {
                set_message(app, nook_id, message_id, |m| m.notices.push(format!("Ik kon niet op je scherm kijken: {e}")));
            }
            None
        }
    }
}

fn set_message(app: &AppHandle, nook_id: &str, message_id: &str, f: impl FnOnce(&mut nook_core::nooks::ChatMessage)) {
    let state = app.state::<AppState>();
    state.with_chat(|c| {
        if let Some(m) = c.get_mut(nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) {
            f(m);
        }
    });
    let _ = tauri::Emitter::emit(app, "nook-updated", nook_id);
}
