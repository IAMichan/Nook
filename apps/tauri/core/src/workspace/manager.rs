//! Start en volgt coding-agents in de werkruimte (`WorkspaceManager` op de Mac). De interface praat alleen met dit
//! object. Eén proces per beurt: een vervolgbericht gaat verder met `--resume` (Claude Code), `exec resume` (Codex) of
//! `--resume` (Gemini CLI). Zo blijven er geen losse processen hangen, en verdergaan na een herstart van Nook werkt
//! precies hetzelfde.
//!
//! Alles wat de interface moet weten, gaat via [`ManagerEvent`]. De status staat achter één mutex die nooit over een
//! `await` vastgehouden wordt.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use uuid::Uuid;

use super::bridge::BridgeLaunch;
use super::command::{self, CommandInput};
use super::driver;
use super::git::{self, Git, GitStatus, Worktree};
use super::limits;
use super::models::*;
use super::parsers::{self, ClaudeEvent, CodexEvent, GeminiEvent, TokenCounts};
use super::paths::{self, Verdict};
use super::queue::MessageQueue;
use super::rollback::{self, ConversationLog, ConversationMark, Plan};
use super::store::{RunStore, UsageFilter, UsageReport, EVENT_LIMIT};
use super::terminal::{self, ProjectScript};
use super::worktree_setup::{SetupStep, WorktreeSetupProgress, REMOTE_BASE_REFRESH_TTL, START_FETCH_TIMEOUT};
use crate::agents::models::{
    approval_title, AgentApproval, ApprovalDecision, ApprovalOrigin, QuestionItem, QuestionOption, QuestionRequest,
};
use crate::agents::risk::{self, RiskLevel};
use crate::i18n::{tr, trf};
use crate::services::recap::RecapSink;

/// Een toestemmingsvraag van een sessie die Nook draait.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingPermission {
    pub id: String,
    pub run_id: Uuid,
    pub tool: String,
    pub summary: String,
    pub input: Value,
    pub suggestions: Option<Value>,
    pub event_id: Uuid,
    pub created: DateTime<Utc>,
}

impl PendingPermission {
    pub fn can_always(&self) -> bool {
        self.suggestions.as_ref().and_then(Value::as_array).is_some_and(|a| !a.is_empty())
    }
}

/// Een vraag van een agent in een sessie die Nook draait (AskUserQuestion van Claude Code).
#[derive(Debug, Clone, PartialEq)]
pub struct PendingQuestion {
    pub id: String,
    pub run_id: Uuid,
    pub items: Vec<QuestionItem>,
    pub input: Value,
    pub created: DateTime<Utc>,
    /// Asked before Nook restarted: nothing waits for it any more, so the answer goes to the agent as a message.
    pub restored: bool,
}

/// De laatste git-stand die Nook voor een sessie zag.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitSnapshot {
    pub status: Option<GitStatus>,
    pub ahead: Option<u32>,
    pub behind: Option<u32>,
    pub error: Option<String>,
    pub loading: bool,
}

/// Eén rij in het overzicht van worktrees.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeRow {
    pub repo_root: String,
    pub worktree: Worktree,
    pub run_ids: Vec<Uuid>,
    pub changed_files: Option<usize>,
    pub ahead: Option<u32>,
    pub behind: Option<u32>,
    pub base_branch: Option<String>,
}

/// Wat de map van een project is, voor "Nieuwe sessie".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub path: String,
    pub name: String,
    pub verdict: Verdict,
    pub verdict_message: String,
    pub repo_root: Option<String>,
    pub current_branch: Option<String>,
    pub branches: Vec<String>,
    pub default_base: Option<String>,
    pub has_commits: bool,
    pub dirty_files: usize,
    pub is_worktree: bool,
}

#[derive(Debug, Clone)]
#[allow(clippy::large_enum_variant)]
pub enum ManagerEvent {
    /// De lijst sessies of hun stand veranderde.
    Changed,
    /// De tijdlijn van deze sessie veranderde.
    Timeline(Uuid),
    Approval(AgentApproval),
    ApprovalGone(String),
    Question(QuestionRequest),
    QuestionGone(String),
    /// Een beurt is klaar (of mislukt, of gestopt), met het laatste antwoord van de agent.
    TurnFinished(WorkspaceRun, String),
}

/// De omgeving voor een account (profiel-id), zoals `CLAUDE_CONFIG_DIR` of een API-sleutel.
pub type AccountEnvironment = Box<dyn Fn(&str) -> BTreeMap<String, String> + Send + Sync>;

/// Wat de app aan de manager geeft: waar de agents staan, de omgeving per account, de brug.
pub struct Hooks {
    pub executable: Box<dyn Fn(RunProvider) -> Option<String> + Send + Sync>,
    pub account_environment: AccountEnvironment,
    pub bridge: Box<dyn Fn() -> Option<BridgeLaunch> + Send + Sync>,
    /// Waar nieuwe worktrees komen (`~/.nook/worktrees`).
    pub worktree_root: Box<dyn Fn() -> String + Send + Sync>,
    /// "Hervat bij reset" staat standaard aan voor sessies die op een gebruikslimiet stopten.
    pub auto_resume_limited: Box<dyn Fn() -> bool + Send + Sync>,
}

enum Input {
    Line(String),
    Close,
}

struct Proc {
    generation: u64,
    pid: Option<u32>,
    input: Option<mpsc::UnboundedSender<Input>>,
    kill: Option<tokio::sync::oneshot::Sender<()>>,
    /// Codex app-server or ACP: the conversation over JSON-RPC (`driver::Driver`). `None` for a stream or one-shot agent.
    driver: Option<Box<dyn driver::Driver>>,
}

#[derive(Default)]
struct TurnState {
    live_text: Option<Uuid>,
    tool_events: HashMap<String, Uuid>,
    tool_names: HashMap<String, String>,
    tool_inputs: HashMap<String, Value>,
    message_usage: HashMap<String, TokenCounts>,
    last_context: Option<u64>,
    finished: bool,
    stopping: bool,
    last_error: Option<String>,
    started: Option<DateTime<Utc>>,
    live_thinking: Option<Uuid>,
    thinking_open: bool,
    streamed_thinking: Vec<Option<Uuid>>,
    steered: bool,
    steered_usage: Vec<TurnUsage>,
    /// Geblokkeerde limietvensters uit `rate_limit_event`, en wanneer elk vrijkomt.
    limit_windows: BTreeMap<String, Option<DateTime<Utc>>>,
    /// When the latest Claude request started (`PromptCache` / AG-32).
    last_request_at: Option<DateTime<Utc>>,
    /// Cache lifetime reported during this turn in seconds (`PromptCache` / AG-32).
    cache_ttl: Option<f64>,
    /// True when the turn ran a compaction (`PromptCache` / `SizeCompaction` / AG-32).
    compacted: bool,
}

/// A session a search found (`Manager::search`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub run_id: Uuid,
    /// The words around the first match in the conversation; empty when the title matched.
    pub snippet: String,
    pub archived: bool,
}

/// About forty characters on either side of the first place `needle` (lower case) is in `text`, on one line.
pub fn snippet(text: &str, needle: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let at = lower.find(needle)?;
    // Lower-casing can change byte lengths; fall back to the start when the offset is not a boundary in `text`.
    let chars: Vec<char> = text.chars().collect();
    let start_char = lower[..at].chars().count();
    let from = start_char.saturating_sub(40);
    let to = (start_char + needle.chars().count() + 40).min(chars.len());
    let mut out: String = chars[from..to].iter().collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 {
        out.insert(0, '…');
    }
    if to < chars.len() {
        out.push('…');
    }
    Some(out)
}

#[derive(Default)]
struct Inner {
    runs: Vec<WorkspaceRun>,
    events: HashMap<Uuid, Vec<RunEvent>>,
    approvals: HashMap<Uuid, Vec<PendingPermission>>,
    questions: HashMap<Uuid, Vec<PendingQuestion>>,
    queues: BTreeMap<Uuid, MessageQueue>,
    processes: HashMap<Uuid, Proc>,
    turns: HashMap<Uuid, TurnState>,
    git: HashMap<Uuid, GitSnapshot>,
    worktrees: Vec<WorktreeRow>,
    fork_next: HashSet<Uuid>,
    /// Sessions whose failed turn is being tried again in a new conversation (`recoveringConversation`): a second
    /// failure is told as it is.
    recovering: HashSet<Uuid>,
    generation: u64,
    dirty_runs: bool,
    dirty_events: HashSet<Uuid>,
    dirty_queues: bool,
    /// Nook is quitting: no turn starts any more.
    quitting: bool,
    /// `continue_interrupted` ran this launch.
    continued_after_launch: bool,
    /// Beurten die op een gebruikslimiet stopten, met de reset als die bekend is.
    limited: HashMap<Uuid, Option<DateTime<Utc>>>,
    /// Het lopende "hervat bij reset" per sessie (een teller, zodat een oud wachten niets meer doet).
    limit_resumes: HashMap<Uuid, u64>,
    /// The `/` commands each session's agent announced (ACP), kept while Nook runs.
    commands: HashMap<Uuid, Vec<driver::SlashCommand>>,
    /// FIFO queue of turns waiting for a free concurrency slot (`CapacityScheduler` on macOS, AG-75).
    capacity: super::capacity::CapacityScheduler,
    /// Live worktree setup checklist progress per session (in memory only, AG-94).
    worktree_setups: HashMap<Uuid, WorktreeSetupProgress>,
    /// In-flight background worktree preparation task handles, aborted when stopped or deleted (AG-94).
    prepare_tasks: HashMap<Uuid, tokio::task::AbortHandle>,
    /// Last `git fetch` time per normalized `(repo_root, base_branch)` key so fetches happen at most once per 2 minutes.
    remote_base_refreshed: HashMap<String, DateTime<Utc>>,
    /// Sessions currently running an automatic idle/size `/compact` turn (`idleCompacting` on macOS, AG-32).
    idle_compacting: HashSet<Uuid>,
}

type Notify = Box<dyn Fn(ManagerEvent) + Send + Sync>;
type TelemetryProvider = Arc<dyn Fn() -> crate::services::telemetry::OtlpConfig + Send + Sync>;
/// Opens a terminal in `folder` running `command` with tab title `title`, returning a closure that reports whether
/// the terminal is still running (`runScript` on macOS, AG-94).
pub type ScriptRunner = Arc<dyn Fn(&str, &str, &str) -> Option<Box<dyn Fn() -> bool + Send + Sync>> + Send + Sync>;

/// Resolves a per-account executable override (`accountExecutable` on the Mac, CH-98).
pub type AccountExecutable = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;
/// Resolves extra arguments appended to every launch under an account (`accountArguments` on the Mac, CH-98).
pub type AccountArguments = Arc<dyn Fn(&str) -> Vec<String> + Send + Sync>;

pub struct Manager {
    inner: Mutex<Inner>,
    store: RunStore,
    notify: Notify,
    hooks: Hooks,
    git: Option<Git>,
    runtime: tokio::runtime::Handle,
    /// Het weekoverzicht: prompts, tools, beslissingen en beurten.
    pub recap: RecapSink,
    /// Optional resolver for active OTLP telemetry config (AG-33 / SV-05); falls back to settings + process env.
    telemetry_provider: Mutex<Option<TelemetryProvider>>,
    /// Optional runner that opens a visible terminal for `nook.json` `runOnWorktreeCreate` scripts (AG-94).
    script_runner: Mutex<Option<ScriptRunner>>,
    /// Optional per-account executable override (`accountExecutable` on the Mac, CH-98).
    account_executable: Mutex<Option<AccountExecutable>>,
    /// Optional per-account extra arguments (`accountArguments` on the Mac, CH-98).
    account_arguments: Mutex<Option<AccountArguments>>,
}

/// Verzamelt events en stuurt ze pas als de mutex los is.
#[derive(Default)]
struct Out(Vec<ManagerEvent>);

impl Out {
    fn push(&mut self, e: ManagerEvent) {
        self.0.push(e);
    }
}

impl Manager {
    pub fn new(
        directory: std::path::PathBuf,
        hooks: Hooks,
        runtime: tokio::runtime::Handle,
        notify: impl Fn(ManagerEvent) + Send + Sync + 'static,
    ) -> Arc<Self> {
        let store = RunStore::new(directory);
        let mut inner = Inner { runs: store.load_runs(Utc::now()), queues: store.load_queues(), ..Default::default() };
        inner.dirty_runs = inner.runs.iter().any(|r| r.status_detail.as_deref() == Some("interrupted"));
        let manager = Arc::new(Self {
            inner: Mutex::new(inner),
            store,
            notify: Box::new(notify),
            hooks,
            git: Git::locate(),
            runtime,
            recap: RecapSink::default(),
            telemetry_provider: Mutex::new(None),
            script_runner: Mutex::new(None),
            account_executable: Mutex::new(None),
            account_arguments: Mutex::new(None),
        });
        manager.restore_waiting();
        // Na een herstart: wat op de reset van een limiet wachtte, wacht weer.
        let waiting: Vec<Uuid> = manager.runs().iter().filter(|r| r.auto_resume && r.limit_reset_at.is_some()).map(|r| r.id).collect();
        for id in waiting {
            manager.arm_limit_resume(id);
        }
        manager
    }

