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
use super::models::{ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunProvider};

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

    fn child_with_key(&self, parent: Uuid, key: &str) -> Option<Uuid> {
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
    let config = NewRunConfig {
        title: if request.title.trim().is_empty() { super::models::title_from(task, 60) } else { request.title.trim().into() },
        task: child_prompt(task, role),
        provider,
        profile_id: if provider == run.provider { run.profile_id.clone() } else { profile(provider) },
        model: if provider == run.provider { run.model.clone() } else { String::new() },
        mode,
        permission,
        isolation: IsolationMode::Folder,
        project_path: run.working_directory.clone(),
        ..NewRunConfig::default()
    };
    let child = manager.start(config, true)?;
    links.insert(child, Link { parent, depth: depth + 1, key: request.key.trim().to_string() });
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
        links.insert(child, Link { parent, depth: 1, key: "k".into() });
        links.insert(grandchild, Link { parent: child, depth: 2, key: String::new() });
        let again = Links::new(&dir);
        assert_eq!(again.depth(parent), 0);
        assert_eq!(again.depth(grandchild), 2);
        assert_eq!(again.children(parent), vec![child]);
        assert_eq!(again.child_with_key(parent, "k"), Some(child));
        assert_eq!(again.child_with_key(parent, ""), None);
        assert_eq!(admit(again.depth(grandchild), 0), Some(Denial::TooDeep));
        let _ = std::fs::remove_dir_all(dir);
    }
}
