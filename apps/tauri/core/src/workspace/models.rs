//! De werkruimte voor coding-agents: sessies die Nook zelf start en volgt (niet in een terminal)
//! (`WorkspaceModels` op de Mac). Alles hier is zonder processen, zodat het los te testen is.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::agents::profiles::fold;

/// Welke agent een sessie draait. Alleen agents met een echte headless stand die Nook kan volgen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunProvider {
    Claude,
    Codex,
    Gemini,
    Opencode,
    Cursor,
    Grok,
    Antigravity,
}

impl RunProvider {
    pub const ALL: [RunProvider; 7] =
        [Self::Claude, Self::Codex, Self::Gemini, Self::Opencode, Self::Cursor, Self::Grok, Self::Antigravity];

    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Gemini => "gemini",
            Self::Opencode => "opencode",
            Self::Cursor => "cursor",
            Self::Grok => "grok",
            Self::Antigravity => "antigravity",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Gemini => "Gemini CLI",
            Self::Opencode => "OpenCode",
            Self::Cursor => "Cursor",
            Self::Grok => "Grok",
            Self::Antigravity => "Antigravity",
        }
    }

    pub fn kind(self) -> crate::agents::AgentKind {
        use crate::agents::AgentKind as K;
        match self {
            Self::Claude => K::Claude,
            Self::Codex => K::Codex,
            Self::Gemini => K::Gemini,
            Self::Opencode => K::Opencode,
            Self::Cursor => K::Cursor,
            Self::Grok => K::Grok,
            Self::Antigravity => K::Antigravity,
        }
    }

    pub fn from_kind(kind: crate::agents::AgentKind) -> Self {
        use crate::agents::AgentKind as K;
        match kind {
            K::Claude => Self::Claude,
            K::Codex => Self::Codex,
            K::Gemini => Self::Gemini,
            K::Opencode => Self::Opencode,
            K::Cursor => Self::Cursor,
            K::Grok => Self::Grok,
            K::Antigravity => Self::Antigravity,
        }
    }

    /// Draait over ACP (Agent Client Protocol), zoals deze agents dat zelf aanbieden.
    pub fn uses_acp(self) -> bool {
        matches!(self, Self::Gemini | Self::Opencode | Self::Cursor | Self::Grok | Self::Antigravity)
    }

    /// Wat deze agent kan zonder terminal. De interface toont wat ontbreekt als niet beschikbaar.
    pub fn capabilities(self) -> ProviderCapabilities {
        use PermissionPolicy::*;
        match self {
            Self::Claude => ProviderCapabilities {
                approvals: true,
                interrupt: true,
                streaming_text: true,
                plan_mode: true,
                reports_cost: true,
                reports_context_window: true,
                reports_cache_tokens: true,
                policies: vec![Ask, AcceptEdits, Bypass],
                steering: true,
                native_fork: true,
            },
            Self::Codex => ProviderCapabilities {
                approvals: true,
                interrupt: true,
                streaming_text: true,
                plan_mode: true,
                reports_cost: false,
                reports_context_window: true,
                reports_cache_tokens: true,
                policies: vec![Ask, AcceptEdits, Bypass],
                steering: false,
                native_fork: false,
            },
            Self::Gemini => ProviderCapabilities {
                approvals: true,
                interrupt: true,
                streaming_text: true,
                plan_mode: true,
                reports_cost: false,
                reports_context_window: true,
                reports_cache_tokens: true,
                policies: vec![Ask, AcceptEdits, Bypass],
                steering: false,
                native_fork: false,
            },
            Self::Opencode | Self::Cursor | Self::Grok | Self::Antigravity => ProviderCapabilities {
                approvals: true,
                interrupt: true,
                streaming_text: true,
                plan_mode: true,
                reports_cost: true,
                reports_context_window: true,
                reports_cache_tokens: true,
                policies: vec![Ask, AcceptEdits, Bypass],
                steering: false,
                native_fork: false,
            },
        }
    }

    /// Snelkeuze voor modellen. Leeg: de standaard van de agent. Een eigen naam typen kan ook.
    pub fn suggested_models(self) -> Vec<&'static str> {
        match self {
            Self::Claude => vec!["", "sonnet", "opus", "haiku"],
            Self::Codex => vec!["", "gpt-5-codex", "gpt-5"],
            Self::Gemini => vec!["", "gemini-2.5-pro", "gemini-2.5-flash"],
            _ => vec![""],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilities {
    pub approvals: bool,
    pub interrupt: bool,
    pub streaming_text: bool,
    pub plan_mode: bool,
    pub reports_cost: bool,
    pub reports_context_window: bool,
    pub reports_cache_tokens: bool,
    pub policies: Vec<PermissionPolicy>,
    /// Een bericht tijdens een beurt stuurt die beurt bij; anders komt het in de wachtrij.
    pub steering: bool,
    /// De agent kan zijn eigen gesprek kopiëren (`--fork-session`).
    pub native_fork: bool,
}

/// Agent: mag uitvoeren. Plan: alleen lezen en een plan maken, niets wijzigen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExecutionMode {
    #[default]
    Agent,
    Plan,
}

