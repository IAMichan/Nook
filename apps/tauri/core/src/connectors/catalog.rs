//! De bronnen die Nook kent (`SourceCatalog` op de Mac): id, titel, soort koppeling en welke tools erbij horen. Bronnen
//! die later bijkomen (MCP-servers) melden zich met [`register`], zodat hun tools ook de bronkiezer volgen.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

/// Hoe een bron gekoppeld is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    /// Op deze computer.
    BuiltIn,
    /// Inloggen bij de dienst zelf.
    Oauth,
    /// Een geplakte API-sleutel.
    ApiKey,
    /// Een eigen bron met web-API of webhook, of een MCP-server.
    Custom,
    Web,
    /// Nooks eigen gegevens.
    Nook,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDescriptor {
    pub id: String,
    pub title: String,
    pub kind: SourceKind,
}

const BUILT_IN: &[(&str, &str, SourceKind)] = &[
    ("calendar", "Agenda", SourceKind::BuiltIn),
    ("icalfeeds", "Andere agenda's", SourceKind::ApiKey),
    ("calcom", "Cal.com", SourceKind::ApiKey),
    ("reminders", "Herinneringen", SourceKind::BuiltIn),
    ("notes", "Notities", SourceKind::BuiltIn),
    ("messages", "Berichten", SourceKind::BuiltIn),
    ("whatsapp", "WhatsApp", SourceKind::BuiltIn),
    ("bear", "Bear", SourceKind::BuiltIn),
    ("callnotes", "Gesprekken", SourceKind::Nook),
    ("system", "Deze computer", SourceKind::BuiltIn),
    ("things", "Things", SourceKind::BuiltIn),
    ("loops", "Open punten", SourceKind::Nook),
    ("memory", "Geheugen", SourceKind::Nook),
    ("mail", "Mail", SourceKind::BuiltIn),
    ("browser", "Browser", SourceKind::BuiltIn),
    ("terminal", "Terminal", SourceKind::BuiltIn),
    ("files", "Bestanden", SourceKind::BuiltIn),
    ("contacts", "Contacten", SourceKind::BuiltIn),
    ("clipboard", "Klembord", SourceKind::BuiltIn),
    ("screen", "Scherm", SourceKind::BuiltIn),
    ("github", "GitHub", SourceKind::Oauth),
    ("vercel", "Vercel", SourceKind::ApiKey),
    ("stripe", "Stripe", SourceKind::ApiKey),
    ("notion", "Notion", SourceKind::ApiKey),
    ("n8n", "n8n", SourceKind::ApiKey),
    ("resend", "Resend", SourceKind::ApiKey),
    ("customsources", "Eigen bronnen", SourceKind::Custom),
    ("web", "Web", SourceKind::Web),
];

/// Bronnen met persoonlijke gegevens: de voorinstelling voor "alleen op deze computer" (Instellingen › Brein).
pub const PERSONAL: &[&str] = &[
    "calendar",
    "icalfeeds",
    "reminders",
    "notes",
    "messages",
    "whatsapp",
    "bear",
    "things",
    "loops",
    "mail",
    "callnotes",
    "browser",
    "files",
    "contacts",
    "clipboard",
    "screen",
    "memory",
];

