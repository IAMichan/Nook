//! `show_chart`: een echte grafiek in de chat (staaf, lijn, vlak, taart, punten), bij het antwoord dat nu geschreven wordt.

use nook_core::brain::chart::ChatChart;
use nook_core::brain::LoopTool;
use serde_json::Value;

use super::{text, ToolCtx, ToolSource};
use crate::commands::chat;

pub struct Charts;

#[async_trait::async_trait]
impl ToolSource for Charts {
    fn id(&self) -> &'static str {
        "chart"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let (app, reply) = (ctx.app.clone(), ctx.reply.clone());
        vec![LoopTool::read(
            "show_chart",
            "Renders a chart in chat. ALWAYS use this when the user asks for a chart, diagram, plot, or visualization, and also proactively when numerical trends or category comparisons are clearer as a visual. Fetch data first using other tools or web search if necessary; use only genuine figures or user-provided data, never fabricate. Choose bar for comparisons, line or area for trends over time, pie for breakdown of a whole (max 6 slices), point for scatter plots. After rendering, state the main takeaway in one or two sentences; do not repeat all raw numbers.",
            ChatChart::schema(),
            move |input: Value| {
                let (app, reply) = (app.clone(), reply.clone());
                async move {
                    let chart = ChatChart::parse(&input)
                        .ok_or_else(|| nook_core::NookError::new("No usable data: provide series with points (label and value)."))?;
                    let title = chart.title.clone();
                    chat::attach(&app, reply.as_ref(), move |m| m.charts.push(chart));
                    Ok(format!("The chart \"{title}\" is now displayed in chat with your answer. Do not describe it again point by point."))
                }
            },
        )]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "show_chart").then(|| format!("Grafiek: {}", text(input, "title")))
    }
}
