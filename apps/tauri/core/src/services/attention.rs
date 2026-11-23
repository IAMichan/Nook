//! One ranking of what may need you, shared by Today, the tray menu and the phone (the Mac's `AttentionItem`,
//! `AttentionScorer` and `AttentionFeedback`): a few plain rules (what it asks of you, how soon it is due, how long it
//! waited, whether you can act on it here) plus what you did with such things before. Feedback fades over two weeks,
//! so a habit that changed is followed. Kept in `attention-feedback.json`, written only when you do something.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::paths;

/// What an item asks of you, most pressing first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NeedsYou {
    Approval,
    Question,
    Reply,
    Review,
    Failure,
    Info,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionItem {
    /// "agents", "chats", "calendar", "github"…
    pub source: String,
    pub id: String,
    #[serde(default)]
    pub app: String,
    #[serde(default)]
    pub subject: String,
    pub needs_you: NeedsYou,
    #[serde(default)]
    pub deadline: Option<DateTime<Utc>>,
    #[serde(default)]
    pub since: Option<DateTime<Utc>>,
    #[serde(default = "yes")]
    pub actionable: bool,
}

fn yes() -> bool {
    true
}

/// What you did with something Nook told you or offered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttentionEvent {
    Shown,
    Opened,
    Dismissed,
    TimedOut,
    Snoozed,
    Muted,
    Answered,
    Approved,
    Denied,
}

impl AttentionEvent {
    /// Points for engagement and against it; approving or denying both mean it was worth asking.
    pub fn weights(self) -> (f64, f64) {
        match self {
            Self::Shown => (0.0, 0.0),
            Self::Opened | Self::Answered | Self::Approved | Self::Denied => (1.0, 0.0),
            Self::Dismissed => (0.0, 1.0),
            Self::TimedOut | Self::Snoozed => (0.0, 0.5),
            Self::Muted => (0.0, 3.0),
        }
    }
}

/// `value` after `elapsed` seconds, halving every `half_life`; time running backwards fades nothing.
pub fn decay(value: f64, elapsed: f64, half_life: f64) -> f64 {
    if half_life <= 0.0 {
        return value;
    }
    value * 0.5f64.powf(elapsed.max(0.0) / half_life)
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub score: f64,
    #[serde(default)]
    pub negative: f64,
    pub last: DateTime<Utc>,
}

/// Counts that fade (the Mac's `DecayedCounter`), keeping at most `limit` keys with the most evidence.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DecayedCounter {
    pub half_life: f64,
    pub limit: usize,
    #[serde(default)]
    pub entries: HashMap<String, Entry>,
}

impl DecayedCounter {
    pub fn new(half_life: f64, limit: usize) -> Self {
        Self { half_life, limit, entries: HashMap::new() }
    }

    fn faded(&self, e: &Entry, now: DateTime<Utc>) -> Entry {
        let elapsed = (now - e.last).num_milliseconds() as f64 / 1000.0;
        Entry { score: decay(e.score, elapsed, self.half_life), negative: decay(e.negative, elapsed, self.half_life), last: now.max(e.last) }
    }

    pub fn add(&mut self, key: &str, positive: f64, negative: f64, now: DateTime<Utc>) {
        let mut entry = self.entries.get(key).map(|e| self.faded(e, now)).unwrap_or(Entry { score: 0.0, negative: 0.0, last: now });
        entry.score += positive;
        entry.negative += negative;
        self.entries.insert(key.to_string(), entry);
        if self.entries.len() > self.limit {
            let mut all: Vec<(String, f64)> = self.entries.iter().map(|(k, e)| { let f = self.faded(e, now); (k.clone(), f.score + f.negative) }).collect();
            all.sort_by(|a, b| b.1.total_cmp(&a.1));
            let keep: std::collections::HashSet<String> = all.into_iter().take(self.limit).map(|(k, _)| k).collect();
            self.entries.retain(|k, _| keep.contains(k));
        }
    }

    pub fn points(&self, key: &str, now: DateTime<Utc>) -> (f64, f64) {
        self.entries.get(key).map(|e| { let f = self.faded(e, now); (f.score, f.negative) }).unwrap_or((0.0, 0.0))
    }
}

