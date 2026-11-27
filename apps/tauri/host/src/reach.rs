//! Discovers how paired Nook clients can reach this host: `.local` name, LAN IPv4 addresses, Tailscale IPv4
//! addresses (`tailscale ip -4`), and any configured public host/domain.

use std::net::{IpAddr, Ipv4Addr};
use std::process::Command;

use nook_core::companion::server::ReachHost;

pub fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..128).contains(&b)
}

pub fn local_hostname() -> String {
    let raw = std::env::var("HOSTNAME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            Command::new("hostname")
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        })
        .unwrap_or_else(|| "nook-host".into());
    raw.split('.').next().unwrap_or("nook-host").trim().to_string()
}

fn interface_addresses() -> Vec<(String, Ipv4Addr)> {
    if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            IpAddr::V4(v4) if v4.is_private() || is_cgnat(v4) => Some((i.name, v4)),
            _ => None,
        })
        .collect()
}

fn tailscale_addresses() -> Vec<Ipv4Addr> {
    Command::new("tailscale")
        .args(["ip", "-4"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| l.trim().parse().ok()).collect())
        .unwrap_or_default()
}

/// Ordered candidate hosts: LAN private addresses, `.local` name, Tailscale addresses, then optional public host.
pub fn discover_hosts(public_host: Option<&str>) -> Vec<ReachHost> {
    let addresses = interface_addresses();
    let confirmed = if addresses.iter().any(|(_, ip)| is_cgnat(*ip)) { tailscale_addresses() } else { Vec::new() };
    let mut hosts: Vec<ReachHost> = Vec::new();
    let mut rest: Vec<ReachHost> = addresses
        .into_iter()
        .map(|(name, ip)| ReachHost {
            host: ip.to_string(),
            tailnet: is_cgnat(ip) && (name.to_ascii_lowercase().contains("tailscale") || confirmed.contains(&ip)),
        })
        .collect();
    // Private LAN first, then Tailscale / CGNAT.
    rest.sort_by_key(|h| h.host.starts_with("100."));
    for h in rest {
        if !hosts.iter().any(|known| known.host == h.host) {
            hosts.push(h);
        }
    }
    let short = local_hostname();
    if !short.is_empty() {
        let local = format!("{short}.local");
        if !hosts.iter().any(|known| known.host.eq_ignore_ascii_case(&local)) {
            hosts.push(ReachHost { host: local, tailnet: false });
        }
    }
    if let Some(pub_h) = public_host.map(str::trim).filter(|s| !s.is_empty()) {
        if !hosts.iter().any(|known| known.host.eq_ignore_ascii_case(pub_h)) {
            hosts.push(ReachHost { host: pub_h.to_string(), tailnet: false });
        }
    }
    if hosts.is_empty() {
        hosts.push(ReachHost { host: "127.0.0.1".into(), tailnet: false });
    }
    hosts
}
