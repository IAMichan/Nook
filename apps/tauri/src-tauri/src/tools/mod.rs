//! Nooks tools voor het brein, als een register van bronnen. Elke bron (open punten, geheugen, web, agenda,
//! GitHub, …) levert zijn eigen tools, zijn stuk context bij elke vraag, en voert zijn eigen acties uit.
//! Lees-tools draaien in de loop (via het grootboek, zodat de chat per bron ziet wat er opgezocht is);
//! acties alleen in [`execute`], na de klik op Uitvoeren.
//!
//! Een nieuwe bron: een module met een type dat [`ToolSource`] implementeert, en één regel in [`sources`].
//! Een bron die niet in de vaste catalogus staat (`nook_core::brain::sources`), geeft een [`ToolSource::descriptor`].
//! Wil een tool zelf een bron onder het antwoord noemen, dan zet hij een regel van
//! `nook_core::brain::retrieval::reference_line` in zijn uitvoer; een https-link in een regel werkt ook.

mod calls;
mod charts;
mod clipboard;
mod connectors;
mod files;
mod loops;
mod mail;
mod memory;
mod screen;
mod system;
mod web;

use std::sync::Arc;

use chrono::Local;
use nook_core::brain::sources::{self, SourceDescriptor, SourceScope};
use nook_core::brain::{LoopTool, ToolKind};
use nook_core::settings::Settings;
use nook_core::store::NookStore;
use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::state::AppState;

pub use mail::{open_mail, send_mail};
pub use memory::rejected as memory_rejected;

/// Het antwoord waar grafieken en mailconcepten van tools heen gaan.
#[derive(Clone, Debug)]
pub struct Reply {
    pub nook_id: String,
    pub message_id: String,
}

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
    /// Welke bronnen deze vraag mag gebruiken (bronkiezer, de vraag zelf en "alleen op dit apparaat").
    pub scope: SourceScope,
    /// Het antwoord dat nu geschreven wordt, als er een vraag loopt.
    pub reply: Option<Reply>,
}

impl ToolCtx {
    pub fn new(app: &AppHandle, request: &str) -> Self {
        let state = app.state::<AppState>();
        let settings = state.settings();
        let scope = SourceScope::default().keeping_local(&settings.private_sources());
        Self { app: app.clone(), store: state.store.clone(), settings, request: request.into(), nook: None, scope, reply: None }
    }

    pub fn in_nook(mut self, nook: &str) -> Self {
        self.nook = Some(nook.to_string());
        self
    }

    pub fn with_scope(mut self, scope: SourceScope) -> Self {
        self.scope = scope.keeping_local(&self.settings.private_sources());
        self
    }

    pub fn for_reply(mut self, nook_id: &str, message_id: &str) -> Self {
        self.reply = Some(Reply { nook_id: nook_id.into(), message_id: message_id.into() });
        self
    }
}

#[async_trait::async_trait]
pub trait ToolSource: Send + Sync {
    /// Korte id, gelijk aan de bron-id's op de Mac (`calendar`, `web`, `memory`, `github`, …).
    fn id(&self) -> &'static str;
    /// De tools van deze bron voor deze vraag. Een bron die niet gekoppeld is, geeft er geen.
    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool>;
    /// Een stuk context dat bij elke vraag meegaat ("Calendar", "Open loops", …).
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
    /// Naam en soort koppeling, voor een bron die niet in de vaste catalogus staat (een MCP-server, een eigen bron).
    fn descriptor(&self) -> Option<SourceDescriptor> {
        None
    }
    /// Hoe mensen naar deze bron verwijzen en bij welke vragen hij hoort (reguliere expressies), voor een nieuwe bron.
    fn aliases(&self) -> &'static [&'static str] {
        &[]
    }
    fn intents(&self) -> &'static [&'static str] {
        &[]
    }
    /// Waarom deze bron nu niet gelezen kan worden (geen toegang, uitgezet), als de gebruiker hem wel heeft.
    fn unavailable(&self, _ctx: &ToolCtx) -> Option<String> {
        None
    }
    /// Leest het resultaat van een uitgevoerde actie terug: ja = bevestigd, nee = niet gevonden, niets = kan niet.
    async fn verify(&self, _ctx: &ToolCtx, _tool: &str, _input: &Value, _result: &str) -> Option<bool> {
        None
    }
    /// Een echte bron (die de bronkiezer kan uitzetten). Algemene tools (grafiek, mailconcept, link openen) niet.
    fn is_source(&self) -> bool {
        true
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
        Box::new(memory::Memory),
        Box::new(web::Web),
        Box::new(charts::Charts),
        Box::new(mail::Mail),
        Box::new(system::System),
        Box::new(screen::Screen),
        Box::new(files::Files),
        Box::new(clipboard::Clipboard),
        Box::new(calls::Calls),
    ]
}

/// Bronnen die het actieve brein niet mag zien (alleen-lokaal bij een extern brein) of die deze vraag uitsluit, vallen af.
fn allowed(ctx: &ToolCtx) -> Vec<Box<dyn ToolSource>> {
    let private = ctx.settings.private_sources();
    sources().into_iter().filter(|s| !s.is_source() || (!private.contains(s.id()) && ctx.scope.allows(s.id()))).collect()
}

