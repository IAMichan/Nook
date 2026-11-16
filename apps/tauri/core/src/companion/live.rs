//! What the computer keeps for a phone's live connection (`subscribe`, `feature::STREAM`), as the Mac keeps a
//! `CompanionPeer`: what it last sent, so only what changed goes, and what the phone has open (a session, a chat, a Nook
//! conversation), so that follows by itself. Also the answers kept for requests that change something
//! (`CommandReceipts`, `feature::RETRY`): a repeat from the phone's outbox gets the same answer without doing it again.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::mpsc::UnboundedSender;

use super::models::{CompanionOp, CompanionResponse, SessionDigest};

/// A live connection is closed after this long without a word from the phone (`CompanionTiming.streamIdle`); the phone
/// pings every 5 seconds while it is in front.
pub const STREAM_IDLE: Duration = Duration::from_secs(45);
/// A connection that never subscribed is closed after this long without a request.
pub const REQUEST_IDLE: Duration = Duration::from_secs(30);
/// How often the live phones are looked at when the backend does not say something changed.
pub const TICK: Duration = Duration::from_millis(1500);
/// A full look (sessions of agents in a terminal, chats) at least this often.
pub const FULL_LOOK: Duration = Duration::from_secs(5);
/// More than this many frames waiting on a phone's connection and it gets nothing new until it took them
/// (`StreamBackpressure`); far more and the connection is dropped, so the phone starts again from a fresh snapshot.
pub const BACKLOG_WAIT: usize = 16;
pub const BACKLOG_DROP: usize = 256;

/// One phone's live connection.
pub struct Peer {
    pub device: String,
    pub key: Vec<u8>,
    /// The id of the `subscribe` request: every update carries it, with a growing `seq`.
    pub stream_id: String,
    pub seq: i64,
    pub tx: UnboundedSender<Vec<u8>>,
    /// Frames handed to the writer that it has not written yet.
    pub pending: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    pub compression: bool,
    pub foreground: bool,
    pub last_heard: Instant,
    pub sent_sessions: Option<Vec<SessionDigest>>,
    /// The session the phone has open (`watch`) and the conversation it last got of it.
    pub watch: Option<String>,
    pub sent_timeline: Vec<Value>,
    /// The chat the phone has open in the Chats tab (`watchChat`) and its messages and who types, as last sent.
    pub watch_chat: Option<String>,
    pub sent_chat: Option<(Value, Value)>,
    pub sent_inbox: Option<Value>,
    /// The Nook conversation the phone has open (`watchConversation`) and its messages as last sent.
    pub watch_conversation: Option<String>,
    pub sent_messages: Option<Vec<Value>>,
    pub sent_conversations: Option<Value>,
}

impl Peer {
    pub fn new(
        device: String,
        key: Vec<u8>,
        stream_id: String,
        tx: UnboundedSender<Vec<u8>>,
        pending: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) -> Self {
        Self {
            device,
            key,
            stream_id,
            seq: 0,
            tx,
            pending,
            compression: false,
            foreground: false,
            last_heard: Instant::now(),
            sent_sessions: None,
            watch: None,
            sent_timeline: Vec::new(),
            watch_chat: None,
            sent_chat: None,
            sent_inbox: None,
            watch_conversation: None,
            sent_messages: None,
            sent_conversations: None,
        }
    }

    /// The next update on this connection: the stream's id and the next number.
    pub fn update(&mut self) -> CompanionResponse {
        self.seq += 1;
        CompanionResponse { seq: Some(self.seq), ..CompanionResponse::success(&self.stream_id) }
    }

