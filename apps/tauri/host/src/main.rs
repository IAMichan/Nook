//! `nook-host`: Nook on a machine without a screen (a server, a desktop in the cupboard). It runs coding agents in
//! its own workspace and serves them over Nook's sealed Companion protocol (`docs/COMPANION.md`): a Nook or a phone
//! pairs with a one-time code or QR, and then reaches the host on the LAN, over Tailscale, at a public address, or
//! through the relay. What a paired device may do is limited by its scopes and by the folders the owner shared.
//!
//! ```text
//! nook-host serve [--port N] [--public-host HOST] [--relay URL]   run the server (prints a pairing code on start)
//! nook-host pair                                                    print a fresh pairing code and QR, then serve
//! nook-host devices                                                 list paired devices
//! nook-host revoke <device-id>                                      unpair one device
//! nook-host project add|remove <folder>                             share or unshare a folder for new sessions
//! nook-host project list
//! ```

mod backend;
mod qr;
mod reach;
mod secrets;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use nook_core::companion::relay::RelayHost;
use nook_core::companion::server::{CompanionServer, Reach, ServerState};
use nook_core::companion::store::{CompanionStore, RelaySettings};
use nook_core::workspace::manager::{Hooks, Manager};
use nook_core::workspace::settings::WorkspaceSettings;

const USAGE: &str = "usage: nook-host <serve|pair|devices|revoke ID|project add|remove|list [FOLDER]> \
[--port N] [--public-host HOST] [--relay URL] [--data DIR]";

struct Options {
    command: Vec<String>,
    port: Option<u16>,
    public_host: Option<String>,
    relay: Option<String>,
    data: PathBuf,
}

fn parse(args: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = Options { command: Vec::new(), port: None, public_host: None, relay: None, data: default_data() };
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "--port" => options.port = Some(value("--port")?.parse().map_err(|_| "--port needs a number".to_string())?),
            "--public-host" => options.public_host = Some(value("--public-host")?),
            "--relay" => options.relay = Some(value("--relay")?),
            "--data" => options.data = PathBuf::from(value("--data")?),
            "-h" | "--help" => return Err(USAGE.into()),
            other => options.command.push(other.to_string()),
        }
    }
    if options.command.is_empty() {
        options.command.push("serve".into());
    }
    Ok(options)
}

/// `NOOK_HOST_DATA`, else `~/.nook-host`: apart from a desktop Nook on the same machine, so their sessions never mix.
fn default_data() -> PathBuf {
    std::env::var_os("NOOK_HOST_DATA")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".nook-host")))
        .unwrap_or_else(|| PathBuf::from(".nook-host"))
}

struct Paths {
    settings: PathBuf,
    companion: PathBuf,
    secrets: PathBuf,
    workspace: PathBuf,
    images: PathBuf,
}

impl Paths {
    fn new(data: &std::path::Path) -> Self {
        Self {
            settings: data.join("settings.json"),
            companion: data.join("companion.json"),
            secrets: data.join("secrets.json"),
            workspace: data.join("workspace"),
            images: data.join("images"),
        }
    }
}

fn store(paths: &Paths) -> Arc<CompanionStore> {
    let secrets = Arc::new(secrets::FileSecrets::open(paths.secrets.clone()));
    Arc::new(CompanionStore::load(paths.companion.clone(), secrets))
}

fn project(paths: &Paths, action: Option<&str>, folder: Option<&str>) -> Result<(), String> {
    let mut settings = WorkspaceSettings::load_from(&paths.settings);
    match (action, folder) {
        (Some("add"), Some(folder)) => {
            let path = std::fs::canonicalize(folder).map_err(|e| format!("{folder}: {e}"))?;
            if !path.is_dir() {
                return Err(format!("{folder} is not a folder"));
            }
            let path = path.to_string_lossy().into_owned();
            if !settings.favorite_projects.contains(&path) {
                settings.favorite_projects.push(path.clone());
            }
            settings.save_to(&paths.settings);
            println!("Shared {path}");
        }
        (Some("remove"), Some(folder)) => {
            let clean = std::fs::canonicalize(folder).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| folder.to_string());
            settings.favorite_projects.retain(|p| *p != clean && p != folder);
            settings.recent_projects.retain(|p| *p != clean && p != folder);
            settings.save_to(&paths.settings);
            println!("No longer shared: {clean}");
        }
        (Some("list") | None, _) => {
            for p in backend::shared_projects(&settings) {
                println!("{p}");
            }
        }
        _ => return Err(USAGE.into()),
    }
    Ok(())
}

fn devices(paths: &Paths) {
    let list = store(paths).devices();
    if list.is_empty() {
        println!("No paired devices. Run `nook-host pair` to pair one.");
    }
    for d in list {
        println!("{}  {}  last seen {}", d.id, d.name, d.last_seen.map(|t| t.to_rfc3339()).unwrap_or_else(|| "never".into()));
    }
}

