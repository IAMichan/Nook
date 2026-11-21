//! Shared pacing and daily interruption budget for notices (`NoticePacer` and `InterruptionBudget` on the Mac).
//!
//! Keeps notices Nook initiates on its own from piling up, the same for every source (agents, chats, Nook, and
//! Think Along). A notice held back by the pacer is still recorded in `NoticeLog` (history-only); it only skips
//! popping up or sounding. Urgent notices that wait on you (permission approvals, agent questions, calls) always
//! bypass pacing and budget. Offers (`Suggestion`) and Nook's own moments (`Moment`) share a small daily budget
//! that resets at midnight local date while preserving inter-interruption gaps across midnight.

use std::collections::BTreeMap;

use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};

use crate::services::notice_rules::NoticeSource;

/// What kind of interruption something is, for the shared daily budget (`InterruptionBudget`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InterruptionClass {
    /// Something that happened and that you asked to hear about: an agent that finished, a chat message.
    Notice,
    /// A Think Along offer about what is on your screen.
    Suggestion,
    /// One of Nook's own moments: a good morning, a break, a milestone.
    Moment,
}

impl InterruptionClass {
    pub const ALL: [Self; 3] = [Self::Notice, Self::Suggestion, Self::Moment];

    /// Maps a `NoticeSource` to its interruption class.
    pub fn from_notice_source(source: NoticeSource) -> Self {
        match source {
            NoticeSource::Suggestions => Self::Suggestion,
            NoticeSource::Agents | NoticeSource::Chats | NoticeSource::Nook => Self::Notice,
        }
    }
}

/// Formats a local timestamp as `"YYYY-MM-DD"`, used to reset daily budget counters at local midnight.
pub fn local_day_key(now: DateTime<Local>) -> String {
    now.format("%Y-%m-%d").to_string()
}

/// One day's budget for what Nook starts by itself without being asked: Think Along offers and moments share it,
/// so the two together stay rare. Notices (agents, chats) are what you asked to hear about: they are paced by
/// `NoticePacer`, not counted here. What waits on you is never counted. Resets at midnight local date; gaps carry
/// across midnight.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InterruptionBudget {
    /// Local date key (`YYYY-MM-DD`) the daily counts apply to.
    day: String,
    /// Count spent on `day`, by class.
    spent: BTreeMap<InterruptionClass, usize>,
    /// Unix timestamp in seconds when each class last interrupted (persists across midnight).
    last: BTreeMap<InterruptionClass, f64>,
}

impl InterruptionBudget {
    /// Offers and moments together per day.
    pub const DAILY_LIMIT: usize = 6;
    /// Minimum seconds between any two unasked interruptions (suggestion or moment), whatever their kind.
    pub const UNASKED_GAP_SECS: f64 = 10.0 * 60.0;
    /// Storage key matching macOS (`InterruptionBudget.storageKey`).
    pub const STORAGE_KEY: &'static str = "attention.budget.v1";

    /// Maximum count per day for one class; `None` means no per-class daily cap.
    pub fn limit(kind: InterruptionClass) -> Option<usize> {
        match kind {
            InterruptionClass::Notice => None,
            InterruptionClass::Suggestion => Some(4),
            InterruptionClass::Moment => Some(4),
        }
    }

    /// Minimum seconds between two interruptions of the same class.
    pub fn gap_secs(kind: InterruptionClass) -> f64 {
        match kind {
            InterruptionClass::Notice => 0.0,
            InterruptionClass::Suggestion => 15.0 * 60.0,
            InterruptionClass::Moment => 20.0 * 60.0,
        }
    }

    /// Decodes a persisted budget from JSON, falling back to a fresh budget if missing or invalid.
    pub fn from_json(data: Option<&str>) -> Self {
        data.and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default()
    }

    /// Encodes the budget as JSON for persistence across launches.
    pub fn to_json(&self) -> Option<String> {
        serde_json::to_string(self).ok()
    }

    /// The day key currently stored in the budget.
    pub fn day(&self) -> &str {
        &self.day
    }

    /// How many of `kind` were spent on `day_key` (0 once a new local day starts).
    pub fn spent(&self, kind: InterruptionClass, day_key: &str) -> usize {
        if self.day == day_key {
            self.spent.get(&kind).copied().unwrap_or(0)
        } else {
            0
        }
    }

