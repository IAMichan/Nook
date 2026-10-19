//! Kleine systeemacties: een link openen. (Apps, volume en muziek komen via de platformlaag.)

use nook_core::brain::LoopTool;
use serde_json::{json, Value};
use tauri_plugin_opener::OpenerExt;

use super::{text, ToolCtx, ToolSource};

pub struct System;

#[async_trait::async_trait]
impl ToolSource for System {
    fn id(&self) -> &'static str {
        "system"
    }

    fn tools(&self, _ctx: &ToolCtx) -> Vec<LoopTool> {
        vec![LoopTool::action(
            "open_url",
            "Opens a web address in the user's browser.",
            json!({"type": "object", "properties": {"url": {"type": "string", "description": "https address"}}, "required": ["url"]}),
        )]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "open_url").then(|| format!("Open {}", text(input, "url")))
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        if tool != "open_url" {
            return None;
        }
        let url = text(input, "url");
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            return Some(Err("Alleen http- en https-adressen.".into()));
        }
        Some(ctx.app.opener().open_url(&url, None::<&str>).map(|_| format!("Geopend: {url}")).map_err(|e| e.to_string()))
    }
}
