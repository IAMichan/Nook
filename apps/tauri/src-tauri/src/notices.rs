//! System notifications with buttons (the Mac's `SystemNotifier`): what each toast does when you act on it, and the
//! clicks that come back after Nook restarted. What a toast says and offers is decided in `nook_core::services::toast`;
//! `platform::toast` shows it (Windows toasts; elsewhere a plain notification when it has no buttons).

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Mutex;

use nook_core::agents::models::ApprovalDecision;
use nook_core::services::notice_pacer::{local_day_key, InterruptionBudget, InterruptionClass, NoticePacer};
use nook_core::services::toast::{NoticeOptions, NoticeTarget, Toast, ToastAction, ToastLevel, ToastLink, NOTICE_LIMIT};
use tauri::{AppHandle, Manager};

type Callback = Box<dyn Fn() + Send + Sync>;

/// Calm period before a Think Along suggestion may appear after another notice (5 minutes, matching macOS).
const SUGGESTION_CALM_SECS: f64 = 300.0;

/// What a toast's click and buttons do while the Nook that posted it runs.
#[derive(Default)]
pub struct Handlers {
    /// Allow, Always and Deny on a permission request.
    pub decide: Option<Box<dyn Fn(ApprovalDecision) + Send + Sync>>,
    /// A click on the toast, and Show; the target's place in the main window when None.
    pub show: Option<Callback>,
    /// The text typed in the toast's reply field.
    pub reply: Option<Box<dyn Fn(String) + Send + Sync>>,
    pub read: Option<Callback>,
    /// The "Open …" button.
    pub app: Option<Callback>,
}

#[derive(Default)]
pub struct Toasts {
    handlers: Mutex<HashMap<String, Handlers>>,
    /// The ids of notices with a handler, oldest first: at most `NOTICE_LIMIT` keep theirs.
    notices: Mutex<VecDeque<String>>,
    /// The group of every toast still up, by id, to withdraw it.
    live: Mutex<HashMap<String, String>>,
    /// Shared pacing and daily interruption budget for all notice sources.
    pacer: Mutex<NoticePacer>,
    /// Best-effort persistence file for `InterruptionBudget` across launches.
    budget_path: Option<PathBuf>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn now_secs_and_day() -> (f64, String) {
    let now = chrono::Local::now();
    let secs = now.timestamp() as f64 + now.timestamp_subsec_nanos() as f64 / 1_000_000_000.0;
    (secs, local_day_key(now))
}

fn save_budget(state: &Toasts, budget: &InterruptionBudget) {
    let Some(path) = &state.budget_path else { return };
    let Some(json) = budget.to_json() else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, json);
}

fn permits_popup(state: &Toasts, class: InterruptionClass, key: &str, urgent: bool, calm_secs: f64) -> bool {
    let (now_secs, day) = now_secs_and_day();
    lock(&state.pacer).permits_class(class, key, urgent, false, calm_secs, 0.0, 1.0, now_secs, &day)
}

fn allow_popup(state: &Toasts, class: InterruptionClass, key: &str, urgent: bool, calm_secs: f64) -> bool {
    let (now_secs, day) = now_secs_and_day();
    let mut pacer = lock(&state.pacer);
    let allowed = pacer.allow_class(class, key, urgent, false, calm_secs, 0.0, 1.0, now_secs, &day);
    if allowed && !urgent && class != InterruptionClass::Notice {
        let snapshot = pacer.budget.clone();
        drop(pacer);
        save_budget(state, &snapshot);
    }
    allowed
}

/// Nook's own moments (`services::buddy`) share the day's interruption budget and keep the notices' distance
/// (`NoticePacer` on the Mac): `consume` false only asks, true records the moment that is shown.
pub fn moment_permitted(app: &AppHandle, consume: bool) -> bool {
    let Some(state) = app.try_state::<Toasts>() else { return true };
    if consume {
        allow_popup(&state, InterruptionClass::Moment, "moments", false, 0.0)
    } else {
        permits_popup(&state, InterruptionClass::Moment, "moments", false, 0.0)
    }
}