    /// Remaining shared daily budget for unasked interruptions (suggestions + moments) on `day_key`.
    pub fn remaining_daily(&self, day_key: &str) -> usize {
        let unasked = self.spent(InterruptionClass::Suggestion, day_key) + self.spent(InterruptionClass::Moment, day_key);
        Self::DAILY_LIMIT.saturating_sub(unasked)
    }

    /// Whether one more interruption of `kind` may fire now.
    ///
    /// - `extra_gap_secs`: caller-specific backoff gap (e.g. Think Along backoff after ignored offers).
    /// - `gap_factor`: multiplier for gaps when the user repeatedly dismisses notices (clamped to `>= 1.0`).
    pub fn allows(
        &self,
        kind: InterruptionClass,
        now_secs: f64,
        day_key: &str,
        extra_gap_secs: f64,
        gap_factor: f64,
    ) -> bool {
        if kind == InterruptionClass::Notice {
            return true;
        }
        if let Some(limit) = Self::limit(kind) {
            if self.spent(kind, day_key) >= limit {
                return false;
            }
        }
        let unasked = self.spent(InterruptionClass::Suggestion, day_key) + self.spent(InterruptionClass::Moment, day_key);
        if unasked >= Self::DAILY_LIMIT {
            return false;
        }
        let factor = gap_factor.max(1.0);
        if let Some(&previous) = self.last.get(&kind) {
            if now_secs - previous < Self::gap_secs(kind).max(extra_gap_secs) * factor {
                return false;
            }
        }
        let last_unasked = [
            self.last.get(&InterruptionClass::Suggestion),
            self.last.get(&InterruptionClass::Moment),
        ]
        .into_iter()
        .flatten()
        .copied()
        .reduce(f64::max);
        if let Some(previous) = last_unasked {
            if now_secs - previous < Self::UNASKED_GAP_SECS * factor {
                return false;
            }
        }
        true
    }

    /// Records one interruption of `kind` at `now_secs` on `day_key`. Resets daily counts when `day_key` changes.
    pub fn spend(&mut self, kind: InterruptionClass, now_secs: f64, day_key: &str) {
        if self.day != day_key {
            self.day = day_key.to_string();
            self.spent.clear();
        }
        *self.spent.entry(kind).or_insert(0) += 1;
        self.last.insert(kind, now_secs);
    }
}

/// Keeps interruptive cards and toasts from piling up, uniformly across every source (agents, chats, Nook,
/// Think Along). Urgent notices (permission approvals, agent questions, calls) always pass through.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NoticePacer {
    shown: Vec<(f64, String)>,
    /// Daily budget shared between Think Along suggestions and Nook moments.
    pub budget: InterruptionBudget,
}

impl NoticePacer {
    /// Minimum seconds between any two pop-ups from any source.
    pub const GAP_SECS: f64 = 20.0;
    /// Minimum seconds between two pop-ups for the same source key (`agent:<id>`, `chat:<id>`).
    pub const SAME_KEY_GAP_SECS: f64 = 120.0;
    /// Maximum pop-ups within `BURST_WINDOW_SECS`; above this, notices stay in history until room opens.
    pub const BURST_LIMIT: usize = 4;
    /// Rolling window for burst limiting (10 minutes).
    pub const BURST_WINDOW_SECS: f64 = 600.0;

    pub fn new(budget: InterruptionBudget) -> Self {
        Self { shown: Vec::new(), budget }
    }

    /// Whether a notice about `key` may pop up now.
    ///
    /// - `urgent`: waits on the user (question, permission approval, call); always permitted.
    /// - `priority`: a chat that asks a question or mentions the user may pass a full burst; gaps still hold.
    /// - `calm_secs`: how long the surface must have been quiet before showing (e.g. 300s for suggestions).
    /// - `gap_factor`: stretches gaps when notices are dismissed; clamped to `>= 1.0`.
    pub fn permits(
        &self,
        key: &str,
        urgent: bool,
        priority: bool,
        calm_secs: f64,
        gap_factor: f64,
        now_secs: f64,
    ) -> bool {
        if urgent {
            return true;
        }
        let factor = gap_factor.max(1.0);
        let recent: Vec<&(f64, String)> = self
            .shown
            .iter()
            .filter(|(t, _)| now_secs - *t < Self::BURST_WINDOW_SECS)
            .collect();
        if let Some((last_t, _)) = recent.last() {
            if now_secs - *last_t < (Self::GAP_SECS * factor).max(calm_secs) {
                return false;
            }
        }
        if recent.iter().any(|(t, k)| k == key && now_secs - *t < Self::SAME_KEY_GAP_SECS * factor) {
            return false;
        }
        priority || recent.len() < Self::BURST_LIMIT
    }

