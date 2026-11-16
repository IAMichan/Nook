//! Where phones can reach this computer (`CompanionEndpoints` on the Mac): its `.local` name and the IPv4 addresses of
//! its interfaces, the Tailscale one marked as such. Told with every `hello` and `list`, so a phone follows a new Wi-Fi
//! address, and knows the Tailscale address away from home, without pairing again.
//!
//! An address in 100.64.0.0/10 is not necessarily Tailscale (Cloudflare WARP and other VPNs use the same range), so it
//! counts as the tailnet only when its interface is named after Tailscale or `tailscale ip -4` names it, as t3code does.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::companion::server::ReachHost;

/// Whether an address is in the shared range Tailscale (and other VPNs) hand out.
pub fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..128).contains(&b)
}

/// The IPv4 addresses phones can use: the local network and VPNs such as Tailscale, never loopback or public ones.
pub fn interface_addresses() -> Vec<(String, Ipv4Addr)> {
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

/// The addresses `tailscale ip -4` names, looked up at most every five minutes (a process per look).
fn tailscale_addresses() -> Vec<Ipv4Addr> {
    static CACHE: Mutex<Option<(Instant, Vec<Ipv4Addr>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, found)) = cache.as_ref() {
        if at.elapsed() < Duration::from_secs(300) {
            return found.clone();
        }
    }
    let mut command = std::process::Command::new("tailscale");
    command.args(["ip", "-4"]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let found: Vec<Ipv4Addr> = command
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| l.trim().parse().ok()).collect())
        .unwrap_or_default();
    *cache = Some((Instant::now(), found.clone()));
    found
}

/// The `.local` name first (it follows the computer to a new address), then every address, local network first.
pub fn hosts(local_name: &str) -> Vec<ReachHost> {
    let addresses = interface_addresses();
    let confirmed = if addresses.iter().any(|(_, ip)| is_cgnat(*ip)) { tailscale_addresses() } else { Vec::new() };
    let mut hosts = vec![ReachHost { host: local_name.to_string(), tailnet: false }];
    let mut rest: Vec<ReachHost> = addresses
        .into_iter()
        .map(|(name, ip)| ReachHost {
            host: ip.to_string(),
            tailnet: is_cgnat(ip) && (name.to_ascii_lowercase().contains("tailscale") || confirmed.contains(&ip)),
        })
        .collect();
    rest.sort_by_key(|h| h.host.starts_with("100."));
    for h in rest {
        if !hosts.iter().any(|known| known.host == h.host) {
            hosts.push(h);
        }
    }
    hosts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_range() {
        assert!(is_cgnat("100.64.0.1".parse().unwrap()));
        assert!(is_cgnat("100.101.2.3".parse().unwrap()));
        assert!(!is_cgnat("100.128.0.1".parse().unwrap()));
        assert!(!is_cgnat("192.168.1.2".parse().unwrap()));
    }
}