    pub fn backlog(&self) -> usize {
        self.pending.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// The id of an entry or message (`TimelineEntry.id`, `ChatLine.id`).
fn id_of(value: &Value) -> Option<&str> {
    value.get("id").and_then(Value::as_str)
}

/// What to send to move a phone that has `old` to `new` (`TimelineDelta.delta`): the entry to put the rest after
/// (`None`: send `new` whole), and the rest.
pub fn delta(old: &[Value], new: &[Value]) -> (Option<String>, Vec<Value>) {
    let Some(first) = new.first().and_then(id_of) else { return (None, new.to_vec()) };
    let Some(start) = old.iter().position(|e| id_of(e) == Some(first)) else { return (None, new.to_vec()) };
    let mut shared = 0;
    while shared < new.len() && start + shared < old.len() && old[start + shared] == new[shared] {
        shared += 1;
    }
    if shared == 0 {
        return (None, new.to_vec());
    }
    (id_of(&new[shared - 1]).map(str::to_string), new[shared..].to_vec())
}

/// What a `watch` that names the last entry the phone has gets (`TimelineResume.resume`): the entries from that one on,
/// after the one before it, so an answer that was still being written is replaced too. `None`: send it whole.
pub fn resume_timeline(entries: &[Value], last: Option<&str>) -> Option<(String, Vec<Value>)> {
    let last = last?;
    let index = entries.iter().rposition(|e| id_of(e) == Some(last))?;
    if index == 0 {
        return None;
    }
    Some((id_of(&entries[index - 1])?.to_string(), entries[index..].to_vec()))
}

/// What a `watchConversation` that names the phone's last finished message gets (`ConversationResume.resume`): the
/// messages after it. `None` when that message is not here (any more) as a finished one.
pub fn resume_conversation(lines: &[Value], last: Option<&str>) -> Option<(String, Vec<Value>)> {
    let last = last?;
    let index = lines.iter().rposition(|l| id_of(l) == Some(last))?;
    if lines[index].get("streaming").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    Some((last.to_string(), lines[index + 1..].to_vec()))
}

/// The requests that change something (`CommandReceipts.keeps`): a repeat of one must not do it again.
pub fn keeps(op: CompanionOp) -> bool {
    use CompanionOp::*;
    matches!(
        op,
        Send | Answer
            | Decide
            | Stop
            | Start
            | Ask
            | InboxSend
            | Manage
            | ChatStop
            | Music
            | InboxMark
            | Register
            | Unregister
            | RequestUpdate
            | PullAct
            | PullWork
            | BindKey
    )
}

/// Whether an answer settles its request (`CommandReceipts.settles`): one that failed in passing may be tried again.
pub fn settles(response: &CompanionResponse) -> bool {
    !matches!(response.error, Some(super::models::CompanionError::Failed) | Some(super::models::CompanionError::Busy))
}

/// The answers to requests that changed something, per id, least recently used first (`CommandReceipts`).
#[derive(Default)]
pub struct Receipts {
    order: VecDeque<String>,
    answers: HashMap<String, (Option<CompanionResponse>, Instant)>,
}

pub enum Lookup {
    New,
    Running,
    Answered(CompanionResponse),
}

impl Receipts {
    pub const CAPACITY: usize = 256;
    /// The outbox keeps a message a day; an hour more to be sure.
    pub const LIFETIME: Duration = Duration::from_secs(25 * 3600);

    pub fn begin(&mut self, id: &str) -> Lookup {
        if let Some((answer, at)) = self.answers.get(id) {
            if at.elapsed() <= Self::LIFETIME {
                return match answer {
                    Some(a) => Lookup::Answered(a.clone()),
                    None => Lookup::Running,
                };
            }
        }
        self.insert(id, None);
        Lookup::New
    }

    pub fn finish(&mut self, id: &str, response: &CompanionResponse) {
        if settles(response) {
            self.insert(id, Some(response.clone()));
        } else {
            self.cancel(id);
        }
    }

    pub fn cancel(&mut self, id: &str) {
        self.answers.remove(id);
        self.order.retain(|o| o != id);
    }

    fn insert(&mut self, id: &str, answer: Option<CompanionResponse>) {
        self.order.retain(|o| o != id);
        self.order.push_back(id.to_string());
        self.answers.insert(id.to_string(), (answer, Instant::now()));
        while self.order.len() > Self::CAPACITY {
            if let Some(old) = self.order.pop_front() {
                self.answers.remove(&old);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn delta_sends_only_the_tail() {
        let old = vec![json!({"id": "a", "t": 1}), json!({"id": "b", "t": 1})];
        let new = vec![json!({"id": "a", "t": 1}), json!({"id": "b", "t": 1}), json!({"id": "c", "t": 1})];
        assert_eq!(delta(&old, &new), (Some("b".into()), vec![json!({"id": "c", "t": 1})]));
        // A changed last entry goes again, after the one before it.
        let changed = vec![json!({"id": "a", "t": 1}), json!({"id": "b", "t": 2})];
        assert_eq!(delta(&old, &changed), (Some("a".into()), vec![json!({"id": "b", "t": 2})]));
        // Nothing shared: the whole conversation.
        assert_eq!(delta(&old, &[json!({"id": "z"})]).0, None);
    }

    #[test]
    fn resume_replaces_the_last_entry() {
        let entries = vec![json!({"id": "a"}), json!({"id": "b"}), json!({"id": "c"})];
        assert_eq!(resume_timeline(&entries, Some("b")), Some(("a".into(), vec![json!({"id": "b"}), json!({"id": "c"})])));
        assert_eq!(resume_timeline(&entries, Some("a")), None);
        assert_eq!(resume_timeline(&entries, Some("x")), None);
        let lines = vec![json!({"id": "1"}), json!({"id": "2", "streaming": true})];
        assert_eq!(resume_conversation(&lines, Some("1")), Some(("1".into(), vec![json!({"id": "2", "streaming": true})])));
        assert_eq!(resume_conversation(&lines, Some("2")), None);
    }

    #[test]
    fn receipts_answer_a_repeat_once() {
        let mut receipts = Receipts::default();
        assert!(matches!(receipts.begin("x"), Lookup::New));
        assert!(matches!(receipts.begin("x"), Lookup::Running));
        receipts.finish("x", &CompanionResponse::success("x"));
        assert!(matches!(receipts.begin("x"), Lookup::Answered(r) if r.ok));
        // A failure in passing may be tried again.
        assert!(matches!(receipts.begin("y"), Lookup::New));
        receipts.finish("y", &CompanionResponse::failure("y", super::super::models::CompanionError::Failed));
        assert!(matches!(receipts.begin("y"), Lookup::New));
    }
}
