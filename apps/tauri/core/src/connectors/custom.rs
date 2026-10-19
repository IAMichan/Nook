//! Eigen bronnen: bijna elke app of dienst met een web-API of webhook (Todoist, Linear, Home Assistant, Slack,
//! Discord, Teams, Telegram, n8n, Zapier, je eigen server…). Alleen https, en de sleutel blijft in de kluis. Nook
//! herkent de dienst aan het adres, toont zijn icoon en weet hoe een bericht eruit moet zien. Lezen (GET) gebeurt
//! meteen; versturen (POST) is een actie die pas na Uitvoeren gebeurt.
//!
//! Eén regel per bron: `Naam | https://api.voorbeeld.nl/v1 | Authorization: Bearer abc | webhook` (de laatste twee
//! delen zijn optioneel; een kale sleutel zonder dubbele punt wordt een Bearer-token). Meer bronnen: `;;` of een
//! nieuwe regel ertussen.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::{json, Value};

use super::brand::{payload, KnownService, SendStyle};
use super::hub::{Connector, Env, Scope};
use super::{short, CResult, ConnectorError, ConnectorItem, ConnectorStatus, Tone};
use crate::brain::LoopTool;

pub const ID: &str = "customsources";
pub const KEY_ACCOUNT: &str = "connector.customsources.list";

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub name: String,
    pub base: String,
    #[serde(skip)]
    pub header: Option<(String, String)>,
    pub service: KnownService,
}

impl Source {
    pub fn can_read(&self) -> bool {
        self.service.readable
    }

    pub fn can_send(&self) -> bool {
        self.service.send.is_some()
    }
}

fn allowed_scheme(url: &url::Url) -> bool {
    let host = url.host_str().unwrap_or("");
    url.scheme() == "https" || (url.scheme() == "http" && (host == "127.0.0.1" || host == "localhost"))
}

pub fn parse_line(line: &str) -> Option<Source> {
    let parts: Vec<&str> = line.split('|').map(str::trim).collect();
    if parts.len() < 2 || parts[0].is_empty() {
        return None;
    }
    let url = url::Url::parse(parts[1]).ok().filter(|u| allowed_scheme(u) && u.host_str().is_some())?;
    let mut header = None;
    if parts.len() >= 3 && !parts[2].is_empty() {
        header = Some(match parts[2].split_once(':') {
            Some((name, value)) => (name.trim().to_string(), value.trim().to_string()),
            None => ("Authorization".to_string(), format!("Bearer {}", parts[2])),
        });
    }
    // Alleen een gewone headernaam: geen witregels of vreemde tekens.
    if let Some((name, value)) = &header {
        if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') || value.contains('\n') || value.contains('\r') {
            return None;
        }
    }
    let explicit = parts.get(3).map(|p| p.to_lowercase());
    Some(Source { name: parts[0].into(), base: parts[1].into(), header, service: KnownService::detect(&url, explicit.as_deref()) })
}

pub fn parse_all(raw: &str) -> Vec<Source> {
    let mut seen = std::collections::HashSet::new();
    raw.split(['\n', '\r']).flat_map(|l| l.split(";;")).filter_map(parse_line).filter(|s| seen.insert(s.name.to_lowercase())).collect()
}

/// Het pad komt achter het basisadres en moet op dezelfde host blijven.
pub fn url_for(source: &Source, path: &str) -> CResult<String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Ok(source.base.clone());
    }
    if !trimmed.starts_with('/') || trimmed.starts_with("//") || trimmed.contains("://") || trimmed.contains("..") {
        return Err(ConnectorError::new(format!("The path must start with / and stay within {}.", source.name)));
    }
    let base = source.base.trim_end_matches('/');
    let joined = format!("{base}{trimmed}");
    let (Ok(url), Ok(original)) = (url::Url::parse(&joined), url::Url::parse(&source.base)) else {
        return Err(ConnectorError::new(format!("Invalid path: {trimmed}")));
    };
    if url.host_str() != original.host_str() || url.scheme() != original.scheme() {
        return Err(ConnectorError::new(format!("Invalid path: {trimmed}")));
    }
    Ok(joined)
}

