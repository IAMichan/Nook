//! `update_plan`: the plan Nook keeps while it works through a request of several steps, as a live checklist above the
//! answer that is being written (`brain::task_steps`).

use nook_core::brain::task_steps;
use nook_core::brain::LoopTool;
use serde_json::Value;

use super::{ToolCtx, ToolSource};
use crate::commands::chat;

pub struct Plan;

#[async_trait::async_trait]
impl ToolSource for Plan {
    fn id(&self) -> &'static str {
        "plan"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let (app, reply) = (ctx.app.clone(), ctx.reply.clone());
        vec![LoopTool::read(task_steps::TOOL, task_steps::DESCRIPTION, task_steps::schema(), move |input: Value| {
            let (app, reply) = (app.clone(), reply.clone());
            async move {
                let steps =
                    task_steps::parse(&input).ok_or_else(|| nook_core::NookError::new("No steps: provide steps with step and status."))?;
                // Only an answer being written has a checklist; outside a chat answer there is nothing to show it on.
                if reply.is_some() {
                    chat::attach(&app, reply.as_ref(), move |m| m.tasks = steps);
                }
                Ok(format!(
                    "The plan is displayed in chat. Keep it current with {} as you work; do not repeat it in your answer.",
                    task_steps::TOOL
                ))
            }
        })]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == task_steps::TOOL).then(|| format!("Plan: {} steps", input["steps"].as_array().map_or(0, Vec::len)))
    }
}