/// Learns from what you do with Nook's notices, per source, app and subject.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttentionFeedback {
    pub counter: DecayedCounter,
    pub exposure: DecayedCounter,
}

pub const HALF_LIFE: f64 = 14.0 * 24.0 * 3600.0;
pub const MAX_GAP_FACTOR: f64 = 3.0;

impl Default for AttentionFeedback {
    fn default() -> Self {
        Self { counter: DecayedCounter::new(HALF_LIFE, 400), exposure: DecayedCounter::new(HALF_LIFE, 200) }
    }
}

impl AttentionFeedback {
    pub fn key(source: &str, app: &str, subject: Option<&str>) -> String {
        let base = format!("{}|{}", source.to_lowercase(), app.trim().to_lowercase());
        match subject.filter(|s| !s.is_empty()) {
            Some(subject) => format!("{base}|{subject}"),
            None => base,
        }
    }

    pub fn record(&mut self, event: AttentionEvent, source: &str, app: &str, subject: Option<&str>, now: DateTime<Utc>) {
        let base = Self::key(source, app, None);
        if event == AttentionEvent::Shown {
            self.exposure.add(&base, 1.0, 0.0, now);
            return;
        }
        let (positive, negative) = event.weights();
        self.counter.add(&base, positive, negative, now);
        if let Some(subject) = subject.filter(|s| !s.is_empty()) {
            self.counter.add(&Self::key(source, app, Some(subject)), positive, negative, now);
        }
    }

    /// How welcome notices from here are, -1…1; zero when Nook knows too little.
    pub fn weight(&self, source: &str, app: &str, subject: Option<&str>, now: DateTime<Utc>) -> f64 {
        let mut keys = vec![Self::key(source, app, None)];
        if let Some(subject) = subject.filter(|s| !s.is_empty()) {
            keys.push(Self::key(source, app, Some(subject)));
        }
        let (mut positive, mut negative) = (0.0, 0.0);
        for key in keys {
            let (p, n) = self.counter.points(&key, now);
            positive += p;
            negative += n;
        }
        (positive - negative) / (positive + negative + 2.0)
    }

    /// How much longer the pacer keeps its distance for notices from here: 1 up to `MAX_GAP_FACTOR`.
    pub fn gap_factor(&self, source: &str, app: &str, now: DateTime<Utc>) -> f64 {
        let weight = self.weight(source, app, None, now);
        if weight >= -0.25 {
            return 1.0;
        }
        (1.0 + (-weight - 0.25) / 0.75 * (MAX_GAP_FACTOR - 1.0)).min(MAX_GAP_FACTOR)
    }
}

/// The base of each need: an approval before a question, a question before a failure, and so on.
pub fn base(need: NeedsYou) -> f64 {
    match need {
        NeedsYou::Approval => 100.0,
        NeedsYou::Question => 90.0,
        NeedsYou::Failure => 70.0,
        NeedsYou::Reply => 60.0,
        NeedsYou::Review => 55.0,
        NeedsYou::Info => 30.0,
    }
}

/// How much one item counts (the Mac's `AttentionScorer.score`). Higher is more important.
pub fn score(item: &AttentionItem, feedback: &AttentionFeedback, now: DateTime<Utc>) -> f64 {
    let mut score = base(item.needs_you);
    if let Some(deadline) = item.deadline {
        let ahead = (deadline - now).num_seconds() as f64;
        score += if ahead < 0.0 {
            if item.needs_you == NeedsYou::Info { 0.0 } else { 20.0 }
        } else if ahead <= 3600.0 {
            25.0
        } else if ahead <= 3.0 * 3600.0 {
            15.0
        } else if ahead <= 24.0 * 3600.0 {
            5.0
        } else {
            0.0
        };
    }
    if let Some(since) = item.since {
        let hours = ((now - since).num_seconds() as f64 / 3600.0).max(0.0);
        score += ((1.0 + hours).log2() * 2.0).min(10.0);
    }
    if item.actionable {
        score += 5.0;
    }
    let subject = (!item.subject.is_empty()).then_some(item.subject.as_str());
    score + 10.0 * feedback.weight(&item.source, &item.app, subject, now)
}