/// Wat de agent zonder te vragen mag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionPolicy {
    /// Vraag voor elke wijziging en elk commando.
    Ask,
    /// Bestanden in de map aanpassen mag; commando's vragen eerst (Claude) of draaien afgeschermd (Codex).
    #[default]
    AcceptEdits,
    /// Alles mag zonder vragen. Alleen als je dat echt wilt.
    Bypass,
}

/// Rechtstreeks in de projectmap werken, of in een aparte git-worktree met een eigen branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IsolationMode {
    #[default]
    Folder,
    Worktree,
}

/// De stand van een sessie. Elke overgang gaat via [`RunStatus::can_move`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunStatus {
    /// Map of worktree klaarzetten, agent starten.
    Preparing,
    Running,
    /// Wacht op jouw toestemming.
    WaitingApproval,
    /// De beurt is klaar; je kunt verder met een nieuw bericht.
    Completed,
    Failed,
    /// Gestopt door jou, of het proces is weg (bijvoorbeeld na het herstarten van Nook).
    Stopped,
}

impl RunStatus {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Preparing | Self::Running | Self::WaitingApproval)
    }

    pub fn can_move(self, next: RunStatus) -> bool {
        use RunStatus::*;
        if next == self {
            return true;
        }
        match self {
            Preparing => matches!(next, Running | Failed | Stopped),
            Running => matches!(next, WaitingApproval | Completed | Failed | Stopped),
            WaitingApproval => matches!(next, Running | Completed | Failed | Stopped),
            Completed | Failed | Stopped => matches!(next, Preparing | Running),
        }
    }

    /// Na een herstart draait er geen proces meer: een "actieve" sessie staat dan op gestopt.
    pub fn after_relaunch(self) -> RunStatus {
        if self.is_active() {
            Self::Stopped
        } else {
            self
        }
    }
}

/// Tokens en kosten. `None`: de agent meldde het niet. Nooit gokken.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    /// Kosten zoals de agent ze zelf berekende (Claude Code: tegen API-prijzen, ook met een abonnement).
    pub reported_cost_usd: Option<f64>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
    pub turns: u32,
    pub active_seconds: f64,
}

impl RunUsage {
    pub fn total_tokens(&self) -> Option<u64> {
        let parts: Vec<u64> =
            [self.input_tokens, self.output_tokens, self.cache_read_tokens, self.cache_write_tokens].into_iter().flatten().collect();
        (!parts.is_empty()).then(|| parts.iter().sum())
    }

    pub fn context_fraction(&self) -> Option<f64> {
        let (tokens, window) = (self.context_tokens?, self.context_window?);
        (window > 0).then(|| (tokens as f64 / window as f64).min(1.0))
    }

    /// Telt een afgeronde beurt op. Wat de beurt niet meldde, blijft zoals het was.
    pub fn add(&mut self, turn: &TurnUsage) {
        fn sum(a: Option<u64>, b: Option<u64>) -> Option<u64> {
            match (a, b) {
                (None, None) => None,
                _ => Some(a.unwrap_or(0) + b.unwrap_or(0)),
            }
        }
        self.input_tokens = sum(self.input_tokens, turn.input_tokens);
        self.output_tokens = sum(self.output_tokens, turn.output_tokens);
        self.cache_read_tokens = sum(self.cache_read_tokens, turn.cache_read_tokens);
        self.cache_write_tokens = sum(self.cache_write_tokens, turn.cache_write_tokens);
        if let Some(c) = turn.reported_cost_usd {
            self.reported_cost_usd = Some(self.reported_cost_usd.unwrap_or(0.0) + c);
        }
        if let Some(c) = turn.context_tokens {
            self.context_tokens = Some(c);
        }
        if let Some(w) = turn.context_window {
            self.context_window = Some(w);
        }
        self.turns += 1;
        self.active_seconds += turn.duration_seconds.unwrap_or(0.0).max(0.0);
    }
}

