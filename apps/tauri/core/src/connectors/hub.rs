//! Het centrum van alle koppelingen (`ConnectorHub` op de Mac): ververst elke bron op de achtergrond op zijn eigen
//! tempo, geeft het brein context uit de cache (nooit wachten op het netwerk) en de tools van de actieve bronnen, en
//! heeft de tools die over bronnen heen kijken: `check_availability`, `list_events`, `list_sources`.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{json, Value};

use super::agenda::{self, AgendaEntry, AgendaResult};
use super::{dates, CResult, ConnectorError, ConnectorStatus, ConnectorStore, Http};
use crate::brain::LoopTool;
use crate::secrets::SecretStore;

/// Wat elke koppeling deelt: de kluis, de instellingen zonder geheimen en HTTP.
pub struct Env {
    pub secrets: Arc<dyn SecretStore>,
    pub store: Arc<ConnectorStore>,
    pub http: Http,
}

impl Env {
    pub fn new(secrets: Arc<dyn SecretStore>, store: Arc<ConnectorStore>) -> Arc<Self> {
        Arc::new(Self { secrets, store, http: Http::new() })
    }

    /// Een opgeschoonde waarde uit de kluis, of `None` als hij leeg is.
    pub fn secret(&self, account: &str) -> Option<String> {
        self.secrets.read(account).map(|v| super::clean(&v)).filter(|v| !v.is_empty())
    }
}

/// Wat een chat mag: de accounts die hij niet mag gebruiken.
#[derive(Debug, Clone, Default)]
pub struct Scope {
    pub excluded_accounts: BTreeSet<String>,
}

/// Een bron die Nook context geeft. `context_lines` komt uit de cache van de laatste [`Connector::refresh`].
#[async_trait::async_trait]
pub trait Connector: Send + Sync {
    /// Vaste id, gelijk aan de Mac (`github`, `icalfeeds`, `mcp.linear`, …).
    fn id(&self) -> String;
    fn title(&self) -> String;
    /// Alle benodigde sleutels zijn er (los van aan/uit).
    fn configured(&self) -> bool;
    fn active(&self) -> bool;
    fn status(&self) -> ConnectorStatus;
    /// Minimale tijd tussen twee verversingen, in seconden.
    fn refresh_interval(&self) -> u64 {
        300
    }
    async fn refresh(&self);
    fn context_lines(&self) -> Vec<String> {
        vec![]
    }
    /// Lees-tools en acties voor het brein (alleen als de bron actief is).
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        vec![]
    }
    /// Een leesbare samenvatting van een actie voor de plankaart.
    fn summarize(&self, _tool: &str, _input: &Value) -> Option<String> {
        None
    }
    /// Voert een goedgekeurde actie uit, als deze bron hem kent.
    async fn execute(&self, _tool: &str, _input: &Value) -> Option<CResult<String>> {
        None
    }
    /// Welke agenda's deze bron voor `check_availability` laat zien ("Werk (ICS)").
    fn agenda_names(&self) -> Vec<String> {
        vec![]
    }
    /// Vers opgehaalde afspraken in het tijdvak, als dit een agenda is.
    async fn agenda(&self, _from: DateTime<Utc>, _to: DateTime<Utc>) -> Option<CResult<AgendaResult>> {
        None
    }
    /// De komende afspraken uit de cache, voor de context.
    fn cached_agenda(&self) -> Vec<AgendaEntry> {
        vec![]
    }
}

/// Hoe de interface een koppeling toont.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectorInfo {
    pub id: String,
    pub title: String,
    pub configured: bool,
    pub on: bool,
    pub status: ConnectorStatus,
}

type Listener = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
pub struct ConnectorHub {
    connectors: RwLock<Vec<Arc<dyn Connector>>>,
    last: Mutex<HashMap<String, Instant>>,
    running: Mutex<HashSet<String>>,
    revision: AtomicU64,
    listener: RwLock<Option<Listener>>,
    store: RwLock<Option<Arc<ConnectorStore>>>,
    /// Met welke instelling elke MCP-koppeling gemaakt is, zodat alleen een gewijzigde opnieuw start.
    mcp: Mutex<HashMap<String, super::mcp::McpServerConfig>>,
}

