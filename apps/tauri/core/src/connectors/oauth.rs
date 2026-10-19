//! Inloggen bij een MCP-server zoals de MCP-autorisatiespec het beschrijft: OAuth 2.1 met PKCE. Nook vindt zelf de
//! autorisatieserver (RFC 9728, RFC 8414), registreert zichzelf (RFC 7591), zodat er geen client-id of geheim in de
//! app hoeft, en vraagt een token voor precies die ene server (RFC 8707).
//!
//! Op de desktop komt de browser terug op een adres op deze computer (`http://127.0.0.1:<poort>/callback`, RFC 8252):
//! alleen Nook luistert daar, en alleen het antwoord met de `state` die Nook voor deze poging maakte, telt.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::hub::Env;
use super::mcp::transport::Authorizer;
use super::{CResult, ConnectorError, ErrorKind};

/// Waarom inloggen of ingelogd blijven niet lukte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OAuthError {
    Insecure,
    NoAuthorizationServer,
    NoPkce,
    NoRegistration,
    Registration(String),
    Declined,
    Cancelled,
    StateMismatch,
    Callback(String),
    Token(String),
    Expired,
    NotSignedIn,
}

impl OAuthError {
    pub fn message(&self) -> String {
        match self {
            Self::Insecure => "Deze dienst gebruikt geen beveiligde verbinding (https). Nook logt daar niet in.".into(),
            Self::NoAuthorizationServer => "Nook kon niet vinden waar je bij deze dienst inlogt. Probeer het later opnieuw.".into(),
            Self::NoPkce => "Deze dienst ondersteunt de veilige inlogmethode (PKCE) niet. Gebruik een sleutel.".into(),
            Self::NoRegistration => "Deze dienst laat apps niet zelf registreren. Gebruik een sleutel.".into(),
            Self::Registration(d) => format!("Registreren bij de dienst lukte niet: {d}"),
            Self::Declined => "Je hebt geen toestemming gegeven. Er is niets opgeslagen.".into(),
            Self::Cancelled => "Het inloggen is afgebroken. Begin gewoon opnieuw.".into(),
            Self::StateMismatch => {
                "Het antwoord van de dienst hoorde niet bij deze inlogpoging en is genegeerd. Probeer het opnieuw.".into()
            }
            Self::Callback(d) => format!("Terugkeren naar Nook lukte niet: {d}"),
            Self::Token(d) => format!("De dienst gaf geen toegang: {d}"),
            Self::Expired => "Je inlog is verlopen. Log opnieuw in.".into(),
            Self::NotSignedIn => "Nog niet ingelogd. Klik op Verbinden.".into(),
        }
    }

    pub fn kind(&self) -> ErrorKind {
        match self {
            Self::Expired | Self::NotSignedIn | Self::Declined | Self::StateMismatch | Self::Cancelled => ErrorKind::Auth,
            Self::Insecure | Self::NoAuthorizationServer | Self::NoPkce | Self::NoRegistration | Self::Registration(_) => ErrorKind::Config,
            Self::Callback(_) | Self::Token(_) => ErrorKind::Other,
        }
    }
}

impl From<OAuthError> for ConnectorError {
    fn from(e: OAuthError) -> Self {
        ConnectorError::kind(e.message(), e.kind())
    }
}

// PKCE en state

pub fn base64_url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Onraadbare, URL-veilige tekst uit de cryptografische generator van het systeem.
pub fn random_token(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::Rng::fill(&mut rand::rngs::OsRng, &mut buf[..]);
    base64_url(&buf)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

impl Pkce {
    /// Een verse verifier (43 tekens uit 32 willekeurige bytes) met zijn S256-challenge.
    pub fn make() -> Self {
        let verifier = random_token(32);
        Self { challenge: Self::challenge(&verifier), verifier }
    }

    pub fn challenge(verifier: &str) -> String {
        base64_url(&Sha256::digest(verifier.as_bytes()))
    }
}

/// Vergelijkt zonder bij het eerste verschil te stoppen, zodat de tijd niets verraadt.
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    if x.len() != y.len() {
        return false;
    }
    x.iter().zip(y).fold(0u8, |d, (p, q)| d | (p ^ q)) == 0
}

// Metadata

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceMetadata {
    pub resource: Option<String>,
    pub authorization_servers: Vec<String>,
    pub scopes: Vec<String>,
}

