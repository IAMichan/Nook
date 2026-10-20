//! De agent-hub (`AgentHub` op de Mac): volgt lopende agents aan de hand van hun hooks en brengt hun vragen naar de
//! balk: toestemming (alleen als de agent het de gebruiker anders zelf zou vragen) en meerkeuzevragen
//! (AskUserQuestion). Beantwoord je in de terminal, dan verdwijnt de kaart meteen.
//!
//! De hub zelf is zonder netwerk of vensters: [`AgentHub::handle`] krijgt één bericht van het hook-script en een
//! [`Responder`] om (één keer) te antwoorden; de verbinding (zie `ipc`) wacht daarna op dat antwoord, op het sluiten
//! door de agent ([`AgentHub::peer_closed`]) of op de tijdslimiet ([`AgentHub::expire`]).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::line_diff::{self, DiffLine};
use super::liveness;
use super::mcp_name::{self, McpToolName};
use super::models::*;
use super::risk::{self, CommandAssessment, RiskLevel};
use super::scanner::DetectedAgent;
use super::text::{one_line, project_name, short_path, shorten};
use crate::services::recap::RecapSink;

/// Na zoveel seconden zonder antwoord vraagt de agent het zelf (de hook-limiet is 120 s).
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(110);
pub const QUESTION_TIMEOUT: Duration = Duration::from_secs(120);

/// Antwoordt één keer op een verbinding van het hook-script. `None` = niets terugsturen (de agent gaat gewoon door).
pub struct Responder(Option<tokio::sync::oneshot::Sender<Option<String>>>);

impl Responder {
    pub fn new() -> (Self, tokio::sync::oneshot::Receiver<Option<String>>) {
        let (tx, rx) = tokio::sync::oneshot::channel();
        (Self(Some(tx)), rx)
    }

    /// Voor tests en voor berichten die nergens op wachten.
    pub fn none() -> Self {
        Self(None)
    }

    pub fn reply(&mut self, response: Option<String>) -> bool {
        match self.0.take() {
            Some(tx) => tx.send(response).is_ok(),
            None => false,
        }
    }
}

/// Waar een verbinding na [`AgentHub::handle`] op wacht.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wait {
    /// Er is al geantwoord.
    Done,
    Approval(String, Duration),
    Question(String, Duration),
}

/// Wat de interface moet weten.
#[derive(Debug, Clone)]
#[allow(clippy::large_enum_variant)] // Zeldzame events; een Box maakt de code alleen omslachtiger.
pub enum HubEvent {
    Changed,
    Approval(ApprovalRequest),
    /// Afgehandeld (hier of elders) of verlopen; met een bevestiging als het in Nook beantwoord is.
    ApprovalGone(String, Option<String>),
    Question(QuestionRequest),
    QuestionGone(String, Option<String>),
    /// Klaar, mislukt of wacht op je: een kaartje in de balk.
    Attention(AgentSession),
    PlanUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    agent_id: String,
    agent: String,
    project: String,
    cwd: String,
    status: AgentStatus,
    steps: Vec<AgentStep>,
    file: String,
    last_message: String,
    updated: DateTime<Utc>,
    host: String,
    home: String,
    #[serde(skip)]
    diff: Vec<DiffLine>,
    lines_added: usize,
    lines_removed: usize,
    session_id: String,
    transcript_path: String,
    last_prompt: String,
    started: DateTime<Utc>,
    /// The processes the latest hook came from, nearest first (see `hook::messages`).
    #[serde(default)]
    lineage: Vec<u32>,
    /// The agent process among them, once the process scan has seen it.
    #[serde(default)]
    pid: Option<u32>,
}

#[derive(Serialize, Deserialize)]
struct SavedRecord {
    key: String,
    #[serde(flatten)]
    record: Record,
}

enum PendingKind {
    Permission { suggestions: Option<Value>, can_always: bool },
    LegacyPreToolUse,
}

struct PendingApproval {
    request: ApprovalRequest,
    responder: Responder,
    kind: PendingKind,
}

struct PendingQuestion {
    request: QuestionRequest,
    responder: Responder,
    raw_questions: Value,
}

#[derive(Default)]
struct State {
    records: HashMap<String, Record>,
    approvals: Vec<ApprovalRequest>,
    pending_approvals: HashMap<String, PendingApproval>,
    pending_questions: HashMap<String, PendingQuestion>,
    sessions: Vec<AgentSession>,
    detected: Vec<AgentSession>,
    processes: Vec<DetectedAgent>,
    plan_usage: Option<PlanUsage>,
    profile_plan_usage: BTreeMap<String, PlanUsage>,
    unconfirmed: HashSet<String>,
    /// Scans in a row each busy session's process was missing from the process list.
    missing_scans: HashMap<String, usize>,
    dirty: bool,
}

type Notify = Box<dyn Fn(HubEvent) + Send + Sync>;

