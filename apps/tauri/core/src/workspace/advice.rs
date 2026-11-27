//! Quiet agent advice (`AgentAdvice` on macOS): account-switch suggestions when hitting a usage limit (`LimitAdvisor`)
//! and stuck-session detection (`StuckDetector`). Pure data decisions without UI or processes.

use std::cmp::Ordering;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::models::{RunProvider, RunStatus};

/// One account's usage-limit snapshot for `LimitAdvisor`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitState {
    pub provider: RunProvider,
    pub profile_id: String,
    /// `0.0..=1.0`, `None` when unknown.
    pub used_fraction: Option<f64>,
    pub reset_at: Option<DateTime<Utc>>,
}

/// An alternative account to continue with when the current account is near or at its usage limit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitSuggestion {
    pub provider: RunProvider,
    pub profile_id: String,
    pub same_agent: bool,
    /// How much of the suggested account's limit is used (`0.0..=1.0`); `None` when unknown.
    pub used_fraction: Option<f64>,
    /// Seconds until the current account resets, for "or wait N".
    pub resume_in: Option<f64>,
}

/// Recommends accounts with remaining capacity when the current account hits its usage limit.
pub struct LimitAdvisor;

impl LimitAdvisor {
    pub const LIMITED_AT: f64 = 0.9;
    pub const FREE_BELOW: f64 = 0.7;

    /// Best account to switch to, or `None` when the current account still has room or no alternative exists.
    pub fn suggest(states: &[LimitState], current: (RunProvider, &str), now: DateTime<Utc>) -> Option<LimitSuggestion> {
        Self::options(states, current, now).into_iter().next()
    }

    /// Every account to go on with, best first: same agent first (its context and skills carry over), then the least
    /// used of the rest; accounts whose use is unknown only after those, same agent first again. Accounts that are
    /// nearly full themselves (`>= FREE_BELOW`) are left out. Empty while the current account still has room.
    pub fn options(states: &[LimitState], current: (RunProvider, &str), now: DateTime<Utc>) -> Vec<LimitSuggestion> {
        let Some(me) = states.iter().find(|s| s.provider == current.0 && s.profile_id == current.1) else {
            return vec![];
        };
        let Some(used) = me.used_fraction else { return vec![] };
        if used < Self::LIMITED_AT {
            return vec![];
        }
        let others: Vec<&LimitState> = states.iter().filter(|s| !(s.provider == current.0 && s.profile_id == current.1)).collect();
        let mut known: Vec<&LimitState> = others.iter().copied().filter(|s| s.used_fraction.unwrap_or(1.0) < Self::FREE_BELOW).collect();
        known.sort_by(|a, b| a.used_fraction.unwrap_or(1.0).partial_cmp(&b.used_fraction.unwrap_or(1.0)).unwrap_or(Ordering::Equal));
        let unknown: Vec<&LimitState> = others.into_iter().filter(|s| s.used_fraction.is_none()).collect();
        fn same_first<'a>(list: Vec<&'a LimitState>, provider: RunProvider) -> Vec<&'a LimitState> {
            let mut out: Vec<&'a LimitState> = list.iter().copied().filter(|s| s.provider == provider).collect();
            out.extend(list.into_iter().filter(|s| s.provider != provider));
            out
        }
        let resume_in = me.reset_at.map(|r| (r - now).num_milliseconds().max(0) as f64 / 1000.0);
        same_first(known, current.0)
            .into_iter()
            .chain(same_first(unknown, current.0))
            .map(|s| LimitSuggestion {
                provider: s.provider,
                profile_id: s.profile_id.clone(),
                same_agent: s.provider == current.0,
                used_fraction: s.used_fraction,
                resume_in,
            })
            .collect()
    }

    /// The accounts to offer when [`Self::options`] has none: the others that are filling up but not full yet
    /// (`used_fraction < 1.0`), least used first (same agent first when equally used), so the usage limit card can
    /// still propose one to go on with.
    pub fn fallbacks(states: &[LimitState], current: (RunProvider, &str), now: DateTime<Utc>) -> Vec<LimitSuggestion> {
        let Some(me) = states.iter().find(|s| s.provider == current.0 && s.profile_id == current.1) else {
            return vec![];
        };
        let Some(used) = me.used_fraction else { return vec![] };
        if used < Self::LIMITED_AT {
            return vec![];
        }
        let resume_in = me.reset_at.map(|r| (r - now).num_milliseconds().max(0) as f64 / 1000.0);
        let mut roomy: Vec<(&LimitState, f64)> = states
            .iter()
            .filter(|s| !(s.provider == current.0 && s.profile_id == current.1))
            .filter_map(|s| s.used_fraction.filter(|&f| f < 1.0).map(|f| (s, f)))
            .collect();
        roomy.sort_by(|(ls, lf), (rs, rf)| {
            lf.partial_cmp(rf).unwrap_or(Ordering::Equal).then_with(|| {
                let l_same = ls.provider == current.0;
                let r_same = rs.provider == current.0;
                r_same.cmp(&l_same)
            })
        });
        roomy
            .into_iter()
            .map(|(s, fraction)| LimitSuggestion {
                provider: s.provider,
                profile_id: s.profile_id.clone(),
                same_agent: s.provider == current.0,
                used_fraction: Some(fraction),
                resume_in,
            })
            .collect()
    }
}