impl ConnectorHub {
    pub fn new(store: Arc<ConnectorStore>) -> Arc<Self> {
        let hub = Arc::new(Self::default());
        *hub.store.write().unwrap_or_else(|e| e.into_inner()) = Some(store);
        hub
    }

    /// Wordt aangeroepen na elke verversing (de app stuurt dan een event naar de interface).
    pub fn on_change(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.listener.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(f));
    }

    pub fn changed(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
        let listener = self.listener.read().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(f) = listener {
            f();
        }
    }

    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }

    pub fn register(&self, connector: Arc<dyn Connector>) {
        let mut list = self.connectors.write().unwrap_or_else(|e| e.into_inner());
        list.retain(|c| c.id() != connector.id());
        list.push(connector);
    }

    pub fn mcp_config(&self, id: &str) -> Option<super::mcp::McpServerConfig> {
        self.mcp.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    pub fn set_mcp_config(&self, id: &str, config: super::mcp::McpServerConfig) {
        self.mcp.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_string(), config);
    }

    pub fn unregister(&self, id: &str) {
        self.mcp.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        self.connectors.write().unwrap_or_else(|e| e.into_inner()).retain(|c| c.id() != id);
        self.last.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        self.changed();
    }

    pub fn all(&self) -> Vec<Arc<dyn Connector>> {
        self.connectors.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn Connector>> {
        self.all().into_iter().find(|c| c.id() == id)
    }

    pub fn active(&self) -> Vec<Arc<dyn Connector>> {
        self.all().into_iter().filter(|c| c.active()).collect()
    }

    pub fn info(&self) -> Vec<ConnectorInfo> {
        let store = self.store.read().unwrap_or_else(|e| e.into_inner()).clone();
        self.all()
            .iter()
            .map(|c| ConnectorInfo {
                id: c.id(),
                title: c.title(),
                configured: c.configured(),
                on: store.as_ref().map(|s| s.is_on(&c.id())).unwrap_or(true),
                status: c.status(),
            })
            .collect()
    }

    /// Ververst elke 15 seconden de actieve bronnen waarvan de tijd om is.
    pub fn start(self: &Arc<Self>) {
        let hub = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                let Some(hub) = hub.upgrade() else { break };
                hub.tick();
                drop(hub);
                tokio::time::sleep(Duration::from_secs(15)).await;
            }
        });
    }

    fn tick(self: &Arc<Self>) {
        let now = Instant::now();
        for c in self.active() {
            let due = self
                .last
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&c.id())
                .map(|t| now.duration_since(*t).as_secs() >= c.refresh_interval())
                .unwrap_or(true);
            if due {
                self.refresh(&c.id());
            }
        }
    }

    /// Ververst één bron op de achtergrond (bv. na het bewaren van een sleutel).
    pub fn refresh(self: &Arc<Self>, id: &str) {
        let hub = self.clone();
        let id = id.to_string();
        tokio::spawn(async move { hub.refresh_now(&id).await });
    }

    pub async fn refresh_now(&self, id: &str) {
        let Some(c) = self.get(id) else { return };
        if !self.running.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_string()) {
            return;
        }
        self.last.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_string(), Instant::now());
        c.refresh().await;
        self.running.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        self.changed();
    }

    pub fn refresh_all(self: &Arc<Self>) {
        for c in self.all() {
            self.refresh(&c.id());
        }
    }

    /// De tools van alle actieve bronnen die `allowed` toelaat.
    pub fn tools(&self, scope: &Scope, allowed: impl Fn(&str) -> bool) -> Vec<LoopTool> {
        self.active().into_iter().filter(|c| allowed(&c.id())).flat_map(|c| c.tools(scope)).collect()
    }

    /// De bron die een tool levert (voor uitvoeren en samenvatten).
    pub fn owner(&self, tool: &str) -> Option<Arc<dyn Connector>> {
        let scope = Scope::default();
        self.all().into_iter().find(|c| c.clone().tools(&scope).iter().any(|t| t.name == tool))
    }

    // Over bronnen heen

    /// De agenda's die meedoen, gefilterd op wat dit brein mag zien.
    fn agendas(&self, allowed: &(dyn Fn(&str) -> bool + Send + Sync)) -> Vec<Arc<dyn Connector>> {
        self.all().into_iter().filter(|c| is_agenda(c.as_ref()) && allowed(&c.id())).collect()
    }

    /// Prompt-regel: welke agenda's `check_availability` bekijkt.
    pub fn coverage_line(&self, allowed: &(dyn Fn(&str) -> bool + Send + Sync)) -> Option<String> {
        let names: Vec<String> = self.agendas(allowed).iter().filter(|c| c.active()).flat_map(|c| c.agenda_names()).collect();
        (!names.is_empty()).then(|| format!("Calendars checked by check_availability: {}.", names.join("; ")))
    }

    /// Alle afspraken uit alle actieve agenda's in het tijdvak, met wat er niet gelezen kon worden.
    pub async fn agenda(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        allowed: &(dyn Fn(&str) -> bool + Send + Sync),
    ) -> (Vec<String>, Vec<AgendaEntry>, Vec<String>, Vec<String>, bool) {
        let mut checked = vec![];
        let mut entries = vec![];
        let mut problems = vec![];
        let agendas = self.agendas(allowed);
        for c in agendas.iter().filter(|c| c.active()) {
            match c.agenda(from, to).await {
                Some(Ok(result)) => {
                    checked.extend(c.agenda_names());
                    entries.extend(result.entries);
                    problems.extend(result.problems);
                }
                Some(Err(e)) => problems.push(format!("{}: {}", c.title(), e.message)),
                None => {}
            }
        }
        let skipped = agendas.iter().filter(|c| !c.active()).map(|c| c.title()).collect();
        let has_feeds = agendas.iter().any(|c| c.id() == "icalfeeds" && c.active());
        entries.sort_by_key(|e| e.start);
        (checked, entries, problems, skipped, has_feeds)
    }

    /// Hoe het er nu voor staat, voor `list_sources`.
    pub fn overview(&self) -> String {
        let all = self.all();
        let on: Vec<_> = all.iter().filter(|c| c.active()).collect();
        let off: Vec<String> = all.iter().filter(|c| !c.active()).map(|c| c.title()).collect();
        let mut lines = vec![];
        if !on.is_empty() {
            lines.push("Enabled:".to_string());
            for c in on {
                let headline = c.status().headline;
                lines.push(if headline.is_empty() { format!("- {}", c.title()) } else { format!("- {}: {headline}", c.title()) });
            }
        }
        if !off.is_empty() {
            lines.push(format!("Not yet connected or disabled: {}.", off.join(", ")));
        }
        lines.push("You can connect services in Settings › Accounts & connections: a calendar via its ICS URL (Google Calendar, Outlook, iCloud…) under Other calendars; almost any other app or service with a web API under Custom sources; any MCP server under MCP servers.".into());
        lines.push("Ask the user which app they mean if it is not listed here, and explain the easiest way to connect it.".into());
        lines.join("\n")
    }

    /// `check_availability` en `list_events`: over alle agenda's heen.
    pub fn calendar_tools(self: &Arc<Self>, allowed: Arc<dyn Fn(&str) -> bool + Send + Sync>) -> Vec<LoopTool> {
        let (hub1, hub2) = (self.clone(), self.clone());
        let (allowed1, allowed2) = (allowed.clone(), allowed);
        vec![
            LoopTool::read(
                "check_availability",
                "Checks ALL calendars of the user simultaneously (calendars via an ICS URL such as Google, Outlook or iCloud, and Cal.com) and returns busy intervals and free time per day. Use this IMMEDIATELY for any question like \"am I available on October 13?\", \"when do I have time?\", or \"does Tuesday 2 PM work?\", even if the period is mentioned in context. Provide from and to (ISO 8601); for a single full day, from as a date (e.g. 2027-10-13) suffices. Mention in your response which calendars were checked.",
                json!({"type": "object", "properties": {
                    "from": {"type": "string", "description": "Start, ISO 8601. Date only (2027-10-13) covers the entire day."},
                    "to": {"type": "string", "description": "End, ISO 8601. Omit for a single full day. At most 14 days after from."}
                }, "required": ["from"]}),
                move |input| {
                    let hub = hub1.clone();
                    let allowed = allowed1.clone();
                    async move {
                        let (from, to) = agenda::period(&input)?;
                        let (checked, entries, problems, skipped, has_feeds) = hub.agenda(from, to, &*allowed).await;
                        Ok(agenda::availability(from, to, &checked, &entries, &problems, &skipped, has_feeds))
                    }
                },
            ),
            LoopTool::read(
                "list_events",
                "Reads calendar events between two timestamps from all connected calendars. Use this to discover free time slots or check for schedule conflicts.",
                json!({"type": "object", "properties": {
                    "from": {"type": "string", "description": "Start, ISO 8601 with timezone."},
                    "to": {"type": "string", "description": "End, ISO 8601 with timezone."}
                }, "required": ["from", "to"]}),
                move |input| {
                    let hub = hub2.clone();
                    let allowed = allowed2.clone();
                    async move {
                        let (Some(from), Some(to)) = (dates::parse(super::text(&input, "from")), dates::parse(super::text(&input, "to"))) else {
                            return Err(ConnectorError::new("from and to must be ISO 8601 dates.").into());
                        };
                        let (checked, entries, problems, _, _) = hub.agenda(from, to, &*allowed).await;
                        let mut out = agenda::event_lines(&entries);
                        if !checked.is_empty() {
                            out.push_str(&format!("\nCalendars checked: {}.", checked.join("; ")));
                        }
                        if !problems.is_empty() {
                            out.push_str(&format!("\nCould not read: {}.", problems.join("; ")));
                        }
                        Ok(out)
                    }
                },
            ),
        ]
    }

    /// `list_sources`: welke bronnen Nook kent en hoe je de rest koppelt.
    pub fn sources_tool(self: &Arc<Self>) -> LoopTool {
        let hub3 = self.clone();
        LoopTool::read(
                "list_sources",
                "Shows which sources Nook currently knows (calendars, services, custom sources, MCP servers), which are active, and which are not yet connected. Use this when the user asks about an app or service with no data visible, so you can ask which app they use and explain how to connect it.",
                json!({"type": "object", "properties": {}, "required": []}),
                move |_| {
                    let hub = hub3.clone();
                    async move { Ok(hub.overview()) }
                },
            )
    }

    /// Context "Calendar": de komende zeven dagen uit alle agenda's die dit brein mag zien (uit de cache).
    pub fn calendar_context(&self, allowed: &(dyn Fn(&str) -> bool + Send + Sync)) -> Option<String> {
        let agendas: Vec<_> = self.agendas(allowed).into_iter().filter(|c| c.active()).collect();
        if agendas.is_empty() {
            return None;
        }
        let now = Utc::now();
        let mut entries: Vec<AgendaEntry> = agendas.iter().flat_map(|c| c.cached_agenda()).filter(|e| e.end > now).collect();
        entries.sort_by_key(|e| e.start);
        let names: Vec<String> = agendas.iter().flat_map(|c| c.agenda_names()).collect();
        let mut lines = vec![format!("Calendar ({}), today and the next seven days:", names.join(", "))];
        if entries.is_empty() {
            lines.push("- no events".into());
        }
        for e in entries.iter().take(40) {
            let place = if e.location.is_empty() { String::new() } else { format!(" | {}", e.location) };
            lines.push(format!("- {} | {} – {} | {}{place}", e.title, dates::iso(e.start), dates::iso(e.end), e.calendar));
        }
        if let Some(line) = self.coverage_line(allowed) {
            lines.push(line);
        }
        Some(lines.join("\n"))
    }
}

fn is_agenda(c: &dyn Connector) -> bool {
    matches!(c.id().as_str(), "icalfeeds" | "calcom")
}
