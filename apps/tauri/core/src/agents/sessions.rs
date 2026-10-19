//! Welke chats in de lijst Agents als afgerond gelden (`FinishedSessions` op de Mac) en wanneer je elke sessie voor het
//! laatst bekeek (`SessionVisits`). Twee manieren: je markeert een chat als afgerond, of de agent is klaar en er gebeurt
//! een tijdje niets (`AUTO_FINISH_AFTER`). Een afgeronde chat komt vanzelf terug als de agent er weer in werkt; een chat
//! die je heropende blijft open tot er iets nieuws gebeurt.

use std::collections::BTreeMap;
use std::path::PathBuf;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

pub const AUTO_FINISH_AFTER: i64 = 10 * 60;
const LIMIT: usize = 500;

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct Stored {
    /// Oudste eerst.
    finished: Vec<String>,
    kept: BTreeMap<String, DateTime<Utc>>,
    visits: BTreeMap<String, DateTime<Utc>>,
}

pub struct SessionMarks {
    file: Option<PathBuf>,
    stored: Stored,
}

impl SessionMarks {
    pub fn load(file: Option<PathBuf>) -> Self {
        let mut stored: Stored =
            file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let cutoff = Utc::now() - Duration::days(14);
        stored.visits.retain(|_, d| *d > cutoff);
        Self { file, stored }
    }

    fn save(&self) {
        if let (Some(file), Ok(bytes)) = (&self.file, serde_json::to_vec(&self.stored)) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// Voor de interface: de afgeronde chats, de heropende chats en de bezoeken.
    pub fn snapshot(&self) -> serde_json::Value {
        serde_json::json!({"finished": self.stored.finished, "kept": self.stored.kept, "visits": self.stored.visits})
    }

    pub fn contains(&self, key: &str) -> bool {
        self.stored.finished.iter().any(|k| k == key)
    }

    pub fn mark(&mut self, key: &str) {
        if key.is_empty() || self.contains(key) {
            return;
        }
        self.stored.finished.push(key.into());
        if self.stored.finished.len() > LIMIT {
            let extra = self.stored.finished.len() - LIMIT;
            self.stored.finished.drain(..extra);
        }
        self.save();
    }

    pub fn reopen(&mut self, key: &str) {
        self.stored.kept.remove(key);
        self.stored.finished.retain(|k| k != key);
        self.save();
    }

    /// Je heropent een chat: hij blijft uit "Afgerond" tot de agent er iets nieuws in deed.
    pub fn reopen_by_user(&mut self, key: &str, now: DateTime<Utc>) {
        self.reopen(key);
        if key.is_empty() {
            return;
        }
        self.stored.kept.insert(key.into(), now);
        if self.stored.kept.len() > LIMIT {
            let mut by_age: Vec<(String, DateTime<Utc>)> = self.stored.kept.iter().map(|(k, d)| (k.clone(), *d)).collect();
            by_age.sort_by_key(|(_, d)| *d);
            for (k, _) in by_age.into_iter().take(self.stored.kept.len() - LIMIT) {
                self.stored.kept.remove(&k);
            }
        }
        self.save();
    }

    pub fn toggle(&mut self, key: &str, now: DateTime<Utc>) {
        if self.contains(key) {
            self.reopen_by_user(key, now);
        } else {
            self.mark(key);
        }
    }

    /// Is deze chat nu afgerond: door jou gemarkeerd, of lang genoeg stil nadat de agent klaar was?
    pub fn is_finished(&self, key: &str, idle: bool, last_active: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
        if self.contains(key) {
            return true;
        }
        let Some(last) = last_active else { return false };
        if !idle || (now - last).num_seconds() < AUTO_FINISH_AFTER {
            return false;
        }
        !self.stored.kept.get(key).is_some_and(|reopened| *reopened >= last)
    }

    /// Een gesprek van een agent ("Claude Code|<gesprek-id>"); zonder gesprek-id alleen de rij-id.
    pub fn key(agent: &str, conversation: Option<&str>, fallback: &str) -> String {
        match conversation.filter(|c| !c.is_empty()) {
            Some(c) => format!("{agent}|{c}"),
            None => fallback.into(),
        }
    }

    // MARK: Bezoeken

    pub fn visit(&mut self, id: &str, at: DateTime<Utc>) {
        if id.is_empty() {
            return;
        }
        self.stored.visits.insert(id.into(), at);
        self.save();
    }

    /// "Markeer als ongelezen": de sessie telt weer als nieuw tot je hem opent.
    pub fn mark_unread(&mut self, id: &str) {
        if !id.is_empty() {
            self.stored.visits.insert(id.into(), DateTime::<Utc>::UNIX_EPOCH);
            self.save();
        }
    }

    /// Klaar na het laatste bezoek. Een sessie die je nooit opende telt alleen als hij de afgelopen dag klaar kwam.
    pub fn is_unseen(&self, id: &str, finished: DateTime<Utc>, now: DateTime<Utc>) -> bool {
        match self.stored.visits.get(id) {
            Some(last) => finished > *last + Duration::seconds(1),
            None => (now - finished).num_seconds() < 24 * 3600,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marked_chat_is_finished_and_reopens_by_hand() {
        let mut s = SessionMarks::load(None);
        let now = Utc::now();
        let key = "Test|x";
        assert!(!s.is_finished(key, true, Some(now), now));
        s.mark(key);
        assert!(s.is_finished(key, false, Some(now), now));
        s.reopen_by_user(key, now);
        assert!(!s.is_finished(key, true, Some(now - Duration::hours(1)), now));
    }

    #[test]
    fn idle_chat_finishes_by_itself() {
        let s = SessionMarks::load(None);
        let now = Utc::now();
        let quiet = now - Duration::seconds(AUTO_FINISH_AFTER + 1);
        assert!(s.is_finished("k", true, Some(quiet), now));
        assert!(!s.is_finished("k", true, Some(now - Duration::seconds(60)), now));
        assert!(!s.is_finished("k", false, Some(quiet), now));
        assert!(!s.is_finished("k", true, None, now));
    }

    #[test]
    fn reopened_chat_finishes_again_after_new_activity() {
        let mut s = SessionMarks::load(None);
        let now = Utc::now();
        s.reopen_by_user("k", now);
        let activity = now + Duration::seconds(60);
        assert!(s.is_finished("k", true, Some(activity), activity + Duration::seconds(AUTO_FINISH_AFTER + 1)));
    }

    #[test]
    fn keys_and_visits() {
        assert_eq!(SessionMarks::key("Codex", Some("abc"), "x"), "Codex|abc");
        assert_eq!(SessionMarks::key("Codex", Some(""), "x"), "x");
        assert_eq!(SessionMarks::key("Codex", None, "x"), "x");
        let mut s = SessionMarks::load(None);
        let now = Utc::now();
        assert!(s.is_unseen("a", now - Duration::hours(1), now));
        s.visit("a", now);
        assert!(!s.is_unseen("a", now - Duration::hours(1), now));
        s.mark_unread("a");
        assert!(s.is_unseen("a", now - Duration::hours(1), now));
    }
}
