//! Handing work to a coding agent (`Delegation.swift` and `AppModel+AgentSessionTools.swift` on the Mac).
//!
//! Two ways in: Nook Chat starts a session on a task (`start_agent_session`, an action the user approves in the
//! chat's plan first), and a session delegates a focused subtask to a child session. The rules here keep both safe: a
//! child never has more rights than its parent, the agent sees only the task (not the chat or the parent's
//! conversation), and the chain is bounded. No processes here; the app starts the session through the manager.

use super::models::{ExecutionMode, PermissionPolicy, RunProvider};

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
            Self::TooManyChildren => format!(
                "Already {MAX_ACTIVE_CHILDREN} delegated tasks are running. Wait for one to finish before delegating more."
            ),
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
        chosen = offered.iter().copied().filter(|p| rank(*p) <= rank(chosen)).max_by_key(|p| rank(*p)).ok_or(Denial::Unsupported(chosen))?;
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

/// The agent Nook Chat asked for: its id or its name in any case; empty is the user's default.
pub fn agent_named(asked: &str, default: RunProvider) -> Option<RunProvider> {
    let asked = asked.trim().to_lowercase();
    if asked.is_empty() {
        return Some(default);
    }
    RunProvider::ALL.into_iter().find(|p| p.id() == asked || p.display_name().to_lowercase() == asked)
}

/// The folder Nook Chat asked for, only among folders the user already worked in (favorites first, then recent):
/// the same path, or a folder with that name. Empty is the most recent one. Nook Chat never opens a new folder by
/// itself, so a session cannot start somewhere the user never chose.
pub fn folder_named(wanted: &str, known: &[String]) -> Option<String> {
    let wanted = wanted.trim().trim_end_matches(['/', '\\']);
    if wanted.is_empty() {
        return known.first().cloned();
    }
    let name = |p: &str| p.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default().to_lowercase();
    known
        .iter()
        .find(|p| p.trim_end_matches(['/', '\\']) == wanted)
        .or_else(|| known.iter().find(|p| name(p) == wanted.to_lowercase()))
        .or_else(|| known.iter().find(|p| name(p) == name(wanted)))
        .cloned()
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
    fn finds_the_agent_and_folder_nook_chat_asked_for() {
        assert_eq!(agent_named("", RunProvider::Codex), Some(RunProvider::Codex));
        assert_eq!(agent_named("Claude Code", RunProvider::Codex), Some(RunProvider::Claude));
        assert_eq!(agent_named("gemini", RunProvider::Codex), Some(RunProvider::Gemini));
        assert_eq!(agent_named("hal", RunProvider::Codex), None);
        let known = vec!["/home/me/code/app".to_string(), "/home/me/code/site/".to_string()];
        assert_eq!(folder_named("", &known).as_deref(), Some("/home/me/code/app"));
        assert_eq!(folder_named("Site", &known).as_deref(), Some("/home/me/code/site/"));
        assert_eq!(folder_named("/home/me/code/app/", &known).as_deref(), Some("/home/me/code/app"));
        assert_eq!(folder_named("~/elsewhere/app", &known).as_deref(), Some("/home/me/code/app"));
        assert_eq!(folder_named("/etc", &known), None);
    }
}
