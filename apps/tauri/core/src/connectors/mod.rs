//! Koppelingen: bronnen die Nook context en tools geven (agenda's, GitHub, Stripe, MCP-servers, WhatsApp, …).
//! Zelfde regels als `ContextSource` op de Mac:
//! - context komt uit de cache van de laatste verversing en wacht nooit op het netwerk;
//! - data van een bron is onbetrouwbare data voor het brein, nooit een instructie;
//! - sleutels staan alleen in de [`SecretStore`](crate::secrets::SecretStore), onder dezelfde namen als de Keychain op de Mac;
//! - een bron praat alleen met het adres dat de gebruiker instelde.

pub mod accounts;
pub mod agenda;
pub mod brand;
pub mod catalog;
pub mod cloud;
pub mod custom;
pub mod dates;
pub mod feeds;
pub mod github;
pub mod gitlab;
pub mod hub;
pub mod ics;
pub mod mcp;
pub mod oauth;
pub mod store;
pub mod whatsapp;

#[cfg(test)]
pub(crate) mod testserver;

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use hub::{Connector, ConnectorHub};
pub use store::ConnectorStore;

/// Hoe een koppeling ervoor staat, voor de instellingen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", tag = "kind", content = "message")]
pub enum ConnectorState {
    /// Niet ingesteld of uitgezet.
    #[default]
    Off,
    Loading,
    Ok,
    /// Iets ging mis; de tekst is voor de gebruiker.
    Error(String),
}

/// Kleur van een stipje: mint = goed, amber = wacht op jou, coral = fout, iris = neutraal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Tone {
    Good,
    Attention,
    Bad,
    #[default]
    Neutral,
}

/// Eén regel onder een koppeling: een pull request, een betaling, een afspraak.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConnectorItem {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub tone: Tone,
    /// Alleen https-links worden klikbaar.
    pub url: Option<String>,
    /// Domein voor het icoon van de dienst.
    pub icon_domain: Option<String>,
}

impl ConnectorItem {
    pub fn new(id: impl Into<String>, title: impl Into<String>, subtitle: impl Into<String>, tone: Tone, url: Option<String>) -> Self {
        Self { id: id.into(), title: title.into(), subtitle: subtitle.into(), tone, url, icon_domain: None }
    }
}

/// Waarom een verversing mislukte: dat bepaalt de uitweg (opnieuw koppelen of later opnieuw proberen).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ErrorKind {
    /// De inloggegevens werden geweigerd of zijn verlopen.
    Auth,
    /// De dienst was niet bereikbaar.
    Network,
    /// De dienst vroeg om rustiger aan te doen.
    RateLimited,
    /// Iets in de instelling klopt niet (adres, veld, recht).
    Config,
    #[default]
    Other,
}

impl ErrorKind {
    pub fn needs_reconnect(self) -> bool {
        matches!(self, Self::Auth | Self::Config)
    }

    pub fn can_retry(self) -> bool {
        matches!(self, Self::Network | Self::RateLimited | Self::Other)
    }

    pub fn for_http(status: u16) -> Self {
        match status {
            401 | 403 => Self::Auth,
            404 => Self::Config,
            429 => Self::RateLimited,
            _ => Self::Other,
        }
    }
}

/// Wat een koppeling laat zien: een kopregel ("3 open PR's"), een detail en een paar items.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConnectorStatus {
    pub state: ConnectorState,
    pub headline: String,
    pub detail: String,
    pub items: Vec<ConnectorItem>,
    pub updated: Option<chrono::DateTime<chrono::Utc>>,
    /// Er wacht iets op de gebruiker (falende CI, gevraagde review).
    pub needs_attention: bool,
    pub error_kind: Option<ErrorKind>,
}

impl ConnectorStatus {
    pub fn ok(headline: impl Into<String>, detail: impl Into<String>, items: Vec<ConnectorItem>, needs_attention: bool) -> Self {
        Self {
            state: ConnectorState::Ok,
            headline: headline.into(),
            detail: detail.into(),
            items,
            updated: Some(chrono::Utc::now()),
            needs_attention,
            error_kind: None,
        }
    }

    pub fn failed(error: &ConnectorError) -> Self {
        Self { state: ConnectorState::Error(error.message.clone()), error_kind: Some(error.kind), ..Default::default() }
    }

    /// Houdt de items van een vorige keer, maar zegt dat het nu misging.
    pub fn fail(&mut self, error: &ConnectorError) {
        self.state = ConnectorState::Error(error.message.clone());
        self.error_kind = Some(error.kind);
    }

    pub fn is_ok(&self) -> bool {
        self.state == ConnectorState::Ok
    }
}

/// Een fout met een zin voor de gebruiker en de soort, zodat de interface de juiste uitweg biedt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectorError {
    pub message: String,
    pub kind: ErrorKind,
}