/// De tools van één bron, met hun bron erbij en bekend bij de catalogus.
fn tools_of(source: &dyn ToolSource, ctx: &ToolCtx) -> Vec<LoopTool> {
    let list = source.tools(ctx);
    if !source.is_source() {
        return list;
    }
    if let Some(descriptor) = source.descriptor() {
        let names: Vec<String> = list.iter().map(|t| t.name.clone()).collect();
        sources::register(descriptor, &names, source.aliases(), source.intents());
    } else {
        sources::register_tools(source.id(), &list.iter().map(|t| t.name.clone()).collect::<Vec<_>>());
    }
    list.into_iter()
        .map(|mut t| {
            t.source.get_or_insert_with(|| source.id().to_string());
            t
        })
        .collect()
}

pub fn tools(ctx: &ToolCtx) -> Vec<LoopTool> {
    allowed(ctx).iter().flat_map(|s| tools_of(s.as_ref(), ctx)).filter(|t| ctx.scope.allows_tool(&t.name)).collect()
}

/// Alle tools, ook van bronnen die deze vraag niet mag gebruiken (voor de plankaart en het controleren bij uitvoeren).
pub fn all_tools(ctx: &ToolCtx) -> Vec<LoopTool> {
    sources().iter().flat_map(|s| tools_of(s.as_ref(), ctx)).collect()
}

/// De bronnen die nu gelezen kunnen worden: die met minstens één tool.
pub fn active(tools: &[LoopTool]) -> std::collections::HashSet<String> {
    let mut set: std::collections::HashSet<String> = tools.iter().filter_map(|t| t.source.clone()).collect();
    set.insert(sources::LOOPS.into());
    set
}

/// Bronnen die de gebruiker heeft maar die nu niet gelezen kunnen worden, met de reden.
pub fn unreachable(ctx: &ToolCtx) -> Vec<(String, String)> {
    sources().iter().filter(|s| s.is_source()).filter_map(|s| s.unavailable(ctx).map(|r| (s.id().to_string(), r))).collect()
}

/// "Now" en de context van alle toegestane bronnen.
#[allow(dead_code)]
pub async fn context(ctx: &ToolCtx) -> String {
    context_titled(ctx).await.0
}

/// De context, met de namen van de bronnen die er iets aan bijdroegen (voor de bronnenregel onder het antwoord).
pub async fn context_titled(ctx: &ToolCtx) -> (String, Vec<String>) {
    let mut titles = vec![];
    let now = Local::now();
    let mut parts = vec![format!("Now: {} ({})", nook_core::brain::dates::long(&now), now.format("%Y-%m-%d %:z"))];
    if ctx.scope.is_restricted() || !ctx.scope.focus.is_empty() {
        let mut lines = vec!["Sources for this question:".to_string(), format!("- Choice: {}", ctx.scope.label())];
        let blocked: Vec<String> = sources::all().into_iter().filter(|d| !ctx.scope.allows(&d.id)).map(|d| d.title).collect();
        if !blocked.is_empty() {
            lines.push(format!("- Do not use (user preference): {}", blocked.join(", ")));
        }
        if !ctx.scope.focus.is_empty() {
            let mut focus: Vec<String> = ctx.scope.focus.iter().map(|f| sources::title(f)).collect();
            focus.sort();
            lines.push(format!("- Specifically requested by user, prioritize: {}", focus.join(", ")));
        }
        parts.push(lines.join("\n"));
    }
    for source in allowed(ctx) {
        if let Some(part) = source.context(ctx).await.filter(|p| !p.trim().is_empty()) {
            parts.push(part);
            if source.is_source() {
                titles.push(sources::title(source.id()));
            }
        }
    }
    (parts.join("\n\n"), titles)
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
    Err(format!("{tool} is nu niet beschikbaar (koppeling uit of niet ingesteld)."))
}

pub async fn verify(ctx: &ToolCtx, tool: &str, input: &Value, result: &str) -> Option<bool> {
    for source in sources() {
        if let Some(found) = source.verify(ctx, tool, input, result).await {
            return Some(found);
        }
    }
    None
}

/// Of een tool een actie is (en dus pas na Uitvoeren draait).
pub fn is_action(tool: &LoopTool) -> bool {
    tool.kind == ToolKind::Action
}

/// Een tekstveld uit de invoer van een tool, getrimd.
pub fn text(input: &Value, key: &str) -> String {
    input.get(key).and_then(|v| v.as_str()).map(str::trim).unwrap_or("").to_string()
}

/// De geïnstalleerde app die met deze naam bedoeld is (ook met een typefout), via de platformlaag.
pub fn find_app(app: &AppHandle, name: &str) -> Option<String> {
    let services = app.try_state::<crate::services::Services>()?;
    let names: Vec<String> = services.platform.system.installed_apps().into_iter().map(|a| a.name).collect();
    nook_core::brain::fuzzy::best(name, &names)
}
