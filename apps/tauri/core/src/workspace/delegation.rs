//! Handing work to a coding agent (`Delegation.swift` and `AppModel+AgentSessionTools.swift` on the Mac).
//!
//! A session delegates a focused subtask to a child session (the bridge's `delegate_task`); Nook Chat starting a
//! session on a task is `start_agent_session` in `src-tauri/src/tools/agents.rs`. The rules here keep delegation safe:
//! a child never has more rights than its parent, it sees only the task (not the parent's conversation), and the chain
//! is bounded. No processes here; the app starts the child through the manager.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::manager::Manager;
use super::models::{
    clip_to, EventKind, ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunEvent, RunProvider, RunStatus, WorkspaceRun,
};

/// What a delegated task is for. It only changes the instruction the agent gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Implementation,
    Research,
    Review,
    Design,
    Test,
    General,
}

impl Role {
    pub fn named(raw: &str) -> Option<Self> {
        Some(match raw.trim().to_ascii_lowercase().as_str() {
            "implementation" => Self::Implementation,
            "research" => Self::Research,
            "review" => Self::Review,
            "design" => Self::Design,
            "test" => Self::Test,
            "" | "general" => Self::General,
            _ => return None,
        })
    }

    pub fn instruction(self) -> &'static str {
        match self {
            Self::Implementation => "Role: implementation. Make the change the task describes and keep it focused.",
            Self::Research => "Role: research. Investigate and report what you find; do not change files.",
            Self::Review => "Role: review. Read the work critically and list concrete problems; do not change files.",
            Self::Design => "Role: design. Propose an approach with its trade-offs; do not change files.",
            Self::Test => "Role: test. Write or run tests for the described behaviour and report the outcome.",
            Self::General => "",
        }
    }

    /// Roles that only look: the agent runs in Plan mode unless asked otherwise.
    pub fn read_only(self) -> bool {
        matches!(self, Self::Research | Self::Review | Self::Design)
    }
}

/// How deep a chain may go: you → child → grandchild.
pub const MAX_DEPTH: usize = 2;
/// Children running at the same time for one parent.
pub const MAX_ACTIVE_CHILDREN: usize = 4;

/// What every child of a session is told after its brief.
pub const CHILD_NOTE: &str = "You are a task delegated from another session in Nook. Do the work yourself; start no subtasks unless this brief asks for them. End with a short report of what you did and found: it is all the other session sees.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Denial {
    /// The child asked for more than its parent has: "mode", "rights".
    Escalation(&'static str),
    Unsupported(PermissionPolicy),
    TooDeep,
    TooManyChildren,
}

impl Denial {
    /// For the agent that asked (English, like every tool result).
    pub fn message(&self) -> String {
        match self {
            Self::Escalation(what) => format!("A delegated task cannot have broader {what} than the session that delegates it."),
            Self::Unsupported(p) => {
                format!("That agent does not offer the rights \"{p:?}\" without asking. Choose other rights or another agent.")
            }
            Self::TooDeep => format!("Delegated tasks can go {MAX_DEPTH} levels deep at most. Do this part yourself."),
            Self::TooManyChildren => {
                format!("Already {MAX_ACTIVE_CHILDREN} delegated tasks are running. Wait for one to finish before delegating more.")
            }
        }
    }
}

fn rank(policy: PermissionPolicy) -> u8 {
    match policy {
        PermissionPolicy::Ask => 0,
        PermissionPolicy::AcceptEdits => 1,
        PermissionPolicy::Bypass => 2,
    }
}

fn mode_rank(mode: ExecutionMode) -> u8 {
    if mode == ExecutionMode::Plan {
        0
    } else {
        1
    }
}

