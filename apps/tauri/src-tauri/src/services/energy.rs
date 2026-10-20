//! The one answer to "how much may Nook do by himself right now" (`EnergyMonitor` on the Mac), for every background
//! worker, so none of them reads the battery or the load on its own. The plan follows your choice in Settings ›
//! General › Energy and the computer's signals: read again every ten seconds and right after a change of settings.
//! Only a changed plan is sent to the interface (`energy-plan`).

use std::sync::RwLock;

use nook_core::services::energy::{self, EnergyPlan, EnergySignals};
use serde::Serialize;
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;

#[derive(Default)]
pub struct EnergyState {
    plan: RwLock<EnergyPlan>,
    signals: RwLock<EnergySignals>,
}

/// What Settings shows: the plan and the status line.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergyView {
    pub plan: EnergyPlan,
    pub signals: EnergySignals,
    pub status: String,
}

/// The current plan (full speed until the first reading).
pub fn plan(app: &AppHandle) -> EnergyPlan {
    app.try_state::<Services>().map(|s| s.energy.plan.read().unwrap_or_else(|e| e.into_inner()).clone()).unwrap_or_default()
}

pub fn view(app: &AppHandle) -> EnergyView {
    let services = app.state::<Services>();
    let plan = services.energy.plan.read().unwrap_or_else(|e| e.into_inner()).clone();
    let signals = *services.energy.signals.read().unwrap_or_else(|e| e.into_inner());
    EnergyView { status: plan.status_text(), plan, signals }
}

/// Reads the computer again and publishes the plan when it changed.
pub fn refresh(app: &AppHandle) {
    let Some(services) = app.try_state::<Services>() else { return };
    let mode = app.state::<AppState>().settings().energy_mode;
    let mut signals = services.platform.power.signals();
    signals.away = services.platform.screen.available() && services.platform.screen.idle_seconds() >= EnergySignals::AWAY_AFTER;
    *services.energy.signals.write().unwrap_or_else(|e| e.into_inner()) = signals;
    let next = energy::plan(&signals, mode);
    let changed = {
        let mut plan = services.energy.plan.write().unwrap_or_else(|e| e.into_inner());
        let changed = *plan != next;
        *plan = next;
        changed
    };
    if changed {
        super::emit(app, "energy-plan", view(app));
    }
}

/// Starts following the computer and your choice.
pub fn start(app: &AppHandle) {
    refresh(app);
    let handle = app.clone();
    tauri::Listener::listen_any(app, "settings-changed", move |_| refresh(&handle));
    #[cfg(desktop)]
    {
        let app = app.clone();
        std::thread::Builder::new()
            .name("nook-energie".into())
            .spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(10));
                refresh(&app);
            })
            .ok();
    }
}
