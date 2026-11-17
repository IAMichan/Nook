//! The plan Nook keeps while it works through a request of several steps (`update_plan`), shown as a live checklist
//! above its answer: the same checklist an agent session shows. Port of the Mac's `ChatTools.planTool` and
//! `RunTaskStep`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// The tool's name, the one Codex and the Mac use.
pub const TOOL: &str = "update_plan";

pub const DESCRIPTION: &str = "Shows your step-by-step plan in chat as a live checklist above your answer. Use it for a request that takes several steps (three or more tool calls, research across several sources, or a task with distinct parts): call it first with every step as pending and the first as in_progress, call it again with the whole list each time a step finishes, and once more with every step completed before you answer. Exactly one step is in_progress while you work. Skip it for a simple question or a single action. Write each step as a short line in the user's language. Do not repeat the plan in your answer.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StepStatus {
    #[default]
    Pending,
    Active,
    Done,
    /// Dropped: the step will not be done.
    Cancelled,
}

impl StepStatus {
    /// The status an agent or the brain wrote; a value Nook does not know reads as still to do.
    pub fn parse(raw: &str) -> Self {
        match raw {
            "completed" | "done" => Self::Done,
            "in_progress" | "inProgress" | "running" | "active" => Self::Active,
            "cancelled" | "canceled" => Self::Cancelled,
            _ => Self::Pending,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskStep {
    pub text: String,
    pub status: StepStatus,
}

pub fn schema() -> Value {
    json!({"type": "object", "properties": {
        "steps": {"type": "array", "description": "The whole plan, in order.", "items": {"type": "object", "properties": {
            "step": {"type": "string", "description": "What this step does, in a few words."},
            "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}
        }, "required": ["step", "status"]}}
    }, "required": ["steps"]})
}

/// The steps of an `update_plan` call; `None` when it holds none. Unknown statuses read as pending.
pub fn parse(input: &Value) -> Option<Vec<TaskStep>> {
    let steps: Vec<TaskStep> = input["steps"]
        .as_array()?
        .iter()
        .filter_map(|entry| {
            let text = entry["step"].as_str().unwrap_or("").trim();
            (!text.is_empty()).then(|| TaskStep { text: text.into(), status: StepStatus::parse(entry["status"].as_str().unwrap_or("")) })
        })
        .collect();
    (!steps.is_empty()).then_some(steps)
}

/// Once the answer stops, nothing runs any more: a step the brain left in progress reads as not done, not spinning.
pub fn settled(steps: &[TaskStep]) -> Vec<TaskStep> {
    steps
        .iter()
        .map(|s| TaskStep { text: s.text.clone(), status: if s.status == StepStatus::Active { StepStatus::Pending } else { s.status } })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_call_becomes_steps() {
        let steps = parse(&json!({"steps": [
            {"step": "Agenda lezen", "status": "completed"},
            {"step": " Mail van Henk zoeken ", "status": "in_progress"},
            {"step": "", "status": "pending"},
            {"step": "Antwoord schrijven", "status": "later"}
        ]}))
        .unwrap();
        assert_eq!(steps.len(), 3, "an empty step is left out");
        assert_eq!(steps[0].status, StepStatus::Done);
        assert_eq!(steps[1], TaskStep { text: "Mail van Henk zoeken".into(), status: StepStatus::Active });
        assert_eq!(steps[2].status, StepStatus::Pending, "an unknown status is still to do");
        assert!(parse(&json!({"steps": []})).is_none() && parse(&json!({})).is_none());
    }

    #[test]
    fn a_finished_answer_spins_nothing() {
        let steps =
            vec![TaskStep { text: "a".into(), status: StepStatus::Active }, TaskStep { text: "b".into(), status: StepStatus::Done }];
        let settled = settled(&steps);
        assert_eq!(settled[0].status, StepStatus::Pending);
        assert_eq!(settled[1].status, StepStatus::Done);
        assert_eq!(serde_json::to_value(&steps[0]).unwrap(), json!({"text": "a", "status": "active"}));
    }
}
