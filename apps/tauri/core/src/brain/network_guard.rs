//! Houdt de eigen webverzoeken van het brein weg van deze computer en het lokale netwerk.
//!
//! Een hostnaam alleen zegt niet genoeg: `printer.example.com` kan naar 192.168.1.20 wijzen en `2130706433` is 127.0.0.1.
//! Daarom wordt de host opgezocht en elk adres gecontroleerd, en worden omleidingen met de hand gevolgd zodat ook elke
//! tussenstap gecontroleerd wordt.

use std::net::{IpAddr, Ipv4Addr, ToSocketAddrs};
use std::time::Duration;

use crate::{NookError, Result};

/// Hosts die alleen al door hun naam privé zijn.
pub fn is_private_name(host: &str) -> bool {
    let lower = host.trim_matches(|c| c == '[' || c == ']' || c == '.').to_lowercase();
    if lower.is_empty() || lower == "localhost" {
        return true;
    }
    [".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".intranet"].iter().any(|s| lower.ends_with(s))
}

/// Of een IPv4-adres loopback, privé, link-local, gedeeld of anderszins niet openbaar is.
pub fn is_private_ipv4(address: u32) -> bool {
    let (a, b) = (address >> 24, (address >> 16) & 0xFF);
    match a {
        0 | 10 | 127 => true,
        100 => (64..=127).contains(&b),
        169 => b == 254,
        172 => (16..=31).contains(&b),
        192 => b == 168 || (b == 0 && (address >> 8) & 0xFF == 0),
        198 => b == 18 || b == 19,
        _ => a >= 224,
    }
}

/// Of een IPv6-adres loopback, ongespecificeerd, unique-local, link-local of een privé IPv4-adres is.
pub fn is_private_ipv6(bytes: &[u8; 16]) -> bool {
    if bytes[..15].iter().all(|b| *b == 0) {
        return true;
    }
    if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] == 0xFF {
        return true;
    }
    if bytes[..10].iter().all(|b| *b == 0) && bytes[10] == 0xFF && bytes[11] == 0xFF {
        return is_private_ipv4(u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]));
    }
    false
}

fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_private_ipv4(u32::from(v4)),
        IpAddr::V6(v6) => is_private_ipv6(&v6.octets()),
    }
}

/// Getallen zoals `2130706433` of `0x7f000001` die een resolver als IPv4-adres leest.
fn numeric_ipv4(host: &str) -> Option<Ipv4Addr> {
    let value = if let Some(hex) = host.strip_prefix("0x").or_else(|| host.strip_prefix("0X")) {
        u32::from_str_radix(hex, 16).ok()?
    } else {
        host.parse::<u32>().ok()?
    };
    Some(Ipv4Addr::from(value))
}

/// Zoekt de host op en geeft waar als een van de adressen niet openbaar is. Een onvindbare host telt als privé.
pub fn resolves_to_private(host: &str) -> bool {
    if is_private_name(host) {
        return true;
    }
    let name = host.trim_matches(|c| c == '[' || c == ']');
    if let Ok(ip) = name.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    if let Some(ip) = numeric_ipv4(name) {
        return is_private_ip(IpAddr::V4(ip));
    }
    match (name, 443).to_socket_addrs() {
        Ok(addresses) => {
            let list: Vec<IpAddr> = addresses.map(|a| a.ip()).collect();
            list.is_empty() || list.into_iter().any(is_private_ip)
        }
        Err(_) => true,
    }
}

/// Controleert schema en host van een adres dat het brein wil ophalen.
pub fn check(raw: &url::Url) -> Result<()> {
    if !matches!(raw.scheme(), "http" | "https") || raw.host_str().is_none_or(str::is_empty) {
        return Err(NookError::new("Ongeldig webadres."));
    }
    if !raw.username().is_empty() || raw.password().is_some() {
        return Err(NookError::new("Adressen met een login erin opent Nook niet."));
    }
    let host = raw.host_str().unwrap_or_default().to_string();
    if resolves_to_private(&host) {
        return Err(NookError::new("Nook opent geen adressen op deze computer of je lokale netwerk."));
    }
    Ok(())
}

