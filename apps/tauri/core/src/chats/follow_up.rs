//! What you owe in your chats and what you wait for, the same for every chat app (`ChatFollowUps`, `ChatFollowUpTick`
//! on the Mac): a private chat whose last word is theirs and has waited a while ("owed", shown in Today), a chat you
//! marked "waiting for reply" with a reminder, a chat you snoozed, and a message you scheduled to go later. A message
//! that looks like phishing or a scam is owed nothing (`message_trust`). Kept in `chat-follow-ups.json`.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::{ChatInbox, ChatKind, InboxThread};
use crate::brain::message_trust;
use crate::paths;

pub const FILE_NAME: &str = "chat-follow-ups.json";

/// A chat reduced to what follow-up needs (`ChatFollowUpTurn`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    /// The chat's key in the inbox.
    pub chat: String,
    pub app: String,
    pub name: String,
    pub kind: ChatKind,
    /// When the newest message was written; `None` while the chat holds none.
    pub date: Option<DateTime<Utc>>,
    pub last_is_mine: bool,
    pub last_text: String,
    pub unread: usize,
    /// Their newest message looks like phishing or a scam: nothing anyone owes an answer.
    pub suspicious: bool,
}

impl Turn {
    pub fn of(thread: &InboxThread, now: DateTime<Utc>) -> Self {
        let last = thread.messages.last();
        let kind = thread.notice_kind();
        // Judged only where it could be owed (a recent private chat whose last word is theirs).
        let candidate = kind == ChatKind::Person && last.is_some_and(|m| !m.from_me && now - m.date <= FollowUps::owed_until());
        let suspicious = candidate && last.is_some_and(|m| message_trust::assess(&thread.name, "", &m.text, thread.messages.iter().any(|x| x.from_me)).is_suspicious());
        Self {
            chat: thread.id.clone(),
            app: thread.app.clone(),
            name: thread.name.clone(),
            kind,
            date: last.map(|m| m.date),
            last_is_mine: last.is_some_and(|m| m.from_me),
            last_text: last.map(|m| m.text.clone()).unwrap_or_default(),
            unread: thread.unread,
            suspicious,
        }
    }

    /// The newest message asks something (`TextKit.asksQuestion`).
    pub fn asks_question(&self) -> bool {
        self.last_text.contains(['?', '¿', '？'])
    }
}

/// Every chat of the inbox as a turn.
pub fn turns(inbox: &ChatInbox, now: DateTime<Utc>) -> Vec<Turn> {
    inbox.threads.values().map(|t| Turn::of(t, now)).collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Waiting {
    /// When you marked the chat: a message of theirs after it answers you.
    pub since: DateTime<Utc>,
    /// When Nook reminds you, once; answering the reminder moves it on.
    pub remind_at: DateTime<Utc>,
}

/// A message you wrote now and chose to send later (`ChatScheduledSend`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduledSend {
    pub id: String,
    /// The chat's key in the inbox.
    pub chat: String,
    pub text: String,
    pub send_at: DateTime<Utc>,
}

/// Your follow-ups, kept by chat key.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FollowUps {
    pub waiting: HashMap<String, Waiting>,
    pub snoozed: HashMap<String, DateTime<Utc>>,
    pub scheduled: Vec<ScheduledSend>,
}

/// What one tick of the follow-ups does (`ChatFollowUpPlan`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Plan {
    /// Chats to remind you about now: oldest wait first.
    pub reminders: Vec<String>,
    /// Scheduled messages that go now.
    pub sends: Vec<ScheduledSend>,
    /// Scheduled messages that came too late (Nook was off) or whose chat is gone: they wait for your OK.
    pub confirm: Vec<ScheduledSend>,
}

impl FollowUps {
    /// Nook reminds you after a day by default.
    pub fn default_wait() -> Duration {
        Duration::hours(24)
    }
    /// A chat owes an answer once their word waited this long.
    pub fn owed_after() -> Duration {
        Duration::hours(4)
    }
    /// Owed chats older than this are not nagged about.
    pub fn owed_until() -> Duration {
        Duration::days(14)
    }
    /// A scheduled message more late than this waits for your OK.
    pub fn late_limit() -> Duration {
        Duration::hours(2)
    }

