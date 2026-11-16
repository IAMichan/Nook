//! When Nook keeps this computer awake, so the phone can reach it away from home (`KeepAwakePolicy.swift` on the Mac,
//! docs/COMPANION.md, "Keeping the Mac awake"). A computer that sleeps drops its connection to the relay and to
//! Tailscale just as one that is off. The rules live here, without the operating system, so they are tested; the app
//! holds the actual sleep block (`SetThreadExecutionState` on Windows, `systemd-inhibit` on Linux).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeepAwakeMode {
    Off,
    /// While agents work or wait on you, a little after, and while a phone is connected.
    #[default]
    WhileWorking,
    /// Whenever the companion is on (on battery only while there is work or a phone).
    Always,
}

/// What is held: nothing; no idle sleep (the screen may still turn off); or no sleep at all while on power.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Hold {
    None,
    Idle,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    Working,
    Phone,
    Always,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Decision {
    pub hold: Hold,
    pub reason: Option<Reason>,
}

impl Decision {
    pub const NONE: Decision = Decision { hold: Hold::None, reason: None };
}

/// After the last work, the computer stays awake this long, so an answer or a follow-up from the phone still finds it.
pub const GRACE_SECONDS: i64 = 5 * 60;
/// On battery, below this charge (percent) the computer is left to sleep.
pub const LOW_BATTERY: u8 = 20;
/// A phone that was heard from this recently counts as connected.
pub const PHONE_RECENT_SECONDS: i64 = 2 * 60;

/// `busy`: agents work or wait on you, or did within [`GRACE_SECONDS`]. `battery` is `None` without one.
pub fn decide(mode: KeepAwakeMode, busy: bool, phone_connected: bool, on_power: bool, battery: Option<u8>) -> Decision {
    let reason = match mode {
        KeepAwakeMode::Off => None,
        KeepAwakeMode::WhileWorking => {
            if busy {
                Some(Reason::Working)
            } else if phone_connected {
                Some(Reason::Phone)
            } else {
                None
            }
        }
        KeepAwakeMode::Always => Some(if busy {
            Reason::Working
        } else if phone_connected {
            Reason::Phone
        } else {
            Reason::Always
        }),
    };
    let Some(reason) = reason else { return Decision::NONE };
    if on_power {
        return Decision { hold: Hold::System, reason: Some(reason) };
    }
    // On battery: never when it runs low, and "always" only for work or a phone, not for an idle computer.
    if battery.is_some_and(|b| b < LOW_BATTERY) || reason == Reason::Always {
        return Decision::NONE;
    }
    Decision { hold: Hold::Idle, reason: Some(reason) }
}

/// Whether a session keeps the computer busy: it works, or waits for an approval or an answer you may give from the phone.
pub fn is_busy(attention: &str, waiting: bool) -> bool {
    waiting || matches!(attention, "working" | "approval" | "input")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_the_mac_rules() {
        use KeepAwakeMode::*;
        assert_eq!(decide(Off, true, true, true, None), Decision::NONE);
        assert_eq!(decide(WhileWorking, false, false, true, None), Decision::NONE);
        assert_eq!(decide(WhileWorking, true, false, true, None), Decision { hold: Hold::System, reason: Some(Reason::Working) });
        assert_eq!(decide(WhileWorking, false, true, false, Some(80)), Decision { hold: Hold::Idle, reason: Some(Reason::Phone) });
        assert_eq!(decide(Always, false, false, true, None), Decision { hold: Hold::System, reason: Some(Reason::Always) });
        // On battery: "always" alone is not enough, and a low battery wins over everything.
        assert_eq!(decide(Always, false, false, false, Some(90)), Decision::NONE);
        assert_eq!(decide(Always, true, false, false, Some(19)), Decision::NONE);
        assert_eq!(decide(Always, true, false, false, Some(20)), Decision { hold: Hold::Idle, reason: Some(Reason::Working) });
    }

    #[test]
    fn busy_sessions() {
        assert!(is_busy("working", false));
        assert!(is_busy("approval", false));
        assert!(is_busy("idle", true));
        assert!(!is_busy("finished", false));
    }

    #[test]
    fn mode_reads_as_stored() {
        assert_eq!(serde_json::to_string(&KeepAwakeMode::WhileWorking).unwrap(), "\"whileWorking\"");
        assert_eq!(serde_json::from_str::<KeepAwakeMode>("\"always\"").unwrap(), KeepAwakeMode::Always);
    }
}