pub struct AgentHub {
    state: Mutex<State>,
    notify: Notify,
    records_file: Option<PathBuf>,
    usage_file: Option<PathBuf>,
    launched_at: DateTime<Utc>,
    /// De standaardmappen van Claude Code en Codex, om een accountmap als "standaard" te herkennen.
    default_homes: (String, String),
    /// Het weekoverzicht: prompts, tools, wijzigingen, beslissingen en beurten.
    pub recap: RecapSink,
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

impl AgentHub {
    /// `support`: de map waar de hub zijn sessies bewaart (`agent-sessions.json`); `None` in tests.
    pub fn new(support: Option<PathBuf>, notify: impl Fn(HubEvent) + Send + Sync + 'static) -> Self {
        let home = dirs::home_dir().unwrap_or_default();
        let claude = std::env::var("CLAUDE_CONFIG_DIR").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or(home.join(".claude"));
        let codex = std::env::var("CODEX_HOME").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or(home.join(".codex"));
        let hub = Self {
            state: Mutex::new(State::default()),
            notify: Box::new(notify),
            records_file: support.as_ref().map(|d| d.join("agent-sessions.json")),
            usage_file: support.as_ref().map(|d| d.join("plan-usage.json")),
            launched_at: Utc::now(),
            default_homes: (normalize_home(&claude.to_string_lossy()), normalize_home(&codex.to_string_lossy())),
            recap: RecapSink::default(),
        };
        hub.restore();
        hub
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    // MARK: Lezen

    pub fn sessions(&self) -> Vec<AgentSession> {
        self.lock().sessions.clone()
    }

    pub fn detected(&self) -> Vec<AgentSession> {
        self.lock().detected.clone()
    }

    pub fn approvals(&self) -> Vec<ApprovalRequest> {
        self.lock().approvals.clone()
    }

    pub fn questions(&self) -> Vec<QuestionRequest> {
        self.lock().pending_questions.values().map(|p| p.request.clone()).collect()
    }

    pub fn question_for(&self, session_key: &str) -> Option<QuestionRequest> {
        self.lock().pending_questions.values().find(|p| p.request.session_key == session_key).map(|p| p.request.clone())
    }

    pub fn plan_usage(&self) -> (Option<PlanUsage>, BTreeMap<String, PlanUsage>) {
        let s = self.lock();
        (s.plan_usage.clone(), s.profile_plan_usage.clone())
    }

    /// Gebruik dat Nook rechtstreeks bij Anthropic ophaalde. Lege map = het standaardaccount.
    pub fn apply_fetched_usage(&self, usage: PlanUsage, home: &str) {
        {
            let mut s = self.lock();
            if home.is_empty() {
                s.plan_usage = Some(usage);
            } else {
                s.profile_plan_usage.insert(home.into(), usage);
            }
        }
        self.save_usage();
        (self.notify)(HubEvent::PlanUsage);
    }

    /// De accountmap uit de omgeving van de hook; leeg voor de standaardmap.
    fn account_home(&self, env: &Value, agent_id: &str) -> String {
        let (variable, default) = if agent_id == "codex" {
            ("CODEX_HOME", &self.default_homes.1)
        } else if agent_id.starts_with("claude") {
            ("CLAUDE_CONFIG_DIR", &self.default_homes.0)
        } else {
            return String::new();
        };
        let Some(raw) = text(env, variable) else { return String::new() };
        let home = normalize_home(raw);
        if &home == default {
            String::new()
        } else {
            home
        }
    }

    // MARK: Berichten

    /// Eén bericht van het hook-script (`{"agent","mode","env","event"}`).
    pub fn handle(&self, data: &[u8], mut responder: Responder) -> Wait {
        let Ok(object) = serde_json::from_slice::<Value>(data) else {
            responder.reply(None);
            return Wait::Done;
        };
        let event = object.get("event").cloned().unwrap_or(json!({}));
        let env = object.get("env").cloned().unwrap_or(json!({}));
        let mut agent_id = clean_agent_id(text(&object, "agent").unwrap_or("agent"));
        if agent_id == "claude-code" && text(&env, "CLAUDE_CODE_ENTRYPOINT") == Some("claude-desktop") {
            agent_id = "claude-desktop".into();
        }
        let mode = text(&object, "mode").map(str::to_string).unwrap_or_else(|| {
            if object.get("wait").and_then(Value::as_bool).unwrap_or(false) {
                "permission".into()
            } else {
                "event".into()
            }
        });
        let kind = normalize(text(&event, "hook_event_name").or_else(|| text(&event, "type")).unwrap_or(""));

        if mode == "statusline" {
            if let Some(usage) = PlanUsage::parse(&event, Utc::now()) {
                let home = self.account_home(&env, &agent_id);
                {
                    let mut s = self.lock();
                    if home.is_empty() {
                        s.plan_usage = Some(usage);
                    } else {
                        s.profile_plan_usage.insert(home, usage);
                    }
                }
                self.save_usage();
                (self.notify)(HubEvent::PlanUsage);
            }
            responder.reply(None);
            return Wait::Done;
        }

        // Sessies die Nook zelf draait, volgt de werkruimte (met eigen goedkeuringen); hier niet dubbel.
        if text(&env, "NOOK_RUN_ID").is_some() {
            responder.reply(None);
            return Wait::Done;
        }

        let cwd = text(&event, "cwd").or_else(|| text(&event, "workdir")).unwrap_or("").to_string();
        let session_id = text(&event, "session_id")
            .or_else(|| text(&event, "thread-id"))
            .or_else(|| text(&event, "thread_id"))
            .or_else(|| text(&event, "conversation_id"))
            .unwrap_or(&cwd)
            .to_string();
        let key = format!("{agent_id}:{session_id}");
        let name = display_name(&agent_id);
        let mut events: Vec<HubEvent> = Vec::new();

        {
            let mut s = self.lock();
            if kind == "SessionEnd" {
                s.records.remove(&key);
                s.dirty = true;
                Self::release_session(&mut s, &key, &mut events);
                Self::rebuild(&mut s);
                drop(s);
                responder.reply(None);
                events.push(HubEvent::Changed);
                self.emit(events);
                return Wait::Done;
            }

            let now = Utc::now();
            let mut record = s.records.get(&key).cloned().unwrap_or_else(|| Record {
                agent_id: agent_id.clone(),
                agent: name.clone(),
                project: project_name(&cwd),
                cwd: cwd.clone(),
                status: AgentStatus::Running,
                steps: vec![],
                file: String::new(),
                last_message: String::new(),
                updated: now,
                host: String::new(),
                home: String::new(),
                diff: vec![],
                lines_added: 0,
                lines_removed: 0,
                session_id: String::new(),
                transcript_path: String::new(),
                last_prompt: String::new(),
                started: now,
                lineage: vec![],
                pid: None,
            });
            if !cwd.is_empty() {
                record.cwd = cwd.clone();
                record.project = project_name(&cwd);
            }
            if let Some(host) = host_of_env(&env) {
                record.host = host;
            }
            record.home = self.account_home(&env, &agent_id);
            record.updated = now;
            // Which process this session runs in; the same session resumed in a new process starts over.
            let lineage: Vec<u32> = object
                .get("lineage")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_u64).filter_map(|p| u32::try_from(p).ok()).collect())
                .unwrap_or_default();
            let same_process = record.pid.is_some_and(|pid| lineage.contains(&pid));
            if !lineage.is_empty() && !same_process {
                record.pid = liveness::agent_process(&name, &lineage, &s.processes);
                record.lineage = lineage;
            }
            if let Some(id) = text(&event, "session_id") {
                record.session_id = id.into();
            }
            if let Some(path) = text(&event, "transcript_path") {
                record.transcript_path = path.into();
            }
            if record.transcript_path.is_empty() && name == "Antigravity" {
                let sid = if !record.session_id.is_empty() {
                    record.session_id.clone()
                } else {
                    text(&env, "ANTIGRAVITY_CONVERSATION_ID").unwrap_or("").into()
                };
                if !sid.is_empty() {
                    record.session_id = sid.clone();
                    let app_data = text(&env, "ANTIGRAVITY_APP_DATA_DIR")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".gemini").join("antigravity"));
                    record.transcript_path = app_data
                        .join("brain")
                        .join(&sid)
                        .join(".system_generated")
                        .join("logs")
                        .join("transcript.jsonl")
                        .to_string_lossy()
                        .into_owned();
                }
            }

            let tool = text(&event, "tool_name").or_else(|| text(&event, "toolName")).unwrap_or("").to_string();
            let input = event
                .get("tool_input")
                .filter(|v| v.is_object())
                .or_else(|| event.get("toolArgs").filter(|v| v.is_object()))
                .cloned()
                .unwrap_or(json!({}));

            // Meerkeuzevraag.
            if mode == "ask" {
                let items = (kind == "PreToolUse" && tool == "AskUserQuestion").then(|| QuestionRequest::parse(&input)).flatten();
                let Some(items) = items else {
                    s.records.insert(key, record);
                    s.dirty = true;
                    drop(s);
                    responder.reply(None);
                    return Wait::Done;
                };
                let id = uuid::Uuid::new_v4().to_string();
                let request = QuestionRequest {
                    id: id.clone(),
                    session_key: key.clone(),
                    agent_name: record.agent.clone(),
                    project: record.project.clone(),
                    items: items.clone(),
                };
                record.status = AgentStatus::Waiting;
                push(&mut record, StepMark::Blocked, format!("vraag: {}", shorten(&items[0].question, 60)));
                s.pending_questions.insert(
                    id.clone(),
                    PendingQuestion {
                        request: request.clone(),
                        responder,
                        raw_questions: input.get("questions").cloned().unwrap_or(json!([])),
                    },
                );
                s.records.insert(key, record);
                s.dirty = true;
                Self::rebuild(&mut s);
                drop(s);
                self.emit(vec![HubEvent::Question(request), HubEvent::Changed]);
                return Wait::Question(id, QUESTION_TIMEOUT);
            }

            // Toestemming: de agent wacht op ons antwoord.
            if mode == "permission" {
                if kind == "PermissionRequest" {
                    if tool == "AskUserQuestion" {
                        drop(s);
                        responder.reply(None);
                        return Wait::Done;
                    }
                    let suggestions = event.get("permission_suggestions").cloned();
                    let can_always =
                        agent_id.starts_with("claude") && suggestions.as_ref().and_then(Value::as_array).is_some_and(|a| !a.is_empty());
                    let (id, request) = Self::request_approval(
                        &mut s,
                        &key,
                        &mut record,
                        &tool,
                        &input,
                        PendingKind::Permission { suggestions, can_always },
                        responder,
                    );
                    s.records.insert(key, record);
                    s.dirty = true;
                    Self::rebuild(&mut s);
                    drop(s);
                    self.emit(vec![HubEvent::Approval(request), HubEvent::Changed]);
                    return Wait::Approval(id, APPROVAL_TIMEOUT);
                }
                if kind == "PreToolUse" && tool == "Bash" {
                    // Oude koppeling (van voor PermissionRequest): alleen commando's die niet duidelijk veilig zijn.
                    push(&mut record, StepMark::Running, describe(&tool, &input));
                    if let Some(command) = command_text(&input) {
                        if risk::assess(&command).level != RiskLevel::Safe {
                            let (id, request) =
                                Self::request_approval(&mut s, &key, &mut record, &tool, &input, PendingKind::LegacyPreToolUse, responder);
                            s.records.insert(key, record);
                            s.dirty = true;
                            Self::rebuild(&mut s);
                            drop(s);
                            self.emit(vec![HubEvent::Approval(request), HubEvent::Changed]);
                            return Wait::Approval(id, APPROVAL_TIMEOUT);
                        }
                    }
                    s.records.insert(key, record);
                    s.dirty = true;
                    Self::rebuild(&mut s);
                    drop(s);
                    responder.reply(None);
                    self.emit(vec![HubEvent::Changed]);
                    return Wait::Done;
                }
                responder.reply(None);
            }

