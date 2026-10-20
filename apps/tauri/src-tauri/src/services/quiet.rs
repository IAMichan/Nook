//! Meetings and screen sharing (`AppModel+Quiet` on the Mac): every two seconds Nook looks whether you share your screen
//! or sit in a meeting (`QuietWatch` of the platform) and behaves the way you chose in Settings › Voice and sound
//! (`nook_core::services::quiet`): as usual, quiet, left out of what you share, or hidden until it is over.
#![cfg_attr(not(desktop), allow(dead_code))]

use std::sync::Mutex;
use std::time::Instant;

use chrono::Utc;
use nook_core::services::quiet::{self, Event, MeetingSignals, QuietBehavior, QuietSituation, QuietState};
use nook_core::settings::Settings;
use serde::Serialize;
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;

/// How often the timer looks (seconds).
const TICK: f64 = 2.0;
/// Settings counts as showing the status line this long after it last asked for it.
const VIEWED_FOR: f64 = 10.0;

#[derive(Default)]
pub struct QuietWatchState {
    state: Mutex<QuietState>,
    /// When Settings last asked for the status line: while it is open the situation is read even with "change nothing".
    viewed: Mutex<Option<Instant>>,
    last_tick: Mutex<Option<Instant>>,
    /// The content protection last applied: on or off, and for how many windows.
    protected: Mutex<Option<(bool, usize)>>,
    /// Nook's windows put away while it hides for a share or meeting, to bring back afterwards.
    hidden_windows: Mutex<Vec<String>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// How Nook behaves right now.
pub fn current(app: &AppHandle) -> QuietState {
    app.try_state::<Services>().map(|s| *lock(&s.quiet.state)).unwrap_or_default()
}

/// No suggestions, cards or sounds of Nook's own right now.
pub fn silent(app: &AppHandle) -> bool {
    current(app).silent
}

/// Nook hides for a share or meeting: agent prompts wait in the bar until it is over.
pub fn holds_cards(app: &AppHandle) -> bool {
    current(app).hidden
}

/// What Settings shows: the state and the line with what Nook notices.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuietView {
    pub state: QuietState,
    pub status: String,
}

/// The status for the interface. `watching`: Settings shows the line, so the situation is read now and for a while
/// even when both choices are "change nothing".
pub fn view(app: &AppHandle, watching: bool) -> QuietView {
    let services = app.state::<Services>();
    if watching {
        *lock(&services.quiet.viewed) = Some(Instant::now());
        let stale = lock(&services.quiet.last_tick).is_none_or(|t| t.elapsed().as_secs_f64() > TICK);
        if stale && cfg!(desktop) {
            tick(app);
        }
    }
    let state = current(app);
    QuietView { status: state.status_text().into(), state }
}

/// Whether what is going on matters right now: you chose to behave differently in a meeting or share, or Settings shows
/// the line that says what Nook notices. Otherwise the read (every window, every program with the microphone open)
/// would be for no one, so it is skipped.
fn needed(app: &AppHandle, settings: &Settings) -> bool {
    let viewed = app.try_state::<Services>().and_then(|s| *lock(&s.quiet.viewed)).is_some_and(|t| t.elapsed().as_secs_f64() < VIEWED_FOR);
    settings.quiet_while_sharing != QuietBehavior::Normal || settings.quiet_in_meetings != QuietBehavior::Normal || viewed
}

/// Events going on in the calendars Nook knows, from their cache (no network).
fn calendar_events(app: &AppHandle) -> Vec<Event> {
    let Some(connectors) = app.try_state::<crate::connectors::Connectors>() else { return vec![] };
    connectors
        .hub
        .active()
        .iter()
        .flat_map(|c| c.cached_agenda())
        .filter(|e| !e.all_day)
        .map(|e| Event { start: e.start, end: e.end })
        .collect()
}