/// Snapshot of a session's liveness passed to [`StuckDetector::detect`].
#[derive(Debug, Clone, PartialEq)]
pub struct StuckInput {
    pub status: RunStatus,
    pub last_activity: Option<DateTime<Utc>>,
    pub pending_request_since: Option<DateTime<Utc>>,
    pub user_idle_seconds: f64,
    pub limited_since: Option<DateTime<Utc>>,
    pub now: DateTime<Utc>,
}

/// Why a session appears stuck.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StuckSuggestion {
    WaitingOnYou { minutes: i64 },
    NoProgress { minutes: i64 },
    LimitedForLong { minutes: i64 },
}

/// Detects sessions waiting too long on an approval/question, stalled while running, or stuck on a usage limit.
pub struct StuckDetector;

impl StuckDetector {
    pub const REQUEST_MINUTES: f64 = 5.0;
    pub const NO_PROGRESS_MINUTES: f64 = 10.0;
    pub const LIMITED_MINUTES: f64 = 30.0;

    pub fn detect(input: &StuckInput) -> Option<StuckSuggestion> {
        let minutes_since = |date: DateTime<Utc>| -> f64 { (input.now - date).num_milliseconds() as f64 / 60_000.0 };
        if let Some(since) = input.pending_request_since {
            let mins = minutes_since(since);
            if mins > Self::REQUEST_MINUTES && input.user_idle_seconds > Self::REQUEST_MINUTES * 60.0 {
                return Some(StuckSuggestion::WaitingOnYou { minutes: mins as i64 });
            }
        }
        if let Some(since) = input.limited_since {
            let mins = minutes_since(since);
            if mins > Self::LIMITED_MINUTES {
                return Some(StuckSuggestion::LimitedForLong { minutes: mins as i64 });
            }
        }
        if input.status == RunStatus::Running && input.pending_request_since.is_none() {
            if let Some(last) = input.last_activity {
                let mins = minutes_since(last);
                if mins > Self::NO_PROGRESS_MINUTES {
                    return Some(StuckSuggestion::NoProgress { minutes: mins as i64 });
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use chrono::Duration;

    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(100_000, 0).unwrap()
    }

    fn st(provider: RunProvider, id: &str, used: Option<f64>, reset: Option<DateTime<Utc>>) -> LimitState {
        LimitState { provider, profile_id: id.into(), used_fraction: used, reset_at: reset }
    }

    #[test]
    fn suggests_same_agent_other_account_first() {
        let n = now();
        let states = vec![
            st(RunProvider::Claude, "a", Some(0.95), Some(n + Duration::seconds(600))),
            st(RunProvider::Codex, "c", Some(0.1), None),
            st(RunProvider::Claude, "b", Some(0.5), None),
        ];
        assert_eq!(
            LimitAdvisor::suggest(&states, (RunProvider::Claude, "a"), n),
            Some(LimitSuggestion {
                provider: RunProvider::Claude,
                profile_id: "b".into(),
                same_agent: true,
                used_fraction: Some(0.5),
                resume_in: Some(600.0),
            })
        );
    }

    #[test]
    fn options_list_every_roomy_account_best_first() {
        let n = now();
        let states = vec![
            st(RunProvider::Claude, "a", Some(0.95), None),
            st(RunProvider::Codex, "c", Some(0.1), None),
            st(RunProvider::Claude, "b", Some(0.5), None),
            st(RunProvider::Gemini, "g", None, None),
            st(RunProvider::Claude, "u", None, None),
            st(RunProvider::Codex, "full", Some(0.8), None),
        ];
        let opts = LimitAdvisor::options(&states, (RunProvider::Claude, "a"), n);
        let ids: Vec<&str> = opts.iter().map(|s| s.profile_id.as_str()).collect();
        assert_eq!(ids, vec!["b", "c", "u", "g"]);
        assert_eq!(opts[0].used_fraction, Some(0.5));
        assert!(LimitAdvisor::options(
            &[st(RunProvider::Claude, "a", Some(0.5), None), st(RunProvider::Codex, "c", Some(0.1), None)],
            (RunProvider::Claude, "a"),
            n
        )
        .is_empty());
    }

    #[test]
    fn other_agent_when_no_same_agent_and_thresholds() {
        let n = now();
        let states = vec![
            st(RunProvider::Claude, "a", Some(0.9), None),
            st(RunProvider::Claude, "b", Some(0.7), None),
            st(RunProvider::Codex, "c", Some(0.69), None),
        ];
        assert_eq!(LimitAdvisor::suggest(&states, (RunProvider::Claude, "a"), n).map(|s| s.provider), Some(RunProvider::Codex));
        assert_eq!(
            LimitAdvisor::suggest(
                &[st(RunProvider::Claude, "a", Some(0.89), None), st(RunProvider::Codex, "c", Some(0.1), None)],
                (RunProvider::Claude, "a"),
                n
            ),
            None
        );
    }

    #[test]
    fn unknown_only_as_last_resort_and_all_limited() {
        let n = now();
        let states = vec![
            st(RunProvider::Claude, "a", Some(0.95), None),
            st(RunProvider::Codex, "c", None, None),
            st(RunProvider::Claude, "b", Some(0.8), None),
        ];
        assert_eq!(LimitAdvisor::suggest(&states, (RunProvider::Claude, "a"), n).map(|s| s.profile_id), Some("c".into()));
        let mut known = states.clone();
        known.push(st(RunProvider::Codex, "d", Some(0.2), None));
        assert_eq!(LimitAdvisor::suggest(&known, (RunProvider::Claude, "a"), n).map(|s| s.profile_id), Some("d".into()));
        assert_eq!(
            LimitAdvisor::suggest(
                &[st(RunProvider::Claude, "a", Some(0.95), None), st(RunProvider::Claude, "b", Some(0.99), None)],
                (RunProvider::Claude, "a"),
                n
            ),
            None
        );
        assert_eq!(
            LimitAdvisor::suggest(
                &[st(RunProvider::Claude, "a", None, None), st(RunProvider::Codex, "c", Some(0.1), None)],
                (RunProvider::Claude, "a"),
                n
            ),
            None
        );
        assert_eq!(LimitAdvisor::suggest(&[], (RunProvider::Claude, "a"), n), None);
    }

    #[test]
    fn fallbacks_offer_filling_accounts_when_none_has_room() {
        let n = now();
        let states = vec![
            st(RunProvider::Claude, "a", Some(1.0), None),
            st(RunProvider::Claude, "b", Some(0.8), None),
            st(RunProvider::Codex, "c", Some(0.75), None),
            st(RunProvider::Codex, "full", Some(1.0), None),
            st(RunProvider::Gemini, "g", None, None),
            st(RunProvider::Claude, "same", Some(0.75), None),
        ];
        let picks = LimitAdvisor::fallbacks(&states, (RunProvider::Claude, "a"), n);
        let ids: Vec<&str> = picks.iter().map(|s| s.profile_id.as_str()).collect();
        assert_eq!(ids, vec!["same", "c", "b"]);
        assert!(picks[0].same_agent);
        assert!(LimitAdvisor::fallbacks(
            &[st(RunProvider::Claude, "a", Some(0.5), None), st(RunProvider::Codex, "c", Some(0.8), None)],
            (RunProvider::Claude, "a"),
            n
        )
        .is_empty());
    }

    fn stuck_input(
        status: RunStatus,
        last_secs: Option<i64>,
        pending_secs: Option<i64>,
        idle: f64,
        limited_secs: Option<i64>,
    ) -> StuckInput {
        let n = now();
        StuckInput {
            status,
            last_activity: last_secs.map(|s| n - Duration::seconds(s)),
            pending_request_since: pending_secs.map(|s| n - Duration::seconds(s)),
            user_idle_seconds: idle,
            limited_since: limited_secs.map(|s| n - Duration::seconds(s)),
            now: n,
        }
    }

    #[test]
    fn stuck_detector_waiting_no_progress_and_limited() {
        assert_eq!(
            StuckDetector::detect(&stuck_input(RunStatus::WaitingApproval, None, Some(360), 400.0, None)),
            Some(StuckSuggestion::WaitingOnYou { minutes: 6 })
        );
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::WaitingApproval, None, Some(360), 10.0, None)), None);
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::WaitingApproval, None, Some(240), 400.0, None)), None);

        assert_eq!(
            StuckDetector::detect(&stuck_input(RunStatus::Running, Some(700), None, 0.0, None)),
            Some(StuckSuggestion::NoProgress { minutes: 11 })
        );
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::Running, Some(500), None, 0.0, None)), None);
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::Completed, Some(5000), None, 0.0, None)), None);
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::Running, Some(5000), Some(10), 0.0, None)), None);
        assert_eq!(
            StuckDetector::detect(&stuck_input(RunStatus::Failed, None, None, 0.0, Some(3600))),
            Some(StuckSuggestion::LimitedForLong { minutes: 60 })
        );
        assert_eq!(StuckDetector::detect(&stuck_input(RunStatus::Failed, None, None, 0.0, Some(60))), None);
    }
}
