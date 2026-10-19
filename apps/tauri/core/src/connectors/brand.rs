//! Waar het echte icoon van een bron vandaan komt (de website van de dienst), en welke dienst er achter een adres zit
//! (`SourceBrand` en `KnownService` op de Mac): Slack, Discord, Teams, Telegram, Zapier, Make, webhooks.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{CResult, ConnectorError};

/// De website waarvan het icoon voor een dienst staat.
pub fn domain(id: &str) -> Option<&'static str> {
    Some(match id {
        "github" => "github.com",
        "gitlab" => "gitlab.com",
        "vercel" => "vercel.com",
        "stripe" => "stripe.com",
        "notion" => "notion.so",
        "calcom" => "cal.com",
        "n8n" => "n8n.io",
        "resend" => "resend.com",
        "whatsapp" => "whatsapp.com",
        "linear" => "linear.app",
        "sentry" => "sentry.io",
        "portfolio" => "coinbase.com",
        _ => return None,
    })
}

/// Bekende MCP-servers aan een woord in hun naam of opdracht (specifiek genoeg om niet per ongeluk te passen).
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

/// Het domein voor een MCP-server: de eigen host bij een server op internet (mcp.notion.com → notion.com), anders een
/// bekende dienst in de opdracht of naam ("npx -y @modelcontextprotocol/server-github" → github.com).
pub fn mcp_domain(name: &str, command: Option<(&str, &[String])>, url: Option<&str>) -> Option<String> {
    if let Some(parsed) = url.and_then(|u| url::Url::parse(u).ok()) {
        if parsed.host_str().is_some() {
            return Some(icon_domain(&parsed));
        }
    }
    let mut text = name.to_lowercase();
    if let Some((cmd, args)) = command {
        text.push(' ');
        text.push_str(&std::iter::once(cmd.to_string()).chain(args.iter().cloned()).collect::<Vec<_>>().join(" ").to_lowercase());
    }
    MCP_SERVICES.iter().find(|(word, _)| text.contains(word)).map(|(_, d)| d.to_string())
}

/// Hoofddomein voor een icoon: api.todoist.com → todoist.com, app.example.co.uk → example.co.uk.
pub fn icon_domain(url: &url::Url) -> String {
    let host = url.host_str().unwrap_or("").to_lowercase();
    let labels: Vec<&str> = host.split('.').filter(|l| !l.is_empty()).collect();
    if labels.len() <= 2 {
        return labels.join(".");
    }
    let second = labels[labels.len() - 2];
    let take = if second.len() <= 3 && ["co", "com", "org", "net", "gov", "ac"].contains(&second) && labels[labels.len() - 1].len() == 2 {
        3
    } else {
        2
    };
    labels[labels.len() - take..].join(".")
}

/// Hoe berichten bij een dienst aankomen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SendStyle {
    SlackWebhook,
    SlackApi,
    Discord,
    Teams,
    Telegram,
    GenericWebhook,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownService {
    pub name: String,
    /// Het domein voor het icoon.
    pub domain: String,
    /// Hoe berichten verstuurd worden; `None` = alleen lezen.
    pub send: Option<SendStyle>,
    /// Een webhook is alleen een ingang: daar valt niets te lezen.
    pub readable: bool,
}

impl KnownService {
    fn new(name: &str, domain: &str, send: Option<SendStyle>, readable: bool) -> Self {
        Self { name: name.into(), domain: domain.into(), send, readable }
    }