/// Called once at launch: Nook takes `nook://notice` links, toasts from before a restart that only Nook's buttons could
/// answer go, and a click that started this Nook is answered.
pub fn setup(app: &AppHandle) {
    let budget_path = app.path().app_data_dir().ok().map(|dir| dir.join("attention-budget.json"));
    let budget = budget_path
        .as_ref()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|raw| InterruptionBudget::from_json(Some(&raw)))
        .unwrap_or_default();
    app.manage(Toasts {
        pacer: Mutex::new(NoticePacer::new(budget)),
        budget_path,
        ..Toasts::default()
    });
    crate::platform::toast::setup(app);
    let args: Vec<String> = std::env::args().collect();
    if let Some(link) = ToastLink::from_args(&args) {
        respond(app, link, None);
    }
}

/// Shows `toast`; `fallback` runs when this computer cannot (notifications off, or buttons this platform can't show),
/// so a request is never lost. Non-urgent notices pass through `NoticePacer` and `InterruptionBudget`, degrading to
/// history-only when paced or when the daily unasked budget is spent; urgent notices always bypass pacing.
pub fn post(app: &AppHandle, toast: Toast, handlers: Handlers, fallback: impl FnOnce()) {
    let approval = toast.kind.is_approval();
    // Every notice is kept for the history (the bell in the main window), also one this computer cannot show or that
    // the pacer holds back.
    crate::notice_history::record(
        app,
        &toast.target.thread(),
        if approval { nook_core::services::notice_log::NoticeKind::Waiting } else { nook_core::services::notice_log::NoticeKind::Info },
        &toast.title,
        &toast.body,
        &toast.subtitle,
        &crate::notice_history::route(&toast.target),
    );
    let Some(state) = app.try_state::<Toasts>() else { return fallback() };
    let urgent = approval || toast.level == ToastLevel::TimeSensitive;
    let class = if toast.id.starts_with("nudge-") || toast.level == ToastLevel::Passive {
        InterruptionClass::Suggestion
    } else {
        InterruptionClass::Notice
    };
    let calm_secs = if class == InterruptionClass::Suggestion { SUGGESTION_CALM_SECS } else { 0.0 };
    let group = toast.group();
    if !allow_popup(&state, class, &group, urgent, calm_secs) {
        log::info!("Notice paced or budget spent, keeping history-only: {} ({})", toast.id, group);
        return;
    }
    let id = toast.id.clone();
    lock(&state.handlers).insert(id.clone(), handlers);
    lock(&state.live).insert(id.clone(), group);
    if !approval {
        let mut notices = lock(&state.notices);
        notices.retain(|n| *n != id);
        notices.push_back(id.clone());
        while notices.len() > NOTICE_LIMIT {
            if let Some(old) = notices.pop_front() {
                lock(&state.handlers).remove(&old);
            }
        }
    }
    if let Err(e) = crate::platform::toast::show(app, &toast) {
        log::info!("Toast not shown, falling back: {e}");
        forget(&state, &id);
        fallback();
    }
}

/// A notice with only a click, which opens `target` (or Nook's main window).
pub fn notice(app: &AppHandle, id: &str, title: &str, body: &str, target: NoticeTarget) {
    let toast = Toast::notice(id, title, "", body, target, ToastLevel::Active, NoticeOptions::default());
    let fallback_app = app.clone();
    let (title, body) = (title.to_string(), body.to_string());
    post(app, toast, Handlers::default(), move || crate::platform::plain_notification(&fallback_app, &title, &body));
}

/// What a toast says was handled elsewhere (decided in Nook, read in its app): it goes away.
pub fn withdraw(app: &AppHandle, id: &str) {
    let Some(state) = app.try_state::<Toasts>() else { return };
    let group = lock(&state.live).get(id).cloned();
    forget(&state, id);
    if let Some(group) = group {
        crate::platform::toast::remove(app, id, &group);
    }
}

fn forget(state: &Toasts, id: &str) {
    lock(&state.handlers).remove(id);
    lock(&state.live).remove(id);
    lock(&state.notices).retain(|n| n != id);
}