            let mut attention = false;
            match kind.as_str() {
                "SessionStart" => record.status = AgentStatus::Running,
                "UserPromptSubmit" => {
                    record.status = AgentStatus::Running;
                    record.diff.clear();
                    if let Some(prompt) = event.get("prompt").and_then(Value::as_str) {
                        record.last_prompt = prompt.into();
                        record.last_message.clear();
                        push(&mut record, StepMark::Done, format!("opdracht: {}", shorten(prompt, 60)));
                    }
                    self.recap.note(|r, now| r.prompt(&key, &record.project, &record.agent, now));
                }
                "PreToolUse" => {
                    record.status = AgentStatus::Running;
                    if let Some(path) = file_path(&input) {
                        record.file = short_path(&path);
                    }
                    if let Some(edit) = edit_diff(&tool, &input) {
                        record.diff = edit.0;
                    }
                    push(&mut record, StepMark::Running, describe(&tool, &input));
                    self.recap.note(|r, now| r.tool_use(&tool, now));
                }
                "PostToolUse" => {
                    complete(&mut record, StepMark::Done);
                    resume(&mut record, Self::is_asking(&s, &key));
                    if let Some((_, added, removed)) = edit_diff(&tool, &input) {
                        record.lines_added += added;
                        record.lines_removed += removed;
                        self.recap.note(|r, now| r.edit(added as u32, removed as u32, now));
                    }
                }
                "PostToolUseFailure" => {
                    complete(&mut record, StepMark::Failed);
                    resume(&mut record, Self::is_asking(&s, &key));
                }
                "Notification" => {
                    let message = text(&event, "message").unwrap_or("wacht op je").to_string();
                    record.last_message = message.clone();
                    // Staat de vraag al als kaart in de balk, dan geen tweede melding.
                    let asking = Self::is_asking(&s, &key);
                    // "Claude is waiting for your input" is de rustmelding na een beurt, geen vraag aan jou.
                    let idle = message.to_lowercase().contains("waiting for your input");
                    if idle && !asking {
                        record.status = AgentStatus::Done;
                        push(&mut record, StepMark::Done, "klaar, wacht op je volgende opdracht");
                    } else if !asking {
                        record.status = AgentStatus::Waiting;
                        push(&mut record, StepMark::Blocked, shorten(&message, 70));
                        attention = true;
                    }
                }
                "Stop" => {
                    record.status = AgentStatus::Done;
                    if let Some(last) = text(&event, "last-assistant-message").or_else(|| text(&event, "last_assistant_message")) {
                        record.last_message = last.into();
                    }
                    complete(&mut record, StepMark::Done);
                    push(&mut record, StepMark::Done, "klaar");
                    attention = true;
                    self.recap.note(|r, now| r.turn_ended(&key, now));
                }
                "StopFailure" => {
                    record.status = AgentStatus::Failed;
                    let error = text(&event, "error").or_else(|| text(&event, "message")).unwrap_or("gestopt met een fout").to_string();
                    complete(&mut record, StepMark::Failed);
                    push(&mut record, StepMark::Failed, shorten(&error, 70));
                    attention = true;
                    self.recap.note(|r, now| r.turn_ended(&key, now));
                }
                "SubagentStart" => {
                    let kind = text(&event, "agent_type").or_else(|| text(&event, "subagent_type")).unwrap_or("");
                    push(
                        &mut record,
                        StepMark::Running,
                        if kind.is_empty() { "hulpagent gestart".into() } else { format!("hulpagent: {kind}") },
                    );
                }
                "SubagentStop" => complete(&mut record, StepMark::Done),
                "Interrupt" => {
                    record.status = AgentStatus::Done;
                    complete(&mut record, StepMark::Failed);
                    push(&mut record, StepMark::Failed, "onderbroken");
                    self.recap.note(|r, now| r.turn_ended(&key, now));
                }
                _ => {}
            }
            s.records.insert(key.clone(), record);
            s.dirty = true;
            Self::rebuild(&mut s);
            if attention {
                if let Some(session) = s.sessions.iter().find(|x| x.id == key) {
                    events.push(HubEvent::Attention(session.clone()));
                }
            }
            if mode != "permission" {
                responder.reply(None);
            }
            events.insert(0, HubEvent::Changed);
        }
        self.emit(events);
        Wait::Done
    }

    /// Is a card in the bar still asking you something for this session (an approval or a question)?
    fn is_asking(s: &State, key: &str) -> bool {
        s.pending_approvals.values().any(|p| p.request.session_key == key)
            || s.pending_questions.values().any(|p| p.request.session_key == key)
    }

    fn emit(&self, events: Vec<HubEvent>) {
        for e in events {
            (self.notify)(e);
        }
    }

    fn request_approval(
        s: &mut State,
        key: &str,
        record: &mut Record,
        tool: &str,
        input: &Value,
        kind: PendingKind,
        responder: Responder,
    ) -> (String, ApprovalRequest) {
        let id = uuid::Uuid::new_v4().to_string();
        let summary = approval_summary(tool, input);
        let edit = edit_diff(tool, input);
        let assessment = assess(tool, input, edit.as_ref());
        let can_always = matches!(kind, PendingKind::Permission { can_always: true, .. });
        let request = ApprovalRequest {
            id: id.clone(),
            session_key: key.into(),
            agent_name: record.agent.clone(),
            project: record.project.clone(),
            tool: tool.into(),
            summary: summary.clone(),
            diff: edit.as_ref().map(|e| e.0.clone()).unwrap_or_default(),
            assessment,
            can_always,
            created: Utc::now(),
        };
        s.pending_approvals.insert(id.clone(), PendingApproval { request: request.clone(), responder, kind });
        s.approvals.push(request.clone());
        record.status = AgentStatus::Waiting;
        if let Some(edit) = edit {
            record.diff = edit.0;
        }
        replace_last(record, StepMark::Blocked, format!("wacht op je: {}", shorten(&summary, 50)));
        (id, request)
    }

    /// Geeft vrij waar een sessie op wachtte.
    fn release_session(s: &mut State, key: &str, events: &mut Vec<HubEvent>) {
        let ids: Vec<String> = s.pending_approvals.iter().filter(|(_, p)| p.request.session_key == key).map(|(id, _)| id.clone()).collect();
        for id in ids {
            if let Some(mut p) = s.pending_approvals.remove(&id) {
                p.responder.reply(None);
                s.approvals.retain(|a| a.id != id);
                events.push(HubEvent::ApprovalGone(id, None));
            }
        }
        let ids: Vec<String> = s.pending_questions.iter().filter(|(_, p)| p.request.session_key == key).map(|(id, _)| id.clone()).collect();
        for id in ids {
            if let Some(mut p) = s.pending_questions.remove(&id) {
                p.responder.reply(None);
                events.push(HubEvent::QuestionGone(id, None));
            }
        }
    }

    // MARK: Antwoorden vanuit Nook

    pub fn approval(&self, id: &str) -> Option<ApprovalRequest> {
        self.lock().pending_approvals.get(id).map(|p| p.request.clone())
    }

    pub fn decide(&self, id: &str, decision: ApprovalDecision) {
        let response = {
            let s = self.lock();
            let Some(pending) = s.pending_approvals.get(id) else { return };
            response_for(decision, &pending.kind)
        };
        if decision != ApprovalDecision::Terminal {
            self.recap.note(|r, now| r.decision(decision != ApprovalDecision::Deny, now));
        }
        match decision {
            ApprovalDecision::Allow => self.close_approval(
                id,
                response,
                Some(AgentStatus::Running),
                Some((StepMark::Running, "toegestaan via Nook")),
                Some("Toegestaan"),
            ),
            ApprovalDecision::Always => self.close_approval(
                id,
                response,
                Some(AgentStatus::Running),
                Some((StepMark::Running, "altijd toegestaan via Nook")),
                Some("Altijd toegestaan"),
            ),
            ApprovalDecision::Deny => self.close_approval(
                id,
                response,
                Some(AgentStatus::Running),
                Some((StepMark::Failed, "geweigerd via Nook")),
                Some("Geweigerd"),
            ),
            ApprovalDecision::Terminal => {
                self.close_approval(id, None, Some(AgentStatus::Waiting), Some((StepMark::Blocked, "wacht op je in de terminal")), None)
            }
        }
    }

    fn close_approval(
        &self,
        id: &str,
        response: Option<String>,
        status: Option<AgentStatus>,
        step: Option<(StepMark, &str)>,
        message: Option<&str>,
    ) {
        {
            let mut s = self.lock();
            let Some(mut pending) = s.pending_approvals.remove(id) else { return };
            pending.responder.reply(response);
            s.approvals.retain(|a| a.id != id);
            let key = pending.request.session_key.clone();
            if let Some(record) = s.records.get_mut(&key) {
                if let Some(status) = status {
                    if record.status == AgentStatus::Waiting {
                        record.status = status;
                    }
                }
                if let Some((mark, text)) = step {
                    replace_last(record, mark, text);
                }
            }
            s.dirty = true;
            Self::rebuild(&mut s);
        }
        self.emit(vec![HubEvent::ApprovalGone(id.into(), message.map(str::to_string)), HubEvent::Changed]);
    }

    pub fn answer_question(&self, id: &str, selections: &[Vec<String>]) {
        let response = {
            let s = self.lock();
            let Some(pending) = s.pending_questions.get(id) else { return };
            let answers = QuestionRequest::answers(&pending.request.items, selections);
            json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                "updatedInput": {"questions": pending.raw_questions, "answers": answers}}})
            .to_string()
        };
        self.recap.note(|r, now| r.question_answered(now));
        let summary = selections.iter().flatten().cloned().collect::<Vec<_>>().join(", ");
        let step = format!("je koos: {}", shorten(&summary, 50));
        self.close_question(id, Some(response), Some(AgentStatus::Running), Some((StepMark::Done, &step)), Some("Antwoord verstuurd"));
    }

    pub fn answer_question_in_terminal(&self, id: &str) {
        self.close_question(id, None, Some(AgentStatus::Waiting), Some((StepMark::Blocked, "de vraag staat in de terminal")), None);
    }

    fn close_question(
        &self,
        id: &str,
        response: Option<String>,
        status: Option<AgentStatus>,
        step: Option<(StepMark, &str)>,
        message: Option<&str>,
    ) {
        {
            let mut s = self.lock();
            let Some(mut pending) = s.pending_questions.remove(id) else { return };
            pending.responder.reply(response);
            if let Some(record) = s.records.get_mut(&pending.request.session_key) {
                if let Some(status) = status {
                    if record.status == AgentStatus::Waiting {
                        record.status = status;
                    }
                }
                if let Some((mark, text)) = step {
                    replace_last(record, mark, text);
                }
            }
            s.dirty = true;
            Self::rebuild(&mut s);
        }
        self.emit(vec![HubEvent::QuestionGone(id.into(), message.map(str::to_string)), HubEvent::Changed]);
    }

    /// De agent sloot de verbinding: in de terminal beantwoord, of de agent stopte.
    pub fn peer_closed(&self, wait: &Wait) {
        match wait {
            Wait::Approval(id, _) => {
                self.close_approval(id, None, Some(AgentStatus::Running), Some((StepMark::Running, "beantwoord in de terminal")), None)
            }
            Wait::Question(id, _) => {
                self.close_question(id, None, Some(AgentStatus::Running), Some((StepMark::Done, "beantwoord in de terminal")), None)
            }
            Wait::Done => {}
        }
    }

    /// Geen antwoord op tijd: de agent vraagt het zelf, zoals altijd.
    pub fn expire(&self, wait: &Wait) {
        match wait {
            Wait::Approval(id, _) => {
                self.close_approval(id, None, Some(AgentStatus::Waiting), Some((StepMark::Blocked, "wacht op je in de terminal")), None)
            }
            Wait::Question(id, _) => {
                self.close_question(id, None, Some(AgentStatus::Waiting), Some((StepMark::Blocked, "de vraag staat in de terminal")), None)
            }
            Wait::Done => {}
        }
    }

    // MARK: Processen

    /// Het proces achter een sessie: uit de scan voor gevonden sessies, anders op agent en map. `None` als dat
    /// onbekend of dubbelzinnig is (twee dezelfde agents in één map), zodat Nook nooit de verkeerde beëindigt.
    pub fn process_id(&self, session_id: &str) -> Option<u32> {
        let s = self.lock();
        if let Some(pid) = session_id.strip_prefix("proc-") {
            return pid.parse().ok();
        }
        let session = s.sessions.iter().find(|x| x.id == session_id)?;
        if session.cwd.is_empty() {
            return None;
        }
        let matches: Vec<&DetectedAgent> = s.processes.iter().filter(|p| p.name == session.name && p.cwd == session.cwd).collect();
        (matches.len() == 1).then(|| matches[0].pid)
    }

    /// Haalt een sessie uit de lijst en geeft vrij waar hij op wachtte.
    pub fn forget(&self, key: &str) {
        let mut events = vec![];
        {
            let mut s = self.lock();
            Self::release_session(&mut s, key, &mut events);
            let pid = key.strip_prefix("proc-").and_then(|p| p.parse::<u32>().ok());
            if let Some(pid) = pid {
                s.processes.retain(|p| p.pid != pid);
                s.detected.retain(|d| d.id != key);
            }
            s.records.remove(key);
            s.dirty = true;
            Self::rebuild(&mut s);
        }
        events.push(HubEvent::Changed);
        self.emit(events);
    }

    /// Nieuwe processcan. `linked(agent, home)` zegt of die agent al gekoppeld is (dan startte deze sessie ervoor).
    pub fn apply_scan(&self, found: Vec<DetectedAgent>, linked: impl Fn(&str, &str) -> bool) {
        let changed = {
            let mut s = self.lock();
            s.processes = found.clone();
            // Sessions whose agent process was not known yet when their hook came.
            for record in s.records.values_mut() {
                if record.pid.is_none() && !record.lineage.is_empty() {
                    record.pid = liveness::agent_process(&record.agent, &record.lineage, &found);
                }
            }
            let mut dropped = self.drop_ended_restored(&mut s, &found);
            // Een sessie met hooks dekt één proces van zijn agent en map, niet allemaal.
            let mut covered: HashMap<String, usize> = HashMap::new();
            for r in s.records.values() {
                *covered.entry(format!("{}|{}", r.agent, r.cwd)).or_default() += 1;
            }
            let mut sorted = found;
            sorted.sort_by_key(|a| a.pid);
            let mut detected = Vec::new();
            for agent in sorted {
                let key = format!("{}|{}", agent.name, agent.cwd);
                if let Some(count) = covered.get_mut(&key) {
                    if *count > 0 {
                        *count -= 1;
                        continue;
                    }
                }
                let agent_id = if agent.name == "Codex" { "codex" } else { "claude-code" };
                let variable = if agent_id == "codex" { "CODEX_HOME" } else { "CLAUDE_CONFIG_DIR" };
                let home = if matches!(agent.name.as_str(), "Codex" | "Claude Code") {
                    self.account_home(&json!({ variable: agent.home }), agent_id)
                } else {
                    String::new()
                };
                let is_linked = linked(&agent.name, &home);
                let steps = if is_linked {
                    vec![
                        AgentStep::new(StepMark::Blocked, "Gestart vóór het koppelen: Nook kan hem niet volgen"),
                        AgentStep::new(StepMark::Todo, format!("Sluit {} en start hem opnieuw", agent.name)),
                    ]
                } else {
                    vec![
                        AgentStep::new(StepMark::Blocked, "Nog niet gekoppeld: Nook kan hem niet volgen"),
                        AgentStep::new(StepMark::Todo, format!("Koppel {} en start hem opnieuw", agent.name)),
                    ]
                };
                detected.push(AgentSession {
                    id: format!("proc-{}", agent.pid),
                    name: agent.name.clone(),
                    project: project_name(&agent.cwd),
                    status: AgentStatus::Detected,
                    file: if agent.cwd.is_empty() { "draait op deze computer".into() } else { short_path(&agent.cwd) },
                    placeholder: format!("Typ in de terminal van {} om verder te gaan", agent.name),
                    steps,
                    diff: vec![],
                    cwd: agent.cwd.clone(),
                    host: String::new(),
                    home,
                    approval_id: None,
                    question_id: None,
                    lines_added: 0,
                    lines_removed: 0,
                    summary: String::new(),
                    is_linked,
                    session_id: String::new(),
                    transcript_path: String::new(),
                    last_prompt: String::new(),
                    last_reply: String::new(),
                    started: None,
                    updated: None,
                    pid: Some(agent.pid),
                });
            }
            if s.detected != detected {
                s.detected = detected;
                dropped = true;
            }
            if dropped {
                Self::rebuild(&mut s);
            }
            dropped
        };
        let settled = self.settle_stale();
        if changed || settled {
            self.emit(vec![HubEvent::Changed]);
        }
    }

    /// Settles sessions that still read as busy while their turn has ended or their agent has quit, when the hook that
    /// should have said so never came (see `liveness`). Reads transcripts outside the lock. True when one changed.
    fn settle_stale(&self) -> bool {
        let scannable: HashSet<&str> = super::scanner::AGENT_NAMES.iter().copied().collect();
        // (key, last event, status) of each busy session, and the transcripts of those that run.
        let (busy, paths) = {
            let mut s = self.lock();
            let busy: Vec<(String, DateTime<Utc>, AgentStatus)> = s
                .records
                .iter()
                .filter(|(_, r)| matches!(r.status, AgentStatus::Running | AgentStatus::Waiting))
                .map(|(k, r)| (k.clone(), r.updated, r.status))
                .collect();
            let keys: HashSet<&String> = busy.iter().map(|(k, _, _)| k).collect();
            s.missing_scans.retain(|k, _| keys.contains(k));
            if busy.is_empty() {
                return false;
            }
            let mut paths = vec![];
            for (key, _, _) in &busy {
                let Some(record) = s.records.get(key) else { continue };
                let gone = scannable.contains(record.agent.as_str())
                    && !liveness::is_running(&record.agent, &record.cwd, record.pid, &s.processes);
                if record.status == AgentStatus::Running {
                    paths.push((key.clone(), record.transcript_path.clone()));
                }
                let count = if gone { s.missing_scans.get(key).copied().unwrap_or(0) + 1 } else { 0 };
                s.missing_scans.insert(key.clone(), count);
            }
            (busy, paths)
        };
        let turns: HashMap<String, (liveness::Turn, Option<DateTime<Utc>>)> =
            paths.into_iter().filter_map(|(key, path)| liveness::read_turn(&path).map(|t| (key, t))).collect();

        let now = Utc::now();
        let mut s = self.lock();
        let mut changed = false;
        for (key, updated, status) in busy {
            // A hook event while the transcript was read wins.
            let Some(record) = s.records.get(&key) else { continue };
            if record.updated != updated || record.status != status || Self::is_asking(&s, &key) {
                continue;
            }
            let (turn, modified) = turns.get(&key).copied().unwrap_or((liveness::Turn::Unknown, None));
            let missing = s.missing_scans.get(&key).copied().unwrap_or(0);
            let Some(verdict) = liveness::verdict(status == AgentStatus::Running, updated, turn, modified, missing, now) else {
                continue;
            };
            let Some(record) = s.records.get_mut(&key) else { continue };
            record.status = AgentStatus::Done;
            complete(record, StepMark::Done);
            push(record, StepMark::Done, if verdict == liveness::Verdict::ProcessGone { "sessie gesloten" } else { "klaar" });
            s.missing_scans.remove(&key);
            changed = true;
            log::info!("Vastgelopen sessie afgerond: {key} ({verdict:?})");
        }
        if changed {
            s.dirty = true;
            Self::rebuild(&mut s);
        }
        changed
    }

    /// Een teruggezette sessie waarvan de agent stopte terwijl Nook dicht was, valt weg zodra de proceslijst dat laat
    /// zien. Agents die de scan niet kent (apps, eigen tools) blijven tot de gewone vervaltijd.
    fn drop_ended_restored(&self, s: &mut State, found: &[DetectedAgent]) -> bool {
        if s.unconfirmed.is_empty() {
            return false;
        }
        let scannable: HashSet<&str> = super::scanner::AGENT_NAMES.iter().copied().collect();
        let mut running: HashMap<String, usize> = HashMap::new();
        for a in found {
            *running.entry(format!("{}|{}", a.name, a.cwd)).or_default() += 1;
        }
        let mut changed = false;
        let mut keys: Vec<String> = s.unconfirmed.drain().collect();
        keys.sort();
        for key in keys {
            let Some(record) = s.records.get(&key) else { continue };
            if record.updated >= self.launched_at || !scannable.contains(record.agent.as_str()) {
                continue;
            }
            let id = format!("{}|{}", record.agent, record.cwd);
            match running.get_mut(&id) {
                Some(count) if *count > 0 => *count -= 1,
                _ => {
                    s.records.remove(&key);
                    s.dirty = true;
                    changed = true;
                }
            }
        }
        changed
    }

    // MARK: Onderhoud

    /// Elke minuut: sessies die lang niets deden vallen weg (klaar na 4 uur, de rest na 12 uur).
    pub fn prune(&self) {
        let now = Utc::now();
        let mut s = self.lock();
        let waiting: HashSet<String> = s.pending_approvals.values().map(|p| p.request.session_key.clone()).collect();
        let before = s.records.len();
        s.records.retain(|key, r| {
            if waiting.contains(key) {
                return true;
            }
            let age = (now - r.updated).num_seconds();
            if r.status == AgentStatus::Done {
                age < 4 * 3600
            } else {
                age < 12 * 3600
            }
        });
        if s.records.len() != before {
            s.dirty = true;
            Self::rebuild(&mut s);
            drop(s);
            self.emit(vec![HubEvent::Changed]);
        }
    }

    /// Schrijft de sessies weg als er iets veranderde (een reeks hook-events wordt één keer schrijven).
    pub fn flush(&self) {
        let Some(file) = &self.records_file else { return };
        let saved: Vec<SavedRecord> = {
            let mut s = self.lock();
            if !s.dirty {
                return;
            }
            s.dirty = false;
            s.records.iter().map(|(k, r)| SavedRecord { key: k.clone(), record: r.clone() }).collect()
        };
        if let Ok(bytes) = serde_json::to_vec(&saved) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    fn save_usage(&self) {
        let Some(file) = &self.usage_file else { return };
        let (main, profiles) = self.plan_usage();
        if let Ok(bytes) = serde_json::to_vec(&json!({"main": main, "profiles": profiles})) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// Agents lopen door in hun terminal als Nook dicht gaat: de sessies van hun hooks worden teruggezet.
    fn restore(&self) {
        let mut s = self.lock();
        if let Some(file) = &self.usage_file {
            if let Some(v) = std::fs::read(file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                s.plan_usage = v.get("main").cloned().and_then(|m| serde_json::from_value(m).ok());
                s.profile_plan_usage = v.get("profiles").cloned().and_then(|m| serde_json::from_value(m).ok()).unwrap_or_default();
            }
        }
        let Some(file) = &self.records_file else { return };
        let Some(saved) = std::fs::read(file).ok().and_then(|b| serde_json::from_slice::<Vec<SavedRecord>>(&b).ok()) else { return };
        let now = Utc::now();
        for item in saved {
            let age = (now - item.record.updated).num_seconds();
            let limit = if item.record.status == AgentStatus::Done { 4 * 3600 } else { 12 * 3600 };
            if age >= limit {
                continue;
            }
            let mut record = item.record;
            record.project = project_name(&record.cwd);
            if record.status == AgentStatus::Detected {
                record.status = AgentStatus::Running;
            }
            s.unconfirmed.insert(item.key.clone());
            s.records.insert(item.key, record);
        }
        Self::rebuild(&mut s);
    }

    fn rebuild(s: &mut State) {
        let mut entries: Vec<(&String, &Record)> = s.records.iter().collect();
        entries.sort_by(|(_, a), (_, b)| a.status.order().cmp(&b.status.order()).then(b.updated.cmp(&a.updated)));
        let sessions: Vec<AgentSession> = entries
            .into_iter()
            .map(|(key, r)| {
                let mut diff = Vec::new();
                if matches!(r.status, AgentStatus::Done | AgentStatus::Failed) || r.diff.is_empty() {
                    if !r.cwd.is_empty() {
                        diff.push(DiffLine::context(r.cwd.clone()));
                    }
                    for line in r.last_message.lines().take(8) {
                        diff.push(DiffLine::context(line.chars().take(110).collect::<String>()));
                    }
                } else {
                    diff = r.diff.clone();
                }
                let mut file = r.file.clone();
                if r.lines_added + r.lines_removed > 0 {
                    file.push_str(&format!("  +{} −{}", r.lines_added, r.lines_removed));
                }
                AgentSession {
                    id: key.clone(),
                    name: r.agent.clone(),
                    project: r.project.clone(),
                    status: r.status,
                    file,
                    placeholder: format!("Typ in de terminal van {} om verder te gaan", r.agent),
                    steps: r.steps.clone(),
                    diff,
                    cwd: r.cwd.clone(),
                    host: r.host.clone(),
                    home: r.home.clone(),
                    approval_id: s.approvals.iter().find(|a| &a.session_key == key).map(|a| a.id.clone()),
                    question_id: s.pending_questions.values().find(|q| &q.request.session_key == key).map(|q| q.request.id.clone()),
                    lines_added: r.lines_added,
                    lines_removed: r.lines_removed,
                    summary: one_line(&r.last_message, 220),
                    is_linked: false,
                    session_id: r.session_id.clone(),
                    transcript_path: r.transcript_path.clone(),
                    last_prompt: r.last_prompt.clone(),
                    last_reply: r.last_message.clone(),
                    started: Some(r.started),
                    updated: Some(r.updated),
                    pid: None,
                }
            })
            .collect();
        s.sessions = sessions;
    }
}

// MARK: Hulpfuncties

/// In welke app de agent draait, uit de omgeving van zijn hook: `x11:<venster>` (xterm, Konsole, Alacritty, …),
/// `windows-terminal`, `vscode`, `kitty`, `wezterm`, `jetbrains`, `konsole` of de `TERM_PROGRAM`.
pub fn host_of_env(env: &Value) -> Option<String> {
    let program = text(env, "TERM_PROGRAM").unwrap_or("").to_lowercase();
    if program == "vscode" {
        // VS Code en Cursor zetten allebei "vscode".
        return Some("vscode".into());
    }
    if let Some(id) = text(env, "WINDOWID").filter(|w| w.chars().all(|c| c.is_ascii_digit())) {
        return Some(format!("x11:{id}"));
    }
    if text(env, "WT_SESSION").is_some() {
        return Some("windows-terminal".into());
    }
    if text(env, "TERMINAL_EMULATOR").is_some_and(|t| t.contains("JetBrains")) {
        return Some("jetbrains".into());
    }
    if text(env, "KITTY_WINDOW_ID").is_some() {
        return Some("kitty".into());
    }
    if text(env, "WEZTERM_PANE").is_some() {
        return Some("wezterm".into());
    }
    if text(env, "KONSOLE_VERSION").is_some() {
        return Some("konsole".into());
    }
    if !program.is_empty() {
        return Some(program);
    }
    text(env, "__CFBundleIdentifier").map(str::to_string)
}

fn push(record: &mut Record, mark: StepMark, text: impl Into<String>) {
    record.steps.push(AgentStep::new(mark, text));
    if record.steps.len() > 6 {
        let extra = record.steps.len() - 6;
        record.steps.drain(..extra);
    }
}

fn replace_last(record: &mut Record, mark: StepMark, text: impl Into<String>) {
    match record.steps.last_mut() {
        Some(last) => *last = AgentStep::new(mark, text),
        None => push(record, mark, text),
    }
}

/// A tool finished while the session read as waiting: you answered its prompt in the terminal, so it works again.
/// Without this it stayed amber ("waits for you") until the next tool started or the turn ended.
fn resume(record: &mut Record, asking: bool) {
    if record.status == AgentStatus::Waiting && !asking {
        record.status = AgentStatus::Running;
    }
}

/// Sluit de laatste stap af die liep (of op de gebruiker wachtte).
fn complete(record: &mut Record, mark: StepMark) {
    if let Some(last) = record.steps.last_mut() {
        if matches!(last.mark, StepMark::Running | StepMark::Blocked) {
            last.mark = mark;
        }
    }
}

fn response_for(decision: ApprovalDecision, kind: &PendingKind) -> Option<String> {
    let payload = match kind {
        PendingKind::LegacyPreToolUse => {
            let value = match decision {
                ApprovalDecision::Allow | ApprovalDecision::Always => "allow",
                ApprovalDecision::Deny => "deny",
                ApprovalDecision::Terminal => return None,
            };
            json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": value,
                "permissionDecisionReason": if value == "allow" { "Approved via Nook" } else { "Denied via Nook" }}})
        }
        PendingKind::Permission { suggestions, can_always } => {
            let result = match decision {
                ApprovalDecision::Allow => json!({"behavior": "allow"}),
                ApprovalDecision::Always => {
                    let mut r = json!({"behavior": "allow"});
                    // Claude Code bewaart de regel zelf, net als "Ja, en vraag het niet meer".
                    if *can_always {
                        if let Some(list) = suggestions.as_ref().filter(|s| s.as_array().is_some_and(|a| !a.is_empty())) {
                            r["updatedPermissions"] = list.clone();
                        }
                    }
                    r
                }
                ApprovalDecision::Deny => json!({"behavior": "deny", "message": "Denied via Nook"}),
                ApprovalDecision::Terminal => return None,
            };
            json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": result}})
        }
    };
    Some(payload.to_string())
}