/// Tools die bij een bron horen. Tools zonder bron (grafieken, app openen) mogen altijd.
const EXACT_TOOLS: &[(&str, &str)] = &[
    ("list_events", "calendar"),
    ("create_event", "calendar"),
    ("update_event", "calendar"),
    ("delete_event", "calendar"),
    ("check_availability", "calendar"),
    ("create_reminder", "reminders"),
    ("complete_reminder", "reminders"),
    ("delete_reminder", "reminders"),
    ("list_reminders", "reminders"),
    ("search_reminders", "reminders"),
    ("list_notes", "notes"),
    ("search_notes", "notes"),
    ("read_note", "notes"),
    ("create_note", "notes"),
    ("search_messages", "messages"),
    ("read_messages", "messages"),
    ("messages_open_chats", "messages"),
    ("search_whatsapp", "whatsapp"),
    ("read_whatsapp", "whatsapp"),
    ("whatsapp_open_chats", "whatsapp"),
    ("whatsapp_live", "whatsapp"),
    ("whatsapp_send", "whatsapp"),
    ("search_call_notes", "callnotes"),
    ("read_call_note", "callnotes"),
    ("mac_status", "system"),
    ("search_bear", "bear"),
    ("read_bear", "bear"),
    ("search_things", "things"),
    ("search_mail", "mail"),
    ("read_mail", "mail"),
    ("mail_unread", "mail"),
    ("inbox_mail", "mail"),
    ("search_files", "files"),
    ("read_file", "files"),
    ("read_browser_tab", "browser"),
    ("read_nook_browser", "browser"),
    ("open_in_nook_browser", "browser"),
    ("run_command", "terminal"),
    ("read_screen", "screen"),
    ("read_app", "screen"),
    ("list_running_apps", "screen"),
    ("get_active_app", "screen"),
    ("search_contacts", "contacts"),
    ("read_clipboard", "clipboard"),
    ("list_open_loops", "loops"),
    ("add_open_loop", "loops"),
    ("complete_open_loop", "loops"),
    ("remember", "memory"),
    ("forget", "memory"),
    ("recall_memory", "memory"),
    ("search_web", "web"),
    ("read_webpage", "web"),
    ("web_search", "web"),
    ("get_weather", "web"),
    ("read_source", "customsources"),
    ("send_to_source", "customsources"),
    ("vercel_deployments", "vercel"),
    ("stripe_payments", "stripe"),
    ("notion_search", "notion"),
    ("notion_read_page", "notion"),
    ("calcom_bookings", "calcom"),
    ("n8n_status", "n8n"),
    ("resend_overview", "resend"),
    ("portfolio_overview", "portfolio"),
    ("list_sources", "sources"),
    ("sources_overview", "sources"),
];

#[derive(Default)]
struct Registry {
    descriptors: Vec<SourceDescriptor>,
    tools: HashMap<String, String>,
}

fn registry() -> &'static Mutex<Registry> {
    static R: OnceLock<Mutex<Registry>> = OnceLock::new();
    R.get_or_init(Default::default)
}

pub fn built_in() -> Vec<SourceDescriptor> {
    BUILT_IN.iter().map(|(id, title, kind)| SourceDescriptor { id: (*id).into(), title: (*title).into(), kind: *kind }).collect()
}

pub fn all() -> Vec<SourceDescriptor> {
    let mut list = built_in();
    let reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    list.extend(reg.descriptors.iter().filter(|d| !list.iter().any(|b| b.id == d.id)).cloned().collect::<Vec<_>>());
    list
}

/// Maakt een bron bekend: zijn tools volgen dan de bronkiezer en de beperkingen per chat.
pub fn register(descriptor: SourceDescriptor, tools: &[String]) {
    let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    reg.descriptors.retain(|d| d.id != descriptor.id);
    reg.tools.retain(|_, source| source != &descriptor.id);
    for tool in tools {
        reg.tools.insert(tool.clone(), descriptor.id.clone());
    }
    reg.descriptors.push(descriptor);
}

/// Haalt een bron weg die er niet meer is (een verwijderde MCP-server).
pub fn unregister(id: &str) {
    let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    reg.descriptors.retain(|d| d.id != id);
    reg.tools.retain(|_, source| source != id);
}

pub fn descriptor(id: &str) -> Option<SourceDescriptor> {
    all().into_iter().find(|d| d.id == id)
}

pub fn title(id: &str) -> String {
    descriptor(id).map(|d| d.title).unwrap_or_else(|| id.to_string())
}

/// De bron van een tool, of `None` voor tools die altijd mogen.
pub fn source_for_tool(name: &str) -> Option<String> {
    if let Some((_, source)) = EXACT_TOOLS.iter().find(|(tool, _)| *tool == name) {
        return Some((*source).to_string());
    }
    if let Some(source) = registry().lock().unwrap_or_else(|e| e.into_inner()).tools.get(name) {
        return Some(source.clone());
    }
    if name.starts_with("github_") {
        return Some("github".into());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_map_to_their_source() {
        assert_eq!(source_for_tool("check_availability").as_deref(), Some("calendar"));
        assert_eq!(source_for_tool("github_merge_pr").as_deref(), Some("github"));
        assert_eq!(source_for_tool("send_to_source").as_deref(), Some("customsources"));
        assert_eq!(source_for_tool("open_url"), None);
    }

    #[test]
    fn runtime_sources_register_and_go() {
        register(SourceDescriptor { id: "mcp.test".into(), title: "Test".into(), kind: SourceKind::Custom }, &["mcp_test_echo".into()]);
        assert_eq!(source_for_tool("mcp_test_echo").as_deref(), Some("mcp.test"));
        assert_eq!(title("mcp.test"), "Test");
        unregister("mcp.test");
        assert_eq!(source_for_tool("mcp_test_echo"), None);
        assert_eq!(title("github"), "GitHub");
    }
}