/// Gebruik van één beurt (één proces).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub reported_cost_usd: Option<f64>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
    pub duration_seconds: Option<f64>,
}

/// Een momentopname van de worktree: "terug naar hier".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunCheckpoint {
    pub r#ref: String,
    pub date: DateTime<Utc>,
}

/// Eén sessie in de werkruimte. Bewaard door `RunStore`, blijft na een herstart.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRun {
    pub id: Uuid,
    pub title: String,
    /// De eerste opdracht.
    pub task: String,
    pub provider: RunProvider,
    /// Het account (`AgentProfile.id`).
    pub profile_id: String,
    /// Leeg: de standaard van de agent.
    pub model: String,
    /// Het model dat de agent echt gebruikte, zoals hij zelf meldde.
    #[serde(default)]
    pub resolved_model: Option<String>,
    pub mode: ExecutionMode,
    pub permission: PermissionPolicy,
    pub isolation: IsolationMode,
    /// De gekozen map of repository.
    pub project_path: String,
    /// Waar de agent echt werkt: de map zelf, of de worktree.
    pub working_directory: String,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub base_branch: Option<String>,
    #[serde(default)]
    pub worktree_path: Option<String>,
    /// Extra instructies voor deze sessie (naast CLAUDE.md / AGENTS.md van het project).
    #[serde(default)]
    pub instructions: String,
    pub status: RunStatus,
    #[serde(default)]
    pub status_detail: Option<String>,
    /// Het sessie-id van de agent, om verder te gaan (`claude --resume`, `codex exec resume`).
    #[serde(default)]
    pub provider_session_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub usage: RunUsage,
    #[serde(default)]
    pub turn_started_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub reviewed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_change_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub changed_files: Option<u32>,
    #[serde(default)]
    pub checkpoints: Vec<RunCheckpoint>,
    /// Gestopt op een gebruikslimiet: sinds wanneer, wanneer de limiet weer vrij is, en of hij dan vanzelf verdergaat.
    #[serde(default)]
    pub limited_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub limit_reset_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub auto_resume: bool,
    /// Redeneerniveau voor de volgende beurten ("low", "medium", "high"); `None` is de standaard van de agent.
    #[serde(default)]
    pub effort: Option<String>,
    /// De samenvatting waarmee de volgende beurt begint, na een kopie of een wissel van agent.
    #[serde(default)]
    pub pending_handoff: Option<String>,
}

impl WorkspaceRun {
    pub fn project_name(&self) -> String {
        crate::agents::text::project_name(&self.project_path)
    }

    pub fn has_unreviewed_changes(&self) -> bool {
        let Some(changed) = self.last_change_at else { return false };
        if self.changed_files == Some(0) {
            return false;
        }
        self.reviewed_at.is_none_or(|r| r < changed)
    }

    /// Kan er een nieuw bericht naar? Alleen als de vorige beurt klaar is.
    pub fn can_continue(&self) -> bool {
        !self.status.is_active()
    }

    /// Een overgang die niet mag, wordt geweigerd (en geeft `false`).
    pub fn move_to(&mut self, next: RunStatus, detail: Option<String>, now: DateTime<Utc>) -> bool {
        if !self.status.can_move(next) {
            return false;
        }
        self.status = next;
        self.status_detail = detail;
        self.updated_at = now;
        if next == RunStatus::Running && self.turn_started_at.is_none() {
            self.turn_started_at = Some(now);
        }
        if !next.is_active() {
            self.turn_started_at = None;
        }
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    User,
    Assistant,
    Thinking,
    Tool,
    FileChange,
    Approval,
    Error,
    System,
    Result,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventState {
    Running,
    Done,
    Failed,
    Pending,
    Allowed,
    Denied,
    Expired,
}

/// Eén regel in de tijdlijn van een sessie.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunEvent {
    pub id: Uuid,
    pub date: DateTime<Utc>,
    pub kind: EventKind,
    /// De hoofdtekst: bericht, samenvatting van een tool, foutmelding.
    pub text: String,
    /// De naam van de tool, of het soort wijziging (toegevoegd/gewijzigd/verwijderd).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// Het id van de tool-aanroep (of van de toestemmingsvraag), om de uitvoer te koppelen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// De invoer van de tool als JSON, of een bestandspad.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// De uitvoer van de tool, ingekort.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<EventState>,
}

impl RunEvent {
    pub const OUTPUT_LIMIT: usize = 16_000;