/// The mode and rights of a child. Omitted values are inherited; asking for more than the parent has is refused; an
/// inherited right the target agent does not offer steps down to the broadest one it does. A read-only role plans.
pub fn resolve(
    parent_mode: ExecutionMode,
    parent_permission: PermissionPolicy,
    mode: Option<ExecutionMode>,
    permission: Option<PermissionPolicy>,
    role: Role,
    target: RunProvider,
) -> Result<(ExecutionMode, PermissionPolicy), Denial> {
    let mut chosen_mode = mode.unwrap_or(if role.read_only() { ExecutionMode::Plan } else { parent_mode });
    if mode_rank(chosen_mode) > mode_rank(parent_mode) {
        return Err(Denial::Escalation("mode"));
    }
    if parent_mode == ExecutionMode::Plan {
        chosen_mode = ExecutionMode::Plan;
    }
    let mut chosen = permission.unwrap_or(parent_permission);
    if rank(chosen) > rank(parent_permission) {
        return Err(Denial::Escalation("rights"));
    }
    let offered = target.capabilities().policies;
    if !offered.contains(&chosen) {
        if permission.is_some() {
            return Err(Denial::Unsupported(chosen));
        }
        chosen =
            offered.iter().copied().filter(|p| rank(*p) <= rank(chosen)).max_by_key(|p| rank(*p)).ok_or(Denial::Unsupported(chosen))?;
    }
    Ok((chosen_mode, chosen))
}

/// May this parent delegate another task now?
pub fn admit(parent_depth: usize, active_children: usize) -> Option<Denial> {
    if parent_depth >= MAX_DEPTH {
        Some(Denial::TooDeep)
    } else if active_children >= MAX_ACTIVE_CHILDREN {
        Some(Denial::TooManyChildren)
    } else {
        None
    }
}

/// What a child is told: the task and its role, nothing from the parent's conversation.
pub fn child_prompt(task: &str, role: Role) -> String {
    [task.trim(), role.instruction(), CHILD_NOTE].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join("\n\n")
}

/// The link from a child session to the session that delegated to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub parent: Uuid,
    /// 1 for a child of a session you started, 2 for its child.
    pub depth: usize,
    /// A repeated call with the same key returns the same child instead of starting a second one.
    #[serde(default)]
    pub key: String,
    /// The parent hears when this task ends (`wake_message`): it did not wait for it, or its wait ran out.
    #[serde(default)]
    pub wake: bool,
}

/// `delegations.json` next to the sessions: child → link.
pub struct Links {
    file: PathBuf,
    links: Mutex<BTreeMap<Uuid, Link>>,
}

impl Links {
    pub fn new(directory: &Path) -> Self {
        let file = directory.join("delegations.json");
        let links = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file, links: Mutex::new(links) }
    }

    pub fn link(&self, child: Uuid) -> Option<Link> {
        self.links.lock().ok()?.get(&child).cloned()
    }

    /// How deep `session` is: 0 for a session you started.
    pub fn depth(&self, session: Uuid) -> usize {
        self.link(session).map_or(0, |l| l.depth)
    }

    pub fn children(&self, parent: Uuid) -> Vec<Uuid> {
        self.links.lock().map(|l| l.iter().filter(|(_, v)| v.parent == parent).map(|(k, _)| *k).collect()).unwrap_or_default()
    }

    /// Turns the parent's wake-up for this task on or off; returns whether the task is linked.
    pub fn set_wake(&self, child: Uuid, wake: bool) -> bool {
        let Ok(mut links) = self.links.lock() else { return false };
        let Some(link) = links.get_mut(&child) else { return false };
        link.wake = wake;
        if let Ok(bytes) = serde_json::to_vec_pretty(&*links) {
            let _ = crate::paths::write_atomic(&self.file, &bytes);
        }
        true
    }

    /// The child for a retried request (`client_request_id`).
    pub fn child_with_key(&self, parent: Uuid, key: &str) -> Option<Uuid> {
        if key.is_empty() {
            return None;
        }
        self.links.lock().ok()?.iter().find(|(_, v)| v.parent == parent && v.key == key).map(|(k, _)| *k)
    }

    fn insert(&self, child: Uuid, link: Link) {
        let Ok(mut links) = self.links.lock() else { return };
        links.insert(child, link);
        if let Ok(bytes) = serde_json::to_vec_pretty(&*links) {
            let _ = crate::paths::write_atomic(&self.file, &bytes);
        }
    }
}