/// Zet de namen van andere agents (Gemini CLI, Antigravity, Copilot, Cursor, …) om naar die van Claude Code.
pub fn normalize(name: &str) -> String {
    match name {
        "BeforeTool" | "pre_tool_use" | "preToolUse" => "PreToolUse",
        "AfterTool" | "PostInvocation" | "post_tool_use" | "postToolUse" => "PostToolUse",
        "BeforeAgent" | "PreInvocation" | "beforeSubmitPrompt" | "user_prompt_submit" | "userPromptSubmitted" => "UserPromptSubmit",
        "AfterAgent" | "stop" | "agentStop" | "agent-turn-complete" => "Stop",
        "postToolUseFailure" => "PostToolUseFailure",
        "subagentStart" => "SubagentStart",
        "subagentStop" => "SubagentStop",
        "session_start" | "sessionStart" | "startup" => "SessionStart",
        "session_end" | "sessionEnd" | "exit" => "SessionEnd",
        "notification" => "Notification",
        "permissionRequest" => "PermissionRequest",
        other => other,
    }
    .to_string()
}

pub fn clean_agent_id(raw: &str) -> String {
    let clean: String =
        raw.to_lowercase().chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-' || *c == '_').take(32).collect();
    if clean.is_empty() {
        "agent".into()
    } else {
        clean
    }
}

