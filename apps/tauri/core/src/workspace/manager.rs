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
use super::git::{self, Git, GitStatus, Worktree};
use super::limits;
use super::models::*;
use super::parsers::{self, ClaudeEvent, CodexEvent, GeminiEvent, TokenCounts};
use super::paths::{self, Verdict};
use super::queue::MessageQueue;
use super::store::{RunStore, UsageFilter, UsageReport};
use crate::agents::models::{
    approval_title, AgentApproval, ApprovalDecision, ApprovalOrigin, QuestionItem, QuestionOption, QuestionRequest,
};
use crate::agents::risk::{self, RiskLevel};
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
    generation: u64,
    dirty_runs: bool,
    dirty_events: HashSet<Uuid>,
    dirty_queues: bool,
    /// Beurten die op een gebruikslimiet stopten, met de reset als die bekend is.
    limited: HashMap<Uuid, Option<DateTime<Utc>>>,
    /// Het lopende "hervat bij reset" per sessie (een teller, zodat een oud wachten niets meer doet).
    limit_resumes: HashMap<Uuid, u64>,
}

type Notify = Box<dyn Fn(ManagerEvent) + Send + Sync>;

pub struct Manager {
    inner: Mutex<Inner>,
    store: RunStore,
    notify: Notify,
    hooks: Hooks,
    git: Option<Git>,
    runtime: tokio::runtime::Handle,
    /// Het weekoverzicht: prompts, tools, beslissingen en beurten.
    pub recap: RecapSink,
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
        });
        // Na een herstart: wat op de reset van een limiet wachtte, wacht weer.
        let waiting: Vec<Uuid> = manager.runs().iter().filter(|r| r.auto_resume && r.limit_reset_at.is_some()).map(|r| r.id).collect();
        for id in waiting {
            manager.arm_limit_resume(id);
        }
        manager
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
        let assessment = command.as_deref().map(risk::assess).unwrap_or_else(|| risk::CommandAssessment::review("Lees het even na"));
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
        info
    }

    // MARK: Nieuwe sessie

    /// Controleert de invoer, zet map of worktree klaar en start de agent. Lukt de worktree niet, dan komt er geen
    /// sessie bij, zodat je het opnieuw kunt proberen.
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
        let executable = (self.hooks.executable)(config.provider)
            .ok_or_else(|| format!("{} staat niet op deze computer.", config.provider.display_name()))?;
        let id = Uuid::new_v4();
        let mut working = project.clone();
        let repo_root = self.git.as_ref().and_then(|g| g.repository_root(&project));
        let mut branch = None;
        let mut worktree = None;
        if config.isolation == IsolationMode::Worktree {
            let git = self.git.as_ref().ok_or("Git is niet gevonden. Installeer git en probeer het opnieuw.")?;
            let root = repo_root.clone().ok_or("Deze map is geen git-repository.")?;
            let root_folder = if config.worktree_root.is_empty() { (self.hooks.worktree_root)() } else { config.worktree_root.clone() };
            let repo_name = crate::agents::text::project_name(&root);
            let path = worktree_path(&paths::normalize(&root_folder), &repo_name, &slug(&config.branch_name.replace('/', "-"), 60), |p| {
                Path::new(p).exists()
            });
            git.add_worktree(&root, &path, &config.branch_name, &config.base_branch).map_err(|e| e.0)?;
            working = path.clone();
            worktree = Some(path);
            branch = Some(config.branch_name.clone());
        } else {
            if !allow_shared_folder {
                if let Some(other) = Self::active_sharing(&self.lock(), &project, None) {
                    return Err(format!(
                        "De sessie '{}' werkt al in deze map. Kies een worktree, of bevestig dat ze de map mogen delen.",
                        other.title
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
            repo_root,
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
            turn_started_at: None,
            reviewed_at: None,
            last_change_at: None,
            changed_files: None,
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: config.effort.clone(),
            pending_handoff: None,
        };
        if let (Some(path), Some(git)) = (&worktree, &self.git) {
            // De eerste momentopname, voor de agent iets doet: "terug naar hier" bij het eerste bericht.
            let r = git::checkpoint_ref(&id.to_string(), 0);
            if git.checkpoint_head(path, &r).is_ok() {
                run.checkpoints.push(RunCheckpoint { r#ref: r, date: Utc::now() });
            }
        }
        let mut out = Out::default();
        {
            let mut s = self.lock();
            s.runs.insert(0, run);
            s.events.insert(id, vec![]);
            s.dirty_runs = true;
            if let Some(path) = &worktree {
                Self::append(
                    &mut s,
                    id,
                    RunEvent::new(
                        EventKind::System,
                        format!("Worktree gemaakt: branch {} in {}", branch.unwrap_or_default(), crate::agents::tilde(path)),
                    ),
                    &mut out,
                );
            }
        }
        self.emit(out);
        self.launch_turn(id, config.task.clone(), executable, true);
        Ok(id)
    }

    fn check_supported(&self, provider: RunProvider) -> Result<(), String> {
        if provider.uses_acp() && provider != RunProvider::Gemini {
            return Err(format!(
                "Nook kan {} op dit platform nog niet zelf aansturen (dat gaat over ACP). Claude Code, Codex en Gemini CLI wel.",
                provider.display_name()
            ));
        }
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
        if (self.hooks.executable)(provider).is_none() {
            return Err(format!("{} staat niet op deze computer.", provider.display_name()));
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
            checkpoints: vec![],
            limited_at: None,
            limit_reset_at: None,
            auto_resume: false,
            effort: None,
            pending_handoff: None,
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
                format!(
                    "Kopie in Nook: je volgende bericht start een kopie van dit gesprek met {}; het origineel loopt ongestoord door.",
                    provider.display_name()
                )
            } else {
                format!("Overgenomen in Nook: dit gesprek gaat hier verder met {}.", provider.display_name())
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
            return Err("Leeg bericht.".into());
        }
        let (run, busy) = {
            let mut s = self.lock();
            // Je gaat zelf verder: wat achter een fout of stop wachtte, gaat na deze beurt weer door.
            if let Some(q) = s.queues.get_mut(&id) {
                q.resume();
            }
            let run = s.runs.iter().find(|r| r.id == id).cloned().ok_or("Deze sessie bestaat niet meer.")?;
            let busy = !run.can_continue() || s.processes.contains_key(&id);
            (run, busy)
        };
        if busy {
            self.enqueue(id, &clean);
            return Ok(());
        }
        let executable =
            (self.hooks.executable)(run.provider).ok_or_else(|| format!("{} staat niet op deze computer.", run.provider.display_name()))?;
        if paths::verdict(&run.working_directory) != Verdict::Ok {
            let message = format!("De werkmap bestaat niet meer: {}", run.working_directory);
            let mut out = Out::default();
            Self::append(&mut self.lock(), id, RunEvent::new(EventKind::Error, message.clone()), &mut out);
            self.emit(out);
            return Err(message);
        }
        let prompt = match &run.pending_handoff {
            Some(handoff) => format!("{handoff}\n\n{clean}"),
            None => clean.clone(),
        };
        self.launch_turn(id, prompt, executable, true);
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
            if provider != Some(RunProvider::Claude) {
                return false;
            }
            let Some(input) = s.processes.get(&id).and_then(|p| p.input.clone()) else { return false };
            if input.send(Input::Line(parsers::claude_user_message(text, true))).is_err() {
                return false;
            }
            if let Some(t) = s.turns.get_mut(&id) {
                t.steered = true;
            }
            Self::finish_live_text(&mut s, id);
            Self::append(&mut s, id, RunEvent::new(EventKind::User, text), &mut out);
            true
        };
        self.emit(out);
        ok
    }

    /// Probeert de vorige opdracht opnieuw (na een fout of een stop).
    pub fn retry(self: &Arc<Self>, id: Uuid) -> Result<(), String> {
        let last = {
            let mut s = self.lock();
            Self::load_timeline(&self.store, &mut s, id);
            let run = s.runs.iter().find(|r| r.id == id).cloned().ok_or("Deze sessie bestaat niet meer.")?;
            s.events.get(&id).and_then(|e| e.iter().rev().find(|e| e.kind == EventKind::User)).map(|e| e.text.clone()).unwrap_or(run.task)
        };
        self.send(id, &last)
    }

    fn launch_turn(self: &Arc<Self>, id: Uuid, prompt: String, executable: String, show_prompt: bool) {
        let mut out = Out::default();
        let spec = {
            let mut s = self.lock();
            if s.processes.contains_key(&id) {
                return;
            }
            // Een nieuwe beurt beëindigt elk wachten op een gebruikslimiet (van jou of het automatische).
            Self::clear_usage_limit(&mut s, id);
            Self::load_timeline(&self.store, &mut s, id);
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            let input = CommandInput {
                provider: run.provider,
                executable: executable.clone(),
                prompt: prompt.clone(),
                model: run.model.clone(),
                mode: run.mode,
                permission: run.permission,
                instructions: run.instructions.clone(),
                working_directory: run.working_directory.clone(),
                resume_session_id: run.provider_session_id.clone(),
                fork_session: s.fork_next.contains(&id),
                account_environment: (self.hooks.account_environment)(&run.profile_id),
                run_id: id.to_string(),
                bridge: (self.hooks.bridge)(),
                effort: run.effort.clone(),
            };
            let spec = command::spec(&input);
            if show_prompt {
                Self::append(&mut s, id, RunEvent::new(EventKind::User, prompt.clone()), &mut out);
            }
            spec
        };
        let base: BTreeMap<String, String> = std::env::vars().collect();
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
                let message = format!("De agent starten lukte niet: {e}");
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
                return;
            }
        };
        let pid = child.id();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let stdin = child.stdin.take();
        let (tx, mut rx) = mpsc::unbounded_channel::<Input>();
        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
        let generation = {
            let mut s = self.lock();
            s.generation += 1;
            let generation = s.generation;
            s.processes.insert(id, Proc { generation, pid, input: spec.keeps_input_open.then(|| tx.clone()), kill: Some(kill_tx) });
            s.fork_next.remove(&id);
            s.turns.insert(id, TurnState { started: Some(Utc::now()), ..Default::default() });
            let now = Utc::now();
            if let Some(run) = s.runs.iter_mut().find(|r| r.id == id) {
                if matches!(run.status, RunStatus::Completed | RunStatus::Failed | RunStatus::Stopped) {
                    run.move_to(RunStatus::Preparing, None, now);
                }
                run.move_to(RunStatus::Running, None, now);
                run.turn_started_at = Some(now);
                let (project, agent) = (run.project_name(), run.provider.display_name());
                self.recap.note(|r, now| r.prompt(&format!("run-{id}"), &project, agent, now));
            }
            s.dirty_runs = true;
            let mut launch = RunEvent::new(EventKind::System, spec.display_command());
            launch.tool = Some("launch".into());
            Self::append(&mut s, id, launch, &mut out);
            generation
        };
        out.push(ManagerEvent::Changed);
        self.emit(out);

        // Schrijven naar stdin: eerst de eerste regels, dan wat Nook later stuurt (antwoorden, onderbreken).
        if let Some(mut stdin) = stdin {
            let initial = spec.initial_input.clone();
            self.runtime.spawn(async move {
                for line in initial {
                    if stdin.write_all(line.as_bytes()).await.is_err() {
                        return;
                    }
                }
                let _ = stdin.flush().await;
                while let Some(msg) = rx.recv().await {
                    match msg {
                        Input::Line(l) => {
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
            self.runtime.spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(line)) = lines.next_line().await {
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
            match provider {
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
        s.events.entry(id).or_default().push(event);
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
                r.provider_session_id = Some(session_id);
                if let Some(m) = model.filter(|m| !m.is_empty()) {
                    r.resolved_model = Some(m);
                }
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
            ClaudeEvent::ToolUse { id: call, name, input, nested } => Self::tool_event(s, id, &call, &name, &input, nested, out),
            ClaudeEvent::ToolResult { id: call, output, is_error } => Self::tool_result(s, id, &call, &output, is_error, out),
            ClaudeEvent::Usage { message_id, tokens, model } => {
                if let Some(t) = s.turns.get_mut(&id) {
                    t.message_usage.insert(message_id, tokens);
                    t.last_context = Some(tokens.context() + tokens.output);
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
                        let q = PendingQuestion { id: request_id.clone(), run_id: id, items, input, created: Utc::now() };
                        s.questions.entry(id).or_default().push(q.clone());
                        Self::update(s, id, |r| {
                            r.move_to(RunStatus::WaitingApproval, None, Utc::now());
                        });
                        let mut e = RunEvent::new(EventKind::Approval, "Wacht op je antwoord…")
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
                    if let Some(session) = &result.session_id {
                        r.provider_session_id = Some(session.clone());
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
                        format!("De agent stopte met een fout ({}).", result.subtype)
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
                    Self::append(
                        s,
                        id,
                        RunEvent::new(EventKind::System, "De agent heeft het gesprek samengevat om ruimte te maken in de context."),
                        out,
                    );
                }
            }
            ClaudeEvent::RateLimits(info) => {
                if let Some(event) = limits::claude_event(&info) {
                    Self::note_claude_limit(s, id, event, out);
                }
            }
        }
        (false, false)
    }

    fn handle_codex(s: &mut Inner, id: Uuid, event: CodexEvent, out: &mut Out) -> bool {
        match event {
            CodexEvent::ThreadStarted(thread) => Self::update(s, id, |r| r.provider_session_id = Some(thread)),
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
                        RunEvent::new(EventKind::Error, message.unwrap_or_else(|| "De agent stopte met een fout.".into())),
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
        self.recap.note(|r, now| r.turn_ended(&format!("run-{id}"), now));
        let mut out = Out::default();
        let run = {
            let mut s = self.lock();
            let Some(run) = s.runs.iter().find(|r| r.id == id).cloned() else { return };
            let stopping = run.status == RunStatus::Stopped;
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
            run
        };
        self.emit(out);
        if run.isolation == IsolationMode::Worktree && run.worktree_path.as_deref().is_some_and(|p| Path::new(p).exists()) {
            if let Some(git) = self.git.clone() {
                let index = run.checkpoints.len();
                let dir = run.working_directory.clone();
                let manager = self.clone();
                let date = Utc::now();
                self.runtime.spawn_blocking(move || {
                    let r = git::checkpoint_ref(&id.to_string(), index);
                    if git.checkpoint(&dir, &r).is_ok() {
                        let mut s = manager.lock();
                        Self::update(&mut s, id, |run| run.checkpoints.push(RunCheckpoint { r#ref: r, date }));
                    }
                    manager.refresh_git(id);
                    manager.send_queued(id);
                });
                return;
            }
        }
        self.refresh_git(id);
        self.send_queued(id);
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
        let mut out = Out::default();
        let target = {
            let mut s = self.lock();
            let Some(proc_) = s.processes.get(&id) else {
                Self::update(&mut s, id, |r| {
                    r.move_to(RunStatus::Stopped, None, Utc::now());
                });
                drop(s);
                self.emit(Out(vec![ManagerEvent::Changed]));
                return;
            };
            let (pid, input, generation) = (proc_.pid, proc_.input.clone(), proc_.generation);
            if let Some(t) = s.turns.get_mut(&id) {
                t.stopping = true;
            }
            let claude = s.runs.iter().find(|r| r.id == id).is_some_and(|r| r.provider == RunProvider::Claude);
            Self::expire_approvals(&mut s, id, &mut out);
            Self::drop_questions(&mut s, id, &mut out);
            Self::append(&mut s, id, RunEvent::new(EventKind::System, "Stoppen…"), &mut out);
            (pid, input, generation, claude)
        };
        self.emit(out);
        let (pid, input, generation, claude) = target;
        let manager = self.clone();
        self.runtime.spawn(async move {
            if claude {
                if let Some(i) = &input {
                    let _ =
                        i.send(Input::Line(parsers::claude_interrupt(&format!("nook-stop-{}", &Uuid::new_v4().simple().to_string()[..8]))));
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
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let pending = s
                .approvals
                .get(&run_id)
                .and_then(|l| l.iter().find(|p| p.id == request_id))
                .cloned()
                .ok_or("Deze vraag bestaat niet meer.")?;
            let input = s.processes.get(&run_id).and_then(|p| p.input.clone());
            let Some(input) = input else {
                Self::expire_approval(&mut s, run_id, request_id, &mut out);
                drop(s);
                self.emit(out);
                return Err("De agent draait niet meer; de vraag is verlopen.".into());
            };
            let allow = decision != ApprovalDecision::Deny && decision != ApprovalDecision::Terminal;
            self.recap.note(|r, now| r.decision(allow, now));
            let rules = (decision == ApprovalDecision::Always && pending.can_always()).then_some(pending.suggestions.clone()).flatten();
            let _ = input.send(Input::Line(parsers::claude_permission_response(request_id, allow, &pending.input, rules.as_ref(), "")));
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
    }

    /// Beantwoordt een meerkeuzevraag: per vraag de gekozen labels.
    pub fn answer_question(&self, run_id: Uuid, request_id: &str, selections: &[Vec<String>]) -> Result<(), String> {
        let mut out = Out::default();
        {
            let mut s = self.lock();
            let q = s
                .questions
                .get(&run_id)
                .and_then(|l| l.iter().find(|q| q.id == request_id))
                .cloned()
                .ok_or("Deze vraag bestaat niet meer.")?;
            let input = s.processes.get(&run_id).and_then(|p| p.input.clone()).ok_or("De agent draait niet meer.")?;
            let answers: Vec<(String, Vec<String>)> =
                q.items.iter().zip(selections).map(|(i, sel)| (i.question.clone(), sel.clone())).collect();
            let _ = input.send(Input::Line(parsers::claude_question_answer(request_id, &q.input, &answers)));
            if let Some(l) = s.questions.get_mut(&run_id) {
                l.retain(|x| x.id != request_id);
            }
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
            Self::append(&mut s, id, RunEvent::new(EventKind::System, "De gebruikslimiet is vrij: de sessie gaat verder."), &mut out);
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
            let run = s.runs.iter().find(|r| r.id == id).cloned().ok_or("Deze sessie bestaat niet meer.")?;
            if run.status.is_active() || s.processes.contains_key(&id) {
                return Err("Kan niet terwijl de agent werkt.".into());
            }
            s.runs.retain(|r| r.id != id);
            s.events.remove(&id);
            s.approvals.remove(&id);
            s.questions.remove(&id);
            s.queues.remove(&id);
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
                snap.error = Some(format!("De werkmap bestaat niet meer: {dir}"));
            }
            {
                let mut s = manager.lock();
                if let Some(st) = &snap.status {
                    let count = st.files.len() as u32;
                    Self::update(&mut s, id, |r| r.changed_files = Some(count));
                }
                s.git.insert(id, snap);
            }
            manager.emit(Out(vec![ManagerEvent::Changed]));
        });
    }

    pub fn diff(&self, id: Uuid, file: &git::FileChange) -> Result<String, String> {
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
        git.diff(&run.working_directory, file).map_err(|e| e.0)
    }

    pub fn commit(self: &Arc<Self>, id: Uuid, message: &str, paths: &[String]) -> Result<String, String> {
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        if run.status.is_active() {
            return Err("Kan niet terwijl de agent werkt.".into());
        }
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
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
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
        let dir = &run.working_directory;
        let branch = git.current_branch(dir).ok_or("Er is geen branch uitgecheckt.")?;
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

    /// Alleen fast-forward, nooit terwijl de agent werkt.
    pub fn pull(self: &Arc<Self>, id: Uuid) -> Result<(), String> {
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        if run.status.is_active() {
            return Err("Kan niet terwijl de agent werkt.".into());
        }
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
        git.pull_fast_forward(&run.working_directory).map_err(|e| e.0)?;
        self.note(id, "Gepulld (alleen fast-forward)");
        self.refresh_git(id);
        Ok(())
    }

    /// Een systeemregel in de tijdlijn (bijvoorbeeld "Pull request geopend: …").
    pub fn note(&self, id: Uuid, text: &str) {
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, text), &mut out);
        self.emit(out);
    }

    pub fn git(&self) -> Option<&Git> {
        self.git.as_ref()
    }

    /// Haalt de worktree van een sessie weg. Nooit terwijl de sessie loopt; niet-vastgelegd werk vraagt `force`.
    pub fn remove_worktree(self: &Arc<Self>, id: Uuid, force: bool) -> Result<(), String> {
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        let (Some(path), Some(repo)) = (run.worktree_path.clone(), run.repo_root.clone()) else { return Ok(()) };
        self.remove_worktree_at(&repo, &path, force)
    }

    /// Haalt een worktree weg die bij geen actieve sessie hoort (vanuit het overzicht).
    pub fn remove_worktree_at(self: &Arc<Self>, repo: &str, path: &str, force: bool) -> Result<(), String> {
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
        let target = paths::normalize(path);
        {
            let s = self.lock();
            if s.runs
                .iter()
                .any(|r| (r.status.is_active() || s.processes.contains_key(&r.id)) && paths::normalize(&r.working_directory) == target)
            {
                return Err("Er werkt nog een sessie in deze worktree. Stop die eerst.".into());
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
                    RunEvent::new(EventKind::System, format!("Worktree verwijderd: {}", crate::agents::tilde(path))),
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

    /// Bestanden kunnen terug naar hoe ze waren vóór een bericht: een worktree-sessie die niets doet, alleen in zijn map.
    pub fn can_revert(&self, id: Uuid, before: DateTime<Utc>) -> bool {
        let s = self.lock();
        let Some(run) = s.runs.iter().find(|r| r.id == id) else { return false };
        run.isolation == IsolationMode::Worktree
            && !run.status.is_active()
            && run.checkpoints.iter().any(|c| c.date <= before)
            && Self::active_sharing(&s, &run.working_directory, Some(id)).is_none()
    }

    pub fn revert_files(self: &Arc<Self>, id: Uuid, before: DateTime<Utc>) -> Result<(), String> {
        if !self.can_revert(id, before) {
            return Err("Terugzetten kan alleen bij een sessie in een eigen worktree die niet bezig is.".into());
        }
        let run = self.run(id).ok_or("Deze sessie bestaat niet meer.")?;
        let checkpoint = run.checkpoints.iter().rev().find(|c| c.date <= before).cloned().ok_or("Geen eerder punt gevonden.")?;
        let git = self.git.as_ref().ok_or("Git is niet gevonden.")?;
        git.restore(&run.working_directory, &checkpoint.r#ref).map_err(|e| e.0)?;
        let mut out = Out::default();
        Self::append(&mut self.lock(), id, RunEvent::new(EventKind::System, "Bestanden teruggezet naar een eerder punt."), &mut out);
        self.emit(out);
        self.refresh_git(id);
        Ok(())
    }

    // MARK: Opslaan

    /// Schrijft weg wat veranderde. De app roept dit elke seconde aan.
    pub fn flush(&self) {
        let (runs, events, queues) = {
            let mut s = self.lock();
            let runs = std::mem::take(&mut s.dirty_runs).then(|| s.runs.clone());
            let ids: Vec<Uuid> = s.dirty_events.drain().collect();
            let events: Vec<(Uuid, Vec<RunEvent>)> = ids.into_iter().filter_map(|id| s.events.get(&id).map(|e| (id, e.clone()))).collect();
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

    /// Bij het afsluiten van Nook: lopende agents netjes stoppen, zodat er geen processen achterblijven.
    pub fn shutdown(&self) {
        {
            let mut s = self.lock();
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
                    if let Some(k) = p.kill.take() {
                        let _ = k.send(());
                    }
                }
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
        return "Dit account is niet ingelogd. Log in via Instellingen › Agents › Accounts en probeer opnieuw.".into();
    }
    if lower.contains("unknown option") || lower.contains("unexpected argument") {
        let short: String = tail.chars().take(400).collect();
        return format!("Je versie van de agent kent een van de opties niet. Werk hem bij en probeer opnieuw.\n{short}");
    }
    if tail.is_empty() {
        return format!("De agent stopte onverwacht (code {status}).");
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
        assert!(clean_error("\u{1b}[31mError: not logged in\u{1b}[0m", 1).contains("niet ingelogd"));
        assert_eq!(clean_error("", 2), "De agent stopte onverwacht (code 2).");
        assert_eq!(
            result_line(&TurnUsage { duration_seconds: Some(3.0), input_tokens: Some(1200), ..Default::default() }, 1),
            "3s · 1,2k tokens · 1 geweigerd"
        );
    }
}