/// What a session asks for when it delegates.
#[derive(Debug, Clone, Default)]
pub struct Request {
    pub task: String,
    pub title: String,
    pub role: Option<Role>,
    /// Another agent than the parent's; `None` is the parent's own.
    pub agent: Option<RunProvider>,
    pub mode: Option<ExecutionMode>,
    pub permission: Option<PermissionPolicy>,
    pub key: String,
    /// Another model than the default; empty is the parent's (same agent) or the agent's default.
    pub model: String,
    /// `shared`, `worktree`, or empty to let Nook choose (`placement`).
    pub isolation: String,
    /// The parent hears when the task ends (it does not wait for it).
    pub wake: bool,
}

/// Where a task works: in its parent's folder, or in a git worktree of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    Shared,
    Worktree,
}

/// The placement asked for, or the error for the agent. Two tasks changing the same files at once overwrite each
/// other, so with nothing asked a second writer in the same folder gets a worktree. A Plan task changes nothing.
pub fn placement(requested: &str, mode: ExecutionMode, writing_siblings: usize, in_repository: bool) -> Result<Placement, String> {
    match requested.trim().to_ascii_lowercase().as_str() {
        "shared" => Ok(Placement::Shared),
        "worktree" if !in_repository => Err("A worktree needs a git repository; this folder is not one. Use isolation: shared.".into()),
        "worktree" => Ok(if mode == ExecutionMode::Plan { Placement::Shared } else { Placement::Worktree }),
        "" if mode == ExecutionMode::Agent && in_repository && writing_siblings > 0 => Ok(Placement::Worktree),
        "" => Ok(Placement::Shared),
        other => Err(format!("isolation must be shared or worktree, not \"{other}\".")),
    }
}

/// How long `delegate_task` with `wait` and `task_wait` wait: default and most, in seconds.
pub const DEFAULT_WAIT: u64 = 45;
pub const MAX_WAIT: u64 = 840;

pub fn wait_seconds(requested: Option<i64>) -> u64 {
    requested.map(|n| n.clamp(1, MAX_WAIT as i64) as u64).unwrap_or(DEFAULT_WAIT)
}

/// A delegated task as its parent sees it (`DelegatedTask` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskState {
    Queued,
    Running,
    Waiting,
    Completed,
    Failed,
    Cancelled,
}

