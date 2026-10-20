//! De platformdiensten in de app: scherm meelezen, meekijken en meedenken, muziek, praten en voorlezen, Flow, de
//! Notetaker, Vandaag en het weekoverzicht. Eigen staat (`Services`), eigen vensters, eigen sneltoetsen; de regels
//! staan in `nook_core::services`, het platform in `crate::platform`.

pub mod energy;
pub mod flow;
pub mod media;
pub mod notes;
pub mod part;
pub mod quiet;
pub mod screen;
pub mod speech;
pub mod think;
pub mod voice;
pub mod windows;

use std::sync::{Arc, Mutex, RwLock};
use std::time::Instant;

use nook_core::services::flow::FlowStore;
use nook_core::services::notes::NoteStore;
use nook_core::services::prefs::ServicePrefs;
use nook_core::services::recap::RecapStore;
use nook_core::services::screen::LiveScreen;
use nook_core::services::think_along::{Nudge, ThinkAlong};
use tauri::{AppHandle, Emitter, Manager};

use crate::platform::{self, Platform};

/// Alles wat de diensten delen. Eén exemplaar, beheerd door Tauri naast `AppState`.
pub struct Services {
    pub platform: Platform,
    pub prefs: RwLock<ServicePrefs>,
    pub live: Mutex<LiveScreen>,
    pub think: Mutex<ThinkAlong>,
    /// Het aanbod van meedenken dat nog op een antwoord wacht (of gemist is, voor Vandaag).
    pub nudge: Mutex<Option<Nudge>>,
    pub flow: Mutex<FlowStore>,
    pub notes: Mutex<NoteStore>,
    /// Gedeeld met de hub en de werkruimte, die het weekoverzicht voeden.
    pub recap: Arc<Mutex<RecapStore>>,
    pub voice: voice::VoiceState,
    pub speech: speech::SpeechState,
    pub flow_state: flow::FlowState,
    pub note_session: notes::NoteSession,
    pub part: Mutex<Option<part::Pending>>,
    /// The energy plan every background worker follows.
    pub energy: energy::EnergyState,
    /// What Nook does in a meeting or while you share your screen.
    pub quiet: quiet::QuietWatchState,
    started: Instant,
}

impl Services {
    pub fn prefs(&self) -> ServicePrefs {
        self.prefs.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn update_prefs(&self, f: impl FnOnce(&mut ServicePrefs)) -> ServicePrefs {
        let mut guard = self.prefs.write().unwrap_or_else(|e| e.into_inner());
        f(&mut guard);
        let _ = guard.save();
        guard.clone()
    }

    /// Seconden sinds de start: de monotone klok van live meelezen en meedenken.
    pub fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }
}

/// Maakt de diensten en start wat op de achtergrond loopt. Vanuit `lib.rs` in `setup`.
pub fn setup(app: &AppHandle) {
    let platform = platform::services(app);
    let mut capabilities = platform::capabilities();
    platform::service_capabilities(&platform, &mut capabilities);
    platform::set_measured(capabilities);
    // De snelle opdrachten in de chat zoeken muziek en systeem als losse diensten.
    app.manage(platform.media.clone());
    app.manage(platform.system.clone());
    app.manage(Services {
        platform,
        prefs: RwLock::new(ServicePrefs::load()),
        live: Mutex::new(LiveScreen::default()),
        think: Mutex::new(ThinkAlong::default()),
        nudge: Mutex::new(None),
        flow: Mutex::new(FlowStore::open_default()),
        notes: Mutex::new(NoteStore::open_default()),
        recap: Arc::new(Mutex::new(RecapStore::open_default())),
        voice: Default::default(),
        speech: Default::default(),
        flow_state: Default::default(),
        note_session: Default::default(),
        part: Mutex::new(None),
        energy: Default::default(),
        quiet: Default::default(),
        started: Instant::now(),
    });
    energy::start(app);
    #[cfg(desktop)]
    {
        windows::create(app);
        screen::start(app);
        think::start(app);
        media::start(app);
        voice::start_wake_word(app);
        quiet::start(app);
    }
    speech::listen(app);
    // "Hé Nook" volgt de instelling.
    let handle = app.clone();
    let wake = std::sync::atomic::AtomicBool::new(handle.state::<crate::state::AppState>().settings().wake_word);
    tauri::Listener::listen_any(app, "settings-changed", move |_| {
        let on = handle.state::<crate::state::AppState>().settings().wake_word;
        if wake.swap(on, std::sync::atomic::Ordering::SeqCst) != on {
            voice::start_wake_word(&handle);
        }
    });
}

/// De sneltoetsen van de diensten (Flow, schermdeel, Notetaker). `desktop::register_shortcuts` roept dit aan na
/// zijn eigen toetsen, omdat die eerst alles wist.
#[cfg(desktop)]
pub fn register_shortcuts(app: &AppHandle) {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
    let Some(services) = app.try_state::<Services>() else { return };
    let prefs = services.prefs();
    let flow = services.flow.lock().unwrap_or_else(|e| e.into_inner()).settings.clone();
    let manager = app.global_shortcut();
    let mut keys: Vec<(String, &'static str)> = vec![];
    if !prefs.screen_part_shortcut.trim().is_empty() {
        keys.push((prefs.screen_part_shortcut.clone(), "screenPart"));
    }
    if !prefs.notes_shortcut.trim().is_empty() {
        keys.push((prefs.notes_shortcut.clone(), "notes"));
    }
    if flow.enabled && !flow.key.trim().is_empty() {
        keys.push((flow.key.clone(), "flow"));
    }
    for (accelerator, action) in keys {
        let result = manager.on_shortcut(accelerator.as_str(), move |app, _shortcut, event| match (action, event.state()) {
            ("flow", ShortcutState::Pressed) => flow::key_down(app),
            ("flow", ShortcutState::Released) => flow::key_up(app),
            ("screenPart", ShortcutState::Pressed) => part::begin(app),
            ("notes", ShortcutState::Pressed) => notes::toggle(app),
            _ => {}
        });
        if let Err(e) = result {
            log::warn!("Sneltoets {accelerator} kon niet worden vastgelegd: {e}");
        }
    }
}

/// Een kort bericht aan de interface (alle vensters).
pub fn emit<S: serde::Serialize + Clone>(app: &AppHandle, event: &str, payload: S) {
    let _ = app.emit(event, payload);
}
