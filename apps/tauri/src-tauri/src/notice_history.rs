//! The history of notices Nook gave since it started (the Mac's `NoticeHistory`), in memory only, for the bell in the
//! main window's sidebar head: searchable, and a click opens where the notice came from. Every system notification
//! (`notices::post`), every agent card and every chat message that arrived is kept, also the ones Settings ›
//! Notifications keeps out of sight ("history only").

use std::sync::Mutex;

use nook_core::services::notice_log::{NoticeEntry, NoticeKind, NoticeLog};
use nook_core::services::toast::NoticeTarget;
use tauri::{AppHandle, Emitter};

static LOG: Mutex<Option<NoticeLog>> = Mutex::new(None);

fn with<T>(f: impl FnOnce(&mut NoticeLog) -> T) -> T {
    let mut guard = LOG.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(NoticeLog::default))
}

fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// The main-window route of a toast's target, as precise as the window can open it.
pub fn route(target: &NoticeTarget) -> String {
    match target {
        NoticeTarget::Agent(id) => format!("agent:{id}"),
        NoticeTarget::Run(id) => format!("agent:run-{id}"),
        other => other.route(),
    }
}

pub fn record(app: &AppHandle, key: &str, kind: NoticeKind, title: &str, detail: &str, context: &str, route: &str) {
    with(|log| log.add(key, kind, title, detail, context, route, now()));
    let unseen = with(|log| log.unseen());
    let _ = app.emit("notice-history", unseen);
}

#[tauri::command]
pub fn notice_history(query: Option<String>) -> Vec<NoticeEntry> {
    with(|log| {
        log.prune(now());
        log.search(query.as_deref().unwrap_or(""))
    })
}

#[tauri::command]
pub fn notice_history_unseen() -> usize {
    with(|log| log.unseen())
}

#[tauri::command]
pub fn notice_history_seen(app: AppHandle, id: Option<u64>) {
    with(|log| match id {
        Some(id) => log.mark_seen(id),
        None => log.mark_all_seen(),
    });
    let _ = app.emit("notice-history", with(|log| log.unseen()));
}

#[tauri::command]
pub fn notice_history_remove(app: AppHandle, id: Option<u64>) {
    with(|log| match id {
        Some(id) => log.remove(id),
        None => log.clear(),
    });
    let _ = app.emit("notice-history", with(|log| log.unseen()));
}

/// Records a notice the interface decided on itself (a bar card it kept out of sight).
#[tauri::command]
pub fn notice_history_record(app: AppHandle, key: String, kind: String, title: String, detail: String, context: String, route: String) {
    let kind = match kind.as_str() {
        "done" => NoticeKind::Done,
        "failed" => NoticeKind::Failed,
        "waiting" => NoticeKind::Waiting,
        _ => NoticeKind::Info,
    };
    record(&app, &key, kind, &title, &detail, &context, &route);
}