impl TaskState {
    /// `queued_work`: a message still waits to go out to the task (not held after a failure or a stop); the task is
    /// not done until it went.
    pub fn of(status: RunStatus, pending_question: bool, queued_work: bool) -> Self {
        if queued_work && !status.is_active() {
            return Self::Running;
        }
        match status {
            RunStatus::Preparing => Self::Queued,
            RunStatus::Running if pending_question => Self::Waiting,
            RunStatus::Running => Self::Running,
            RunStatus::WaitingApproval => Self::Waiting,
            RunStatus::Completed => Self::Completed,
            RunStatus::Failed => Self::Failed,
            RunStatus::Stopped => Self::Cancelled,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub task_id: String,
    pub title: String,
    pub state: TaskState,
    pub summary: Option<String>,
    pub pending_question: bool,
    pub model: String,
    pub provider: String,
    /// For a task in a worktree of its own: where it works and on which branch, so the parent can merge it.
    pub worktree: Option<String>,
    pub branch: Option<String>,
}

impl Snapshot {
    /// Finished, or asking something only the parent or the user can answer.
    pub fn is_settled(&self) -> bool {
        self.state.is_terminal() || self.pending_question
    }

    fn object(&self) -> serde_json::Map<String, serde_json::Value> {
        use serde_json::Value;
        let mut o = serde_json::Map::new();
        o.insert("taskId".into(), self.task_id.clone().into());
        o.insert("title".into(), self.title.clone().into());
        o.insert("status".into(), self.state.name().into());
        o.insert("agent".into(), self.provider.clone().into());
        o.insert("hasPendingQuestion".into(), self.pending_question.into());
        if !self.model.is_empty() {
            o.insert("model".into(), self.model.clone().into());
        }
        if let Some(worktree) = self.worktree.as_ref().filter(|w| !w.is_empty()) {
            o.insert("worktree".into(), worktree.clone().into());
            if let Some(branch) = self.branch.as_ref().filter(|b| !b.is_empty()) {
                o.insert("branch".into(), branch.clone().into());
                o.insert("merge".into(), merge_note(branch).into());
            }
        }
        o.insert("summary".into(), self.summary.clone().map(Value::String).unwrap_or(Value::Null));
        o
    }

    /// The tool result: JSON the agent can read.
    pub fn render(&self, wait_timed_out: bool) -> String {
        let mut o = self.object();
        o.insert("waitTimedOut".into(), wait_timed_out.into());
        pretty(serde_json::Value::Object(o))
    }
}

fn merge_note(branch: &str) -> String {
    format!("Its changes are on branch {branch}, not in your folder: review them, then merge that branch (git merge {branch}) once it has committed.")
}

/// Pretty JSON with sorted keys, as the Mac writes it.
fn pretty(value: serde_json::Value) -> String {
    fn sort(v: serde_json::Value) -> serde_json::Value {
        match v {
            serde_json::Value::Object(m) => {
                let sorted: BTreeMap<String, serde_json::Value> = m.into_iter().map(|(k, v)| (k, sort(v))).collect();
                serde_json::Value::Object(sorted.into_iter().collect())
            }
            serde_json::Value::Array(a) => serde_json::Value::Array(a.into_iter().map(sort).collect()),
            other => other,
        }
    }
    serde_json::to_string_pretty(&sort(value)).unwrap_or_default()
}

/// How `task_wait` waits on several tasks: until one of them (`any`) or all of them settle.
pub fn wait_is_over(snapshots: &[Snapshot], all: bool) -> bool {
    if snapshots.is_empty() {
        return true;
    }
    if all {
        snapshots.iter().all(Snapshot::is_settled)
    } else {
        snapshots.iter().any(Snapshot::is_settled)
    }
}

/// The `task_wait` result: every task's state, and whether the wait ran out first.
pub fn render_wait(snapshots: &[Snapshot], wait_timed_out: bool) -> String {
    let tasks: Vec<serde_json::Value> = snapshots.iter().map(|s| serde_json::Value::Object(s.object())).collect();
    let settled: Vec<String> = snapshots.iter().filter(|s| s.is_settled()).map(|s| s.task_id.clone()).collect();
    pretty(serde_json::json!({"tasks": tasks, "waitTimedOut": wait_timed_out, "settled": settled}))
}

/// What the parent is told when a task it did not wait for has ended: everything it needs, so it need not ask again.
pub fn wake_message(snapshot: &Snapshot) -> String {
    let mut text = format!("Delegated task \"{}\" ({}) {}.", snapshot.title, snapshot.task_id, snapshot.state.name());
    if let Some(summary) = snapshot.summary.as_ref().filter(|s| !s.is_empty()) {
        text += &format!("\n\nResult:\n{summary}");
    }
    if let Some(branch) = snapshot.branch.as_ref().filter(|b| !b.is_empty()) {
        text += &format!("\n\n{}", merge_note(branch));
    }
    text
}

/// Whether the parent hears of a finished task now: it ended (well, failed or stopped) and nothing it still has to do
/// waits in its queue, so the parent never reads a result that is not the last.
pub fn may_deliver(status: RunStatus, queued_work: bool) -> bool {
    matches!(status, RunStatus::Completed | RunStatus::Failed | RunStatus::Stopped) && !queued_work
}

pub const SUMMARY_LIMIT: usize = 4_000;

/// The result of a task: what the child said last, or why it failed (the error before any progress text).
pub fn summary(status: RunStatus, status_detail: Option<&str>, events: &[RunEvent]) -> Option<String> {
    if status == RunStatus::Failed {
        let error = events.iter().rev().find(|e| e.kind == EventKind::Error).map(|e| e.text.as_str()).or(status_detail);
        if let Some(e) = error.filter(|e| !e.is_empty()) {
            return Some(clip_to(e, SUMMARY_LIMIT));
        }
    }
    events.iter().rev().find(|e| e.kind == EventKind::Assistant && !e.text.trim().is_empty()).map(|e| clip_to(e.text.trim(), SUMMARY_LIMIT))
}

/// A task as its parent sees it now.
pub fn snapshot(manager: &Manager, run: &WorkspaceRun) -> Snapshot {
    let queue = manager.queue(run.id);
    let queued_work = !queue.is_empty() && !queue.is_held();
    let pending_question = !manager.questions(run.id).is_empty();
    let worktree = (run.isolation == IsolationMode::Worktree).then(|| run.worktree_path.clone().unwrap_or_default());
    Snapshot {
        task_id: run.id.to_string(),
        title: run.title.clone(),
        state: TaskState::of(run.status, pending_question, queued_work),
        summary: summary(run.status, run.status_detail.as_deref(), &manager.timeline(run.id)),
        pending_question,
        model: run.resolved_model.clone().unwrap_or_else(|| run.model.clone()),
        provider: run.provider.id().into(),
        branch: worktree.as_ref().and(run.branch.clone()),
        worktree,
    }
}

/// Starts a child session in the parent's folder with at most the parent's rights. Returns the child's id (the same
/// child again for a repeated key). `profile`: the user's account for an agent the parent does not run itself.
pub fn delegate(
    manager: &Arc<Manager>,
    links: &Links,
    parent: Uuid,
    request: Request,
    profile: &dyn Fn(RunProvider) -> String,
) -> Result<Uuid, String> {
    let run = manager.run(parent).ok_or("Delegating works from a session that Nook runs.")?;
    if let Some(existing) = links.child_with_key(parent, request.key.trim()) {
        return Ok(existing);
    }
    let task = request.task.trim();
    if task.is_empty() {
        return Err("Give the task for the delegated session.".into());
    }
    let active = links.children(parent).into_iter().filter(|c| manager.run(*c).is_some_and(|r| r.status.is_active())).count();
    let depth = links.depth(parent);
    if let Some(denial) = admit(depth, active) {
        return Err(denial.message());
    }
    let role = request.role.unwrap_or(Role::General);
    let provider = request.agent.unwrap_or(run.provider);
    let (mode, permission) =
        resolve(run.mode, run.permission, request.mode, request.permission, role, provider).map_err(|d| d.message())?;
    let same_folder = |r: &WorkspaceRun| super::paths::normalize(&r.working_directory) == super::paths::normalize(&run.working_directory);
    let writing_siblings = links
        .children(parent)
        .into_iter()
        .filter_map(|c| manager.run(c))
        .filter(|r| r.status.is_active() && r.mode == ExecutionMode::Agent && r.isolation == IsolationMode::Folder && same_folder(r))
        .count();
    let repo_root = run.repo_root.clone().filter(|r| !r.is_empty());
    let place = placement(&request.isolation, mode, writing_siblings, repo_root.is_some())?;
    let model = request.model.trim();
    let mut config = NewRunConfig {
        title: if request.title.trim().is_empty() { super::models::title_from(task, 60) } else { request.title.trim().into() },
        task: child_prompt(task, role),
        provider,
        profile_id: if provider == run.provider { run.profile_id.clone() } else { profile(provider) },
        model: if !model.is_empty() {
            model.into()
        } else if provider == run.provider {
            run.model.clone()
        } else {
            String::new()
        },
        mode,
        permission,
        isolation: IsolationMode::Folder,
        project_path: run.working_directory.clone(),
        ..NewRunConfig::default()
    };
    if place == Placement::Worktree {
        // From the parent's branch, so the task starts from what the parent committed.
        config.isolation = IsolationMode::Worktree;
        config.project_path = repo_root.unwrap_or_else(|| run.working_directory.clone());
        config.base_branch = run.branch.clone().unwrap_or_default();
    }
    let child = manager.start(config, place == Placement::Shared)?;
    links.insert(child, Link { parent, depth: depth + 1, key: request.key.trim().to_string(), wake: request.wake });
    manager.note(child, &crate::i18n::trf("Gedelegeerd door ‘{parent}’", "Delegated by “{parent}”", &[("parent", &run.title)]));
    Ok(child)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ExecutionMode::*;
    use PermissionPolicy::*;

    #[test]
    fn a_child_never_gets_more_than_its_parent() {
        assert_eq!(resolve(Agent, AcceptEdits, None, None, Role::General, RunProvider::Codex), Ok((Agent, AcceptEdits)));
        assert_eq!(resolve(Agent, AcceptEdits, None, Some(Bypass), Role::General, RunProvider::Claude), Err(Denial::Escalation("rights")));
        assert_eq!(resolve(Plan, Ask, Some(Agent), None, Role::General, RunProvider::Claude), Err(Denial::Escalation("mode")));
        assert_eq!(resolve(Agent, Bypass, None, None, Role::Review, RunProvider::Claude), Ok((Plan, Bypass)));
        assert_eq!(resolve(Agent, Ask, Some(Agent), None, Role::Research, RunProvider::Claude), Ok((Agent, Ask)));
    }

    #[test]
    fn the_chain_is_bounded() {
        assert_eq!(admit(0, 0), None);
        assert_eq!(admit(MAX_DEPTH, 0), Some(Denial::TooDeep));
        assert_eq!(admit(1, MAX_ACTIVE_CHILDREN), Some(Denial::TooManyChildren));
    }

    #[test]
    fn the_child_sees_only_the_task() {
        let p = child_prompt("  Check the parser  ", Role::Review);
        assert!(p.starts_with("Check the parser\n\nRole: review."));
        assert!(p.ends_with(CHILD_NOTE));
        assert_eq!(child_prompt("x", Role::General), format!("x\n\n{CHILD_NOTE}"));
        assert_eq!(Role::named("Test"), Some(Role::Test));
        assert_eq!(Role::named("boss"), None);
    }

    #[test]
    fn links_remember_depth_and_children() {
        let dir = std::env::temp_dir().join(format!("nook-delegation-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let (parent, child, grandchild) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let links = Links::new(&dir);
        links.insert(child, Link { parent, depth: 1, key: "k".into(), wake: false });
        links.insert(grandchild, Link { parent: child, depth: 2, key: String::new(), wake: true });
        let again = Links::new(&dir);
        assert_eq!(again.depth(parent), 0);
        assert_eq!(again.depth(grandchild), 2);
        assert_eq!(again.children(parent), vec![child]);
        assert_eq!(again.child_with_key(parent, "k"), Some(child));
        assert_eq!(again.child_with_key(parent, ""), None);
        assert_eq!(admit(again.depth(grandchild), 0), Some(Denial::TooDeep));
        assert!(again.link(grandchild).unwrap().wake);
        assert!(again.set_wake(child, true));
        assert!(Links::new(&dir).link(child).unwrap().wake, "kept on disk");
        assert!(!again.set_wake(Uuid::new_v4(), true));
        let _ = std::fs::remove_dir_all(dir);
    }

    fn snap(id: &str, state: TaskState, question: bool) -> Snapshot {
        Snapshot {
            task_id: id.into(),
            title: "Check parser".into(),
            state,
            summary: Some("All good".into()),
            pending_question: question,
            model: String::new(),
            provider: "codex".into(),
            worktree: None,
            branch: None,
        }
    }

    #[test]
    fn where_a_task_works() {
        use Placement::*;
        assert_eq!(placement("", Agent, 0, true), Ok(Shared));
        assert_eq!(placement("", Agent, 1, true), Ok(Worktree), "a second writer gets its own worktree");
        assert_eq!(placement("", Plan, 3, true), Ok(Shared));
        assert_eq!(placement("", Agent, 1, false), Ok(Shared));
        assert_eq!(placement("Worktree", Plan, 0, true), Ok(Shared));
        assert_eq!(placement("worktree", Agent, 0, true), Ok(Worktree));
        assert!(placement("worktree", Agent, 0, false).unwrap_err().contains("git repository"));
        assert!(placement("nearby", Agent, 0, true).unwrap_err().contains("\"nearby\""));
        assert_eq!(wait_seconds(None), 45);
        assert_eq!(wait_seconds(Some(10_000)), 840);
    }

    #[test]
    fn task_states_follow_the_session() {
        use TaskState::*;
        assert_eq!(TaskState::of(RunStatus::Preparing, false, false), Queued);
        assert_eq!(TaskState::of(RunStatus::Running, true, false), Waiting);
        assert_eq!(TaskState::of(RunStatus::WaitingApproval, false, false), Waiting);
        assert_eq!(TaskState::of(RunStatus::Completed, false, true), Running, "queued work is still to come");
        assert_eq!(TaskState::of(RunStatus::Stopped, false, false), Cancelled);
        assert!(may_deliver(RunStatus::Failed, false));
        assert!(!may_deliver(RunStatus::Completed, true));
        assert!(!may_deliver(RunStatus::Running, false));
    }

    #[test]
    fn results_read_as_on_the_mac() {
        let mut s = snap("t1", TaskState::Completed, false);
        s.worktree = Some("/w/t1".into());
        s.branch = Some("nook/t1".into());
        let v: serde_json::Value = serde_json::from_str(&s.render(true)).unwrap();
        assert_eq!(v["status"], "completed");
        assert_eq!(v["agent"], "codex");
        assert_eq!(v["waitTimedOut"], true);
        assert!(v["merge"].as_str().unwrap().contains("git merge nook/t1"));
        assert!(v.get("model").is_none());
        let running = snap("t2", TaskState::Running, false);
        assert!(!wait_is_over(std::slice::from_ref(&running), false));
        assert!(wait_is_over(&[running.clone(), s.clone()], false));
        assert!(!wait_is_over(&[running.clone(), s.clone()], true));
        assert!(wait_is_over(&[snap("t3", TaskState::Running, true), s.clone()], true), "a question settles too");
        let w: serde_json::Value = serde_json::from_str(&render_wait(&[running, s.clone()], false)).unwrap();
        assert_eq!(w["settled"], serde_json::json!(["t1"]));
        assert!(w["tasks"][0].get("waitTimedOut").is_none());
        let wake = wake_message(&s);
        assert!(wake.starts_with("Delegated task \"Check parser\" (t1) completed.\n\nResult:\nAll good"));
        assert!(wake.ends_with("once it has committed."));
    }

    #[test]
    fn a_failed_task_reports_its_error() {
        let events = vec![RunEvent::new(EventKind::Assistant, "Working on it"), RunEvent::new(EventKind::Error, "Out of credits")];
        assert_eq!(summary(RunStatus::Failed, None, &events).as_deref(), Some("Out of credits"));
        assert_eq!(summary(RunStatus::Completed, None, &events).as_deref(), Some("Working on it"));
        assert_eq!(summary(RunStatus::Failed, Some("Crashed"), &[]).as_deref(), Some("Crashed"));
        assert_eq!(summary(RunStatus::Completed, None, &[]), None);
    }
}
