//! Nooks tools voor het brein, als een register van bronnen. Elke bron (open punten, geheugen, web, agenda,
//! GitHub, …) levert zijn eigen tools, zijn stuk context bij elke vraag, en voert zijn eigen acties uit.
//! Lees-tools draaien in de loop; acties alleen in [`execute`], na de klik op Uitvoeren.
//!
//! Een nieuwe bron: een module met een type dat [`ToolSource`] implementeert, en één regel in [`sources`].

mod calls;
mod clipboard;
mod connectors;
mod files;
mod loops;
mod screen;
mod system;

use std::sync::Arc;

use chrono::Local;
use nook_core::brain::LoopTool;
use nook_core::settings::Settings;
use nook_core::store::NookStore;
use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::state::AppState;

/// Wat een bron nodig heeft om tools te bouwen en acties uit te voeren.
#[derive(Clone)]
pub struct ToolCtx {
    pub app: AppHandle,
    pub store: Arc<NookStore>,
    pub settings: Settings,
    /// De vraag waar het om gaat (leeg bij uitvoeren), voor bronnen die hun context erop afstemmen.
    #[allow(dead_code)]
    pub request: String,
    /// De Nook (chat) waarin gevraagd of uitgevoerd wordt, voor de accounts die die chat mag gebruiken.
    pub nook: Option<String>,
}

impl ToolCtx {
    pub fn new(app: &AppHandle, request: &str) -> Self {
        let state = app.state::<AppState>();
        Self { app: app.clone(), store: state.store.clone(), settings: state.settings(), request: request.into(), nook: None }
    }

    pub fn in_nook(mut self, nook: &str) -> Self {
        self.nook = Some(nook.to_string());
        self
    }
}

#[async_trait::async_trait]
pub trait ToolSource: Send + Sync {
    /// Korte id, gelijk aan de bron-id's op de Mac (`calendar`, `web`, `memory`, `github`, …).
    fn id(&self) -> &'static str;
    /// De tools van deze bron voor deze vraag. Een bron die niet gekoppeld is, geeft er geen.
    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool>;
    /// Een stuk context dat bij elke vraag meegaat ("What Nook remembers", "Calendar", …).
    async fn context(&self, _ctx: &ToolCtx) -> Option<String> {
        None
    }
    /// Een leesbare samenvatting van een actie voor de plankaart, als deze bron de tool kent.
    fn summarize(&self, _tool: &str, _input: &Value) -> Option<String> {
        None
    }
    /// Voert een goedgekeurde actie uit, als deze bron de tool kent.
    async fn execute(&self, _ctx: &ToolCtx, _tool: &str, _input: &Value) -> Option<Result<String, String>> {
        None
    }
}

/// Alle bronnen, in de volgorde waarin hun context in de prompt komt.
pub fn sources() -> Vec<Box<dyn ToolSource>> {
    vec![
        Box::new(loops::Loops),
        Box::new(connectors::Calendar),
        Box::new(connectors::Hub("icalfeeds")),
        Box::new(connectors::Hub("calcom")),
        Box::new(connectors::Hub("github")),
        Box::new(connectors::Hub("vercel")),
        Box::new(connectors::Hub("stripe")),
        Box::new(connectors::Hub("notion")),
        Box::new(connectors::Hub("n8n")),
        Box::new(connectors::Hub("resend")),
        Box::new(connectors::Hub("customsources")),
        Box::new(connectors::Hub("whatsapp")),
        Box::new(connectors::Mcp),
        Box::new(connectors::Sources),
        Box::new(system::System),
        Box::new(screen::Screen),
        Box::new(files::Files),
        Box::new(clipboard::Clipboard),
        Box::new(calls::Calls),
    ]
}

/// Bronnen die het actieve brein niet mag zien (alleen-lokaal bij een extern brein) vallen af.
fn allowed(ctx: &ToolCtx) -> Vec<Box<dyn ToolSource>> {
    let private = ctx.settings.private_sources();
    sources().into_iter().filter(|s| !private.contains(s.id())).collect()
}

pub fn tools(ctx: &ToolCtx) -> Vec<LoopTool> {
    allowed(ctx).iter().flat_map(|s| s.tools(ctx)).collect()
}

/// "Nu" en de context van alle toegestane bronnen.
pub async fn context(ctx: &ToolCtx) -> String {
    let now = Local::now();
    let mut parts = vec![format!("Now: {} ({})", now.format("%A %Y-%m-%d %H:%M"), now.format("%:z"))];
    for source in allowed(ctx) {
        if let Some(part) = source.context(ctx).await.filter(|p| !p.trim().is_empty()) {
            parts.push(part);
        }
    }
    parts.join("\n\n")
}

pub fn summarize(tool: &str, input: &Value) -> String {
    sources().iter().find_map(|s| s.summarize(tool, input)).unwrap_or_else(|| tool.replace('_', " "))
}

pub async fn execute(ctx: &ToolCtx, tool: &str, input: &Value) -> Result<String, String> {
    for source in sources() {
        if let Some(result) = source.execute(ctx, tool, input).await {
            return result;
        }
    }
    Err(format!("Onbekende actie {tool}."))
}

/// Een tekstveld uit de invoer van een tool, getrimd.
pub fn text(input: &Value, key: &str) -> String {
    input.get(key).and_then(|v| v.as_str()).map(str::trim).unwrap_or("").to_string()
}
