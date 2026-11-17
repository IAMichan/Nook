//! Chat messages from other apps' notifications into the shared inbox (`ChatCaptureService` on the Mac), for the
//! apps Nook has no bridge for: Discord, Google Chat, Viber, LINE and the rest. Off until you switch Chats on (the
//! `chats` toggle, as on the Mac).
//!
//! - Windows: the notification database Windows keeps for the user (`wpndatabase.db`), read-only, once a second. A
//!   first start also brings in what came in the last two weeks, the older part of it as read.
//! - Linux: the notification bus through `dbus-monitor`; only what comes while Nook runs.
//! - macOS: the Mac app does this itself.

use std::sync::Arc;

use chrono::Utc;
use nook_core::chats::apps::MessagingApp;
use nook_core::chats::capture::{self, CapturedNotification};
use nook_core::chats::{ChatInbox, InboxStore};
use nook_core::connectors::whatsapp::WhatsAppLink;
use nook_core::connectors::ConnectorStore;
use tauri::{AppHandle, Emitter, Manager};

use crate::state::AppState;

/// The toggle that switches reading other apps' notifications on (`ChatInboxConnector.sourceID`).
pub const TOGGLE: &str = "chats";
/// A first start shows what came in this long ago.
#[cfg_attr(not(windows), allow(dead_code))]
const FIRST_LOOK_DAYS: i64 = 14;
/// What came in before this long ago, on a first start, counts as read: it was likely seen already.
#[cfg_attr(not(windows), allow(dead_code))]
const FRESHNESS_MINUTES: i64 = 60;

/// Whether reading notifications is on: off until you switch it on, as on the Mac.
pub fn is_on(store: &ConnectorStore) -> bool {
    store.read(|c| c.toggles.get(TOGGLE).copied().unwrap_or(false))
}

/// What reading the notifications needs from the rest of the app.
#[derive(Clone)]
#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
pub struct Capture {
    app: AppHandle,
    chats: Arc<InboxStore>,
    store: Arc<ConnectorStore>,
    whatsapp: Arc<WhatsAppLink>,
}

#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
impl Capture {
    fn apps(&self) -> Vec<MessagingApp> {
        let sources = self.app.state::<AppState>().settings().chat_sources;
        sources
            .active()
            .into_iter()
            // WhatsApp's notifications only repeat what its linked phone brings.
            .filter(|a| !(a.id == "whatsapp" && self.whatsapp.is_connected()))
            .collect()
    }

    /// Brings these notifications into the inbox. `fresh_after`: older ones count as read (a first look back).
    fn take(&self, notifications: Vec<CapturedNotification>, fresh_after: Option<chrono::DateTime<Utc>>) {
        if notifications.is_empty() {
            return;
        }
        let apps = self.apps();
        let changed = self.chats.with(|inbox| {
            let mut changed = false;
            for n in &notifications {
                inbox.last_record = Some(inbox.last_record.unwrap_or(0).max(n.record));
                let Some(notice) = capture::notice(n, &apps, |_| None) else { continue };
                if inbox.add(&notice, &format!("notice-{}", n.record)) {
                    changed = true;
                    if fresh_after.is_some_and(|fresh| notice.date < fresh) {
                        inbox.mark_read(&ChatInbox::key_by_name(&notice.app, &notice.chat), notice.date);
                    }
                }
            }
            changed
        });
        if changed {
            let _ = self.app.emit("chats-changed", ());
        }
    }
}

/// Starts reading notifications. Called from `connectors::setup`.
pub fn setup(app: &AppHandle, chats: Arc<InboxStore>, store: Arc<ConnectorStore>, whatsapp: Arc<WhatsAppLink>) {
    let capture = Capture { app: app.clone(), chats, store, whatsapp };
    #[cfg(windows)]
    tauri::async_runtime::spawn(windows_reader(capture));
    #[cfg(target_os = "linux")]
    std::thread::spawn(move || linux_reader(capture));
    #[cfg(not(any(windows, target_os = "linux")))]
    let _ = capture;
}

#[cfg(windows)]
async fn windows_reader(capture: Capture) {
    use capture::windows_db;
    use chrono::Duration;
    const PAGE: usize = 200;
    let Some(base) = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from) else { return };
    let path = windows_db::path(&base);
    loop {
        if !is_on(&capture.store) || !path.is_file() {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            continue;
        }
        let last = capture.chats.read(|i| i.last_record);
        let now = Utc::now();
        let since = now - Duration::days(FIRST_LOOK_DAYS);
        let fresh_after = last.is_none().then(|| now - Duration::minutes(FRESHNESS_MINUTES));
        let read = {
            let path = path.clone();
            tokio::task::spawn_blocking(move || windows_db::read(&path, last.unwrap_or(0), since, PAGE)).await
        };
        match read {
            Ok(Ok(list)) => {
                let full = list.len() >= PAGE;
                if list.is_empty() && last.is_none() {
                    // Nothing in the look-back: start from the newest, so the next look does not read it all again.
                    if let Ok(newest) = windows_db::newest(&path) {
                        capture.chats.with(|i| i.last_record = Some(newest));
                    }
                }
                capture.take(list, fresh_after);
                // A full page: the next one at once.
                if full {
                    continue;
                }
            }
            Ok(Err(error)) => log::info!("Chats: notifications not read: {error}"),
            Err(_) => {}
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

#[cfg(target_os = "linux")]
fn linux_reader(capture: Capture) {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};

    let mut record = Utc::now().timestamp_millis();
    loop {
        if !is_on(&capture.store) {
            std::thread::sleep(std::time::Duration::from_secs(5));
            continue;
        }
        let child = Command::new("dbus-monitor")
            .args(["--session", "--monitor", capture::dbus::MATCH])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else {
            log::info!("Chats: dbus-monitor is not available; other apps' notifications are not read");
            return;
        };
        let Some(out) = child.stdout.take() else { return };
        let mut monitor = capture::dbus::Monitor::default();
        for line in BufReader::new(out).lines() {
            let Ok(line) = line else { break };
            if !is_on(&capture.store) {
                break;
            }
            if let Some((system_id, title, body)) = monitor.line(&line) {
                record += 1;
                let n = CapturedNotification { record, system_id, title, subtitle: String::new(), body, date: Utc::now() };
                capture.take(vec![n], None);
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
}

/// Switches reading other apps' notifications on or off (Settings › Chats).
#[tauri::command]
pub fn chat_capture_set(c: tauri::State<'_, crate::connectors::Connectors>, on: bool) {
    c.env.store.set_on(TOGGLE, on);
}

#[tauri::command]
pub fn chat_capture_status(c: tauri::State<'_, crate::connectors::Connectors>) -> bool {
    is_on(&c.env.store)
}
