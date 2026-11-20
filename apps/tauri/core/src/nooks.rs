//! Nooks: elk gesprek is een eigen Nook die aan één ding werkt. Bewaard in `nooks.json`, net als op de Mac.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::brain::chart::ChatChart;
pub use crate::brain::retrieval::{Outcome, RetrievalStep, SourceReference};
use crate::brain::sources::{self, SourceScope};
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
    /// Voorgesteld; de gebruiker heeft nog niet besloten.
    Pending,
    /// De gebruiker klikte Uitvoeren; wacht op zijn beurt.
    Approved,
    Running,
    /// De dienst meldde succes.
    Done(String),
    /// Gelukt, en Nook las het resultaat terug bij de dienst.
    Verified(String),
    Failed(String),
    /// Niet aan toe gekomen omdat een eerdere stap mislukte.
    NotRun,
    /// Uitgezet door de gebruiker.
    Skipped,
    /// Niet herhaald: al eerder uitgevoerd.
    Duplicate(String),
}

impl StepState {
    pub fn is_finished(&self) -> bool {
        matches!(self, Self::Done(_) | Self::Verified(_) | Self::Skipped | Self::Duplicate(_))
    }

    /// De uitkomst van een gelukte stap.
    pub fn result(&self) -> Option<&str> {
        match self {
            Self::Done(r) | Self::Verified(r) => Some(r),
            _ => None,
        }
    }

    /// Of deze stap (nog eens) mag draaien.
    pub fn can_run(&self) -> bool {
        matches!(self, Self::Pending | Self::Approved | Self::Failed(_) | Self::NotRun)
    }
}

/// Een mailconcept in de chat: aan te passen, en pas weg na een klik op Versturen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailDraft {
    pub id: String,
    pub to: String,
    #[serde(default)]
    pub cc: String,
    /// Blind copy recipients; empty in drafts stored before Bcc existed.
    #[serde(default)]
    pub bcc: String,
    pub subject: String,
    pub body: String,
    /// Paths on disk attached to this draft (such as `invite.ics`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<String>,
    /// A calendar invitation attached as `invite.ics`; rewritten if To/Cc changes before sending.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invite: Option<crate::brain::calendar_invite::CalendarInviteEvent>,
    /// draft, sending, sent, opened of failed.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub error: String,
}