    pub fn new(kind: EventKind, text: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            date: Utc::now(),
            kind,
            text: text.into(),
            tool: None,
            call_id: None,
            detail: None,
            output: None,
            state: None,
        }
    }

    pub fn with_state(mut self, state: EventState) -> Self {
        self.state = Some(state);
        self
    }

    pub fn with_tool(mut self, tool: impl Into<String>) -> Self {
        self.tool = Some(tool.into());
        self
    }

    pub fn with_call(mut self, id: impl Into<String>) -> Self {
        self.call_id = Some(id.into());
        self
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    /// Lange uitvoer wordt ingekort; de volledige staat in het eigen transcript van de agent.
    pub fn clip(text: &str) -> String {
        clip_to(text, Self::OUTPUT_LIMIT)
    }
}

pub fn clip_to(text: &str, limit: usize) -> String {
    if text.chars().count() > limit {
        text.chars().take(limit).collect::<String>() + "\n…"
    } else {
        text.into()
    }
}

/// De velden van "Nieuwe sessie". Gecontroleerd voordat er iets start.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewRunConfig {
    pub title: String,
    pub task: String,
    pub provider: RunProvider,
    pub profile_id: String,
    pub model: String,
    pub mode: ExecutionMode,
    pub permission: PermissionPolicy,
    pub isolation: IsolationMode,
    pub project_path: String,
    pub base_branch: String,
    pub branch_name: String,
    pub worktree_root: String,
    pub instructions: String,
    pub effort: Option<String>,
}

impl Default for NewRunConfig {
    fn default() -> Self {
        Self {
            title: String::new(),
            task: String::new(),
            provider: RunProvider::Claude,
            profile_id: "claude".into(),
            model: String::new(),
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            isolation: IsolationMode::Folder,
            project_path: String::new(),
            base_branch: String::new(),
            branch_name: String::new(),
            worktree_root: String::new(),
            instructions: String::new(),
            effort: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfigProblem {
    MissingTask,
    MissingWorkspace,
    UnsupportedPolicy,
    MissingBaseBranch,
    InvalidBranchName,
}

impl ConfigProblem {
    pub fn message(self) -> &'static str {
        match self {
            Self::MissingTask => "Schrijf eerst wat de agent moet doen.",
            Self::MissingWorkspace => "Kies een map om in te werken.",
            Self::UnsupportedPolicy => "Deze agent kent deze rechten niet.",
            Self::MissingBaseBranch => "Kies de branch waar de worktree van uitgaat.",
            Self::InvalidBranchName => "Deze branchnaam kan niet in git.",
        }
    }
}

impl NewRunConfig {
    /// Wat er mis is met de invoer, of `None`. Controleert alleen de velden; git en paden doet de manager.
    pub fn problem(&self) -> Option<ConfigProblem> {
        if self.task.trim().is_empty() {
            return Some(ConfigProblem::MissingTask);
        }
        if self.project_path.is_empty() {
            return Some(ConfigProblem::MissingWorkspace);
        }
        if !self.provider.capabilities().policies.contains(&self.permission) {
            return Some(ConfigProblem::UnsupportedPolicy);
        }
        if self.isolation == IsolationMode::Worktree {
            if self.base_branch.is_empty() {
                return Some(ConfigProblem::MissingBaseBranch);
            }
            if !is_plausible_branch_name(&self.branch_name) {
                return Some(ConfigProblem::InvalidBranchName);
            }
        }
        None
    }
}

/// "Fix de login-bug in Safari!" → "fix-de-login-bug-in-safari".
pub fn slug(text: &str, limit: usize) -> String {
    let mut result = String::new();
    for c in fold(text).to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            result.push(c);
        } else if !result.is_empty() && !result.ends_with('-') {
            result.push('-');
        }
        if result.chars().count() >= limit {
            break;
        }
    }
    while result.ends_with('-') {
        result.pop();
    }
    if result.is_empty() {
        "sessie".into()
    } else {
        result
    }
}