    /// Herkent de dienst aan het adres. `explicit` is "webhook" of "post" als de gebruiker dat achter de regel zette.
    pub fn detect(url: &url::Url, explicit: Option<&str>) -> Self {
        let host = url.host_str().unwrap_or("").to_lowercase();
        let path = url.path().to_lowercase();
        let domain = icon_domain(url);
        if host == "hooks.slack.com" {
            return Self::new("Slack", "slack.com", Some(SendStyle::SlackWebhook), false);
        }
        if (host == "slack.com" || host.ends_with(".slack.com")) && path.starts_with("/api") {
            return Self::new("Slack", "slack.com", Some(SendStyle::SlackApi), true);
        }
        if (host == "discord.com" || host == "discordapp.com" || host.ends_with(".discord.com")) && path.contains("/webhooks/") {
            return Self::new("Discord", "discord.com", Some(SendStyle::Discord), false);
        }
        if host.ends_with("webhook.office.com") || (host == "outlook.office.com" && path.contains("/webhook")) {
            return Self::new("Microsoft Teams", "microsoft.com", Some(SendStyle::Teams), false);
        }
        if host == "api.telegram.org" {
            return Self::new("Telegram", "telegram.org", Some(SendStyle::Telegram), true);
        }
        if host == "hooks.zapier.com" {
            return Self::new("Zapier", "zapier.com", Some(SendStyle::GenericWebhook), false);
        }
        if host.starts_with("hook.") && (host.ends_with(".make.com") || host.ends_with(".integromat.com")) {
            return Self::new("Make", "make.com", Some(SendStyle::GenericWebhook), false);
        }
        if path.contains("/webhook/")
            || path.contains("/webhook-test/")
            || host.starts_with("hooks.")
            || matches!(explicit, Some("webhook") | Some("post"))
        {
            return Self::new("Webhook", &domain, Some(SendStyle::GenericWebhook), false);
        }
        Self::new(&domain, &domain, None, true)
    }
}

/// De inhoud van een bericht voor een dienst. `to` is kanaal, ontvanger of gebruiker, afhankelijk van de dienst.
pub fn payload(style: SendStyle, message: &str, to: &str) -> CResult<Value> {
    let prefixed = if to.is_empty() { message.to_string() } else { format!("{to} {message}") };
    Ok(match style {
        // Een Slack-webhook hoort bij één kanaal; een ontvanger komt voor het bericht.
        SendStyle::SlackWebhook | SendStyle::Teams => json!({"text": prefixed}),
        SendStyle::SlackApi => {
            if to.is_empty() {
                return Err(ConnectorError::new("Naar welk Slack-kanaal of welke ontvanger moet het bericht? Bijvoorbeeld #algemeen."));
            }
            json!({"channel": to, "text": message})
        }
        SendStyle::Discord => json!({"content": prefixed}),
        SendStyle::Telegram => {
            let mut body = json!({"text": message});
            if !to.is_empty() {
                body["chat_id"] = json!(to);
            }
            body
        }
        SendStyle::GenericWebhook => {
            let mut body = json!({"text": message, "message": message});
            if !to.is_empty() {
                body["to"] = json!(to);
            }
            body
        }
    })
}

