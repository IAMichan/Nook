//! The companion's `inbox` area on Windows and Linux: what the Mac's `CompanionServer` answers for these ops, from this
//! app's own state. To be filled in; until then it lists no feature, so a phone does not ask.

use nook_core::companion::{CompanionRequest, CompanionResponse};
use tauri::AppHandle;

/// The `feature` names this area can answer.
pub fn features(_app: &AppHandle) -> Vec<&'static str> {
    Vec::new()
}

/// The answer to one of this area's ops; `None` when it cannot.
pub async fn handle(_app: &AppHandle, _request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    None
}
