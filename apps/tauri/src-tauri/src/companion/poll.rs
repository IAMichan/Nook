//! De telefoonkant vraagt de lijst elke paar seconden op zolang de app voor staat (zoals de iPhone-app), en
//! minder vaak op de achtergrond. Komt er een nieuwe goedkeuring of vraag bij terwijl je de app niet ziet, dan een
//! melding (op Android via `tauri-plugin-notification`). Echte pushmeldingen naar Android bestaan niet: daarvoor is een
//! server van Google (FCM) nodig, en Nook heeft er bewust geen.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use nook_core::companion::client::{ClientSnapshot, Phase};
use nook_core::companion::{DeliveryLog, ItemKind};
use tauri::{AppHandle, Emitter, Manager};

use super::Companion;

pub struct Poller {
    visible: AtomicBool,
    wake: tokio::sync::Notify,
    seen: Mutex<Option<DeliveryLog>>,
}

impl Default for Poller {
    fn default() -> Self {
        Self { visible: AtomicBool::new(true), wake: tokio::sync::Notify::new(), seen: Mutex::new(None) }
    }
}

impl Poller {
    pub fn set_visible(&self, visible: bool) {
        self.visible.store(visible, Ordering::SeqCst);
        if visible {
            self.wake.notify_one();
        }
    }

    pub fn wake(&self) {
        self.wake.notify_one();
    }

    /// Wat er nieuw op je wacht sinds de vorige keer. De eerste keer telt alles als gezien: geen stortvloed bij het starten.
    fn fresh(&self, snapshot: &ClientSnapshot) -> Vec<(String, String)> {
        let mut guard = self.seen.lock().unwrap_or_else(|e| e.into_inner());
        let first = guard.is_none();
        let log = guard.get_or_insert_with(|| DeliveryLog::new(300));
        let mut out = Vec::new();
        for session in &snapshot.sessions {
            for item in &session.items {
                if log.record(&format!("{}:{}", session.id, item.id)) && !first {
                    let what = match item.kind {
                        ItemKind::Approval => "Wacht op jouw toestemming",
                        ItemKind::Question => "Heeft een vraag",
                    };
                    out.push((session.agent.clone(), what.to_string()));
                }
            }
        }
        out
    }
}

pub fn start(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            let companion = app.state::<Companion>();
            if companion.client.is_paired() {
                let snapshot = companion.client.refresh().await;
                let _ = app.emit("companion-client", &snapshot);
                if snapshot.phase == Phase::Connected {
                    let fresh = companion.poll.fresh(&snapshot);
                    if !companion.poll.visible.load(Ordering::SeqCst) {
                        for (agent, what) in fresh {
                            notify(&app, &agent, &what);
                        }
                    }
                }
            }
            let every = if companion.poll.visible.load(Ordering::SeqCst) { 5 } else { 60 };
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(every)) => {}
                _ = companion.poll.wake.notified() => {}
            }
        }
    });
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    #[cfg(mobile)]
    {
        use tauri_plugin_notification::NotificationExt;
        if let Err(e) = app.notification().builder().title(title).body(body).show() {
            log::warn!("Melding mislukt: {e}");
        }
    }
    #[cfg(not(mobile))]
    {
        let _ = app;
        log::info!("Companion: {title} · {body}");
    }
}
