//! Connectors (MCP servers) an agent has but cannot use until you sign in (`ConnectorSignIn` + `ConnectorDomains` on the
//! Mac, AG-31): a claude.ai connector that was never connected, or an MCP server that asks for OAuth. Nook asks the
//! agent for the sign-in page, opens it, and checks back until the server connects.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::models::RunProvider;

/// A connector (MCP server) waiting for the user to sign in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectorSignIn {
    /// The server's name as the agent reports it (`claude.ai Supabase`, `plugin:design:linear`): the agent takes it back
    /// as is.
    pub name: String,
    /// The name as you know it: without the `claude.ai ` prefix or a plugin's path.
    pub title: String,
    /// The website whose icon is the connector's logo, wherever it is listed; `None` shows the connector symbol.
    pub icon_domain: Option<String>,
    /// Its sign-in page is open and Nook waits for the server to connect.
    #[serde(default)]
    pub waiting: bool,
}

impl ConnectorSignIn {
    pub fn new(name: impl Into<String>, waiting: bool) -> Self {
        let name = name.into();
        let title = connector_title(&name);
        let icon_domain = connector_domain(&title).map(str::to_string);
        Self { name, title, icon_domain, waiting }
    }
}

/// The name as you know it: without the `claude.ai ` prefix or a plugin's `plugin:<scope>:` path.
pub fn connector_title(name: &str) -> String {
    if let Some(rest) = name.strip_prefix("claude.ai ") {
        return rest.to_string();
    }
    if name.starts_with("plugin:") {
        if let Some(last) = name.split(':').next_back().filter(|s| !s.is_empty()) {
            return last.to_string();
        }
    }
    name.to_string()
}

/// Claude Code: the `needs-auth` rows of `mcp_servers` (system/init) or of an `mcp_status` reply.
pub fn parse_claude_needs_auth(servers: &Value) -> Vec<String> {
    servers
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    if row.get("status").and_then(Value::as_str) != Some("needs-auth") {
                        return None;
                    }
                    let name = row.get("name").and_then(Value::as_str)?;
                    (!name.is_empty()).then(|| name.to_string())
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Codex app-server: the `mcpServerStatus/list` rows whose `authStatus` is `notLoggedIn`.
pub fn parse_codex_needs_auth(response: &Value) -> Vec<String> {
    response
        .get("data")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    if row.get("authStatus").and_then(Value::as_str) != Some("notLoggedIn") {
                        return None;
                    }
                    let name = row.get("name").and_then(Value::as_str)?;
                    (!name.is_empty()).then(|| name.to_string())
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The new list, preserving which ones are currently waiting on their sign-in page, deduplicated and sorted by title.
pub fn merge_sign_ins(names: &[String], current: &[ConnectorSignIn]) -> Vec<ConnectorSignIn> {
    let waiting: HashSet<&str> = current.iter().filter(|c| c.waiting).map(|c| c.name.as_str()).collect();
    let mut seen = HashSet::new();
    let mut list: Vec<ConnectorSignIn> = names
        .iter()
        .filter(|name| !name.is_empty() && seen.insert(name.as_str()))
        .map(|name| ConnectorSignIn::new(name.clone(), waiting.contains(name.as_str())))
        .collect();
    list.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()).then_with(|| a.name.cmp(&b.name)));
    list
}

/// Where an agent keeps its connector sign-ins: per agent, account (profile) and machine. Sessions with the same key
/// share them so you sign in once instead of once per chat.
pub fn account_key(provider: RunProvider, profile_id: &str, machine: Option<&str>) -> String {
    let kind = match provider {
        RunProvider::Claude => "claude",
        RunProvider::Codex => "codex",
        RunProvider::Gemini => "gemini",
        RunProvider::Opencode => "opencode",
        RunProvider::Cursor => "cursor",
        RunProvider::Grok => "grok",
        RunProvider::Antigravity => "antigravity",
    };
    format!("{kind}|{profile_id}|{}", machine.unwrap_or(""))
}

/// The ones the row above the composer shows: anything waiting stays visible; dismissed ones leave the banner (they
/// remain in the session menu).
pub fn shown_sign_ins(all: &[ConnectorSignIn], dismissed: &HashSet<String>) -> Vec<ConnectorSignIn> {
    all.iter().filter(|c| c.waiting || !dismissed.contains(&c.name)).cloned().collect()
}

/// Official remote MCP services whose website icon stands for them (`MCPRemoteService.all` on the Mac).
const REMOTE_SERVICES: &[(&str, &str, &str)] = &[
    ("notion", "notion", "notion.so"),
    ("linear", "linear", "linear.app"),
    ("stripe", "stripe", "stripe.com"),
    ("vercel", "vercel", "vercel.com"),
    ("sentry", "sentry", "sentry.io"),
    ("atlassian", "jira & confluence", "atlassian.com"),
    ("canva", "canva", "canva.com"),
    ("supabase", "supabase", "supabase.com"),
    ("neon", "neon", "neon.tech"),
    ("huggingface", "hugging face", "huggingface.co"),
    ("calcom", "cal.com", "cal.com"),
    ("resend", "resend", "resend.com"),
    ("gitlab", "gitlab", "gitlab.com"),
];