fn manager(paths: &Paths, runtime: tokio::runtime::Handle) -> Arc<Manager> {
    let settings_file = paths.settings.clone();
    let resume_file = paths.settings.clone();
    let hooks = Hooks {
        executable: Box::new(|provider| {
            let found = nook_core::agents::find_executable(provider.kind()).map(|p| p.to_string_lossy().into_owned());
            nook_core::workspace::driver::session_executable(provider, found)
        }),
        // Each agent uses its own login on this machine.
        account_environment: Box::new(|_| Default::default()),
        // Nook's browser and page tools live in a desktop Nook; a headless host has none to give.
        bridge: Box::new(|| None),
        worktree_root: Box::new(move || WorkspaceSettings::load_from(&settings_file).worktree_root()),
        auto_resume_limited: Box::new(move || WorkspaceSettings::load_from(&resume_file).auto_resume_limited),
    };
    Manager::new(paths.workspace.clone(), hooks, runtime, |_event| {})
}

fn print_pairing(server: &CompanionServer, host: &str) {
    let Some(link) = server.pairing_link(host) else {
        eprintln!("The server is not listening, so there is no pairing code.");
        return;
    };
    let url = link.url();
    println!("\nPair a Nook or a phone with this host (the code works once, for a few minutes):\n\n{url}\n");
    if let Ok(code) = qr::render_terminal_qr(&url) {
        println!("{code}");
    }
}

async fn serve(paths: Paths, options: &Options, pair: bool) -> Result<(), String> {
    std::fs::create_dir_all(&paths.workspace).map_err(|e| e.to_string())?;
    let store = store(&paths);
    if let Some(port) = options.port {
        store.set_port(Some(port));
    }
    store.set_enabled(true);
    if let Some(relay) = &options.relay {
        store.set_relay(RelaySettings { enabled: true, own: true, address: relay.clone() });
    }
    let runtime = tokio::runtime::Handle::current();
    let manager = manager(&paths, runtime.clone());
    let backend = Arc::new(backend::HostBackend::new(manager, paths.settings.clone(), paths.images.clone()));
    let name = reach::local_hostname();
    let server = Arc::new(CompanionServer::new(store.clone(), backend, None, name.clone()));
    server.set_app_version(env!("CARGO_PKG_VERSION"));
    let hosts = reach::discover_hosts(options.public_host.as_deref());
    server.set_reach(Reach { hosts: hosts.clone(), relay: String::new() });
    let relay = Arc::new(RelayHost::new(server.clone(), runtime));
    let apply_relay = |relay: &RelayHost| {
        let settings = store.relay();
        let address = nook_core::companion::transport::normalize_relay(&settings.address);
        relay.apply(settings.enabled, address.as_deref());
    };
    apply_relay(&relay);
    match server.start().await {
        ServerState::Listening { port } => {
            println!("nook-host {} listening on port {port} as \"{name}\"", env!("CARGO_PKG_VERSION"));
            for h in &hosts {
                println!("  reachable at {}:{port}{}", h.host, if h.tailnet { " (Tailscale)" } else { "" });
            }
        }
        ServerState::Failed { message } => return Err(format!("could not listen: {message}")),
        _ => return Err("could not listen".into()),
    }
    if pair || store.devices().is_empty() {
        let first = hosts.first().map(|h| h.host.clone()).unwrap_or_else(|| "127.0.0.1".into());
        // The relay address goes in the code once its room is open.
        tokio::time::sleep(Duration::from_millis(500)).await;
        server.set_reach(Reach { hosts: hosts.clone(), relay: relay.advertised() });
        print_pairing(&server, &first);
    }
    // Look at the network now and then: a new address goes to paired clients with the next answer.
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    loop {
        tokio::select! {
            _ = tick.tick() => {
                let hosts = reach::discover_hosts(options.public_host.as_deref());
                apply_relay(&relay);
                server.set_reach(Reach { hosts, relay: relay.advertised() });
            }
            _ = tokio::signal::ctrl_c() => {
                println!("Stopping.");
                server.stop();
                return Ok(());
            }
        }
    }
}

