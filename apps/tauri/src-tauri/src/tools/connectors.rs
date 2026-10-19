//! De koppelingen als bronnen voor het brein. Elke koppeling in de hub (GitHub, Stripe, agenda's, eigen bronnen,
//! WhatsApp, MCP-servers) is hier één [`ToolSource`] met dezelfde id als op de Mac; de logica staat in
//! `nook_core::connectors`.

use std::collections::BTreeSet;
use std::sync::Arc;

use nook_core::brain::LoopTool;
use nook_core::connectors::accounts;
use nook_core::connectors::hub::{Connector, Scope};
use serde_json::{json, Value};
use tauri::Manager;

use super::{ToolCtx, ToolSource};
use crate::connectors::Connectors;

fn connectors(ctx: &ToolCtx) -> Option<tauri::State<'_, Connectors>> {
    ctx.app.try_state::<Connectors>()
}

/// Wat deze chat mag: de accounts die hij niet mag gebruiken.
fn scope(ctx: &ToolCtx, c: &Connectors) -> Scope {
    let excluded = ctx.nook.as_deref().map(|n| c.env.store.excluded_accounts(n)).unwrap_or_default();
    Scope { excluded_accounts: excluded }
}

/// De bronnen die dit brein mag zien (een extern brein ziet de bronnen "alleen lokaal" niet).
fn allowed(ctx: &ToolCtx) -> Arc<dyn Fn(&str) -> bool + Send + Sync> {
    let private: BTreeSet<String> = ctx.settings.private_sources();
    Arc::new(move |id: &str| !private.contains(id))
}

/// Een actie met een `account` dat deze chat niet mag, wordt geweigerd; met maar één toegestaan account wordt dat
/// ingevuld. Gecontroleerd bij het uitvoeren, ook als het plan eerder gemaakt is.
fn check_account(ctx: &ToolCtx, c: &Connectors, service: &str, input: &Value) -> Result<Value, String> {
    let all: Vec<_> = accounts::accounts(&c.env.store, service).into_iter().filter(|a| c.env.secret(&a.key("token")).is_some()).collect();
    if all.len() < 2 {
        return Ok(input.clone());
    }
    let excluded = scope(ctx, c).excluded_accounts;
    let allowed = accounts::allowed_names(&all, &excluded);
    let mut filled = input.clone();
    match input.get("account").and_then(Value::as_str).map(str::trim).filter(|a| !a.is_empty()) {
        Some(chosen) => {
            if let Some(account) = accounts::find(chosen, &all) {
                if excluded.contains(&account.id) {
                    return Err(format!("Deze chat mag het account \"{chosen}\" niet gebruiken (bronkiezer)."));
                }
            }
        }
        None if allowed.len() == 1 => filled["account"] = json!(allowed[0]),
        None => {}
    }
    Ok(filled)
}

/// Eén koppeling uit de hub.
pub struct Hub(pub &'static str);

#[async_trait::async_trait]
impl ToolSource for Hub {
    fn id(&self) -> &'static str {
        self.0
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(c) = connectors(ctx) else { return vec![] };
        match c.hub.get(self.0).filter(|c| c.active()) {
            Some(connector) => connector.tools(&scope(ctx, &c)),
            None => vec![],
        }
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let c = connectors(ctx)?;
        let connector = c.hub.get(self.0).filter(|c| c.active())?;
        let lines = connector.context_lines();
        (!lines.is_empty()).then(|| lines.join("\n"))
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        let app = crate::connectors::handle()?;
        let c = app.try_state::<Connectors>()?;
        c.hub.get(self.0)?.summarize(tool, input)
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        let c = connectors(ctx)?;
        let connector = c.hub.get(self.0)?;
        // Alleen acties van deze koppeling; die hebben allemaal een samenvatting.
        connector.summarize(tool, input)?;
        let input = match check_account(ctx, &c, self.0, input) {
            Ok(i) => i,
            Err(e) => return Some(Err(e)),
        };
        if !connector.active() {
            return Some(Err(format!("{} is nog niet gekoppeld of staat uit (Instellingen › Accounts & koppelingen).", connector.title())));
        }
        let result = connector.execute(tool, &input).await?;
        c.hub.refresh(self.0);
        Some(result.map_err(|e| e.message))
    }
}

/// De agenda's samen: `check_availability`, `list_events` en de context "Calendar" (komende afspraken).
pub struct Calendar;

#[async_trait::async_trait]
impl ToolSource for Calendar {
    fn id(&self) -> &'static str {
        "calendar"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        connectors(ctx).map(|c| c.hub.calendar_tools(allowed(ctx))).unwrap_or_default()
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let c = connectors(ctx)?;
        c.hub.calendar_context(&*allowed(ctx))
    }
}

/// `list_sources`: wat Nook kent en hoe je de rest koppelt.
pub struct Sources;

#[async_trait::async_trait]
impl ToolSource for Sources {
    fn id(&self) -> &'static str {
        "sources"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        connectors(ctx).map(|c| vec![c.hub.sources_tool()]).unwrap_or_default()
    }
}

/// Alle MCP-servers die de gebruiker toevoegde ("mcp.<server>").
pub struct Mcp;

impl Mcp {
    fn servers(ctx: &ToolCtx) -> Vec<Arc<dyn Connector>> {
        let Some(c) = connectors(ctx) else { return vec![] };
        let private = ctx.settings.private_sources();
        c.hub.all().into_iter().filter(|s| s.id().starts_with("mcp.") && !private.contains(&s.id())).collect()
    }
}

#[async_trait::async_trait]
impl ToolSource for Mcp {
    fn id(&self) -> &'static str {
        "mcp"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        Self::servers(ctx).into_iter().filter(|s| s.active()).flat_map(|s| s.tools(&Scope::default())).collect()
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        let app = crate::connectors::handle()?;
        let c = app.try_state::<Connectors>()?;
        c.hub.all().into_iter().filter(|s| s.id().starts_with("mcp.")).find_map(|s| s.summarize(tool, input))
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        for server in Self::servers(ctx) {
            if server.summarize(tool, input).is_some() {
                return server.execute(tool, input).await.map(|r| r.map_err(|e| e.message));
            }
        }
        None
    }
}
