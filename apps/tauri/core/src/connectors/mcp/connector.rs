//! Eén MCP-server als koppeling, en het beheer van de servers die de gebruiker toevoegde. Lees-tools draaien tijdens
//! een antwoord; elke andere tool is een actie die wacht op de goedkeuring van de gebruiker, net als Nooks eigen acties.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::Value;

use super::transport::{Authorizer, HttpTransport, McpTransport, StdioTransport};
use super::{McpClient, McpServerConfig, McpTool, Transport};
use crate::brain::LoopTool;
use crate::connectors::catalog::{self, SourceDescriptor, SourceKind};
use crate::connectors::hub::{Connector, Env, Scope};
use crate::connectors::oauth::{self, OAuthAuthorizer};
use crate::connectors::{short, CResult, ConnectorError, ConnectorItem, ConnectorState, ConnectorStatus, ConnectorStore, ErrorKind, Tone};

/// Diensten waarvan de officiële MCP-server een app laat inloggen zonder eigen client-id of geheim.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteService {
    pub id: &'static str,
    pub name: &'static str,
    pub url: &'static str,
    pub domain: &'static str,
    pub category: &'static str,
    pub tagline: &'static str,
}

pub const REMOTE_SERVICES: [RemoteService; 5] = [
    RemoteService {
        id: "notion",
        name: "Notion",
        url: "https://mcp.notion.com/mcp",
        domain: "notion.so",
        category: "work",
        tagline: "Pagina’s en databases die je deelt",
    },
    RemoteService {
        id: "linear",
        name: "Linear",
        url: "https://mcp.linear.app/mcp",
        domain: "linear.app",
        category: "work",
        tagline: "Issues, projecten en cycles",
    },
    RemoteService {
        id: "stripe",
        name: "Stripe",
        url: "https://mcp.stripe.com",
        domain: "stripe.com",
        category: "business",
        tagline: "Omzet, betalingen en klanten",
    },
    RemoteService {
        id: "vercel",
        name: "Vercel",
        url: "https://mcp.vercel.com",
        domain: "vercel.com",
        category: "development",
        tagline: "Deploys, builds en logs",
    },
    RemoteService {
        id: "sentry",
        name: "Sentry",
        url: "https://mcp.sentry.dev/mcp",
        domain: "sentry.io",
        category: "development",
        tagline: "Fouten en prestaties van je apps",
    },
];

// Beheer

pub fn servers(store: &ConnectorStore) -> Vec<McpServerConfig> {
    store.read(|c| c.mcp_servers.clone())
}

/// Voegt een server toe. `secrets` zijn omgevingsvariabelen (lokaal programma) of headers (https); ze gaan naar de kluis.
pub fn add(
    env: &Env,
    name: &str,
    transport: Transport,
    secrets: &[(String, String)],
    uses_oauth: bool,
    service_id: Option<&str>,
) -> CResult<McpServerConfig> {
    let name = name.trim();
    let base = crate::connectors::accounts::slug(if name.is_empty() { "mcp" } else { name });
    let config = env.store.update(|c| {
        let mut id = base.clone();
        let mut counter = 2;
        while c.mcp_servers.iter().any(|s| s.id == id) {
            id = format!("{base}{counter}");
            counter += 1;
        }
        let config = McpServerConfig {
            id,
            name: if name.is_empty() { "MCP-server".into() } else { name.into() },
            transport,
            secret_names: secrets.iter().filter(|(n, _)| !n.is_empty()).map(|(n, _)| n.clone()).collect(),
            enabled: true,
            uses_oauth: uses_oauth.then_some(true),
            service_id: service_id.map(str::to_string),
        };
        c.mcp_servers.push(config.clone());
        config
    });
    for (secret, value) in secrets.iter().filter(|(n, _)| !n.is_empty()) {
        env.secrets.write(&config.secret_key(secret), value).map_err(ConnectorError::new)?;
    }
    Ok(config)
}

pub fn set_enabled(store: &ConnectorStore, id: &str, enabled: bool) {
    store.update(|c| {
        if let Some(s) = c.mcp_servers.iter_mut().find(|s| s.id == id) {
            s.enabled = enabled;
        }
    });
}