/// What is going on right now.
fn situation(app: &AppHandle, settings: &Settings) -> QuietSituation {
    if settings.demo_data {
        return QuietSituation::default();
    }
    let services = app.state::<Services>();
    let watch = &services.platform.quiet;
    let windows = watch.windows();
    let mut meeting = MeetingSignals::new(Utc::now());
    meeting.use_calendar = settings.quiet_use_calendar;
    if settings.quiet_use_calendar {
        meeting.events = calendar_events(app);
    }
    meeting.microphone_apps = watch.microphone_apps();
    meeting.window_names = windows.iter().map(|w| w.name.clone()).filter(|n| !n.is_empty()).collect();
    meeting.recording = super::notes::live(app).recording;
    QuietSituation { sharing: quiet::is_sharing(&windows, !settings.show_in_screenshots), meeting: quiet::is_meeting(&meeting) }
}

/// Reads what is going on and, when that or your choice changed, tells the windows and the interface.
pub fn tick(app: &AppHandle) {
    let Some(services) = app.try_state::<Services>() else { return };
    *lock(&services.quiet.last_tick) = Some(Instant::now());
    let settings = app.state::<AppState>().settings();
    let situation = situation(app, &settings);
    let state = quiet::state(situation, settings.quiet_while_sharing, settings.quiet_in_meetings);
    let before = std::mem::replace(&mut *lock(&services.quiet.state), state);
    protect(app, settings.hide_from_captures || state.excluded_from_capture);
    if state.hidden != before.hidden {
        hide_windows(app, state.hidden);
    }
    if state != before {
        super::emit(app, "quiet-changed", state);
    }
}

/// Leaves every Nook window out of screen sharing and screenshots, or lets it back in. Only applied when that or the
/// number of windows changed, so a window opened during the share is covered too.
fn protect(app: &AppHandle, on: bool) {
    let Some(services) = app.try_state::<Services>() else { return };
    let windows = app.webview_windows();
    let next = (on, windows.len());
    let mut applied = lock(&services.quiet.protected);
    if *applied == Some(next) {
        return;
    }
    // Nothing to undo at the start: windows are not protected until Nook says so.
    if applied.is_none() && !on {
        *applied = Some(next);
        return;
    }
    for window in windows.values() {
        if let Err(e) = window.set_content_protected(on) {
            log::warn!("Content protection for {}: {e}", window.label());
        }
    }
    *applied = Some(next);
}

/// Hidden for a share or meeting: Nook's windows go, and come back when it is over. A window you open yourself in the
/// meantime stays.
fn hide_windows(app: &AppHandle, hide: bool) {
    let Some(services) = app.try_state::<Services>() else { return };
    let mut hidden = lock(&services.quiet.hidden_windows);
    if hide {
        *hidden = app
            .webview_windows()
            .into_iter()
            .filter(|(label, w)| label.as_str() != super::windows::PART && w.is_visible().unwrap_or(false))
            .map(|(label, w)| {
                let _ = w.hide();
                label
            })
            .collect();
    } else {
        for label in hidden.drain(..) {
            if let Some(window) = app.get_webview_window(&label) {
                let _ = window.show();
            }
        }
    }
}

/// The timer: every two seconds while it matters. With only the meeting choice in play it is slower while you are away
/// or the computer saves power; a choice for screen sharing keeps the two seconds, so a share that starts never shows
/// Nook to the viewers for longer than that. A changed setting applies right away.
#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let handle = app.clone();
    tauri::Listener::listen_any(app, "settings-changed", move |_| {
        let app = handle.clone();
        // Settings are saved on the main thread; the read can take a moment.
        std::thread::spawn(move || tick(&app));
    });
    let app = app.clone();
    std::thread::Builder::new()
        .name("nook-stil".into())
        .spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs_f64(TICK));
            let settings = app.state::<AppState>().settings();
            let services = app.state::<Services>();
            if !needed(&app, &settings) {
                let state = *lock(&services.quiet.state);
                // Still quiet or hidden for a choice you just changed to "change nothing": one more read puts it back.
                if state.silent || state.excluded_from_capture || state.hidden {
                    tick(&app);
                } else {
                    // A window opened since (a screen part) still follows "always keep Nook out of screen sharing".
                    protect(&app, settings.hide_from_captures);
                }
                continue;
            }
            let interval =
                if settings.quiet_while_sharing == QuietBehavior::Normal { TICK * super::energy::plan(&app).slowdown() } else { TICK };
            let due = lock(&services.quiet.last_tick).is_none_or(|t| t.elapsed().as_secs_f64() >= interval - 0.5);
            if due {
                tick(&app);
            }
        })
        .ok();
}
