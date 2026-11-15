//! De telefoonkant vraagt de lijst elke paar seconden op zolang de app voor staat (zoals de iPhone-app), en
//! minder vaak op de achtergrond. Komt er een nieuwe goedkeuring of vraag bij terwijl je de app niet ziet, dan een
//! melding (op Android via `tauri-plugin-notification`). Echte pushmeldingen naar Android bestaan niet: daarvoor is een
//! server van Google (FCM) nodig, en Nook heeft er bewust geen.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use nook_core::companion::client::{ClientSnapshot, Phase};
use nook_core::companion::{feature, DeliveryLog, ItemKind};
use tauri::{AppHandle, Emitter, Manager};

use super::Companion;

pub struct Poller {
    visible: AtomicBool,
    wake: tokio::sync::Notify,
    /// The app went to the background: the kept connection closes, and the phone asks now and then instead.
    hidden: tokio::sync::Notify,
    /// Another computer became active: the kept connection moves to it.
    restart: tokio::sync::Notify,
    seen: Mutex<Option<DeliveryLog>>,
}

impl Default for Poller {
    fn default() -> Self {
        Self {
            visible: AtomicBool::new(true),
            wake: tokio::sync::Notify::new(),
            hidden: tokio::sync::Notify::new(),
            restart: tokio::sync::Notify::new(),
            seen: Mutex::new(None),
        }
    }
}

impl Poller {
    pub fn set_visible(&self, visible: bool) {
        self.visible.store(visible, Ordering::SeqCst);
        if visible {
            self.wake.notify_one();
        } else {
            self.hidden.notify_waiters();
        }
    }

    pub fn restart(&self) {
        self.restart.notify_waiters();
        self.wake.notify_one();
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
    // The other paired computers are asked for their sessions every 30 seconds while the app is in front.
    let others = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(30)).await;
            let companion = others.state::<Companion>();
            if companion.poll.visible.load(Ordering::SeqCst) && companion.client.snapshot().macs.len() > 1 {
                let snapshot = companion.client.refresh_others().await;
                let _ = others.emit("companion-client", &snapshot);
            }
        }
    });
    tauri::async_runtime::spawn(async move {
        loop {
            let companion = app.state::<Companion>();
            let visible = companion.poll.visible.load(Ordering::SeqCst);
            // In front, with a computer that keeps a connection open: everything follows live, as on the iPhone.
            if companion.client.is_paired() && visible && companion.client.has(feature::STREAM) {
                let poll = &companion.poll;
                let result = tokio::select! {
                    r = companion.client.stream(
                        || poll.visible.load(Ordering::SeqCst),
                        |snapshot, update| {
                            let _ = app.emit("companion-client", &snapshot);
                            let _ = app.emit("companion-live", &update);
                        },
                    ) => r,
                    _ = poll.hidden.notified() => Ok(()),
                    _ = poll.restart.notified() => Ok(()),
                };
                if let Err(e) = result {
                    log::info!("Companion: live connection ended ({e}); asking instead");
                    let snapshot = companion.client.refresh().await;
                    let _ = app.emit("companion-client", &snapshot);
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(3)) => {}
                        _ = companion.poll.wake.notified() => {}
                    }
                }
                continue;
            }
            if companion.client.is_paired() {
                let snapshot = companion.client.refresh().await;
                let _ = app.emit("companion-client", &snapshot);
                if snapshot.phase == Phase::Connected {
                    let fresh = companion.poll.fresh(&snapshot);
                    if !visible {
                        for (agent, what) in fresh {
                            notify(&app, &agent, &what);
                        }
                    }
                }
            }
            let every = if visible { 5 } else { 60 };
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