impl ResourceMetadata {
    pub fn parse(json: &Value) -> Option<Self> {
        let strings = |k: &str| super::list(&json[k]).iter().filter_map(|v| v.as_str().map(str::to_string)).collect::<Vec<_>>();
        let meta = Self {
            resource: json["resource"].as_str().map(str::to_string),
            authorization_servers: strings("authorization_servers"),
            scopes: strings("scopes_supported"),
        };
        (meta.resource.is_some() || !meta.authorization_servers.is_empty()).then_some(meta)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerMetadata {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub registration_endpoint: Option<String>,
    pub revocation_endpoint: Option<String>,
    pub code_challenge_methods: Option<Vec<String>>,
    pub scopes: Option<Vec<String>>,
}

impl ServerMetadata {
    pub fn parse(json: &Value, fallback_issuer: &str) -> Option<Self> {
        let strings = |k: &str| json[k].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect::<Vec<_>>());
        Some(Self {
            issuer: json["issuer"].as_str().unwrap_or(fallback_issuer).to_string(),
            authorization_endpoint: json["authorization_endpoint"].as_str()?.to_string(),
            token_endpoint: json["token_endpoint"].as_str()?.to_string(),
            registration_endpoint: json["registration_endpoint"].as_str().map(str::to_string),
            revocation_endpoint: json["revocation_endpoint"].as_str().map(str::to_string),
            code_challenge_methods: strings("code_challenge_methods_supported"),
            scopes: strings("scopes_supported"),
        })
    }

    /// Elk adres waar Nook een code, token of verifier heen stuurt, is https.
    pub fn is_secure(&self) -> bool {
        [
            Some(&self.authorization_endpoint),
            Some(&self.token_endpoint),
            self.registration_endpoint.as_ref(),
            self.revocation_endpoint.as_ref(),
        ]
        .into_iter()
        .flatten()
        .all(|u| url::Url::parse(u).map(|u| is_secure(&u)).unwrap_or(false))
    }

    /// PKCE met S256 is verplicht in OAuth 2.1. Een server die methodes noemt zonder S256 wordt geweigerd; een die
    /// er geen noemt krijgt het voordeel van de twijfel.
    pub fn supports_s256(&self) -> bool {
        self.code_challenge_methods.as_ref().map(|m| m.iter().any(|x| x == "S256")).unwrap_or(true)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Client {
    pub id: String,
    /// Alleen als de server er per se een geeft; die staat dan samen met de tokens in de kluis.
    pub secret: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
}

impl Tokens {
    /// Een minuut eerder vernieuwen, zodat een verzoek nooit vertrekt met een token dat onderweg verloopt.
    pub fn needs_refresh(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.map(|e| (e - now).num_seconds() < 60).unwrap_or(false)
    }
}

/// Alles wat Nook voor één server bewaart (in de kluis, als JSON).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    pub server: ServerMetadata,
    pub client: Client,
    pub tokens: Tokens,
    pub resource: String,
    pub scope: Option<String>,
    /// Het terugkeeradres waarmee deze client geregistreerd is.
    #[serde(default)]
    pub redirect_uri: Option<String>,
}

pub fn is_secure(url: &url::Url) -> bool {
    let host = url.host_str().unwrap_or("").to_lowercase();
    url.scheme() == "https" || (url.scheme() == "http" && (host == "localhost" || host == "127.0.0.1"))
}

/// Het adres van de server zoals OAuth het noemt: kleine letters, geen query, fragment of slash aan het eind.
pub fn canonical_resource(url: &url::Url) -> String {
    let mut u = url.clone();
    u.set_query(None);
    u.set_fragment(None);
    let mut text = u.to_string();
    if text.ends_with('/') {
        text.pop();
    }
    text
}

/// Een parameter uit `WWW-Authenticate: Bearer resource_metadata="…", scope="…"`.
pub fn authenticate_parameter(name: &str, header: &str) -> Option<String> {
    let re = regex::Regex::new(&format!(r#"(?i){}\s*=\s*(?:"([^"]*)"|([^\s,]+))"#, regex::escape(name))).ok()?;
    let caps = re.captures(header)?;
    caps.get(1).or_else(|| caps.get(2)).map(|m| m.as_str().to_string())
}

pub fn origin(url: &url::Url) -> Option<String> {
    let host = url.host_str()?.to_lowercase();
    Some(format!("{}://{}{}", url.scheme(), host, url.port().map(|p| format!(":{p}")).unwrap_or_default()))
}

/// Waar de metadata van de server kan staan als hij het niet zegt: eerst met het pad, dan in de root.
pub fn resource_metadata_candidates(server: &url::Url) -> Vec<String> {
    let Some(origin) = origin(server) else { return vec![] };
    let path = if server.path() == "/" { "" } else { server.path() };
    let mut out = vec![];
    if !path.is_empty() {
        out.push(format!("{origin}/.well-known/oauth-protected-resource{path}"));
    }
    out.push(format!("{origin}/.well-known/oauth-protected-resource"));
    out
}

/// Waar de metadata van een autorisatieserver kan staan (RFC 8414 sectie 3, dan OpenID Connect discovery).
pub fn server_metadata_candidates(issuer: &url::Url) -> Vec<String> {
    let Some(origin) = origin(issuer) else { return vec![] };
    let path = issuer.path().trim_end_matches('/');
    if path.is_empty() {
        vec![format!("{origin}/.well-known/oauth-authorization-server"), format!("{origin}/.well-known/openid-configuration")]
    } else {
        vec![
            format!("{origin}/.well-known/oauth-authorization-server{path}"),
            format!("{origin}/.well-known/openid-configuration{path}"),
            format!("{origin}{path}/.well-known/openid-configuration"),
        ]
    }
}

pub fn authorization_url(
    server: &ServerMetadata,
    client: &Client,
    pkce: &Pkce,
    state: &str,
    resource: &str,
    scope: Option<&str>,
    redirect: &str,
) -> Option<String> {
    let mut url = url::Url::parse(&server.authorization_endpoint).ok()?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("response_type", "code")
            .append_pair("client_id", &client.id)
            .append_pair("redirect_uri", redirect)
            .append_pair("code_challenge", &pkce.challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", state)
            .append_pair("resource", resource);
        if let Some(scope) = scope.filter(|s| !s.is_empty()) {
            q.append_pair("scope", scope);
        }
    }
    Some(url.to_string())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Callback {
    Code(String),
    Failed(OAuthError),
}

/// Controleert het adres waarop de browser terugkwam: alleen Nooks eigen terugkeeradres, met de state die Nook voor
/// deze poging maakte (en de verwachte issuer als de server die noemt).
pub fn parse_callback(callback: &str, expected_state: &str, issuer: Option<&str>, redirect: &str) -> Callback {
    let (Ok(got), Ok(want)) = (url::Url::parse(callback), url::Url::parse(redirect)) else {
        return Callback::Failed(OAuthError::Callback("unexpected redirect".into()));
    };
    if got.scheme() != want.scheme() || got.host_str() != want.host_str() || got.port() != want.port() || got.path() != want.path() {
        return Callback::Failed(OAuthError::Callback("unexpected redirect".into()));
    }
    let value = |name: &str| got.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.to_string());
    match value("state") {
        Some(state) if constant_time_eq(&state, expected_state) => {}
        _ => return Callback::Failed(OAuthError::StateMismatch),
    }
    if let Some(error) = value("error") {
        if error == "access_denied" {
            return Callback::Failed(OAuthError::Declined);
        }
        return Callback::Failed(OAuthError::Callback(value("error_description").unwrap_or(error)));
    }
    if let (Some(iss), Some(issuer)) = (value("iss"), issuer) {
        if iss != issuer {
            return Callback::Failed(OAuthError::Callback("issuer mismatch".into()));
        }
    }
    match value("code").filter(|c| !c.is_empty()) {
        Some(code) => Callback::Code(code),
        None => Callback::Failed(OAuthError::Callback("no code".into())),
    }
}

/// Leest een token-antwoord. Een vernieuwing zonder nieuw refresh-token houdt het vorige.
pub fn tokens_from(json: &Value, previous_refresh: Option<&str>, now: DateTime<Utc>) -> Result<Tokens, OAuthError> {
    let Some(access) = json["access_token"].as_str().filter(|a| !a.is_empty()) else {
        if let Some(error) = json["error"].as_str() {
            if error == "invalid_grant" {
                return Err(OAuthError::Expired);
            }
            return Err(OAuthError::Token(json["error_description"].as_str().unwrap_or(error).to_string()));
        }
        return Err(OAuthError::Token("no access token".into()));
    };
    if let Some(kind) = json["token_type"].as_str() {
        if !kind.eq_ignore_ascii_case("bearer") {
            return Err(OAuthError::Token(format!("unsupported token type {kind}")));
        }
    }
    let seconds = super::float(&json["expires_in"]);
    Ok(Tokens {
        access_token: access.to_string(),
        refresh_token: json["refresh_token"].as_str().map(str::to_string).or_else(|| previous_refresh.map(str::to_string)),
        expires_at: seconds.map(|s| now + chrono::Duration::milliseconds((s * 1000.0) as i64)),
    })
}

/// `application/x-www-form-urlencoded`, alles behalve de onbeperkte tekens gecodeerd.
pub fn form_body(items: &[(&str, &str)]) -> String {
    fn enc(s: &str) -> String {
        s.bytes()
            .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
            .collect()
    }
    items.iter().map(|(k, v)| format!("{}={}", enc(k), enc(v))).collect::<Vec<_>>().join("&")
}

// Netwerk

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Discovery {
    pub server: ServerMetadata,
    pub resource: String,
    pub scope: Option<String>,
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent("Nook")
        .build()
        .unwrap_or_default()
}

async fn get_json(url: &str) -> Option<Value> {
    let response = client()
        .get(url)
        .header("Accept", "application/json")
        .header("MCP-Protocol-Version", super::mcp::PROTOCOL_VERSION)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json().await.ok()
}

/// Wat Nook over een server moet weten voor hij de browser opent. `None`: de server vraagt geen inlog.
pub async fn discover(server: &str) -> Result<Option<Discovery>, OAuthError> {
    let url = url::Url::parse(server).map_err(|_| OAuthError::Insecure)?;
    if !is_secure(&url) {
        return Err(OAuthError::Insecure);
    }
    let probe = client()
        .post(server)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .body(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Nook","version":"1.0"}}}"#)
        .send()
        .await
        .map_err(|_| OAuthError::NoAuthorizationServer)?;
    let status = probe.status().as_u16();
    if status != 401 && status != 403 {
        return Ok(None);
    }
    let header = probe.headers().get("www-authenticate").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let mut candidates = resource_metadata_candidates(&url);
    if let Some(hinted) = authenticate_parameter("resource_metadata", &header) {
        if url::Url::parse(&hinted).map(|u| is_secure(&u)).unwrap_or(false) {
            candidates.insert(0, hinted);
        }
    }
    let mut metadata = None;
    for c in candidates {
        if let Some(found) = get_json(&c).await.as_ref().and_then(ResourceMetadata::parse) {
            metadata = Some(found);
            break;
        }
    }
    // Oudere servers (spec 2025-03-26) hebben geen resource-metadata: hun eigen origin is de autorisatieserver.
    let issuer_text = metadata
        .as_ref()
        .and_then(|m| m.authorization_servers.first().cloned())
        .or_else(|| origin(&url))
        .ok_or(OAuthError::NoAuthorizationServer)?;
    let issuer = url::Url::parse(&issuer_text).map_err(|_| OAuthError::NoAuthorizationServer)?;
    if !is_secure(&issuer) {
        return Err(OAuthError::NoAuthorizationServer);
    }
    let mut server_meta = None;
    for c in server_metadata_candidates(&issuer) {
        if let Some(found) = get_json(&c).await.and_then(|j| ServerMetadata::parse(&j, &issuer_text)) {
            server_meta = Some(found);
            break;
        }
    }
    let server_meta = server_meta.ok_or(OAuthError::NoAuthorizationServer)?;
    if !server_meta.is_secure() {
        return Err(OAuthError::Insecure);
    }
    if !server_meta.supports_s256() {
        return Err(OAuthError::NoPkce);
    }
    let canonical = canonical_resource(&url);
    // De eigen naam van de server, als die bij dezelfde origin hoort; nooit een vreemde.
    let resource = metadata
        .as_ref()
        .and_then(|m| m.resource.clone())
        .filter(|declared| url::Url::parse(declared).ok().and_then(|d| origin(&d)) == origin(&url))
        .unwrap_or(canonical);
    let scope = authenticate_parameter("scope", &header).or_else(|| metadata.map(|m| m.scopes.join(" ")).filter(|s| !s.is_empty()));
    Ok(Some(Discovery { server: server_meta, resource, scope }))
}

/// Registreert Nook als publieke client (zonder geheim) met dit terugkeeradres.
pub async fn register(server: &ServerMetadata, redirect: &str) -> Result<Client, OAuthError> {
    let endpoint = server.registration_endpoint.clone().ok_or(OAuthError::NoRegistration)?;
    let response = client()
        .post(&endpoint)
        .header("Accept", "application/json")
        .json(&json!({
            "client_name": "Nook",
            "client_uri": "https://github.com/IAMichan/nook",
            "redirect_uris": [redirect],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        }))
        .send()
        .await
        .map_err(|e| OAuthError::Registration(e.to_string()))?;
    let ok = response.status().is_success();
    let json: Value = response.json().await.unwrap_or_default();
    match json["client_id"].as_str().filter(|id| ok && !id.is_empty()) {
        Some(id) => Ok(Client { id: id.into(), secret: json["client_secret"].as_str().map(str::to_string) }),
        None => {
            Err(OAuthError::Registration(json["error_description"].as_str().or(json["error"].as_str()).unwrap_or("no client id").into()))
        }
    }
}

async fn token_request(
    server: &ServerMetadata,
    client_info: &Client,
    mut items: Vec<(&str, String)>,
    previous_refresh: Option<&str>,
) -> Result<Tokens, OAuthError> {
    let endpoint = url::Url::parse(&server.token_endpoint).map_err(|_| OAuthError::Insecure)?;
    if !is_secure(&endpoint) {
        return Err(OAuthError::Insecure);
    }
    items.push(("client_id", client_info.id.clone()));
    if let Some(secret) = client_info.secret.as_ref().filter(|s| !s.is_empty()) {
        items.push(("client_secret", secret.clone()));
    }
    let pairs: Vec<(&str, &str)> = items.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let response = client()
        .post(endpoint)
        .header("Accept", "application/json")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form_body(&pairs))
        .send()
        .await
        .map_err(|e| OAuthError::Token(e.to_string()))?;
    let status = response.status().as_u16();
    let json: Value = response.json().await.unwrap_or_default();
    // Een geweigerd refresh-token gaat niet meer werken: opnieuw inloggen.
    if previous_refresh.is_some() && (status == 400 || status == 401) {
        return Err(OAuthError::Expired);
    }
    if !(200..300).contains(&status) {
        if json["error"].as_str() == Some("invalid_grant") {
            return Err(OAuthError::Expired);
        }
        return Err(OAuthError::Token(
            json["error_description"].as_str().or(json["error"].as_str()).map(str::to_string).unwrap_or(format!("HTTP {status}")),
        ));
    }
    tokens_from(&json, previous_refresh, Utc::now())
}

/// Ruilt de code voor tokens; de PKCE-verifier bewijst dat Nook deze inlog begon.
pub async fn exchange(
    code: &str,
    verifier: &str,
    server: &ServerMetadata,
    client_info: &Client,
    resource: &str,
    redirect: &str,
) -> Result<Tokens, OAuthError> {
    let items = vec![
        ("grant_type", "authorization_code".to_string()),
        ("code", code.to_string()),
        ("redirect_uri", redirect.to_string()),
        ("code_verifier", verifier.to_string()),
        ("resource", resource.to_string()),
    ];
    token_request(server, client_info, items, None).await
}

/// Een nieuw toegangstoken met het refresh-token.
pub async fn refresh(credentials: &Credentials) -> Result<Tokens, OAuthError> {
    let refresh_token = credentials.tokens.refresh_token.clone().ok_or(OAuthError::Expired)?;
    let items = vec![
        ("grant_type", "refresh_token".to_string()),
        ("refresh_token", refresh_token.clone()),
        ("resource", credentials.resource.clone()),
    ];
    token_request(&credentials.server, &credentials.client, items, Some(&refresh_token)).await
}

/// Vraagt de dienst een token te vergeten (RFC 7009) bij ontkoppelen. Naar best vermogen: de kopie in de kluis gaat hoe dan ook weg.
pub async fn revoke(credentials: &Credentials) {
    let Some(endpoint) = credentials.server.revocation_endpoint.clone() else { return };
    if !url::Url::parse(&endpoint).map(|u| is_secure(&u)).unwrap_or(false) {
        return;
    }
    for (token, hint) in
        [(credentials.tokens.refresh_token.clone(), "refresh_token"), (Some(credentials.tokens.access_token.clone()), "access_token")]
    {
        let Some(token) = token else { continue };
        let mut items = vec![("token", token.as_str()), ("token_type_hint", hint), ("client_id", credentials.client.id.as_str())];
        if let Some(secret) = credentials.client.secret.as_deref() {
            items.push(("client_secret", secret));
        }
        let _ = client()
            .post(&endpoint)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form_body(&items))
            .timeout(Duration::from_secs(10))
            .send()
            .await;
    }
}

// Bewaren en vernieuwen

pub fn load(env: &Env, account: &str) -> Option<Credentials> {
    env.secrets.read(account).and_then(|t| serde_json::from_str(&t).ok())
}

pub fn save(env: &Env, account: &str, credentials: &Credentials) -> CResult<()> {
    let text = serde_json::to_string(credentials).map_err(|e| ConnectorError::new(e.to_string()))?;
    env.secrets
        .write(account, &text)
        .map_err(|_| ConnectorError::kind("De kluis weigerde de inloggegevens op te slaan. Probeer het opnieuw.", ErrorKind::Config))
}

/// Geeft het transport een geldig token. Eén vernieuwing tegelijk per server, zodat twee verzoeken die allebei een
/// verlopen token zien niet elk het (eenmalige) refresh-token opmaken.
pub struct OAuthAuthorizer {
    env: Arc<Env>,
    account: String,
    lock: tokio::sync::Mutex<()>,
}

impl OAuthAuthorizer {
    pub fn new(env: Arc<Env>, account: String) -> Self {
        Self { env, account, lock: tokio::sync::Mutex::new(()) }
    }
}

#[async_trait::async_trait]
impl Authorizer for OAuthAuthorizer {
    async fn bearer_token(&self, force_refresh: bool) -> CResult<String> {
        let before = load(&self.env, &self.account).ok_or(OAuthError::NotSignedIn)?;
        if !force_refresh && !before.tokens.needs_refresh(Utc::now()) {
            return Ok(before.tokens.access_token);
        }
        let _guard = self.lock.lock().await;
        let current = load(&self.env, &self.account).ok_or(OAuthError::NotSignedIn)?;
        // Een ander verzoek vernieuwde net: dat token gebruiken.
        if current.tokens.access_token != before.tokens.access_token && !current.tokens.needs_refresh(Utc::now()) {
            return Ok(current.tokens.access_token);
        }
        let mut updated = current.clone();
        updated.tokens = refresh(&current).await?;
        save(&self.env, &self.account, &updated)?;
        Ok(updated.tokens.access_token)
    }
}

// Terugkeren in de browser

/// Een luisteraar op 127.0.0.1 voor één terugkeer uit de browser.
pub struct Loopback {
    listener: TcpListener,
    pub redirect: String,
}

/// Vaste poorten eerst, zodat een eerdere registratie (met dat adres) bruikbaar blijft.
const PORTS: [u16; 3] = [33418, 33419, 33420];

impl Loopback {
    pub async fn bind() -> CResult<Self> {
        for port in PORTS {
            if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)).await {
                return Ok(Self { listener, redirect: format!("http://127.0.0.1:{port}/callback") });
            }
        }
        let listener =
            TcpListener::bind(("127.0.0.1", 0)).await.map_err(|e| ConnectorError::new(format!("Kon niet luisteren op 127.0.0.1: {e}")))?;
        let port = listener.local_addr().map_err(|e| ConnectorError::new(e.to_string()))?.port();
        Ok(Self { listener, redirect: format!("http://127.0.0.1:{port}/callback") })
    }

    /// Wacht op de browser (hooguit `timeout`) en geeft het volledige terugkeeradres. Andere paden krijgen een 404.
    pub async fn wait(self, timeout: Duration) -> Result<String, OAuthError> {
        let base = self.redirect.trim_end_matches("/callback").to_string();
        let accept = async {
            loop {
                let Ok((mut socket, peer)) = self.listener.accept().await else { continue };
                if !peer.ip().is_loopback() {
                    continue;
                }
                let mut buf = vec![0u8; 8192];
                let n = tokio::time::timeout(Duration::from_secs(5), socket.read(&mut buf)).await.ok().and_then(|r| r.ok()).unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = head.lines().next().and_then(|l| l.split(' ').nth(1)).unwrap_or("").to_string();
                if !path.starts_with("/callback") {
                    let _ = socket.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                    continue;
                }
                let page = "<!doctype html><meta charset=utf-8><title>Nook</title><body style=\"font-family:system-ui;background:#16161b;color:#f4f3f7;display:grid;place-items:center;height:90vh\"><div><h2>Klaar</h2><p>Je kunt dit venster sluiten en terug naar Nook.</p></div>";
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
                    page.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
                return format!("{base}{path}");
            }
        };
        tokio::time::timeout(timeout, accept).await.map_err(|_| OAuthError::Cancelled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REDIRECT: &str = "http://127.0.0.1:33418/callback";

    fn server() -> ServerMetadata {
        ServerMetadata {
            issuer: "https://auth.example.com".into(),
            authorization_endpoint: "https://auth.example.com/authorize".into(),
            token_endpoint: "https://auth.example.com/token".into(),
            registration_endpoint: Some("https://auth.example.com/register".into()),
            revocation_endpoint: None,
            code_challenge_methods: Some(vec!["S256".into()]),
            scopes: None,
        }
    }

    #[test]
    fn challenge_matches_the_rfc_example() {
        assert_eq!(Pkce::challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn verifiers_are_long_url_safe_and_unique() {
        let (a, b) = (Pkce::make(), Pkce::make());
        assert_ne!(a.verifier, b.verifier);
        assert_eq!(a.verifier.len(), 43);
        assert!(a.verifier.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
        assert_eq!(a.challenge, Pkce::challenge(&a.verifier));
    }

    #[test]
    fn authorization_url_carries_pkce_state_and_resource() {
        let pkce = Pkce::make();
        let url = authorization_url(
            &server(),
            &Client { id: "client+1".into(), secret: None },
            &pkce,
            "s1",
            "https://mcp.example.com/mcp",
            Some("read write"),
            REDIRECT,
        )
        .unwrap();
        let parsed = url::Url::parse(&url).unwrap();
        let q: std::collections::HashMap<String, String> = parsed.query_pairs().into_owned().collect();
        assert_eq!(q["response_type"], "code");
        assert_eq!(q["client_id"], "client+1");
        assert_eq!(q["redirect_uri"], REDIRECT);
        assert_eq!(q["code_challenge"], pkce.challenge);
        assert_eq!(q["code_challenge_method"], "S256");
        assert_eq!(q["state"], "s1");
        assert_eq!(q["resource"], "https://mcp.example.com/mcp");
        assert_eq!(q["scope"], "read write");
        assert!(!url.contains("client+1"), "a literal + would be read as a space");
    }

    #[test]
    fn callbacks() {
        let ok = format!("{REDIRECT}?code=abc&state=xyz");
        assert_eq!(parse_callback(&ok, "xyz", None, REDIRECT), Callback::Code("abc".into()));
        assert_eq!(
            parse_callback(&format!("{REDIRECT}?code=abc&state=forged"), "xyz", None, REDIRECT),
            Callback::Failed(OAuthError::StateMismatch)
        );
        assert_eq!(parse_callback(&format!("{REDIRECT}?code=abc"), "xyz", None, REDIRECT), Callback::Failed(OAuthError::StateMismatch));
        assert_eq!(
            parse_callback(&format!("{REDIRECT}?error=access_denied&state=xyz"), "xyz", None, REDIRECT),
            Callback::Failed(OAuthError::Declined)
        );
        assert!(matches!(
            parse_callback("http://127.0.0.1:33418/evil?code=abc&state=xyz", "xyz", None, REDIRECT),
            Callback::Failed(OAuthError::Callback(_))
        ));
        assert!(matches!(
            parse_callback("http://127.0.0.1:9999/callback?code=abc&state=xyz", "xyz", None, REDIRECT),
            Callback::Failed(OAuthError::Callback(_))
        ));
        let other_issuer = format!("{REDIRECT}?code=abc&state=xyz&iss=https://other.example.com");
        assert!(matches!(
            parse_callback(&other_issuer, "xyz", Some("https://auth.example.com"), REDIRECT),
            Callback::Failed(OAuthError::Callback(_))
        ));
        let good = format!("{REDIRECT}?code=abc&state=xyz&iss=https://auth.example.com");
        assert_eq!(parse_callback(&good, "xyz", Some("https://auth.example.com"), REDIRECT), Callback::Code("abc".into()));
    }

    #[test]
    fn token_responses() {
        let now = Utc::now();
        let t = tokens_from(&json!({"access_token": "a", "refresh_token": "r", "expires_in": 3600, "token_type": "Bearer"}), None, now)
            .unwrap();
        assert_eq!((t.access_token.as_str(), t.refresh_token.as_deref()), ("a", Some("r")));
        assert!(!t.needs_refresh(now));
        assert!(t.needs_refresh(now + chrono::Duration::seconds(3570)));
        assert_eq!(
            tokens_from(&json!({"access_token": "a2", "expires_in": 60}), Some("r1"), now).unwrap().refresh_token.as_deref(),
            Some("r1")
        );
        assert_eq!(tokens_from(&json!({"error": "invalid_grant"}), None, now), Err(OAuthError::Expired));
        assert!(tokens_from(&json!({"access_token": "a", "token_type": "mac"}), None, now).is_err());
    }

    #[test]
    fn discovery_helpers() {
        let header = r#"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read""#;
        assert_eq!(
            authenticate_parameter("resource_metadata", header).as_deref(),
            Some("https://mcp.example.com/.well-known/oauth-protected-resource")
        );
        assert_eq!(authenticate_parameter("scope", header).as_deref(), Some("files:read"));
        assert_eq!(authenticate_parameter("missing", header), None);
        let u = |s: &str| url::Url::parse(s).unwrap();
        assert_eq!(
            resource_metadata_candidates(&u("https://mcp.example.com/mcp")),
            [
                "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                "https://mcp.example.com/.well-known/oauth-protected-resource"
            ]
        );
        assert_eq!(
            server_metadata_candidates(&u("https://auth.example.com")),
            [
                "https://auth.example.com/.well-known/oauth-authorization-server",
                "https://auth.example.com/.well-known/openid-configuration"
            ]
        );
        let tenant = server_metadata_candidates(&u("https://auth.example.com/tenant1"));
        assert_eq!(tenant[0], "https://auth.example.com/.well-known/oauth-authorization-server/tenant1");
        assert_eq!(tenant.len(), 3);
        assert_eq!(canonical_resource(&u("HTTPS://MCP.Example.com/mcp/?x=1#f")), "https://mcp.example.com/mcp");
        assert_eq!(canonical_resource(&u("https://mcp.example.com:8443")), "https://mcp.example.com:8443");
    }

    #[test]
    fn server_metadata_rules() {
        let s = server();
        assert!(s.is_secure() && s.supports_s256());
        let mut plain = s.clone();
        plain.code_challenge_methods = Some(vec!["plain".into()]);
        assert!(!plain.supports_s256());
        let mut insecure = s.clone();
        insecure.token_endpoint = "http://auth.example.com/token".into();
        assert!(!insecure.is_secure());
        let parsed = ServerMetadata::parse(
            &json!({"authorization_endpoint": "https://a/authorize", "token_endpoint": "https://a/token"}),
            "https://a",
        )
        .unwrap();
        assert_eq!(parsed.issuer, "https://a");
        assert!(ServerMetadata::parse(&json!({"token_endpoint": "https://a/token"}), "https://a").is_none());
    }

    #[test]
    fn form_body_encodes_reserved_characters() {
        assert_eq!(
            form_body(&[("code", "a+b/c=d&e"), ("redirect_uri", "nook://oauth/callback")]),
            "code=a%2Bb%2Fc%3Dd%26e&redirect_uri=nook%3A%2F%2Foauth%2Fcallback"
        );
        assert!(constant_time_eq("abc", "abc"));
        assert!(!constant_time_eq("abc", "abd"));
        assert!(!constant_time_eq("abc", "abcd"));
    }

    #[tokio::test]
    async fn loopback_catches_the_browser() {
        let loopback = Loopback::bind().await.unwrap();
        let redirect = loopback.redirect.clone();
        let target = format!("{redirect}?code=c1&state=s1");
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let _ = reqwest::get(target.replace("/callback", "/other")).await;
            let _ = reqwest::get(target).await;
        });
        let got = loopback.wait(Duration::from_secs(5)).await.unwrap();
        assert_eq!(parse_callback(&got, "s1", None, &redirect), Callback::Code("c1".into()));
    }
}