pub fn display_name(id: &str) -> String {
    match id {
        "claude-code" => "Claude Code".into(),
        "claude-desktop" => "Claude (app)".into(),
        "codex" => "Codex".into(),
        "gemini" => "Gemini CLI".into(),
        "antigravity" => "Antigravity".into(),
        "copilot" => "Copilot CLI".into(),
        "cursor" => "Cursor".into(),
        "opencode" => "OpenCode".into(),
        "amp" => "Amp".into(),
        "hermes" => "Hermes".into(),
        "muse" => "Muse Code".into(),
        "qwen" => "Qwen Code".into(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        }
    }
}

/// Vergelijkbaar pad: `~` uitgeschreven, zonder slotscheidingsteken.
pub fn normalize_home(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    let expanded = if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        dirs::home_dir().unwrap_or_default().join(rest).to_string_lossy().into_owned()
    } else if path == "~" {
        dirs::home_dir().unwrap_or_default().to_string_lossy().into_owned()
    } else {
        path.to_string()
    };
    let trimmed = expanded.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        expanded
    } else {
        trimmed.to_string()
    }
}

/// De commandotekst, ook als een agent hem als lijst geeft (Codex: `["bash", "-lc", "npm test"]`).
pub fn command_text(input: &Value) -> Option<String> {
    match input.get("command")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(parts) => {
            let parts: Vec<String> = parts.iter().filter_map(|p| p.as_str().map(str::to_string)).collect();
            if parts.is_empty() {
                return None;
            }
            let shell = parts[0].rsplit(['/', '\\']).next().unwrap_or("").to_lowercase();
            let shells = ["bash", "sh", "zsh", "powershell", "powershell.exe", "pwsh", "pwsh.exe", "cmd", "cmd.exe"];
            if parts.len() >= 3 && shells.contains(&shell.as_str()) && (parts[1].starts_with('-') || parts[1].eq_ignore_ascii_case("/c")) {
                return Some(parts[2..].join(" "));
            }
            Some(parts.join(" "))
        }
        _ => None,
    }
}