impl ConnectorError {
    pub fn new(message: impl Into<String>) -> Self {
        Self { message: message.into(), kind: ErrorKind::Other }
    }

    pub fn kind(message: impl Into<String>, kind: ErrorKind) -> Self {
        Self { message: message.into(), kind }
    }

    pub fn not_set_up(service: &str) -> Self {
        Self::kind(format!("{service} is nog niet gekoppeld of staat uit (Instellingen › Accounts & koppelingen)."), ErrorKind::Config)
    }
}

impl std::fmt::Display for ConnectorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ConnectorError {}

impl From<ConnectorError> for crate::NookError {
    fn from(e: ConnectorError) -> Self {
        crate::NookError(e.message)
    }
}

impl From<ConnectorError> for String {
    fn from(e: ConnectorError) -> Self {
        e.message
    }
}

pub type CResult<T> = std::result::Result<T, ConnectorError>;

// Hulpjes

/// Plakken brengt vaak spaties, witregels of aanhalingstekens mee.
pub fn clean(raw: &str) -> String {
    raw.trim().trim_matches(|c: char| c == '"' || c == '\'' || c == '`' || c.is_whitespace()).to_string()
}

/// Eén regel, ingekort met "…".
pub fn short(text: &str, max: usize) -> String {
    let flat = text.replace('\n', " ");
    let flat = flat.trim();
    if flat.chars().count() <= max {
        return flat.to_string();
    }
    format!("{}…", flat.chars().take(max.saturating_sub(1)).collect::<String>())
}

/// "1 open PR" / "3 open PRs" (Engels: deze zinnen gaan naar het model).
pub fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

/// Valuta zonder decimalen bij Stripe.
const ZERO_DECIMAL: [&str; 16] =
    ["bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"];

/// Bedrag in de kleinste eenheid (centen) als "€ 1.240,50", zoals `nl_NL` het schrijft.
pub fn money(minor: i64, currency: &str) -> String {
    let code = currency.to_lowercase();
    let zero = ZERO_DECIMAL.contains(&code.as_str());
    let negative = minor < 0;
    let abs = minor.unsigned_abs();
    let (whole, cents) = if zero { (abs, 0) } else { (abs / 100, abs % 100) };
    let digits = whole.to_string();
    let mut grouped = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            grouped.push('.');
        }
        grouped.push(c);
    }
    let symbol = match code.as_str() {
        "eur" => "€".to_string(),
        "usd" => "US$".to_string(),
        "gbp" => "£".to_string(),
        "jpy" => "JP¥".to_string(),
        other => other.to_uppercase(),
    };
    let sign = if negative { "-" } else { "" };
    if zero {
        format!("{symbol} {sign}{grouped}")
    } else {
        format!("{symbol} {sign}{grouped},{cents:02}")
    }
}

/// Alleen https-links worden klikbaar.
pub fn link(text: Option<&str>) -> Option<String> {
    let t = text?.trim();
    let url = url::Url::parse(t).ok()?;
    (url.scheme() == "https" && url.host_str().is_some()).then(|| t.to_string())
}

/// Een id kan tekst of een getal zijn.
pub fn string(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

pub fn int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn float(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Een tekstveld uit tool-invoer, getrimd; leeg wordt `None`.
pub fn field(input: &Value, key: &str) -> Option<String> {
    let t = text(input, key).trim();
    (!t.is_empty()).then(|| t.to_string())
}

pub fn list(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}

pub fn date(value: &Value) -> Option<chrono::DateTime<chrono::Utc>> {
    value.as_str().filter(|s| !s.is_empty()).and_then(dates::parse)
}

/// JSON-schema van een lees-tool zonder verplichte velden.
pub fn schema(properties: Value) -> Value {
    serde_json::json!({"type": "object", "properties": properties, "required": []})
}

// HTTP

/// HTTP voor koppelingen: vaste time-outs, nooit cookies, en foutmeldingen die de gebruiker begrijpt.
#[derive(Clone)]
pub struct Http {
    pub client: reqwest::Client,
}

impl Default for Http {
    fn default() -> Self {
        Self::new()
    }
}

impl Http {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(20))
            .user_agent("Nook")
            .build()
            .unwrap_or_default();
        Self { client }
    }

    /// GET of een ander verzoek dat JSON teruggeeft. `headers` bevat meestal de Authorization-header.
    pub async fn json(&self, method: &str, url: &str, headers: &[(&str, String)], body: Option<&Value>, service: &str) -> CResult<Value> {
        let (status, bytes) = self.send(method, url, headers, body, service).await?;
        if !(200..300).contains(&status) {
            return Err(status_error(status, service));
        }
        if bytes.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&bytes).map_err(|_| ConnectorError::new(format!("{service} gaf een onverwacht antwoord.")))
    }

    pub async fn get(&self, url: &str, headers: &[(&str, String)], service: &str) -> CResult<Value> {
        self.json("GET", url, headers, None, service).await
    }

    /// Het ruwe antwoord, ook bij een foutstatus (voor diensten die hun eigen foutmelding meesturen).
    pub async fn send(
        &self,
        method: &str,
        url: &str,
        headers: &[(&str, String)],
        body: Option<&Value>,
        service: &str,
    ) -> CResult<(u16, Vec<u8>)> {
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap_or(reqwest::Method::GET);
        let mut request = self.client.request(method, url).header("Accept", "application/json");
        for (k, v) in headers {
            request = request.header(*k, v);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().await.map_err(|e| network_error(e, service))?;
        let status = response.status().as_u16();
        let bytes = response.bytes().await.map_err(|e| network_error(e, service))?.to_vec();
        Ok((status, bytes))
    }
}

