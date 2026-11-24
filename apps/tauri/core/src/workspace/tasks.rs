//! The agent's own task list while it works (`RunTasks` and `RunTaskStep` on the Mac): Claude Code's `TodoWrite` (and
//! the same shape from Cursor's `todo_write`, OpenCode's `todowrite` and Gemini CLI's `write_todos`), Codex's
//! `turn/plan/updated`, and an ACP agent's `plan` update. Every agent's list lands in the same steps, so the Tasks strip
//! and its current phase work alike for all of them.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum StepStatus {
    #[default]
    Pending,
    Active,
    Done,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunTaskStep {
    pub text: String,
    pub status: StepStatus,
}

pub fn status(raw: Option<&str>) -> StepStatus {
    match raw {
        Some("completed" | "done") => StepStatus::Done,
        Some("in_progress" | "inProgress" | "running" | "active") => StepStatus::Active,
        Some("cancelled" | "canceled") => StepStatus::Cancelled,
        _ => StepStatus::Pending,
    }
}

/// The tools that write a task list in Claude Code's shape.
pub fn is_todo_tool(name: &str) -> bool {
    matches!(name, "TodoWrite" | "todo_write" | "todowrite" | "write_todos")
}

/// `todos` with `content` (or `description`), `status` and, for the running one, `activeForm`.
pub fn claude(input: &Value) -> Option<Vec<RunTaskStep>> {
    let todos = input.get("todos")?.as_array()?;
    Some(
        todos
            .iter()
            .filter_map(|todo| {
                let state = status(todo.get("status").and_then(Value::as_str));
                let active = todo.get("activeForm").and_then(Value::as_str).filter(|s| !s.is_empty());
                let text = (if state == StepStatus::Active { active } else { None })
                    .or_else(|| todo.get("content").and_then(Value::as_str))
                    .or_else(|| todo.get("description").and_then(Value::as_str))
                    .filter(|t| !t.is_empty())?;
                Some(RunTaskStep { text: text.to_string(), status: state })
            })
            .collect(),
    )
}

/// Codex's `turn/plan/updated`: `plan` with `step` and `status`.
pub fn codex(params: &Value) -> Option<Vec<RunTaskStep>> {
    let plan = params.get("plan")?.as_array()?;
    Some(
        plan.iter()
            .enumerate()
            .map(|(i, step)| {
                let text = step.get("step").and_then(Value::as_str).unwrap_or("").trim();
                RunTaskStep {
                    text: if text.is_empty() { format!("Step {}", i + 1) } else { text.to_string() },
                    status: status(step.get("status").and_then(Value::as_str)),
                }
            })
            .collect(),
    )
}

/// An ACP `plan` update: `entries` with `content` and `status`.
pub fn acp(update: &Value) -> Vec<RunTaskStep> {
    update
        .get("entries")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let text = e.get("content").and_then(Value::as_str).filter(|t| !t.is_empty())?;
            Some(RunTaskStep { text: text.to_string(), status: status(e.get("status").and_then(Value::as_str)) })
        })
        .collect()
}

/// How far the list is, and the step that matters now: the running one, else the next, else the last. A dropped step
/// counts in neither number.
pub fn progress(steps: &[RunTaskStep]) -> (usize, usize, String) {
    let current = steps
        .iter()
        .find(|s| s.status == StepStatus::Active)
        .or_else(|| steps.iter().find(|s| s.status == StepStatus::Pending))
        .or_else(|| steps.iter().rev().find(|s| s.status != StepStatus::Cancelled))
        .or(steps.last());
    (
        steps.iter().filter(|s| s.status == StepStatus::Done).count(),
        steps.iter().filter(|s| s.status != StepStatus::Cancelled).count(),
        current.map(|s| s.text.clone()).unwrap_or_default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_every_agents_list() {
        let todo = json!({"todos": [
            {"content": "Read the code", "status": "completed"},
            {"content": "Fix the bug", "activeForm": "Fixing the bug", "status": "in_progress"},
            {"content": "Write a test", "status": "pending"},
            {"content": "Old idea", "status": "cancelled"}
        ]});
        let steps = claude(&todo).unwrap();
        assert_eq!(steps[1].text, "Fixing the bug");
        assert_eq!(progress(&steps), (1, 3, "Fixing the bug".into()));
        let plan = codex(&json!({"plan": [{"step": "", "status": "completed"}, {"step": "Ship", "status": "inProgress"}]})).unwrap();
        assert_eq!(plan[0].text, "Step 1");
        assert_eq!(plan[1].status, StepStatus::Active);
        let entries = acp(&json!({"sessionUpdate": "plan", "entries": [{"content": "Look", "status": "pending"}, {"content": ""}]}));
        assert_eq!(entries.len(), 1);
        assert!(is_todo_tool("write_todos") && !is_todo_tool("Write"));
    }
}
