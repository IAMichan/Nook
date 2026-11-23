//! Keeps the programs Nook installed for you up to date, the way Nook keeps itself (`ToolUpdates` on the Mac): shortly
//! after launch and then once a day, each only when you installed it. GOWA (the WhatsApp gateway) comes to its newest
//! release with the same download and checks as installing it; Antigravity comes to the release this Nook pins. Nothing
//! that was not installed is installed, and a check that fails waits for the next one.
//!
//! Not here: the ACP agents downloaded from the registry. Nook on Windows has no ACP registry install yet, so there is
//! nothing of that kind to update (see docs/WINDOWS-PARITY.md, SV-04).

use std::path::PathBuf;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Shortly after launch: not while Nook itself is starting.
pub const FIRST_CHECK: Duration = Duration::from_secs(60);
/// How often the clock is looked at; the check itself runs at most once a day.
pub const TICK: Duration = Duration::from_secs(3600);
pub const INTERVAL: chrono::Duration = chrono::Duration::hours(24);

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub last_check: Option<DateTime<Utc>>,
}

fn file() -> PathBuf {
    crate::paths::support_directory().join("tool-updates.json")
}

pub fn load() -> State {
    std::fs::read(file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save(state: &State) {
    if let Ok(bytes) = serde_json::to_vec(state) {
        let _ = crate::paths::write_atomic(&file(), &bytes);
    }
}

/// At most once a day, also across launches (a minute of slack so a tick just before the mark is not skipped).
pub fn due(last: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
    last.map_or(true, |last| now - last >= INTERVAL - chrono::Duration::seconds(60))
}

/// GOWA is updated only when Nook's own copy is the one in use.
pub fn gowa_due(nooks_own: bool, version: &str) -> bool {
    nooks_own && !version.trim().is_empty()
}

/// Antigravity is updated when Nook installed one that is not the pinned release.
pub fn antigravity_due(was_installed: bool, pinned_ready: bool) -> bool {
    was_installed && !pinned_ready
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_once_a_day() {
        let now = Utc::now();
        assert!(due(None, now));
        assert!(!due(Some(now - chrono::Duration::hours(3)), now));
        assert!(due(Some(now - chrono::Duration::hours(24)), now));
        assert!(due(Some(now - chrono::Duration::seconds(24 * 3600 - 30)), now));
    }

    #[test]
    fn only_what_was_installed_is_updated() {
        assert!(gowa_due(true, "v8.1.0"));
        assert!(!gowa_due(false, "v8.1.0"));
        assert!(!gowa_due(true, ""));
        assert!(antigravity_due(true, false));
        assert!(!antigravity_due(false, false));
        assert!(!antigravity_due(true, true));
    }

    #[test]
    fn state_reads_an_empty_file() {
        assert_eq!(serde_json::from_str::<State>("{}").unwrap(), State { last_check: None });
    }
}