pub fn file_path(input: &Value) -> Option<String> {
    ["file_path", "absolute_path", "notebook_path", "path"].iter().find_map(|k| text(input, k).map(str::to_string))
}

/// De wijziging van een bewerk-tool als diff, met (regels, toegevoegd, weggehaald).
pub fn edit_diff(tool: &str, input: &Value) -> Option<(Vec<DiffLine>, usize, usize)> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let ops = match tool {
        "Edit" | "replace" => line_diff::diff(&line_diff::lines(&s(input, "old_string")), &line_diff::lines(&s(input, "new_string"))),
        "MultiEdit" => input
            .get("edits")
            .and_then(Value::as_array)
            .map(|edits| {
                edits
                    .iter()
                    .flat_map(|e| line_diff::diff(&line_diff::lines(&s(e, "old_string")), &line_diff::lines(&s(e, "new_string"))))
                    .collect()
            })
            .unwrap_or_default(),
        "Write" | "write_file" => line_diff::lines(&s(input, "content")).into_iter().map(line_diff::Op::Add).collect(),
        _ => return None,
    };
    if ops.is_empty() {
        return None;
    }
    let (added, removed) = line_diff::counts(&ops);
    Some((line_diff::display(&ops, 1, 30, 110), added, removed))
}

pub fn approval_summary(tool: &str, input: &Value) -> String {
    // An MCP tool shows every argument it gets: the title names the tool and its server.
    if let Some(mcp) = McpToolName::parse(tool) {
        let arguments = mcp_name::arguments(input);
        return if arguments.is_empty() { mcp.label() } else { arguments };
    }
    if let Some(command) = command_text(input) {
        return command;
    }
    if let Some(path) = file_path(input) {
        return format!("{tool} {}", short_path(&path));
    }
    if let Some(url) = text(input, "url") {
        return url.into();
    }
    if let Some(query) = text(input, "query") {
        return format!("zoekt: {query}");
    }
    if let Some(obj) = input.as_object().filter(|o| !o.is_empty()) {
        let sorted: BTreeMap<_, _> = obj.iter().collect();
        if let Ok(text) = serde_json::to_string(&sorted) {
            return format!("{tool} {}", shorten(&text, 140));
        }
    }
    if tool.is_empty() {
        "iets op je computer".into()
    } else {
        tool.into()
    }
}