/// The items, most important first; equal scores keep their order.
pub fn rank(items: Vec<AttentionItem>, feedback: &AttentionFeedback, now: DateTime<Utc>) -> Vec<AttentionItem> {
    let mut scored: Vec<(usize, f64, AttentionItem)> = items.into_iter().enumerate().map(|(i, it)| (i, score(&it, feedback, now), it)).collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    scored.into_iter().map(|(_, _, it)| it).collect()
}

/// The first item that truly waits on you, if any.
pub fn top_need(items: Vec<AttentionItem>, feedback: &AttentionFeedback, now: DateTime<Utc>) -> Option<AttentionItem> {
    rank(items.into_iter().filter(|i| i.needs_you != NeedsYou::Info).collect(), feedback, now).into_iter().next()
}

/// Keeps the feedback between runs. A write happens only when you do something, never on a timer.
pub struct AttentionFeedbackStore {
    path: Option<PathBuf>,
    cached: Mutex<AttentionFeedback>,
}

impl AttentionFeedbackStore {
    pub fn open_default() -> Self {
        let path = paths::support_directory().join("attention-feedback.json");
        Self { cached: Mutex::new(crate::storage_recovery::read_json_plain(&path)), path: Some(path) }
    }

    pub fn memory() -> Self {
        Self { path: None, cached: Mutex::default() }
    }

    pub fn feedback(&self) -> AttentionFeedback {
        self.cached.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn record(&self, event: AttentionEvent, source: &str, app: &str, subject: Option<&str>) {
        let mut cached = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        cached.record(event, source, app, subject, Utc::now());
        if let (Some(path), Ok(bytes)) = (&self.path, serde_json::to_vec(&*cached)) {
            let _ = paths::write_atomic(path, &bytes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn item(id: &str, need: NeedsYou) -> AttentionItem {
        AttentionItem { source: "agents".into(), id: id.into(), app: String::new(), subject: String::new(), needs_you: need, deadline: None, since: None, actionable: true }
    }

    #[test]
    fn needs_come_in_the_macs_order_and_deadlines_lift() {
        let now = Utc::now();
        let f = AttentionFeedback::default();
        let ranked = rank(vec![item("i", NeedsYou::Info), item("r", NeedsYou::Reply), item("a", NeedsYou::Approval), item("q", NeedsYou::Question)], &f, now);
        assert_eq!(ranked.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["a", "q", "r", "i"]);
        let mut soon = item("soon", NeedsYou::Info);
        soon.deadline = Some(now + Duration::minutes(30));
        assert_eq!(score(&soon, &f, now), 30.0 + 25.0 + 5.0);
        let mut overdue = item("late", NeedsYou::Review);
        overdue.deadline = Some(now - Duration::minutes(5));
        assert_eq!(score(&overdue, &f, now), 55.0 + 20.0 + 5.0);
        let mut waited = item("w", NeedsYou::Reply);
        waited.since = Some(now - Duration::hours(1000));
        assert_eq!(score(&waited, &f, now), 60.0 + 10.0 + 5.0);
        assert_eq!(top_need(vec![item("i", NeedsYou::Info)], &f, now), None);
    }

    #[test]
    fn feedback_moves_an_app_and_fades() {
        let now = Utc::now();
        let mut f = AttentionFeedback::default();
        assert_eq!(f.weight("chats", "slack", None, now), 0.0);
        for _ in 0..5 {
            f.record(AttentionEvent::Dismissed, "chats", "Slack", Some("c1"), now);
        }
        let w = f.weight("chats", "slack", None, now);
        assert!((w - (-5.0 / 7.0)).abs() < 1e-9);
        assert!(f.gap_factor("chats", "slack", now) > 1.5);
        let later = now + Duration::days(56);
        assert!(f.weight("chats", "slack", None, later) > w, "four half-lives later it counts far less");
        f.record(AttentionEvent::Opened, "chats", "whatsapp", None, now);
        assert!(f.weight("chats", "whatsapp", None, now) > 0.0);
        let mut slack = item("s", NeedsYou::Reply);
        slack.source = "chats".into();
        slack.app = "slack".into();
        let mut wa = slack.clone();
        wa.id = "w".into();
        wa.app = "whatsapp".into();
        assert_eq!(rank(vec![slack, wa], &f, now)[0].id, "w");
        f.record(AttentionEvent::Shown, "chats", "x", None, now);
        assert_eq!(f.weight("chats", "x", None, now), 0.0);
    }
}
