//! Nooks: elk gesprek is een eigen Nook die aan één ding werkt. Bewaard in `nooks.json`, net als op de Mac.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::brain::{ChatTurn, PlannedAction};
use crate::paths;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum PlanState {
    Pending,
    Running,
    Done(String),
    Cancelled,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum StepState {
    Pending,
    Running,
    Done(String),
    Failed(String),
    Skipped,
    /// Niet herhaald: al eerder uitgevoerd.
    Duplicate(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailDraft {
    pub id: String,
    pub to: String,
    #[serde(default)]
    pub cc: String,
    pub subject: String,
    pub body: String,
    #[serde(default)]
    pub state: String,
}

/// Een genummerde bron onder een antwoord ([1], [2]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceReference {
    pub number: u32,
    pub title: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub url: Option<String>,
}

/// Per bron: doorzocht, niets gevonden of mislukt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetrievalStep {
    pub source: String,
    pub source_title: String,
    pub outcome: String,
    #[serde(default)]
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatMessage {
    pub id: String,
    pub from_user: bool,
    pub text: String,
    pub date: DateTime<Utc>,
    pub is_error: bool,
    pub streaming: bool,
    pub status: String,
    pub images: Vec<String>,
    pub sources: Vec<String>,
    pub retrieval: Vec<RetrievalStep>,
    pub references: Vec<SourceReference>,
    pub notices: Vec<String>,
    /// Grafieken als JSON (zelfde vorm als `ChatChart` op de Mac).
    pub charts: Vec<Value>,
    pub mails: Vec<MailDraft>,
    pub actions: Vec<PlannedAction>,
    pub plan_state: Option<PlanState>,
    pub action_states: Vec<StepState>,
    pub action_included: Vec<bool>,
    pub action_problems: Vec<Vec<String>>,
    /// Vervolgvoorstellen als knoppen onder het antwoord.
    pub offers: Vec<String>,
}

impl Default for ChatMessage {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            from_user: false,
            text: String::new(),
            date: Utc::now(),
            is_error: false,
            streaming: false,
            status: String::new(),
            images: vec![],
            sources: vec![],
            retrieval: vec![],
            references: vec![],
            notices: vec![],
            charts: vec![],
            mails: vec![],
            actions: vec![],
            plan_state: None,
            action_states: vec![],
            action_included: vec![],
            action_problems: vec![],
            offers: vec![],
        }
    }
}

impl ChatMessage {
    pub fn user(text: &str) -> Self {
        Self { from_user: true, text: text.into(), ..Default::default() }
    }

    pub fn nook(text: &str) -> Self {
        Self { text: text.into(), ..Default::default() }
    }

