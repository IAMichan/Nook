//! Commando's voor Instellingen › Accounts & koppelingen: diensten koppelen met een sleutel of door in te loggen,
//! extra accounts, MCP-servers, GitLab-hosts, WhatsApp live, de accounts per chat en de iconen van de diensten.
//! Geheimen gaan alleen de kluis in; terug naar de interface komt nooit meer dan "staat erin".

use std::collections::{BTreeSet, HashMap};

use nook_core::connectors::accounts::{self, ServiceAccount};
use nook_core::connectors::cloud::{self, ServiceInfo};
use nook_core::connectors::github::{self, AccountPullRequests};
use nook_core::connectors::hub::ConnectorInfo;
use nook_core::connectors::mcp::{self, connector as mcp_store, McpServerConfig, McpTool, Pasted, Transport};
use nook_core::connectors::whatsapp::{link::LinkView, Conversation, WhatsAppSettings};
use nook_core::connectors::{brand, gitlab};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_opener::OpenerExt;

use crate::connectors::Connectors;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountView {
    id: String,
    label: String,
    title: String,
    identity: Option<String>,
    has_token: bool,
    primary: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    #[serde(flatten)]
    info: ServiceInfo,
    /// De waarde van velden die geen geheim zijn (een adres, een team-id).
    values: HashMap<String, String>,
    /// De geheime velden die al in de kluis staan.
    stored: Vec<String>,
    accounts: Vec<AccountView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteView {
    #[serde(flatten)]
    service: mcp_store::RemoteService,
    /// De server die voor deze dienst is toegevoegd, als die er is.
    server: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpView {
    config: McpServerConfig,
    target: String,
    remote: bool,
    domain: Option<String>,
    signed_in: bool,
    tools: Vec<McpTool>,
}

/// Een bron van de Mac die hier niet (of nog niet) kan, met de reden.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSource {
    id: &'static str,
    title: &'static str,
    reason: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Caps {
    desktop: bool,
    /// Een lokaal programma als MCP-server starten.
    stdio: bool,
    /// Inloggen via de browser en terug naar 127.0.0.1.
    browser_sign_in: bool,
    /// De login van de GitHub CLI overnemen.
    gh_cli: bool,
    /// "Koppel met GitHub" (device flow) is ingesteld.
    device_flow: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    connectors: Vec<ConnectorInfo>,
    services: Vec<ServiceView>,
    remote: Vec<RemoteView>,
    mcp: Vec<McpView>,
    gitlab: Vec<String>,
    local: Vec<LocalSource>,
    caps: Caps,
}

const LOCAL: [LocalSource; 8] = [
    LocalSource { id: "calendar", title: "Agenda van het systeem", reason: "Apple Agenda bestaat hier niet, en de agenda's van Windows, GNOME of Android zijn (nog) niet te lezen. Koppel je agenda met een ICS-adres onder Andere agenda's: dat werkt voor Google, Outlook, iCloud en werkagenda's." },
    LocalSource { id: "reminders", title: "Herinneringen", reason: "Alleen op de Mac (Apple Herinneringen). Nook houdt zelf je open punten bij." },
    LocalSource { id: "notes", title: "Notities", reason: "Alleen op de Mac (Apple Notities)." },
    LocalSource { id: "mail", title: "Mail", reason: "Alleen op de Mac (Mail.app)." },
    LocalSource { id: "messages", title: "Berichten", reason: "Alleen op de Mac (iMessage)." },
    LocalSource { id: "bear", title: "Bear", reason: "Bear bestaat alleen voor de Mac en iOS." },
    LocalSource { id: "things", title: "Things", reason: "Things bestaat alleen voor de Mac en iOS." },
    LocalSource { id: "contacts", title: "Contacten", reason: "Alleen op de Mac (Apple Contacten)." },
];

fn caps() -> Caps {
    Caps {
        desktop: cfg!(desktop),
        stdio: mcp_store::stdio_supported(),
        browser_sign_in: cfg!(desktop),
        gh_cli: cfg!(desktop),
        device_flow: cfg!(desktop) && !github::CLIENT_ID.is_empty(),
    }
}

fn account_view(c: &Connectors, a: &ServiceAccount, service_title: &str) -> AccountView {
    AccountView {
        id: a.id.clone(),
        label: a.label.clone(),
        title: a.title(service_title),
        identity: a.identity.clone(),
        has_token: c.env.secret(&a.key("token")).is_some(),
        primary: a.is_primary(),
    }
}

fn service_views(c: &Connectors) -> Vec<ServiceView> {
    cloud::services()
        .into_iter()
        .map(|info| {
            let mut values = HashMap::new();
            let mut stored = vec![];
            for f in &info.fields {
                match c.env.secret(f.account) {
                    Some(v) if !f.secret => {
                        values.insert(f.account.to_string(), v);
                    }
                    Some(_) => stored.push(f.account.to_string()),
                    None => {}
                }
            }
            let accounts = if info.id == "github" {
                accounts::accounts(&c.env.store, "github").iter().map(|a| account_view(c, a, "GitHub")).collect()
            } else {
                vec![]
            };
            ServiceView { info, values, stored, accounts }
        })
        .collect()
}

fn mcp_views(c: &Connectors) -> Vec<McpView> {
    mcp_store::servers(&c.env.store)
        .into_iter()
        .map(|config| {
            let tools = c.hub.get(&config.source_id()).and_then(|_| mcp_tools_of(c, &config.id)).unwrap_or_default();
            let (domain, remote) = match &config.transport {
                Transport::Http { url } => (brand::mcp_domain(&config.name, None, Some(url)), true),
                Transport::Stdio { command, arguments } => (brand::mcp_domain(&config.name, Some((command, arguments)), None), false),
            };
            McpView { target: config.target(), remote, domain, signed_in: c.env.secret(&config.oauth_key()).is_some(), tools, config }
        })
        .collect()
}

fn mcp_tools_of(c: &Connectors, id: &str) -> Option<Vec<McpTool>> {
    let config = mcp_store::servers(&c.env.store).into_iter().find(|s| s.id == id)?;
    let connector = c.hub.get(&config.source_id())?;
    // Nook's tool names carry the server ("mcp_files_move_file") and the descriptions a "[Server] " prefix for the
    // model; the settings already name the server.
    let prefix = McpTool::nook_name(&config.id, "");
    let label = format!("[{}] ", config.name);
    Some(
        connector
            .tools(&nook_core::connectors::hub::Scope::default())
            .into_iter()
            .map(|t| McpTool {
                name: t.name.clone(),
                title: nook_core::agents::mcp_name::readable(t.name.strip_prefix(&prefix).unwrap_or(&t.name)),
                description: t.description.strip_prefix(&label).unwrap_or(&t.description).to_string(),
                input_schema: t.schema.clone(),
                read_only: t.kind == nook_core::brain::ToolKind::Read,
            })
            .collect(),
    )
}

#[tauri::command]
pub async fn connectors_overview(c: State<'_, Connectors>) -> Res<Overview> {
    let servers = mcp_store::servers(&c.env.store);
    Ok(Overview {
        connectors: c.hub.info(),
        services: service_views(&c),
        remote: mcp_store::REMOTE_SERVICES
            .iter()
            .map(|s| RemoteView {
                service: s.clone(),
                server: servers.iter().find(|x| x.service_id.as_deref() == Some(s.id)).map(|x| x.id.clone()),
            })
            .collect(),
        mcp: mcp_views(&c),
        gitlab: gitlab::hosts(&c.env.store, &*c.env.secrets),
        local: LOCAL.into_iter().collect(),
        caps: caps(),
    })
}

fn info(c: &Connectors, id: &str) -> Option<ConnectorInfo> {
    c.hub.info().into_iter().find(|i| i.id == id)
}

/// Bewaart de velden van een dienst (alleen die van die dienst) en kijkt meteen of de verbinding werkt.
#[tauri::command]
pub async fn connector_save(c: State<'_, Connectors>, id: String, values: HashMap<String, String>) -> Res<Option<ConnectorInfo>> {
    let service = cloud::services().into_iter().find(|s| s.id == id).ok_or_else(|| format!("Onbekende dienst {id}"))?;
    for field in &service.fields {
        if let Some(value) = values.get(field.account) {
            // Een leeg geheim veld laat de bewaarde sleutel staan; een leeg gewoon veld wist hem.
            if value.trim().is_empty() && field.secret {
                continue;
            }
            c.env.secrets.write(field.account, value)?;
        }
    }
    c.env.store.set_on(&id, true);
    c.hub.refresh_now(&id).await;
    Ok(info(&c, &id))
}

/// Ontkoppelt een dienst: zijn sleutels gaan uit de kluis.
#[tauri::command]
pub async fn connector_disconnect(c: State<'_, Connectors>, id: String) -> Res<Option<ConnectorInfo>> {
    let service = cloud::services().into_iter().find(|s| s.id == id).ok_or_else(|| format!("Onbekende dienst {id}"))?;
    for field in &service.fields {
        c.env.secrets.remove(field.account)?;
    }
    c.hub.refresh_now(&id).await;
    Ok(info(&c, &id))
}

#[tauri::command]
pub async fn connector_toggle(c: State<'_, Connectors>, id: String, on: bool) -> Res<Option<ConnectorInfo>> {
    c.env.store.set_on(&id, on);
    if id.starts_with("mcp.") {
        c.sync_mcp();
    }
    c.hub.refresh_now(&id).await;
    Ok(info(&c, &id))
}

#[tauri::command]
pub async fn connector_refresh(c: State<'_, Connectors>, id: String) -> Res<Option<ConnectorInfo>> {
    c.hub.refresh_now(&id).await;
    Ok(info(&c, &id))
}

// Accounts

#[tauri::command]
pub async fn account_add(c: State<'_, Connectors>, service: String, label: String) -> Res<AccountView> {
    let account = accounts::add(&c.env.store, &service, &label);
    Ok(account_view(&c, &account, &brand_title(&service)))
}

fn brand_title(service: &str) -> String {
    nook_core::connectors::catalog::title(service)
}

#[tauri::command]
pub async fn account_rename(c: State<'_, Connectors>, id: String, label: String) -> Res<()> {
    accounts::rename(&c.env.store, &id, &label);
    c.hub.changed();
    Ok(())
}

/// Haalt een account weg met zijn token. Het hoofdaccount blijft bestaan, alleen zijn token gaat weg.
#[tauri::command]
pub async fn account_remove(c: State<'_, Connectors>, id: String) -> Res<()> {
    let account = accounts::account(&c.env.store, &id).ok_or("Dit account bestaat niet.")?;
    c.env.secrets.remove(&account.key("token"))?;
    accounts::remove(&c.env.store, &id);
    c.hub.refresh_now(&account.service).await;
    Ok(())
}

#[tauri::command]
pub async fn account_token(c: State<'_, Connectors>, id: String, token: String) -> Res<Option<ConnectorInfo>> {
    let account = accounts::account(&c.env.store, &id).ok_or("Dit account bestaat niet.")?;
    c.env.secrets.write(&account.key("token"), &token)?;
    c.env.store.set_on(&account.service, true);
    c.hub.refresh_now(&account.service).await;
    Ok(info(&c, &account.service))
}

// Koppel met GitHub

/// Neemt de login van de GitHub CLI over voor dit account.
#[tauri::command]
pub async fn github_cli(c: State<'_, Connectors>, account: String) -> Res<Option<ConnectorInfo>> {
    let target = accounts::account(&c.env.store, &account).ok_or("Dit account bestaat niet.")?;
    let token = tauri::async_runtime::spawn_blocking(github::cli_token).await.map_err(|e| e.to_string())??;
    c.env.secrets.write(&target.key("token"), &token).map_err(|_| "De kluis weigerde de sleutel. Probeer het nog eens.".to_string())?;
    c.env.store.set_on("github", true);
    c.hub.refresh_now("github").await;
    Ok(info(&c, "github"))
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SignInEvent {
    service: String,
    ok: bool,
    message: String,
}

/// Start "Koppel met GitHub": geeft de code terug (de interface zet hem op het klembord), opent GitHub en wacht op
/// de bevestiging. Het resultaat komt als event `connector-signin`.
#[tauri::command]
pub async fn github_device_start(app: AppHandle, c: State<'_, Connectors>, account: String) -> Res<github::DeviceCode> {
    if github::CLIENT_ID.is_empty() {
        return Err("Koppel met GitHub is in deze versie nog niet ingesteld. Gebruik je GitHub CLI-login of plak een token.".into());
    }
    let target = accounts::account(&c.env.store, &account).ok_or("Dit account bestaat niet.")?;
    let code = github::request_code(&c.env, github::CLIENT_ID).await?;
    app.opener().open_url(&code.verification_uri, None::<&str>).map_err(|e| e.to_string())?;
    let (env, hub, pending) = (c.env.clone(), c.hub.clone(), code.clone());
    tauri::async_runtime::spawn(async move {
        let result = github::finish_device_flow(&env, github::CLIENT_ID, &pending, &target.key("token")).await;
        if result.is_ok() {
            env.store.set_on("github", true);
            hub.refresh_now("github").await;
        }
        let _ = app.emit(
            "connector-signin",
            SignInEvent {
                service: "github".into(),
                ok: result.is_ok(),
                message: result.err().map(|e| e.message).unwrap_or_else(|| "GitHub is gekoppeld.".into()),
            },
        );
    });
    Ok(code)
}

/// De open pull requests van alle GitHub-accounts (voor de lijst bij Agents).
#[tauri::command]
pub async fn github_pull_requests(c: State<'_, Connectors>) -> Res<Vec<AccountPullRequests>> {
    Ok(c.github.pull_request_list().await)
}

// MCP

#[tauri::command]
pub async fn mcp_paste(text: String) -> Pasted {
    mcp::parse_pasted(&text)
}

/// Voegt een server toe: een opdracht (lokaal programma) of een https-adres. Sleutels gaan naar de kluis.
#[tauri::command]
pub async fn mcp_add(c: State<'_, Connectors>, name: String, target: String, remote: bool, secrets: String) -> Res<String> {
    let transport = mcp::transport_for(&target, remote)?;
    let config = mcp_store::add(&c.env, &name, transport, &mcp::parse_secrets(&secrets), false, None)?;
    c.sync_mcp();
    Ok(config.id)
}

#[tauri::command]
pub async fn mcp_remove(c: State<'_, Connectors>, id: String) -> Res<()> {
    if let Some(config) = mcp_store::servers(&c.env.store).into_iter().find(|s| s.id == id) {
        if config.signs_in() {
            mcp_store::sign_out(&c.env, &config).await;
        }
    }
    mcp_store::remove(&c.env, &id);
    c.sync_mcp();
    Ok(())
}

#[tauri::command]
pub async fn mcp_set_enabled(c: State<'_, Connectors>, id: String, enabled: bool) -> Res<()> {
    mcp_store::set_enabled(&c.env.store, &id, enabled);
    c.sync_mcp();
    Ok(())
}

/// Start de server opnieuw en geeft zijn tools; een fout komt terug als zin.
#[tauri::command]
pub async fn mcp_test(c: State<'_, Connectors>, id: String) -> Res<Vec<McpTool>> {
    let config = mcp_store::servers(&c.env.store).into_iter().find(|s| s.id == id).ok_or("Deze server bestaat niet meer.")?;
    let probe = mcp::McpConnector::new(c.env.clone(), config.clone());
    let result = probe.test().await;
    probe.disconnect().await;
    c.hub.refresh_now(&config.source_id()).await;
    result.map_err(|e| e.message)
}

async fn sign_in(app: &AppHandle, c: &Connectors, config: &McpServerConfig) -> Res<()> {
    if !cfg!(desktop) {
        return Err("Inloggen via de browser kan op Android nog niet. Gebruik een sleutel.".into());
    }
    let opener = app.clone();
    mcp_store::sign_in(&c.env, config, move |url| opener.opener().open_url(url, None::<&str>).map_err(|e| e.to_string()))
        .await
        .map_err(|e| e.message)?;
    c.env.store.set_on(&config.source_id(), true);
    c.sync_mcp();
    c.hub.refresh_now(&config.source_id()).await;
    Ok(())
}

/// Verbindt een ingebouwde dienst via zijn officiële MCP-server: toevoegen, inloggen in de browser, terug.
/// Een eerste poging die niet lukt, laat niets achter.
#[tauri::command]
pub async fn mcp_connect_service(app: AppHandle, c: State<'_, Connectors>, service: String) -> Res<()> {
    let remote = mcp_store::REMOTE_SERVICES.iter().find(|s| s.id == service).ok_or_else(|| format!("Onbekende dienst {service}"))?;
    let existing = mcp_store::servers(&c.env.store).into_iter().find(|s| s.service_id.as_deref() == Some(remote.id));
    let config = match &existing {
        Some(e) => e.clone(),
        None => mcp_store::add(&c.env, remote.name, Transport::Http { url: remote.url.into() }, &[], true, Some(remote.id))?,
    };
    let result = sign_in(&app, &c, &config).await;
    if result.is_err() && existing.is_none() {
        mcp_store::remove(&c.env, &config.id);
        c.sync_mcp();
    }
    result
}

/// Opnieuw inloggen bij een server (verlopen inlog).
#[tauri::command]
pub async fn mcp_sign_in(app: AppHandle, c: State<'_, Connectors>, id: String) -> Res<()> {
    let config = mcp_store::servers(&c.env.store).into_iter().find(|s| s.id == id).ok_or("Deze server bestaat niet meer.")?;
    sign_in(&app, &c, &config).await
}

// GitLab

#[tauri::command]
pub async fn gitlab_save(c: State<'_, Connectors>, host: String, token: String) -> Res<Vec<String>> {
    gitlab::save(&c.env.store, &*c.env.secrets, &host, &token)?;
    Ok(gitlab::hosts(&c.env.store, &*c.env.secrets))
}

#[tauri::command]
pub async fn gitlab_remove(c: State<'_, Connectors>, host: String) -> Res<Vec<String>> {
    gitlab::remove(&c.env.store, &*c.env.secrets, &host);
    Ok(gitlab::hosts(&c.env.store, &*c.env.secrets))
}

// WhatsApp live

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WhatsAppView {
    #[serde(flatten)]
    view: LinkView,
    settings: WhatsAppSettings,
    has_credential: bool,
    desktop: bool,
}

#[tauri::command]
pub async fn whatsapp_view(c: State<'_, Connectors>) -> Res<WhatsAppView> {
    let mut view = c.whatsapp.view();
    view.gowa_running = c.whatsapp.gowa_running();
    Ok(WhatsAppView { view, settings: c.whatsapp.settings(), has_credential: c.whatsapp.has_credential(), desktop: cfg!(desktop) })
}

#[tauri::command]
pub async fn whatsapp_save(c: State<'_, Connectors>, settings: WhatsAppSettings) -> Res<()> {
    let mut settings = settings;
    if !cfg!(desktop) {
        settings.auto_start = false;
    }
    c.whatsapp.update_settings(|s| *s = settings);
    Ok(())
}

#[tauri::command]
pub async fn whatsapp_credential(c: State<'_, Connectors>, value: String) -> Res<()> {
    c.whatsapp.set_credential(&value).map_err(|e| e.message)
}

#[tauri::command]
pub async fn whatsapp_test(c: State<'_, Connectors>) -> Res<String> {
    Ok(c.whatsapp.test_connection().await)
}

/// De gesprekken die de interface toont (geen stille groepen, geen genegeerde chats).
#[tauri::command]
pub async fn whatsapp_chats(c: State<'_, Connectors>) -> Res<Vec<Conversation>> {
    Ok(c.whatsapp.visible())
}

/// Een antwoord dat de gebruiker zelf typte (geen plan nodig: de gebruiker drukte zelf op Versturen).
#[tauri::command]
pub async fn whatsapp_reply(c: State<'_, Connectors>, chat: String, text: String) -> Res<String> {
    c.whatsapp.send(&text, &chat).await.map_err(|e| e.message)
}

#[tauri::command]
pub async fn whatsapp_mark_read(c: State<'_, Connectors>, chat: String) -> Res<()> {
    c.whatsapp.mark_read(&chat);
    Ok(())
}

#[tauri::command]
pub async fn whatsapp_ignore(c: State<'_, Connectors>, chat: String) -> Res<()> {
    c.whatsapp.ignore(&chat);
    Ok(())
}

#[tauri::command]
pub async fn whatsapp_unmute(c: State<'_, Connectors>) -> Res<()> {
    c.whatsapp.update_settings(|s| s.ignored.clear());
    Ok(())
}

// Accounts per chat

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatAccount {
    id: String,
    title: String,
    allowed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatService {
    service: String,
    title: String,
    accounts: Vec<ChatAccount>,
}

/// De diensten met meer dan één account, en welke deze chat mag gebruiken.
#[tauri::command]
pub async fn chat_accounts(c: State<'_, Connectors>, nook_id: String) -> Res<Vec<ChatService>> {
    let excluded = c.env.store.excluded_accounts(&nook_id);
    let mut out = vec![];
    for service in ["github"] {
        let list: Vec<ServiceAccount> =
            accounts::accounts(&c.env.store, service).into_iter().filter(|a| c.env.secret(&a.key("token")).is_some()).collect();
        if list.len() < 2 {
            continue;
        }
        let title = brand_title(service);
        out.push(ChatService {
            service: service.into(),
            accounts: list
                .iter()
                .map(|a| ChatAccount { id: a.id.clone(), title: a.title(&title), allowed: !excluded.contains(&a.id) })
                .collect(),
            title,
        });
    }
    Ok(out)
}

#[tauri::command]
pub async fn chat_accounts_set(c: State<'_, Connectors>, nook_id: String, excluded: Vec<String>) -> Res<()> {
    c.env.store.set_excluded_accounts(&nook_id, excluded.into_iter().collect::<BTreeSet<_>>());
    Ok(())
}

// Iconen

/// Het icoon van een dienst, van zijn eigen website (zoals op de Mac), als data-URL. Eén keer opgehaald en bewaard.
#[tauri::command]
pub async fn service_icon(domain: String) -> Option<String> {
    nook_core::connectors::brand::icon(&domain).await
}