impl MailDraft {
    pub fn new(to: &str, cc: &str, subject: &str, body: &str) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            to: to.into(),
            cc: cc.into(),
            bcc: String::new(),
            subject: subject.into(),
            body: body.into(),
            attachments: Vec::new(),
            invite: None,
            state: "draft".into(),
            error: String::new(),
        }
    }
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
    /// Context zonder tools: een bijlage of de schermtekst.
    pub sources: Vec<String>,
    /// Wat Nook voor dit antwoord raadpleegde, met de uitkomst per bron.
    pub retrieval: Vec<RetrievalStep>,
    pub references: Vec<SourceReference>,
    /// Bronnen waarvan de samenvatting volledig meeging.
    pub context_sources: Vec<String>,
    /// De toegestane bronnen als de gebruiker ze beperkte ("Alleen Agenda en Mail").
    pub scope_label: String,
    pub notices: Vec<String>,
    /// The filtered note this answer was written from (`brain::private_brief`): exactly what left this computer of
    /// what stays on it.
    pub private_brief: String,
    pub charts: Vec<ChatChart>,
    /// The plan Nook works through (`update_plan`), shown as a checklist above the answer.
    pub tasks: Vec<crate::brain::task_steps::TaskStep>,
    pub mails: Vec<MailDraft>,
    pub actions: Vec<PlannedAction>,
    pub plan_state: Option<PlanState>,
    pub action_states: Vec<StepState>,
    pub action_included: Vec<bool>,
    pub action_problems: Vec<Vec<String>>,
    /// Vervolgvoorstellen als knoppen onder het antwoord.
    pub offers: Vec<String>,
    /// De knop die een fout oplost ("Kies een model", "Hoe start ik Ollama?").
    pub recovery: Option<serde_json::Value>,
    /// De bijlage bij een vraag (bestandsnaam).
    pub attachment: Option<String>,
    /// A question an automation asked (a scheduled run), shown as a quiet marker instead of a bubble the user typed.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub scheduled: bool,
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
            context_sources: vec![],
            scope_label: String::new(),
            notices: vec![],
            private_brief: String::new(),
            charts: vec![],
            tasks: vec![],
            mails: vec![],
            actions: vec![],
            plan_state: None,
            action_states: vec![],
            action_included: vec![],
            action_problems: vec![],
            offers: vec![],
            recovery: None,
            attachment: None,
            scheduled: false,
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

    /// Of dit antwoord met een van deze bronnen gemaakt is (opgezocht, geciteerd of in de context).
    pub fn used(&self, ids: &std::collections::BTreeSet<String>) -> bool {
        if self.retrieval.iter().any(|s| s.source_id.as_ref().is_some_and(|id| ids.contains(id))) {
            return true;
        }
        if self.references.iter().any(|r| ids.contains(&r.source_id)) {
            return true;
        }
        let titles: std::collections::HashSet<String> = ids.iter().map(|id| sources::title(id)).collect();
        if self.context_sources.iter().any(|c| titles.contains(c)) {
            return true;
        }
        ids.contains(sources::SCREEN) && !self.sources.is_empty()
    }

    /// Wat het brein bij een vervolgvraag van deze beurt te zien krijgt, inclusief wat er met een plan gebeurde.
    pub fn history_text(&self) -> String {
        let mut parts = vec![];
        if !self.text.is_empty() {
            parts.push(self.text.clone());
        }
        for chart in &self.charts {
            parts.push(format!("[chart displayed: {}]", chart.title));
        }
        for mail in &self.mails {
            let state = match mail.state.as_str() {
                "sent" => "sent",
                "opened" => "opened in the mail app",
                _ => "not yet sent",
            };
            parts.push(format!(
                "[draft email to {}, subject \"{}\", {state}]",
                if mail.to.is_empty() { "?" } else { &mail.to },
                mail.subject
            ));
        }
        if !self.retrieval.is_empty() {
            let searched: Vec<String> = self
                .retrieval
                .iter()
                .map(|s| match &s.outcome {
                    Outcome::Failed(e) => format!("{} (error: {e})", s.source_title),
                    Outcome::Empty => format!("{} (nothing found)", s.source_title),
                    _ if s.query.is_empty() => s.source_title.clone(),
                    _ => format!("{} \"{}\"", s.source_title, s.query),
                })
                .collect();
            parts.push(format!("[searched: {}]", searched.join(", ")));
        }
        if !self.references.is_empty() {
            let list: Vec<String> = self
                .references
                .iter()
                .take(8)
                .map(|r| {
                    format!("[{}] {}{}", r.number, r.title, if r.detail.is_empty() { String::new() } else { format!(" — {}", r.detail) })
                })
                .collect();
            parts.push(format!("[sources for this reply: {}]", list.join("; ")));
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
                        Some(StepState::Done(r)) | Some(StepState::Verified(r)) => format!("completed: {r}"),
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
    /// Welke bronnen dit gesprek mag gebruiken (de bronkiezer naast het invoerveld).
    #[serde(default)]
    pub scope: Option<SourceScope>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub archived: bool,
    /// Questions waiting for the answer that is being written (`NookChat.enqueue` on the Mac).
    #[serde(default, skip_serializing_if = "crate::brain::queue::MessageQueue::is_empty")]
    pub queue: crate::brain::queue::MessageQueue,
    /// The automation whose run this conversation is (a scheduled task for Nook Chat), for the "Scheduled run" marker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_task: Option<String>,
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
            queue: Default::default(),
            scheduled_task: None,
        }
    }

    pub fn status(&self) -> ConversationStatus {
        if self.busy {
            return ConversationStatus::Working;
        }
        // Only what Nook proposed since your last message: a plan or draft you moved past no longer waits for you.
        let since = self.messages.iter().rposition(|m| m.from_user).map_or(0, |i| i + 1);
        let waiting = self.messages[since..].iter().any(|m| {
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
        self.history_hiding(limit, &Default::default())
    }

    /// Zonder de antwoorden die met een verborgen bron gemaakt zijn, en de vraag ervoor: een extern brein krijgt die niet.
    pub fn history_hiding(&self, limit: usize, hidden: &std::collections::BTreeSet<String>) -> Vec<ChatTurn> {
        let turns: Vec<ChatTurn> =
            self.turns_hiding(hidden).into_iter().map(|t| ChatTurn { text: t.text.chars().take(4_000).collect(), ..t }).collect();
        let start = turns.len().saturating_sub(limit);
        turns[start..].to_vec()
    }

    /// What goes to the brain with a new question: the whole conversation (hidden answers left out) fitted to `limits`,
    /// newest turns in full, older ones shortened, the rest folded into a recap (`conversation_window`).
    pub fn window_hiding(
        &self,
        limits: &crate::brain::conversation_window::Limits,
        hidden: &std::collections::BTreeSet<String>,
    ) -> Vec<ChatTurn> {
        crate::brain::conversation_window::fit(&self.turns_hiding(hidden), limits)
    }

    fn turns_hiding(&self, hidden: &std::collections::BTreeSet<String>) -> Vec<ChatTurn> {
        let mut kept: Vec<&ChatMessage> = vec![];
        for message in &self.messages {
            if !hidden.is_empty() && !message.from_user && message.used(hidden) {
                if kept.last().is_some_and(|m| m.from_user) {
                    kept.pop();
                }
                continue;
            }
            kept.push(message);
        }
        kept.into_iter()
            .filter(|m| !m.is_error && !m.streaming)
            .map(|m| ChatTurn { from_user: m.from_user, text: m.history_text() })
            .filter(|t| !t.text.trim().is_empty())
            .collect()
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
    /// The automation whose run this conversation is.
    pub scheduled_task: Option<String>,
    /// What the list's hover card says of it (`NookHoverCard` on the Mac).
    pub card: ConversationCard,
}

/// What a Nook did, for the hover card in the list: its plan, a mail draft, a chart, the sources it searched, the
/// question it started with, its last answer in short, and when it started.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationCard {
    pub created: DateTime<Utc>,
    pub messages: usize,
    /// The latest plan's steps done and in all; 0 of 0 without a plan.
    pub tasks_done: usize,
    pub tasks_total: usize,
    /// The step working now, else the last one done.
    pub task: Option<String>,
    pub task_active: bool,
    /// The last mail draft's addressee ("" for a draft without one); None without a draft.
    pub mail_to: Option<String>,
    /// The last chart's title ("" for one without); None without a chart.
    pub chart: Option<String>,
    /// Up to three sources it searched, by name.
    pub sources: Vec<String>,
    /// The first question, on one line, when it says more than the title.
    pub request: String,
    /// The last answer, on one line, up to 200 characters.
    pub summary: String,
    /// The sources it may use when you limited them ("Only Calendar and Mail").
    pub scope: Option<String>,
}

impl Conversation {
    /// The hover card's lines for this conversation.
    pub fn card(&self) -> ConversationCard {
        use crate::brain::task_steps::StepStatus;
        let one_line = |text: &str| text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ");
        let clip = |text: String, n: usize| if text.chars().count() > n { format!("{}…", text.chars().take(n - 1).collect::<String>()) } else { text };
        let tasks = self.messages.iter().rev().find(|m| !m.tasks.is_empty()).map(|m| m.tasks.as_slice()).unwrap_or(&[]);
        let active = tasks.iter().find(|t| t.status == StepStatus::Active);
        let done = tasks.iter().rev().find(|t| t.status == StepStatus::Done);
        let mut sources: Vec<String> = vec![];
        for step in self.messages.iter().flat_map(|m| m.retrieval.iter()) {
            if !step.source_title.is_empty() && !sources.contains(&step.source_title) {
                sources.push(step.source_title.clone());
            }
        }
        sources.truncate(3);
        let request = self.messages.iter().find(|m| m.from_user).map(|m| one_line(&m.text)).filter(|r| !r.is_empty() && *r != self.title).unwrap_or_default();
        let summary = self
            .messages
            .iter()
            .rev()
            .find(|m| !m.from_user && !m.text.is_empty())
            .map(|m| m.text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')).collect::<Vec<_>>().join(" "))
            .map(|t| t.chars().filter(|c| !"#*_`>|".contains(*c)).collect::<String>().trim().to_string())
            .unwrap_or_default();
        ConversationCard {
            created: self.created,
            messages: self.messages.len(),
            tasks_done: tasks.iter().filter(|t| t.status == StepStatus::Done).count(),
            tasks_total: tasks.len(),
            task: active.or(done).map(|t| t.text.clone()),
            task_active: active.is_some(),
            mail_to: self.messages.iter().flat_map(|m| m.mails.iter()).last().map(|d| d.to.trim().to_string()),
            chart: self.messages.iter().flat_map(|m| m.charts.iter()).last().map(|c| c.title.clone()),
            sources,
            request: clip(request, 120),
            summary: clip(summary, 200),
            scope: self.scope.as_ref().filter(|s| s.is_restricted()).map(|s| s.label()),
        }
    }
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
                m.tasks = crate::brain::task_steps::settled(&m.tasks);
            }
        }
        chat.active_id = stored.active.filter(|id| chat.conversations.iter().any(|c| &c.id == id));
        chat
    }

    pub fn save(&self) -> std::io::Result<()> {
        let Some(file) = &self.file else { return Ok(()) };
        paths::write_atomic(file, &self.encoded()?)
    }

    /// What `save` writes, serialized straight from the conversations: going through `json!` would first copy every
    /// conversation, attached images included, into a `Value`.
    fn encoded(&self) -> std::io::Result<Vec<u8>> {
        #[derive(Serialize)]
        struct Stored<'a> {
            version: u8,
            active: &'a Option<String>,
            conversations: Vec<&'a Conversation>,
        }
        let stored = Stored {
            version: 2,
            active: &self.active_id,
            conversations: self.conversations.iter().filter(|c| !c.messages.is_empty()).collect(),
        };
        serde_json::to_vec(&stored).map_err(std::io::Error::other)
    }

    /// The file and its contents, so the caller can write it after releasing the lock around the chat.
    pub fn snapshot(&self) -> Option<(std::path::PathBuf, std::io::Result<Vec<u8>>)> {
        self.file.clone().map(|file| (file, self.encoded()))
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
                scheduled_task: c.scheduled_task.clone(),
                card: c.card(),
            })
            .collect()
    }

    /// The conversation of an automation's latest run, archived ones included; `None` before its first run.
    pub fn latest_run(&self, task: &str) -> Option<&Conversation> {
        self.conversations.iter().filter(|c| c.scheduled_task.as_deref() == Some(task)).max_by_key(|c| c.created)
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
        c.messages[0].plan_state = None;
        c.messages.push(ChatMessage::user("laat maar, iets anders"));
        assert_eq!(c.status(), ConversationStatus::Idle, "a plan you moved past no longer waits");
    }

    #[test]
    fn an_automation_finds_its_latest_run_and_the_list_says_whose_run_it_is() {
        let mut chat = NookChat::default();
        for minutes in [1, 3, 2] {
            let mut c = Conversation::new();
            c.created = Utc::now() + chrono::Duration::minutes(minutes);
            c.scheduled_task = Some("task".into());
            c.title = format!("run {minutes}");
            let mut question = ChatMessage::user("Anything new?");
            question.scheduled = true;
            c.messages.push(question);
            chat.conversations.push(c);
        }
        chat.conversations.push(Conversation::new());
        assert_eq!(chat.latest_run("task").unwrap().title, "run 3");
        assert!(chat.latest_run("other").is_none());
        let list = chat.list(false);
        assert_eq!(list.iter().filter(|s| s.scheduled_task.as_deref() == Some("task")).count(), 3);
        let json = serde_json::to_value(&chat.conversations[0].messages[0]).unwrap();
        assert_eq!(json["scheduled"], true);
        assert!(serde_json::to_value(ChatMessage::user("x")).unwrap().get("scheduled").is_none());
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