/// Well-known MCP servers by a word in their name (`ConnectorDomains.mcpServices` on the Mac).
const MCP_SERVICES: &[(&str, &str)] = &[
    ("github", "github.com"),
    ("gitlab", "gitlab.com"),
    ("slack", "slack.com"),
    ("notion", "notion.so"),
    ("linear", "linear.app"),
    ("atlassian", "atlassian.com"),
    ("jira", "atlassian.com"),
    ("confluence", "atlassian.com"),
    ("brave", "brave.com"),
    ("postgres", "postgresql.org"),
    ("sqlite", "sqlite.org"),
    ("mysql", "mysql.com"),
    ("mongo", "mongodb.com"),
    ("redis", "redis.io"),
    ("supabase", "supabase.com"),
    ("puppeteer", "pptr.dev"),
    ("playwright", "playwright.dev"),
    ("stripe", "stripe.com"),
    ("sentry", "sentry.io"),
    ("figma", "figma.com"),
    ("vercel", "vercel.com"),
    ("cloudflare", "cloudflare.com"),
    ("todoist", "todoist.com"),
    ("discord", "discord.com"),
    ("telegram", "telegram.org"),
    ("airtable", "airtable.com"),
    ("hubspot", "hubspot.com"),
    ("shopify", "shopify.com"),
    ("obsidian", "obsidian.md"),
    ("spotify", "spotify.com"),
    ("gdrive", "drive.google.com"),
    ("google-drive", "drive.google.com"),
    ("gmail", "mail.google.com"),
    ("google-maps", "maps.google.com"),
    ("asana", "asana.com"),
    ("trello", "trello.com"),
    ("zapier", "zapier.com"),
    ("docker", "docker.com"),
    ("kubernetes", "kubernetes.io"),
    ("aws", "aws.amazon.com"),
    ("azure", "azure.microsoft.com"),
    ("dropbox", "dropbox.com"),
    ("box-mcp", "box.com"),
    ("hugging", "huggingface.co"),
    ("exa-mcp", "exa.ai"),
    ("tavily", "tavily.com"),
    ("perplexity", "perplexity.ai"),
    ("firecrawl", "firecrawl.dev"),
    ("context7", "context7.com"),
    ("n8n", "n8n.io"),
    ("resend", "resend.com"),
    ("calcom", "cal.com"),
    ("memory", "modelcontextprotocol.io"),
    ("sequential-thinking", "modelcontextprotocol.io"),
    ("everything", "modelcontextprotocol.io"),
    ("fetch", "modelcontextprotocol.io"),
];

/// Connectors an agent reports by name only (`ConnectorDomains.connectorNames` on the Mac).
const CONNECTOR_NAMES: &[(&str, &str)] = &[
    ("google calendar", "calendar.google.com"),
    ("gmail", "mail.google.com"),
    ("google drive", "drive.google.com"),
    ("google docs", "docs.google.com"),
    ("google sheets", "sheets.google.com"),
    ("google maps", "maps.google.com"),
    ("microsoft 365", "microsoft.com"),
    ("outlook", "outlook.com"),
    ("microsoft teams", "teams.microsoft.com"),
    ("onedrive", "onedrive.live.com"),
    ("sharepoint", "microsoft.com"),
    ("box", "box.com"),
    ("close", "close.com"),
    ("clay", "clay.com"),
    ("monday", "monday.com"),
    ("monday.com", "monday.com"),
    ("otter ai", "otter.ai"),
    ("otter", "otter.ai"),
    ("apollo", "apollo.io"),
    ("gong", "gong.io"),
    ("granola", "granola.ai"),
    ("intercom", "intercom.com"),
    ("datadog", "datadoghq.com"),
    ("pagerduty", "pagerduty.com"),
    ("ahrefs", "ahrefs.com"),
    ("amplitude", "amplitude.com"),
    ("amplitude eu", "amplitude.com"),
    ("canva", "canva.com"),
    ("klaviyo", "klaviyo.com"),
    ("similarweb", "similarweb.com"),
    ("supermetrics", "supermetrics.com"),
    ("calendly", "calendly.com"),
    ("crunchbase", "crunchbase.com"),
    ("fireflies", "fireflies.ai"),
    ("lusha", "lusha.com"),
    ("zoominfo", "zoominfo.com"),
    ("salesforce", "salesforce.com"),
    ("zendesk", "zendesk.com"),
    ("webflow", "webflow.com"),
    ("wix", "wix.com"),
    ("paypal", "paypal.com"),
    ("square", "squareup.com"),
    ("plaid", "plaid.com"),
    ("netlify", "netlify.com"),
    ("neon", "neon.tech"),
    ("prisma", "prisma.io"),
    ("mixpanel", "mixpanel.com"),
    ("posthog", "posthog.com"),
    ("miro", "miro.com"),
    ("clickup", "clickup.com"),
    ("egnyte", "egnyte.com"),
    ("harvey", "harvey.ai"),
    ("pitchbook", "pitchbook.com"),
    ("hex", "hex.tech"),
    ("snowflake", "snowflake.com"),
    ("databricks", "databricks.com"),
    ("bigquery", "cloud.google.com"),
    ("dropbox", "dropbox.com"),
    ("evernote", "evernote.com"),
    ("loom", "loom.com"),
    ("zoom", "zoom.us"),
    ("cloudinary", "cloudinary.com"),
    ("contentful", "contentful.com"),
    ("sanity", "sanity.io"),
    ("railway", "railway.app"),
    ("render", "render.com"),
    ("fly", "fly.io"),
    ("heroku", "heroku.com"),
    ("pinecone", "pinecone.io"),
    ("claude in chrome", "claude.ai"),
];

