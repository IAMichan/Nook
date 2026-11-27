//! Going back to before a message rolls back the agent's own conversation together with the files
//! (`ConversationRollback` on the Mac): Codex drops the later turns from its thread (`thread/rollback`), Claude Code
//! resumes a copy of its conversation at the last message that stays (`--resume <id> --resume-session-at <uuid>
//! --fork-session`). Back to before the first message starts a new conversation. Other agents: files only.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::models::{RunCheckpoint, RunEvent, RunProvider};

/// Where the agent's own conversation stood when a checkpoint was made.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConversationMark {
    /// The agent's session or thread; `None`: there was no conversation yet.
    pub session: Option<String>,
    pub provider: Option<RunProvider>,
    /// Turns in that session so far (Codex counts them to roll back).
    pub turns: usize,
    /// Claude Code: the last entry of the conversation chain (a message uuid).
    pub head: Option<String>,
    /// Nook missed turns of this conversation (Codex over `codex exec`): its count cannot be trusted.
    #[serde(default = "yes")]
    pub exact: bool,
}

fn yes() -> bool {
    true
}

impl Default for ConversationMark {
    fn default() -> Self {
        Self { session: None, provider: None, turns: 0, head: None, exact: true }
    }
}

impl ConversationMark {
    /// Before the first message of a new session.
    pub fn empty() -> Self {
        Self::default()
    }
}

/// The conversation as Nook follows it live, kept on the session so a checkpoint can record where it stood.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConversationLog {
    pub session: Option<String>,
    pub provider: Option<RunProvider>,
    /// Codex: the thread's turn ids in order (a turn without a known id counts in `turns` only).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub turn_ids: Vec<String>,
    pub turns: usize,
    pub head: Option<String>,
    #[serde(default = "yes")]
    pub exact: bool,
}

impl Default for ConversationLog {
    fn default() -> Self {
        Self { session: None, provider: None, turn_ids: vec![], turns: 0, head: None, exact: true }
    }
}

impl ConversationLog {
    pub fn new(session: Option<String>, provider: RunProvider) -> Self {
        Self { session, provider: Some(provider), turn_ids: vec![], turns: 0, head: None, exact: true }
    }

    /// The agent reported its session. Another thread (Codex) starts the count again; a copy of a Claude Code
    /// conversation (`--fork-session`, a resume) keeps what it copied.
    pub fn note_session(&mut self, session: &str, provider: RunProvider) {
        if self.provider.is_some_and(|p| p != provider) {
            *self = Self::new(Some(session.into()), provider);
            return;
        }
        self.provider = Some(provider);
        if self.session.as_deref() == Some(session) {
            return;
        }
        let keeps_history = provider == RunProvider::Claude;
        if !keeps_history && self.session.is_some() {
            self.turn_ids.clear();
            self.turns = 0;
            self.head = None;
            self.exact = true;
        }
        self.session = Some(session.into());
    }

    /// A turn started. Codex reports a turn id, sometimes twice (the `turn/start` reply and `turn/started`): counted once.
    pub fn start_turn(&mut self, id: Option<&str>) {
        if let Some(id) = id {
            if self.turn_ids.iter().any(|existing| existing == id) {
                return;
            }
            self.turn_ids.push(id.into());
        }
        self.turns += 1;
    }

    pub fn note_head(&mut self, uuid: &str) {
        self.head = Some(uuid.into());
    }

    pub fn mark(&self) -> ConversationMark {
        ConversationMark {
            session: self.session.clone(),
            provider: self.provider,
            turns: self.turns,
            head: self.head.clone(),
            exact: self.exact,
        }
    }

    /// After a rollback to `mark`: what is left of the conversation.
    pub fn rewind(&mut self, mark: &ConversationMark) {
        let kept = mark.turns.min(self.turns);
        if self.turn_ids.len() > kept {
            self.turn_ids.truncate(kept);
        }
        self.turns = kept;
        self.head = mark.head.clone();
        if let Some(session) = &mark.session {
            self.session = Some(session.clone());
        }
    }
}

/// A rollback that waits for the next turn: the conversation goes back right before that turn starts, so going back
/// needs no running agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct PendingRollback {
    /// Codex: the thread, how many of its last turns go, and the first of them when its id is known (`thread/revert`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    pub num_turns: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before_turn_id: Option<String>,
    /// Claude Code: resume a copy of this conversation at this chain entry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_at: Option<String>,
}