    /// Wat het brein bij een vervolgvraag van deze beurt te zien krijgt, inclusief wat er met een plan gebeurde.
    pub fn history_text(&self) -> String {
        let mut parts = vec![self.text.clone()];
        if !self.references.is_empty() {
            let list: Vec<String> = self.references.iter().take(8).map(|r| format!("[{}] {}", r.number, r.title)).collect();
            parts.push(format!("Sources: {}", list.join("; ")));
        }
        if !self.actions.is_empty() {
            let state = match &self.plan_state {
                Some(PlanState::Done(_)) => "executed",
                Some(PlanState::Cancelled) => "cancelled by the user",
                Some(PlanState::Failed(_)) => "partially failed",
                Some(PlanState::Running) => "running",
                _ => "proposed, waiting for the user",
            };
            let steps: Vec<String> = self
                .actions
                .iter()
                .enumerate()
                .map(|(i, a)| {
                    let outcome = match self.action_states.get(i) {
                        Some(StepState::Done(r)) => format!("completed: {r}"),
                        Some(StepState::Failed(e)) => format!("failed: {e}"),
                        Some(StepState::Skipped) => "skipped".into(),
                        Some(StepState::Duplicate(w)) => format!("not repeated, already executed on {w}"),
                        _ => "not executed".into(),
                    };
                    format!("{}. {} {} — {outcome}", i + 1, a.tool, a.input)
                })
                .collect();
            parts.push(format!("Plan ({state}):\n{}", steps.join("\n")));
        }
        parts.join("\n\n")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConversationStatus {
    Working,
    Waiting,
    Unread,
    Idle,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub created: DateTime<Utc>,
    pub updated: DateTime<Utc>,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    #[serde(default, skip_serializing)]
    pub busy: bool,
    #[serde(default)]
    pub unread: bool,
    /// Welke bronnen dit gesprek mag gebruiken ("automatic" of een lijst).
    #[serde(default)]
    pub scope: Option<Vec<String>>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub archived: bool,
}

impl Conversation {
    pub fn new() -> Self {
        let now = Utc::now();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: "Nieuwe Nook".into(),
            created: now,
            updated: now,
            messages: vec![],
            busy: false,
            unread: false,
            scope: None,
            pinned: false,
            archived: false,
        }
    }

    pub fn status(&self) -> ConversationStatus {
        if self.busy {
            return ConversationStatus::Working;
        }
        let waiting = self.messages.iter().any(|m| {
            (!m.actions.is_empty() && matches!(m.plan_state, None | Some(PlanState::Pending)))
                || m.mails.iter().any(|d| d.state.is_empty() || d.state == "draft")
        });
        if waiting {
            ConversationStatus::Waiting
        } else if self.unread {
            ConversationStatus::Unread
        } else {
            ConversationStatus::Idle
        }
    }

    /// Eén regel: het laatste antwoord van Nook zonder Markdown-tekens.
    pub fn preview(&self) -> String {
        let Some(last) = self.messages.iter().rev().find(|m| !m.from_user && !m.text.is_empty()) else { return String::new() };
        let sample: String = last.text.chars().take(240).collect::<String>().replace('\n', " ");
        let cleaned: String = sample.chars().filter(|c| !"#*_`>|".contains(*c)).collect();
        cleaned.trim().chars().take(80).collect()
    }

    /// Een korte titel uit de eerste vraag.
    pub fn title_from(question: &str) -> String {
        let text = question.replace('\n', " ");
        let text = text.trim().trim_matches(|c| "?!. ".contains(c));
        let capitalize = |s: &str| {
            let mut chars = s.chars();
            chars.next().map(|f| f.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
        };
        if text.chars().count() <= 40 {
            return capitalize(text);
        }
        let cut: String = text.chars().take(40).collect();
        let short = cut.rfind(' ').map(|i| cut[..i].to_string()).unwrap_or(cut);
        format!("{}…", capitalize(&short))
    }

    /// De beurten die als geschiedenis met een nieuwe vraag meegaan (zonder fouten en lege berichten).
    pub fn history(&self, limit: usize) -> Vec<ChatTurn> {
        let turns: Vec<ChatTurn> = self
            .messages
            .iter()
            .filter(|m| !m.is_error && !m.streaming && !m.text.trim().is_empty())
            .map(|m| ChatTurn { from_user: m.from_user, text: m.history_text() })
            .collect();
        let start = turns.len().saturating_sub(limit);
        turns[start..].to_vec()
    }
}

impl Default for Conversation {
    fn default() -> Self {
        Self::new()
    }
}

/// Lichte samenvatting voor de lijst links.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSummary {
    pub id: String,
    pub title: String,
    pub updated: DateTime<Utc>,
    pub status: ConversationStatus,
    pub preview: String,
    pub pinned: bool,
    pub archived: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredChats {
    #[serde(default)]
    version: Option<u32>,
    #[serde(default)]
    active: Option<String>,
    #[serde(default)]
    conversations: Vec<Value>,
}

/// Alle Nooks, lokaal bewaard.
#[derive(Debug, Default)]
pub struct NookChat {
    pub conversations: Vec<Conversation>,
    pub active_id: Option<String>,
    file: Option<std::path::PathBuf>,
}

/// Hoeveel berichten een Nook bewaart en hoeveel Nooks actief blijven voor ze naar het archief gaan.
pub const MAX_MESSAGES: usize = 80;
pub const MAX_ACTIVE: usize = 60;
pub const MAX_TOTAL: usize = 300;

impl NookChat {
    pub fn load() -> Self {
        Self::load_from(paths::nooks_file())
    }

    /// Gesprek voor gesprek; een onleesbaar bestand wordt apart gezet, zodat de volgende keer opslaan nooit je geschiedenis wist.
    pub fn load_from(file: std::path::PathBuf) -> Self {
        let mut chat = Self { file: Some(file.clone()), ..Default::default() };
        let Ok(bytes) = std::fs::read(&file) else { return chat };
        let stored: StoredChats = match serde_json::from_slice(&bytes) {
            Ok(s) => s,
            Err(_) => {
                let _ = std::fs::copy(&file, file.with_extension("unreadable.json"));
                return chat;
            }
        };
        let total = stored.conversations.len();
        chat.conversations = stored.conversations.into_iter().filter_map(|v| serde_json::from_value::<Conversation>(v).ok()).collect();
        if chat.conversations.len() < total {
            let _ = std::fs::copy(&file, file.with_extension("backup.json"));
        }
        chat.conversations.retain(|c| !c.messages.is_empty());
        for c in &mut chat.conversations {
            for m in &mut c.messages {
                m.streaming = false;
            }
        }
        chat.active_id = stored.active.filter(|id| chat.conversations.iter().any(|c| &c.id == id));
        chat
    }

    pub fn save(&self) -> std::io::Result<()> {
        let Some(file) = &self.file else { return Ok(()) };
        let stored = serde_json::json!({
            "version": 2,
            "active": self.active_id,
            "conversations": self.conversations.iter().filter(|c| !c.messages.is_empty()).collect::<Vec<_>>(),
        });
        paths::write_atomic(file, &serde_json::to_vec(&stored).map_err(std::io::Error::other)?)
    }

    pub fn get(&self, id: &str) -> Option<&Conversation> {
        self.conversations.iter().find(|c| c.id == id)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut Conversation> {
        self.conversations.iter_mut().find(|c| c.id == id)
    }

    /// De actieve Nook, of een nieuwe als er geen is.
    pub fn active_or_new(&mut self) -> String {
        if let Some(id) = self.active_id.clone().filter(|id| self.get(id).is_some()) {
            return id;
        }
        self.new_conversation()
    }

    /// Een lege Nook wordt hergebruikt; anders komt er een nieuwe bovenaan.
    pub fn new_conversation(&mut self) -> String {
        if let Some(empty) = self.conversations.iter().find(|c| c.messages.is_empty()) {
            let id = empty.id.clone();
            self.active_id = Some(id.clone());
            return id;
        }
        let c = Conversation::new();
        let id = c.id.clone();
        self.conversations.insert(0, c);
        self.active_id = Some(id.clone());
        id
    }

    pub fn remove(&mut self, id: &str) {
        self.conversations.retain(|c| c.id != id);
        if self.active_id.as_deref() == Some(id) {
            self.active_id = self.list(false).first().map(|c| c.id.clone());
        }
    }

    pub fn push(&mut self, id: &str, message: ChatMessage) {
        if let Some(c) = self.get_mut(id) {
            if c.messages.is_empty() && message.from_user {
                c.title = Conversation::title_from(&message.text);
            }
            c.messages.push(message);
            c.updated = Utc::now();
            if c.messages.len() > MAX_MESSAGES {
                let drop = c.messages.len() - MAX_MESSAGES;
                c.messages.drain(..drop);
            }
        }
        self.trim();
    }

    /// Te veel Nooks: de oudste gaan naar het archief (nog doorzoekbaar); alleen een heel oud archief wordt gewist.
    fn trim(&mut self) {
        let mut active: Vec<&mut Conversation> = self.conversations.iter_mut().filter(|c| !c.archived && !c.pinned).collect();
        active.sort_by_key(|c| std::cmp::Reverse(c.updated));
        for c in active.into_iter().skip(MAX_ACTIVE) {
            c.archived = true;
        }
        if self.conversations.len() > MAX_TOTAL {
            self.conversations.sort_by_key(|c| std::cmp::Reverse(c.updated));
            self.conversations.truncate(MAX_TOTAL);
        }
    }

    /// Vastgezet bovenaan, daarna nieuwste eerst.
    pub fn list(&self, archived: bool) -> Vec<ConversationSummary> {
        let mut list: Vec<&Conversation> = self.conversations.iter().filter(|c| c.archived == archived).collect();
        list.sort_by(|a, b| b.pinned.cmp(&a.pinned).then(b.updated.cmp(&a.updated)));
        list.into_iter()
            .map(|c| ConversationSummary {
                id: c.id.clone(),
                title: c.title.clone(),
                updated: c.updated,
                status: c.status(),
                preview: c.preview(),
                pinned: c.pinned,
                archived: c.archived,
            })
            .collect()
    }

    /// Zoeken in titels en berichten, ook in het archief.
    pub fn search(&self, query: &str) -> Vec<ConversationSummary> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return self.list(false);
        }
        let mut all = self.list(false);
        all.extend(self.list(true));
        all.into_iter()
            .filter(|s| {
                self.get(&s.id)
                    .is_some_and(|c| c.title.to_lowercase().contains(&q) || c.messages.iter().any(|m| m.text.to_lowercase().contains(&q)))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_are_short() {
        assert_eq!(Conversation::title_from("wat staat er morgen?"), "Wat staat er morgen");
        let long = Conversation::title_from("schrijf een mail aan Lisa dat ik vandaag wat later ben omdat de trein uitvalt");
        assert!(long.ends_with('…') && long.chars().count() <= 41);
    }

    #[test]
    fn status_waits_on_pending_plans() {
        let mut c = Conversation::new();
        let mut m = ChatMessage::nook("plan");
        m.actions.push(PlannedAction::new("create_event", serde_json::json!({})));
        c.messages.push(m);
        assert_eq!(c.status(), ConversationStatus::Waiting);
        c.messages[0].plan_state = Some(PlanState::Done("ok".into()));
        assert_eq!(c.status(), ConversationStatus::Idle);
    }

    #[test]
    fn saves_and_loads() {
        let dir = std::env::temp_dir().join(format!("nook-chat-{}", uuid::Uuid::new_v4()));
        let file = dir.join("nooks.json");
        let mut chat = NookChat::load_from(file.clone());
        let id = chat.new_conversation();
        chat.push(&id, ChatMessage::user("hoi Nook"));
        chat.push(&id, ChatMessage::nook("Hoi! **Wat** kan ik doen?"));
        chat.save().unwrap();
        let again = NookChat::load_from(file);
        assert_eq!(again.active_id.as_deref(), Some(id.as_str()));
        assert_eq!(again.list(false)[0].preview, "Hoi! Wat kan ik doen?");
        assert_eq!(again.get(&id).unwrap().history(10).len(), 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn empty_nooks_are_reused() {
        let mut chat = NookChat::default();
        let a = chat.new_conversation();
        assert_eq!(chat.new_conversation(), a);
    }
}