/// Volgt een redirect alleen op dezelfde host, zodat een sleutel nooit naar buiten gaat.
fn client(host: String) -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent("Nook")
        .redirect(reqwest::redirect::Policy::custom(move |attempt| {
            if attempt.url().host_str() == Some(host.as_str()) && attempt.url().scheme() == "https" && attempt.previous().len() < 5 {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .unwrap_or_default()
}

pub struct CustomSources {
    env: Arc<Env>,
    status: Mutex<ConnectorStatus>,
}

impl CustomSources {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { env, status: Mutex::default() })
    }

    pub fn sources(&self) -> Vec<Source> {
        self.env.secret(KEY_ACCOUNT).map(|raw| parse_all(&raw)).unwrap_or_default()
    }

    fn find(&self, name: &str) -> CResult<Source> {
        let list = self.sources();
        let lower = name.to_lowercase();
        list.iter()
            .find(|s| s.name.to_lowercase() == lower)
            .or_else(|| list.iter().find(|s| s.name.to_lowercase().contains(&lower)))
            .cloned()
            .ok_or_else(|| {
                ConnectorError::new(format!(
                    "No source named {name}. Known sources: {}.",
                    list.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().join(", ")
                ))
            })
    }

    pub async fn read(&self, name: &str, path: &str) -> CResult<String> {
        let source = self.find(name)?;
        if !source.can_read() {
            return Err(ConnectorError::new(format!("{} is a webhook: incoming messages only, cannot read data.", source.name)));
        }
        let url = url_for(&source, path)?;
        let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_default();
        let mut request = client(host).get(&url).header("Accept", "application/json, text/plain;q=0.8, */*;q=0.5");
        if let Some((k, v)) = &source.header {
            request = request.header(k, v);
        }
        let response = request.send().await.map_err(|e| super::network_error(e, &source.name))?;
        let code = response.status().as_u16();
        if !(200..300).contains(&code) {
            return Err(ConnectorError::new(match code {
                401 | 403 => format!("{} rejected credentials ({code}). Check them in Settings › Accounts & connections.", source.name),
                404 => format!("{}: not found (404). Is the path correct?", source.name),
                429 => format!("{}: too many requests. Please try again shortly.", source.name),
                _ => format!("{} returned an error ({code}).", source.name),
            }));
        }
        let bytes = response.bytes().await.map_err(|e| super::network_error(e, &source.name))?;
        let mut text = match serde_json::from_slice::<Value>(&bytes) {
            Ok(json) => sorted(&json).to_string(),
            Err(_) => String::from_utf8_lossy(&bytes).to_string(),
        };
        if text.chars().count() > 8_000 {
            text = format!("{}\n… (truncated; query with a path or filter for less data)", text.chars().take(8_000).collect::<String>());
        }
        Ok(if text.is_empty() { format!("Empty response from {}.", source.name) } else { text })
    }

    pub async fn send(&self, name: &str, message: &str, to: &str) -> CResult<String> {
        let source = self.find(name)?;
        let style = source.service.send.ok_or_else(|| ConnectorError::new(format!("{} cannot receive messages.", source.name)))?;
        let text: String = message.chars().take(4_000).collect();
        let body = payload(style, &text, to)?;
        let mut url = source.base.clone();
        match style {
            SendStyle::SlackApi if !url.to_lowercase().ends_with("chat.postmessage") => url = url_for(&source, "/chat.postMessage")?,
            SendStyle::Telegram if !url.to_lowercase().ends_with("sendmessage") => url = url_for(&source, "/sendMessage")?,
            _ => {}
        }
        let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_default();
        let mut request = client(host).post(&url).header("Content-Type", "application/json; charset=utf-8").body(body.to_string());
        if let Some((k, v)) = &source.header {
            request = request.header(k, v);
        }
        let service = source.service.name.clone();
        let response = request.send().await.map_err(|e| super::network_error(e, &service))?;
        let code = response.status().as_u16();
        if !(200..300).contains(&code) {
            return Err(ConnectorError::new(match code {
                401 | 403 | 404 => format!("{service} weigerde het bericht ({code}). Klopt het adres of de sleutel?"),
                429 => format!("{service}: te veel verzoeken. Probeer het zo opnieuw."),
                _ => format!("{service} gaf een fout ({code})."),
            }));
        }
        // Slack en Telegram melden fouten in de body, niet in de status.
        if let Ok(json) = response.json::<Value>().await {
            if json["ok"] == json!(false) {
                let reason = json["error"].as_str().or(json["description"].as_str()).unwrap_or("onbekende fout");
                return Err(ConnectorError::new(format!("{service} weigerde het bericht: {reason}")));
            }
        }
        Ok(format!("Bericht verstuurd via {service}{}.", if to.is_empty() { String::new() } else { format!(" aan {to}") }))
    }
}

/// JSON met gesorteerde sleutels, zoals op de Mac.
fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&map[k]))).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