/// Verwijdert een server met zijn sleutels en inlog uit de kluis.
pub fn remove(env: &Env, id: &str) {
    let Some(config) = servers(&env.store).into_iter().find(|s| s.id == id) else { return };
    for name in &config.secret_names {
        let _ = env.secrets.remove(&config.secret_key(name));
    }
    let _ = env.secrets.remove(&config.oauth_key());
    env.store.update(|c| c.mcp_servers.retain(|s| s.id != id));
    catalog::unregister(&config.source_id());
}

pub fn secrets(env: &Env, config: &McpServerConfig) -> Vec<(String, String)> {
    config
        .secret_names
        .iter()
        .filter_map(|n| env.secrets.read(&config.secret_key(n)).filter(|v| !v.is_empty()).map(|v| (n.clone(), v)))
        .collect()
}

/// Houdt de MCP-koppelingen in de hub gelijk aan de servers in de instellingen; nieuwe of gewijzigde worden ververst.
pub fn sync(hub: &Arc<crate::connectors::ConnectorHub>, env: &Arc<Env>) {
    let wanted = servers(&env.store);
    for c in hub.all() {
        let id = c.id();
        if id.starts_with("mcp.") && !wanted.iter().any(|s| s.source_id() == id) {
            hub.unregister(&id);
            catalog::unregister(&id);
        }
    }
    for config in wanted {
        let same = hub.get(&config.source_id()).is_some() && hub.mcp_config(&config.source_id()).as_ref() == Some(&config);
        if same {
            continue;
        }
        let connector = McpConnector::new(env.clone(), config.clone());
        hub.register(connector.clone());
        hub.set_mcp_config(&config.source_id(), config.clone());
        hub.refresh(&config.source_id());
    }
}

/// Of dit platform een lokaal programma als server kan starten (niet op Android).
pub fn stdio_supported() -> bool {
    !cfg!(any(target_os = "android", target_os = "ios"))
}

pub struct McpConnector {
    pub config: McpServerConfig,
    env: Arc<Env>,
    client: tokio::sync::Mutex<Option<Arc<McpClient>>>,
    tools: Mutex<Vec<McpTool>>,
    status: Mutex<ConnectorStatus>,
}

impl McpConnector {
    pub fn new(env: Arc<Env>, config: McpServerConfig) -> Arc<Self> {
        Arc::new(Self {
            config,
            env,
            client: Default::default(),
            tools: Mutex::new(vec![]),
            status: Mutex::new(ConnectorStatus::default()),
        })
    }

    pub fn server_tools(&self) -> Vec<McpTool> {
        self.tools.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn set_status(&self, status: ConnectorStatus) {
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = status;
    }

    async fn connected(&self) -> CResult<Arc<McpClient>> {
        let mut guard = self.client.lock().await;
        if let Some(client) = guard.as_ref() {
            return Ok(client.clone());
        }
        let secrets = secrets(&self.env, &self.config);
        let transport: Arc<dyn McpTransport> = match &self.config.transport {
            Transport::Stdio { command, arguments } => {
                if !stdio_supported() {
                    return Err(ConnectorError::kind(
                        "Een lokaal programma als MCP-server kan op Android niet; gebruik een server met een https-adres.",
                        ErrorKind::Config,
                    ));
                }
                Arc::new(StdioTransport::spawn(command, arguments, &secrets, Duration::from_secs(60))?)
            }
            Transport::Http { url } => {
                let authorizer: Option<Arc<dyn Authorizer>> = self
                    .config
                    .signs_in()
                    .then(|| Arc::new(OAuthAuthorizer::new(self.env.clone(), self.config.oauth_key())) as Arc<dyn Authorizer>);
                Arc::new(HttpTransport::new(url, secrets, authorizer)?)
            }
        };
        let client = Arc::new(McpClient::new(transport));
        client.initialize().await?;
        *guard = Some(client.clone());
        Ok(client)
    }

    pub async fn disconnect(&self) {
        if let Some(client) = self.client.lock().await.take() {
            client.close();
        }
    }

    /// Roept een tool aan. Een server die stopte, wordt één keer opnieuw gestart; een verlopen inlog niet.
    pub async fn call(&self, tool: &str, input: &Value) -> CResult<String> {
        if !self.active() {
            return Err(ConnectorError::kind(
                format!("{} staat uit (Instellingen › Accounts & koppelingen).", self.config.name),
                ErrorKind::Config,
            ));
        }
        match self.connected().await?.call_tool(tool, input).await {
            Ok(text) => Ok(text),
            Err(e) if e.kind == ErrorKind::Auth => {
                self.disconnect().await;
                let mut status = self.status();
                status.fail(&e);
                self.set_status(status);
                Err(e)
            }
            Err(e) if e.kind == ErrorKind::Network => {
                self.disconnect().await;
                self.connected().await?.call_tool(tool, input).await
            }
            Err(e) => Err(e),
        }
    }

    fn find(&self, name: &str) -> Option<McpTool> {
        self.server_tools().into_iter().find(|t| McpTool::nook_name(&self.config.id, &t.name) == name)
    }

    /// Test de verbinding: start, handdruk en de lijst met tools.
    pub async fn test(&self) -> CResult<Vec<McpTool>> {
        self.disconnect().await;
        let client = self.connected().await?;
        client.list_tools().await
    }
}

#[async_trait]
impl Connector for McpConnector {
    fn id(&self) -> String {
        self.config.source_id()
    }

