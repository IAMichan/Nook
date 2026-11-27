//! Deploying Nook's companion relay to the user's own Cloudflare account from Settings (`CloudflareRelaySetup` and
//! `CloudflareRelayDeployer` on the Mac, CO-08).
//!
//! No command line or `wrangler` install is needed: Nook embeds the Worker ES modules from `apps/relay/worker`,
//! uploads them with one scoped Cloudflare API token, enables the account's `workers.dev` route, and waits until
//! `/health` answers `Nook relay`.

use std::fmt::Write as _;
use std::time::Duration;

use rand::TryRng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Worker name on the user's Cloudflare account.
pub const SCRIPT_NAME: &str = "nook-relay";
/// Cloudflare Workers compatibility date (matches macOS `CloudflareRelaySetup.compatibilityDate`).
pub const COMPATIBILITY_DATE: &str = "2025-06-01";
/// Cloudflare v4 API base URL.
pub const API_BASE: &str = "https://api.cloudflare.com/client/v4";
/// Vault account name where the Cloudflare API token is stored so Nook can quietly keep the relay up to date.
pub const TOKEN_ACCOUNT: &str = "companion.relay.cloudflareToken";

/// The Worker ES modules shipped inside Nook, straight from `apps/relay/worker`; `index.js` is the entry point.
pub const BUNDLED_MODULES: &[(&str, &[u8])] = &[
    ("index.js", include_bytes!("../../../../relay/worker/index.js")),
    ("mux.js", include_bytes!("../../../../relay/worker/mux.js")),
    ("room.js", include_bytes!("../../../../relay/worker/room.js")),
    ("push.js", include_bytes!("../../../../relay/worker/push.js")),
    ("hooks.js", include_bytes!("../../../../relay/worker/hooks.js")),
    ("guest.js", include_bytes!("../../../../relay/worker/guest.js")),
    ("mcp.js", include_bytes!("../../../../relay/worker/mcp.js")),
];

/// Progress steps reported while deploying the relay to Cloudflare (`CloudflareRelayDeployer.Step`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeployStep {
    Account,
    Uploading,
    Starting,
}

/// Structured failure from Cloudflare deployment so the Settings UI translates each cause cleanly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum DeployError {
    BadToken,
    NoAccount,
    SeveralAccounts,
    NoSubdomain,
    NoAnswer,
    Cloudflare(String),
    Network(String),
}

impl std::fmt::Display for DeployError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadToken => write!(f, "Cloudflare did not accept this token."),
            Self::NoAccount => write!(f, "The token cannot see a Cloudflare account."),
            Self::SeveralAccounts => write!(f, "This token can see several Cloudflare accounts."),
            Self::NoSubdomain => write!(f, "Cloudflare did not give your account a workers.dev address."),
            Self::NoAnswer => write!(f, "The relay is set up but does not answer yet."),
            Self::Cloudflare(msg) | Self::Network(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for DeployError {}

/// Live setup status shown by Settings › Companion › Away from home › Your own relay.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum RelaySetupState {
    #[default]
    Idle,
    Working {
        step: DeployStep,
    },
    Failed {
        error: DeployError,
    },
}

/// Outcome of a successful Cloudflare deployment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeployedRelay {
    pub address: String,
    pub account: String,
    pub version: String,
}

/// Configuration for [`deploy`]; defaults target production Cloudflare, tests override base URL and polling.
#[derive(Debug, Clone)]
pub struct DeployOptions {
    pub api_base: String,
    /// When set (tests), `/health` is checked against this base URL instead of the generated `workers.dev` URL.
    pub health_base_override: Option<String>,
    pub health_attempts: usize,
    pub health_interval: Duration,
}

impl Default for DeployOptions {
    fn default() -> Self {
        Self { api_base: API_BASE.to_string(), health_base_override: None, health_attempts: 40, health_interval: Duration::from_secs(3) }
    }
}

