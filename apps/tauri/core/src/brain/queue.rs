//! Questions waiting for the answer Nook is writing (`MessageQueue` behind `NookChat.enqueue` on the Mac): each goes out
//! on its own once that answer is done, can be reordered or taken back, and after a stop or an error the line is held
//! until you send one of its questions yourself.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::PromptImage;

/// At most this many questions wait; one more is refused.
pub const LIMIT: usize = 50;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedQuestion {
    pub id: String,
    pub text: String,
    pub created: DateTime<Utc>,
    /// Pictures that go with it. Kept in memory only, like the Mac: a restart keeps the question, not its pictures.
    #[serde(default, skip_serializing)]
    pub images: Vec<PromptImage>,
    /// How many pictures it had, so the row can show them without sending the pictures to the window.
    #[serde(default)]
    pub image_count: usize,
    /// A document that goes with it: its name and text. In memory only, like the pictures.
    #[serde(default, skip_serializing)]
    pub document: Option<(String, String)>,
    /// The document's name, for the row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document_name: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageQueue {
    #[serde(default)]
    pub messages: Vec<QueuedQuestion>,
    /// Held after a stop or an error: nothing goes out on its own.
    #[serde(default)]
    pub is_held: bool,
}

impl MessageQueue {
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    /// Puts a question in line. None when it is empty or the line is full.
    pub fn enqueue(
        &mut self,
        text: &str,
        images: Vec<PromptImage>,
        document: Option<(String, String)>,
        now: DateTime<Utc>,
    ) -> Option<&QueuedQuestion> {
        let text = text.trim();
        if (text.is_empty() && images.is_empty() && document.is_none()) || self.messages.len() >= LIMIT {
            return None;
        }
        self.messages.push(QueuedQuestion {
            id: uuid::Uuid::new_v4().to_string(),
            text: text.to_string(),
            created: now,
            image_count: images.len(),
            images,
            document_name: document.as_ref().map(|d| d.0.clone()),
            document,
        });
        self.messages.last()
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.messages.len();
        self.messages.retain(|m| m.id != id);
        if self.messages.is_empty() {
            self.is_held = false;
        }
        self.messages.len() != before
    }

    /// Moves a question to `to`, clamped to the line, so a move past either end lands at that end.
    pub fn move_to(&mut self, id: &str, to: usize) -> bool {
        let Some(from) = self.messages.iter().position(|m| m.id == id) else { return false };
        let to = to.min(self.messages.len() - 1);
        let message = self.messages.remove(from);
        self.messages.insert(to, message);
        true
    }

    /// The next question to send, or none when the line is held or empty.
    pub fn take_next(&mut self) -> Option<QueuedQuestion> {
        if self.is_held || self.messages.is_empty() {
            return None;
        }
        Some(self.messages.remove(0))
    }

    /// Takes this question out to send it now; sending one yourself lets a held line go again.
    pub fn take(&mut self, id: &str) -> Option<QueuedQuestion> {
        let index = self.messages.iter().position(|m| m.id == id)?;
        self.is_held = false;
        Some(self.messages.remove(index))
    }

    /// After a stop or an error. An empty line has nothing to hold.
    pub fn hold(&mut self) {
        if !self.messages.is_empty() {
            self.is_held = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue(texts: &[&str]) -> MessageQueue {
        let mut q = MessageQueue::default();
        for t in texts {
            q.enqueue(t, vec![], None, Utc::now());
        }
        q
    }

    fn texts(q: &MessageQueue) -> Vec<&str> {
        q.messages.iter().map(|m| m.text.as_str()).collect()
    }

    #[test]
    fn questions_wait_in_the_order_they_came() {
        let mut q = queue(&["one", "two"]);
        assert_eq!(q.take_next().unwrap().text, "one");
        assert_eq!(q.take_next().unwrap().text, "two");
        assert!(q.take_next().is_none());
    }

    #[test]
    fn an_empty_question_and_one_past_the_limit_are_refused() {
        let mut q = queue(&["  "]);
        assert!(q.is_empty());
        for i in 0..LIMIT {
            assert!(q.enqueue(&format!("q{i}"), vec![], None, Utc::now()).is_some());
        }
        assert!(q.enqueue("one more", vec![], None, Utc::now()).is_none());
        assert_eq!(q.messages.len(), LIMIT);
    }

    #[test]
    fn a_picture_or_a_document_alone_is_a_question() {
        let mut q = MessageQueue::default();
        let image = PromptImage { media_type: "image/png".into(), base64: "AA==".into() };
        assert_eq!(q.enqueue("", vec![image], None, Utc::now()).unwrap().image_count, 1);
        let doc = q.enqueue("", vec![], Some(("notes.txt".into(), "hello".into())), Utc::now()).unwrap();
        assert_eq!(doc.document_name.as_deref(), Some("notes.txt"));
    }

    #[test]
    fn moving_is_clamped_to_the_line() {
        let mut q = queue(&["a", "b", "c"]);
        let c = q.messages[2].id.clone();
        assert!(q.move_to(&c, 0));
        assert_eq!(texts(&q), ["c", "a", "b"]);
        assert!(q.move_to(&c, 99));
        assert_eq!(texts(&q), ["a", "b", "c"]);
        assert!(!q.move_to("gone", 0));
    }

    #[test]
    fn a_held_line_waits_until_you_send_one_of_its_questions() {
        let mut q = queue(&["a", "b"]);
        q.hold();
        assert!(q.take_next().is_none());
        let b = q.messages[1].id.clone();
        assert_eq!(q.take(&b).unwrap().text, "b");
        assert!(!q.is_held);
        assert_eq!(q.take_next().unwrap().text, "a");
    }

    #[test]
    fn an_empty_line_is_never_held() {
        let mut q = MessageQueue::default();
        q.hold();
        assert!(!q.is_held);
        let mut q = queue(&["a"]);
        q.hold();
        let a = q.messages[0].id.clone();
        q.remove(&a);
        assert!(!q.is_held);
    }

    #[test]
    fn pictures_and_documents_stay_out_of_the_saved_line() {
        let mut q = MessageQueue::default();
        q.enqueue(
            "look",
            vec![PromptImage { media_type: "image/png".into(), base64: "AA==".into() }],
            Some(("a.txt".into(), "secret text".into())),
            Utc::now(),
        );
        let saved = serde_json::to_string(&q).unwrap();
        assert!(!saved.contains("AA==") && !saved.contains("secret text"));
        let back: MessageQueue = serde_json::from_str(&saved).unwrap();
        assert_eq!(back.messages[0].image_count, 1);
        assert!(back.messages[0].images.is_empty());
    }
}
