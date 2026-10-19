//! De staat van het brein in de app: het geheugen, de adressen die het brein mag openen, wat de gebruiker in plannen
//! veranderde (om gewoontes te leren) en wat er net uitgevoerd is (om ongedaan te maken).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use nook_core::brain::memory::NookMemory;
use nook_core::brain::web::KnownUrls;
use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::state::AppState;

/// Een uitgevoerde actie, voor "maak ongedaan".
#[derive(Clone, Debug)]
pub struct Done {
    pub tool: String,
    pub input: Value,
    pub result: String,
    pub date: DateTime<Utc>,
}

pub struct BrainState {
    pub memory: Arc<NookMemory>,
    pub urls: Arc<KnownUrls>,
    /// De waarde van een voorgesteld veld voor de eerste aanpassing ("bericht#stap#veld" → oud).
    pub edit_origins: Mutex<HashMap<String, String>>,
    pub done: Mutex<Vec<Done>>,
    /// Lopende downloads van modellen, zodat er niet twee tegelijk van hetzelfde model lopen.
    pub pulling: Mutex<std::collections::HashSet<String>>,
}

impl BrainState {
    pub fn remember_done(&self, tool: &str, input: &Value, result: &str) {
        let mut done = self.done.lock().unwrap_or_else(|e| e.into_inner());
        done.push(Done { tool: tool.into(), input: input.clone(), result: result.into(), date: Utc::now() });
        let len = done.len();
        if len > 50 {
            done.drain(..len - 50);
        }
    }
}

pub fn setup(app: &AppHandle) {
    let store = app.state::<AppState>().store.clone();
    app.manage(BrainState {
        memory: Arc::new(NookMemory::new(store)),
        urls: Arc::new(KnownUrls::default()),
        edit_origins: Mutex::default(),
        done: Mutex::default(),
        pulling: Mutex::default(),
    });
}

/// Het geheugen van deze computer in GB: Linux en Android uit /proc/meminfo, Windows via het systeem.
pub fn memory_gb() -> u64 {
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut status = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..unsafe { std::mem::zeroed() } };
        // SAFETY: `status` is een geldige, op de juiste lengte gezette MEMORYSTATUSEX.
        if unsafe { GlobalMemoryStatusEx(&mut status) } != 0 {
            return ((status.ullTotalPhys as f64 / 1_073_741_824.0) + 0.5) as u64;
        }
        8
    }
    #[cfg(not(target_os = "windows"))]
    {
        nook_core::brain::profile::system_memory_gb().unwrap_or(8)
    }
}

/// De IANA-tijdzone van deze computer ("Europe/Amsterdam"), als die te lezen is.
pub fn timezone() -> Option<String> {
    iana_time_zone::get_timezone().ok()
}

/// Het land voor de zoektool van Claude, uit de taalinstelling van het systeem ("nl-NL" → "NL").
pub fn country() -> Option<String> {
    let locale = std::env::var("LC_ALL").or_else(|_| std::env::var("LANG")).ok()?;
    let region = locale.split(['.', '@']).next()?.split(['_', '-']).nth(1)?;
    (region.len() == 2).then(|| region.to_uppercase())
}