/// Cloudflare's page to create an API token with the relay's exact permissions pre-filled (`workers_scripts: edit`,
/// `account_settings: read`). The user only signs in, confirms, and copies the token.
pub fn token_page() -> String {
    let mut url = url::Url::parse("https://dash.cloudflare.com/profile/api-tokens").expect("valid static URL");
    url.query_pairs_mut()
        .append_pair("permissionGroupKeys", r#"[{"key":"workers_scripts","type":"edit"},{"key":"account_settings","type":"read"}]"#)
        .append_pair("name", "Nook relay")
        .append_pair("accountId", "*")
        .append_pair("zoneId", "all");
    url.to_string()
}

/// The Worker's upload metadata: entry point, Durable Object namespace `ROOMS` (`Room`), and (on first deploy)
/// the SQLite Durable Object migration. Cloudflare refuses the migration once it has already run, so updates
/// retry with `with_migration = false`.
pub fn metadata(with_migration: bool) -> Vec<u8> {
    let mut map = serde_json::Map::new();
    map.insert("bindings".into(), json!([{ "type": "durable_object_namespace", "name": "ROOMS", "class_name": "Room" }]));
    map.insert("compatibility_date".into(), json!(COMPATIBILITY_DATE));
    map.insert("main_module".into(), json!("index.js"));
    if with_migration {
        map.insert("migrations".into(), json!({ "new_tag": "v1", "new_sqlite_classes": ["Room"] }));
    }
    serde_json::to_vec(&Value::Object(map)).unwrap_or_default()
}

/// Multipart upload body for a Cloudflare ES-module Worker: `metadata` JSON part followed by one JS module per file.
pub fn multipart(metadata_bytes: &[u8], modules: &[(&str, &[u8])], boundary: &str) -> Vec<u8> {
    let mut body = Vec::new();
    let append_part = |buf: &mut Vec<u8>, name: &str, filename: Option<&str>, content_type: &str, content: &[u8]| {
        buf.extend_from_slice(b"--");
        buf.extend_from_slice(boundary.as_bytes());
        buf.extend_from_slice(b"\r\nContent-Disposition: form-data; name=\"");
        buf.extend_from_slice(name.as_bytes());
        buf.extend_from_slice(b"\"");
        if let Some(file) = filename {
            buf.extend_from_slice(b"; filename=\"");
            buf.extend_from_slice(file.as_bytes());
            buf.extend_from_slice(b"\"");
        }
        buf.extend_from_slice(b"\r\nContent-Type: ");
        buf.extend_from_slice(content_type.as_bytes());
        buf.extend_from_slice(b"\r\n\r\n");
        buf.extend_from_slice(content);
        buf.extend_from_slice(b"\r\n");
    };
    append_part(&mut body, "metadata", None, "application/json", metadata_bytes);
    for (name, content) in modules {
        append_part(&mut body, name, Some(name), "application/javascript+module", content);
    }
    body.extend_from_slice(b"--");
    body.extend_from_slice(boundary.as_bytes());
    body.extend_from_slice(b"--\r\n");
    body
}

/// The relay's URL on the account's `workers.dev` subdomain.
pub fn address(subdomain: &str) -> String {
    format!("https://{SCRIPT_NAME}.{subdomain}.workers.dev")
}

/// A fresh `workers.dev` subdomain for an account that does not have one yet: `"nook-"` plus 6 random lowercase
/// alphanumeric characters.
pub fn new_subdomain() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut bytes = [0u8; 6];
    let _ = rand::rngs::SysRng.try_fill_bytes(&mut bytes);
    let mut out = String::from("nook-");
    for b in bytes {
        out.push(ALPHABET[(b as usize) % ALPHABET.len()] as char);
    }
    out
}