pub const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

pub fn client() -> reqwest::Client {
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(reqwest::header::ACCEPT_LANGUAGE, reqwest::header::HeaderValue::from_static("nl-NL,nl;q=0.9,en;q=0.8"));
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(10))
        .user_agent(USER_AGENT)
        .default_headers(headers)
        .build()
        .unwrap_or_default()
}

/// Haalt een openbaar adres op en volgt hoogstens vijf omleidingen, elk opnieuw gecontroleerd.
pub async fn fetch(start: &str) -> Result<reqwest::Response> {
    let mut url = url::Url::parse(start).map_err(|_| NookError::new("Ongeldig webadres."))?;
    let client = client();
    for _ in 0..6 {
        let target = url.clone();
        tokio::task::spawn_blocking(move || check(&target)).await.map_err(|e| NookError(e.to_string()))??;
        let response = client.get(url.clone()).send().await?;
        let status = response.status();
        if status.is_redirection() {
            if let Some(next) =
                response.headers().get(reqwest::header::LOCATION).and_then(|l| l.to_str().ok()).and_then(|l| url.join(l).ok())
            {
                url = next;
                continue;
            }
        }
        return Ok(response);
    }
    Err(NookError::new("Die pagina stuurt te vaak door."))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v4(a: u32, b: u32, c: u32, d: u32) -> u32 {
        (a << 24) | (b << 16) | (c << 8) | d
    }

    #[test]
    fn private_ipv4_ranges() {
        for address in [
            v4(127, 0, 0, 1),
            v4(10, 1, 2, 3),
            v4(172, 16, 0, 1),
            v4(172, 31, 255, 255),
            v4(192, 168, 1, 20),
            v4(169, 254, 169, 254),
            v4(100, 64, 0, 1),
            v4(0, 0, 0, 0),
            v4(224, 0, 0, 1),
            v4(255, 255, 255, 255),
        ] {
            assert!(is_private_ipv4(address), "{address:x}");
        }
        for address in [v4(8, 8, 8, 8), v4(172, 32, 0, 1), v4(192, 169, 0, 1), v4(100, 128, 0, 1), v4(1, 1, 1, 1)] {
            assert!(!is_private_ipv4(address), "{address:x}");
        }
    }

    #[test]
    fn private_ipv6_ranges() {
        let mut loopback = [0u8; 16];
        loopback[15] = 1;
        let mut unique_local = [0u8; 16];
        unique_local[0] = 0xFD;
        let mut link_local = [0u8; 16];
        link_local[0] = 0xFE;
        link_local[1] = 0x80;
        let mut mapped = [0u8; 16];
        mapped[10..].copy_from_slice(&[0xFF, 0xFF, 192, 168, 0, 1]);
        let mut public = [0u8; 16];
        public[0] = 0x26;
        public[1] = 0x06;
        assert!(is_private_ipv6(&loopback) && is_private_ipv6(&unique_local) && is_private_ipv6(&link_local) && is_private_ipv6(&mapped));
        assert!(!is_private_ipv6(&public));
        assert!(is_private_ip(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)));
    }

    #[test]
    fn names_and_numeric_hosts_that_resolve_locally() {
        assert!(is_private_name("localhost") && is_private_name("printer.local"));
        assert!(resolves_to_private("[::1]"));
        assert!(resolves_to_private("127.0.0.1") && resolves_to_private("2130706433") && resolves_to_private("0x7f000001"));
        assert!(resolves_to_private("localhost"));
    }

    #[test]
    fn check_rejects_bad_urls() {
        for bad in ["file:///etc/passwd", "http://127.0.0.1:8080/admin", "https://user:pw@example.com/"] {
            assert!(check(&url::Url::parse(bad).unwrap()).is_err(), "{bad}");
        }
    }
}