    fn title(&self) -> String {
        self.config.name.clone()
    }

    fn configured(&self) -> bool {
        true
    }

    fn active(&self) -> bool {
        self.config.enabled && self.env.store.is_on(&self.id())
    }

    fn status(&self) -> ConnectorStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn refresh_interval(&self) -> u64 {
        900
    }

    async fn refresh(&self) {
        if !self.active() {
            self.disconnect().await;
            self.set_status(ConnectorStatus::default());
            return;
        }
        if self.status().updated.is_none() {
            let mut s = self.status();
            s.state = ConnectorState::Loading;
            self.set_status(s);
        }
        let result = match self.connected().await {
            Ok(client) => client.list_tools().await,
            Err(e) => Err(e),
        };
        match result {
            Ok(tools) => {
                catalog::register(
                    SourceDescriptor { id: self.id(), title: self.title(), kind: SourceKind::Custom },
                    &tools.iter().map(|t| McpTool::nook_name(&self.config.id, &t.name)).collect::<Vec<_>>(),
                );
                let reads = tools.iter().filter(|t| t.read_only).count();
                let items = tools
                    .iter()
                    .take(12)
                    .map(|t| {
                        ConnectorItem::new(
                            &t.name,
                            &t.title,
                            short(&t.description, 80),
                            if t.read_only { Tone::Neutral } else { Tone::Attention },
                            None,
                        )
                    })
                    .collect();
                let status = ConnectorStatus::ok(
                    format!("{} tools", tools.len()),
                    format!("{reads} lezen, {} acties met goedkeuring", tools.len() - reads),
                    items,
                    false,
                );
                *self.tools.lock().unwrap_or_else(|e| e.into_inner()) = tools;
                self.set_status(status);
            }
            Err(e) => {
                self.disconnect().await;
                let mut status = self.status();
                status.fail(&e);
                self.set_status(status);
            }
        }
    }

    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        if !self.active() {
            return vec![];
        }
        let server = self.config.name.clone();
        self.server_tools()
            .into_iter()
            .map(|tool| {
                let name = McpTool::nook_name(&self.config.id, &tool.name);
                let description =
                    format!("[{server}] {}", if tool.description.is_empty() { tool.name.clone() } else { tool.description.clone() });
                if tool.read_only {
                    let me = self.clone();
                    let original = tool.name.clone();
                    LoopTool::read(&name, &description, tool.input_schema.clone(), move |input| {
                        let me = me.clone();
                        let original = original.clone();
                        async move { me.call(&original, &input).await.map_err(Into::into) }
                    })
                } else {
                    LoopTool::action(&name, &description, tool.input_schema.clone())
                }
            })
            .collect()
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        let found = self.find(tool)?;
        let mut pairs: Vec<(&String, &Value)> = input.as_object().map(|o| o.iter().collect()).unwrap_or_default();
        pairs.sort_by_key(|(k, _)| k.as_str());
        let detail: Vec<String> = pairs
            .iter()
            .take(2)
            .map(|(k, v)| {
                format!(
                    "{}: {}",
                    crate::agents::mcp_name::readable(k),
                    short(&v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()), 30)
                )
            })
            .collect();
        Some(format!(
            "{}: {}{}",
            self.config.name,
            found.title,
            if detail.is_empty() { String::new() } else { format!(" · {}", detail.join(", ")) }
        ))
    }

    async fn execute(&self, tool: &str, input: &Value) -> Option<CResult<String>> {
        let found = self.find(tool)?;
        Some(self.call(&found.name, input).await)
    }
}