    /// Checks both the daily `InterruptionBudget` (for suggestions/moments) and `NoticePacer::permits`.
    /// Urgent notices always bypass both budget and pacing.
    #[allow(clippy::too_many_arguments)]
    pub fn permits_class(
        &self,
        kind: InterruptionClass,
        key: &str,
        urgent: bool,
        priority: bool,
        calm_secs: f64,
        extra_gap_secs: f64,
        gap_factor: f64,
        now_secs: f64,
        day_key: &str,
    ) -> bool {
        if urgent {
            return true;
        }
        self.budget.allows(kind, now_secs, day_key, extra_gap_secs, gap_factor)
            && self.permits(key, false, priority, calm_secs, gap_factor, now_secs)
    }

    /// The earliest timestamp (`>= now_secs`) at which `permits` will let a notice for `key` through.
    pub fn next_permitted(
        &self,
        key: &str,
        priority: bool,
        calm_secs: f64,
        gap_factor: f64,
        now_secs: f64,
    ) -> f64 {
        let factor = gap_factor.max(1.0);
        let recent: Vec<&(f64, String)> = self
            .shown
            .iter()
            .filter(|(t, _)| now_secs - *t < Self::BURST_WINDOW_SECS)
            .collect();
        let mut at = now_secs;
        if let Some((last_t, _)) = recent.last() {
            at = at.max(*last_t + (Self::GAP_SECS * factor).max(calm_secs));
        }
        if let Some((same_t, _)) = recent.iter().rev().find(|(_, k)| k == key) {
            at = at.max(*same_t + Self::SAME_KEY_GAP_SECS * factor);
        }
        if !priority && recent.len() >= Self::BURST_LIMIT {
            at = at.max(recent[recent.len() - Self::BURST_LIMIT].0 + Self::BURST_WINDOW_SECS);
        }
        at
    }

    /// Records a pop-up that was shown so subsequent notices keep their distance.
    pub fn record(&mut self, key: &str, now_secs: f64) {
        self.shown.retain(|(t, _)| now_secs - *t < Self::BURST_WINDOW_SECS);
        self.shown.push((now_secs, key.to_string()));
    }

    /// Records a pop-up of `kind`; suggestions and moments also spend from the daily `budget`.
    pub fn record_class(&mut self, kind: InterruptionClass, key: &str, now_secs: f64, day_key: &str) {
        self.record(key, now_secs);
        if kind != InterruptionClass::Notice {
            self.budget.spend(kind, now_secs, day_key);
        }
    }

    /// Checks `permits`, and if allowed, records the pop-up.
    pub fn allow(
        &mut self,
        key: &str,
        urgent: bool,
        priority: bool,
        calm_secs: f64,
        gap_factor: f64,
        now_secs: f64,
    ) -> bool {
        if !self.permits(key, urgent, priority, calm_secs, gap_factor, now_secs) {
            return false;
        }
        self.record(key, now_secs);
        true
    }

    /// Checks `permits_class`, and if allowed, records the pop-up (spending daily budget for suggestions/moments).
    /// Returns `false` when paced or when the daily budget is exhausted, signaling history-only degradation.
    #[allow(clippy::too_many_arguments)]
    pub fn allow_class(
        &mut self,
        kind: InterruptionClass,
        key: &str,
        urgent: bool,
        priority: bool,
        calm_secs: f64,
        extra_gap_secs: f64,
        gap_factor: f64,
        now_secs: f64,
        day_key: &str,
    ) -> bool {
        if !self.permits_class(kind, key, urgent, priority, calm_secs, extra_gap_secs, gap_factor, now_secs, day_key) {
            return false;
        }
        if urgent {
            // Urgent notices keep subsequent non-urgent notices spaced out, without spending unasked budget.
            self.record(key, now_secs);
        } else {
            self.record_class(kind, key, now_secs, day_key);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const START: f64 = 1_800_000_000.0;
    const DAY1: &str = "2026-11-20";
    const DAY2: &str = "2026-11-21";

    #[test]
    fn two_notices_keep_a_gap() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.allow("agent:a", false, false, 0.0, 1.0, START));
        assert!(!pacer.allow("agent:b", false, false, 0.0, 1.0, START + 5.0));
        assert!(pacer.allow("agent:b", false, false, 0.0, 1.0, START + NoticePacer::GAP_SECS));
    }

