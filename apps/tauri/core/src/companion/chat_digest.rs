//! Nook's own chats as the phone sees them (`ChatDigest`, `ChatLine` in `packages/protocol`): the list of
//! conversations for `chats`, and one conversation's messages for `chat`, `ask` and `chatStop`, the way the Mac's
//! `CompanionServer.lines(_:)` cuts them. Pure: the same conversation always gives the same JSON, so a live phone is
//! only sent what changed (`live::delta` compares the lines by value).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::models::EXCERPT_LIMIT;
use crate::nooks::{ChatMessage, Conversation, ConversationStatus, ConversationSummary};

/// One line of a conversation as the phone sees it (`CompanionConstants.lineLimit`).
pub const LINE_LIMIT: usize = 4_000;
/// What the lines of one answer may take together, well under `MAX_FRAME` once sealed and framed.
pub const LINES_BUDGET: usize = 150_000;
/// How many conversations `chats` lists, and how many messages of one `chat` shows (as on the Mac).
pub const MAX_CONVERSATIONS: usize = 40;
pub const MAX_LINES: usize = 60;
/// What Nook is doing, as a line under an answer without text yet.
const STATUS_LIMIT: usize = 120;

/// One Nook conversation in the phone's list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatDigest {
    pub id: String,
    pub title: String,
    pub updated: f64,
    /// Nook is writing an answer.
    pub busy: bool,
    /// A plan or a draft waits for you (on the computer).
    pub waiting: bool,
    pub preview: String,
}

/// One message of a Nook conversation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatLine {
    pub id: String,
    pub from_nook: bool,
    pub text: String,
    pub date: f64,
    pub streaming: bool,
    /// What Nook is doing while the answer has no text yet ("Looking in your calendar…").
    pub status: String,
    pub failed: bool,
    /// The answer carries a plan, a mail draft or a chart: those are handled on the computer.
    pub on_mac: bool,
}

/// `text` without carriage returns and surrounding white space, cut at `limit` characters with an ellipsis. Only its
/// start is read, as `CompanionPolicy.cut` on the Mac: an answer can be long and is cut every time the phone looks.
pub fn clip(text: &str, limit: usize) -> String {
    let start = text.trim_start();
    let mut head = String::new();
    let mut more = false;
    for (taken, c) in start.chars().enumerate() {
        if taken >= limit * 2 + 16 {
            more = true;
            break;
        }
        head.push(c);
    }
    let flat = head.replace('\r', "");
    let flat = flat.trim();
    let count = flat.chars().count();
    if !more && count <= limit {
        return flat.to_string();
    }
    let mut cut: String = flat.chars().take(limit).collect();
    cut.push('…');
    cut
}