fn host_of(url: &str) -> String {
    url.split("://").nth(1).unwrap_or("").split(['/', '?', '#']).next().unwrap_or("").to_string()
}

/// The note on an approval for a tool of an MCP server.
pub const MCP_NOTE: &str = "Voert een tool uit van een gekoppelde MCP-server";

pub fn assess(tool: &str, input: &Value, edit: Option<&(Vec<DiffLine>, usize, usize)>) -> CommandAssessment {
    if let Some(command) = command_text(input) {
        let a = risk::assess(&command);
        if a.level == RiskLevel::Safe {
            return CommandAssessment::review("Alleen lezen · ziet er onschuldig uit");
        }
        return a;
    }
    if let Some((_, added, removed)) = edit {
        let file = file_path(input).map(|p| p.rsplit(['/', '\\']).next().unwrap_or("").to_string()).unwrap_or_else(|| "een bestand".into());
        return CommandAssessment::review(format!("Wijzigt {file} · +{added} −{removed}"));
    }
    if let Some(url) = text(input, "url") {
        let host = host_of(url);
        return CommandAssessment::review(format!("Haalt op van {}", if host.is_empty() { "het internet".into() } else { host }));
    }
    if tool.starts_with("mcp__") {
        return CommandAssessment::review(MCP_NOTE);
    }
    CommandAssessment::review("Kijk het even na")
}