    pub fn mark_waiting(&mut self, chat: &str, now: DateTime<Utc>, after: Duration) {
        self.waiting.insert(chat.into(), Waiting { since: now, remind_at: now + after.max(Duration::minutes(1)) });
    }

    pub fn clear_waiting(&mut self, chat: &str) {
        self.waiting.remove(chat);
    }

    /// The reminder was shown: the next one comes after another day.
    pub fn acknowledge(&mut self, chat: &str, now: DateTime<Utc>) {
        if let Some(w) = self.waiting.get_mut(chat) {
            w.remind_at = now + Self::default_wait();
        }
    }

    pub fn snooze(&mut self, chat: &str, until: DateTime<Utc>) {
        self.snoozed.insert(chat.into(), until);
    }

    pub fn unsnooze(&mut self, chat: &str) {
        self.snoozed.remove(chat);
    }

    pub fn is_snoozed(&self, chat: &str, now: DateTime<Utc>) -> bool {
        self.snoozed.get(chat).is_some_and(|u| *u > now)
    }

    /// The chats where the last word is theirs and has waited since `owed_after` (not longer than `owed_until`):
    /// questions first, then the oldest. A group, a status or a channel is no person waiting on you; a snoozed chat comes
    /// back when its time is up; a message that looks like a scam is owed nothing.
    pub fn owed(&self, turns: &[Turn], now: DateTime<Utc>) -> Vec<Turn> {
        let mut out: Vec<Turn> = turns
            .iter()
            .filter(|t| {
                let Some(date) = t.date else { return false };
                let age = now - date;
                t.kind == ChatKind::Person
                    && !t.last_is_mine
                    && !t.suspicious
                    && !self.is_snoozed(&t.chat, now)
                    && age >= Self::owed_after()
                    && age <= Self::owed_until()
            })
            .cloned()
            .collect();
        out.sort_by(|a, b| b.asks_question().cmp(&a.asks_question()).then(a.date.cmp(&b.date)));
        out
    }

    /// Whether they answered a chat you wait on: their word after you marked it.
    pub fn answered(&self, turn: &Turn) -> bool {
        let (Some(entry), Some(date)) = (self.waiting.get(&turn.chat), turn.date) else { return false };
        !turn.last_is_mine && date > entry.since
    }

    /// Forgets what is settled: a wait they answered, a chat gone, a snooze past its time. True when anything changed.
    pub fn settle(&mut self, turns: &[Turn], now: DateTime<Utc>) -> bool {
        let before = self.clone();
        let by_chat: HashMap<&str, &Turn> = turns.iter().map(|t| (t.chat.as_str(), t)).collect();
        let keys: Vec<String> = self.waiting.keys().cloned().collect();
        for chat in keys {
            match by_chat.get(chat.as_str()) {
                Some(turn) if !self.answered(turn) => {}
                _ => {
                    self.waiting.remove(&chat);
                }
            }
        }
        self.snoozed.retain(|_, until| *until > now);
        *self != before
    }

    pub fn schedule(&mut self, send: ScheduledSend) {
        self.scheduled.retain(|s| s.id != send.id);
        self.scheduled.push(send);
        self.scheduled.sort_by_key(|s| s.send_at);
    }

    pub fn cancel_scheduled(&mut self, id: &str) {
        self.scheduled.retain(|s| s.id != id);
    }

    /// What is due at `now` (`ChatFollowUpTick.plan`). Writing the scheduled message (its text and its time) is your OK
    /// for sending it then; one that comes too late, or whose chat is gone, asks again.
    pub fn plan(&self, chats: &HashSet<String>, now: DateTime<Utc>) -> Plan {
        let mut plan = Plan::default();
        let mut due: Vec<(&String, &Waiting)> =
            self.waiting.iter().filter(|(c, w)| w.remind_at <= now && !self.is_snoozed(c, now) && chats.contains(*c)).collect();
        due.sort_by_key(|(_, w)| w.since);
        plan.reminders = due.into_iter().map(|(c, _)| c.clone()).collect();
        for send in self.scheduled.iter().filter(|s| s.send_at <= now) {
            if now - send.send_at > Self::late_limit() || !chats.contains(&send.chat) || send.text.trim().is_empty() {
                plan.confirm.push(send.clone());
            } else {
                plan.sends.push(send.clone());
            }
        }
        plan
    }
}

/// The follow-ups on disk, behind one lock.
pub struct FollowUpStore {
    inner: Mutex<FollowUps>,
    path: Option<PathBuf>,
}