/// Het icoon van een dienst van zijn eigen website (apple-touch-icon, anders favicon), als data-URL. Eén keer
/// opgehaald en bewaard in de gegevensmap; een domein dat er geen heeft, wordt een dag niet opnieuw gevraagd.
pub async fn icon(domain: &str) -> Option<String> {
    use base64::Engine;
    let domain = domain.trim().to_lowercase();
    if domain.is_empty()
        || domain.len() > 100
        || !domain.contains('.')
        || !domain.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return None;
    }
    let dir = crate::paths::support_directory().join("icons");
    let file = dir.join(format!("{domain}.img"));
    let miss = dir.join(format!("{domain}.none"));
    let encode = |bytes: &[u8]| {
        let kind = if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
            "image/png"
        } else if bytes.starts_with(&[0xFF, 0xD8]) {
            "image/jpeg"
        } else if bytes.starts_with(b"<svg") || bytes.starts_with(b"<?xml") {
            "image/svg+xml"
        } else {
            "image/x-icon"
        };
        format!("data:{kind};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
    };
    if let Ok(bytes) = std::fs::read(&file) {
        return Some(encode(&bytes));
    }
    if let Ok(meta) = std::fs::metadata(&miss) {
        if meta.modified().ok().and_then(|m| m.elapsed().ok()).map(|e| e.as_secs() < 86_400).unwrap_or(false) {
            return None;
        }
    }
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(8)).user_agent("Nook").build().ok()?;
    for candidate in [
        format!("https://{domain}/apple-touch-icon.png"),
        format!("https://{domain}/favicon.ico"),
        format!("https://www.{domain}/favicon.ico"),
    ] {
        let Ok(response) = client.get(&candidate).send().await else { continue };
        if !response.status().is_success() {
            continue;
        }
        let Ok(bytes) = response.bytes().await else { continue };
        // Alleen een echt plaatje van redelijke grootte, geen HTML-pagina.
        if bytes.len() < 64 || bytes.len() > 500_000 || bytes.starts_with(b"<!") || bytes.starts_with(b"<html") {
            continue;
        }
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&file, &bytes);
        return Some(encode(&bytes));
    }
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(&miss, b"");
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect(s: &str) -> KnownService {
        KnownService::detect(&url::Url::parse(s).unwrap(), None)
    }

    #[test]
    fn recognizes_services_by_address() {
        assert_eq!(detect("https://hooks.slack.com/services/T/B/x").send, Some(SendStyle::SlackWebhook));
        let api = detect("https://slack.com/api");
        assert_eq!((api.send, api.readable), (Some(SendStyle::SlackApi), true));
        assert_eq!(detect("https://discord.com/api/webhooks/1/abc").name, "Discord");
        assert_eq!(detect("https://acme.webhook.office.com/webhookb2/x").name, "Microsoft Teams");
        assert_eq!(detect("https://api.telegram.org/bot123:abc").send, Some(SendStyle::Telegram));
        assert_eq!(detect("https://hooks.zapier.com/hooks/catch/1/x").name, "Zapier");
        assert_eq!(detect("https://hook.eu1.make.com/abc").name, "Make");
        let n8n = detect("https://n8n.example.com/webhook/abc");
        assert_eq!((n8n.name.as_str(), n8n.readable), ("Webhook", false));
        let todoist = detect("https://api.todoist.com/rest/v2");
        assert_eq!((todoist.name.as_str(), todoist.send, todoist.readable), ("todoist.com", None, true));
        assert_eq!(
            KnownService::detect(&url::Url::parse("https://api.example.com/in").unwrap(), Some("webhook")).send,
            Some(SendStyle::GenericWebhook)
        );
    }

    #[test]
    fn icon_domains() {
        assert_eq!(icon_domain(&url::Url::parse("https://api.todoist.com/x").unwrap()), "todoist.com");
        assert_eq!(icon_domain(&url::Url::parse("https://app.example.co.uk").unwrap()), "example.co.uk");
        assert_eq!(icon_domain(&url::Url::parse("https://mcp.notion.com/mcp").unwrap()), "notion.com");
    }

    #[test]
    fn payloads_per_service() {
        assert_eq!(payload(SendStyle::SlackWebhook, "hoi", "@jan").unwrap(), json!({"text": "@jan hoi"}));
        assert!(payload(SendStyle::SlackApi, "hoi", "").is_err());
        assert_eq!(payload(SendStyle::SlackApi, "hoi", "#team").unwrap(), json!({"channel": "#team", "text": "hoi"}));
        assert_eq!(payload(SendStyle::Discord, "hoi", "").unwrap(), json!({"content": "hoi"}));
        assert_eq!(payload(SendStyle::Telegram, "hoi", "42").unwrap(), json!({"text": "hoi", "chat_id": "42"}));
        assert_eq!(payload(SendStyle::GenericWebhook, "hoi", "").unwrap(), json!({"text": "hoi", "message": "hoi"}));
    }

    #[test]
    fn mcp_domains() {
        let args = vec!["-y".to_string(), "@modelcontextprotocol/server-github".to_string()];
        assert_eq!(mcp_domain("GitHub", Some(("npx", &args)), None).as_deref(), Some("github.com"));
        assert_eq!(mcp_domain("Notion", None, Some("https://mcp.notion.com/mcp")).as_deref(), Some("notion.com"));
        assert_eq!(mcp_domain("Mijn server", Some(("python3", &[])), None), None);
    }
}