pub fn describe(tool: &str, input: &Value) -> String {
    if let Some(mcp) = McpToolName::parse(tool) {
        return mcp.label();
    }
    if let Some(command) = command_text(input) {
        return format!("Bash: {}", shorten(&command, 55));
    }
    let file_name = || file_path(input).map(|p| p.rsplit(['/', '\\']).next().unwrap_or("").to_string()).unwrap_or_default();
    match tool {
        "Read" | "read_file" => format!("Leest {}", file_name()),
        "Write" | "write_file" => format!("Schrijft {}", file_name()),
        "Edit" | "MultiEdit" | "NotebookEdit" | "replace" => format!("Wijzigt {}", file_name()),
        "Grep" | "Glob" | "search_file_content" | "glob" => format!("Zoekt {}", shorten(text(input, "pattern").unwrap_or(""), 40)),
        "WebFetch" | "web_fetch" => format!("Haalt op: {}", host_of(text(input, "url").unwrap_or(""))),
        "WebSearch" | "google_web_search" => format!("Zoekt online: {}", shorten(text(input, "query").unwrap_or(""), 40)),
        "Task" | "Agent" => format!("Hulpagent: {}", shorten(text(input, "description").unwrap_or(""), 40)),
        "TodoWrite" => "Werkt de takenlijst bij".into(),
        "" => "bezig".into(),
        t => t.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn hub() -> (AgentHub, Arc<Mutex<Vec<String>>>) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let l = log.clone();
        let hub = AgentHub::new(None, move |e| {
            let name = match e {
                HubEvent::Changed => "changed".to_string(),
                HubEvent::Approval(_) => "approval".into(),
                HubEvent::ApprovalGone(_, m) => format!("approvalGone:{}", m.unwrap_or_default()),
                HubEvent::Question(_) => "question".into(),
                HubEvent::QuestionGone(_, m) => format!("questionGone:{}", m.unwrap_or_default()),
                HubEvent::Attention(_) => "attention".into(),
                HubEvent::PlanUsage => "usage".into(),
            };
            l.lock().unwrap().push(name);
        });
        (hub, log)
    }

    fn msg(agent: &str, mode: &str, event: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({"agent": agent, "mode": mode, "env": {}, "event": event})).unwrap()
    }

    #[test]
    fn prompt_tool_and_stop_make_steps() {
        let (hub, log) = hub();
        let recap = Arc::new(Mutex::new(crate::services::recap::RecapStore::default()));
        hub.recap.set(recap.clone());
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/w/app", "prompt": "hallo"}),
            ),
            Responder::none(),
        );
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "npm test"}}),
            ),
            Responder::none(),
        );
        hub.handle(
            &msg("claude-code", "event", json!({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash"})),
            Responder::none(),
        );
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "Stop", "session_id": "s1", "last_assistant_message": "## Klaar\nAlle tests slagen."}),
            ),
            Responder::none(),
        );
        let s = &hub.sessions()[0];
        assert_eq!(s.id, "claude-code:s1");
        assert_eq!(s.name, "Claude Code");
        assert_eq!(s.project, "app");
        assert_eq!(s.status, AgentStatus::Done);
        assert_eq!(s.summary, "Klaar Alle tests slagen.");
        let texts: Vec<_> = s.steps.iter().map(|x| (x.mark, x.text.as_str())).collect();
        assert_eq!(texts, vec![(StepMark::Done, "opdracht: hallo"), (StepMark::Done, "Bash: npm test"), (StepMark::Done, "klaar")]);
        assert!(log.lock().unwrap().contains(&"attention".to_string()));
        // Het weekoverzicht telt mee.
        let week = recap.lock().unwrap().summary(chrono::Local::now().date_naive());
        assert_eq!((week.sessions, week.prompts, week.commands), (1, 1, 1));
        assert_eq!(week.top_agent.as_deref(), Some("Claude Code"));
    }

    #[tokio::test]
    async fn permission_waits_and_allow_replies() {
        let (hub, _) = hub();
        let recap = Arc::new(Mutex::new(crate::services::recap::RecapStore::default()));
        hub.recap.set(recap.clone());
        let (responder, rx) = Responder::new();
        let wait = hub.handle(
            &msg(
                "claude-code",
                "permission",
                json!({"hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/w/app",
                "tool_name": "Bash", "tool_input": {"command": "rm -rf build"}, "permission_suggestions": [{"type": "addRules"}]}),
            ),
            responder,
        );
        let Wait::Approval(id, _) = wait else { panic!("geen wachten") };
        let approval = hub.approval(&id).unwrap();
        assert!(approval.can_always);
        assert_eq!(approval.summary, "rm -rf build");
        assert_eq!(approval.assessment.level, RiskLevel::Danger);
        assert_eq!(hub.sessions()[0].status, AgentStatus::Waiting);
        hub.decide(&id, ApprovalDecision::Always);
        let reply: Value = serde_json::from_str(&rx.await.unwrap().unwrap()).unwrap();
        assert_eq!(reply["hookSpecificOutput"]["decision"]["behavior"], "allow");
        assert_eq!(reply["hookSpecificOutput"]["decision"]["updatedPermissions"][0]["type"], "addRules");
        assert!(hub.approvals().is_empty());
        assert_eq!(hub.sessions()[0].status, AgentStatus::Running);
        let week = recap.lock().unwrap().summary(chrono::Local::now().date_naive());
        assert_eq!((week.allowed, week.denied), (1, 0));
    }

    #[tokio::test]
    async fn answering_in_terminal_dismisses() {
        let (hub, log) = hub();
        let (responder, rx) = Responder::new();
        let wait = hub.handle(
            &msg(
                "codex",
                "permission",
                json!({"hook_event_name": "PermissionRequest", "session_id": "c", "tool_name": "exec_command",
                "tool_input": {"command": ["bash", "-lc", "cargo test"]}}),
            ),
            responder,
        );
        hub.peer_closed(&wait);
        assert!(hub.approvals().is_empty());
        assert_eq!(rx.await.unwrap(), None);
        assert!(log.lock().unwrap().iter().any(|e| e == "approvalGone:"));
        assert_eq!(hub.sessions()[0].steps.last().unwrap().text, "beantwoord in de terminal");
    }

    #[tokio::test]
    async fn questions_round_trip() {
        let (hub, _) = hub();
        let (responder, rx) = Responder::new();
        let input = json!({"questions": [{"question": "Welke database?", "header": "DB", "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]});
        let wait = hub.handle(
            &msg(
                "claude-code",
                "ask",
                json!({"hook_event_name": "PreToolUse", "session_id": "q", "tool_name": "AskUserQuestion", "tool_input": input}),
            ),
            responder,
        );
        let Wait::Question(id, _) = wait else { panic!() };
        assert_eq!(hub.sessions()[0].question_id.as_deref(), Some(id.as_str()));
        hub.answer_question(&id, &[vec!["SQLite".into()]]);
        let reply: Value = serde_json::from_str(&rx.await.unwrap().unwrap()).unwrap();
        assert_eq!(reply["hookSpecificOutput"]["updatedInput"]["answers"]["Welke database?"], "SQLite");
        assert_eq!(reply["hookSpecificOutput"]["permissionDecision"], "allow");
    }

    #[test]
    fn nook_runs_and_session_end() {
        let (hub, _) = hub();
        let data = serde_json::to_vec(&json!({"agent": "claude-code", "mode": "event", "env": {"NOOK_RUN_ID": "x"},
            "event": {"hook_event_name": "UserPromptSubmit", "session_id": "n"}}))
        .unwrap();
        hub.handle(&data, Responder::none());
        assert!(hub.sessions().is_empty());
        hub.handle(&msg("gemini", "event", json!({"hook_event_name": "BeforeAgent", "session_id": "g"})), Responder::none());
        assert_eq!(hub.sessions()[0].name, "Gemini CLI");
        hub.handle(&msg("gemini", "event", json!({"hook_event_name": "session_end", "session_id": "g"})), Responder::none());
        assert!(hub.sessions().is_empty());
    }

    #[test]
    fn idle_notification_is_done() {
        let (hub, _) = hub();
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "Notification", "session_id": "i", "message": "Claude is waiting for your input"}),
            ),
            Responder::none(),
        );
        assert_eq!(hub.sessions()[0].status, AgentStatus::Done);
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "Notification", "session_id": "j", "message": "Claude needs your permission"}),
            ),
            Responder::none(),
        );
        assert!(hub.sessions().iter().any(|s| s.status == AgentStatus::Waiting));
    }

    #[test]
    fn a_finished_tool_puts_a_waiting_session_back_to_work() {
        let (hub, _) = hub();
        let event = |name: &str| msg("claude-code", "event", json!({"hook_event_name": name, "session_id": "w", "tool_name": "Bash"}));
        hub.handle(
            &msg(
                "claude-code",
                "event",
                json!({"hook_event_name": "Notification", "session_id": "w", "message": "Claude needs your permission"}),
            ),
            Responder::none(),
        );
        assert_eq!(hub.sessions()[0].status, AgentStatus::Waiting);
        hub.handle(&event("PostToolUse"), Responder::none());
        assert_eq!(hub.sessions()[0].status, AgentStatus::Running, "answered in the terminal");
    }

    #[test]
    fn a_closed_session_settles_even_with_another_session_in_its_folder() {
        let (hub, _) = hub();
        let start = |sid: &str, lineage: Vec<u32>| {
            serde_json::to_vec(&json!({"agent": "claude-code", "mode": "event", "env": {}, "lineage": lineage,
                "event": {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/site", "prompt": "go"}}))
            .unwrap()
        };
        let p = |pid| DetectedAgent { pid, name: "Claude Code".into(), cwd: "/site".into(), home: String::new() };
        hub.apply_scan(vec![p(50), p(60)], |_, _| true);
        hub.handle(&start("a", vec![90, 80, 50, 10]), Responder::none());
        hub.handle(&start("b", vec![91, 60]), Responder::none());
        assert_eq!(hub.lock().records["claude-code:a"].pid, Some(50));
        // Session a's process quits; b keeps running in the same folder.
        for record in hub.lock().records.values_mut() {
            record.updated = Utc::now() - chrono::Duration::seconds(120);
        }
        hub.apply_scan(vec![p(60)], |_, _| true);
        hub.apply_scan(vec![p(60)], |_, _| true);
        let status = |key: &str| hub.lock().records[key].status;
        assert_eq!(status("claude-code:a"), AgentStatus::Done);
        assert_eq!(status("claude-code:b"), AgentStatus::Running);
    }

    #[test]
    fn scan_covers_one_process_per_hooked_session() {
        let (hub, _) = hub();
        hub.handle(
            &msg("claude-code", "event", json!({"hook_event_name": "SessionStart", "session_id": "a", "cwd": "/w"})),
            Responder::none(),
        );
        let p = |pid| DetectedAgent { pid, name: "Claude Code".into(), cwd: "/w".into(), home: String::new() };
        hub.apply_scan(vec![p(10), p(11)], |_, _| true);
        let d = hub.detected();
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].id, "proc-11");
        assert!(d[0].is_linked);
        assert_eq!(hub.process_id("proc-11"), Some(11));
        assert_eq!(hub.process_id("claude-code:a"), None, "twee processen in één map: dubbelzinnig");
    }

    #[test]
    fn saves_and_restores() {
        let dir = std::env::temp_dir().join(format!("nook-hub-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        {
            let hub = AgentHub::new(Some(dir.clone()), |_| {});
            hub.handle(
                &msg("codex", "event", json!({"hook_event_name": "UserPromptSubmit", "session_id": "r", "cwd": "/w/x", "prompt": "p"})),
                Responder::none(),
            );
            hub.flush();
        }
        let hub = AgentHub::new(Some(dir.clone()), |_| {});
        assert_eq!(hub.sessions()[0].last_prompt, "p");
        // Het proces is weg: bij de eerste scan valt de sessie weg.
        hub.apply_scan(vec![], |_, _| false);
        assert!(hub.sessions().is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn helpers() {
        assert_eq!(normalize("BeforeTool"), "PreToolUse");
        assert_eq!(clean_agent_id("Mijn Tool!"), "mijntool");
        assert_eq!(display_name("mijn-tool"), "Mijn-tool");
        assert_eq!(command_text(&json!({"command": ["bash", "-lc", "npm test"]})).as_deref(), Some("npm test"));
        assert_eq!(command_text(&json!({"command": ["cmd", "/c", "dir"]})).as_deref(), Some("dir"));
        assert_eq!(describe("Edit", &json!({"file_path": "/a/b/Login.swift"})), "Wijzigt Login.swift");
        let (lines, a, r) = edit_diff("Edit", &json!({"old_string": "a\nb", "new_string": "a\nc"})).unwrap();
        assert_eq!((a, r), (1, 1));
        assert!(!lines.is_empty());
        assert_eq!(approval_summary("mcp__github__create_issue", &json!({})), "Github › Create issue");
        assert_eq!(approval_summary("mcp__files__move_file", &json!({"source": "a", "target": "b"})), "Source: a\nTarget: b");
        assert_eq!(describe("mcp__files__move_file", &json!({})), "Files › Move file");
    }
}