    /// Registers a per-account executable override resolver (`accountExecutable` on the Mac, CH-98).
    pub fn set_account_executable(&self, resolver: impl Fn(&str) -> Option<String> + Send + Sync + 'static) {
        *self.account_executable.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(resolver));
    }

    /// Registers a per-account extra launch arguments resolver (`accountArguments` on the Mac, CH-98).
    pub fn set_account_arguments(&self, resolver: impl Fn(&str) -> Vec<String> + Send + Sync + 'static) {
        *self.account_arguments.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(resolver));
    }

    fn resolve_executable(&self, provider: RunProvider, profile_id: &str) -> Option<String> {
        if !profile_id.is_empty() {
            if let Some(resolver) = self.account_executable.lock().unwrap_or_else(|e| e.into_inner()).clone() {
                if let Some(own) = resolver(profile_id) {
                    return Some(own);
                }
            }
            if provider == RunProvider::Acp {
                if let Some(agent) = super::custom_agents::CustomAgents::agent_for(profile_id) {
                    return Some(super::custom_agents::CustomAgents::find_executable(&agent.command).unwrap_or(agent.command));
                }
            }
        }
        (self.hooks.executable)(provider)
    }

    fn resolve_account_arguments(&self, profile_id: &str) -> Vec<String> {
        if profile_id.is_empty() {
            return Vec::new();
        }
        self.account_arguments.lock().unwrap_or_else(|e| e.into_inner()).clone().map(|r| r(profile_id)).unwrap_or_default()
    }

    /// Registers the host app's terminal launcher for `runOnWorktreeCreate` project scripts (AG-94).
    pub fn set_script_runner(
        &self,
        runner: impl Fn(&str, &str, &str) -> Option<Box<dyn Fn() -> bool + Send + Sync>> + Send + Sync + 'static,
    ) {
        *self.script_runner.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(runner));
    }

    fn run_setup_script(&self, folder: &str, command: &str, title: &str) -> Option<Box<dyn Fn() -> bool + Send + Sync>> {
        let runner = self.script_runner.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        runner(folder, command, title)
    }

    /// The worktree setup checklist currently visible for `id`, matching macOS `visibleSetup(_:)`.
    pub fn visible_setup(&self, id: Uuid) -> Option<WorktreeSetupProgress> {
        let s = self.lock();
        let run = s.runs.iter().find(|r| r.id == id)?;
        Self::visible_setup_in(&s, run)
    }

    /// All currently visible worktree setup checklists keyed by session id (sent in `workspace_overview`).
    pub fn visible_setups(&self) -> HashMap<Uuid, WorktreeSetupProgress> {
        let s = self.lock();
        let mut out = HashMap::new();
        for run in &s.runs {
            if let Some(progress) = Self::visible_setup_in(&s, run) {
                out.insert(run.id, progress);
            }
        }
        out
    }

    fn visible_setup_in(s: &Inner, run: &WorkspaceRun) -> Option<WorktreeSetupProgress> {
        let progress = s.worktree_setups.get(&run.id)?;
        if run.status.is_active() || run.status == RunStatus::Failed || run.status == RunStatus::Stopped {
            return Some(progress.clone());
        }
        None
    }

    /// Whether `base` in `root` needs a fresh `git fetch` (at most once every two minutes per repo & base).
    pub fn should_refresh_remote_base(&self, root: &str, base: &str, now: DateTime<Utc>) -> bool {
        let key = format!("{}\n{base}", paths::normalize(root));
        let mut s = self.lock();
        if let Some(&last) = s.remote_base_refreshed.get(&key) {
            let elapsed = (now - last).to_std().unwrap_or_default();
            if elapsed < REMOTE_BASE_REFRESH_TTL {
                return false;
            }
        }
        s.remote_base_refreshed.insert(key, now);
        true
    }

    fn setup_step(&self, id: Uuid, change: impl FnOnce(&mut WorktreeSetupProgress)) {
        let changed = {
            let mut s = self.lock();
            if let Some(progress) = s.worktree_setups.get_mut(&id) {
                change(progress);
                true
            } else {
                false
            }
        };
        if changed {
            self.emit(Out(vec![ManagerEvent::Changed]));
        }
    }

    /// Called when an event is appended to `id`: the agent's first real output ends `StartAgent` and clears the checklist.
    fn note_setup_event(s: &mut Inner, id: Uuid, event: &RunEvent, out: &mut Out) {
        let Some(progress) = s.worktree_setups.get_mut(&id) else { return };
        if !progress.is_running(SetupStep::StartAgent) {
            return;
        }
        match event.kind {
            EventKind::Assistant
            | EventKind::Thinking
            | EventKind::Tool
            | EventKind::FileChange
            | EventKind::Approval
            | EventKind::Result => {
                s.worktree_setups.remove(&id);
                out.push(ManagerEvent::Changed);
            }
            EventKind::Error => {
                progress.fail(SetupStep::StartAgent, event.text.clone());
                out.push(ManagerEvent::Changed);
            }
            EventKind::User | EventKind::System => {}
        }
    }

    /// Clears a finished/failed/stopped setup checklist when a later turn begins; keeps it for the initial preparing turn.
    fn drop_finished_setup(s: &mut Inner, id: Uuid) {
        let keep = s.worktree_setups.get(&id).is_some_and(|p| p.is_running(SetupStep::StartAgent))
            && s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.status == RunStatus::Preparing);
        if !keep {
            s.worktree_setups.remove(&id);
        }
    }

    /// Registers a live resolver for OpenTelemetry export settings (including keychain headers from the host app).
    pub fn set_telemetry_provider(&self, provider: impl Fn() -> crate::services::telemetry::OtlpConfig + Send + Sync + 'static) {
        *self.telemetry_provider.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(provider));
    }

    pub fn has_telemetry_provider(&self) -> bool {
        self.telemetry_provider.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    fn resolve_telemetry(&self) -> crate::services::telemetry::OtlpConfig {
        if let Some(provider) = self.telemetry_provider.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return provider();
        }
        if cfg!(test) {
            return crate::services::telemetry::OtlpConfig::default();
        }
        let saved = crate::settings::Settings::load_from(&crate::paths::settings_file()).telemetry;
        crate::services::telemetry::OtlpConfig::resolve_process(&saved, "")
    }

    /// Whether `id` is currently waiting in the FIFO queue for a free working session slot (AG-75).
    pub fn is_waiting_for_capacity(&self, id: Uuid) -> bool {
        self.lock().capacity.is_waiting(id)
    }

    /// Holds a turn in FIFO order when `max_working_sessions` is reached; returns `true` when queued.
    fn wait_for_capacity(&self, id: Uuid, prompt: &str, executable: &str, show_prompt: bool) -> bool {
        let limit = super::capacity::max_working_sessions();
        if limit == 0 {
            return false;
        }
        let mut out = Out::default();
        {
            let mut s = self.lock();
            if s.capacity.is_waiting(id) {
                return false;
            }
            let Some(status) = s.runs.iter().find(|r| r.id == id).map(|r| r.status) else {
                return false;
            };
            if status.is_active() && status != RunStatus::Preparing {
                return false;
            }
            let others_working = s.runs.iter().filter(|r| r.id != id && r.status.is_active() && !s.capacity.is_waiting(r.id)).count();
            if !super::capacity::must_wait(limit, others_working) {
                return false;
            }
            Self::load_timeline(&self.store, &mut s, id);
            if show_prompt {
                Self::append(&mut s, id, RunEvent::new(EventKind::User, prompt.to_string()), &mut out);
            }
            s.capacity.add(id, prompt.to_string(), executable.to_string());
            let waiting_text = trf(
                "Wacht: er werken al {limit} sessies. Deze beurt start zodra er een klaar is (Instellingen › Agents › Sessies).",
                "Waiting: {limit} sessions are already working. This turn starts as soon as one of them is done (Settings › Agents › Sessions).",
                &[("limit", &limit)],
            );
            Self::update(&mut s, id, |r| {
                r.move_to(RunStatus::Preparing, Some(waiting_text.clone()), Utc::now());
            });
            Self::append(&mut s, id, RunEvent::new(EventKind::System, waiting_text), &mut out);
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        true
    }

    /// Starts waiting turns (oldest first) as far as `max_working_sessions` now allows.
    pub fn start_waiting_turns(self: &Arc<Self>) {
        let ready = {
            let mut s = self.lock();
            if s.capacity.is_empty() {
                return;
            }
            let existing: HashSet<Uuid> = s.runs.iter().map(|r| r.id).collect();
            s.capacity.prune(|id| existing.contains(&id));
            let working = s.runs.iter().filter(|r| r.status.is_active() && !s.capacity.is_waiting(r.id)).count();
            let limit = super::capacity::max_working_sessions();
            s.capacity.dequeue_ready(limit, working)
        };
        for (id, turn) in ready {
            self.launch_turn(id, turn.prompt, turn.executable, false);
        }
    }

    /// Cancels a turn waiting for a concurrency slot so it never starts.
    fn cancel_waiting_turn(&self, id: Uuid) -> bool {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            if s.capacity.remove(id).is_none() {
                return false;
            }
            Self::update(&mut s, id, |r| {
                r.move_to(RunStatus::Stopped, None, Utc::now());
            });
            Self::append(&mut s, id, RunEvent::new(EventKind::System, tr("Gestopt.", "Stopped.")), &mut out);
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        true
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn emit(&self, out: Out) {
        for e in out.0 {
            (self.notify)(e);
        }
    }

    pub fn git_available(&self) -> bool {
        self.git.is_some()
    }

    // MARK: Lezen

    pub fn runs(&self) -> Vec<WorkspaceRun> {
        self.lock().runs.clone()
    }

    pub fn run(&self, id: Uuid) -> Option<WorkspaceRun> {
        self.lock().runs.iter().find(|r| r.id == id).cloned()
    }

    pub fn timeline(&self, id: Uuid) -> Vec<RunEvent> {
        let mut s = self.lock();
        Self::load_timeline(&self.store, &mut s, id);
        s.events.get(&id).cloned().unwrap_or_default()
    }

    /// Every session whose title or conversation holds `query` (`TimelineSearch` across sessions, #1498), archived
    /// ones too, newest first: the run and the words around the first match. Timelines not open are read from disk
    /// without being kept.
    pub fn search(&self, query: &str, limit: usize) -> Vec<SearchHit> {
        let needle = query.trim().to_lowercase();
        if needle.chars().count() < 2 {
            return vec![];
        }
        let mut runs = self.lock().runs.clone();
        runs.sort_by_key(|b| std::cmp::Reverse(b.updated_at));
        let mut hits = vec![];
        for run in runs {
            if hits.len() >= limit {
                break;
            }
            if run.title.to_lowercase().contains(&needle) {
                hits.push(SearchHit { run_id: run.id, snippet: String::new(), archived: run.archived });
                continue;
            }
            let loaded = self.lock().events.get(&run.id).cloned();
            let events = loaded.unwrap_or_else(|| self.store.load_events(run.id));
            let found =
                events.iter().filter(|e| matches!(e.kind, EventKind::User | EventKind::Assistant)).find_map(|e| snippet(&e.text, &needle));
            if let Some(snippet) = found {
                hits.push(SearchHit { run_id: run.id, snippet, archived: run.archived });
            }
        }
        hits
    }

    fn load_timeline(store: &RunStore, s: &mut Inner, id: Uuid) {
        s.events.entry(id).or_insert_with(|| store.load_events(id));
    }

    pub fn queue(&self, id: Uuid) -> MessageQueue {
        self.lock().queues.get(&id).cloned().unwrap_or_default()
    }

    pub fn git_snapshot(&self, id: Uuid) -> Option<GitSnapshot> {
        self.lock().git.get(&id).cloned()
    }

    pub fn worktree_rows(&self) -> Vec<WorktreeRow> {
        self.lock().worktrees.clone()
    }

    pub fn is_running(&self, id: Uuid) -> bool {
        self.lock().processes.contains_key(&id)
    }

    pub fn usage_report(&self, filter: &UsageFilter) -> UsageReport {
        UsageReport::make(&self.runs(), filter, chrono::Local::now().date_naive())
    }

    /// Alle toestemmingsvragen van sessies, zoals de balk en de tab Agents ze tonen.
    pub fn pending_approvals(&self) -> Vec<AgentApproval> {
        let s = self.lock();
        let mut list = vec![];
        for run in &s.runs {
            for p in s.approvals.get(&run.id).into_iter().flatten() {
                list.push(Self::approval_view(run, p));
            }
        }
        list
    }

    fn approval_view(run: &WorkspaceRun, p: &PendingPermission) -> AgentApproval {
        let command = tool_summary::command(&p.input);
        let assessment = command
            .as_deref()
            .map(risk::assess)
            .unwrap_or_else(|| risk::CommandAssessment::review(tr("Lees het even na", "Read it over first")));
        let edit = crate::agents::hub::edit_diff(&p.tool, &p.input);
        let danger = assessment.level == RiskLevel::Danger;
        // An MCP tool by its readable name and server (in the title), with every argument it gets.
        let mcp = crate::agents::mcp_name::McpToolName::parse(&p.tool);
        let arguments = if mcp.is_some() { crate::agents::mcp_name::arguments(&p.input) } else { String::new() };
        let note = if mcp.is_some() && !danger { crate::agents::hub::MCP_NOTE.to_string() } else { assessment.note.clone() };
        AgentApproval {
            id: format!("run-{}", p.id),
            origin: ApprovalOrigin::Run { run_id: run.id.to_string(), request_id: p.id.clone() },
            agent_name: run.provider.display_name().into(),
            project: run.title.clone(),
            tool: p.tool.clone(),
            title: if danger { assessment.title.clone() } else { approval_title(run.provider.display_name(), &p.tool) },
            command: if arguments.is_empty() { command.unwrap_or_else(|| p.summary.clone()) } else { arguments },
            diff: edit.map(|e| e.0).unwrap_or_default(),
            note,
            danger,
            can_always: p.can_always(),
            can_terminal: false,
            session_key: format!("run:{}", run.id),
            created: p.created,
            always_scope: if p.can_always() {
                crate::agents::permission_scope::preview(&crate::agents::permission_scope::rules(p.suggestions.as_ref()))
            } else {
                None
            },
        }
    }

    /// De toestemmingsvragen van één sessie, zoals de agent ze stuurde (voor de companion).
    pub fn permissions(&self, id: Uuid) -> Vec<PendingPermission> {
        self.lock().approvals.get(&id).cloned().unwrap_or_default()
    }

    pub fn questions(&self, id: Uuid) -> Vec<PendingQuestion> {
        self.lock().questions.get(&id).cloned().unwrap_or_default()
    }

    /// Het laatste antwoord van de agent in een sessie.
    pub fn last_answer(&self, id: Uuid) -> String {
        let mut s = self.lock();
        Self::load_timeline(&self.store, &mut s, id);
        s.events.get(&id).and_then(|l| l.iter().rev().find(|e| e.kind == EventKind::Assistant)).map(|e| e.text.clone()).unwrap_or_default()
    }

    pub fn pending_questions(&self) -> Vec<QuestionRequest> {
        let s = self.lock();
        let mut list = vec![];
        for run in &s.runs {
            for q in s.questions.get(&run.id).into_iter().flatten() {
                list.push(Self::question_view(run, q));
            }
        }
        list
    }

    fn question_view(run: &WorkspaceRun, q: &PendingQuestion) -> QuestionRequest {
        QuestionRequest {
            id: format!("runq:{}:{}", run.id, q.id),
            session_key: format!("run:{}", run.id),
            agent_name: run.provider.display_name().into(),
            project: run.title.clone(),
            items: q.items.clone(),
            restored: q.restored,
        }
    }

    /// Andere actieve sessies in dezelfde map: gelijktijdig bewerken kan botsen.
    fn active_sharing(s: &Inner, directory: &str, except: Option<Uuid>) -> Option<WorkspaceRun> {
        let target = paths::normalize(directory);
        s.runs.iter().find(|r| Some(r.id) != except && r.status.is_active() && paths::normalize(&r.working_directory) == target).cloned()
    }

    // MARK: Project bekijken

    /// Wat "Nieuwe sessie" van een map moet weten. Blokkeert even (git): draai op de achtergrond.
    pub fn inspect_project(&self, path: &str) -> ProjectInfo {
        let normalized = paths::normalize(path);
        let verdict = paths::verdict(&normalized);
        let mut info = ProjectInfo {
            path: normalized.clone(),
            name: crate::agents::text::project_name(&normalized),
            verdict,
            verdict_message: verdict.message(&normalized),
            repo_root: None,
            current_branch: None,
            branches: vec![],
            default_base: None,
            has_commits: false,
            dirty_files: 0,
            is_worktree: false,
        };
        let Some(git) = &self.git else { return info };
        if verdict != Verdict::Ok {
            return info;
        }
        let Some(root) = git.repository_root(&normalized) else { return info };
        info.repo_root = Some(root.clone());
        let current = git.current_branch(&root);
        info.current_branch = current.clone();
        info.has_commits = git.has_commits(&root);
        if let Ok((local, remote)) = git.branches(&root) {
            info.default_base = git.default_base_branch(&root, Some(&local), current);
            info.branches = local.into_iter().chain(remote).collect();
        }
        info.dirty_files = git.changed_file_count(&root).unwrap_or(0);
        if let Some(common) = git.common_directory(&root) {
            let parent = Path::new(&common).parent().map(|p| paths::normalize(&p.to_string_lossy())).unwrap_or_default();
            info.is_worktree = parent != paths::normalize(&root);
        }
        if let Some(base) = info.default_base.clone().filter(|b| b.contains('/')) {
            if self.should_refresh_remote_base(&root, &base, Utc::now()) {
                let git = Clone::clone(git);
                let root = root.clone();
                self.runtime.spawn_blocking(move || {
                    let _ = git.refresh_remote_base(&base, &root, Duration::from_secs(20));
                });
            }
        }
        info
    }

    // MARK: Nieuwe sessie

    /// Controleert de invoer, zet map of worktree klaar en start de agent. Voor een worktree opent de sessie direct
    /// met een live checklist (`WorktreeSetupProgress`, AG-94): ophalen van de basisbranch (max 5 s), uitchecken,
    /// eventuele setup-scripts (`nook.json`), en daarna de agent.
    pub fn start(self: &Arc<Self>, config: NewRunConfig, allow_shared_folder: bool) -> Result<Uuid, String> {
        if let Some(problem) = config.problem() {
            return Err(problem.message().into());
        }
        let project = paths::normalize(&config.project_path);
        let verdict = paths::verdict(&project);
        if verdict != Verdict::Ok {
            return Err(verdict.message(&project));
        }
        self.check_supported(config.provider)?;
        let executable = self.resolve_executable(config.provider, &config.profile_id).ok_or_else(|| {
            trf("{agent} staat niet op deze computer.", "{agent} is not on this computer.", &[("agent", &config.provider.display_name())])
        })?;
        let id = Uuid::new_v4();
        let mut working = project.clone();
        let repo_root = self.git.as_ref().and_then(|g| g.repository_root(&project));
        let mut branch = None;
        let mut worktree = None;
        if config.isolation == IsolationMode::Worktree {
            let _git = self.git.as_ref().ok_or(tr(
                "Git is niet gevonden. Installeer git en probeer het opnieuw.",
                "Git was not found. Install git and try again.",
            ))?;
            let root = repo_root.clone().ok_or(tr("Deze map is geen git-repository.", "This folder is not a git repository."))?;
            let root_folder = if config.worktree_root.is_empty() { (self.hooks.worktree_root)() } else { config.worktree_root.clone() };
            let repo_name = crate::agents::text::project_name(&root);
            let reserved: HashSet<String> = self.lock().runs.iter().filter_map(|r| r.worktree_path.clone()).collect();
            let path = worktree_path(&paths::normalize(&root_folder), &repo_name, &slug(&config.branch_name.replace('/', "-"), 60), |p| {
                reserved.contains(p) || Path::new(p).exists()
            });
            working = path.clone();
            worktree = Some(path);
            branch = Some(config.branch_name.clone());
        } else {
            if !allow_shared_folder {
                if let Some(other) = Self::active_sharing(&self.lock(), &project, None) {
                    return Err(trf(
                        "De sessie '{title}' werkt al in deze map. Kies een worktree, of bevestig dat ze de map mogen delen.",
                        "The session '{title}' already works in this folder. Choose a worktree, or confirm that they may share the folder.",
                        &[("title", &other.title)],
                    ));
                }
            }
            if repo_root.is_some() {
                branch = self.git.as_ref().and_then(|g| g.current_branch(&project));
            }
        }
        let now = Utc::now();
        let title = config.title.trim();
        let mut run = WorkspaceRun {
            id,
            title: if title.is_empty() { title_from(&config.task, 60) } else { title.into() },
            task: config.task.clone(),
            provider: config.provider,
            profile_id: config.profile_id.clone(),
            model: config.model.trim().into(),
            resolved_model: None,
            mode: config.mode,
            permission: config.permission,
            isolation: config.isolation,
            project_path: repo_root.clone().unwrap_or_else(|| project.clone()),
            working_directory: working,
            repo_root: repo_root.clone(),
            branch: branch.clone(),
            base_branch: (config.isolation == IsolationMode::Worktree).then(|| config.base_branch.clone()),
            worktree_path: worktree.clone(),
            instructions: config.instructions.clone(),
            status: RunStatus::Preparing,
            status_detail: None,
            provider_session_id: None,
            created_at: now,
            updated_at: now,
            archived: false,
            usage: RunUsage::default(),
            turn_started_at: Some(now),
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            lines_added: None,
            lines_removed: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: config.effort.clone(),
            pending_handoff: None,
            conversation: None,
            pending_rollback: None,
            goal: None,
            compacting: false,
            tasks: None,
            restart: Default::default(),
            prompt_cache: None,
        };
        if worktree.is_none() && rollback::can_roll_back(run.provider) {
            run.checkpoints.push(RunCheckpoint { r#ref: String::new(), date: Utc::now(), conversation: Some(ConversationMark::empty()) });
        }
        let mut out = Out::default();
        {
            let mut s = self.lock();
            s.runs.insert(0, run);
            s.events.insert(id, vec![]);
            s.dirty_runs = true;
            if let Some(path) = &worktree {
                s.worktree_setups.insert(id, WorktreeSetupProgress::new(now));
                Self::append(
                    &mut s,
                    id,
                    RunEvent::new(
                        EventKind::System,
                        trf(
                            "Worktree gemaakt: branch {branch} in {path}",
                            "Worktree created: branch {branch} in {path}",
                            &[("branch", &branch.clone().unwrap_or_default()), ("path", &crate::agents::tilde(path))],
                        ),
                    ),
                    &mut out,
                );
                if !config.task.trim().is_empty() {
                    Self::append(&mut s, id, RunEvent::new(EventKind::User, config.task.clone()), &mut out);
                }
            }
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        if let (Some(path), Some(root)) = (worktree, repo_root) {
            self.prepare_worktree_and_launch(id, root, path, branch.unwrap_or_default(), config.base_branch, config.task, executable);
        } else {
            self.launch_turn(id, config.task.clone(), executable, true);
        }
        Ok(id)
    }

    /// Creates the session's worktree asynchronously, updating [`WorktreeSetupProgress`] after each real step:
    /// 5-second capped remote-base fetch, `git worktree add`, `nook.json` setup scripts (blocking when `async: false`),
    /// initial checkpoint, and launching the first turn (`prepareWorktreeAndLaunch` on macOS, AG-94).
    #[allow(clippy::too_many_arguments)]
    fn prepare_worktree_and_launch(
        self: &Arc<Self>,
        id: Uuid,
        root: String,
        path: String,
        branch: String,
        base: String,
        prompt: String,
        executable: String,
    ) {
        let Some(git) = self.git.clone() else { return };
        let refresh_base = self.should_refresh_remote_base(&root, &base, Utc::now());
        let manager = self.clone();
        let handle = self.runtime.spawn(async move {
            let fetches = refresh_base && base.contains('/');
            if fetches {
                manager.setup_step(id, |p| p.begin(SetupStep::FetchBase, Utc::now()));
                let git_fetch = Clone::clone(&git);
                let base_fetch = base.clone();
                let root_fetch = root.clone();
                let fetched =
                    tokio::task::spawn_blocking(move || git_fetch.refresh_remote_base(&base_fetch, &root_fetch, START_FETCH_TIMEOUT)).await;
                if let Ok(result) = fetched {
                    let checkout_start = Utc::now();
                    manager.setup_step(id, |p| {
                        p.record_fetch(&result, &base, checkout_start);
                        p.begin(SetupStep::CheckOut, checkout_start);
                    });
                } else {
                    manager.setup_step(id, |p| p.begin(SetupStep::CheckOut, Utc::now()));
                }
            } else {
                let now = Utc::now();
                manager.setup_step(id, |p| {
                    p.skip(SetupStep::FetchBase);
                    if base.contains('/') {
                        p.note_fetched_recently(&base);
                    } else {
                        p.note_local_base(&base);
                    }
                    p.begin(SetupStep::CheckOut, now);
                });
            }

            let git_wt = Clone::clone(&git);
            let root_wt = root.clone();
            let path_wt = path.clone();
            let branch_wt = branch.clone();
            let base_wt = base.clone();
            let created = tokio::task::spawn_blocking(move || git_wt.add_worktree(&root_wt, &path_wt, &branch_wt, &base_wt)).await;
            let err = match created {
                Ok(Ok(())) => None,
                Ok(Err(e)) => Some(e.0),
                Err(e) => Some(e.to_string()),
            };
            if let Some(message) = err {
                let mut out = Out::default();
                {
                    let mut s = manager.lock();
                    s.prepare_tasks.remove(&id);
                    if !s.runs.iter().any(|r| r.id == id) {
                        return;
                    }
                    if let Some(progress) = s.worktree_setups.get_mut(&id) {
                        let step = if progress.is_running(SetupStep::FetchBase) { SetupStep::FetchBase } else { SetupStep::CheckOut };
                        progress.fail(step, message.clone());
                    }
                    Self::update(&mut s, id, |r| {
                        r.worktree_path = None;
                        r.working_directory = root.clone();
                        r.move_to(RunStatus::Failed, Some(message.clone()), Utc::now());
                    });
                    Self::append(&mut s, id, RunEvent::new(EventKind::Error, message), &mut out);
                    out.push(ManagerEvent::Changed);
                }
                manager.emit(out);
                return;
            }

            manager.setup_step(id, |p| {
                p.finish(SetupStep::CheckOut, Utc::now());
                p.note_checkout(&branch, &base, &crate::agents::tilde(&path));
            });

            if !manager.run(id).is_some_and(|r| r.status == RunStatus::Preparing) {
                return;
            }

            let path_scripts = path.clone();
            let loaded = tokio::task::spawn_blocking(move || terminal::load_scripts(&path_scripts)).await.unwrap_or_default();
            let (scripts, holds_agent) = terminal::setup_scripts(&loaded);

            if !manager.run(id).is_some_and(|r| r.status == RunStatus::Preparing) {
                return;
            }

            let holds = holds_agent && !prompt.trim().is_empty();
            manager.setup_step(id, |p| {
                if scripts.is_empty() {
                    p.skip(SetupStep::RunSetup);
                    p.note_no_script();
                } else {
                    p.begin(SetupStep::RunSetup, Utc::now());
                    for script in &scripts {
                        p.note_script(&script.name, script.async_run);
                    }
                }
            });

            if !holds {
                manager.lock().prepare_tasks.remove(&id);
                manager.start_first_turn(id, prompt.clone(), executable.clone());
            }

            // Capture the initial checkpoint at HEAD before the agent modifies files.
            let cp_ref = git::checkpoint_ref(&id.to_string(), 0);
            let git_cp = Clone::clone(&git);
            let path_cp = path.clone();
            let cp_ref_run = cp_ref.clone();
            let made_cp = tokio::task::spawn_blocking(move || git_cp.checkpoint_head(&path_cp, &cp_ref_run).is_ok()).await.unwrap_or(false);
            if made_cp {
                let mut s = manager.lock();
                Self::update(&mut s, id, |r| {
                    if !r.checkpoints.iter().any(|c| c.r#ref == cp_ref) {
                        r.checkpoints
                            .insert(0, RunCheckpoint { r#ref: cp_ref, date: Utc::now(), conversation: Some(ConversationMark::empty()) });
                    }
                });
            }

            if manager.run(id).is_none() {
                return;
            }

            let failure = manager.start_setup_scripts(id, &path, &scripts).await;
            manager.setup_step(id, |p| {
                if !p.is_running(SetupStep::RunSetup) {
                    return;
                }
                if let Some(msg) = &failure {
                    p.fail(SetupStep::RunSetup, msg.clone());
                } else {
                    p.finish(SetupStep::RunSetup, Utc::now());
                }
            });

            if !holds || !manager.run(id).is_some_and(|r| r.status == RunStatus::Preparing) {
                return;
            }
            manager.lock().prepare_tasks.remove(&id);
            if let Some(msg) = failure {
                let mut out = Out::default();
                {
                    let mut s = manager.lock();
                    Self::update(&mut s, id, |r| {
                        r.move_to(RunStatus::Failed, Some(msg.clone()), Utc::now());
                    });
                    Self::append(&mut s, id, RunEvent::new(EventKind::Error, msg), &mut out);
                    out.push(ManagerEvent::Changed);
                }
                manager.emit(out);
                return;
            }
            manager.start_first_turn(id, prompt, executable);
        });
        let mut s = self.lock();
        if let Some(prev) = s.prepare_tasks.insert(id, handle.abort_handle()) {
            prev.abort();
        }
    }

    fn start_first_turn(self: &Arc<Self>, id: Uuid, prompt: String, executable: String) {
        if prompt.trim().is_empty() {
            self.setup_step(id, |p| p.skip(SetupStep::StartAgent));
            let mut out = Out::default();
            {
                let mut s = self.lock();
                Self::update(&mut s, id, |r| {
                    r.status = RunStatus::Completed;
                    r.turn_started_at = None;
                });
                out.push(ManagerEvent::Changed);
            }
            self.emit(out);
        } else {
            self.setup_step(id, |p| p.begin(SetupStep::StartAgent, Utc::now()));
            self.launch_turn(id, prompt, executable, false);
        }
    }

    /// Runs `runOnWorktreeCreate` scripts in visible terminals and waits for any `"async": false` scripts to exit.
    /// Returns `None` on success (or if no script blocks), or an error string if a blocking script fails or is closed.
    async fn start_setup_scripts(&self, id: Uuid, path: &str, scripts: &[ProjectScript]) -> Option<String> {
        type WaitingScript = (String, std::path::PathBuf, Box<dyn Fn() -> bool + Send + Sync>);
        let mut waiting: Vec<WaitingScript> = Vec::new();
        for script in scripts {
            if script.async_run {
                let _ = self.run_setup_script(path, &script.command, &script.name);
                let mut out = Out::default();
                Self::append(
                    &mut self.lock(),
                    id,
                    RunEvent::new(
                        EventKind::System,
                        trf("Setup-script gestart: {name}", "Setup script started: {name}", &[("name", &script.name)]),
                    ),
                    &mut out,
                );
                self.emit(out);
                continue;
            }
            let status_path = std::env::temp_dir().join(format!("nook-setup-{}", Uuid::new_v4()));
            let wrapped = terminal::blocking_command(&script.command, &status_path.to_string_lossy(), cfg!(windows));
            let Some(is_open) = self.run_setup_script(path, &wrapped, &script.name) else {
                continue;
            };
            let mut out = Out::default();
            Self::append(
                &mut self.lock(),
                id,
                RunEvent::new(
                    EventKind::System,
                    trf("Wacht op setup-script: {name}", "Waiting for setup script: {name}", &[("name", &script.name)]),
                ),
                &mut out,
            );
            self.emit(out);
            waiting.push((script.name.clone(), status_path, is_open));
        }
        let mut failure: Option<String> = None;
        for (name, status_path, is_open) in waiting {
            loop {
                let still_open = is_open();
                let bytes = std::fs::read(&status_path).ok();
                if let Some(code) = terminal::exit_status(bytes.as_deref()) {
                    if code != 0 && failure.is_none() {
                        failure = Some(trf(
                            "Setup-script '{name}' mislukte (afsluitcode {code}).",
                            "Setup script '{name}' failed (exit code {code}).",
                            &[("name", &name), ("code", &code)],
                        ));
                    }
                    break;
                }
                if !still_open {
                    if failure.is_none() {
                        failure = Some(trf(
                            "Setup-script '{name}' is gesloten voordat het klaar was.",
                            "Setup script '{name}' was closed before it finished.",
                            &[("name", &name)],
                        ));
                    }
                    break;
                }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            let _ = std::fs::remove_file(&status_path);
        }
        failure
    }

    /// Every agent runs here: Claude Code over its stream, Codex over app-server, the rest over ACP (`driver`).
    fn check_supported(&self, _provider: RunProvider) -> Result<(), String> {
        Ok(())
    }

    /// Neemt een bestaand gesprek van een agent over als sessie in Nook. Er start nog niets: het eerste bericht gaat
    /// verder met dat gesprek. `fork`: die eerste beurt wordt een kopie (alleen Claude Code), zodat een gesprek dat
    /// elders nog loopt nooit twee keer beschreven wordt. Al overgenomen? Dan die sessie.
    pub fn adopt(
        &self,
        provider: RunProvider,
        session_id: &str,
        profile_id: &str,
        directory: &str,
        title: &str,
        history: Vec<(EventKind, String)>,
        fork: bool,
    ) -> Result<Uuid, String> {
        if !fork {
            let mut s = self.lock();
            if let Some(existing) =
                s.runs.iter_mut().find(|r| r.provider == provider && r.provider_session_id.as_deref() == Some(session_id))
            {
                existing.archived = false;
                let id = existing.id;
                s.dirty_runs = true;
                return Ok(id);
            }
        }
        let project = paths::normalize(directory);
        let verdict = paths::verdict(&project);
        if verdict != Verdict::Ok {
            return Err(verdict.message(&project));
        }
        self.check_supported(provider)?;
        if self.resolve_executable(provider, profile_id).is_none() {
            return Err(trf(
                "{agent} staat niet op deze computer.",
                "{agent} is not on this computer.",
                &[("agent", &provider.display_name())],
            ));
        }
        let repo_root = self.git.as_ref().and_then(|g| g.repository_root(&project));
        let branch = repo_root.as_ref().and_then(|_| self.git.as_ref().and_then(|g| g.current_branch(&project)));
        let id = Uuid::new_v4();
        let now = Utc::now();
        let clean = title.trim();
        let run = WorkspaceRun {
            id,
            title: if clean.is_empty() { crate::agents::text::project_name(&project) } else { title_from(clean, 60) },
            task: clean.into(),
            provider,
            profile_id: profile_id.into(),
            model: String::new(),
            resolved_model: None,
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            isolation: IsolationMode::Folder,
            project_path: project.clone(),
            working_directory: project,
            repo_root,
            branch,
            base_branch: None,
            worktree_path: None,
            instructions: String::new(),
            status: RunStatus::Completed,
            status_detail: None,
            provider_session_id: Some(session_id.into()),
            created_at: now,
            updated_at: now,
            archived: false,
            usage: RunUsage::default(),
            turn_started_at: None,
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            lines_added: None,
            lines_removed: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: None,
            pending_handoff: None,
            conversation: None,
            pending_rollback: None,
            goal: None,
            compacting: false,
            tasks: None,
            restart: Default::default(),
            prompt_cache: None,
        };
        let mut out = Out::default();
        {
            let mut s = self.lock();
            s.runs.insert(0, run);
            s.events.insert(id, vec![]);
            if fork {
                s.fork_next.insert(id);
            }
            for (kind, text) in history.into_iter().filter(|(_, t)| !t.is_empty()) {
                let mut e = RunEvent::new(kind, text);
                if kind == EventKind::Assistant {
                    e.state = Some(EventState::Done);
                }
                Self::append(&mut s, id, e, &mut out);
            }
            let text = if fork {
                trf(
                    "Kopie in Nook: je volgende bericht start een kopie van dit gesprek met {agent}; het origineel loopt ongestoord door.",
                    "Copy in Nook: your next message starts a copy of this conversation with {agent}; the original carries on undisturbed.",
                    &[("agent", &provider.display_name())],
                )
            } else {
                trf(
                    "Overgenomen in Nook: dit gesprek gaat hier verder met {agent}.",
                    "Taken over in Nook: this conversation continues here with {agent}.",
                    &[("agent", &provider.display_name())],
                )
            };
            Self::append(&mut s, id, RunEvent::new(EventKind::System, text), &mut out);
            s.dirty_runs = true;
        }
        out.push(ManagerEvent::Changed);
        self.emit(out);
        Ok(id)
    }

    /// Hoe de volgende beurt draait: modus, rechten, model en redeneerniveau. Alleen tussen beurten.
    pub fn configure(
        &self,
        id: Uuid,
        mode: Option<ExecutionMode>,
        permission: Option<PermissionPolicy>,
        model: Option<String>,
        effort: Option<Option<String>>,
    ) {
        let mut s = self.lock();
        let Some(run) = s.runs.iter_mut().find(|r| r.id == id) else { return };
        if run.status.is_active() {
            return;
        }
        if let Some(m) = mode {
            run.mode = m;
        }
        if let Some(p) = permission.filter(|p| run.provider.capabilities().policies.contains(p)) {
            run.permission = p;
        }
        if let Some(m) = model {
            run.model = m.trim().into();
        }
        if let Some(e) = effort {
            run.effort = e.filter(|e| !e.is_empty());
        }
        s.dirty_runs = true;
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    // MARK: Beurten

    /// Een vervolgbericht. Kan alleen als de vorige beurt klaar is; anders gaat het in de wachtrij.
    pub fn send(self: &Arc<Self>, id: Uuid, text: &str) -> Result<(), String> {
        let clean = text.trim().to_string();
        if clean.is_empty() {
            return Err(tr("Leeg bericht.", "Empty message.").into());
        }
        // `/goal <text>`, `/goal clear`, or empty `/goal` (AG-67): updates the session's goal strip immediately.
        if let Some(cmd) = super::context_usage::parse_goal_command(&clean) {
            let next = match cmd {
                super::context_usage::GoalCommand::Set(obj) => Some(obj),
                super::context_usage::GoalCommand::Clear => None,
            };
            let saved = self.set_goal(id, next)?;
            let note = match saved {
                Some(ref goal) => trf("Doel ingesteld: {goal}", "Goal set: {goal}", &[("goal", goal)]),
                None => tr("Doel gewist.", "Goal cleared.").into(),
            };
            let mut out = Out::default();
            {
                let mut s = self.lock();
                Self::load_timeline(&self.store, &mut s, id);
                Self::append(&mut s, id, RunEvent::new(EventKind::System, note).with_tool(super::context_usage::GOAL_TOOL), &mut out);
            }
            self.emit(out);
            return Ok(());
        }
        let (run, busy) = {
            let mut s = self.lock();
            // Je gaat zelf verder: wat achter een fout of stop wachtte, gaat na deze beurt weer door.
            if let Some(q) = s.queues.get_mut(&id) {
                q.resume();
            }
            let run = s
                .runs
                .iter()
                .find(|r| r.id == id)
                .cloned()
                .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
            let busy = !run.can_continue() || s.processes.contains_key(&id);
            (run, busy)
        };
        if busy {
            self.enqueue(id, &clean);
            return Ok(());
        }
        let executable = self.resolve_executable(run.provider, &run.profile_id).ok_or_else(|| {
            trf("{agent} staat niet op deze computer.", "{agent} is not on this computer.", &[("agent", &run.provider.display_name())])
        })?;
        if paths::verdict(&run.working_directory) != Verdict::Ok {
            let message = trf(
                "De werkmap bestaat niet meer: {dir}",
                "The working folder no longer exists: {dir}",
                &[("dir", &run.working_directory)],
            );
            let mut out = Out::default();
            Self::append(&mut self.lock(), id, RunEvent::new(EventKind::Error, message.clone()), &mut out);
            self.emit(out);
            return Err(message);
        }
        let prompt = match &run.pending_handoff {
            Some(handoff) => format!("{handoff}\n\n{clean}"),
            None => clean.clone(),
        };
        let compacting = super::context_usage::is_compact_command(&clean);
        self.launch_turn(id, prompt, executable, true);
        if compacting {
            let mut out = Out::default();
            Self::compaction_started(&mut self.lock(), id, &mut out);
            self.emit(out);
        }
        Ok(())
    }

    /// Bewaart een bericht voor als de huidige beurt klaar is: je typt door terwijl de agent werkt.
    pub fn enqueue(&self, id: Uuid, text: &str) {
        let mut s = self.lock();
        let q = s.queues.entry(id).or_default();
        q.enqueue(text);
        s.dirty_queues = true;
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    pub fn remove_queued(&self, id: Uuid, message: Uuid) {
        let mut s = self.lock();
        if let Some(q) = s.queues.get_mut(&id) {
            q.remove(message);
        }
        s.dirty_queues = true;
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    pub fn move_queued(&self, id: Uuid, message: Uuid, to_index: i64) {
        let mut s = self.lock();
        if let Some(q) = s.queues.get_mut(&id) {
            q.move_to(message, to_index);
        }
        s.dirty_queues = true;
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    pub fn edit_queued(&self, id: Uuid, message: Uuid, text: &str) {
        let mut s = self.lock();
        if let Some(q) = s.queues.get_mut(&id) {
            q.edit(message, text);
        }
        s.dirty_queues = true;
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    /// Stuurt het eerste bericht uit de wachtrij nu (na een stop of fout, als de wachtrij op jou wacht).
    pub fn send_queued_now(self: &Arc<Self>, id: Uuid) {
        let next = {
            let mut s = self.lock();
            let active = s.runs.iter().find(|r| r.id == id).is_none_or(|r| r.status.is_active()) || s.processes.contains_key(&id);
            if active {
                return;
            }
            let Some(q) = s.queues.get_mut(&id) else { return };
            q.resume();
            let next = q.next(false);
            s.dirty_queues = true;
            next
        };
        if let Some(m) = next {
            let _ = self.send(id, &m.text);
        }
    }

    /// Neemt een bericht uit de wachtrij nu mee in de lopende beurt (alleen Claude Code kan bijsturen).
    pub fn steer_queued(&self, id: Uuid, message: Uuid) {
        let text = {
            let mut s = self.lock();
            let Some(q) = s.queues.get_mut(&id) else { return };
            let text = q.promote_to_steer(message);
            s.dirty_queues = true;
            text
        };
        if let Some(t) = text {
            if !self.steer(id, &t) {
                self.enqueue(id, &t);
            }
        }
    }

    /// Stuurt een bericht in de lopende beurt van Claude Code (`priority: "now"`).
    pub fn steer(&self, id: Uuid, text: &str) -> bool {
        let mut out = Out::default();
        let ok = {
            let mut s = self.lock();
            let provider = s.runs.iter().find(|r| r.id == id).map(|r| r.provider);
            if !provider.is_some_and(|p| p.capabilities().steering) {
                return false;
            }
            let Some(input) = s.processes.get(&id).and_then(|p| p.input.clone()) else { return false };
            // Over a driver (Codex's `turn/steer`) or Claude Code's stream; `None`: not now (`codex exec`, no turn yet).
            let lines = match s.processes.get_mut(&id).map(|p| p.driver.as_mut()) {
                Some(Some(d)) => d.steer(text),
                _ if provider == Some(RunProvider::Claude) => Some(vec![parsers::claude_user_message(text, true)]),
                _ => None,
            };
            let Some(lines) = lines else { return false };
            for line in lines {
                if input.send(Input::Line(line)).is_err() {
                    return false;
                }
            }
            if provider == Some(RunProvider::Claude) {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.steered = true;
                }
            }
            Self::finish_live_text(&mut s, id);
            // An agent that says when it read a steer (`echoes_steers`): the message waits marked until then.
            let mut event = RunEvent::new(EventKind::User, text).with_tool("steer");
            if provider.is_some_and(|p| p.capabilities().echoes_steers) {
                event.state = Some(EventState::Pending);
            }
            Self::append(&mut s, id, event, &mut out);
            true
        };
        self.emit(out);
        ok
    }

    /// The agent read a steered message (`SteerReceipts`): the oldest one still waiting with that text (or else the
    /// oldest waiting at all) is read.
    fn steer_read(s: &mut Inner, id: Uuid, text: &str, out: &mut Out) {
        let waiting =
            |e: &RunEvent| e.kind == EventKind::User && e.tool.as_deref() == Some("steer") && e.state == Some(EventState::Pending);
        let Some(list) = s.events.get(&id) else { return };
        let target =
            list.iter().find(|e| waiting(e) && e.text.trim() == text.trim()).or_else(|| list.iter().find(|e| waiting(e))).map(|e| e.id);
        if let Some(event_id) = target {
            Self::mutate(s, id, event_id, out, |e| e.state = Some(EventState::Done));
        }
    }

    /// The turn ended: a steer the agent never took in stays unread (`SteerReceipts` "not read").
    fn steers_unread(s: &mut Inner, id: Uuid, out: &mut Out) {
        let ids: Vec<_> = s
            .events
            .get(&id)
            .map(|l| {
                l.iter()
                    .filter(|e| e.kind == EventKind::User && e.tool.as_deref() == Some("steer") && e.state == Some(EventState::Pending))
                    .map(|e| e.id)
                    .collect()
            })
            .unwrap_or_default();
        for event_id in ids {
            Self::mutate(s, id, event_id, out, |e| e.state = Some(EventState::Expired));
        }
    }

    /// Probeert de vorige opdracht opnieuw (na een fout of een stop).
    pub fn retry(self: &Arc<Self>, id: Uuid) -> Result<(), String> {
        let last = {
            let mut s = self.lock();
            Self::load_timeline(&self.store, &mut s, id);
            let run = s
                .runs
                .iter()
                .find(|r| r.id == id)
                .cloned()
                .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
            s.events.get(&id).and_then(|e| e.iter().rev().find(|e| e.kind == EventKind::User)).map(|e| e.text.clone()).unwrap_or(run.task)
        };
        self.send(id, &last)
    }

    fn launch_turn(self: &Arc<Self>, id: Uuid, prompt: String, executable: String, show_prompt: bool) {
        if self.lock().quitting {
            return;
        }
        if self.wait_for_capacity(id, &prompt, &executable, show_prompt) {
            return;
        }
        // Does this version of the agent have its server? Asked once per program, before the lock.
        if let Some(provider) = self.run(id).map(|r| r.provider) {
            driver::warm(provider, &executable);
        }
        // Resolve OTLP telemetry outside the mutex (may read settings/secrets/env).
        let telemetry = self.resolve_telemetry();
        let mut out = Out::default();
        let (spec, mut turn_driver, used_claude_rollback) = {
            let mut s = self.lock();
            if s.processes.contains_key(&id) {
                return;
            }
            // Een nieuwe beurt beëindigt elk wachten op een gebruikslimiet (van jou of het automatische).
            Self::clear_usage_limit(&mut s, id);
            Self::drop_finished_setup(&mut s, id);
            Self::load_timeline(&self.store, &mut s, id);
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            let claude_rollback =
                run.pending_rollback.as_ref().filter(|p| !p.is_codex() && p.resume_session.is_some() && p.resume_at.is_some()).cloned();
            let (resume_session_id, fork_session, resume_at, used_claude_rollback) = match claude_rollback {
                Some(pending) => (pending.resume_session, true, pending.resume_at, true),
                None => (run.provider_session_id.clone(), s.fork_next.contains(&id), None, false),
            };
            let codex_rollback = run.pending_rollback.clone().filter(|p| p.is_codex());
            let account_environment = (self.hooks.account_environment)(&run.profile_id);
            let config_dir = account_environment.get("CLAUDE_CONFIG_DIR").map(String::as_str);
            let tool_search = if run.provider == RunProvider::Claude {
                let files = super::token_savings::ClaudeToolSearch::settings_files(&run.working_directory, config_dir);
                let env_val = std::env::var("ENABLE_TOOL_SEARCH").ok();
                let user_val = super::token_savings::ClaudeToolSearch::user_value(&files).or(env_val);
                super::token_savings::ClaudeToolSearch::override_value(user_val.as_deref()).map(String::from)
            } else {
                None
            };
            let tuning = if config_dir.unwrap_or("").trim().is_empty() {
                super::tuning::AppliedTuning::load_from(&super::tuning::AppliedTuning::file())
            } else {
                super::tuning::AppliedTuning::default()
            };
            let input = CommandInput {
                provider: run.provider,
                executable: executable.clone(),
                prompt: prompt.clone(),
                model: run.model.clone(),
                mode: run.mode,
                permission: run.permission,
                instructions: run.instructions.clone(),
                working_directory: run.working_directory.clone(),
                resume_session_id,
                fork_session,
                resume_at,
                pending_rollback: codex_rollback,
                account_environment,
                run_id: id.to_string(),
                profile_id: run.profile_id.clone(),
                bridge: (self.hooks.bridge)(),
                effort: run.effort.clone(),
                tool_search,
                tuning,
                omit_agent_credits: super::token_savings::omit_agent_credits(),
                custom_agent: if run.provider == RunProvider::Acp {
                    super::custom_agents::CustomAgents::agent_for(&run.profile_id)
                } else {
                    None
                },
            };
            if show_prompt {
                s.idle_compacting.remove(&id);
                Self::append(&mut s, id, RunEvent::new(EventKind::User, prompt.clone()), &mut out);
            }
            match driver::plan(&input) {
                Ok(planned) => {
                    if let Some(note) = planned.note {
                        if !s.events.get(&id).is_some_and(|l| l.iter().any(|e| e.text == note)) {
                            Self::append(&mut s, id, RunEvent::new(EventKind::System, note), &mut out);
                        }
                    }
                    // Codex over `codex exec`: cannot roll back its conversation and Nook cannot trust its turn count.
                    if run.provider == RunProvider::Codex && planned.driver.is_none() {
                        Self::mark_conversation_inexact(&mut s, id);
                        if run.pending_rollback.is_some() {
                            Self::update(&mut s, id, |r| r.pending_rollback = None);
                            let reason = tr(
                                "Codex draait via codex exec, dat zijn gesprek niet kan terugzetten.",
                                "Codex runs through codex exec, which cannot roll back its conversation.",
                            );
                            Self::append(
                                &mut s,
                                id,
                                RunEvent::new(
                                    EventKind::Error,
                                    trf(
                                        "Het gesprek van de agent kon niet worden teruggezet: {reason}",
                                        "The agent's conversation could not be rolled back: {reason}",
                                        &[("reason", &reason)],
                                    ),
                                ),
                                &mut out,
                            );
                        }
                    }
                    let mut spec = planned.spec;
                    spec.arguments.extend(self.resolve_account_arguments(&run.profile_id));
                    let spec = command::apply_telemetry(run.provider, &telemetry, spec);
                    (spec, planned.driver, used_claude_rollback)
                }
                Err(message) => {
                    if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
                        if !run.status.is_active() {
                            run.move_to(RunStatus::Preparing, None, Utc::now());
                        }
                        run.move_to(RunStatus::Failed, Some(message.clone()), Utc::now());
                    }
                    s.dirty_runs = true;
                    Self::append(&mut s, id, RunEvent::new(EventKind::Error, message), &mut out);
                    drop(s);
                    out.push(ManagerEvent::Changed);
                    self.emit(out);
                    self.start_waiting_turns();
                    return;
                }
            }
        };
        let mut base: BTreeMap<String, String> = std::env::vars().collect();
        for key in turn_driver.as_ref().map(|d| d.removed_environment()).unwrap_or_default() {
            base.remove(*key);
        }
        let env = command::environment(&base, &spec.executable, &spec.extra_environment);
        let mut cmd = tokio::process::Command::new(&spec.executable);
        cmd.args(&spec.arguments)
            .current_dir(&spec.working_directory)
            .env_clear()
            .envs(&env)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .stdin(if spec.keeps_input_open { std::process::Stdio::piped() } else { std::process::Stdio::null() });
        #[cfg(windows)]
        {
            cmd.creation_flags(0x0800_0000);
        }
        let _guard = self.runtime.enter();
        let spawned = cmd.spawn();
        let mut child = match spawned {
            Ok(c) => c,
            Err(e) => {
                let message = trf("De agent starten lukte niet: {e}", "Could not start the agent: {e}", &[("e", &e)]);
                let mut s = self.lock();
                if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
                    if !run.status.is_active() {
                        run.move_to(RunStatus::Preparing, None, Utc::now());
                    }
                    run.move_to(RunStatus::Failed, Some(message.clone()), Utc::now());
                }
                s.dirty_runs = true;
                Self::append(&mut s, id, RunEvent::new(EventKind::Error, message), &mut out);
                drop(s);
                out.push(ManagerEvent::Changed);
                self.emit(out);
                self.start_waiting_turns();
                return;
            }
        };
        let pid = child.id();
        if let Some(p) = pid {
            super::dev_stop::note_agent(p);
        }
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let stdin = child.stdin.take();
        let (tx, mut rx) = mpsc::unbounded_channel::<Input>();
        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
        let generation = {
            let mut s = self.lock();
            s.generation += 1;
            let generation = s.generation;
            s.processes.insert(
                id,
                Proc { generation, pid, input: spec.keeps_input_open.then(|| tx.clone()), kill: Some(kill_tx), driver: turn_driver.take() },
            );
            s.fork_next.remove(&id);
            s.turns.insert(id, TurnState { started: Some(Utc::now()), ..Default::default() });
            let now = Utc::now();
            let mut is_claude = false;
            if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
                if matches!(run.status, RunStatus::Completed | RunStatus::Failed | RunStatus::Stopped) {
                    run.move_to(RunStatus::Preparing, None, now);
                }
                run.move_to(RunStatus::Running, None, now);
                run.turn_started_at = Some(now);
                crate::services::nook_telemetry::shared().turn_started(id, &run.usage, now);
                // A finished task list goes with the work it was for; an unfinished one stays until the agent writes anew.
                if run.tasks.as_ref().is_some_and(|t| {
                    t.iter().all(|x| matches!(x.status, super::tasks::StepStatus::Done | super::tasks::StepStatus::Cancelled))
                }) {
                    run.tasks = None;
                }
                if used_claude_rollback {
                    run.pending_rollback = None;
                }
                is_claude = run.provider == RunProvider::Claude;
                let (project, agent) = (run.project_name(), run.provider.display_name());
                self.recap.note(|r, now| r.prompt(&format!("run-{id}"), &project, agent, now));
            }
            if is_claude {
                Self::note_conversation_turn(&mut s, id, None);
            }
            s.dirty_runs = true;
            let mut launch = RunEvent::new(EventKind::System, spec.display_command());
            launch.tool = Some("launch".into());
            Self::append(&mut s, id, launch, &mut out);
            generation
        };
        out.push(ManagerEvent::Changed);
        self.emit(out);

        // "Keep agent traffic": what goes in and out of this process, when it is on.
        let traffic = super::traffic::Recorder::open(&id.to_string(), pid).map(Arc::new);
        // Schrijven naar stdin: eerst de eerste regels, dan wat Nook later stuurt (antwoorden, onderbreken).
        if let Some(mut stdin) = stdin {
            let initial = spec.initial_input.clone();
            let traffic = traffic.clone();
            self.runtime.spawn(async move {
                for line in initial {
                    if let Some(t) = &traffic {
                        t.line(true, &line);
                    }
                    if stdin.write_all(line.as_bytes()).await.is_err() {
                        return;
                    }
                }
                let _ = stdin.flush().await;
                while let Some(msg) = rx.recv().await {
                    match msg {
                        Input::Line(l) => {
                            if let Some(t) = &traffic {
                                t.line(true, &l);
                            }
                            if stdin.write_all(l.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                                return;
                            }
                        }
                        Input::Close => return,
                    }
                }
            });
        }
        let tail = Arc::new(Mutex::new(String::new()));
        if let Some(mut err) = stderr {
            let tail = tail.clone();
            self.runtime.spawn(async move {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    let mut t = tail.lock().unwrap_or_else(|e| e.into_inner());
                    t.push_str(&String::from_utf8_lossy(&buf[..n]));
                    if t.len() > 8_192 {
                        let cut = t.len() - 8_192;
                        let cut = (cut..t.len()).find(|i| t.is_char_boundary(*i)).unwrap_or(t.len());
                        t.drain(..cut);
                    }
                }
            });
        }
        let manager = self.clone();
        let reader = stdout.map(|out| {
            let manager = manager.clone();
            let traffic = traffic.clone();
            self.runtime.spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if let Some(t) = &traffic {
                        t.line(false, &line);
                    }
                    let line = line.trim().to_string();
                    if !line.is_empty() {
                        manager.handle_line(id, generation, &line);
                    }
                }
            })
        });
        self.runtime.spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status.ok(),
                _ = kill_rx => {
                    let _ = child.start_kill();
                    child.wait().await.ok()
                }
            };
            if let Some(r) = reader {
                let _ = tokio::time::timeout(Duration::from_millis(500), r).await;
            }
            let code = status.and_then(|s| s.code()).unwrap_or(-1);
            let stderr = tail.lock().unwrap_or_else(|e| e.into_inner()).clone();
            manager.process_exited(id, generation, code, &stderr);
        });
    }

    // MARK: Uitvoer van de agent

    fn handle_line(self: &Arc<Self>, id: Uuid, generation: u64, line: &str) {
        let mut out = Out::default();
        let mut finished = false;
        let mut close_input = false;
        let tools: Vec<String> = {
            let mut s = self.lock();
            if s.processes.get(&id).map(|p| p.generation) != Some(generation) {
                return;
            }
            let before = s.events.get(&id).map_or(0, Vec::len);
            let Some(provider) = s.runs.iter().find(|r| r.id == id).map(|r| r.provider) else { return };
            let stepped = s.processes.get_mut(&id).and_then(|p| p.driver.as_mut()).map(|d| d.receive(line));
            let driven = stepped.is_some();
            if let Some(step) = stepped {
                if let Some(input) = s.processes.get(&id).and_then(|p| p.input.clone()) {
                    for reply in step.replies {
                        let _ = input.send(Input::Line(reply));
                    }
                }
                for event in step.events {
                    match event {
                        driver::DriverEvent::Claude(event) => {
                            let (done, close) = Self::handle_claude(&mut s, id, event, &mut out);
                            finished |= done;
                            close_input |= close;
                        }
                        driver::DriverEvent::FileChange { path, kind } => Self::record_file_change(&mut s, id, &path, &kind, &mut out),
                        driver::DriverEvent::System(text) => Self::append(&mut s, id, RunEvent::new(EventKind::System, text), &mut out),
                        driver::DriverEvent::Commands(list) => {
                            s.commands.insert(id, list);
                        }
                        driver::DriverEvent::Tasks(steps) => Self::update(&mut s, id, |r| r.tasks = Some(steps)),
                        driver::DriverEvent::UserMessageRead(text) => Self::steer_read(&mut s, id, &text, &mut out),
                        driver::DriverEvent::TurnStarted(turn_id) => Self::note_conversation_turn(&mut s, id, turn_id.as_deref()),
                        driver::DriverEvent::RollbackApplied => Self::update(&mut s, id, |r| r.pending_rollback = None),
                        driver::DriverEvent::RollbackFailed(reason) => {
                            Self::update(&mut s, id, |r| r.pending_rollback = None);
                            Self::mark_conversation_inexact(&mut s, id);
                            Self::append(
                                &mut s,
                                id,
                                RunEvent::new(
                                    EventKind::Error,
                                    trf(
                                        "Het gesprek van de agent kon niet worden teruggezet: {reason}",
                                        "The agent's conversation could not be rolled back: {reason}",
                                        &[("reason", &reason)],
                                    ),
                                ),
                                &mut out,
                            );
                        }
                    }
                }
            }
            match provider {
                _ if driven => {}
                RunProvider::Claude => {
                    for event in parsers::parse_claude(line) {
                        let (done, close) = Self::handle_claude(&mut s, id, event, &mut out);
                        finished |= done;
                        close_input |= close;
                    }
                }
                RunProvider::Codex => {
                    for event in parsers::parse_codex(line) {
                        finished |= Self::handle_codex(&mut s, id, event, &mut out);
                    }
                }
                _ => {
                    for event in parsers::parse_gemini(line) {
                        finished |= Self::handle_gemini(&mut s, id, event, &mut out);
                    }
                }
            }
            if close_input {
                // Beurt klaar: Claude Code sluit af als zijn invoer dicht gaat.
                if let Some(p) = s.processes.get(&id) {
                    if let Some(input) = &p.input {
                        let _ = input.send(Input::Close);
                    }
                }
                // A server that stays up after its input closed is ended after a moment, so the next turn can start.
                if driven {
                    let manager = self.clone();
                    self.runtime.spawn(async move {
                        tokio::time::sleep(Duration::from_secs(3)).await;
                        if manager.same_process(id, generation) {
                            manager.force_kill(id);
                        }
                    });
                }
            }
            // Elke nieuwe tool-regel in de tijdlijn is een tool die de agent gebruikte.
            let events = s.events.get(&id).map(Vec::as_slice).unwrap_or_default();
            events[before.min(events.len())..].iter().filter(|e| e.kind == EventKind::Tool).filter_map(|e| e.tool.clone()).collect()
        };
        for tool in tools {
            self.recap.note(|r, now| r.tool_use(&tool, now));
        }
        self.emit(out);
        if finished {
            self.turn_did_finish(id);
        }
    }

    fn update(s: &mut Inner, id: Uuid, change: impl FnOnce(&mut WorkspaceRun)) {
        if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
            change(run);
            s.dirty_runs = true;
        }
    }

    fn append(s: &mut Inner, id: Uuid, event: RunEvent, out: &mut Out) {
        let notable = !(event.kind == EventKind::System && event.tool.as_deref() == Some("launch"));
        Self::note_setup_event(s, id, &event, out);
        let list = s.events.entry(id).or_default();
        list.push(event);
        // Only the last EVENT_LIMIT events are ever saved; trimming in batches keeps a long session from growing
        // without bound in memory, without shifting the list on every event.
        if list.len() > 2 * EVENT_LIMIT {
            list.drain(..list.len() - EVENT_LIMIT);
        }
        s.dirty_events.insert(id);
        if notable {
            if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
                run.updated_at = Utc::now();
                s.dirty_runs = true;
            }
        }
        out.push(ManagerEvent::Timeline(id));
    }

    fn mutate(s: &mut Inner, id: Uuid, event_id: Uuid, out: &mut Out, change: impl FnOnce(&mut RunEvent)) {
        if let Some(e) = s.events.get_mut(&id).and_then(|l| l.iter_mut().rev().find(|e| e.id == event_id)) {
            change(e);
            s.dirty_events.insert(id);
            out.push(ManagerEvent::Timeline(id));
        }
    }

    fn finish_live_text(s: &mut Inner, id: Uuid) {
        let Some(live) = s.turns.get_mut(&id).and_then(|t| t.live_text.take()) else { return };
        if let Some(e) = s.events.get_mut(&id).and_then(|l| l.iter_mut().rev().find(|e| e.id == live)) {
            e.state = Some(EventState::Done);
            s.dirty_events.insert(id);
        }
    }

    /// Sluit het denkblok dat binnenkwam; het wacht dan op zijn volledige kopie.
    fn close_thinking(s: &mut Inner, id: Uuid, out: &mut Out) {
        let Some(turn) = s.turns.get_mut(&id) else { return };
        if !turn.thinking_open {
            return;
        }
        turn.thinking_open = false;
        let live = turn.live_thinking.take();
        turn.streamed_thinking.push(live);
        if let Some(l) = live {
            Self::mutate(s, id, l, out, |e| e.state = Some(EventState::Done));
        }
    }

    fn record_file_change(s: &mut Inner, id: Uuid, path: &str, kind: &str, out: &mut Out) {
        let base = s.runs.iter().find(|r| r.id == id).map(|r| r.working_directory.clone()).unwrap_or_default();
        let shown = path.strip_prefix(&format!("{base}/")).or_else(|| path.strip_prefix(&format!("{base}\\"))).unwrap_or(path).to_string();
        let mut e = RunEvent::new(EventKind::FileChange, shown).with_tool(kind).with_detail(path);
        e.state = None;
        Self::append(s, id, e, out);
        Self::update(s, id, |r| r.last_change_at = Some(Utc::now()));
    }

    fn tool_event(s: &mut Inner, id: Uuid, call: &str, name: &str, input: &Value, nested: bool, out: &mut Out) {
        Self::finish_live_text(s, id);
        let summary = tool_summary::describe(name, input);
        let text = if nested { format!("↳ {summary}") } else { summary };
        let e = RunEvent::new(EventKind::Tool, text)
            .with_tool(name)
            .with_call(call)
            .with_detail(tool_summary::json(input))
            .with_state(EventState::Running);
        if let Some(t) = s.turns.get_mut(&id) {
            t.tool_events.insert(call.into(), e.id);
            t.tool_names.insert(call.into(), name.into());
            t.tool_inputs.insert(call.into(), input.clone());
        }
        Self::append(s, id, e, out);
    }

    fn tool_result(s: &mut Inner, id: Uuid, call: &str, output: &str, is_error: bool, out: &mut Out) {
        let event = s.turns.get(&id).and_then(|t| t.tool_events.get(call)).copied();
        if let Some(event) = event {
            Self::mutate(s, id, event, out, |e| {
                e.output = Some(RunEvent::clip(output));
                e.state = Some(if is_error { EventState::Failed } else { EventState::Done });
            });
        }
        if !is_error {
            let (name, input) = {
                let t = s.turns.get(&id);
                (t.and_then(|t| t.tool_names.get(call).cloned()), t.and_then(|t| t.tool_inputs.get(call).cloned()))
            };
            if let (Some(name), Some(input)) = (name, input) {
                for (path, kind) in tool_summary::file_changes(&name, &input) {
                    Self::record_file_change(s, id, &path, &kind, out);
                }
            }
        }
    }

    /// Geeft (beurt klaar, invoer sluiten).
    fn handle_claude(s: &mut Inner, id: Uuid, event: ClaudeEvent, out: &mut Out) -> (bool, bool) {
        match event {
            ClaudeEvent::Initialized { session_id, model } => Self::update(s, id, |r| {
                r.provider_session_id = Some(session_id.clone());
                if let Some(m) = model.filter(|m| !m.is_empty()) {
                    r.resolved_model = Some(m);
                }
                let mut log = r.conversation.take().unwrap_or_else(|| ConversationLog::new(None, r.provider));
                log.note_session(&session_id, r.provider);
                r.conversation = Some(log);
            }),
            ClaudeEvent::TextDelta(text) => {
                let live = s.turns.get(&id).and_then(|t| t.live_text);
                match live {
                    Some(l) => Self::mutate(s, id, l, out, |e| e.text.push_str(&text)),
                    None => {
                        let e = RunEvent::new(EventKind::Assistant, text).with_state(EventState::Running);
                        if let Some(t) = s.turns.get_mut(&id) {
                            t.live_text = Some(e.id);
                        }
                        Self::append(s, id, e, out);
                    }
                }
            }
            ClaudeEvent::Text(text) => {
                let live = s.turns.get_mut(&id).and_then(|t| t.live_text.take());
                match live {
                    Some(l) => Self::mutate(s, id, l, out, |e| {
                        e.text = text;
                        e.state = Some(EventState::Done);
                    }),
                    None => Self::append(s, id, RunEvent::new(EventKind::Assistant, text).with_state(EventState::Done), out),
                }
            }
            ClaudeEvent::ThinkingDelta { text, starts } => {
                if starts {
                    Self::close_thinking(s, id, out);
                    if let Some(t) = s.turns.get_mut(&id) {
                        t.thinking_open = true;
                    }
                }
                if text.is_empty() {
                    return (false, false);
                }
                let live = s.turns.get(&id).and_then(|t| t.live_thinking);
                match live {
                    Some(l) => Self::mutate(s, id, l, out, |e| e.text.push_str(&text)),
                    None => {
                        let e = RunEvent::new(EventKind::Thinking, text).with_state(EventState::Running);
                        if let Some(t) = s.turns.get_mut(&id) {
                            t.live_thinking = Some(e.id);
                        }
                        Self::append(s, id, e, out);
                    }
                }
            }
            ClaudeEvent::BlockStopped => Self::close_thinking(s, id, out),
            ClaudeEvent::Thinking(text) => {
                Self::close_thinking(s, id, out);
                // De volledige kopie van een blok dat binnenkwam: houd de tekst, tenzij deze meer zegt.
                let streamed = s.turns.get_mut(&id).filter(|t| !t.streamed_thinking.is_empty()).map(|t| t.streamed_thinking.remove(0));
                if let Some(Some(event)) = streamed {
                    if !text.is_empty() {
                        Self::mutate(s, id, event, out, |e| e.text = text);
                    }
                    return (false, false);
                }
                if !text.is_empty() {
                    Self::append(s, id, RunEvent::new(EventKind::Thinking, text), out);
                }
            }
            ClaudeEvent::ToolUse { id: call, name, input, nested } => {
                // The agent's own task list (TodoWrite and its likes): the Tasks strip follows it.
                if !nested && super::tasks::is_todo_tool(&name) {
                    if let Some(steps) = super::tasks::claude(&input) {
                        Self::update(s, id, |r| r.tasks = Some(steps));
                    }
                }
                Self::tool_event(s, id, &call, &name, &input, nested, out)
            }
            ClaudeEvent::ToolResult { id: call, output, is_error } => Self::tool_result(s, id, &call, &output, is_error, out),
            ClaudeEvent::RequestStarted { cache_ttl } => {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.last_request_at = Some(Utc::now());
                    if let Some(ttl) = cache_ttl {
                        t.cache_ttl = Some(ttl as f64);
                    }
                }
            }
            ClaudeEvent::Usage { message_id, tokens, model } => {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.message_usage.insert(message_id, tokens);
                    t.last_context = Some(tokens.context() + tokens.output);
                    if let Some(ttl) = tokens.cache_ttl {
                        t.cache_ttl = Some(ttl as f64);
                    }
                    if t.last_request_at.is_none() {
                        t.last_request_at = Some(Utc::now());
                    }
                }
                if let Some(m) = model.filter(|m| !m.is_empty()) {
                    if s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.resolved_model.is_none()) {
                        Self::update(s, id, |r| r.resolved_model = Some(m));
                    }
                }
            }
            ClaudeEvent::PermissionRequest { request_id, tool, input, suggestions, .. } => {
                Self::finish_live_text(s, id);
                // Een vraag wordt beantwoord, niet goedgekeurd: de antwoorden gaan terug als invoer van de tool.
                if tool == "AskUserQuestion" {
                    if let Some(items) = question_items(&input) {
                        let q = PendingQuestion { id: request_id.clone(), run_id: id, items, input, created: Utc::now(), restored: false };
                        s.questions.entry(id).or_default().push(q.clone());
                        Self::sync_waiting(s, id);
                        Self::update(s, id, |r| {
                            r.move_to(RunStatus::WaitingApproval, None, Utc::now());
                        });
                        let mut e = RunEvent::new(EventKind::Approval, tr("Wacht op je antwoord…", "Waiting for your answer…"))
                            .with_tool(tool)
                            .with_call(&request_id)
                            .with_state(EventState::Pending);
                        e.detail = Some(q.items.iter().map(|i| i.question.clone()).collect::<Vec<_>>().join("\n"));
                        Self::append(s, id, e, out);
                        if let Some(run) = s.runs.iter().find(|r| r.id == id) {
                            out.push(ManagerEvent::Question(Self::question_view(run, &q)));
                        }
                        out.push(ManagerEvent::Changed);
                        return (false, false);
                    }
                }
                // In Plan-modus wordt het plan een kaart; Claude Code wacht op jouw woord in plaats van de plan-modus te verlaten.
                if tool == "ExitPlanMode" && s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.mode == ExecutionMode::Plan) {
                    let plan = input.get("plan").and_then(Value::as_str).unwrap_or("").trim().to_string();
                    if !plan.is_empty() {
                        Self::append(s, id, RunEvent::new(EventKind::Assistant, plan).with_tool("plan").with_state(EventState::Done), out);
                    }
                    if let Some(p) = s.processes.get(&id).and_then(|p| p.input.clone()) {
                        let _ = p.send(Input::Line(parsers::claude_permission_response(
                            &request_id,
                            false,
                            &input,
                            None,
                            "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn.",
                        )));
                    }
                    return (false, false);
                }
                let summary = tool_summary::describe(&tool, &input);
                let e = RunEvent::new(EventKind::Approval, summary.clone())
                    .with_tool(&tool)
                    .with_call(&request_id)
                    .with_detail(tool_summary::json(&input))
                    .with_state(EventState::Pending);
                let pending = PendingPermission {
                    id: request_id,
                    run_id: id,
                    tool,
                    summary,
                    input,
                    suggestions,
                    event_id: e.id,
                    created: Utc::now(),
                };
                Self::append(s, id, e, out);
                s.approvals.entry(id).or_default().push(pending.clone());
                Self::update(s, id, |r| {
                    r.move_to(RunStatus::WaitingApproval, None, Utc::now());
                });
                if let Some(run) = s.runs.iter().find(|r| r.id == id) {
                    out.push(ManagerEvent::Approval(Self::approval_view(run, &pending)));
                }
                out.push(ManagerEvent::Changed);
            }
            ClaudeEvent::Result(result) => {
                Self::finish_live_text(s, id);
                // Een bijsturend bericht kapte dit stuk af: de beurt gaat door met het nieuwe bericht.
                let stopping = s.turns.get(&id).is_some_and(|t| t.stopping);
                if s.turns.get(&id).is_some_and(|t| t.steered) && !stopping && result.ended_by_steer() {
                    if let Some(t) = s.turns.get_mut(&id) {
                        t.steered_usage.push(result.usage.clone());
                        t.streamed_thinking.clear();
                    }
                    Self::close_thinking(s, id, out);
                    return (false, false);
                }
                Self::close_thinking(s, id, out);
                let mut usage = result.usage.clone();
                let turn = s.turns.get(&id);
                // Meldde het einde van de beurt geen tokens, dan de som van de losse berichten.
                if usage.input_tokens.unwrap_or(0) + usage.output_tokens.unwrap_or(0) == 0 {
                    if let Some(m) = turn.map(|t| &t.message_usage).filter(|m| !m.is_empty()) {
                        usage.input_tokens = Some(m.values().map(|t| t.input).sum());
                        usage.output_tokens = Some(m.values().map(|t| t.output).sum());
                        usage.cache_read_tokens = Some(m.values().map(|t| t.cache_read).sum());
                        usage.cache_write_tokens = Some(m.values().map(|t| t.cache_write).sum());
                    }
                }
                usage.context_tokens = turn.and_then(|t| t.last_context);
                if usage.duration_seconds.is_none() {
                    if let Some(started) = turn.and_then(|t| t.started) {
                        usage.duration_seconds = Some((Utc::now() - started).num_milliseconds() as f64 / 1000.0);
                    }
                }
                let steered: Vec<TurnUsage> = turn.map(|t| t.steered_usage.clone()).unwrap_or_default();
                let cache_inputs = turn.map(|t| (t.last_request_at, t.cache_ttl, t.compacted));
                // Gestopt op een gebruikslimiet: onthoud wanneer hij vrijkomt, voor "Hervat bij reset".
                if !stopping {
                    let windows = turn.map(|t| t.limit_windows.clone()).unwrap_or_default();
                    let evidence = limits::FailureEvidence {
                        result_subtype: Some(result.subtype.clone()),
                        terminal_reason: result.terminal_reason.clone(),
                        api_error_status: result.api_error_status,
                        is_error: result.is_error,
                        rate_limit_rejected: !windows.is_empty(),
                        rate_limit_resets: windows,
                        message_text: Some(result.text.clone()),
                        ..Default::default()
                    };
                    if let limits::FailureClass::UsageLimit(reset) = limits::classify(&evidence) {
                        if result.is_error {
                            s.limited.insert(id, reset);
                        }
                    }
                }
                if let Some(t) = s.turns.get_mut(&id) {
                    t.finished = true;
                }
                let failed = result.is_error && !stopping;
                Self::update(s, id, |r| {
                    for seg in &steered {
                        r.usage.add(seg);
                    }
                    r.usage.add(&usage);
                    if let Some((last_request_at, cache_ttl, compacted)) = cache_inputs {
                        if let Some(window) =
                            super::token_savings::PromptCache::window_after(last_request_at, cache_ttl, r.prompt_cache.as_ref(), compacted)
                        {
                            r.prompt_cache = Some(window);
                        }
                    }
                    if let Some(session) = &result.session_id {
                        r.provider_session_id = Some(session.clone());
                        r.conversation.get_or_insert_with(|| ConversationLog::new(None, r.provider)).note_session(session, r.provider);
                    }
                    let now = Utc::now();
                    if stopping {
                        r.move_to(RunStatus::Stopped, None, now);
                    } else if result.is_error {
                        let detail = if result.text.is_empty() { result.subtype.clone() } else { result.text.clone() };
                        r.move_to(RunStatus::Failed, Some(detail), now);
                    } else {
                        r.move_to(RunStatus::Completed, None, now);
                    }
                });
                if failed {
                    let text = if result.text.is_empty() {
                        trf(
                            "De agent stopte met een fout ({reason}).",
                            "The agent stopped with an error ({reason}).",
                            &[("reason", &result.subtype)],
                        )
                    } else {
                        result.text.clone()
                    };
                    Self::append(s, id, RunEvent::new(EventKind::Error, text), out);
                }
                Self::append(
                    s,
                    id,
                    RunEvent::new(EventKind::Result, result_line(&usage, result.permission_denials)).with_state(if failed {
                        EventState::Failed
                    } else {
                        EventState::Done
                    }),
                    out,
                );
                Self::expire_approvals(s, id, out);
                Self::drop_questions(s, id, out);
                out.push(ManagerEvent::Changed);
                return (true, true);
            }
            ClaudeEvent::Notice(text) => {
                if text == "compact" {
                    Self::compaction_finished(s, id, out);
                }
            }
            ClaudeEvent::CompactionStarted => Self::compaction_started(s, id, out),
            ClaudeEvent::CompactionFailed(reason) => Self::compaction_failed(s, id, reason.as_deref(), out),
            ClaudeEvent::Goal(goal) => {
                let normalized = super::context_usage::normalize_goal(goal.as_deref());
                Self::update(s, id, |r| r.goal = normalized);
                out.push(ManagerEvent::Changed);
            }
            ClaudeEvent::RateLimits(info) => {
                if let Some(event) = limits::claude_event(&info) {
                    Self::note_claude_limit(s, id, event, out);
                }
            }
            ClaudeEvent::ChainEntry(uuid) => Self::note_conversation_head(s, id, &uuid),
        }
        (false, false)
    }

    /// Marks compaction as actively running on the session and appends one live compaction timeline row (`CompactionProgress.start`).
    fn compaction_started(s: &mut Inner, id: Uuid, out: &mut Out) {
        let already = s.events.get(&id).and_then(|e| super::context_usage::running_compaction_id(e)).is_some();
        Self::update(s, id, |r| r.compacting = true);
        if !already {
            let text = tr(
                "De agent heeft het gesprek samengevat om ruimte te maken in de context.",
                "The agent summarized the conversation to make room in the context.",
            );
            Self::append(
                s,
                id,
                RunEvent::new(EventKind::System, text).with_tool(super::context_usage::COMPACTION_TOOL).with_state(EventState::Running),
                out,
            );
        }
        out.push(ManagerEvent::Changed);
    }

    /// Completes a running compaction (or records a done compaction row without duplicating consecutive ones) and clears
    /// stale pre-compaction context usage (`WorkspaceManager+Compaction.swift`).
    fn compaction_finished(s: &mut Inner, id: Uuid, out: &mut Out) {
        if let Some(t) = s.turns.get_mut(&id) {
            t.last_context = None;
            t.compacted = true;
        }
        Self::update(s, id, |r| {
            r.compacting = false;
            r.usage.context_tokens = None;
        });
        let text = tr(
            "De agent heeft het gesprek samengevat om ruimte te maken in de context.",
            "The agent summarized the conversation to make room in the context.",
        );
        let running_id = s.events.get(&id).and_then(|e| super::context_usage::running_compaction_id(e));
        if let Some(event_id) = running_id {
            Self::mutate(s, id, event_id, out, |e| {
                e.kind = EventKind::System;
                e.text = text.into();
                e.state = Some(EventState::Done);
            });
        } else {
            let duplicate = s
                .events
                .get(&id)
                .and_then(|e| e.last())
                .is_some_and(|e| super::context_usage::is_compaction_event(e) && e.state == Some(EventState::Done));
            if !duplicate {
                Self::append(
                    s,
                    id,
                    RunEvent::new(EventKind::System, text).with_tool(super::context_usage::COMPACTION_TOOL).with_state(EventState::Done),
                    out,
                );
            }
        }
        out.push(ManagerEvent::Changed);
    }

    /// Turns any running compaction row into a failed error row and clears `compacting` (`CompactionProgress.fail`).
    fn compaction_failed(s: &mut Inner, id: Uuid, reason: Option<&str>, out: &mut Out) {
        Self::update(s, id, |r| r.compacting = false);
        let running_id = s.events.get(&id).and_then(|e| super::context_usage::running_compaction_id(e));
        if let Some(event_id) = running_id {
            let clean = reason.map(str::trim).filter(|m| !m.is_empty());
            let message = clean
                .map(str::to_string)
                .unwrap_or_else(|| tr("Samenvatten van het gesprek gestopt.", "Compacting the conversation stopped.").into());
            Self::mutate(s, id, event_id, out, |e| {
                e.kind = EventKind::Error;
                e.text = message;
                e.state = Some(EventState::Failed);
            });
        }
        out.push(ManagerEvent::Changed);
    }

    fn handle_codex(s: &mut Inner, id: Uuid, event: CodexEvent, out: &mut Out) -> bool {
        match event {
            CodexEvent::ThreadStarted(thread) => Self::update(s, id, |r| {
                r.provider_session_id = Some(thread.clone());
                let mut log = r.conversation.take().unwrap_or_else(|| ConversationLog::new(None, r.provider));
                log.note_session(&thread, r.provider);
                log.exact = false;
                r.conversation = Some(log);
            }),
            CodexEvent::Message(text) => Self::append(s, id, RunEvent::new(EventKind::Assistant, text).with_state(EventState::Done), out),
            CodexEvent::Reasoning(text) => Self::append(s, id, RunEvent::new(EventKind::Thinking, text), out),
            CodexEvent::CommandStarted { id: call, command } => {
                let e = RunEvent::new(EventKind::Tool, format!("shell · {}", tool_summary::one_line(&command, 120)))
                    .with_tool("shell")
                    .with_call(&call)
                    .with_detail(command)
                    .with_state(EventState::Running);
                if let Some(t) = s.turns.get_mut(&id) {
                    t.tool_events.insert(call, e.id);
                }
                Self::append(s, id, e, out);
            }
            CodexEvent::CommandFinished { id: call, command, output, exit_code } => {
                let failed = exit_code.unwrap_or(0) != 0;
                let state = if failed { EventState::Failed } else { EventState::Done };
                match s.turns.get(&id).and_then(|t| t.tool_events.get(&call)).copied() {
                    Some(e) => Self::mutate(s, id, e, out, |e| {
                        e.output = Some(RunEvent::clip(&output));
                        e.state = Some(state);
                    }),
                    None => {
                        let mut e = RunEvent::new(EventKind::Tool, format!("shell · {}", tool_summary::one_line(&command, 120)))
                            .with_tool("shell")
                            .with_call(&call)
                            .with_detail(command)
                            .with_state(state);
                        e.output = Some(RunEvent::clip(&output));
                        Self::append(s, id, e, out);
                    }
                }
            }
            CodexEvent::FileChanges { changes, .. } => {
                for c in changes {
                    Self::record_file_change(s, id, &c.path, &c.kind, out);
                }
            }
            CodexEvent::ToolCall { id: call, name, detail, finished, failed } => {
                match s.turns.get(&id).and_then(|t| t.tool_events.get(&call)).copied() {
                    Some(e) => {
                        if finished {
                            Self::mutate(s, id, e, out, |e| e.state = Some(if failed { EventState::Failed } else { EventState::Done }));
                        }
                    }
                    None => {
                        let text = if detail.is_empty() { name.clone() } else { format!("{name} · {detail}") };
                        let state = if finished {
                            if failed {
                                EventState::Failed
                            } else {
                                EventState::Done
                            }
                        } else {
                            EventState::Running
                        };
                        let e = RunEvent::new(EventKind::Tool, text).with_tool(name).with_call(&call).with_state(state);
                        if let Some(t) = s.turns.get_mut(&id) {
                            t.tool_events.insert(call, e.id);
                        }
                        Self::append(s, id, e, out);
                    }
                }
            }
            CodexEvent::TurnCompleted(mut usage) => {
                if let Some(started) = s.turns.get(&id).and_then(|t| t.started) {
                    usage.duration_seconds = Some((Utc::now() - started).num_milliseconds() as f64 / 1000.0);
                }
                let stopping = s.turns.get(&id).is_some_and(|t| t.stopping);
                if let Some(t) = s.turns.get_mut(&id) {
                    t.finished = true;
                }
                Self::update(s, id, |r| {
                    r.usage.add(&usage);
                    r.move_to(if stopping { RunStatus::Stopped } else { RunStatus::Completed }, None, Utc::now());
                });
                Self::append(s, id, RunEvent::new(EventKind::Result, result_line(&usage, 0)).with_state(EventState::Done), out);
                out.push(ManagerEvent::Changed);
                return true;
            }
            CodexEvent::Failed(message) => {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.last_error = Some(message.clone());
                }
                Self::append(s, id, RunEvent::new(EventKind::Error, message), out);
            }
            CodexEvent::UsageLimited => {
                s.limited.insert(id, None);
            }
        }
        false
    }

    fn handle_gemini(s: &mut Inner, id: Uuid, event: GeminiEvent, out: &mut Out) -> bool {
        match event {
            GeminiEvent::Initialized { session_id, model } => Self::update(s, id, |r| {
                r.provider_session_id = Some(session_id);
                if let Some(m) = model.filter(|m| !m.is_empty()) {
                    r.resolved_model = Some(m);
                }
            }),
            GeminiEvent::Text { text, delta } => {
                let live = s.turns.get(&id).and_then(|t| t.live_text);
                match live {
                    Some(l) => Self::mutate(s, id, l, out, |e| if delta { e.text.push_str(&text) } else { e.text = text.clone() }),
                    None => {
                        let e = RunEvent::new(EventKind::Assistant, text).with_state(EventState::Running);
                        if let Some(t) = s.turns.get_mut(&id) {
                            t.live_text = Some(e.id);
                        }
                        Self::append(s, id, e, out);
                    }
                }
                if !delta {
                    Self::finish_live_text(s, id);
                }
            }
            GeminiEvent::ToolUse { id: call, name, input } => Self::tool_event(s, id, &call, &name, &input, false, out),
            GeminiEvent::ToolResult { id: call, output, is_error } => Self::tool_result(s, id, &call, &output, is_error, out),
            GeminiEvent::Warning(message) => Self::append(s, id, RunEvent::new(EventKind::System, message), out),
            GeminiEvent::Failed(message) => {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.last_error = Some(message.clone());
                }
                Self::append(s, id, RunEvent::new(EventKind::Error, message), out);
            }
            GeminiEvent::Result { is_error, message, mut usage } => {
                Self::finish_live_text(s, id);
                if usage.duration_seconds.is_none() {
                    if let Some(started) = s.turns.get(&id).and_then(|t| t.started) {
                        usage.duration_seconds = Some((Utc::now() - started).num_milliseconds() as f64 / 1000.0);
                    }
                }
                let stopping = s.turns.get(&id).is_some_and(|t| t.stopping);
                if let Some(t) = s.turns.get_mut(&id) {
                    t.finished = true;
                }
                Self::update(s, id, |r| {
                    r.usage.add(&usage);
                    let now = Utc::now();
                    if stopping {
                        r.move_to(RunStatus::Stopped, None, now);
                    } else if is_error {
                        r.move_to(RunStatus::Failed, message.clone(), now);
                    } else {
                        r.move_to(RunStatus::Completed, None, now);
                    }
                });
                if is_error && !stopping {
                    Self::append(
                        s,
                        id,
                        RunEvent::new(
                            EventKind::Error,
                            message.unwrap_or_else(|| tr("De agent stopte met een fout.", "The agent stopped with an error.").into()),
                        ),
                        out,
                    );
                }
                Self::append(
                    s,
                    id,
                    RunEvent::new(EventKind::Result, result_line(&usage, 0)).with_state(if is_error && !stopping {
                        EventState::Failed
                    } else {
                        EventState::Done
                    }),
                    out,
                );
                out.push(ManagerEvent::Changed);
                return true;
            }
        }
        false
    }

    fn process_exited(self: &Arc<Self>, id: Uuid, generation: u64, status: i32, stderr: &str) {
        let mut out = Out::default();
        let mut finished_now = false;
        {
            let mut s = self.lock();
            if s.processes.get(&id).map(|p| p.generation) != Some(generation) {
                return;
            }
            s.processes.remove(&id);
            Self::drop_questions(&mut s, id, &mut out);
            let state = s.turns.remove(&id);
            Self::finish_live_text(&mut s, id);
            Self::expire_approvals(&mut s, id, &mut out);
            Self::steers_unread(&mut s, id, &mut out);
            let stopping = state.as_ref().is_some_and(|t| t.stopping);
            // Wat nog liep, wordt afgesloten: niets mag open blijven als het proces weg is.
            Self::settle_open_work(&mut s, id, stopping, &mut out);
            match state {
                Some(state) if !state.finished => {
                    let now = Utc::now();
                    if state.stopping {
                        Self::update(&mut s, id, |r| {
                            r.move_to(RunStatus::Stopped, None, now);
                        });
                        Self::append(&mut s, id, RunEvent::new(EventKind::System, "Gestopt."), &mut out);
                    } else {
                        let detail = clean_error(state.last_error.as_deref().unwrap_or(stderr), status);
                        Self::update(&mut s, id, |r| {
                            r.move_to(RunStatus::Failed, Some(detail.clone()), now);
                        });
                        Self::append(&mut s, id, RunEvent::new(EventKind::Error, detail), &mut out);
                        finished_now = true;
                    }
                }
                _ => {}
            }
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        if finished_now {
            self.turn_did_finish(id);
        } else {
            self.refresh_git(id);
            self.send_queued(id);
            self.start_waiting_turns();
        }
    }

    fn settle_open_work(s: &mut Inner, id: Uuid, stopping: bool, out: &mut Out) {
        let Some(events) = s.events.get_mut(&id) else { return };
        let mut changed = false;
        for e in events.iter_mut() {
            let next = match (e.kind, e.state) {
                (EventKind::Tool | EventKind::FileChange, Some(EventState::Running)) => {
                    Some(if stopping { EventState::Failed } else { EventState::Done })
                }
                (EventKind::Assistant | EventKind::Thinking, Some(EventState::Running)) => Some(EventState::Done),
                (EventKind::Approval, Some(EventState::Pending)) => Some(EventState::Expired),
                _ => None,
            };
            if let Some(n) = next {
                e.state = Some(n);
                changed = true;
            }
        }
        if changed {
            s.dirty_events.insert(id);
            out.push(ManagerEvent::Timeline(id));
        }
    }

    /// Een beurt is klaar: momentopname (in een eigen worktree), wachtrij, git, en de app laten weten.
    fn turn_did_finish(self: &Arc<Self>, id: Uuid) {
        self.check_usage_limit(id);
        if self.recover_conversation(id) {
            return;
        }
        self.recap.note(|r, now| r.turn_ended(&format!("run-{id}"), now));
        let mut out = Out::default();
        let run = {
            let mut s = self.lock();
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            let stopping = run.status == RunStatus::Stopped;
            let was_idle_compacting = s.idle_compacting.remove(&id);
            let turn_compacted = s.turns.get(&id).is_some_and(|t| t.compacted) || was_idle_compacting;
            if run.compacting {
                if run.status == RunStatus::Completed {
                    Self::compaction_finished(&mut s, id, &mut out);
                } else {
                    Self::compaction_failed(&mut s, id, run.status_detail.as_deref(), &mut out);
                }
            }
            Self::settle_open_work(&mut s, id, stopping, &mut out);
            if matches!(run.status, RunStatus::Failed | RunStatus::Stopped) {
                if let Some(q) = s.queues.get_mut(&id).filter(|q| !q.is_empty()) {
                    q.hold();
                    s.dirty_queues = true;
                }
            }
            if run.status == RunStatus::Completed && run.pending_handoff.is_some() {
                Self::update(&mut s, id, |r| r.pending_handoff = None);
            }
            let last = s
                .events
                .get(&id)
                .and_then(|e| e.iter().rev().find(|e| e.kind == EventKind::Assistant))
                .map(|e| e.text.clone())
                .unwrap_or_default();
            out.push(ManagerEvent::TurnFinished(run.clone(), last));
            crate::services::nook_telemetry::shared().turn_finished(&run, Utc::now());
            (run, turn_compacted)
        };
        let (run, turn_compacted) = run;
        self.emit(out);
        self.start_waiting_turns();
        self.maybe_compact_for_size(id, turn_compacted);
        let mark = Self::conversation_mark(&run);
        if run.isolation == IsolationMode::Worktree && run.worktree_path.as_deref().is_some_and(|p| Path::new(p).exists()) {
            if let Some(git) = self.git.clone() {
                let index = run.checkpoints.len();
                let dir = run.working_directory.clone();
                let manager = self.clone();
                let date = Utc::now();
                self.runtime.spawn_blocking(move || {
                    let r = git::checkpoint_ref(&id.to_string(), index);
                    let git_ok = git.checkpoint(&dir, &r).is_ok();
                    if git_ok || mark.is_some() {
                        let mut s = manager.lock();
                        Self::update(&mut s, id, |run| {
                            run.checkpoints.push(RunCheckpoint { r#ref: if git_ok { r } else { String::new() }, date, conversation: mark })
                        });
                    }
                    manager.refresh_git(id);
                    manager.send_queued(id);
                });
                return;
            }
        }
        if let Some(mark) = mark {
            let mut s = self.lock();
            Self::update(&mut s, id, |run| {
                run.checkpoints.push(RunCheckpoint { r#ref: String::new(), date: Utc::now(), conversation: Some(mark) });
            });
            drop(s);
            self.emit(Out(vec![ManagerEvent::Changed]));
        }
        self.refresh_git(id);
        self.send_queued(id);
    }

    /// A turn that failed because the agent lost its conversation or it no longer fits the context window
    /// (`recoverConversation`): a new conversation starts from a summary of the timeline and the turn's words go again.
    /// Once per failure: a second try that fails again is told as it is. The same for every agent.
    fn recover_conversation(self: &Arc<Self>, id: Uuid) -> bool {
        let (run, prompt, carried) = {
            let mut s = self.lock();
            if s.recovering.remove(&id) {
                return false;
            }
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return false };
            if run.status != RunStatus::Failed || run.provider_session_id.is_none() {
                return false;
            }
            let Some(recovery) = run.status_detail.as_deref().and_then(super::recovery::recovery) else { return false };
            let events = s.events.get(&id).cloned().unwrap_or_default();
            let Some(prompt) = events.iter().rev().find(|e| e.kind == EventKind::User).map(|e| e.text.clone()) else { return false };
            let before: Vec<RunEvent> = {
                let last_user = events.iter().rposition(|e| e.kind == EventKind::User).unwrap_or(events.len());
                events[..last_user].to_vec()
            };
            let carried = super::handoff::render(&before, 0, run.provider.display_name(), super::handoff::TOKEN_BUDGET).map(|h| h.text);
            s.recovering.insert(id);
            s.fork_next.remove(&id);
            Self::update(&mut s, id, |r| {
                r.provider_session_id = None;
                r.pending_handoff = None;
                r.usage.context_tokens = None;
            });
            let mut out = Out::default();
            Self::append(
                &mut s,
                id,
                RunEvent::new(EventKind::System, tr("Nieuw gesprek", "New conversation")).with_tool("clear"),
                &mut out,
            );
            let agent = run.provider.display_name();
            let note = match recovery {
                super::recovery::Recovery::Full => trf(
                    "Dit gesprek past niet meer in de context van {agent}. Nook begon een nieuw gesprek vanuit de tijdlijn en stuurde je bericht opnieuw.",
                    "This conversation no longer fits in {agent}'s context. Nook started a new one from the timeline and sent your message again.",
                    &[("agent", &agent)],
                ),
                super::recovery::Recovery::Gone => trf(
                    "{agent} heeft dit gesprek niet meer. Nook begon een nieuw gesprek vanuit de tijdlijn en stuurde je bericht opnieuw.",
                    "{agent} no longer has this conversation. Nook started a new one from the timeline and sent your message again.",
                    &[("agent", &agent)],
                ),
            };
            Self::append(&mut s, id, RunEvent::new(EventKind::System, note), &mut out);
            drop(s);
            out.push(ManagerEvent::Changed);
            self.emit(out);
            (run, prompt, carried)
        };
        let Some(executable) = self.resolve_executable(run.provider, &run.profile_id) else {
            self.lock().recovering.remove(&id);
            return false;
        };
        let text = match carried {
            Some(summary) => format!("{summary}\n\n{prompt}"),
            None => prompt,
        };
        // The failed turn's process may still be closing: the new conversation starts once it is gone.
        let manager = self.clone();
        self.runtime.spawn(async move {
            for _ in 0..200 {
                if !manager.lock().processes.contains_key(&id) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            manager.launch_turn(id, text, executable, false);
        });
        true
    }

    /// De beurt ging goed en het proces is weg: stuur het volgende bericht uit de wachtrij.
    fn send_queued(self: &Arc<Self>, id: Uuid) {
        let next = {
            let mut s = self.lock();
            if s.processes.contains_key(&id) || s.runs.iter().find(|r| r.id == id).is_none_or(|r| r.status != RunStatus::Completed) {
                return;
            }
            let Some(q) = s.queues.get_mut(&id) else { return };
            let next = q.next(false);
            s.dirty_queues = true;
            next
        };
        if let Some(m) = next {
            let _ = self.send(id, &m.text);
        }
    }

    /// Stopt de lopende beurt. Claude Code krijgt eerst een nette vraag om te onderbreken, daarna SIGINT.
    pub fn stop(self: &Arc<Self>, id: Uuid) {
        if self.cancel_waiting_turn(id) {
            return;
        }
        let mut out = Out::default();
        let target = {
            let mut s = self.lock();
            if let Some(handle) = s.prepare_tasks.remove(&id) {
                handle.abort();
            }
            let Some(proc_) = s.processes.get(&id) else {
                Self::update(&mut s, id, |r| {
                    r.move_to(RunStatus::Stopped, None, Utc::now());
                });
                drop(s);
                self.emit(Out(vec![ManagerEvent::Changed]));
                self.start_waiting_turns();
                return;
            };
            let (pid, input, generation) = (proc_.pid, proc_.input.clone(), proc_.generation);
            if let Some(t) = s.turns.get_mut(&id) {
                t.stopping = true;
            }
            let claude = s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.provider == RunProvider::Claude);
            // Codex (`turn/interrupt`) and ACP (`session/cancel`) are asked to end the turn the way Claude Code is.
            let polite: Option<Vec<String>> = match s.processes.get_mut(&id).and_then(|p| p.driver.as_mut()) {
                Some(d) => Some(d.interrupt()),
                None if claude => {
                    Some(vec![parsers::claude_interrupt(&format!("nook-stop-{}", &Uuid::new_v4().simple().to_string()[..8]))])
                }
                None => None,
            };
            Self::expire_approvals(&mut s, id, &mut out);
            Self::drop_questions(&mut s, id, &mut out);
            Self::append(&mut s, id, RunEvent::new(EventKind::System, "Stoppen…"), &mut out);
            (pid, input, generation, polite)
        };
        self.emit(out);
        let (pid, input, generation, polite) = target;
        let manager = self.clone();
        self.runtime.spawn(async move {
            if let Some(lines) = polite {
                if let Some(i) = &input {
                    for line in lines {
                        let _ = i.send(Input::Line(line));
                    }
                }
                tokio::time::sleep(Duration::from_millis(2_500)).await;
                if !manager.same_process(id, generation) {
                    return;
                }
                if let Some(i) = &input {
                    let _ = i.send(Input::Close);
                }
            }
            interrupt(pid);
            tokio::time::sleep(Duration::from_secs(4)).await;
            if manager.same_process(id, generation) {
                terminate(pid);
            }
            tokio::time::sleep(Duration::from_secs(4)).await;
            if manager.same_process(id, generation) {
                manager.force_kill(id);
            }
        });
    }

    fn same_process(&self, id: Uuid, generation: u64) -> bool {
        self.lock().processes.get(&id).map(|p| p.generation) == Some(generation)
    }

    fn force_kill(&self, id: Uuid) {
        let mut s = self.lock();
        if let Some(p) = s.processes.get_mut(&id) {
            if let Some(k) = p.kill.take() {
                let _ = k.send(());
            }
        }
    }

    // MARK: Toestemming en vragen

    pub fn decide(&self, run_id: Uuid, request_id: &str, decision: ApprovalDecision) -> Result<(), String> {
        self.decide_with_reason(run_id, request_id, decision, None)
    }

    /// Decides; with Deny and a reason the agent hears why. Claude Code takes it as the denial's message; the agents on
    /// a driver (Codex, ACP) have no field for it, so it goes to them as a steer, or else first in the queue.
    pub fn decide_with_reason(
        &self,
        run_id: Uuid,
        request_id: &str,
        decision: ApprovalDecision,
        reason: Option<&str>,
    ) -> Result<(), String> {
        let reason = reason.map(str::trim).filter(|r| !r.is_empty() && decision == ApprovalDecision::Deny).map(String::from);
        let mut tell_after = None;
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let pending = s
                .approvals
                .get(&run_id)
                .and_then(|l| l.iter().find(|p| p.id == request_id))
                .cloned()
                .ok_or(tr("Deze vraag bestaat niet meer.", "This question no longer exists."))?;
            let input = s.processes.get(&run_id).and_then(|p| p.input.clone());
            let Some(input) = input else {
                Self::expire_approval(&mut s, run_id, request_id, &mut out);
                drop(s);
                self.emit(out);
                return Err(
                    tr("De agent draait niet meer; de vraag is verlopen.", "The agent no longer runs; the question has expired.").into()
                );
            };
            let allow = decision != ApprovalDecision::Deny && decision != ApprovalDecision::Terminal;
            self.recap.note(|r, now| r.decision(allow, now));
            let rules = (decision == ApprovalDecision::Always && pending.can_always()).then_some(pending.suggestions.clone()).flatten();
            let lines = match s.processes.get_mut(&run_id).and_then(|p| p.driver.as_mut()) {
                Some(d) => {
                    tell_after = reason.clone();
                    d.decide(request_id, allow, rules.is_some())
                }
                None => vec![parsers::claude_permission_response(
                    request_id,
                    allow,
                    &pending.input,
                    rules.as_ref(),
                    reason.as_deref().unwrap_or(""),
                )],
            };
            for line in lines {
                let _ = input.send(Input::Line(line));
            }
            if let Some(l) = s.approvals.get_mut(&run_id) {
                l.retain(|p| p.id != request_id);
            }
            Self::mutate(&mut s, run_id, pending.event_id, &mut out, |e| {
                e.state = Some(if allow { EventState::Allowed } else { EventState::Denied })
            });
            if s.approvals.get(&run_id).is_none_or(Vec::is_empty) && s.questions.get(&run_id).is_none_or(Vec::is_empty) {
                Self::update(&mut s, run_id, |r| {
                    r.move_to(RunStatus::Running, None, Utc::now());
                });
            }
            out.push(ManagerEvent::ApprovalGone(format!("run-{request_id}")));
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        if let Some(text) = tell_after {
            if !self.steer(run_id, &text) {
                self.enqueue(run_id, &text);
            }
        }
        Ok(())
    }

    fn expire_approval(s: &mut Inner, run_id: Uuid, request_id: &str, out: &mut Out) {
        let Some(pending) = s.approvals.get(&run_id).and_then(|l| l.iter().find(|p| p.id == request_id)).cloned() else { return };
        if let Some(l) = s.approvals.get_mut(&run_id) {
            l.retain(|p| p.id != request_id);
        }
        Self::mutate(s, run_id, pending.event_id, out, |e| e.state = Some(EventState::Expired));
        out.push(ManagerEvent::ApprovalGone(format!("run-{request_id}")));
    }

    fn expire_approvals(s: &mut Inner, run_id: Uuid, out: &mut Out) {
        let ids: Vec<String> = s.approvals.get(&run_id).map(|l| l.iter().map(|p| p.id.clone()).collect()).unwrap_or_default();
        for id in ids {
            Self::expire_approval(s, run_id, &id, out);
        }
        s.approvals.remove(&run_id);
    }

    fn drop_questions(s: &mut Inner, run_id: Uuid, out: &mut Out) {
        for q in s.questions.remove(&run_id).unwrap_or_default() {
            out.push(ManagerEvent::QuestionGone(format!("runq:{run_id}:{}", q.id)));
        }
        Self::sync_waiting(s, run_id);
    }

    /// Beantwoordt een meerkeuzevraag: per vraag de gekozen labels.
    pub fn answer_question(self: &Arc<Self>, run_id: Uuid, request_id: &str, selections: &[Vec<String>]) -> Result<(), String> {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let q = s
                .questions
                .get(&run_id)
                .and_then(|l| l.iter().find(|q| q.id == request_id))
                .cloned()
                .ok_or(tr("Deze vraag bestaat niet meer.", "This question no longer exists."))?;
            if q.restored {
                // Nobody waits for it any more: the answer reaches the agent as a message and picks the conversation up.
                if let Some(l) = s.questions.get_mut(&run_id) {
                    l.retain(|x| x.id != request_id);
                }
                Self::sync_waiting(&mut s, run_id);
                out.push(ManagerEvent::QuestionGone(format!("runq:{run_id}:{request_id}")));
                out.push(ManagerEvent::Changed);
                let text = super::restart::answer_message(&q.items, selections, true);
                drop(s);
                self.emit(out);
                return self.send(run_id, &text);
            }
            let input = s
                .processes
                .get(&run_id)
                .and_then(|p| p.input.clone())
                .ok_or(tr("De agent draait niet meer.", "The agent no longer runs."))?;
            let answers: Vec<(String, Vec<String>)> =
                q.items.iter().zip(selections).map(|(i, sel)| (i.question.clone(), sel.clone())).collect();
            let lines = match s.processes.get_mut(&run_id).and_then(|p| p.driver.as_mut()) {
                Some(d) => d.answer(request_id, &answers).unwrap_or_default(),
                None => vec![parsers::claude_question_answer(request_id, &q.input, &answers)],
            };
            for line in lines {
                let _ = input.send(Input::Line(line));
            }
            if let Some(l) = s.questions.get_mut(&run_id) {
                l.retain(|x| x.id != request_id);
            }
            Self::sync_waiting(&mut s, run_id);
            let event = s
                .events
                .get(&run_id)
                .and_then(|l| l.iter().rev().find(|e| e.kind == EventKind::Approval && e.call_id.as_deref() == Some(request_id)))
                .map(|e| e.id);
            let summary = selections.iter().flatten().cloned().collect::<Vec<_>>().join(", ");
            if let Some(e) = event {
                Self::mutate(&mut s, run_id, e, &mut out, |e| {
                    e.state = Some(EventState::Allowed);
                    e.output = Some(format!("Je koos: {summary}"));
                });
            }
            if s.approvals.get(&run_id).is_none_or(Vec::is_empty) && s.questions.get(&run_id).is_none_or(Vec::is_empty) {
                Self::update(&mut s, run_id, |r| {
                    r.move_to(RunStatus::Running, None, Utc::now());
                });
            }
            out.push(ManagerEvent::QuestionGone(format!("runq:{run_id}:{request_id}")));
            out.push(ManagerEvent::Changed);
        }
        self.emit(out);
        Ok(())
    }

    // MARK: Beheer

    pub fn rename(&self, id: Uuid, title: &str) {
        let clean: String = title.trim().chars().take(120).collect();
        if clean.is_empty() {
            return;
        }
        let mut s = self.lock();
        Self::update(&mut s, id, |r| r.title = clean);
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    /// Sets or clears a session's active goal (`/goal`, AG-67). Empty/whitespace clears it.
    pub fn set_goal(&self, id: Uuid, goal: Option<String>) -> Result<Option<String>, String> {
        let normalized = super::context_usage::normalize_goal(goal.as_deref());
        let mut s = self.lock();
        if !s.runs.iter().any(|r| r.id == id) {
            return Err(tr("Deze sessie bestaat niet meer.", "This session no longer exists.").into());
        }
        Self::update(&mut s, id, |r| {
            r.goal = normalized.clone();
            r.updated_at = Utc::now();
        });
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
        Ok(normalized)
    }

    /// Computes the context window breakdown and compaction pressure for a session (AG-65, AG-66 & AG-32).
    pub fn context_usage(&self, id: Uuid) -> Option<super::context_usage::ContextUsage> {
        let (mut run, events, offered_commands) = {
            let mut s = self.lock();
            Self::load_timeline(&self.store, &mut s, id);
            let run = s.runs.iter().find(|r| r.id == id)?.clone();
            let live_context = s.turns.get(&id).filter(|t| !t.finished).and_then(|t| t.last_context);
            let mut run = run;
            if let Some(live) = live_context {
                run.usage.context_tokens = Some(live);
            }
            let events = s.events.get(&id).cloned().unwrap_or_default();
            let offered_commands: Vec<String> =
                s.commands.get(&id).map(|cmds| cmds.iter().map(|c| c.name.clone()).collect()).unwrap_or_default();
            (run, events, offered_commands)
        };
        // If context_window is not yet reported on an active compaction turn, keep computing when window is known.
        if run.usage.context_window.is_none() && run.usage.context_tokens.is_some() {
            run.usage.context_window = None;
        }
        let auto_compact_at = self.auto_compact_at(&run, &offered_commands);
        super::context_usage::compute_with_mark(&run, &events, auto_compact_at)
    }

    /// Computes where automatic compaction happens for `run`, combining Nook's `SizeCompaction` limit with Claude Code's
    /// own `autoCompactWindow` when present (`AutoCompactMark` / AG-32).
    fn auto_compact_at(&self, run: &WorkspaceRun, offered_commands: &[String]) -> Option<u64> {
        let nook_limit = if super::token_savings::can_compact(run.provider, offered_commands) {
            super::token_savings::SizeCompaction::limit(super::token_savings::auto_compact_tokens(), run.usage.context_window)
        } else {
            None
        };
        let agent_threshold = match run.provider {
            RunProvider::Claude => {
                let env = (self.hooks.account_environment)(&run.profile_id);
                let config_dir = env.get("CLAUDE_CONFIG_DIR").map(String::as_str);
                let files = super::token_savings::ClaudeToolSearch::settings_files(&run.working_directory, config_dir);
                let model = run.resolved_model.as_deref().unwrap_or(&run.model);
                let window = super::token_savings::AutoCompactMark::claude_window(&files, model);
                super::token_savings::AutoCompactMark::claude_threshold(window, run.usage.context_window)
            }
            _ => None,
        };
        super::token_savings::AutoCompactMark::tokens(nook_limit, agent_threshold)
    }

    /// Triggers a delayed quiet `/compact` turn after a completed turn whose context crossed `SizeCompaction` (AG-32).
    fn maybe_compact_for_size(self: &Arc<Self>, id: Uuid, already_compacted: bool) {
        let should = {
            let s = self.lock();
            let Some(run) = s.runs.iter().find(|r| r.id == id) else { return };
            let offered: Vec<String> = s.commands.get(&id).map(|cmds| cmds.iter().map(|c| c.name.clone()).collect()).unwrap_or_default();
            let holds = !s.approvals.get(&id).is_none_or(Vec::is_empty)
                || !s.questions.get(&id).is_none_or(Vec::is_empty)
                || run.pending_handoff.is_some()
                || run.pending_rollback.is_some();
            super::token_savings::SizeCompaction::should_compact(
                super::token_savings::auto_compact_tokens(),
                run.usage.context_tokens,
                run.usage.context_window,
                super::token_savings::can_compact(run.provider, &offered),
                run.status == RunStatus::Completed,
                holds,
                false,
                already_compacted,
            )
        };
        if !should {
            return;
        }
        let manager = self.clone();
        self.runtime.spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
            let executable = {
                let mut s = manager.lock();
                if s.quitting || s.processes.contains_key(&id) || s.idle_compacting.contains(&id) {
                    return;
                }
                let Some(run) = s.runs.iter().find(|r| r.id == id) else { return };
                if run.status != RunStatus::Completed {
                    return;
                }
                let Some(exec) = (manager.hooks.executable)(run.provider) else { return };
                s.idle_compacting.insert(id);
                exec
            };
            manager.launch_turn(id, "/compact".into(), executable, false);
        });
    }

    /// Scans idle sessions and sends a quiet `/compact` before their prompt cache expires (`IdleCompaction` / AG-32).
    pub fn check_idle_compactions(self: &Arc<Self>) {
        if !super::token_savings::idle_compaction_enabled() {
            return;
        }
        let now = Utc::now();
        let due: Vec<(Uuid, String)> = {
            let mut s = self.lock();
            if s.quitting {
                return;
            }
            let mut due = Vec::new();
            let snapshot: Vec<WorkspaceRun> = s.runs.iter().filter(|r| r.prompt_cache.is_some()).cloned().collect();
            for run in snapshot {
                let id = run.id;
                if s.processes.contains_key(&id) || s.idle_compacting.contains(&id) {
                    continue;
                }
                let holds = !s.approvals.get(&id).is_none_or(Vec::is_empty)
                    || !s.questions.get(&id).is_none_or(Vec::is_empty)
                    || !s.queues.get(&id).is_none_or(MessageQueue::is_empty)
                    || run.pending_handoff.is_some()
                    || run.pending_rollback.is_some();
                let candidate = super::token_savings::IdleCandidate {
                    agent_reports_cache_lifetime: run.provider.capabilities().reports_prompt_cache_lifetime,
                    status: run.status,
                    archived: run.archived,
                    settled: false,
                    snoozed_until: None,
                    context_tokens: run.usage.context_tokens,
                    cache: run.prompt_cache.clone(),
                    holds_for_you: holds,
                    is_remote: false,
                };
                if let Some(fire) = super::token_savings::IdleCompaction::fire_date(&candidate, now) {
                    if fire <= now {
                        if let Some(exec) = (self.hooks.executable)(run.provider) {
                            s.idle_compacting.insert(id);
                            due.push((id, exec));
                        }
                    }
                }
            }
            due
        };
        for (id, exec) in due {
            self.launch_turn(id, "/compact".into(), exec, false);
        }
    }

    /// Whether the session should offer a "Compact first" chip before sending the next message (`ReturnCompaction` / AG-32).
    pub fn offers_compact_first(&self, id: Uuid) -> bool {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return false };
        let offered: Vec<String> = s.commands.get(&id).map(|cmds| cmds.iter().map(|c| c.name.clone()).collect()).unwrap_or_default();
        let candidate = super::token_savings::ReturnCandidate {
            agent_reports_cache_lifetime: run.provider.capabilities().reports_prompt_cache_lifetime,
            can_compact: super::token_savings::can_compact(run.provider, &offered),
            enabled: super::token_savings::idle_compaction_enabled(),
            status: run.status,
            context_tokens: run.usage.context_tokens,
            cache: run.prompt_cache.clone(),
            is_remote: false,
        };
        super::token_savings::ReturnCompaction::offers(&candidate, Utc::now())
    }

    pub fn set_archived(&self, id: Uuid, archived: bool) {
        let mut s = self.lock();
        if s.runs.iter().find(|r| r.id == id).is_some_and(|r| archived && r.status.is_active()) {
            return;
        }
        Self::update(&mut s, id, |r| r.archived = archived);
        if archived {
            Self::clear_usage_limit(&mut s, id);
        }
        drop(s);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    // MARK: Gebruikslimieten

    /// Claude Code meldde een limiet tijdens de beurt: een geblokkeerd venster komt (één keer) in de tijdlijn.
    fn note_claude_limit(s: &mut Inner, id: Uuid, event: limits::ClaudeLimitEvent, out: &mut Out) {
        let Some(turn) = s.turns.get_mut(&id) else { return };
        if event.blocked {
            let first = turn.limit_windows.is_empty();
            turn.limit_windows.insert(event.window, event.resets_at);
            if first {
                Self::append(s, id, RunEvent::new(EventKind::System, limits::limit_text(event.resets_at, Utc::now())), out);
            }
        } else {
            turn.limit_windows.remove(&event.window);
        }
    }

    /// Na een beurt: stopte een gebruikslimiet hem? Dan wacht de sessie op de reset (en gaat dan door, als dat aan staat).
    fn check_usage_limit(self: &Arc<Self>, id: Uuid) {
        {
            let mut s = self.lock();
            let Some(known) = s.limited.remove(&id) else { return };
            if s.runs.iter().find(|r| r.id == id).is_none_or(|r| r.status != RunStatus::Failed) {
                return;
            }
            let auto = (self.hooks.auto_resume_limited)() && known.is_some();
            Self::update(&mut s, id, |r| {
                r.limited_at = Some(Utc::now());
                r.limit_reset_at = known;
                r.auto_resume = auto;
            });
        }
        self.arm_limit_resume(id);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    /// "Hervat bij reset" aan of uit voor deze sessie.
    pub fn set_auto_resume(self: &Arc<Self>, id: Uuid, on: bool) {
        {
            let mut s = self.lock();
            if s.runs.iter().find(|r| r.id == id).is_none_or(|r| r.limited_at.is_none() || r.limit_reset_at.is_none()) {
                return;
            }
            Self::update(&mut s, id, |r| r.auto_resume = on);
        }
        self.arm_limit_resume(id);
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    fn clear_usage_limit(s: &mut Inner, id: Uuid) {
        s.limit_resumes.remove(&id);
        s.limited.remove(&id);
        if s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.limited_at.is_some()) {
            Self::update(s, id, |r| {
                r.limited_at = None;
                r.limit_reset_at = None;
                r.auto_resume = false;
            });
        }
    }

    fn arm_limit_resume(self: &Arc<Self>, id: Uuid) {
        let (token, wait) = {
            let mut s = self.lock();
            s.limit_resumes.remove(&id);
            let Some(run) = s.runs.iter().find(|r| r.id == id) else { return };
            let (true, Some(reset)) = (run.auto_resume, run.limit_reset_at) else { return };
            // Even na de reset, zodat de limiet echt weer vrij is.
            let wait = (reset - Utc::now()).num_milliseconds().max(0) as u64 + 20_000;
            s.generation += 1;
            let token = s.generation;
            s.limit_resumes.insert(id, token);
            (token, wait)
        };
        let manager = self.clone();
        self.runtime.spawn(async move {
            tokio::time::sleep(Duration::from_millis(wait)).await;
            manager.resume_after_limit(id, token);
        });
    }

    /// Vlak voor het versturen opnieuw gecontroleerd: nog steeds aan het wachten, nog steeds gewild, niets open, niet
    /// gearchiveerd.
    fn resume_after_limit(self: &Arc<Self>, id: Uuid, token: u64) {
        {
            let mut s = self.lock();
            if s.limit_resumes.get(&id) != Some(&token) {
                return;
            }
            s.limit_resumes.remove(&id);
            let Some(run) = s.runs.iter().find(|r| r.id == id) else { return };
            let ready = run.auto_resume
                && run.limited_at.is_some()
                && run.limit_reset_at.is_some_and(|r| r <= Utc::now())
                && !run.archived
                && !run.status.is_active()
                && s.approvals.get(&id).is_none_or(Vec::is_empty)
                && s.questions.get(&id).is_none_or(Vec::is_empty);
            if !ready {
                return;
            }
            let mut out = Out::default();
            Self::append(
                &mut s,
                id,
                RunEvent::new(
                    EventKind::System,
                    tr("De gebruikslimiet is vrij: de sessie gaat verder.", "The usage limit has reset: the session carries on."),
                ),
                &mut out,
            );
            drop(s);
            self.emit(out);
        }
        let _ = self.send(id, limits::RESUME_MESSAGE);
    }

    pub fn mark_reviewed(&self, id: Uuid) {
        let mut s = self.lock();
        Self::update(&mut s, id, |r| r.reviewed_at = Some(Utc::now()));
    }

    /// Haalt een sessie uit Nook. De map of worktree blijft staan; een lopende sessie nooit.
    pub fn delete(&self, id: Uuid) -> Result<(), String> {
        let run = {
            let mut s = self.lock();
            let run = s
                .runs
                .iter()
                .find(|r| r.id == id)
                .cloned()
                .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
            if run.status.is_active() || s.processes.contains_key(&id) {
                return Err(tr("Kan niet terwijl de agent werkt.", "Not possible while the agent works.").into());
            }
            s.runs.retain(|r| r.id != id);
            s.events.remove(&id);
            s.approvals.remove(&id);
            s.questions.remove(&id);
            s.queues.remove(&id);
            s.capacity.forget(id);
            s.worktree_setups.remove(&id);
            if let Some(handle) = s.prepare_tasks.remove(&id) {
                handle.abort();
            }
            s.git.remove(&id);
            s.dirty_runs = true;
            s.dirty_queues = true;
            run
        };
        self.store.delete_events(id);
        if let (Some(root), Some(git)) = (&run.repo_root, &self.git) {
            if !run.checkpoints.is_empty() {
                git.remove_checkpoints(root, &id.to_string());
            }
        }
        self.emit(Out(vec![ManagerEvent::Changed]));
        Ok(())
    }

    // MARK: Git

    /// A folder became a git repository (`git init` on a session without a project): the sessions working there get it
    /// as their repository, and their changes are read.
    pub fn adopt_repository(self: &Arc<Self>, dir: &str) {
        let clean = dir.trim_end_matches(['/', '\\']);
        let ids: Vec<Uuid> = {
            let mut s = self.lock();
            let ids: Vec<Uuid> = s
                .runs
                .iter()
                .filter(|r| r.repo_root.is_none() && r.working_directory.trim_end_matches(['/', '\\']) == clean)
                .map(|r| r.id)
                .collect();
            for id in &ids {
                Self::update(&mut s, *id, |r| r.repo_root = Some(clean.to_string()));
            }
            ids
        };
        for id in ids {
            self.refresh_git(id);
        }
        self.emit(Out(vec![ManagerEvent::Changed]));
    }

    pub fn refresh_git(self: &Arc<Self>, id: Uuid) {
        let Some(git) = self.git.clone() else { return };
        let Some(run) = self.run(id).filter(|r| r.repo_root.is_some()) else { return };
        {
            let mut s = self.lock();
            s.git.entry(id).or_default().loading = true;
        }
        let manager = self.clone();
        self.runtime.spawn_blocking(move || {
            let dir = run.working_directory.clone();
            let mut snap = GitSnapshot::default();
            if Path::new(&dir).exists() {
                match git.status(&dir) {
                    Ok(st) => snap.status = Some(st),
                    Err(e) => snap.error = Some(e.0),
                }
                if let Some(base) = &run.base_branch {
                    if let Some((a, b)) = git.divergence(&dir, base) {
                        snap.ahead = Some(a);
                        snap.behind = Some(b);
                    }
                }
            } else {
                snap.error =
                    Some(trf("De werkmap bestaat niet meer: {dir}", "The working folder no longer exists: {dir}", &[("dir", &dir)]));
            }
            {
                let mut s = manager.lock();
                if let Some(st) = &snap.status {
                    let count = st.files.len() as u32;
                    let added = st.files.iter().filter_map(|f| f.added).sum::<u64>();
                    let removed = st.files.iter().filter_map(|f| f.removed).sum::<u64>();
                    Self::update(&mut s, id, |r| {
                        r.changed_files = Some(count);
                        r.lines_added = Some(added);
                        r.lines_removed = Some(removed);
                    });
                }
                s.git.insert(id, snap);
            }
            manager.emit(Out(vec![ManagerEvent::Changed]));
        });
    }

    pub fn diff(&self, id: Uuid, file: &git::FileChange) -> Result<String, String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        git.diff(&run.working_directory, file).map_err(|e| e.0)
    }

    pub fn commit(self: &Arc<Self>, id: Uuid, message: &str, paths: &[String]) -> Result<String, String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        if run.status.is_active() {
            return Err(tr("Kan niet terwijl de agent werkt.", "Not possible while the agent works.").into());
        }
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let sha = git.commit(&run.working_directory, message, paths).map_err(|e| e.0)?;
        let mut out = Out::default();
        {
            let mut s = self.lock();
            Self::append(
                &mut s,
                id,
                RunEvent::new(EventKind::System, format!("Commit {sha}: {}", tool_summary::one_line(message, 80))),
                &mut out,
            );
            Self::update(&mut s, id, |r| r.reviewed_at = Some(Utc::now()));
        }
        self.emit(out);
        self.refresh_git(id);
        Ok(sha)
    }

    pub fn push(self: &Arc<Self>, id: Uuid) -> Result<String, String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let dir = &run.working_directory;
        let branch = git.current_branch(dir).ok_or(tr("Er is geen branch uitgecheckt.", "No branch is checked out."))?;
        let remotes = git.remotes(dir);
        let remote = if remotes.iter().any(|r| r == "origin") {
            "origin".to_string()
        } else {
            remotes.first().cloned().unwrap_or_else(|| "origin".into())
        };
        git.push(dir, &remote, &branch).map_err(|e| e.0)?;
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, format!("Gepusht: {branch} naar {remote}")), &mut out);
        self.emit(out);
        self.refresh_git(id);
        Ok(branch)
    }

    /// Een nieuwe branch voor een nieuwe pull request, met de niet-gecommitte wijzigingen mee. Geeft de naam en het
    /// snijpunt voor `move_onto_base`.
    pub fn start_branch(self: &Arc<Self>, id: Uuid, topic: &str) -> Result<(String, Option<String>), String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        if run.status.is_active() {
            return Err(tr("Kan niet terwijl de agent werkt.", "Not possible while the agent works.").into());
        }
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let dir = &run.working_directory;
        let name = super::models::branch_name(topic, Uuid::new_v4());
        let cut = git.start_branch(dir, &name, &Self::push_remote(git, dir)).map_err(|e| e.0)?;
        let mut out = Out::default();
        {
            let mut s = self.lock();
            Self::append(
                &mut s,
                id,
                RunEvent::new(
                    EventKind::System,
                    trf(
                        "Branch {name} gestart voor een nieuwe pull request",
                        "Started branch {name} for a new pull request",
                        &[("name", &name)],
                    ),
                ),
                &mut out,
            );
            Self::update(&mut s, id, |r| r.branch = Some(name.clone()));
        }
        self.emit(out);
        self.refresh_git(id);
        Ok((name, cut))
    }

    /// Alleen het nieuwe werk in de nieuwe pull request: de commits na `cut` op de basis van de sessie.
    pub fn move_onto_base(self: &Arc<Self>, id: Uuid, cut: &str) -> Result<bool, String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let dir = &run.working_directory;
        let remote = Self::push_remote(git, dir);
        let base = git
            .default_branch(dir, &remote)
            .or_else(|| run.base_branch.clone().map(|b| b.trim_start_matches("origin/").to_string()))
            .ok_or(tr("De basisbranch is onbekend.", "The base branch is unknown."))?;
        let moved = git.move_onto_base(dir, &base, &remote, cut);
        self.refresh_git(id);
        Ok(moved)
    }

    fn push_remote(git: &Git, dir: &str) -> String {
        let remotes = git.remotes(dir);
        if remotes.iter().any(|r| r == "origin") {
            "origin".to_string()
        } else {
            remotes.first().cloned().unwrap_or_else(|| "origin".into())
        }
    }

    /// Alleen fast-forward, nooit terwijl de agent werkt.
    pub fn pull(self: &Arc<Self>, id: Uuid) -> Result<(), String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        if run.status.is_active() {
            return Err(tr("Kan niet terwijl de agent werkt.", "Not possible while the agent works.").into());
        }
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        git.pull_fast_forward(&run.working_directory).map_err(|e| e.0)?;
        self.note(id, tr("Gepulld (alleen fast-forward)", "Pulled (fast-forward only)"));
        self.refresh_git(id);
        Ok(())
    }

    /// Een systeemregel in de tijdlijn (bijvoorbeeld "Pull request geopend: …").
    pub fn note(&self, id: Uuid, text: &str) {
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, text), &mut out);
        self.emit(out);
    }

    /// A card a bridge tool puts in the session's own timeline (`session_suggest`'s suggestion, `render_page`'s page).
    pub fn append_event(&self, id: Uuid, event: RunEvent) {
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, event, &mut out);
        self.emit(out);
    }

    /// Changes one event of a session's timeline in place (a suggestion card after you chose on it). False when the
    /// session or the event is gone.
    pub fn change_event(&self, id: Uuid, event_id: Uuid, change: impl FnOnce(&mut RunEvent)) -> bool {
        let mut out = Out::default();
        let mut found = false;
        {
            let mut s = self.lock();
            Self::mutate(&mut s, id, event_id, &mut out, |e| {
                found = true;
                change(e);
            });
        }
        self.emit(out);
        found
    }

    /// One event of a session's timeline by id.
    pub fn event(&self, id: Uuid, event_id: Uuid) -> Option<RunEvent> {
        self.lock().events.get(&id).and_then(|l| l.iter().rev().find(|e| e.id == event_id).cloned())
    }

    /// The first line of a session that someone else started ("Started by …", "Delegated by …"): a note tagged
    /// `origin`, so the transcript draws it with the Mac's arrow (`TranscriptWorkLine`) instead of an info mark.
    pub fn note_origin(&self, id: Uuid, text: &str) {
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, text).with_tool("origin"), &mut out);
        self.emit(out);
    }

    /// `/clear` (`clearConversation` on the Mac): the session goes on in a new, empty conversation with the same agent,
    /// in the same folder and on the same branch. The agent forgets everything so far; the timeline stays, with a
    /// divider (`tool: "clear"`) where the new conversation starts. Not while the agent works. The same for every agent:
    /// each one starts its next turn without a session to resume.
    pub fn clear_conversation(&self, id: Uuid) -> bool {
        let cleared = self.update_between_turns(id, |r| {
            r.provider_session_id = None;
            r.pending_handoff = None;
            r.conversation = None;
            r.pending_rollback = None;
            r.goal = None;
            r.compacting = false;
        });
        let mut out = Out::default();
        let event = if cleared {
            RunEvent::new(EventKind::System, tr("Nieuw gesprek", "New conversation")).with_tool("clear")
        } else {
            RunEvent::new(EventKind::System, tr("/clear wacht tot de agent gestopt is.", "/clear waits until the agent has stopped."))
        };
        if self.run(id).is_some() {
            Self::append(&mut self.lock(), id, event, &mut out);
            self.emit(out);
        }
        cleared
    }

    /// Changes a session between turns, for features in their own files (handing it to another agent, `handoff.rs`).
    /// `false` while it works or when it is gone; nothing changes then.
    pub fn update_between_turns(&self, id: Uuid, change: impl FnOnce(&mut WorkspaceRun)) -> bool {
        let mut s = self.lock();
        let free = s.runs.iter().any(|r| r.id == id && !r.status.is_active()) && !s.processes.contains_key(&id);
        if free {
            Self::update(&mut s, id, change);
        }
        drop(s);
        if free {
            self.emit(Out(vec![ManagerEvent::Changed]));
        }
        free
    }

    /// The `/` commands the session's agent announced itself (`acpCommands` on the Mac).
    pub fn agent_commands(&self, id: Uuid) -> Vec<driver::SlashCommand> {
        self.lock().commands.get(&id).cloned().unwrap_or_default()
    }

    /// The process of the agent working for a session now, for its CPU and memory (`agentPIDs` on the Mac).
    pub fn agent_pid(&self, id: Uuid) -> Option<u32> {
        self.lock().processes.get(&id).and_then(|p| p.pid)
    }

    pub fn git(&self) -> Option<&Git> {
        self.git.as_ref()
    }

    /// Haalt de worktree van een sessie weg. Nooit terwijl de sessie loopt; niet-vastgelegd werk vraagt `force`.
    pub fn remove_worktree(self: &Arc<Self>, id: Uuid, force: bool) -> Result<(), String> {
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let (Some(path), Some(repo)) = (run.worktree_path.clone(), run.repo_root.clone()) else { return Ok(()) };
        self.remove_worktree_at(&repo, &path, force)
    }

    /// Haalt een worktree weg die bij geen actieve sessie hoort (vanuit het overzicht).
    pub fn remove_worktree_at(self: &Arc<Self>, repo: &str, path: &str, force: bool) -> Result<(), String> {
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let target = paths::normalize(path);
        {
            let s = self.lock();
            if s.runs
                .iter()
                .any(|r| (r.status.is_active() || s.processes.contains_key(&r.id)) && paths::normalize(&r.working_directory) == target)
            {
                return Err(tr(
                    "Er werkt nog een sessie in deze worktree. Stop die eerst.",
                    "A session still works in this worktree. Stop it first.",
                )
                .into());
            }
        }
        git.remove_worktree(repo, path, force).map_err(|e| e.0)?;
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let ids: Vec<Uuid> = s.runs.iter().filter(|r| paths::normalize(&r.working_directory) == target).map(|r| r.id).collect();
            for id in ids {
                Self::append(
                    &mut s,
                    id,
                    RunEvent::new(
                        EventKind::System,
                        trf("Worktree verwijderd: {path}", "Worktree removed: {path}", &[("path", &crate::agents::tilde(path))]),
                    ),
                    &mut out,
                );
                Self::update(&mut s, id, |r| r.status_detail = Some("worktreeRemoved".into()));
                s.git.remove(&id);
            }
        }
        out.push(ManagerEvent::Changed);
        self.emit(out);
        self.refresh_worktrees();
        Ok(())
    }

    /// Alle worktrees van repositories met sessies, met de sessies erbij en hun wijzigingen.
    pub fn refresh_worktrees(self: &Arc<Self>) {
        let Some(git) = self.git.clone() else { return };
        let runs = self.runs();
        let manager = self.clone();
        self.runtime.spawn_blocking(move || {
            let mut repos: Vec<String> = runs.iter().filter_map(|r| r.repo_root.clone()).collect();
            repos.sort();
            repos.dedup();
            let mut rows = vec![];
            for repo in repos.iter().filter(|r| Path::new(r).exists()) {
                let Ok(list) = git.worktrees(repo) else { continue };
                for w in list {
                    let path = paths::normalize(&w.path);
                    let linked: Vec<&WorkspaceRun> = runs.iter().filter(|r| paths::normalize(&r.working_directory) == path).collect();
                    // De hoofdmap alleen als er een sessie in werkt.
                    if w.is_main && linked.is_empty() {
                        continue;
                    }
                    let mut row = WorktreeRow {
                        repo_root: repo.clone(),
                        worktree: w.clone(),
                        run_ids: linked.iter().map(|r| r.id).collect(),
                        changed_files: None,
                        ahead: None,
                        behind: None,
                        base_branch: linked.iter().find_map(|r| r.base_branch.clone()),
                    };
                    if Path::new(&w.path).exists() {
                        row.changed_files = git.changed_file_count(&w.path);
                        if let Some(base) = &row.base_branch {
                            if let Some((a, b)) = git.divergence(&w.path, base) {
                                row.ahead = Some(a);
                                row.behind = Some(b);
                            }
                        }
                    }
                    rows.push(row);
                }
            }
            manager.lock().worktrees = rows;
            manager.emit(Out(vec![ManagerEvent::Changed]));
        });
    }

    fn conversation_mark(run: &WorkspaceRun) -> Option<ConversationMark> {
        if !rollback::can_roll_back(run.provider) {
            return None;
        }
        Some(run.conversation.as_ref().map_or_else(ConversationMark::empty, ConversationLog::mark))
    }

    fn note_conversation_turn(s: &mut Inner, id: Uuid, turn_id: Option<&str>) {
        Self::update(s, id, |r| {
            if !rollback::can_roll_back(r.provider) {
                return;
            }
            let session = r.provider_session_id.clone();
            let log = r.conversation.get_or_insert_with(|| ConversationLog::new(None, r.provider));
            if let Some(sid) = session.as_deref() {
                log.note_session(sid, r.provider);
            }
            log.start_turn(turn_id);
        });
    }

    fn note_conversation_head(s: &mut Inner, id: Uuid, uuid: &str) {
        Self::update(s, id, |r| {
            if r.provider != RunProvider::Claude {
                return;
            }
            let session = r.provider_session_id.clone();
            let log = r.conversation.get_or_insert_with(|| ConversationLog::new(None, r.provider));
            if let Some(sid) = session.as_deref() {
                log.note_session(sid, r.provider);
            }
            log.note_head(uuid);
        });
    }

    fn mark_conversation_inexact(s: &mut Inner, id: Uuid) {
        Self::update(s, id, |r| {
            if !rollback::can_roll_back(r.provider) {
                return;
            }
            let log = r.conversation.get_or_insert_with(|| ConversationLog::new(None, r.provider));
            log.exact = false;
        });
    }

    fn plan_for(run: &WorkspaceRun, mark: Option<&ConversationMark>) -> Plan {
        rollback::plan(run.provider, mark, run.conversation.as_ref(), run.provider_session_id.as_deref())
    }

    /// Bestanden kunnen terug naar hoe ze waren vóór een bericht: een worktree-sessie die niets doet, alleen in zijn map.
    pub fn can_revert(&self, id: Uuid, before: DateTime<Utc>) -> bool {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return false };
        run.isolation == IsolationMode::Worktree
            && !run.status.is_active()
            && !s.processes.contains_key(&id)
            && run.checkpoints.iter().any(|c| c.date <= before && !c.r#ref.is_empty())
            && Self::active_sharing(&s, &run.working_directory, Some(id)).is_none()
    }

    /// Whether the agent's conversation itself can be rolled back to before `before` (AG-62).
    pub fn can_rollback_conversation(&self, id: Uuid, before: DateTime<Utc>) -> bool {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return false };
        !run.status.is_active()
            && !s.processes.contains_key(&id)
            && run
                .checkpoints
                .iter()
                .rev()
                .find(|c| c.date <= before && c.conversation.is_some())
                .is_some_and(|c| !matches!(Self::plan_for(run, c.conversation.as_ref()), Plan::Unavailable))
    }

    /// Whether the user can edit from a message at `before` ("Edit from here").
    pub fn can_edit_from_here(&self, id: Uuid, before: DateTime<Utc>) -> bool {
        self.can_rollback_conversation(id, before)
    }

    fn apply_conversation_rollback(
        &self,
        s: &mut Inner,
        id: Uuid,
        checkpoint_index: usize,
        checkpoint: &RunCheckpoint,
        before: DateTime<Utc>,
        out: &mut Out,
    ) -> (bool, Vec<String>) {
        let mut rolled_back = false;
        let mut removed_refs = Vec::new();
        let planned = s.runs.iter().find(|r| r.id == id).map(|run| Self::plan_for(run, checkpoint.conversation.as_ref()));
        Self::update(s, id, |r| {
            if let Some(plan) = planned {
                match plan {
                    Plan::Unavailable => {}
                    Plan::Nothing => {
                        rolled_back = true;
                    }
                    Plan::Fresh => {
                        r.provider_session_id = None;
                        r.pending_rollback = None;
                        if let (Some(log), Some(mark)) = (r.conversation.as_mut(), checkpoint.conversation.as_ref()) {
                            log.rewind(mark);
                        }
                        rolled_back = true;
                    }
                    Plan::Codex { .. } | Plan::ClaudeResume { .. } => {
                        r.pending_rollback = rollback::merge(r.pending_rollback.take(), &plan);
                        if let (Some(log), Some(mark)) = (r.conversation.as_mut(), checkpoint.conversation.as_ref()) {
                            log.rewind(mark);
                        }
                        rolled_back = true;
                    }
                }
            }
            let (kept, trimmed) = rollback::trim(&r.checkpoints, checkpoint_index);
            removed_refs = trimmed.into_iter().filter(|r| !r.is_empty()).collect();
            r.checkpoints = kept;
        });
        if rolled_back {
            Self::load_timeline(&self.store, s, id);
            if let Some(events) = s.events.get_mut(&id) {
                let cutoff = checkpoint.date.min(before - chrono::Duration::nanoseconds(1));
                let ids = rollback::rolled_back_ids(events, cutoff);
                if !ids.is_empty() {
                    for e in events.iter_mut() {
                        if ids.contains(&e.id) {
                            e.rolled_back = Some(true);
                        }
                    }
                    s.dirty_events.insert(id);
                    out.push(ManagerEvent::Timeline(id));
                }
            }
        }
        out.push(ManagerEvent::Changed);
        (rolled_back, removed_refs)
    }

    pub fn revert_files(self: &Arc<Self>, id: Uuid, before: DateTime<Utc>) -> Result<(), String> {
        if !self.can_revert(id, before) {
            return Err(tr(
                "Terugzetten kan alleen bij een sessie in een eigen worktree die niet bezig is.",
                "Files can only be restored for a session in its own worktree that is not busy.",
            )
            .into());
        }
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let (index, checkpoint) = run
            .checkpoints
            .iter()
            .enumerate()
            .rev()
            .find(|(_, c)| c.date <= before && !c.r#ref.is_empty())
            .map(|(i, c)| (i, c.clone()))
            .ok_or(tr("Geen eerder punt gevonden.", "No earlier point found."))?;
        let git = self.git.as_ref().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        git.restore(&run.working_directory, &checkpoint.r#ref).map_err(|e| e.0)?;
        let mut out = Out::default();
        let removed_refs = {
            let mut s = self.lock();
            let (rolled_back, removed_refs) = self.apply_conversation_rollback(&mut s, id, index, &checkpoint, before, &mut out);
            let note = if rolled_back {
                tr(
                    "Bestanden en gesprek teruggezet naar een eerder punt. De agent weet niets meer van de latere berichten.",
                    "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.",
                )
            } else {
                tr("Bestanden teruggezet naar een eerder punt.", "Files restored to an earlier point.")
            };
            Self::append(&mut s, id, RunEvent::new(EventKind::System, note), &mut out);
            removed_refs
        };
        if !removed_refs.is_empty() {
            git.remove_checkpoint_refs(&run.working_directory, &removed_refs);
        }
        self.emit(out);
        self.refresh_git(id);
        Ok(())
    }

    /// Rewinds the conversation to before a user message ("Edit from here"), optionally restoring files too.
    pub fn edit_from_here(self: &Arc<Self>, id: Uuid, before: DateTime<Utc>, reverting_files: bool) -> Result<(), String> {
        if reverting_files {
            return self.revert_files(id, before);
        }
        if !self.can_edit_from_here(id, before) {
            return Err(tr("Deze sessie kan niet terug tot vóór dit bericht.", "This session can't go back to before this message.").into());
        }
        let run = self.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let (index, checkpoint) = run
            .checkpoints
            .iter()
            .enumerate()
            .rev()
            .find(|(_, c)| c.date <= before && !matches!(Self::plan_for(&run, c.conversation.as_ref()), Plan::Unavailable))
            .map(|(i, c)| (i, c.clone()))
            .ok_or(tr("Geen eerder punt gevonden.", "No earlier point found."))?;
        let mut out = Out::default();
        let removed_refs = {
            let mut s = self.lock();
            let (_, removed_refs) = self.apply_conversation_rollback(&mut s, id, index, &checkpoint, before, &mut out);
            Self::append(
                &mut s,
                id,
                RunEvent::new(
                    EventKind::System,
                    tr(
                        "Teruggegaan tot vóór je bericht. De bestanden zijn gebleven zoals ze waren.",
                        "Went back to before your message. The files stayed as they were.",
                    ),
                ),
                &mut out,
            );
            removed_refs
        };
        if !removed_refs.is_empty() {
            if let Some(git) = &self.git {
                git.remove_checkpoint_refs(&run.working_directory, &removed_refs);
            }
        }
        self.emit(out);
        Ok(())
    }

    // MARK: Opslaan

    /// Schrijft weg wat veranderde. De app roept dit elke seconde aan.
    pub fn flush(&self) {
        let (runs, events, queues) = {
            let mut s = self.lock();
            let runs = std::mem::take(&mut s.dirty_runs).then(|| s.runs.clone());
            let ids: Vec<Uuid> = s.dirty_events.drain().collect();
            // Only the part that is saved is copied under the lock, not a long session's whole timeline.
            let events: Vec<(Uuid, Vec<RunEvent>)> = ids
                .into_iter()
                .filter_map(|id| s.events.get(&id).map(|e| (id, e[e.len().saturating_sub(EVENT_LIMIT)..].to_vec())))
                .collect();
            let queues = std::mem::take(&mut s.dirty_queues).then(|| s.queues.clone());
            (runs, events, queues)
        };
        if let Some(r) = runs {
            let _ = self.store.save_runs(&r);
        }
        for (id, e) in events {
            let _ = self.store.save_events(id, &e);
        }
        if let Some(q) = queues {
            self.store.save_queues(&q);
        }
    }

    /// What waits on you in a session, saved with it (`RestartRequests`): the questions come back after a restart.
    fn sync_waiting(s: &mut Inner, id: Uuid) {
        let asked: Vec<super::restart::SavedQuestion> = s
            .questions
            .get(&id)
            .into_iter()
            .flatten()
            .filter(|q| q.items.iter().any(|i| !i.question.is_empty() || !i.options.is_empty()))
            .map(|q| super::restart::SavedQuestion { id: q.id.clone(), items: q.items.clone(), created: q.created })
            .collect();
        let approvals: Vec<String> = s
            .approvals
            .get(&id)
            .into_iter()
            .flatten()
            .map(|p| {
                [p.tool.as_str(), p.summary.as_str()]
                    .iter()
                    .filter(|t| !t.is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(": ")
                    .chars()
                    .take(160)
                    .collect()
            })
            .collect();
        let changed = s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.restart.questions != asked || r.restart.approvals != approvals);
        if changed {
            Self::update(s, id, |r| {
                r.restart.questions = asked;
                r.restart.approvals = approvals;
            });
        }
    }

    /// After a launch: the questions that waited come back to be answered as a message, and each approval that waited
    /// leaves a note that it expired (`restoreWaiting`).
    fn restore_waiting(self: &Arc<Self>) {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let ids: Vec<Uuid> =
                s.runs.iter().filter(|r| !r.restart.questions.is_empty() || !r.restart.approvals.is_empty()).map(|r| r.id).collect();
            for id in ids {
                let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { continue };
                for q in &run.restart.questions {
                    let pending = PendingQuestion {
                        id: q.id.clone(),
                        run_id: id,
                        items: q.items.clone(),
                        input: Value::Null,
                        created: q.created,
                        restored: true,
                    };
                    let list = s.questions.entry(id).or_default();
                    if !list.iter().any(|p| p.id == pending.id) {
                        list.push(pending);
                    }
                }
                if !run.restart.approvals.is_empty() {
                    Self::load_timeline(&self.store, &mut s, id);
                    for summary in &run.restart.approvals {
                        let text = trf(
                            "Nook is opnieuw gestart, dus deze goedkeuring is verlopen: {summary}. Stuur een bericht om verder te gaan.",
                            "Nook restarted, so this approval expired: {summary}. Send a message to go on.",
                            &[("summary", summary)],
                        );
                        Self::append(&mut s, id, RunEvent::new(EventKind::System, text).with_tool("restart"), &mut out);
                    }
                    Self::update(&mut s, id, |r| r.restart.approvals.clear());
                }
            }
        }
        self.emit(out);
    }

    /// "Continue where you left off." once for each session that quitting or restarting Nook cut off, when
    /// `enabled` (Settings › Agents › Sessions › Continue after restart). `skip` holds the sessions you settled or
    /// snoozed. Only the first call after a launch does anything; what is not continued is not continued at a later one.
    pub fn continue_interrupted(self: &Arc<Self>, enabled: bool, skip: &HashSet<Uuid>) -> usize {
        let now = Utc::now();
        let mut go: Vec<(Uuid, bool)> = vec![];
        {
            let mut s = self.lock();
            if s.continued_after_launch {
                return 0;
            }
            s.continued_after_launch = true;
            let ids: Vec<Uuid> = s.runs.iter().map(|r| r.id).collect();
            for id in ids {
                let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { continue };
                let waits = s.questions.get(&id).into_iter().flatten().any(|q| !q.restored);
                if super::restart::should_continue(&run, enabled, waits, skip.contains(&id), now) {
                    // A turn whose result was saved had finished; only its status was not saved yet. Sending it back to
                    // work would repeat what it did: it waits for you like any stopped session.
                    Self::load_timeline(&self.store, &mut s, id);
                    if super::restart::turn_ended(s.events.get(&id).map(Vec::as_slice).unwrap_or(&[])) {
                        Self::update(&mut s, id, |r| r.status_detail = None);
                        continue;
                    }
                    let chain = super::restart::chain_length(&run, now);
                    Self::update(&mut s, id, |r| {
                        r.restart.continuations = chain + 1;
                        r.restart.last_continued_at = Some(now);
                        // No longer "interrupted": a second launch before this turn ends must not continue it again.
                        r.status_detail = None;
                    });
                    go.push((id, true));
                }
            }
            // Only the first launch after the quit counts.
            for id in s.runs.iter().filter(|r| r.restart.stopped_by_quit).map(|r| r.id).collect::<Vec<_>>() {
                Self::update(&mut s, id, |r| r.restart.stopped_by_quit = false);
            }
            s.dirty_runs = true;
        }
        for (id, _) in &go {
            let note = tr("Nook is weer geopend: de sessie gaat verder.", "Nook opened again: the session continues.");
            {
                let mut out = Out::default();
                let mut s = self.lock();
                Self::append(&mut s, *id, RunEvent::new(EventKind::System, note), &mut out);
                drop(s);
                self.emit(out);
            }
            let _ = self.send(*id, super::restart::MESSAGE);
        }
        self.emit(Out(vec![ManagerEvent::Changed]));
        go.len()
    }

    /// Leaves a question that nothing waits for (asked before a restart) unanswered (`dismissQuestion`).
    pub fn dismiss_question(&self, run_id: Uuid, request_id: &str) {
        let mut s = self.lock();
        if !s.questions.get(&run_id).is_some_and(|l| l.iter().any(|q| q.id == request_id && q.restored)) {
            return;
        }
        if let Some(l) = s.questions.get_mut(&run_id) {
            l.retain(|q| q.id != request_id);
        }
        Self::sync_waiting(&mut s, run_id);
        drop(s);
        self.emit(Out(vec![ManagerEvent::QuestionGone(format!("runq:{run_id}:{request_id}")), ManagerEvent::Changed]));
    }

    /// Bij het afsluiten van Nook: lopende agents stoppen en erop wachten (`QuitShutdown`). Eerst een nette vraag om te
    /// stoppen, na de grace een SIGTERM, op één gedeelde deadline een kill: afsluiten duurt nooit langer dan die
    /// deadline, hoeveel agents er ook draaien. Wat de sessies bezighield (vragen) wordt bewaard, en de sessies die dit
    /// afbrak gaan na de volgende start verder als dat aan staat.
    pub fn shutdown(&self) {
        let cut: Vec<(Uuid, bool)> = {
            let mut s = self.lock();
            s.quitting = true;
            let cut: Vec<(Uuid, bool)> =
                s.runs.iter().filter(|r| r.status.is_active()).map(|r| (r.id, r.status == RunStatus::WaitingApproval)).collect();
            for (id, _) in &cut {
                Self::sync_waiting(&mut s, *id);
            }
            let ids: Vec<Uuid> = s.processes.keys().copied().collect();
            for id in ids {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.stopping = true;
                }
                if let Some(p) = s.processes.get_mut(&id) {
                    if let Some(i) = &p.input {
                        let _ = i.send(Input::Close);
                    }
                    interrupt(p.pid);
                }
            }
            s.capacity.clear();
            for (_, handle) in s.prepare_tasks.drain() {
                handle.abort();
            }
            cut
        };
        let running = self.lock().processes.len();
        let alive = || !self.lock().processes.is_empty();
        let pids = || -> Vec<Option<u32>> { self.lock().processes.values().map(|p| p.pid).collect() };
        let kill_all = || {
            let mut s = self.lock();
            for p in s.processes.values_mut() {
                if let Some(k) = p.kill.take() {
                    let _ = k.send(());
                }
            }
        };
        let outcome = super::restart::stop_all(
            running,
            super::restart::Timing::default(),
            || {},
            alive,
            || {
                for pid in pids() {
                    terminate(pid);
                }
                // Windows has no polite terminate: the process ends at the deadline.
            },
            kill_all,
            std::thread::sleep,
            std::time::Instant::now,
        );
        // The kill needs a moment to land before the state is saved.
        if outcome == super::restart::Outcome::Killed {
            for _ in 0..40 {
                if !alive() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
        {
            let mut s = self.lock();
            for (id, waiting) in cut {
                // Stopped by the quit (or still active): "interrupted", unless its turn really ended meanwhile.
                if s.runs.iter().find(|r| r.id == id).is_some_and(|r| matches!(r.status, RunStatus::Completed | RunStatus::Failed)) {
                    continue;
                }
                Self::update(&mut s, id, |r| {
                    r.status = RunStatus::Stopped;
                    r.status_detail = Some("interrupted".into());
                    r.turn_started_at = None;
                    r.restart.stopped_by_quit = true;
                    r.restart.interrupted_while_waiting = waiting;
                });
            }
            for r in s.runs.iter_mut().filter(|r| r.status.is_active()) {
                r.status = RunStatus::Stopped;
                r.status_detail = Some("interrupted".into());
                r.turn_started_at = None;
            }
            s.dirty_runs = true;
            let ids: Vec<Uuid> = s.events.keys().copied().collect();
            s.dirty_events.extend(ids);
        }
        self.flush();
    }
}

/// De vragen van AskUserQuestion als vragen die Nook kan tonen.
fn question_items(input: &Value) -> Option<Vec<QuestionItem>> {
    let raw = input.get("questions")?.as_array()?;
    let items: Vec<QuestionItem> = raw
        .iter()
        .filter_map(|q| {
            let question = q.get("question")?.as_str()?.to_string();
            let options = q
                .get("options")
                .and_then(Value::as_array)
                .map(|o| {
                    o.iter()
                        .filter_map(|o| {
                            Some(QuestionOption {
                                label: o.get("label")?.as_str()?.into(),
                                description: o.get("description").and_then(Value::as_str).unwrap_or("").into(),
                                preview: crate::agents::models::read_preview(o),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(QuestionItem {
                question,
                header: q.get("header").and_then(Value::as_str).unwrap_or("").chars().take(16).collect(),
                options,
                multi_select: q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect();
    (!items.is_empty()).then_some(items)
}

/// "12 s · 845k tokens · $0,04"
pub fn result_line(usage: &TurnUsage, denials: usize) -> String {
    let mut parts = vec![];
    if let Some(s) = usage.duration_seconds {
        parts.push(duration(s));
    }
    let tokens = usage.input_tokens.unwrap_or(0)
        + usage.output_tokens.unwrap_or(0)
        + usage.cache_read_tokens.unwrap_or(0)
        + usage.cache_write_tokens.unwrap_or(0);
    if tokens > 0 {
        parts.push(format!("{} tokens", crate::agents::history::format_tokens(tokens)));
    }
    if let Some(c) = usage.reported_cost_usd {
        parts.push(cost(c));
    }
    if denials > 0 {
        parts.push(format!("{denials} geweigerd"));
    }
    parts.join(" · ")
}

pub fn duration(seconds: f64) -> String {
    let total = seconds.round() as i64;
    if total < 60 {
        return format!("{total}s");
    }
    let minutes = total / 60;
    if minutes < 60 {
        return format!("{minutes}m {}s", total % 60);
    }
    format!("{}u {}m", minutes / 60, minutes % 60)
}

pub fn cost(usd: f64) -> String {
    if usd > 0.0 && usd < 0.01 {
        "< $0,01".into()
    } else {
        format!("${usd:.2}").replace('.', ",")
    }
}

/// De laatste regels van de foutuitvoer, zonder ANSI-codes. Herkent "niet ingelogd" en een verouderde agent.
pub fn clean_error(raw: &str, status: i32) -> String {
    let ansi = regex::Regex::new("\u{1b}\\[[0-9;]*[A-Za-z]").unwrap();
    let stripped = ansi.replace_all(raw, "");
    let lines: Vec<&str> = stripped.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let tail = lines[lines.len().saturating_sub(6)..].join("\n");
    let lower = tail.to_lowercase();
    if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("authenticat") {
        return tr(
            "Dit account is niet ingelogd. Log in via Instellingen › Agents › Accounts en probeer opnieuw.",
            "This account is not signed in. Sign in under Settings › Agents › Accounts and try again.",
        )
        .into();
    }
    if lower.contains("unknown option") || lower.contains("unexpected argument") {
        let short: String = tail.chars().take(400).collect();
        return trf(
            "Je versie van de agent kent een van de opties niet. Werk hem bij en probeer opnieuw.\n{short}",
            "Your version of the agent does not know one of the options. Update it and try again.\n{short}",
            &[("short", &short)],
        );
    }
    if tail.is_empty() {
        return trf(
            "De agent stopte onverwacht (code {status}).",
            "The agent stopped unexpectedly (code {status}).",
            &[("status", &status)],
        );
    }
    tail.chars().take(800).collect()
}

/// Vraagt een proces netjes te stoppen (Ctrl-C).
fn interrupt(pid: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = pid.filter(|p| *p > 1) {
        // SAFETY: een signaal naar een proces dat Nook zelf startte.
        unsafe {
            libc::kill(pid as i32, libc::SIGINT);
        }
    }
    #[cfg(not(unix))]
    let _ = pid;
}

fn terminate(pid: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = pid.filter(|p| *p > 1) {
        // SAFETY: een signaal naar een proces dat Nook zelf startte.
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
    }
    #[cfg(not(unix))]
    let _ = pid;
}

/// Een sessie als rij in de lijst Agents, voor het kaartje "klaar" in de balk.
pub fn attention_summary(text: &str) -> String {
    crate::agents::text::one_line(text, 220)
}

impl Manager {
    /// A new session that starts from this one (`fork` on the Mac). Claude Code copies its own conversation
    /// (`--fork-session` on its first turn); any other agent, and a fork from an earlier point (`keep`: the number of
    /// timeline entries that stay), starts from a summary of what happened. It works in the same folder and never owns
    /// a worktree, so removing it cannot take the original's. Not while the original works.
    pub fn fork(&self, id: Uuid, keep: Option<usize>) -> Result<Uuid, String> {
        let mut out = Out::default();
        let new_id = Uuid::new_v4();
        {
            let mut s = self.lock();
            Self::load_timeline(&self.store, &mut s, id);
            let source = s
                .runs
                .iter()
                .find(|r| r.id == id)
                .cloned()
                .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
            if source.status.is_active() || s.processes.contains_key(&id) {
                return Err(tr(
                    "Dat kan niet terwijl de agent werkt. Wacht tot de beurt klaar is of stop hem.",
                    "Not while the agent works. Wait for the turn to finish, or stop it.",
                )
                .into());
            }
            let all = s.events.get(&id).cloned().unwrap_or_default();
            let partial = keep.is_some_and(|k| k < all.len());
            let events: Vec<RunEvent> = all.into_iter().take(keep.unwrap_or(usize::MAX)).collect();
            // The agent's own fork copies the whole conversation, so a fork from an earlier point always gets a summary.
            let native = source.provider.capabilities().native_fork && !partial && source.provider_session_id.is_some();
            let now = Utc::now();
            let mut copy = source.clone();
            copy.id = new_id;
            copy.title = trf("Vork van {title}", "Fork of {title}", &[("title", &source.title)]);
            copy.status = RunStatus::Completed;
            copy.status_detail = None;
            copy.created_at = now;
            copy.updated_at = now;
            copy.archived = false;
            copy.usage = RunUsage::default();
            copy.turn_started_at = None;
            copy.reviewed_at = None;
            copy.checkpoints = vec![];
            copy.limited_at = None;
            copy.limit_reset_at = None;
            copy.auto_resume = false;
            copy.isolation = IsolationMode::Folder;
            copy.worktree_path = None;
            copy.base_branch = None;
            copy.pending_handoff = None;
            copy.conversation = None;
            copy.pending_rollback = None;
            copy.compacting = false;
            if !native {
                copy.goal = None;
                copy.provider_session_id = None;
                copy.pending_handoff =
                    super::handoff::render(&events, 0, source.provider.display_name(), super::handoff::TOKEN_BUDGET).map(|h| h.text);
            }
            s.runs.insert(0, copy);
            s.events.insert(new_id, events);
            s.dirty_events.insert(new_id);
            s.dirty_runs = true;
            if native {
                s.fork_next.insert(new_id);
            }
            let text = if native {
                trf(
                    "Vork van \"{title}\": de agent gaat verder in een kopie van zijn eigen gesprek.",
                    "Fork of \"{title}\": the agent continues in a copy of its own conversation.",
                    &[("title", &source.title)],
                )
            } else {
                trf(
                    "Vork van \"{title}\": de agent start met een samenvatting van wat er gebeurde.",
                    "Fork of \"{title}\": the agent starts from a summary of what happened.",
                    &[("title", &source.title)],
                )
            };
            Self::append(&mut s, new_id, RunEvent::new(EventKind::System, text), &mut out);
        }
        out.push(ManagerEvent::Changed);
        self.emit(out);
        Ok(new_id)
    }
}

impl Manager {
    /// Voor tests: wacht tot de sessie niet meer loopt.
    pub async fn wait_idle(&self, id: Uuid, limit: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < limit {
            let idle = {
                let s = self.lock();
                !s.processes.contains_key(&id) && s.runs.iter().find(|r| r.id == id).is_some_and(|r| !r.status.is_active())
            };
            if idle {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        false
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn fake_claude(dir: &Path) -> String {
        let path = dir.join("claude");
        std::fs::write(
            &path,
            r#"#!/bin/sh
read first
echo '{"type":"system","subtype":"init","session_id":"fake-1","model":"fake-model"}'
echo '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Ik "}}}'
echo '{"type":"assistant","parent_tool_use_id":null,"message":{"id":"m1","content":[{"type":"text","text":"Ik kijk even."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build"}}],"usage":{"input_tokens":3,"output_tokens":4}}}'
printf '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"}}}\n'
read answer
echo "$answer" | grep -q '"behavior":"allow"' || exit 3
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"weg","is_error":false}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"Klaar.","session_id":"fake-1","total_cost_usd":0.01,"usage":{"input_tokens":3,"output_tokens":4}}'
read rest
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_string_lossy().into_owned()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn claude_turn_with_approval_and_resume_after_restart() {
        let root = std::env::temp_dir().join(format!("nook-manager-{}", Uuid::new_v4()));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let exe = fake_claude(&root);
        let events = Arc::new(Mutex::new(Vec::<String>::new()));
        let log = events.clone();
        let hooks = || Hooks {
            executable: Box::new({
                let exe = exe.clone();
                move |_| Some(exe.clone())
            }),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(|| "/tmp".into()),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks(), tokio::runtime::Handle::current(), move |e| {
            let name = match e {
                ManagerEvent::Approval(a) => format!("approval:{}", a.command),
                ManagerEvent::TurnFinished(r, last) => format!("finished:{:?}:{last}", r.status),
                _ => return,
            };
            log.lock().unwrap().push(name);
        });
        let recap = Arc::new(Mutex::new(crate::services::recap::RecapStore::default()));
        manager.recap.set(recap.clone());
        let config = NewRunConfig { task: "Ruim op".into(), project_path: project.to_string_lossy().into(), ..Default::default() };
        let id = manager.start(config, false).unwrap();
        let mut asked = false;
        for _ in 0..200 {
            if !manager.pending_approvals().is_empty() {
                asked = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(asked, "toestemming gevraagd");
        let approval = manager.pending_approvals()[0].clone();
        assert!(approval.danger, "rm -rf is riskant");
        assert_eq!(manager.run(id).unwrap().status, RunStatus::WaitingApproval);
        // Zo ziet de telefoon het: een goedkeuring die alleen op de computer kan.
        let phone =
            crate::companion::sessions::run_session(&manager.run(id).unwrap(), &manager.permissions(id), &manager.questions(id), "");
        assert_eq!(phone.digest.attention, "approval");
        assert_eq!((phone.digest.items[0].id.as_str(), phone.digest.items[0].detail.as_str()), ("r1", "Bash"));
        assert!(!phone.digest.items[0].can_allow);
        manager.decide(id, "r1", ApprovalDecision::Allow).unwrap();
        assert!(manager.wait_idle(id, Duration::from_secs(10)).await);
        let run = manager.run(id).unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.provider_session_id.as_deref(), Some("fake-1"));
        assert_eq!(run.resolved_model.as_deref(), Some("fake-model"));
        assert!((run.usage.reported_cost_usd.unwrap() - 0.01).abs() < 1e-9);
        let timeline = manager.timeline(id);
        assert!(timeline.iter().any(|e| e.kind == EventKind::Assistant && e.text == "Ik kijk even."));
        assert!(timeline
            .iter()
            .any(|e| e.kind == EventKind::Tool && e.state == Some(EventState::Done) && e.output.as_deref() == Some("weg")));
        assert!(timeline.iter().any(|e| e.kind == EventKind::Approval && e.state == Some(EventState::Allowed)));
        assert!(events.lock().unwrap().iter().any(|e| e.starts_with("finished:Completed:Ik kijk even.")));
        assert_eq!(manager.last_answer(id), "Ik kijk even.");
        let week = recap.lock().unwrap().summary(chrono::Local::now().date_naive());
        assert_eq!((week.sessions, week.prompts, week.commands, week.allowed), (1, 1, 1, 1));
        assert_eq!(week.top_project.as_deref(), Some("project"));
        manager.flush();

        // Na een herstart staat alles er nog.
        let again = Manager::new(root.join("store"), hooks(), tokio::runtime::Handle::current(), |_| {});
        let restored = again.run(id).unwrap();
        assert_eq!(restored.provider_session_id.as_deref(), Some("fake-1"));
        assert!(again.timeline(id).iter().any(|e| e.text == "Ik kijk even."));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn helpers() {
        assert_eq!(duration(42.0), "42s");
        assert_eq!(duration(125.0), "2m 5s");
        assert_eq!(cost(0.004), "< $0,01");
        assert_eq!(cost(1.5), "$1,50");
        assert!(clean_error("\u{1b}[31mError: not logged in\u{1b}[0m", 1).contains("not signed in"));
        assert_eq!(clean_error("", 2), "The agent stopped unexpectedly (code 2).");
        assert_eq!(
            result_line(&TurnUsage { duration_seconds: Some(3.0), input_tokens: Some(1200), ..Default::default() }, 1),
            "3s · 1,2k tokens · 1 geweigerd"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn goal_commands_compaction_and_context_usage() {
        let root = std::env::temp_dir().join(format!("nook-manager-goal-{}", Uuid::new_v4()));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let hooks = || Hooks {
            executable: Box::new(|_| Some("/usr/bin/true".into())),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(|| "/tmp".into()),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks(), tokio::runtime::Handle::current(), |_| {});
        let id = manager
            .adopt(
                RunProvider::Claude,
                "sess-1",
                "claude",
                project.to_str().unwrap(),
                "Goal test",
                vec![(EventKind::User, "Hello world".into()), (EventKind::Assistant, "Hi there!".into())],
                false,
            )
            .unwrap();

        // `/goal <text>` sets and persists the goal.
        manager.send(id, "/goal Ship AG-67 parity").unwrap();
        assert_eq!(manager.run(id).unwrap().goal.as_deref(), Some("Ship AG-67 parity"));
        assert!(manager.timeline(id).iter().any(|e| e.kind == EventKind::System && e.tool.as_deref() == Some("goal")));

        // Inline edit via `set_goal` updates without requiring a turn.
        assert_eq!(manager.set_goal(id, Some("  Polish UX  ".into())).unwrap().as_deref(), Some("Polish UX"));
        assert_eq!(manager.run(id).unwrap().goal.as_deref(), Some("Polish UX"));
        manager.flush();

        // Reload preserves the goal.
        let reloaded = Manager::new(root.join("store"), hooks(), tokio::runtime::Handle::current(), |_| {});
        assert_eq!(reloaded.run(id).unwrap().goal.as_deref(), Some("Polish UX"));

        // `/goal clear` and bare `/goal` clear the goal.
        reloaded.send(id, "/goal clear").unwrap();
        assert_eq!(reloaded.run(id).unwrap().goal, None);
        reloaded.send(id, "/goal Temporary").unwrap();
        assert_eq!(reloaded.run(id).unwrap().goal.as_deref(), Some("Temporary"));
        reloaded.send(id, "/goal").unwrap();
        assert_eq!(reloaded.run(id).unwrap().goal, None);

        // Context breakdown & compaction lifecycle.
        {
            let mut s = reloaded.lock();
            Manager::update(&mut s, id, |r| {
                r.usage.context_window = Some(200_000);
                r.usage.context_tokens = Some(135_000);
            });
        }
        let usage = reloaded.context_usage(id).expect("expected context usage");
        assert_eq!(usage.level, super::super::context_usage::ContextLevel::Warning);
        assert_eq!(usage.auto_compact_at, Some(160_000));
        assert!(!usage.compacting);

        {
            let mut s = reloaded.lock();
            let mut out = Out::default();
            Manager::compaction_started(&mut s, id, &mut out);
        }
        assert!(reloaded.run(id).unwrap().compacting);
        assert!(reloaded.context_usage(id).unwrap().compacting);

        {
            let mut s = reloaded.lock();
            let mut out = Out::default();
            Manager::compaction_finished(&mut s, id, &mut out);
        }
        assert!(!reloaded.run(id).unwrap().compacting);
        assert!(reloaded.run(id).unwrap().usage.context_tokens.is_none());

        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn capacity_queues_cancels_and_promotes_waiting_turns() {
        struct ResetCap;
        impl Drop for ResetCap {
            fn drop(&mut self) {
                super::super::capacity::set_max_working_sessions(0);
            }
        }
        let _reset = ResetCap;

        let root = std::env::temp_dir().join(format!("nook-cap-{}", Uuid::new_v4()));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let hooks = Hooks {
            executable: Box::new(|_| Some("/usr/bin/true".into())),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(|| "/tmp".into()),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks, tokio::runtime::Handle::current(), |_| {});
        let a = manager.adopt(RunProvider::Claude, "s-a", "claude", project.to_str().unwrap(), "Run A", vec![], false).unwrap();
        let b = manager.adopt(RunProvider::Claude, "s-b", "claude", project.to_str().unwrap(), "Run B", vec![], false).unwrap();
        let c = manager.adopt(RunProvider::Claude, "s-c", "claude", project.to_str().unwrap(), "Run C", vec![], false).unwrap();

        // Telemetry provider hook works and overrides default.
        assert!(!manager.has_telemetry_provider());
        manager.set_telemetry_provider(|| {
            let mut endpoints = BTreeMap::new();
            endpoints.insert(crate::services::telemetry::OtlpSignal::Traces, "http://localhost:4318/v1/traces".into());
            crate::services::telemetry::OtlpConfig { enabled: true, endpoints, ..Default::default() }
        });
        assert!(manager.has_telemetry_provider());
        assert!(manager.resolve_telemetry().is_exporting());

        // Cap at 1 working session and mark A as actively running.
        super::super::capacity::set_max_working_sessions(1);
        {
            let mut s = manager.lock();
            Manager::update(&mut s, a, |r| {
                r.move_to(RunStatus::Running, None, Utc::now());
            });
        }

        // B and C wait in FIFO order without spawning.
        assert!(manager.wait_for_capacity(b, "prompt b", "/usr/bin/true", true));
        assert!(manager.wait_for_capacity(c, "prompt c", "/usr/bin/true", true));
        assert!(manager.is_waiting_for_capacity(b));
        assert!(manager.is_waiting_for_capacity(c));
        assert_eq!(manager.run(b).unwrap().status, RunStatus::Preparing);
        assert!(manager.run(b).unwrap().status_detail.is_some());
        assert!(manager.timeline(b).iter().any(|e| e.kind == EventKind::User && e.text == "prompt b"));

        // Stopping a waiting turn cancels it cleanly without freeing A's slot.
        manager.stop(b);
        assert!(!manager.is_waiting_for_capacity(b));
        assert_eq!(manager.run(b).unwrap().status, RunStatus::Stopped);
        assert!(manager.is_waiting_for_capacity(c));

        // Stopping A (no backing process) frees the slot and auto-promotes C out of the waiting queue.
        manager.stop(a);
        assert_eq!(manager.run(a).unwrap().status, RunStatus::Stopped);
        assert!(!manager.is_waiting_for_capacity(c), "C should be dequeued and launched once A stops");

        manager.shutdown();
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn worktree_setup_progress_and_blocking_scripts() {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        let root = std::env::temp_dir().join(format!("nook-wt-setup-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let hooks = Hooks {
            executable: Box::new(|_| Some("/nonexistent-agent".into())),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new({
                let wt = root.join("wt");
                move || wt.to_string_lossy().into_owned()
            }),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks, rt.handle().clone(), |_| {});

        // 1. Remote-base refresh cache throttles repeat fetches within 2 minutes.
        let t0 = Utc::now();
        assert!(manager.should_refresh_remote_base("/repo", "origin/main", t0));
        assert!(!manager.should_refresh_remote_base("/repo", "origin/main", t0 + chrono::Duration::seconds(60)));
        assert!(manager.should_refresh_remote_base("/repo", "origin/main", t0 + chrono::Duration::seconds(121)));
        assert!(manager.should_refresh_remote_base("/repo", "origin/dev", t0));

        // 2. Setup checklist visibility & clearing on first agent output or error.
        let id = Uuid::new_v4();
        let run = WorkspaceRun {
            id,
            title: "Setup test".into(),
            task: "Do work".into(),
            provider: RunProvider::Claude,
            profile_id: String::new(),
            model: String::new(),
            resolved_model: None,
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::Ask,
            isolation: IsolationMode::Worktree,
            project_path: root.to_string_lossy().into_owned(),
            working_directory: root.to_string_lossy().into_owned(),
            repo_root: None,
            branch: Some("nook/test".into()),
            base_branch: Some("main".into()),
            worktree_path: None,
            instructions: String::new(),
            status: RunStatus::Preparing,
            status_detail: None,
            provider_session_id: None,
            created_at: t0,
            updated_at: t0,
            archived: false,
            usage: RunUsage::default(),
            turn_started_at: Some(t0),
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            lines_added: None,
            lines_removed: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: None,
            pending_handoff: None,
            conversation: None,
            pending_rollback: None,
            goal: None,
            compacting: false,
            tasks: None,
            restart: Default::default(),
            prompt_cache: None,
        };
        {
            let mut s = manager.lock();
            s.runs.push(run);
            s.events.insert(id, vec![]);
            let mut progress = WorktreeSetupProgress::new(t0);
            progress.begin(SetupStep::StartAgent, t0);
            s.worktree_setups.insert(id, progress);
        }
        assert!(manager.visible_setup(id).is_some());

        // User/system events keep the checklist alive; assistant output clears it.
        {
            let mut out = Out::default();
            let mut s = manager.lock();
            Manager::append(&mut s, id, RunEvent::new(EventKind::System, "still starting"), &mut out);
        }
        assert!(manager.visible_setup(id).is_some());
        {
            let mut out = Out::default();
            let mut s = manager.lock();
            Manager::append(&mut s, id, RunEvent::new(EventKind::Assistant, "Hello!"), &mut out);
        }
        assert!(manager.visible_setup(id).is_none());

        // 3. Blocking setup script reports failure when terminal closes without writing exit status.
        manager.set_script_runner(|_, _, _| Some(Box::new(|| false)));
        let blocking_script = ProjectScript {
            id: "setup".into(),
            name: "Install deps".into(),
            command: "pnpm install".into(),
            run_on_worktree_create: true,
            preview_url: None,
            auto_open_preview: false,
            stop_on_settle: false,
            run_on_settle: false,
            async_run: false,
        };
        let err = rt.block_on(manager.start_setup_scripts(id, &root.to_string_lossy(), &[blocking_script]));
        assert!(err.is_some(), "closing a blocking setup script terminal before exit code must fail setup");

        manager.shutdown();
        let _ = std::fs::remove_dir_all(root);
    }
}

#[cfg(test)]
mod search_tests {
    use super::snippet;

    #[test]
    fn cuts_the_words_around_a_match() {
        assert_eq!(snippet("Fix the login bug", "login").as_deref(), Some("Fix the login bug"));
        let long = format!("{}needle{}", "a ".repeat(40), " b".repeat(40));
        let s = snippet(&long, "needle").unwrap();
        assert!(s.starts_with('…') && s.ends_with('…') && s.contains("needle"));
        assert_eq!(snippet("nothing here", "needle"), None);
    }
}
