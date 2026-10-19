//! mDNS (Bonjour): de computer kondigt zich aan als `_nookcompanion._tcp` met zijn naam `….local`, zoals de Mac met
//! `NWListener.Service`; de telefoon zoekt een `….local`-naam zo op als DNS hem niet kent (Android kent `.local` vaak niet).

use std::net::{IpAddr, SocketAddr};
use std::sync::OnceLock;
use std::time::Duration;

use async_trait::async_trait;
use mdns_sd::{HostnameResolutionEvent, ServiceDaemon};
use nook_core::companion::client::HostResolver;

fn daemon() -> Option<&'static ServiceDaemon> {
    static DAEMON: OnceLock<Option<ServiceDaemon>> = OnceLock::new();
    DAEMON
        .get_or_init(|| match ServiceDaemon::new() {
            Ok(d) => Some(d),
            Err(e) => {
                log::warn!("mDNS niet beschikbaar: {e}");
                None
            }
        })
        .as_ref()
}

/// De aankondiging van de luisteraar; weg zodra de companion uitgaat.
#[cfg(desktop)]
#[derive(Default)]
pub struct Announcer {
    fullname: std::sync::Mutex<Option<String>>,
}

#[cfg(desktop)]
impl Announcer {
    pub fn apply(&self, state: &nook_core::companion::server::ServerState, name: &str) {
        use nook_core::companion::server::ServerState;
        let mut current = self.fullname.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = current.take() {
            if let Some(d) = daemon() {
                let _ = d.unregister(&old);
            }
        }
        let ServerState::Listening { port } = state else { return };
        let Some(d) = daemon() else { return };
        let host = format!("{}.", super::local_host_name());
        let ty = format!("{}.local.", nook_core::companion::BONJOUR_TYPE);
        match mdns_sd::ServiceInfo::new(&ty, name, &host, (), *port, None::<std::collections::HashMap<String, String>>) {
            Ok(info) => {
                let info = info.enable_addr_auto();
                let fullname = info.get_fullname().to_string();
                match d.register(info) {
                    Ok(()) => *current = Some(fullname),
                    Err(e) => log::warn!("mDNS-aankondiging mislukt: {e}"),
                }
            }
            Err(e) => log::warn!("mDNS-aankondiging mislukt: {e}"),
        }
    }
}

/// DNS, en voor `….local` daarna mDNS.
pub struct LocalResolver;

#[async_trait]
impl HostResolver for LocalResolver {
    async fn resolve(&self, host: &str, port: u16) -> Vec<SocketAddr> {
        if let Ok(ip) = host.parse::<IpAddr>() {
            return vec![SocketAddr::new(ip, port)];
        }
        let dns = tokio::time::timeout(Duration::from_secs(3), tokio::net::lookup_host((host, port))).await;
        if let Ok(Ok(found)) = dns {
            let found: Vec<SocketAddr> = found.collect();
            if !found.is_empty() {
                return found;
            }
        }
        if !host.to_ascii_lowercase().ends_with(".local") {
            return Vec::new();
        }
        let Some(d) = daemon() else { return Vec::new() };
        let name = format!("{host}.");
        let Ok(events) = d.resolve_hostname(&name, Some(3000)) else { return Vec::new() };
        // Een adres in het netwerk zodra dat er is; alleen een loopback-adres (dezelfde computer) als er niets anders komt.
        let mut found: Vec<IpAddr> = Vec::new();
        while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_secs(4), events.recv_async()).await {
            match event {
                HostnameResolutionEvent::AddressesFound(_, addresses) => {
                    for ip in addresses.iter().map(|a| a.to_ip_addr()) {
                        if !found.contains(&ip) {
                            found.push(ip);
                        }
                    }
                    if found.iter().any(|ip| !ip.is_loopback()) {
                        break;
                    }
                }
                HostnameResolutionEvent::SearchTimeout(_) | HostnameResolutionEvent::SearchStopped(_) => break,
                _ => {}
            }
        }
        let _ = d.stop_resolve_hostname(&name);
        // IPv4 eerst (een IPv6-link-local-adres heeft een interface nodig), loopback achteraan.
        found.sort_by_key(|ip| (ip.is_loopback(), !ip.is_ipv4()));
        found.into_iter().map(|ip| SocketAddr::new(ip, port)).collect()
    }
}

/// De IPv4-adressen van deze computer in het lokale netwerk, voor wie liever een adres dan `….local` in de code heeft.
#[cfg(desktop)]
pub fn local_addresses() -> Vec<String> {
    if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            IpAddr::V4(v4) if v4.is_private() => Some(v4.to_string()),
            _ => None,
        })
        .collect()
}