fn main() {
    let options = match parse(std::env::args().skip(1)) {
        Ok(o) => o,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let paths = Paths::new(&options.data);
    let command: Vec<&str> = options.command.iter().map(String::as_str).collect();
    let result = match command.as_slice() {
        ["serve"] | ["pair"] => {
            let pair = command[0] == "pair";
            let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
            runtime.block_on(serve(paths, &options, pair))
        }
        ["devices"] => {
            devices(&paths);
            Ok(())
        }
        ["revoke", id] => {
            let store = store(&paths);
            if store.device(id).is_some() {
                store.remove(id);
                println!("Unpaired {id}");
                Ok(())
            } else {
                Err(format!("no paired device {id}"))
            }
        }
        ["project", rest @ ..] => project(&paths, rest.first().copied(), rest.get(1).copied()),
        _ => Err(USAGE.into()),
    };
    if let Err(message) = result {
        eprintln!("{message}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter().map(|s| s.to_string()).collect::<Vec<_>>().into_iter()
    }

    #[test]
    fn parses_flags_and_defaults_to_serve() {
        let o = parse(args(&["--port", "4100", "--public-host", "box.example.com", "--data", "/srv/nook"])).unwrap();
        assert_eq!(o.command, vec!["serve"]);
        assert_eq!(o.port, Some(4100));
        assert_eq!(o.public_host.as_deref(), Some("box.example.com"));
        assert_eq!(o.data, PathBuf::from("/srv/nook"));
        assert!(parse(args(&["--port", "x"])).is_err());
        assert_eq!(parse(args(&["project", "add", "/tmp"])).unwrap().command, vec!["project", "add", "/tmp"]);
    }

    #[test]
    fn sharing_a_folder_offers_it() {
        let data = std::env::temp_dir().join(format!("nook-host-main-{}", uuid::Uuid::new_v4()));
        let folder = data.join("repo");
        std::fs::create_dir_all(&folder).unwrap();
        let paths = Paths::new(&data);
        project(&paths, Some("add"), Some(&folder.to_string_lossy())).unwrap();
        let shared = backend::shared_projects(&WorkspaceSettings::load_from(&paths.settings));
        assert_eq!(shared.len(), 1);
        project(&paths, Some("remove"), Some(&folder.to_string_lossy())).unwrap();
        assert!(backend::shared_projects(&WorkspaceSettings::load_from(&paths.settings)).is_empty());
        let _ = std::fs::remove_dir_all(&data);
    }

    async fn snapshot_sessions(client: &nook_core::companion::client::CompanionClient) -> Vec<String> {
        client.refresh().await.sessions.into_iter().map(|s| s.id).collect()
    }

    /// A client pairs with the code, then gets this host's shared folder as a place to start, and cannot start an
    /// agent in a folder that was not shared.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_paired_client_sees_only_shared_folders() {
        use nook_core::companion::client::{ClientCall, CompanionClient, DnsResolver, Phase};
        use nook_core::companion::{CompanionOp, LaunchRequest};
        use nook_core::secrets::MemorySecrets;

        let data = std::env::temp_dir().join(format!("nook-host-pair-{}", uuid::Uuid::new_v4()));
        let shared = data.join("shared");
        let other = data.join("other");
        std::fs::create_dir_all(&shared).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        let paths = Paths::new(&data);
        project(&paths, Some("add"), Some(&shared.to_string_lossy())).unwrap();
        let store = store(&paths);
        store.set_enabled(true);
        let manager = manager(&paths, tokio::runtime::Handle::current());
        let backend = Arc::new(backend::HostBackend::new(manager, paths.settings.clone(), paths.images.clone()));
        let server = Arc::new(CompanionServer::new(store.clone(), backend, None, "box".into()));
        assert!(matches!(server.start().await, ServerState::Listening { .. }));

        let client = CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver));
        let link = server.pairing_link("127.0.0.1").unwrap();
        let paired = client.pair(&link.url(), "Laptop").await;
        assert_eq!(paired.phase, Phase::Connected, "{:?}", paired.notice);
        assert_eq!(store.devices().len(), 1);

        let (_, answer) = client.call(ClientCall { op: Some(CompanionOp::Options), ..Default::default() }).await;
        let launch = answer.and_then(|a| a.launch).expect("launch options");
        let projects: Vec<String> =
            launch["projects"].as_array().unwrap().iter().map(|p| p["path"].as_str().unwrap().to_string()).collect();
        let canonical = std::fs::canonicalize(&shared).unwrap().to_string_lossy().into_owned();
        assert_eq!(projects, vec![nook_core::workspace::paths::normalize(&canonical)]);

        let start = |agent: &str, folder: &std::path::Path| ClientCall {
            op: Some(CompanionOp::Start),
            launch: Some(LaunchRequest {
                agent: agent.into(),
                project: folder.to_string_lossy().into_owned(),
                task: "hello".into(),
                ..Default::default()
            }),
            ..Default::default()
        };
        // The client keeps a refusal to itself (no answer, a notice) and nothing starts.
        let (snapshot, refused) = client.call(start("no-such-agent", &shared)).await;
        assert!(refused.is_none() && snapshot.notice.is_some());
        if let Some(agent) = backend::launchable().first() {
            let (snapshot, refused) = client.call(start(agent.id(), &other)).await;
            assert!(refused.is_none() && snapshot.notice.is_some());
        }
        assert!(snapshot_sessions(&client).await.is_empty(), "no session started");
        server.stop();
        let _ = std::fs::remove_dir_all(&data);
    }
}