/// Stable 16-hex fingerprint of the Worker modules (`CloudflareRelaySetup.version`), so Nook knows when a
/// managed relay needs an update after a Nook upgrade.
pub fn version(modules: &[(&str, &[u8])]) -> String {
    let mut hasher = Sha256::new();
    for (name, content) in modules {
        hasher.update(name.as_bytes());
        hasher.update([0u8]);
        hasher.update(content);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(16);
    for byte in &digest[..8] {
        let _ = write!(&mut hex, "{byte:02x}");
    }
    hex
}

/// Version string of the Worker modules embedded in this build.
pub fn bundled_version() -> String {
    version(BUNDLED_MODULES)
}

/// Checks whether the relay at `base` responds `200 OK` with a body starting with `"Nook relay"` on `/health`.
pub async fn answers(http: &reqwest::Client, base: &str) -> bool {
    let url = format!("{}/health", base.trim_end_matches('/'));
    let Ok(resp) = http.get(url).timeout(Duration::from_secs(5)).send().await else { return false };
    if resp.status().as_u16() != 200 {
        return false;
    }
    resp.text().await.is_ok_and(|body| body.starts_with("Nook relay"))
}

/// Deploys (or updates) Nook's Worker on the Cloudflare account associated with `token`.
///
/// When `preferred_account` is `Some`, deployment targets that exact account (used for automatic updates so a
/// multi-account token never guesses).
pub async fn deploy<F>(
    token: &str,
    preferred_account: Option<&str>,
    options: &DeployOptions,
    mut on_progress: F,
) -> Result<DeployedRelay, DeployError>
where
    F: FnMut(DeployStep),
{
    let token = token.trim();
    if token.is_empty() {
        return Err(DeployError::BadToken);
    }
    let http = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap_or_default();
    let api_base = options.api_base.trim_end_matches('/');

    on_progress(DeployStep::Account);
    let accounts_val = cf_json(&http, api_base, token, reqwest::Method::GET, "/accounts?per_page=50", None).await?;
    let accounts: Vec<String> = accounts_val
        .as_array()
        .map(|items| items.iter().filter_map(|v| v.get("id").and_then(Value::as_str).map(String::from)).collect())
        .unwrap_or_default();

    let account = match preferred_account {
        Some(preferred) => {
            if accounts.iter().any(|a| a == preferred) {
                preferred.to_string()
            } else {
                return Err(DeployError::NoAccount);
            }
        }
        None => match accounts.len() {
            0 => return Err(DeployError::NoAccount),
            1 => accounts[0].clone(),
            _ => return Err(DeployError::SeveralAccounts),
        },
    };

    let subdomain_path = format!("/accounts/{account}/workers/subdomain");
    let mut subdomain = cf_json(&http, api_base, token, reqwest::Method::GET, &subdomain_path, None)
        .await
        .ok()
        .and_then(|v| v.get("subdomain").and_then(Value::as_str).map(String::from))
        .filter(|s| !s.is_empty());

    if subdomain.is_none() {
        let created =
            cf_json(&http, api_base, token, reqwest::Method::PUT, &subdomain_path, Some(json!({ "subdomain": new_subdomain() }))).await?;
        subdomain = created.get("subdomain").and_then(Value::as_str).map(String::from).filter(|s| !s.is_empty());
    }
    let Some(subdomain) = subdomain else {
        return Err(DeployError::NoSubdomain);
    };

    on_progress(DeployStep::Uploading);
    let script_path = format!("/accounts/{account}/workers/scripts/{SCRIPT_NAME}");
    let first_upload = cf_upload(&http, api_base, token, &script_path, &metadata(true), BUNDLED_MODULES).await;
    if let Err(err) = first_upload {
        let is_migration_err = match &err {
            DeployError::Cloudflare(msg) => msg.to_ascii_lowercase().contains("migration"),
            _ => false,
        };
        if is_migration_err {
            cf_upload(&http, api_base, token, &script_path, &metadata(false), BUNDLED_MODULES).await?;
        } else {
            return Err(err);
        }
    }

    let enable_path = format!("{script_path}/subdomain");
    cf_json(&http, api_base, token, reqwest::Method::POST, &enable_path, Some(json!({ "enabled": true, "previews_enabled": false })))
        .await?;

    on_progress(DeployStep::Starting);
    let relay_address = address(&subdomain);
    let health_target = options.health_base_override.as_deref().unwrap_or(&relay_address);
    let attempts = options.health_attempts.max(1);
    for attempt in 0..attempts {
        if answers(&http, health_target).await {
            return Ok(DeployedRelay { address: relay_address, account, version: bundled_version() });
        }
        if attempt + 1 < attempts && !options.health_interval.is_zero() {
            tokio::time::sleep(options.health_interval).await;
        }
    }
    Err(DeployError::NoAnswer)
}

async fn cf_json(
    http: &reqwest::Client,
    api_base: &str,
    token: &str,
    method: reqwest::Method,
    path: &str,
    body: Option<Value>,
) -> Result<Value, DeployError> {
    let mut req = http.request(method, format!("{api_base}{path}")).bearer_auth(token);
    if let Some(json_body) = body {
        req = req.json(&json_body);
    }
    parse_cf_response(req.send().await).await
}

async fn cf_upload(
    http: &reqwest::Client,
    api_base: &str,
    token: &str,
    path: &str,
    metadata_bytes: &[u8],
    modules: &[(&str, &[u8])],
) -> Result<Value, DeployError> {
    let mut nonce = [0u8; 8];
    let _ = rand::rngs::SysRng.try_fill_bytes(&mut nonce);
    let mut boundary = String::from("nook-");
    for byte in nonce {
        let _ = write!(&mut boundary, "{byte:02x}");
    }
    let payload = multipart(metadata_bytes, modules, &boundary);
    let req = http
        .put(format!("{api_base}{path}"))
        .bearer_auth(token)
        .header(reqwest::header::CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
        .body(payload);
    parse_cf_response(req.send().await).await
}

async fn parse_cf_response(response: Result<reqwest::Response, reqwest::Error>) -> Result<Value, DeployError> {
    let response = response.map_err(|e| DeployError::Network(e.to_string()))?;
    let status = response.status().as_u16();
    let data = response.bytes().await.map_err(|e| DeployError::Network(e.to_string()))?;
    if status == 401 || status == 403 {
        return Err(DeployError::BadToken);
    }
    let parsed: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
    if parsed.get("success").and_then(Value::as_bool) == Some(true) {
        return Ok(parsed.get("result").cloned().unwrap_or(Value::Null));
    }
    let errors: Vec<String> = parsed
        .get("errors")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(|e| e.get("message").and_then(Value::as_str).map(String::from)).collect())
        .unwrap_or_default();
    let message = if errors.is_empty() { format!("Cloudflare: HTTP {status}") } else { format!("Cloudflare: {}", errors.join("; ")) };
    Err(DeployError::Cloudflare(message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::transport::normalize_relay;
    use crate::connectors::testserver::TestServer;

    #[test]
    fn metadata_with_and_without_migration() {
        let first: Value = serde_json::from_slice(&metadata(true)).unwrap();
        assert_eq!(first["main_module"], "index.js");
        assert_eq!(first["bindings"][0]["name"], "ROOMS");
        assert_eq!(first["migrations"]["new_tag"], "v1");
        assert_eq!(first["migrations"]["new_sqlite_classes"], json!(["Room"]));

        let update: Value = serde_json::from_slice(&metadata(false)).unwrap();
        assert!(update.get("migrations").is_none());
    }

    #[test]
    fn multipart_contains_metadata_and_modules() {
        let body = String::from_utf8(multipart(b"{}", &[("index.js", b"export default {}")], "B")).unwrap();
        assert!(body.contains("name=\"metadata\""));
        assert!(body.contains("name=\"index.js\"; filename=\"index.js\""));
        assert!(body.contains("Content-Type: application/javascript+module"));
        assert!(body.ends_with("--B--\r\n"));
    }

    #[test]
    fn token_page_and_address_and_subdomain() {
        let page = token_page();
        assert!(page.starts_with("https://dash.cloudflare.com/profile/api-tokens?"));
        assert!(page.contains("workers_scripts"));
        assert!(page.contains("account_settings"));
        assert_eq!(address("me"), "https://nook-relay.me.workers.dev");
        let sub = new_subdomain();
        assert!(sub.starts_with("nook-"));
        assert_eq!(sub.len(), 11);
        assert!(normalize_relay(&address(&sub)).is_some());
    }

    #[test]
    fn version_changes_when_module_changes() {
        let a = version(&[("index.js", b"one")]);
        assert_eq!(a.len(), 16);
        assert_eq!(a, version(&[("index.js", b"one")]));
        assert_ne!(a, version(&[("index.js", b"two")]));
        assert_eq!(bundled_version().len(), 16);
        assert!(BUNDLED_MODULES.iter().all(|(_, bytes)| !bytes.is_empty()));
    }

    #[tokio::test]
    async fn deploy_creates_subdomain_uploads_and_checks_health() {
        let server = TestServer::start(vec![
            ("GET /accounts", 200, json!({ "success": true, "result": [{ "id": "acc-1" }] }).to_string()),
            ("GET /accounts/acc-1/workers/subdomain", 404, json!({ "success": false, "errors": [] }).to_string()),
            (
                "PUT /accounts/acc-1/workers/subdomain",
                200,
                json!({ "success": true, "result": { "subdomain": "nook-abc123" } }).to_string(),
            ),
            ("PUT /accounts/acc-1/workers/scripts/nook-relay", 200, json!({ "success": true, "result": {} }).to_string()),
            (
                "POST /accounts/acc-1/workers/scripts/nook-relay/subdomain",
                200,
                json!({ "success": true, "result": { "enabled": true } }).to_string(),
            ),
            ("GET /health", 200, "Nook relay\n".to_string()),
        ])
        .await;

        let base = format!("http://127.0.0.1:{}", server.port);
        let opts = DeployOptions {
            api_base: base.clone(),
            health_base_override: Some(base),
            health_attempts: 2,
            health_interval: Duration::from_millis(10),
        };

        let mut steps = Vec::new();
        let deployed = deploy("cf-token-123", None, &opts, |s| steps.push(s)).await.unwrap();
        assert_eq!(steps, vec![DeployStep::Account, DeployStep::Uploading, DeployStep::Starting]);
        assert_eq!(deployed.account, "acc-1");
        assert_eq!(deployed.address, "https://nook-relay.nook-abc123.workers.dev");
        assert_eq!(deployed.version, bundled_version());

        let received = server.received.lock().unwrap().clone();
        assert!(received.iter().any(|r| r.method == "PUT" && r.path == "/accounts/acc-1/workers/scripts/nook-relay"));
        assert!(received.iter().any(|r| r.method == "POST" && r.path == "/accounts/acc-1/workers/scripts/nook-relay/subdomain"));
        assert!(received.iter().any(|r| r.header("authorization") == Some("Bearer cf-token-123")));
    }

    #[tokio::test]
    async fn deploy_handles_bad_token_and_multiple_accounts() {
        let bad_server = TestServer::start(vec![("GET /accounts", 401, json!({ "success": false }).to_string())]).await;
        let opts = DeployOptions {
            api_base: format!("http://127.0.0.1:{}", bad_server.port),
            health_base_override: None,
            health_attempts: 1,
            health_interval: Duration::ZERO,
        };
        assert_eq!(deploy("wrong", None, &opts, |_| {}).await, Err(DeployError::BadToken));

        let multi_server = TestServer::start(vec![(
            "GET /accounts",
            200,
            json!({ "success": true, "result": [{ "id": "acc-1" }, { "id": "acc-2" }] }).to_string(),
        )])
        .await;
        let multi_opts = DeployOptions { api_base: format!("http://127.0.0.1:{}", multi_server.port), ..opts };
        assert_eq!(deploy("token", None, &multi_opts, |_| {}).await, Err(DeployError::SeveralAccounts));
    }
}
