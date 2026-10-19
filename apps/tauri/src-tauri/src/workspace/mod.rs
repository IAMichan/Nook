//! De werkruimte in de app: sessies die Nook zelf draait, git, terminals, de browser en de brug voor agents.

pub mod bridge_cli;

use nook_core::agents::models::{AgentApproval, ApprovalDecision};
use tauri::AppHandle;

/// Toestemmingsvragen van sessies die Nook draait en van de werkruimte-brug.
pub fn pending_approvals(_app: &AppHandle) -> Vec<AgentApproval> {
    vec![]
}

pub fn decide_approval(_app: &AppHandle, _id: &str, _decision: ApprovalDecision) -> Result<(), String> {
    Err("Deze vraag bestaat niet meer.".into())
}