/// A click or button on a toast, from the running toast (`text` from its reply field) or from a `nook://notice` link
/// Windows started Nook with.
pub fn respond(app: &AppHandle, link: ToastLink, text: Option<String>) {
    let handler = app.try_state::<Toasts>().and_then(|state| {
        let handler = lock(&state.handlers).remove(&link.toast);
        lock(&state.live).remove(&link.toast);
        lock(&state.notices).retain(|n| *n != link.toast);
        handler
    });
    let open = |app: &AppHandle| crate::platform::desktop_or_main(app, &link.target.route());
    let Some(handler) = handler else {
        // Nook restarted, or forgot it after many newer notices: the toast's link says where it leads. An old
        // permission request cannot be answered any more; its session shows what it waits on.
        return open(app);
    };
    let run = |f: &Option<Callback>| match f {
        Some(f) => f(),
        None => open(app),
    };
    match link.action {
        ToastAction::Allow | ToastAction::Always | ToastAction::Deny => {
            let decision = match link.action {
                ToastAction::Allow => ApprovalDecision::Allow,
                ToastAction::Always => ApprovalDecision::Always,
                _ => ApprovalDecision::Deny,
            };
            match &handler.decide {
                Some(decide) => decide(decision),
                None => open(app),
            }
        }
        ToastAction::Reply => match (&handler.reply, text.filter(|t| !t.trim().is_empty())) {
            (Some(reply), Some(text)) => reply(text),
            _ => run(&handler.show),
        },
        ToastAction::Read => run(&handler.read),
        ToastAction::App => run(&handler.app),
        ToastAction::Open | ToastAction::Show => run(&handler.show),
    }
}

/// The one place that decides what a notice does (Settings › Notifications): its source's style (the agents' from
/// `agent_notice`), the app's switch, quiet hours, and quiet while you share your screen or sit in a meeting. Every
/// notice asks here first; the bar and the chats ask through `notice_decide`.
pub fn decide(app: &AppHandle, source: nook_core::services::notice_rules::NoticeSource, app_name: &str, urgent: bool) -> nook_core::services::notice_rules::NoticeDecision {
    use chrono::Timelike;
    use nook_core::services::notice_rules::{NoticeDecision, NoticeRules, NoticeSource, NoticeStyle};
    let settings = app.state::<crate::state::AppState>().settings();
    let mut rules = settings.notice_rules.clone();
    rules.styles.insert(NoticeSource::Agents.id().into(), NoticeRules::agent_style(&settings.agent_notice));
    #[cfg(desktop)]
    let quiet = crate::services::quiet::silent(app);
    #[cfg(not(desktop))]
    let quiet = false;
    let decision = rules.decide(source, app_name, urgent, quiet, false, chrono::Local::now().hour());
    if let NoticeDecision::Show(style) = decision {
        if source == NoticeSource::Suggestions {
            if let Some(state) = app.try_state::<Toasts>() {
                // System-style suggestions go through `post` next (which consumes the pacer/budget), so only peek here;
                // card/strip suggestions emit directly and consume here.
                let allowed = if style == NoticeStyle::System {
                    permits_popup(&state, InterruptionClass::Suggestion, "suggestion", urgent, SUGGESTION_CALM_SECS)
                } else {
                    allow_popup(&state, InterruptionClass::Suggestion, "suggestion", urgent, SUGGESTION_CALM_SECS)
                };
                if !allowed {
                    return NoticeDecision::HistoryOnly;
                }
            }
        }
    }
    decision
}

/// What a notice from `source` (agents, chats, nook, suggestions) does now: "card", "strip", "system" or "history".
#[tauri::command]
pub fn notice_decide(app: AppHandle, source: String, app_name: Option<String>, urgent: Option<bool>) -> String {
    use nook_core::services::notice_rules::{NoticeDecision, NoticeSource, NoticeStyle};
    let Some(source) = NoticeSource::from_id(&source) else { return "card".into() };
    let name = app_name.as_deref().unwrap_or("");
    let urgent = urgent.unwrap_or(false);
    match decide(&app, source, name, urgent) {
        NoticeDecision::Show(style @ (NoticeStyle::Card | NoticeStyle::Off | NoticeStyle::Strip)) => {
            // Card and strip notices are rendered directly by the frontend bar without calling `post`, so pace them
            // here. Suggestions were already paced in `decide`.
            if source != NoticeSource::Suggestions {
                if let Some(state) = app.try_state::<Toasts>() {
                    let key = if name.is_empty() {
                        source.id().to_string()
                    } else {
                        format!("{}:{name}", source.id())
                    };
                    let class = InterruptionClass::from_notice_source(source);
                    if !allow_popup(&state, class, &key, urgent, 0.0) {
                        return "history".into();
                    }
                }
            }
            match style {
                NoticeStyle::Strip => "strip".into(),
                _ => "card".into(),
            }
        }
        NoticeDecision::Show(NoticeStyle::System) => "system".into(),
        NoticeDecision::HistoryOnly => "history".into(),
    }
}