/// The website for a connector an agent reports by name only (`ConnectorDomains.connectorDomain` on the Mac).
pub fn connector_domain(name: &str) -> Option<&'static str> {
    let key = name.to_lowercase().replace(['_', '-'], " ").trim().to_string();
    if key.is_empty() {
        return None;
    }
    if let Some((_, domain)) = CONNECTOR_NAMES.iter().find(|(k, _)| *k == key) {
        return Some(domain);
    }
    if let Some((_, _, domain)) = REMOTE_SERVICES.iter().find(|(id, label, _)| *id == key || *label == key) {
        return Some(domain);
    }
    let dashed = key.replace(' ', "-");
    MCP_SERVICES.iter().find(|(word, _)| dashed.contains(word)).map(|(_, domain)| *domain)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn titles_strip_claude_and_plugin_prefixes() {
        assert_eq!(connector_title("claude.ai Supabase"), "Supabase");
        assert_eq!(connector_title("claude.ai Google Calendar"), "Google Calendar");
        assert_eq!(connector_title("plugin:design:linear"), "linear");
        assert_eq!(connector_title("my-custom-mcp"), "my-custom-mcp");
    }

    #[test]
    fn domains_match_known_connectors_and_services() {
        assert_eq!(connector_domain("Google Calendar"), Some("calendar.google.com"));
        assert_eq!(connector_domain("Supabase"), Some("supabase.com"));
        assert_eq!(connector_domain("linear"), Some("linear.app"));
        assert_eq!(connector_domain("Jira & Confluence"), Some("atlassian.com"));
        assert_eq!(connector_domain("my_github_server"), Some("github.com"));
        assert_eq!(connector_domain("completely-unknown-tool"), None);
    }

    #[test]
    fn parses_claude_needs_auth_rows() {
        let raw = json!([
            {"name": "claude.ai Supabase", "status": "needs-auth"},
            {"name": "nook", "status": "connected"},
            {"name": "plugin:work:linear", "status": "needs-auth"},
            {"name": "", "status": "needs-auth"},
            {"name": "broken", "status": "failed"}
        ]);
        assert_eq!(parse_claude_needs_auth(&raw), vec!["claude.ai Supabase", "plugin:work:linear"]);
    }

    #[test]
    fn parses_codex_not_logged_in_rows() {
        let raw = json!({
            "data": [
                {"name": "Notion", "authStatus": "notLoggedIn"},
                {"name": "nook", "authStatus": "unsupported"},
                {"name": "Linear", "authStatus": "oAuth"},
                {"name": "Stripe", "authStatus": "notLoggedIn"}
            ]
        });
        assert_eq!(parse_codex_needs_auth(&raw), vec!["Notion", "Stripe"]);
    }

    #[test]
    fn merge_preserves_waiting_deduplicates_and_sorts_by_title() {
        let current = vec![ConnectorSignIn::new("claude.ai Supabase", true)];
        let names = vec!["claude.ai Supabase".into(), "plugin:work:Linear".into(), "claude.ai Supabase".into(), "claude.ai Figma".into()];
        let merged = merge_sign_ins(&names, &current);
        assert_eq!(merged.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(), vec!["Figma", "Linear", "Supabase"]);
        assert!(!merged[0].waiting);
        assert!(!merged[1].waiting);
        assert!(merged[2].waiting);
        assert_eq!(merged[0].icon_domain.as_deref(), Some("figma.com"));
        assert_eq!(merged[1].icon_domain.as_deref(), Some("linear.app"));
        assert_eq!(merged[2].icon_domain.as_deref(), Some("supabase.com"));
    }

    #[test]
    fn shown_keeps_waiting_even_if_dismissed() {
        let all = vec![ConnectorSignIn::new("claude.ai Figma", false), ConnectorSignIn::new("claude.ai Linear", true)];
        let dismissed: HashSet<String> = ["claude.ai Figma".into(), "claude.ai Linear".into()].into_iter().collect();
        let shown = shown_sign_ins(&all, &dismissed);
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].name, "claude.ai Linear");
    }

    #[test]
    fn account_key_groups_provider_profile_and_machine() {
        assert_eq!(account_key(RunProvider::Claude, "work", None), "claude|work|");
        assert_eq!(account_key(RunProvider::Codex, "", Some("box-1")), "codex||box-1");
        assert_ne!(account_key(RunProvider::Claude, "work", None), account_key(RunProvider::Claude, "personal", None));
    }
}
