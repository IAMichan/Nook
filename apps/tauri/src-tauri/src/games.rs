//! Gamer Mode on this computer. The coach itself (catalog, match memory, analysis) is `nook_core::games`; here is
//! what needs the app: the saved state, looking at the screen while the game is in front, and telling the interface.
//!
//! Nook only takes a screenshot of your own screen and gives it to the brain you chose, the same way the screen part
//! does. It never reads the game's memory or sends input to it.

use std::io::Cursor;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use chrono::{DateTime, Utc};
use nook_core::brain::PromptImage;
use nook_core::games::valorant::coach::{self, Analysis};
use nook_core::games::valorant::memory::{GamerPrefs, Match, ValorantStore};
use nook_core::games::valorant::{self, observe};
use nook_core::services::rewrite;
use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::services::Services;
use crate::state::AppState;

/// Screenshots go to the brain at most this wide: enough for the HUD and the kill feed, far fewer tokens.
const MAX_WIDTH: u32 = 1600;

pub struct Gamer {
    pub store: Mutex<ValorantStore>,
    /// A look is under way; the next one waits.
    busy: AtomicBool,
    /// The game was in front at the last check.
    in_front: AtomicBool,
    last_look: Mutex<Option<(Instant, DateTime<Utc>)>>,
    last_error: Mutex<Option<String>>,
}

/// A finished match, short, for the history list.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MatchSummary {
    pub id: String,
    pub started: DateTime<Utc>,
    pub map: Option<String>,
    pub my_agent: Option<String>,
    pub rounds: u32,
    pub patterns: usize,
}

/// Everything the Valorant Coach page shows.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CoachView {
    pub prefs: GamerPrefs,
    /// Valorant is the window in front right now.
    pub in_game: bool,
    pub looking: bool,
    pub last_look: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub current: Option<Match>,
    pub analysis: Option<Analysis>,
    pub history: Vec<MatchSummary>,
}

pub fn setup(app: &AppHandle) {
    app.manage(Gamer {
        store: Mutex::new(ValorantStore::open_default()),
        busy: AtomicBool::new(false),
        in_front: AtomicBool::new(false),
        last_look: Mutex::new(None),
        last_error: Mutex::new(None),
    });
}

impl Gamer {
    pub fn with_store<T>(&self, f: impl FnOnce(&mut ValorantStore) -> T) -> T {
        let mut store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut store);
        store.save();
        out
    }

    pub fn view(&self) -> CoachView {
        let store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        CoachView {
            prefs: store.prefs.clone(),
            in_game: self.in_front.load(Ordering::SeqCst),
            looking: self.busy.load(Ordering::SeqCst),
            last_look: self.last_look.lock().unwrap_or_else(|e| e.into_inner()).map(|(_, at)| at),
            last_error: self.last_error.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            analysis: store.current.as_ref().map(coach::analyze),
            current: store.current.clone(),
            history: store
                .history
                .iter()
                .map(|m| MatchSummary {
                    id: m.id.clone(),
                    started: m.started,
                    map: m.map.clone(),
                    my_agent: m.my_agent.clone(),
                    rounds: m.current_round(),
                    patterns: coach::patterns(m).iter().filter(|p| p.occurrences >= 2).count(),
                })
                .collect(),
        }
    }
}

/// Tells every window the coach changed.
pub fn changed(app: &AppHandle) {
    let view = app.state::<Gamer>().view();
    crate::services::emit(app, "valorant-updated", view);
}

/// Valorant is the app in front.
fn valorant_in_front(app: &AppHandle) -> bool {
    let services = app.state::<Services>();
    services.platform.screen.active_app().and_then(|a| nook_core::games::game_for_process(&a.id)).is_some_and(|g| g.id == valorant::GAME_ID)
}

/// A smaller JPEG of the screenshot.
fn shrink(png: &[u8]) -> Result<PromptImage, String> {
    let image = image::load_from_memory(png).map_err(|e| e.to_string())?;
    let image = if image.width() > MAX_WIDTH { image.resize(MAX_WIDTH, u32::MAX, image::imageops::FilterType::Triangle) } else { image };
    let mut jpeg = Vec::new();
    image.to_rgb8().write_to(&mut Cursor::new(&mut jpeg), image::ImageFormat::Jpeg).map_err(|e| e.to_string())?;
    Ok(PromptImage { media_type: "image/jpeg".into(), base64: base64::engine::general_purpose::STANDARD.encode(jpeg) })
}

/// Takes a screenshot, lets the brain read it, and remembers what it saw. Returns how many events it added. Never
/// while the game is switched off: off means no screenshots and no requests to the brain.
pub async fn look(app: &AppHandle) -> Result<usize, String> {
    let gamer = app.state::<Gamer>();
    if !gamer.store.lock().unwrap_or_else(|e| e.into_inner()).prefs.enabled {
        return Err("Valorant is switched off in Gamer Mode.".into());
    }
    if gamer.busy.swap(true, Ordering::SeqCst) {
        return Ok(0);
    }
    changed(app);
    let result = look_inner(app).await;
    *gamer.last_look.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), Utc::now()));
    *gamer.last_error.lock().unwrap_or_else(|e| e.into_inner()) = result.as_ref().err().cloned();
    gamer.busy.store(false, Ordering::SeqCst);
    changed(app);
    result
}

async fn look_inner(app: &AppHandle) -> Result<usize, String> {
    if !crate::services::screen::allowed(app) {
        return Err("Your screen is set to stay on this computer, and the chosen brain is external.".into());
    }
    let services = app.state::<Services>();
    let capture = services.platform.screen.capture_screen()?;
    let image = tauri::async_runtime::spawn_blocking(move || shrink(&capture.png)).await.map_err(|e| e.to_string())??;
    let gamer = app.state::<Gamer>();
    let brief = {
        let mut store = gamer.store.lock().unwrap_or_else(|e| e.into_inner());
        let m = store.current_or_start(Utc::now());
        coach::memory_brief(m, &coach::patterns(m))
    };
    let state = app.state::<AppState>();
    let settings = state.settings();
    let key = state.key_for(settings.provider);
    let answer = tokio::time::timeout(
        Duration::from_secs(60),
        rewrite::complete_seeing(&settings, key, observe::SYSTEM, &observe::prompt(&brief), &[image], 1024),
    )
    .await
    .map_err(|_| "The brain took too long to read the screenshot.".to_string())?
    .map_err(|e| e.0)?;
    let observation = observe::parse(&answer).ok_or("The brain's answer was not readable.")?;
    Ok(gamer.with_store(|store| valorant::apply(store.current_or_start(Utc::now()), observation, Utc::now())))
}

/// Watches for the game while Gamer Mode is on: every few seconds a look, only while Valorant is in front.
#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::Builder::new()
        .name("nook-gamer".into())
        .spawn(move || loop {
            std::thread::sleep(Duration::from_secs(1));
            let gamer = app.state::<Gamer>();
            let prefs = gamer.store.lock().unwrap_or_else(|e| e.into_inner()).prefs.clone();
            let in_front = prefs.enabled && valorant_in_front(&app);
            if gamer.in_front.swap(in_front, Ordering::SeqCst) != in_front {
                changed(&app);
            }
            if !in_front || gamer.busy.load(Ordering::SeqCst) {
                continue;
            }
            let due = gamer
                .last_look
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .is_none_or(|(at, _)| at.elapsed() >= Duration::from_secs(prefs.interval() as u64));
            if due {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = look(&app).await;
                });
            }
        })
        .ok();
}