/// Een korte titel uit de eerste regel van de opdracht.
pub fn title_from(task: &str, limit: usize) -> String {
    let first = task.lines().next().unwrap_or("").trim();
    if first.is_empty() {
        return "Nieuwe sessie".into();
    }
    if first.chars().count() <= limit {
        return first.into();
    }
    let cut: String = first.chars().take(limit).collect();
    if let Some(space) = cut.rfind(' ') {
        if cut[..space].chars().count() > limit / 2 {
            return format!("{}…", &cut[..space]);
        }
    }
    format!("{cut}…")
}

/// "nook/fix-login-bug-3fa2": herkenbaar en uniek dankzij een stukje van het id.
pub fn branch_name(task: &str, id: Uuid) -> String {
    format!("nook/{}-{}", slug(task, 32), &id.simple().to_string()[..4])
}

/// Snelle controle zonder git.
pub fn is_plausible_branch_name(name: &str) -> bool {
    if name.is_empty()
        || name.chars().count() > 200
        || name.starts_with('-')
        || name.starts_with('/')
        || name.ends_with('/')
        || name.ends_with('.')
        || name.ends_with(".lock")
        || name.contains("..")
        || name.contains("//")
        || name.contains("@{")
        || name == "@"
    {
        return false;
    }
    !name.chars().any(|c| " ~^:?*[\\".contains(c) || c.is_control() || c.is_whitespace())
}

/// De plek van een worktree: `<root>/<repo>/<slug>`, met een volgnummer als de map al bestaat.
pub fn worktree_path(root: &str, repo_name: &str, slug_text: &str, exists: impl Fn(&str) -> bool) -> String {
    let base = std::path::Path::new(root).join(slug(repo_name, 40));
    let mut candidate = base.join(slug_text).to_string_lossy().into_owned();
    let mut counter = 2;
    while exists(&candidate) {
        candidate = base.join(format!("{slug_text}-{counter}")).to_string_lossy().into_owned();
        counter += 1;
    }
    candidate
}

/// Korte, taalneutrale samenvatting van een tool-aanroep: "Bash · npm test", "Edit · Login.swift".
pub mod tool_summary {
    use super::*;

