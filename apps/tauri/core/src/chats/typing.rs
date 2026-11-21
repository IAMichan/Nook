//! Who is typing in which chat (`ChatTyping` on the Mac): ephemeral live state held in memory only and never saved to
//! disk. Apps repeat typing signals while someone types and may never send a "stopped" event, so each typist expires
//! automatically after `until`.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};

/// Someone typing in a chat until `until`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Typist {
    /// Who it is, by their id in the app (to replace their own earlier word).
    pub id: String,
    /// Their name as the chat shows it; may be empty in a private chat.
    pub name: String,
    pub until: DateTime<Utc>,
}

/// Every chat's active typists, keyed by the chat's inbox key (`app#id`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TypingState {
    chats: HashMap<String, Vec<Typist>>,
}

impl TypingState {
    /// Default hold when an app does not specify a timeout (matches Mac `ChatTypingState.hold`).
    pub const DEFAULT_HOLD_SECS: i64 = 15;

    /// Records that `person_id` is typing in `chat` until `until`, replacing any earlier entry for them.
    pub fn typing(&mut self, chat: &str, person_id: &str, name: &str, until: DateTime<Utc>) {
        let list = self.chats.entry(chat.to_string()).or_default();
        list.retain(|t| t.id != person_id);
        list.push(Typist { id: person_id.to_string(), name: name.to_string(), until });
    }

    /// Records that `person_id` stopped typing in `chat` (or sent a message). Returns true if state changed.
    pub fn stopped(&mut self, chat: &str, person_id: &str) -> bool {
        let Some(list) = self.chats.get_mut(chat) else { return false };
        let before = list.len();
        list.retain(|t| t.id != person_id);
        let changed = list.len() != before;
        if list.is_empty() {
            self.chats.remove(chat);
        }
        changed
    }

    /// Clears all active typists across every chat.
    pub fn clear(&mut self) {
        self.chats.clear();
    }

    /// Removes all typists whose word ran out by `now`, returning the keys of chats whose typing list changed.
    pub fn expire_keys(&mut self, now: DateTime<Utc>) -> Vec<String> {
        let mut touched = Vec::new();
        self.chats.retain(|key, list| {
            let before = list.len();
            list.retain(|t| t.until > now);
            if list.len() != before {
                touched.push(key.clone());
            }
            !list.is_empty()
        });
        touched
    }

    /// Removes all typists whose word ran out by `now`. Returns true if any expired.
    pub fn expire(&mut self, now: DateTime<Utc>) -> bool {
        !self.expire_keys(now).is_empty()
    }

    /// Active typists in `chat` at `now`, in the order they started.
    pub fn typists(&self, chat: &str, now: DateTime<Utc>) -> Vec<Typist> {
        self.chats.get(chat).map(|list| list.iter().filter(|t| t.until > now).cloned().collect()).unwrap_or_default()
    }

    /// Display names of people currently typing in `chat` at `now`.
    pub fn names(&self, chat: &str, now: DateTime<Utc>) -> Vec<String> {
        self.typists(chat, now).into_iter().map(|t| t.name).collect()
    }

    /// Clamps an app-supplied duration in seconds to a sensible hold window (1..=15s).
    pub fn hold_duration(seconds: f64) -> Duration {
        let secs = if seconds.is_finite() && seconds > 0.0 {
            seconds.clamp(1.0, Self::DEFAULT_HOLD_SECS as f64)
        } else {
            Self::DEFAULT_HOLD_SECS as f64
        };
        Duration::milliseconds((secs * 1000.0).round() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(sec: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 20, 12, 0, 0).unwrap() + Duration::seconds(sec)
    }

    #[test]
    fn tracks_updates_stops_and_expires_typists() {
        let mut state = TypingState::default();
        state.typing("telegram#1", "@anna", "Anna", at(10));
        state.typing("telegram#1", "@bo", "Bo", at(15));
        assert_eq!(state.names("telegram#1", at(5)), vec!["Anna", "Bo"]);

        // Updating Anna replaces her earlier entry instead of duplicating it.
        state.typing("telegram#1", "@anna", "Anna", at(20));
        assert_eq!(state.names("telegram#1", at(12)), vec!["Bo", "Anna"]);

        // Bo expires at t=15.
        assert!(state.expire(at(16)));
        assert_eq!(state.names("telegram#1", at(16)), vec!["Anna"]);
        assert!(!state.expire(at(17)));

        // Explicit stop clears Anna.
        assert!(state.stopped("telegram#1", "@anna"));
        assert!(!state.stopped("telegram#1", "@anna"));
        assert!(state.names("telegram#1", at(17)).is_empty());
    }
}