fn seconds(date: chrono::DateTime<chrono::Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

/// The conversations of the list on the computer (pinned first, then newest), at most `MAX_CONVERSATIONS`.
pub fn digests(list: &[ConversationSummary]) -> Vec<ChatDigest> {
    list.iter()
        .take(MAX_CONVERSATIONS)
        .map(|c| ChatDigest {
            id: c.id.clone(),
            title: clip(&c.title, EXCERPT_LIMIT),
            updated: seconds(c.updated),
            busy: c.status == ConversationStatus::Working,
            waiting: c.status == ConversationStatus::Waiting,
            preview: c.preview.clone(),
        })
        .collect()
}

/// One message. `partial` is the answer written so far while it streams (the app keeps it out of the stored
/// conversation until it is done).
pub fn line(message: &ChatMessage, partial: Option<&str>) -> ChatLine {
    let text = match partial.filter(|_| message.streaming) {
        Some(partial) if partial.len() >= message.text.len() => partial,
        _ => message.text.as_str(),
    };
    ChatLine {
        id: message.id.clone(),
        from_nook: !message.from_user,
        text: clip(text, LINE_LIMIT),
        date: seconds(message.date),
        streaming: message.streaming,
        status: clip(&message.status, STATUS_LIMIT),
        failed: message.is_error,
        on_mac: !message.actions.is_empty() || !message.mails.is_empty() || !message.charts.is_empty(),
    }
}

/// The newest `MAX_LINES` messages, oldest first, as far as they fit in `LINES_BUDGET`. `partials` holds the text
/// so far of answers being written, by message id.
pub fn lines(conversation: &Conversation, partials: &HashMap<String, String>) -> Vec<ChatLine> {
    let start = conversation.messages.len().saturating_sub(MAX_LINES);
    let all: Vec<ChatLine> = conversation.messages[start..].iter().map(|m| line(m, partials.get(&m.id).map(String::as_str))).collect();
    newest_fitting(all, LINES_BUDGET)
}

/// The newest items whose JSON together stays within `budget` bytes, oldest first, so one answer always fits a frame.
pub fn newest_fitting<T: Serialize>(items: Vec<T>, budget: usize) -> Vec<T> {
    let mut used = 0;
    let mut kept = Vec::new();
    for item in items.into_iter().rev() {
        let size = serde_json::to_vec(&item).map(|b| b.len()).unwrap_or(budget + 1);
        if used + size > budget {
            break;
        }
        used += size;
        kept.push(item);
    }
    kept.reverse();
    kept
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::PlannedAction;
    use crate::nooks::NookChat;
    use chrono::TimeZone;

    fn message(id: &str, from_user: bool, text: &str) -> ChatMessage {
        ChatMessage {
            id: id.into(),
            from_user,
            text: text.into(),
            date: chrono::Utc.timestamp_millis_opt(1_700_000_000_500).unwrap(),
            ..Default::default()
        }
    }

    fn conversation(messages: Vec<ChatMessage>) -> Conversation {
        Conversation { id: "c1".into(), title: "Agenda".into(), messages, ..Default::default() }
    }

    #[test]
    fn a_line_has_the_keys_swift_decodes() {
        let line = line(&message("m1", false, "Hallo"), None);
        let json = serde_json::to_value(&line).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "id": "m1", "fromNook": true, "text": "Hallo", "date": 1_700_000_000.5, "streaming": false,
                "status": "", "failed": false, "onMac": false
            })
        );
    }

    #[test]
    fn the_same_conversation_gives_the_same_json() {
        let c = conversation(vec![message("q", true, "Wat staat er morgen?"), message("a", false, "Twee afspraken.")]);
        let a = serde_json::to_string(&lines(&c, &HashMap::new())).unwrap();
        let b = serde_json::to_string(&lines(&c.clone(), &HashMap::new())).unwrap();
        assert_eq!(a, b);
        assert_eq!(lines(&c, &HashMap::new()).iter().map(|l| l.from_nook).collect::<Vec<_>>(), vec![false, true]);
    }

    #[test]
    fn an_answer_being_written_shows_its_text_so_far() {
        let mut answer = message("a", false, "");
        answer.streaming = true;
        answer.status = "Even nadenken…".into();
        let c = conversation(vec![message("q", true, "Vraag"), answer]);
        let partials = HashMap::from([("a".to_string(), "Twee afs".to_string())]);
        let shown = lines(&c, &partials);
        assert_eq!(shown[1].text, "Twee afs");
        assert!(shown[1].streaming);
        assert_eq!(shown[1].status, "Even nadenken…");
        // Once done, the stored text counts, whatever was left behind.
        let mut done = c.clone();
        done.messages[1].streaming = false;
        done.messages[1].text = "Twee afspraken.".into();
        assert_eq!(lines(&done, &partials)[1].text, "Twee afspraken.");
    }

    #[test]
    fn plans_drafts_and_charts_are_on_the_computer() {
        let mut answer = message("a", false, "Zal ik dit doen?");
        answer.actions = vec![PlannedAction::new("create_reminder", serde_json::json!({"title": "bellen"}))];
        assert!(line(&answer, None).on_mac);
        let mut failed = message("e", false, "Geen verbinding");
        failed.is_error = true;
        assert!(line(&failed, None).failed);
        assert!(!line(&failed, None).on_mac);
    }

    #[test]
    fn long_text_is_cut_and_only_the_newest_lines_go() {
        assert_eq!(clip("  a\r\nb  ", 10), "a\nb");
        assert_eq!(clip(&"x".repeat(5_000), LINE_LIMIT).chars().count(), LINE_LIMIT + 1);
        assert_eq!(clip(&"x".repeat(LINE_LIMIT), LINE_LIMIT).chars().count(), LINE_LIMIT);
        let many: Vec<ChatMessage> = (0..70).map(|i| message(&format!("m{i}"), i % 2 == 0, &"y".repeat(3_000))).collect();
        let shown = lines(&conversation(many), &HashMap::new());
        assert!(shown.len() < MAX_LINES, "150 KB holds fewer than 60 lines of 3,000 characters");
        assert_eq!(shown.last().unwrap().id, "m69");
        let size: usize = shown.iter().map(|l| serde_json::to_vec(l).unwrap().len()).sum();
        assert!(size <= LINES_BUDGET);
    }

    #[test]
    fn the_list_says_what_is_busy_and_what_waits() {
        let mut chat = NookChat::default();
        let mut waiting = conversation(vec![message("q", true, "Herinner me"), message("a", false, "Zal ik?")]);
        waiting.messages[1].actions = vec![PlannedAction::new("create_reminder", serde_json::json!({}))];
        let mut working = conversation(vec![message("q2", true, "Hoi")]);
        working.id = "c2".into();
        working.busy = true;
        chat.conversations = vec![waiting, working];
        let list = digests(&chat.list(false));
        let by_id = |id: &str| list.iter().find(|d| d.id == id).unwrap().clone();
        assert!(by_id("c1").waiting && !by_id("c1").busy);
        assert!(by_id("c2").busy);
        assert_eq!(by_id("c1").preview, "Zal ik?");
        let json = serde_json::to_value(by_id("c1")).unwrap();
        for key in ["id", "title", "updated", "busy", "waiting", "preview"] {
            assert!(json.get(key).is_some(), "{key}");
        }
    }
}
