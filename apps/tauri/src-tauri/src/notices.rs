//! System notifications with buttons (the Mac's `SystemNotifier`): what each toast does when you act on it, and the
//! clicks that come back after Nook restarted. What a toast says and offers is decided in `nook_core::services::toast`;
//! `platform::toast` shows it (Windows toasts; elsewhere a plain notification when it has no buttons).

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use nook_core::agents::models::ApprovalDecision;
use nook_core::services::toast::{NoticeOptions, NoticeTarget, Toast, ToastAction, ToastLevel, ToastLink, NOTICE_LIMIT};
use tauri::{AppHandle, Manager};

type Callback = Box<dyn Fn() + Send + Sync>;

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
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Called once at launch: Nook takes `nook://notice` links, toasts from before a restart that only Nook's buttons could
/// answer go, and a click that started this Nook is answered.
pub fn setup(app: &AppHandle) {
    app.manage(Toasts::default());
    crate::platform::toast::setup(app);
    let args: Vec<String> = std::env::args().collect();
    if let Some(link) = ToastLink::from_args(&args) {
        respond(app, link, None);
    }
}

/// Shows `toast`; `fallback` runs when this computer cannot (notifications off, or buttons this platform can't show),
/// so a request is never lost.
pub fn post(app: &AppHandle, toast: Toast, handlers: Handlers, fallback: impl FnOnce()) {
    let Some(state) = app.try_state::<Toasts>() else { return fallback() };
    let id = toast.id.clone();
    let approval = toast.kind.is_approval();
    lock(&state.handlers).insert(id.clone(), handlers);
    lock(&state.live).insert(id.clone(), toast.group());
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