    pub fn describe(tool: &str, input: &Value) -> String {
        if let Some((label, detail)) = super::super::bridge::describe_tool(tool, input) {
            return match detail {
                Some(d) => format!("{label} · {}", one_line(&d, 120)),
                None => label,
            };
        }
        // Another MCP tool: "Bestanden mappen › Move file · Source: a.txt, Destination: b.txt".
        if let Some(mcp) = crate::agents::mcp_name::McpToolName::parse(tool) {
            let detail = crate::agents::mcp_name::argument_lines(input).into_iter().take(2).collect::<Vec<_>>().join(", ");
            return if detail.is_empty() { mcp.label() } else { format!("{} · {}", mcp.label(), one_line(&detail, 100)) };
        }
        if let Some(command) = command(input) {
            return format!("{tool} · {}", one_line(&command, 120));
        }
        if let Some(path) = path(input) {
            return format!("{tool} · {}", path.rsplit(['/', '\\']).next().unwrap_or(&path));
        }
        for key in ["pattern", "query", "url", "description", "prompt"] {
            if let Some(v) = input.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()) {
                return format!("{tool} · {}", one_line(v, 100));
            }
        }
        if tool == "TodoWrite" {
            if let Some(list) = input.get("todos").and_then(Value::as_array) {
                return format!("{tool} · {}", list.len());
            }
        }
        tool.into()
    }

    pub fn command(input: &Value) -> Option<String> {
        crate::agents::hub::command_text(input)
    }

    pub fn path(input: &Value) -> Option<String> {
        ["file_path", "notebook_path", "absolute_path", "path"]
            .iter()
            .find_map(|k| input.get(*k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_string))
    }

    /// Bestanden die deze tool wijzigt, met het soort wijziging.
    pub fn file_changes(tool: &str, input: &Value) -> Vec<(String, String)> {
        match tool {
            "Edit" | "MultiEdit" | "NotebookEdit" | "replace" => path(input).map(|p| vec![(p, "modified".into())]).unwrap_or_default(),
            "Write" | "write_file" => path(input).map(|p| vec![(p, "written".into())]).unwrap_or_default(),
            _ => vec![],
        }
    }

    pub fn one_line(text: &str, limit: usize) -> String {
        let single = text.replace('\n', " ");
        let single = single.trim();
        if single.chars().count() > limit {
            single.chars().take(limit).collect::<String>() + "…"
        } else {
            single.into()
        }
    }

    /// Opgemaakte JSON met gesorteerde sleutels, voor de tijdlijn.
    pub fn json(value: &Value) -> String {
        serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    pub fn run(status: RunStatus) -> WorkspaceRun {
        let now = Utc::now();
        WorkspaceRun {
            id: Uuid::new_v4(),
            title: "Taak".into(),
            task: "Doe iets".into(),
            provider: RunProvider::Claude,
            profile_id: "claude".into(),
            model: String::new(),
            resolved_model: None,
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            isolation: IsolationMode::Folder,
            project_path: "/tmp/p".into(),
            working_directory: "/tmp/p".into(),
            repo_root: None,
            branch: None,
            base_branch: None,
            worktree_path: None,
            instructions: String::new(),
            status,
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
            effort: None,
            pending_handoff: None,
        }
    }

    #[test]
    fn status_transitions() {
        use RunStatus::*;
        assert!(Preparing.can_move(Running));
        assert!(Running.can_move(WaitingApproval));
        assert!(WaitingApproval.can_move(Running));
        assert!(Running.can_move(Completed));
        assert!(Completed.can_move(Preparing));
        assert!(Failed.can_move(Preparing));
        assert!(!Completed.can_move(WaitingApproval));
        assert!(!Preparing.can_move(Completed));
        assert!(!Stopped.can_move(Failed));
        assert_eq!(Running.after_relaunch(), Stopped);
        assert_eq!(WaitingApproval.after_relaunch(), Stopped);
        assert_eq!(Completed.after_relaunch(), Completed);
        assert_eq!(Failed.after_relaunch(), Failed);
    }

    #[test]
    fn move_rejects_invalid_and_tracks_turn_start() {
        let mut r = run(RunStatus::Preparing);
        let now = Utc::now();
        assert!(!r.move_to(RunStatus::Completed, None, now));
        assert!(r.move_to(RunStatus::Running, None, now));
        assert!(r.turn_started_at.is_some());
        assert!(r.move_to(RunStatus::Failed, Some("boom".into()), now));
        assert!(r.turn_started_at.is_none());
        assert_eq!(r.status_detail.as_deref(), Some("boom"));
        assert!(r.can_continue());
    }

    #[test]
    fn config_validation() {
        let mut c = NewRunConfig::default();
        assert_eq!(c.problem(), Some(ConfigProblem::MissingTask));
        c.task = "Fix de login".into();
        assert_eq!(c.problem(), Some(ConfigProblem::MissingWorkspace));
        c.project_path = "/tmp/project".into();
        assert_eq!(c.problem(), None);
        c.permission = PermissionPolicy::Ask;
        for p in RunProvider::ALL {
            c.provider = p;
            assert_eq!(c.problem(), None);
        }
        c.isolation = IsolationMode::Worktree;
        assert_eq!(c.problem(), Some(ConfigProblem::MissingBaseBranch));
        c.base_branch = "main".into();
        c.branch_name = "bad name".into();
        assert_eq!(c.problem(), Some(ConfigProblem::InvalidBranchName));
        c.branch_name = "nook/fix-login-1a2b".into();
        assert_eq!(c.problem(), None);
    }

    #[test]
    fn naming() {
        assert_eq!(slug("Fix de login-bug in Safari!", 40), "fix-de-login-bug-in-safari");
        assert_eq!(slug("Één café", 40), "een-cafe");
        assert_eq!(slug("!!!", 40), "sessie");
        assert!(slug(&"abc ".repeat(40), 20).chars().count() <= 20);
        assert_eq!(title_from("Korte taak\nmet details", 60), "Korte taak");
        assert_eq!(title_from("   ", 60), "Nieuwe sessie");
        assert!(title_from(&"woord ".repeat(30), 60).ends_with('…'));
        for task in ["Is de ci gefaald?", "Fix: login [urgent] *nu*", "~weg^ @{x} \\"] {
            assert!(is_plausible_branch_name(&branch_name(task, Uuid::new_v4())), "{task}");
        }
        let id = Uuid::parse_str("3FA2C1D0-0000-0000-0000-000000000000").unwrap();
        assert_eq!(branch_name("Add archive button", id), "nook/add-archive-button-3fa2");
        for bad in ["", "-x", "a..b", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "x.lock", "x/", "/x", "@", "a@{b", "x."] {
            assert!(!is_plausible_branch_name(bad), "{bad}");
        }
        for good in ["main", "feature/x", "nook/fix-1", "release-1.2"] {
            assert!(is_plausible_branch_name(good), "{good}");
        }
    }

    #[test]
    fn worktree_path_avoids_existing() {
        let existing = std::cell::RefCell::new(std::collections::HashSet::new());
        let first = worktree_path("/r", "My Repo", "task", |p| existing.borrow().contains(p));
        assert_eq!(first, std::path::Path::new("/r/my-repo/task").to_string_lossy());
        existing.borrow_mut().insert(first);
        let second = worktree_path("/r", "My Repo", "task", |p| existing.borrow().contains(p));
        assert_eq!(second, std::path::Path::new("/r/my-repo/task-2").to_string_lossy());
    }

    #[test]
    fn usage_keeps_unknown_fields_none() {
        let mut u = RunUsage::default();
        assert_eq!(u.total_tokens(), None);
        u.add(&TurnUsage { input_tokens: Some(100), output_tokens: Some(20), duration_seconds: Some(3.0), ..Default::default() });
        assert_eq!(u.input_tokens, Some(100));
        assert_eq!(u.cache_read_tokens, None);
        assert_eq!(u.reported_cost_usd, None);
        u.add(&TurnUsage {
            input_tokens: Some(50),
            output_tokens: Some(5),
            cache_read_tokens: Some(1000),
            reported_cost_usd: Some(0.12),
            context_tokens: Some(1200),
            context_window: Some(200_000),
            duration_seconds: Some(2.0),
            ..Default::default()
        });
        assert_eq!((u.input_tokens, u.output_tokens, u.cache_read_tokens), (Some(150), Some(25), Some(1000)));
        assert!((u.reported_cost_usd.unwrap() - 0.12).abs() < 1e-6);
        assert_eq!(u.turns, 2);
        assert!((u.active_seconds - 5.0).abs() < 1e-6);
        assert!((u.context_fraction().unwrap() - 0.006).abs() < 1e-6);
        assert_eq!(u.total_tokens(), Some(1175));
    }

    #[test]
    fn unreviewed_changes() {
        let mut r = run(RunStatus::Completed);
        assert!(!r.has_unreviewed_changes());
        let now = Utc::now();
        r.last_change_at = Some(now);
        assert!(r.has_unreviewed_changes());
        r.reviewed_at = Some(now + chrono::Duration::seconds(1));
        assert!(!r.has_unreviewed_changes());
        r.last_change_at = Some(now + chrono::Duration::seconds(5));
        r.changed_files = Some(0);
        assert!(!r.has_unreviewed_changes());
    }

    #[test]
    fn tool_summaries() {
        assert_eq!(tool_summary::describe("Bash", &json!({"command": "npm test\n--watch"})), "Bash · npm test --watch");
        assert_eq!(tool_summary::describe("Edit", &json!({"file_path": "/a/b/Login.swift"})), "Edit · Login.swift");
        assert_eq!(
            tool_summary::describe("mcp__bestanden-mappen__move_file", &json!({"source": "/a.txt", "destination": "/b.txt"})),
            "Bestanden mappen › Move file · Destination: /b.txt, Source: /a.txt"
        );
        assert_eq!(tool_summary::command(&json!({"command": ["bash", "-lc", "ls -la"]})).as_deref(), Some("ls -la"));
        assert_eq!(tool_summary::file_changes("Write", &json!({"file_path": "/x/y.txt"}))[0].1, "written");
        assert!(tool_summary::file_changes("Read", &json!({"file_path": "/x/y.txt"})).is_empty());
    }
}