impl FollowUpStore {
    pub fn memory() -> Self {
        Self { inner: Mutex::default(), path: None }
    }

    pub fn open_default() -> Self {
        let path = paths::support_directory().join(FILE_NAME);
        let inner = std::fs::read(&path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        Self { inner: Mutex::new(inner), path: Some(path) }
    }

    pub fn read<T>(&self, f: impl FnOnce(&FollowUps) -> T) -> T {
        f(&self.inner.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// Changes the follow-ups and writes them when they changed.
    pub fn change<T>(&self, f: impl FnOnce(&mut FollowUps) -> T) -> T {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let before = inner.clone();
        let out = f(&mut inner);
        if *inner != before {
            if let Some(path) = &self.path {
                if let Ok(data) = serde_json::to_vec(&*inner) {
                    let _ = paths::write_atomic(path, &data);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::InboxMessage;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 20, 12, 0, 0).unwrap()
    }

    fn turn(chat: &str, hours_ago: i64, mine: bool, text: &str) -> Turn {
        Turn {
            chat: chat.into(),
            app: "telegram".into(),
            name: chat.into(),
            kind: ChatKind::Person,
            date: Some(now() - Duration::hours(hours_ago)),
            last_is_mine: mine,
            last_text: text.into(),
            unread: 0,
            suspicious: false,
        }
    }

    #[test]
    fn owed_are_their_words_that_waited_questions_first() {
        let f = FollowUps::default();
        let mut group = turn("g", 6, false, "hi");
        group.kind = ChatKind::Group;
        let mut scam = turn("s", 6, false, "verify");
        scam.suspicious = true;
        let turns = vec![turn("a", 8, false, "ok"), turn("b", 5, false, "coming?"), turn("c", 1, false, "new"), turn("d", 6, true, "mine"), turn("e", 24 * 20, false, "old"), group, scam];
        let owed: Vec<String> = f.owed(&turns, now()).into_iter().map(|t| t.chat).collect();
        assert_eq!(owed, vec!["b", "a"]);
        let mut snoozed = FollowUps::default();
        snoozed.snooze("b", now() + Duration::hours(1));
        assert_eq!(snoozed.owed(&turns, now()).len(), 1);
    }

    #[test]
    fn waits_settle_when_they_answer_and_reminders_come_due() {
        let mut f = FollowUps::default();
        f.mark_waiting("a", now() - Duration::hours(30), FollowUps::default_wait());
        f.mark_waiting("b", now() - Duration::hours(2), FollowUps::default_wait());
        let chats: HashSet<String> = ["a".to_string(), "b".to_string()].into();
        assert_eq!(f.plan(&chats, now()).reminders, vec!["a".to_string()]);
        assert!(f.settle(&[turn("a", 1, false, "here"), turn("b", 3, true, "?")], now()));
        assert!(!f.waiting.contains_key("a"));
        assert!(f.waiting.contains_key("b"));
    }

    #[test]
    fn scheduled_messages_go_in_time_or_wait_for_an_ok() {
        let mut f = FollowUps::default();
        let send = |id: &str, chat: &str, mins_ago: i64| ScheduledSend { id: id.into(), chat: chat.into(), text: "hi".into(), send_at: now() - Duration::minutes(mins_ago) };
        f.schedule(send("1", "a", 1));
        f.schedule(send("2", "a", 300));
        f.schedule(send("3", "gone", 1));
        f.schedule(ScheduledSend { send_at: now() + Duration::hours(1), ..send("4", "a", 0) });
        let plan = f.plan(&["a".to_string()].into(), now());
        assert_eq!(plan.sends.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["1"]);
        assert_eq!(plan.confirm.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["2", "3"]);
        f.cancel_scheduled("4");
        assert_eq!(f.scheduled.len(), 3);
    }

    #[test]
    fn a_turn_reads_a_thread() {
        let mut t = InboxThread::new("telegram#1", "telegram", "Eva");
        t.kind = Some(ChatKind::Person);
        t.messages.push(InboxMessage::new("m", "Your account is locked, verify now at http://paypa1.co/login", now() - Duration::hours(5), false));
        let turn = Turn::of(&t, now());
        assert!(!turn.last_is_mine);
        assert_eq!(turn.kind, ChatKind::Person);
    }
}
