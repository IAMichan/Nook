//! Open punten: beloftes en taken die Nook bijhoudt (lokale database).

use chrono::{DateTime, Local, Utc};
use nook_core::brain::LoopTool;
use serde_json::{json, Value};

use super::{text, ToolCtx, ToolSource};

pub struct Loops;

#[async_trait::async_trait]
impl ToolSource for Loops {
    fn id(&self) -> &'static str {
        "loops"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let store = ctx.store.clone();
        vec![
            LoopTool::read(
                "list_open_loops",
                "Lists the user's open loops: promises and tasks Nook keeps track of, with their id.",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let store = store.clone();
                    async move {
                        let list = store.open_loops();
                        if list.is_empty() {
                            return Ok("No open loops.".to_string());
                        }
                        Ok(list
                            .iter()
                            .map(|l| {
                                let due = l
                                    .due
                                    .map(|d| format!(" (due {})", d.with_timezone(&Local).format("%Y-%m-%d %H:%M")))
                                    .unwrap_or_default();
                                format!("- {} [id {}]{due}", l.title, &l.id[..8.min(l.id.len())])
                            })
                            .collect::<Vec<_>>()
                            .join("\n"))
                    }
                },
            ),
            LoopTool::action(
                "add_open_loop",
                "Adds an open loop (a promise or task the user wants to keep track of).",
                json!({"type": "object", "properties": {
                    "title": {"type": "string", "description": "Short description of the task."},
                    "due": {"type": "string", "description": "Optional deadline, ISO 8601 with timezone offset."}
                }, "required": ["title"]}),
            ),
            LoopTool::action(
                "complete_open_loop",
                "Marks an open loop as done, by id (or the start of the id) or exact title.",
                json!({"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}),
            ),
        ]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let loops = ctx.store.open_loops();
        (!loops.is_empty()).then(|| {
            let mut lines = vec!["Open loops:".to_string()];
            lines.extend(loops.iter().take(10).map(|l| format!("- {}", l.title)));
            lines.join("\n")
        })
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "add_open_loop" => Some(format!("Open punt: {}", text(input, "title"))),
            "complete_open_loop" => Some(format!("Afvinken: {}", text(input, "id"))),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            "add_open_loop" => {
                let due = DateTime::parse_from_rfc3339(&text(input, "due")).ok().map(|d| d.with_timezone(&Utc));
                let lp = ctx.store.add_loop(&text(input, "title"), "chat", due);
                Some(Ok(format!("Toegevoegd: {} [id {}]", lp.title, &lp.id[..8.min(lp.id.len())])))
            }
            "complete_open_loop" => Some(
                ctx.store
                    .complete_loop_matching(&text(input, "id"))
                    .map(|l| format!("Afgevinkt: {}", l.title))
                    .ok_or_else(|| "Dat open punt bestaat niet (meer).".into()),
            ),
            _ => None,
        }
    }
}
