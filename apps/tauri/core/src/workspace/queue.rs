//! De wachtrij van vervolgberichten per sessie (`MessageQueue` op de Mac: volgorde, wissen, bewerken,
//! nu meesturen). Na een fout, een stop of een herstart staat hij stil, zodat er niets bovenop een probleem verstuurd
//! wordt; jij zet hem weer aan.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedMessage {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub text: String,
    #[serde(default = "epoch")]
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub edited: bool,
}

fn epoch() -> DateTime<Utc> {
    DateTime::<Utc>::UNIX_EPOCH
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct EditSession {
    message_id: Uuid,
    /// Wat het invoerveld had voor het bewerken begon; komt daarna terug.
    previous_draft: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MessageQueue {
    messages: Vec<QueuedMessage>,
    is_held: bool,
    #[serde(skip)]
    edit_session: Option<EditSession>,
}

impl MessageQueue {
    pub const LIMIT: usize = 50;

    pub fn messages(&self) -> &[QueuedMessage] {
        &self.messages
    }

    pub fn is_held(&self) -> bool {
        self.is_held
    }

    pub fn len(&self) -> usize {
        self.messages.len()
    }

    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    /// Het nieuwe bericht, of `None` als de tekst leeg is of de wachtrij vol.
    pub fn enqueue(&mut self, text: &str) -> Option<QueuedMessage> {
        let trimmed = text.trim();
        if trimmed.is_empty() || self.messages.len() >= Self::LIMIT {
            return None;
        }
        let m = QueuedMessage { id: Uuid::new_v4(), text: trimmed.into(), created_at: Utc::now(), edited: false };
        self.messages.push(m.clone());
        Some(m)
    }

    /// Een lege tekst wordt geweigerd (weghalen gaat met `remove`).
    pub fn edit(&mut self, id: Uuid, text: &str) -> bool {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return false;
        }
        let Some(m) = self.messages.iter_mut().find(|m| m.id == id) else { return false };
        if m.text != trimmed {
            m.text = trimmed.into();
            m.edited = true;
        }
        true
    }

    pub fn remove(&mut self, id: Uuid) -> bool {
        let Some(index) = self.messages.iter().position(|m| m.id == id) else { return false };
        self.messages.remove(index);
        if self.edit_session.as_ref().is_some_and(|e| e.message_id == id) {
            self.edit_session = None;
        }
        true
    }

    /// `to_index` wordt begrensd, zodat slepen voorbij een eind op dat eind belandt.
    pub fn move_to(&mut self, id: Uuid, to_index: i64) -> bool {
        let Some(index) = self.messages.iter().position(|m| m.id == id) else { return false };
        let target = to_index.clamp(0, self.messages.len() as i64 - 1) as usize;
        if target != index {
            let m = self.messages.remove(index);
            self.messages.insert(target, m);
        }
        true
    }

    /// Haalt het bericht eruit om het nu in de lopende beurt te sturen; een tweede keer vindt niets.
    pub fn promote_to_steer(&mut self, id: Uuid) -> Option<String> {
        let index = self.messages.iter().position(|m| m.id == id)?;
        if self.edit_session.as_ref().is_some_and(|e| e.message_id == id) {
            self.edit_session = None;
        }
        Some(self.messages.remove(index).text)
    }

    /// Zet een bericht dat niet weg kon terug vooraan. Het was al te zien, dus de limiet telt niet: het wacht in plaats
    /// van verloren te gaan.
    pub fn requeue_first(&mut self, text: &str) {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            self.messages.insert(0, QueuedMessage { id: Uuid::new_v4(), text: trimmed.into(), created_at: Utc::now(), edited: false });
        }
    }

    pub fn clear(&mut self) {
        self.messages.clear();
        self.edit_session = None;
    }

    /// Het volgende bericht om te versturen, of `None` als de wachtrij stilstaat of leeg is. Het bericht dat je bewerkt
    /// blijft staan.
    pub fn next(&mut self, held: bool) -> Option<QueuedMessage> {
        if held || self.is_held {
            return None;
        }
        let editing = self.edit_session.as_ref().map(|e| e.message_id);
        let index = self.messages.iter().position(|m| Some(m.id) != editing)?;
        Some(self.messages.remove(index))
    }

    pub fn hold(&mut self) {
        self.is_held = true;
    }

    pub fn resume(&mut self) {
        self.is_held = false;
    }

    /// De tekst voor het invoerveld. Een tweede `begin_edit` houdt het eerste concept, zodat je eigen tekst nooit
    /// door die van een ander bericht vervangen wordt.
    pub fn begin_edit(&mut self, id: Uuid, current_draft: &str) -> Option<String> {
        let text = self.messages.iter().find(|m| m.id == id)?.text.clone();
        let previous = self.edit_session.as_ref().map(|e| e.previous_draft.clone()).unwrap_or_else(|| current_draft.into());
        self.edit_session = Some(EditSession { message_id: id, previous_draft: previous });
        Some(text)
    }

    /// Stopt met bewerken en geeft het concept terug voor het invoerveld. Met `save` krijgt het bericht `text`; een
    /// bericht dat intussen weg is, komt niet terug.
    pub fn end_edit(&mut self, save: bool, text: &str) -> Option<String> {
        let session = self.edit_session.take()?;
        if save {
            self.edit(session.message_id, text);
        }
        Some(session.previous_draft)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue(texts: &[&str]) -> MessageQueue {
        let mut q = MessageQueue::default();
        for t in texts {
            q.enqueue(t);
        }
        q
    }

    #[test]
    fn enqueue_trims_ignores_empty_and_caps() {
        let mut q = MessageQueue::default();
        assert!(q.enqueue("   \n").is_none());
        assert_eq!(q.enqueue("  hi ").unwrap().text, "hi");
        for i in 0..60 {
            q.enqueue(&format!("m{i}"));
        }
        assert_eq!(q.len(), MessageQueue::LIMIT);
        assert!(q.enqueue("one more").is_none());
    }

    #[test]
    fn edit_remove_requeue_move_promote() {
        let mut q = queue(&["a"]);
        let id = q.messages[0].id;
        assert!(q.edit(id, "a"));
        assert!(!q.messages[0].edited);
        assert!(q.edit(id, " b "));
        assert!(q.messages[0].edited);
        assert!(!q.edit(id, " "));
        assert!(!q.edit(Uuid::new_v4(), "x"));

        let mut q = queue(&["a", "b"]);
        let id = q.messages[0].id;
        assert!(q.remove(id));
        assert!(!q.remove(id));

        let mut q = queue(&["a"]);
        q.requeue_first(" back ");
        q.requeue_first("  ");
        assert_eq!(q.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), vec!["back", "a"]);

        let mut q = queue(&["a", "b", "c"]);
        let a = q.messages[0].id;
        assert!(q.move_to(a, 99));
        assert_eq!(q.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), vec!["b", "c", "a"]);
        assert!(q.move_to(a, -5));
        assert!(!q.move_to(Uuid::new_v4(), 0));

        let mut q = queue(&["a", "b"]);
        let id = q.messages[1].id;
        assert_eq!(q.promote_to_steer(id).as_deref(), Some("b"));
        assert!(q.promote_to_steer(id).is_none());
    }

    #[test]
    fn held_queue_sends_nothing_until_resumed() {
        let mut q = queue(&["a", "b"]);
        q.hold();
        assert!(q.next(false).is_none());
        q.resume();
        assert_eq!(q.next(false).unwrap().text, "a");
        assert!(q.next(true).is_none());
        assert_eq!(q.next(false).unwrap().text, "b");
        assert!(q.next(false).is_none());
    }

    #[test]
    fn edit_sessions() {
        let mut q = queue(&["a", "b"]);
        let id = q.messages[0].id;
        assert_eq!(q.begin_edit(id, "my draft").as_deref(), Some("a"));
        assert_eq!(q.next(false).unwrap().text, "b");
        assert_eq!(q.end_edit(true, "a2").as_deref(), Some("my draft"));
        assert_eq!(q.messages[0].text, "a2");
        assert!(q.end_edit(false, "").is_none());

        let mut q = queue(&["a", "b"]);
        let (a, b) = (q.messages[0].id, q.messages[1].id);
        q.begin_edit(a, "draft");
        q.begin_edit(b, "a");
        assert_eq!(q.end_edit(false, "").as_deref(), Some("draft"));
        assert!(q.begin_edit(Uuid::new_v4(), "x").is_none());

        let mut q = queue(&["a"]);
        let id = q.messages[0].id;
        q.begin_edit(id, "d");
        q.remove(id);
        assert!(q.end_edit(true, "x").is_none());
        assert!(q.is_empty());
    }

    #[test]
    fn serde_tolerates_missing_and_unknown_fields() {
        let mut q = queue(&["a"]);
        q.hold();
        let back: MessageQueue = serde_json::from_str(&serde_json::to_string(&q).unwrap()).unwrap();
        assert_eq!(back.messages, q.messages);
        assert!(back.is_held());
        let old: MessageQueue = serde_json::from_str(r#"{"messages":[{"text":"x","future":1}],"other":true}"#).unwrap();
        assert_eq!(old.messages[0].text, "x");
        assert!(!old.is_held());
        assert!(serde_json::from_str::<MessageQueue>("{}").unwrap().is_empty());
    }
}