/// Inloggen bij een server met OAuth en PKCE. `open` opent het inlogadres in de browser van het systeem; Nook wacht
/// op 127.0.0.1 tot de browser terugkomt. Een server die geen inlog vraagt, werkt gewoon.
pub async fn sign_in(env: &Env, config: &McpServerConfig, open: impl FnOnce(&str) -> Result<(), String>) -> CResult<()> {
    let Transport::Http { url } = &config.transport else { return Err(oauth::OAuthError::Insecure.into()) };
    let Some(discovery) = oauth::discover(url).await? else { return Ok(()) };
    let loopback = oauth::Loopback::bind().await?;
    let previous = oauth::load(env, &config.oauth_key());
    // De registratie van een eerdere inlog bij dezelfde server en hetzelfde terugkeeradres blijft bruikbaar.
    let client = match previous {
        Some(p) if p.server.issuer == discovery.server.issuer && p.redirect_uri.as_deref() == Some(loopback.redirect.as_str()) => p.client,
        _ => oauth::register(&discovery.server, &loopback.redirect).await?,
    };
    let pkce = oauth::Pkce::make();
    let state = oauth::random_token(32);
    let authorize = oauth::authorization_url(
        &discovery.server,
        &client,
        &pkce,
        &state,
        &discovery.resource,
        discovery.scope.as_deref(),
        &loopback.redirect,
    )
    .ok_or(oauth::OAuthError::NoAuthorizationServer)?;
    open(&authorize).map_err(|e| ConnectorError::new(format!("De browser ging niet open: {e}")))?;
    let redirect = loopback.redirect.clone();
    let callback = loopback.wait(Duration::from_secs(300)).await?;
    match oauth::parse_callback(&callback, &state, Some(&discovery.server.issuer), &redirect) {
        oauth::Callback::Failed(e) => Err(e.into()),
        oauth::Callback::Code(code) => {
            let tokens = oauth::exchange(&code, &pkce.verifier, &discovery.server, &client, &discovery.resource, &redirect).await?;
            let credentials = oauth::Credentials {
                server: discovery.server,
                client,
                tokens,
                resource: discovery.resource,
                scope: discovery.scope,
                redirect_uri: Some(redirect),
            };
            oauth::save(env, &config.oauth_key(), &credentials)
        }
    }
}

/// Uitloggen: de dienst vragen het token te vergeten en het uit de kluis halen.
pub async fn sign_out(env: &Env, config: &McpServerConfig) {
    if let Some(credentials) = oauth::load(env, &config.oauth_key()) {
        oauth::revoke(&credentials).await;
    }
    let _ = env.secrets.remove(&config.oauth_key());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;

    #[test]
    fn servers_are_added_with_secrets_in_the_vault_and_removed_with_them() {
        let env = Env::new(Arc::new(MemorySecrets::default()), Arc::new(ConnectorStore::in_memory()));
        let a = add(
            &env,
            "GitHub",
            Transport::Stdio { command: "npx".into(), arguments: vec![] },
            &[("GITHUB_TOKEN".into(), "ghp_x".into())],
            false,
            None,
        )
        .unwrap();
        let b = add(&env, "GitHub", Transport::Http { url: "https://example.com/mcp".into() }, &[], true, Some("github")).unwrap();
        assert_eq!((a.id.as_str(), b.id.as_str()), ("github", "github2"));
        assert_eq!(env.secrets.read("connector.mcp.github.GITHUB_TOKEN").as_deref(), Some("ghp_x"));
        assert!(env.store.read(|c| c.mcp_servers.iter().all(|s| s.secret_names.iter().all(|n| n == "GITHUB_TOKEN"))));
        remove(&env, "github");
        assert_eq!(env.secrets.read("connector.mcp.github.GITHUB_TOKEN"), None);
        assert_eq!(servers(&env.store).len(), 1);
    }
}