pub fn network_error(error: reqwest::Error, service: &str) -> ConnectorError {
    if error.is_timeout() {
        return ConnectorError::kind(format!("{service} antwoordde niet op tijd. Nook probeert het later opnieuw."), ErrorKind::Network);
    }
    ConnectorError::kind(format!("Geen verbinding met {service}. Nook probeert het later opnieuw."), ErrorKind::Network)
}

pub fn status_error(status: u16, service: &str) -> ConnectorError {
    let kind = ErrorKind::for_http(status);
    let message = match status {
        401 | 403 => format!("{service} weigerde de inloggegevens ({status}). Controleer ze bij Instellingen › Accounts & koppelingen."),
        404 => "Niet gevonden (404). Klopt het adres?".to_string(),
        429 => "Te veel verzoeken. Nook probeert het zo opnieuw.".to_string(),
        _ => format!("{service} gaf een fout ({status})."),
    };
    ConnectorError::kind(message, kind)
}

/// Het basisadres van een API, in een debug-build te vervangen met een omgevingsvariabele (voor tests tegen een
/// nep-server). In een release-build gaat een sleutel nooit naar een ander adres dan de dienst zelf.
pub fn api_base(default: &str, env: &str) -> String {
    if cfg!(debug_assertions) {
        if let Ok(value) = std::env::var(env) {
            let value = value.trim().trim_end_matches('/').to_string();
            if !value.is_empty() {
                return value;
            }
        }
    }
    default.to_string()
}

/// Querystring met percent-encoding.
pub fn with_query(base: &str, query: &[(&str, String)]) -> String {
    if query.is_empty() {
        return base.to_string();
    }
    let mut url = match url::Url::parse(base) {
        Ok(u) => u,
        Err(_) => return base.to_string(),
    };
    {
        let mut pairs = url.query_pairs_mut();
        for (k, v) in query {
            pairs.append_pair(k, v);
        }
    }
    url.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_kinds() {
        assert_eq!(ErrorKind::for_http(401), ErrorKind::Auth);
        assert_eq!(ErrorKind::for_http(403), ErrorKind::Auth);
        assert_eq!(ErrorKind::for_http(404), ErrorKind::Config);
        assert_eq!(ErrorKind::for_http(429), ErrorKind::RateLimited);
        assert_eq!(ErrorKind::for_http(500), ErrorKind::Other);
        assert!(ErrorKind::Auth.needs_reconnect());
        assert!(ErrorKind::Config.needs_reconnect());
        assert!(!ErrorKind::Network.needs_reconnect());
        assert!(ErrorKind::Network.can_retry());
        assert!(ErrorKind::RateLimited.can_retry());
        assert!(!ErrorKind::Auth.can_retry());
    }

    #[test]
    fn helpers() {
        assert_eq!(clean(" \"ghp_abc\"\n"), "ghp_abc");
        assert_eq!(short("een\nlange zin hier", 9), "een lang…");
        assert_eq!(plural(1, "open PR", "open PRs"), "1 open PR");
        assert_eq!(plural(3, "open PR", "open PRs"), "3 open PRs");
        assert_eq!(money(124050, "eur"), "€ 1.240,50");
        assert_eq!(money(500, "jpy"), "JP¥ 500");
        assert_eq!(money(-250, "usd"), "US$ -2,50");
        assert_eq!(link(Some("https://github.com/x")), Some("https://github.com/x".into()));
        assert_eq!(link(Some("http://github.com/x")), None);
        assert_eq!(link(Some("javascript:alert(1)")), None);
    }

    #[test]
    fn query_is_encoded() {
        assert_eq!(
            with_query("https://api.github.com/search/issues", &[("q", "is:pr author:me".into())]),
            "https://api.github.com/search/issues?q=is%3Apr+author%3Ame"
        );
    }
}
