//! Nook as a buddy (`AppModel+Buddy` on the Mac, SV-19): every half minute Nook notes whether you are at your computer
//! and, when a moment is due (a good morning, welcome back, a break, a milestone, late night, Friday wrap, your
//! birthday) and nothing else is going on, shares it in the bar as a short notice with his mood (`buddy-moment`).
//! What to say and when is decided by `nook_core::services::buddy`; this side gathers the signals.
#![cfg_attr(not(desktop), allow(dead_code))]

use std::sync::{Mutex, OnceLock};

use chrono::{Local, Timelike};
use nook_core::services::buddy::{BuddyMomentView, BuddyService, BuddyTone, MonthDay};
use tauri::{AppHandle, Manager};

use super::Services;
use crate::agents::AgentsState;
use crate::state::AppState;

/// How often Nook looks (seconds), as the Mac's half-minute timer.
const TICK_SECS: u64 = 30;

static BUDDY: OnceLock<Mutex<BuddyService>> = OnceLock::new();

fn service() -> std::sync::MutexGuard<'static, BuddyService> {
    BUDDY.get_or_init(|| Mutex::new(BuddyService::open_default())).lock().unwrap_or_else(|e| e.into_inner())
}

/// Starts the half-minute timer.
#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let app = app.clone();
    let _ = std::thread::Builder::new().name("nook-buddy".into()).spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(TICK_SECS));
        tick(&app);
    });
}

/// One look: notes your activity and shares a moment when one is due.
pub fn tick(app: &AppHandle) {
    let settings = app.state::<AppState>().settings();
    let idle = app
        .try_state::<Services>()
        .filter(|s| s.platform.screen.available())
        .map(|s| s.platform.screen.idle_seconds())
        // Without an idle reading you count as at your computer.
        .unwrap_or(0.0);
    let now = Local::now().fixed_offset();
    let mut svc = service();
    feed(app, &mut svc);
    if !settings.buddy_moments || !settings.onboarding_done || settings.demo_data {
        // Still note the activity, so a moment switched on later knows how long you have been working.
        svc.activity.note(idle, now);
        return;
    }
    let in_event = stays_quiet(app, &settings);
    let birthday = MonthDay::parse(&settings.birthday);
    let events = events_left_today(app);
    // The moment keeps the notices' distance and shares the day's budget: only plan when the pacer allows one.
    if !crate::notices::moment_permitted(app, false) {
        svc.activity.note(idle, now);
        return;
    }
    let Some(moment) = svc.plan(idle, now, in_event, true, events, birthday) else { return };
    if !crate::notices::moment_permitted(app, true) {
        return;
    }
    let view = svc.commit(&moment, now, BuddyTone::parse(&settings.buddy_tone));
    drop(svc);
    super::emit(app, "buddy-moment", view);
}

/// The moment shown last, while it is fresh and not dismissed (Home's card asks for it); `dismiss_id` puts it away.
pub fn current(app: &AppHandle, dismiss_id: Option<&str>) -> Option<BuddyMomentView> {
    if !app.state::<AppState>().settings().buddy_moments {
        return None;
    }
    let mut svc = service();
    if let Some(id) = dismiss_id.filter(|s| !s.is_empty()) {
        svc.dismiss(id);
        return None;
    }
    svc.active(Local::now().fixed_offset())
}

/// "Breathe with Nook now" (Settings) or "Breathe along" on a break: a minute of slow breathing in the bar, also when
/// no moment shows and while Nook keeps quiet in a meeting, because you asked for it.
pub fn breathe(app: &AppHandle) {
    service().breathed(Local::now().fixed_offset());
    super::emit(app, "buddy-breathe", ());
}

/// In a meeting, on a call, sharing your screen, or inside the quiet hours: no moments, whatever you chose for the
/// rest of the bar (`keepsNiceToHaveQuiet` on the Mac).
fn stays_quiet(app: &AppHandle, settings: &nook_core::settings::Settings) -> bool {
    if super::quiet::silent(app) {
        return true;
    }
    if settings.notice_rules.quiet_hours.is_some_and(|q| q.silences(false, Local::now().hour())) {
        return true;
    }
    #[cfg(desktop)]
    {
        let situation = super::quiet::situation(app, settings);
        situation.meeting || situation.sharing
    }
    #[cfg(not(desktop))]
    false
}

/// The events in your calendars for the rest of today, from their cache (no network): what the morning greeting counts.
fn events_left_today(app: &AppHandle) -> usize {
    let Some(connectors) = app.try_state::<crate::connectors::Connectors>() else { return 0 };
    let now = Local::now();
    let today = now.date_naive();
    connectors
        .hub
        .active()
        .iter()
        .flat_map(|c| c.cached_agenda())
        .filter(|e| !e.all_day && e.start > now.to_utc() && e.start.with_timezone(&Local).date_naive() == today)
        .count()
}

/// Finished agent runs and sessions count towards the milestones and the "while you were away" count, once each;
/// Flow's word count towards the word milestones.
fn feed(app: &AppHandle, svc: &mut BuddyService) {
    if let Some(ws) = app.try_state::<crate::workspace::WorkspaceState>() {
        use nook_core::workspace::models::RunStatus;
        for run in ws.manager.runs() {
            if run.status == RunStatus::Completed {
                svc.note_finished_agent(&format!("run:{}", run.id), run.updated_at);
            }
        }
    }
    if let Some(agents) = app.try_state::<AgentsState>() {
        use nook_core::agents::models::AgentStatus;
        for s in agents.hub.sessions() {
            if s.status == AgentStatus::Done {
                svc.note_finished_agent(&s.id, s.updated.unwrap_or_else(chrono::Utc::now));
            }
        }
        let past = crate::agents::lock(&agents.last_history).sessions.clone();
        for p in past {
            svc.note_finished_agent(&p.session_id, p.ended);
        }
    }
    if let Some(services) = app.try_state::<Services>() {
        let words = services.flow.lock().unwrap_or_else(|e| e.into_inner()).stats.total_words();
        svc.sync_words_total(words);
    }
}