impl PendingRollback {
    pub fn is_codex(&self) -> bool {
        self.thread_id.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Plan {
    /// The conversation already ends there.
    Nothing,
    Codex {
        thread: String,
        num_turns: usize,
        before_turn_id: Option<String>,
    },
    ClaudeResume {
        session: String,
        at: String,
    },
    /// Back to before the first message: the next turn starts a new conversation.
    Fresh,
    /// The conversation cannot follow (no mark, another agent or thread, turns Nook missed): files only.
    Unavailable,
}

/// Which agents roll back their own conversation (`ProviderCapabilities.canRollbackConversation`).
pub fn can_roll_back(provider: RunProvider) -> bool {
    match provider {
        RunProvider::Claude | RunProvider::Codex => true,
        RunProvider::Gemini
        | RunProvider::Opencode
        | RunProvider::Cursor
        | RunProvider::Grok
        | RunProvider::Antigravity
        | RunProvider::Pi => false,
    }
}

/// What it takes to bring the conversation back to `mark` (made with the checkpoint the files go back to).
pub fn plan(provider: RunProvider, mark: Option<&ConversationMark>, log: Option<&ConversationLog>, current: Option<&str>) -> Plan {
    let Some(mark) = mark.filter(|_| can_roll_back(provider)) else { return Plan::Unavailable };
    if mark.session.is_none() && mark.turns == 0 {
        return if current.is_none() { Plan::Nothing } else { Plan::Fresh };
    }
    let Some(session) = mark.session.clone().filter(|_| mark.provider == Some(provider)) else { return Plan::Unavailable };
    match provider {
        RunProvider::Codex => {
            let Some(log) = log.filter(|l| l.exact && mark.exact && l.provider == Some(provider)) else { return Plan::Unavailable };
            let Some(thread) = current.filter(|t| log.session.as_deref() == Some(*t) && session == *t) else { return Plan::Unavailable };
            if log.turns < mark.turns {
                return Plan::Unavailable;
            }
            let dropped = log.turns - mark.turns;
            if dropped == 0 {
                Plan::Nothing
            } else if mark.turns == 0 {
                Plan::Fresh
            } else {
                let before_turn_id = if log.turn_ids.len() == log.turns { log.turn_ids.get(mark.turns).cloned() } else { None };
                Plan::Codex { thread: thread.into(), num_turns: dropped, before_turn_id }
            }
        }
        RunProvider::Claude => {
            if log.is_some_and(|l| l.provider == Some(provider) && l.session.as_deref() == Some(session.as_str()) && l.head == mark.head) {
                return Plan::Nothing;
            }
            match &mark.head {
                Some(at) => Plan::ClaudeResume { session, at: at.clone() },
                None => Plan::Unavailable,
            }
        }
        _ => Plan::Unavailable,
    }
}

/// Adds a plan to a rollback that has not gone out yet: Codex's counts add up and the earlier turn id wins;
/// Claude Code's newest position replaces the old.
pub fn merge(pending: Option<PendingRollback>, plan: &Plan) -> Option<PendingRollback> {
    match plan {
        Plan::Nothing | Plan::Unavailable => pending,
        Plan::Codex { thread, num_turns, before_turn_id } => {
            let mut next = pending
                .filter(|p| p.thread_id.as_deref() == Some(thread.as_str()))
                .unwrap_or_else(|| PendingRollback { thread_id: Some(thread.clone()), ..Default::default() });
            next.num_turns += num_turns;
            next.before_turn_id = before_turn_id.clone();
            Some(next)
        }
        Plan::ClaudeResume { session, at } => {
            Some(PendingRollback { resume_session: Some(session.clone()), resume_at: Some(at.clone()), ..Default::default() })
        }
        Plan::Fresh => None,
    }
}

/// The checkpoints that stay when the files go back to the one at `index`, and the refs of those that go.
pub fn trim(checkpoints: &[RunCheckpoint], index: usize) -> (Vec<RunCheckpoint>, Vec<String>) {
    if index >= checkpoints.len() {
        return (checkpoints.to_vec(), vec![]);
    }
    (checkpoints[..=index].to_vec(), checkpoints[index + 1..].iter().map(|c| c.r#ref.clone()).collect())
}

/// Timeline entries after the point you went back to: the agent no longer remembers them.
pub fn rolled_back_ids(events: &[RunEvent], after: DateTime<Utc>) -> Vec<Uuid> {
    events.iter().filter(|e| e.date > after && e.rolled_back != Some(true)).map(|e| e.id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::EventKind;
    use chrono::Duration;

    fn mark(session: Option<&str>, provider: RunProvider, turns: usize, head: Option<&str>) -> ConversationMark {
        ConversationMark {
            session: session.map(str::to_string),
            provider: Some(provider),
            turns,
            head: head.map(str::to_string),
            exact: true,
        }
    }

    fn codex_log(ids: &[&str], thread: &str) -> ConversationLog {
        let mut log = ConversationLog::default();
        log.note_session(thread, RunProvider::Codex);
        for id in ids {
            log.start_turn(Some(id));
        }
        log
    }

    #[test]
    fn capabilities_match_can_roll_back() {
        assert!(RunProvider::Claude.capabilities().can_rollback_conversation);
        assert!(RunProvider::Codex.capabilities().can_rollback_conversation);
        for p in RunProvider::ALL {
            assert_eq!(p.capabilities().can_rollback_conversation, can_roll_back(p), "{p:?}");
            if p.uses_acp() {
                assert!(!can_roll_back(p), "{p:?}");
            }
        }
    }

    #[test]
    fn codex_drops_the_later_turns_and_tracks_turn_ids() {
        let log = codex_log(&["a", "b", "c"], "th");
        let at = mark(Some("th"), RunProvider::Codex, 1, None);
        assert_eq!(
            plan(RunProvider::Codex, Some(&at), Some(&log), Some("th")),
            Plan::Codex { thread: "th".into(), num_turns: 2, before_turn_id: Some("b".into()) }
        );
        let mut rewound = log.clone();
        rewound.rewind(&at);
        assert_eq!(rewound.turns, 1);
        assert_eq!(rewound.turn_ids, vec!["a"]);
        assert_eq!(plan(RunProvider::Codex, Some(&log.mark()), Some(&log), Some("th")), Plan::Nothing);
    }

    #[test]
    fn codex_counts_turn_once_and_missing_id_clears_before_turn_id() {
        let mut log = codex_log(&["a", "a"], "th");
        assert_eq!(log.turns, 1, "turn/start reply and turn/started name the same turn");
        log.start_turn(None);
        let at = mark(Some("th"), RunProvider::Codex, 1, None);
        assert_eq!(
            plan(RunProvider::Codex, Some(&at), Some(&log), Some("th")),
            Plan::Codex { thread: "th".into(), num_turns: 1, before_turn_id: None }
        );
    }

    #[test]
    fn codex_refuses_what_it_cannot_count() {
        let log = codex_log(&["a", "b"], "th");
        let at = mark(Some("th"), RunProvider::Codex, 1, None);
        assert_eq!(plan(RunProvider::Codex, Some(&at), Some(&log), Some("other")), Plan::Unavailable);
        let mut inexact = log.clone();
        inexact.exact = false;
        assert_eq!(plan(RunProvider::Codex, Some(&at), Some(&inexact), Some("th")), Plan::Unavailable);
        assert_eq!(plan(RunProvider::Codex, None, Some(&log), Some("th")), Plan::Unavailable);
        let claude_mark = mark(Some("th"), RunProvider::Claude, 1, Some("u"));
        assert_eq!(plan(RunProvider::Codex, Some(&claude_mark), Some(&log), Some("th")), Plan::Unavailable);
    }

    #[test]
    fn claude_resumes_a_copy_at_the_head() {
        let mut log = ConversationLog::default();
        log.start_turn(None);
        log.note_session("s1", RunProvider::Claude);
        assert_eq!(log.turns, 1, "session arrives after the turn started");
        log.note_head("u1");
        let at = log.mark();
        log.start_turn(None);
        log.note_head("u2");
        assert_eq!(
            plan(RunProvider::Claude, Some(&at), Some(&log), Some("s1")),
            Plan::ClaudeResume { session: "s1".into(), at: "u1".into() }
        );
        // A resumed copy (--fork-session) gets a new id and keeps its history; the old mark still names the original.
        log.note_session("s2", RunProvider::Claude);
        assert_eq!(log.turns, 2);
        assert_eq!(log.head.as_deref(), Some("u2"));
        assert_eq!(
            plan(RunProvider::Claude, Some(&at), Some(&log), Some("s2")),
            Plan::ClaudeResume { session: "s1".into(), at: "u1".into() }
        );
        assert_eq!(plan(RunProvider::Claude, Some(&log.mark()), Some(&log), Some("s2")), Plan::Nothing);
        let headless = mark(Some("s1"), RunProvider::Claude, 1, None);
        assert_eq!(plan(RunProvider::Claude, Some(&headless), Some(&log), Some("s2")), Plan::Unavailable);
    }

    #[test]
    fn before_the_first_message_starts_fresh_and_others_follow_files_only() {
        let log = codex_log(&["a"], "t1");
        assert_eq!(plan(RunProvider::Codex, Some(&ConversationMark::empty()), Some(&log), Some("t1")), Plan::Fresh);
        assert_eq!(plan(RunProvider::Claude, Some(&ConversationMark::empty()), None, Some("s1")), Plan::Fresh);
        assert_eq!(plan(RunProvider::Claude, Some(&ConversationMark::empty()), None, None), Plan::Nothing);
        let opened = mark(Some("t1"), RunProvider::Codex, 0, None);
        assert_eq!(plan(RunProvider::Codex, Some(&opened), Some(&log), Some("t1")), Plan::Fresh);
        assert_eq!(plan(RunProvider::Gemini, Some(&ConversationMark::empty()), None, Some("g")), Plan::Unavailable);
        assert_eq!(plan(RunProvider::Claude, None, None, Some("s1")), Plan::Unavailable);
    }

    #[test]
    fn another_agent_or_codex_thread_resets_log() {
        let mut log = codex_log(&["a", "b"], "t1");
        log.note_session("s1", RunProvider::Claude);
        assert_eq!(log.provider, Some(RunProvider::Claude));
        assert_eq!(log.turns, 0);
        assert!(log.turn_ids.is_empty());

        let mut thread = codex_log(&["a"], "t1");
        thread.note_session("t2", RunProvider::Codex);
        assert_eq!(thread.turns, 0);
        assert!(thread.turn_ids.is_empty());
    }

    #[test]
    fn pending_rollbacks_merge_correctly() {
        let first = merge(None, &Plan::Codex { thread: "t".into(), num_turns: 2, before_turn_id: Some("c".into()) });
        let second = merge(first, &Plan::Codex { thread: "t".into(), num_turns: 1, before_turn_id: Some("b".into()) }).unwrap();
        assert_eq!(second.thread_id.as_deref(), Some("t"));
        assert_eq!(second.num_turns, 3);
        assert_eq!(second.before_turn_id.as_deref(), Some("b"));
        assert!(second.is_codex());
        assert_eq!(merge(Some(second.clone()), &Plan::Nothing), Some(second.clone()));
        assert_eq!(merge(Some(second), &Plan::Fresh), None);

        let claude = merge(
            Some(PendingRollback { resume_session: Some("s".into()), resume_at: Some("u2".into()), ..Default::default() }),
            &Plan::ClaudeResume { session: "s".into(), at: "u1".into() },
        )
        .unwrap();
        assert_eq!(claude.resume_session.as_deref(), Some("s"));
        assert_eq!(claude.resume_at.as_deref(), Some("u1"));
        assert!(!claude.is_codex());
    }

    #[test]
    fn trims_checkpoints_and_marks_rolled_back_events() {
        let t0 = Utc::now();
        let c = |r: &str, secs: i64| RunCheckpoint { r#ref: r.into(), date: t0 + Duration::seconds(secs), conversation: None };
        let (kept, gone) = trim(&[c("a", 0), c("b", 10), c("c", 20)], 0);
        assert_eq!(kept.len(), 1);
        assert_eq!(gone, vec!["b".to_string(), "c".to_string()]);
        assert!(trim(&[c("a", 0)], 9).1.is_empty());

        let mut before = RunEvent::new(EventKind::User, "one");
        before.date = t0 + Duration::seconds(5);
        let mut after = RunEvent::new(EventKind::User, "two");
        after.date = t0 + Duration::seconds(15);
        let mut already = RunEvent::new(EventKind::Assistant, "old");
        already.date = t0 + Duration::seconds(16);
        already.rolled_back = Some(true);
        assert_eq!(rolled_back_ids(&[before, after.clone(), already], t0 + Duration::seconds(10)), vec![after.id]);
    }

    #[test]
    fn old_checkpoint_and_event_json_still_decode() {
        let cp: RunCheckpoint = serde_json::from_str(r#"{"ref":"r","date":"2026-01-01T00:00:00Z"}"#).unwrap();
        assert!(cp.conversation.is_none());
        let ev = RunEvent::new(EventKind::User, "hi");
        let raw = serde_json::to_string(&ev).unwrap();
        assert!(!raw.contains("rolledBack"));
        let decoded: RunEvent = serde_json::from_str(&raw).unwrap();
        assert_eq!(decoded.rolled_back, None);
    }
}