    #[test]
    fn one_thing_pops_up_once_in_a_while() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.allow("chat:anna", false, false, 0.0, 1.0, START));
        assert!(!pacer.allow("chat:anna", false, false, 0.0, 1.0, START + 60.0));
        assert!(pacer.allow("chat:anna", false, false, 0.0, 1.0, START + NoticePacer::SAME_KEY_GAP_SECS));
    }

    #[test]
    fn a_burst_ends_in_history() {
        let mut pacer = NoticePacer::default();
        for index in 0..NoticePacer::BURST_LIMIT {
            assert!(pacer.allow(&format!("agent:{index}"), false, false, 0.0, 1.0, START + (index as f64) * 30.0));
        }
        let later = START + (NoticePacer::BURST_LIMIT as f64) * 30.0;
        assert!(!pacer.allow("agent:new", false, false, 0.0, 1.0, later));
        assert!(pacer.allow("agent:new", false, false, 0.0, 1.0, START + NoticePacer::BURST_WINDOW_SECS + 1.0));
    }

    #[test]
    fn priority_passes_full_burst_but_still_respects_gaps() {
        let mut pacer = NoticePacer::default();
        for index in 0..NoticePacer::BURST_LIMIT {
            assert!(pacer.allow(&format!("agent:{index}"), false, false, 0.0, 1.0, START + (index as f64) * 30.0));
        }
        let last = START + ((NoticePacer::BURST_LIMIT - 1) as f64) * 30.0;
        // Too close to the previous pop-up: gap still holds even with priority.
        assert!(!pacer.permits("chat:anna", false, true, 0.0, 1.0, last + 5.0));
        // After the global gap, priority bypasses the burst cap.
        assert!(pacer.permits("chat:anna", false, true, 0.0, 1.0, last + NoticePacer::GAP_SECS));
    }

    #[test]
    fn urgent_always_gets_through() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.allow("agent:a", false, false, 0.0, 1.0, START));
        // Permission approvals, questions, and calls bypass all pacing & budget checks.
        assert!(pacer.allow("agent:a", true, false, 0.0, 1.0, START + 1.0));
        assert!(pacer.allow_class(InterruptionClass::Suggestion, "call:1", true, false, 300.0, 999.0, 2.0, START + 2.0, DAY1));
        // Urgent notices do not consume the daily unasked suggestion/moment budget.
        assert_eq!(pacer.budget.spent(InterruptionClass::Suggestion, DAY1), 0);
    }

    #[test]
    fn suggestion_waits_for_a_calm_surface() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.allow("agent:a", false, false, 0.0, 1.0, START));
        assert!(!pacer.permits("suggestion", false, false, 300.0, 1.0, START + 120.0));
        assert!(pacer.permits("suggestion", false, false, 300.0, 1.0, START + 300.0));
    }

    #[test]
    fn next_permitted_reports_exact_ready_time() {
        let mut pacer = NoticePacer::default();
        assert_eq!(pacer.next_permitted("chat:anna", false, 0.0, 1.0, START), START);
        assert!(pacer.allow("chat:anna", false, false, 0.0, 1.0, START));
        let soon = START + 5.0;
        assert_eq!(pacer.next_permitted("chat:ben", false, 0.0, 1.0, soon), START + NoticePacer::GAP_SECS);
        let again = pacer.next_permitted("chat:anna", false, 0.0, 1.0, soon);
        assert_eq!(again, START + NoticePacer::SAME_KEY_GAP_SECS);
        assert!(!pacer.permits("chat:anna", false, false, 0.0, 1.0, again - 1.0));
        assert!(pacer.permits("chat:anna", false, false, 0.0, 1.0, again));
    }

    #[test]
    fn full_burst_reports_when_window_has_room_again() {
        let mut pacer = NoticePacer::default();
        for index in 0..NoticePacer::BURST_LIMIT {
            assert!(pacer.allow(&format!("agent:{index}"), false, false, 0.0, 1.0, START + (index as f64) * 30.0));
        }
        let later = START + (NoticePacer::BURST_LIMIT as f64) * 30.0;
        let room = pacer.next_permitted("chat:new", false, 0.0, 1.0, later);
        assert_eq!(room, START + NoticePacer::BURST_WINDOW_SECS);
        assert!(!pacer.permits("chat:new", false, false, 0.0, 1.0, room - 1.0));
        assert!(pacer.permits("chat:new", false, false, 0.0, 1.0, room));
    }

    #[test]
    fn asking_does_not_count() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.permits("agent:a", false, false, 0.0, 1.0, START));
        assert!(pacer.allow("agent:a", false, false, 0.0, 1.0, START));
    }

    #[test]
    fn gap_factor_stretches_but_never_shrinks() {
        let mut pacer = NoticePacer::default();
        assert!(pacer.allow("agent:a", false, false, 0.0, 1.0, START));
        // Factor < 1.0 is clamped to 1.0.
        assert!(!pacer.permits("agent:b", false, false, 0.0, 0.2, START + 10.0));
        assert!(pacer.permits("agent:b", false, false, 0.0, 0.2, START + NoticePacer::GAP_SECS));
        // Factor 2.0 doubles both global and same-key gaps.
        assert!(!pacer.permits("agent:b", false, false, 0.0, 2.0, START + NoticePacer::GAP_SECS));
        assert!(pacer.permits("agent:b", false, false, 0.0, 2.0, START + NoticePacer::GAP_SECS * 2.0));
        assert!(!pacer.permits("agent:a", false, false, 0.0, 2.0, START + NoticePacer::SAME_KEY_GAP_SECS));
        assert!(pacer.permits("agent:a", false, false, 0.0, 2.0, START + NoticePacer::SAME_KEY_GAP_SECS * 2.0));
    }

    #[test]
    fn interruption_budget_enforces_daily_shared_and_per_class_limits() {
        let mut budget = InterruptionBudget::default();
        let mut t = START;
        // Spend 4 suggestions (the per-class cap), spaced 20 min apart.
        for _ in 0..4 {
            assert!(budget.allows(InterruptionClass::Suggestion, t, DAY1, 0.0, 1.0));
            budget.spend(InterruptionClass::Suggestion, t, DAY1);
            t += 20.0 * 60.0;
        }
        // 5th suggestion is blocked by per-class cap (4), even though daily cap is 6.
        assert!(!budget.allows(InterruptionClass::Suggestion, t, DAY1, 0.0, 1.0));
        assert_eq!(budget.remaining_daily(DAY1), 2);

        // Two moments can use the remaining 2 slots of the shared daily limit of 6.
        for _ in 0..2 {
            assert!(budget.allows(InterruptionClass::Moment, t, DAY1, 0.0, 1.0));
            budget.spend(InterruptionClass::Moment, t, DAY1);
            t += 25.0 * 60.0;
        }
        // Shared daily limit (6) is now spent: neither moment nor suggestion allowed.
        assert_eq!(budget.remaining_daily(DAY1), 0);
        assert!(!budget.allows(InterruptionClass::Moment, t, DAY1, 0.0, 1.0));
        assert!(!budget.allows(InterruptionClass::Suggestion, t, DAY1, 0.0, 1.0));
        // Notices are never counted against the unasked daily budget.
        assert!(budget.allows(InterruptionClass::Notice, t, DAY1, 0.0, 1.0));
    }

    #[test]
    fn interruption_budget_enforces_unasked_and_class_gaps() {
        let mut budget = InterruptionBudget::default();
        budget.spend(InterruptionClass::Suggestion, START, DAY1);
        // Moment must wait UNASKED_GAP_SECS (10 min) after a suggestion.
        assert!(!budget.allows(InterruptionClass::Moment, START + 9.0 * 60.0, DAY1, 0.0, 1.0));
        assert!(budget.allows(InterruptionClass::Moment, START + 10.0 * 60.0, DAY1, 0.0, 1.0));
        // Another suggestion must wait its own 15 min gap (or longer extra_gap_secs).
        assert!(!budget.allows(InterruptionClass::Suggestion, START + 14.0 * 60.0, DAY1, 0.0, 1.0));
        assert!(budget.allows(InterruptionClass::Suggestion, START + 15.0 * 60.0, DAY1, 0.0, 1.0));
        assert!(!budget.allows(InterruptionClass::Suggestion, START + 15.0 * 60.0, DAY1, 30.0 * 60.0, 1.0));
        assert!(budget.allows(InterruptionClass::Suggestion, START + 30.0 * 60.0, DAY1, 30.0 * 60.0, 1.0));
    }

    #[test]
    fn interruption_budget_resets_at_midnight_while_preserving_gap() {
        let mut budget = InterruptionBudget::default();
        let mut t = START;
        for _ in 0..4 {
            budget.spend(InterruptionClass::Suggestion, t, DAY1);
            t += 20.0 * 60.0;
        }
        assert_eq!(budget.spent(InterruptionClass::Suggestion, DAY1), 4);
        assert_eq!(budget.spent(InterruptionClass::Suggestion, DAY2), 0);
        assert_eq!(budget.remaining_daily(DAY2), InterruptionBudget::DAILY_LIMIT);

        let last_spent = t - 20.0 * 60.0;
        // 5 minutes after midnight: daily count reset, but gap from last suggestion still holds.
        assert!(!budget.allows(InterruptionClass::Suggestion, last_spent + 5.0 * 60.0, DAY2, 0.0, 1.0));
        // Once the 15-minute gap clears on the new day, suggestions work again and counts start fresh.
        assert!(budget.allows(InterruptionClass::Suggestion, last_spent + 15.0 * 60.0, DAY2, 0.0, 1.0));
        budget.spend(InterruptionClass::Suggestion, last_spent + 15.0 * 60.0, DAY2);
        assert_eq!(budget.day(), DAY2);
        assert_eq!(budget.spent(InterruptionClass::Suggestion, DAY2), 1);
    }

    #[test]
    fn interruption_budget_roundtrips_json() {
        let mut budget = InterruptionBudget::default();
        budget.spend(InterruptionClass::Suggestion, START, DAY1);
        budget.spend(InterruptionClass::Moment, START + 1200.0, DAY1);
        let raw = budget.to_json().expect("serializes");
        let restored = InterruptionBudget::from_json(Some(&raw));
        assert_eq!(restored, budget);
        assert_eq!(InterruptionBudget::from_json(Some("not-json")), InterruptionBudget::default());
        assert_eq!(InterruptionBudget::from_json(None), InterruptionBudget::default());
    }

    #[test]
    fn pacer_allow_class_degrades_gracefully_when_budget_spent() {
        let mut pacer = NoticePacer::default();
        let mut t = START;
        for i in 0..4 {
            assert!(pacer.allow_class(
                InterruptionClass::Suggestion,
                &format!("suggestion:{i}"),
                false,
                false,
                300.0,
                0.0,
                1.0,
                t,
                DAY1,
            ));
            t += 20.0 * 60.0;
        }
        // 5th suggestion hits per-class budget cap -> gracefully denied (history-only).
        assert!(!pacer.allow_class(
            InterruptionClass::Suggestion,
            "suggestion:4",
            false,
            false,
            300.0,
            0.0,
            1.0,
            t,
            DAY1,
        ));
        // Regular notices are still permitted and don't touch the unasked budget.
        assert!(pacer.allow_class(InterruptionClass::Notice, "agent:1", false, false, 0.0, 0.0, 1.0, t, DAY1));
        assert_eq!(pacer.budget.spent(InterruptionClass::Notice, DAY1), 0);
    }

    #[test]
    fn source_mapping_matches_mac_classes() {
        assert_eq!(InterruptionClass::from_notice_source(NoticeSource::Suggestions), InterruptionClass::Suggestion);
        assert_eq!(InterruptionClass::from_notice_source(NoticeSource::Agents), InterruptionClass::Notice);
        assert_eq!(InterruptionClass::from_notice_source(NoticeSource::Chats), InterruptionClass::Notice);
        assert_eq!(InterruptionClass::from_notice_source(NoticeSource::Nook), InterruptionClass::Notice);
    }
}