#[async_trait]
impl Connector for CustomSources {
    fn id(&self) -> String {
        ID.into()
    }

    fn title(&self) -> String {
        "Eigen bronnen".into()
    }

    fn configured(&self) -> bool {
        !self.sources().is_empty()
    }

    fn active(&self) -> bool {
        self.configured() && self.env.store.is_on(ID)
    }

    fn status(&self) -> ConnectorStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn refresh_interval(&self) -> u64 {
        3600
    }

    async fn refresh(&self) {
        let status = if !self.active() {
            ConnectorStatus::default()
        } else {
            let list = self.sources();
            let items = list
                .iter()
                .map(|s| {
                    let mut parts = vec![s.service.name.clone()];
                    if s.can_read() {
                        parts.push("lezen".into());
                    }
                    if s.can_send() {
                        parts.push("versturen".into());
                    }
                    let mut item = ConnectorItem::new(&s.name, &s.name, parts.join(" · "), Tone::Neutral, None);
                    item.icon_domain = Some(s.service.domain.clone());
                    item
                })
                .collect();
            ConnectorStatus::ok(
                format!("{} bronnen", list.len()),
                list.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().join(", "),
                items,
                false,
            )
        };
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = status;
    }

    fn context_lines(&self) -> Vec<String> {
        if !self.active() {
            return vec![];
        }
        let list = self.sources();
        let mut lines = vec![];
        let readable: Vec<String> = list.iter().filter(|s| s.can_read()).map(|s| format!("{} ({})", s.name, s.service.name)).collect();
        if !readable.is_empty() {
            lines.push(format!("Custom sources readable via read_source: {}.", readable.join(", ")));
        }
        let sendable: Vec<String> = list.iter().filter(|s| s.can_send()).map(|s| format!("{} ({})", s.name, s.service.name)).collect();
        if !sendable.is_empty() {
            lines.push(format!(
                "Custom sources you can send messages to via send_to_source (user approves first): {}.",
                sendable.join(", ")
            ));
        }
        lines
    }

    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        if !self.active() {
            return vec![];
        }
        let list = self.sources();
        let mut tools = vec![];
        if list.iter().any(Source::can_read) {
            let me = self.clone();
            tools.push(LoopTool::read(
                "read_source",
                "Reads (read-only, GET) from a user's custom source, an app or service connected to Nook. Specify the source name (from context) and optional path appended to the base URL including query string, e.g. \"/tasks?filter=today\". Omitting path fetches the base URL itself. For Slack (API URL with user token), search messages with path \"/search.messages?query=…\" and read a channel with \"/conversations.history?channel=…\"; for Telegram read new messages with \"/getUpdates\". Result is third-party data.",
                super::schema(json!({
                    "name": {"type": "string", "description": "Name of the source."},
                    "path": {"type": "string", "description": "Starts with /, optional, with query parameters."}
                })),
                move |input| {
                    let me = me.clone();
                    async move {
                        let name = super::field(&input, "name").ok_or_else(|| ConnectorError::new("Source name is missing."))?;
                        me.read(&name, super::text(&input, "path")).await.map_err(Into::into)
                    }
                },
            ));
        }
        if list.iter().any(Source::can_send) {
            tools.push(LoopTool::action(
                "send_to_source",
                "Sends a message via an outgoing custom source: Slack, Discord, Microsoft Teams, Telegram, or a webhook (n8n, Zapier, Make…). Use this when the user asks to send something \"via Slack\" (or another connected service). Write the message in an appropriate tone. Specify the source name from context in name. to is the recipient or channel: required for a Slack API source (e.g. #general or a user ID) and for Telegram if the chat ID is not part of the URL; for a webhook, the channel is determined by the webhook and to is prepended to the message. If a required recipient is missing, ask first. The user reviews the message as a plan and approves before it is sent.",
                json!({"type": "object", "properties": {
                    "name": {"type": "string", "description": "Name of the source."},
                    "message": {"type": "string", "description": "Full text of the message."},
                    "to": {"type": "string", "description": "Recipient or channel, optional."}
                }, "required": ["name", "message"]}),
            ));
        }
        tools
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "send_to_source").then(|| {
            let to = super::text(input, "to").trim().to_string();
            format!(
                "{}{}: {}",
                super::text(input, "name"),
                if to.is_empty() { String::new() } else { format!(" → {to}") },
                short(super::text(input, "message"), 70)
            )
        })
    }

    async fn execute(&self, tool: &str, input: &Value) -> Option<CResult<String>> {
        if tool != "send_to_source" {
            return None;
        }
        if !self.active() {
            return Some(Err(ConnectorError::not_set_up("Eigen bronnen")));
        }
        let Some(name) = super::field(input, "name") else { return Some(Err(ConnectorError::new("Source name is missing."))) };
        let message = super::text(input, "message").trim().to_string();
        if message.is_empty() {
            return Some(Err(ConnectorError::new("Het bericht is leeg.")));
        }
        Some(self.send(&name, &message, super::text(input, "to").trim()).await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::{MemorySecrets, SecretStore};

    #[test]
    fn parses_lines_and_headers() {
        let list = parse_all("Todoist | https://api.todoist.com/rest/v2 | abc123 ;; Team | https://hooks.slack.com/services/T/B/x\nKapot | http://example.com\nRaar | https://x.example.com | Bad Header: y");
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].header, Some(("Authorization".into(), "Bearer abc123".into())));
        assert!(list[0].can_read() && !list[0].can_send());
        assert!(list[1].can_send() && !list[1].can_read());
        assert_eq!(list[1].service.name, "Slack");
    }

    #[test]
    fn paths_stay_on_the_same_host() {
        let s = parse_line("T | https://api.todoist.com/rest/v2").unwrap();
        assert_eq!(url_for(&s, "/tasks?filter=today").unwrap(), "https://api.todoist.com/rest/v2/tasks?filter=today");
        assert!(url_for(&s, "//evil.com").is_err());
        assert!(url_for(&s, "/../x").is_err());
        assert!(url_for(&s, "https://evil.com").is_err());
        assert!(url_for(&s, "@evil.com").is_err());
    }

    #[tokio::test]
    async fn reads_and_sends() {
        let server = TestServer::start(vec![
            ("GET /api/tasks", 200, r#"{"b":1,"a":[{"z":2,"y":1}]}"#.into()),
            ("POST /hook/webhook/x", 200, "{}".into()),
        ])
        .await;
        let secrets = Arc::new(MemorySecrets::default());
        secrets
            .write(KEY_ACCOUNT, &format!("Taken | {} | X-Key: geheim\nn8n | {}", server.url("/api"), server.url("/hook/webhook/x")))
            .unwrap();
        let sources = CustomSources::new(Env::new(secrets, Arc::new(ConnectorStore::in_memory())));
        let read = sources.read("taken", "/tasks").await.unwrap();
        assert_eq!(serde_json::from_str::<Value>(&read).unwrap(), json!({"a": [{"y": 1, "z": 2}], "b": 1}));
        assert!(sources.read("n8n", "").await.unwrap_err().message.contains("is a webhook"));
        assert_eq!(sources.send("n8n", "Hallo", "").await.unwrap(), "Bericht verstuurd via Webhook.");
        let sent = server.requests();
        assert_eq!(sent[0].header("x-key"), Some("geheim"));
        assert_eq!(serde_json::from_str::<Value>(&sent[1].body).unwrap(), json!({"message": "Hallo", "text": "Hallo"}));
        let tools: Vec<String> = sources.clone().tools(&Scope::default()).iter().map(|t| t.name.clone()).collect();
        assert_eq!(tools, ["read_source", "send_to_source"]);
    }
}
