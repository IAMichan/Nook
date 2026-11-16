//! How the phone reaches the computer (`CompanionRoutes`, `CompanionRelay`, `CompanionWire` on the iPhone): every
//! address it knows (the one in the code, the others the code and the computer named, the last one that worked), and,
//! away from home, the relay the computer keeps a connection to. What travels is sealed before it leaves, so the relay
//! reads nothing. Large answers come compressed (`"\0NZ"`, raw DEFLATE) when the phone says it can open them.

use std::io::{Read, Write};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;

use super::client::{ClientError, HostResolver};

/// How long one route may take to connect before the next is tried.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// One way to the computer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Route {
    /// A host and port: this network, a VPN or Tailscale, or the internet.
    Direct { host: String, port: u16 },
    /// The relay (`https://…`), in the room only this phone and the computer know.
    Relay { relay: String, room: String },
}

impl Route {
    /// How this route reads to the person (the iPhone's route line): "lan", "tailnet", "internet" or "relay".
    pub fn kind(&self) -> &'static str {
        match self {
            Route::Relay { .. } => "relay",
            Route::Direct { host, .. } => {
                let h = host.to_ascii_lowercase();
                if h.ends_with(".local") || h.starts_with("192.168.") || h.starts_with("10.") || is_private_172(&h) || h.starts_with("fe80")
                {
                    "lan"
                } else if h.starts_with("100.") || h.ends_with(".ts.net") {
                    "tailnet"
                } else {
                    "internet"
                }
            }
        }
    }
}

fn is_private_172(h: &str) -> bool {
    h.strip_prefix("172.").and_then(|r| r.split('.').next()).and_then(|n| n.parse::<u8>().ok()).is_some_and(|n| (16..=31).contains(&n))
}

/// The relay room of a pairing (`CompanionRelay.room`): the first 16 bytes of HMAC-SHA256(key, label), as hex.
pub fn relay_room(key: &[u8]) -> String {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("any key length");
    mac.update(b"nook-companion-relay-room-v1");
    mac.finalize().into_bytes()[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// A relay address as `https://host[:port]` (`CompanionRelay.normalize`); plain http only for this machine.
pub fn normalize_relay(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let with_scheme = if trimmed.contains("://") { trimmed.to_string() } else { format!("https://{trimmed}") };
    let url = url::Url::parse(&with_scheme).ok()?;
    let host = url.host_str()?.to_ascii_lowercase();
    if host.is_empty() || !url.username().is_empty() || url.password().is_some() || !super::models::valid_host(&host) {
        return None;
    }
    let local = host == "localhost" || host == "127.0.0.1";
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return None;
    }
    Some(match url.port() {
        Some(p) => format!("{}://{host}:{p}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

/// The WebSocket a phone opens: `wss://host/v1/rooms/<room>?role=phone`.
pub fn relay_socket(relay: &str, room: &str) -> Option<String> {
    let base = normalize_relay(relay)?;
    let ws = base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    Some(format!("{ws}/v1/rooms/{room}?role=phone"))
}

/// An open connection over one route: bytes in, bytes out.
pub enum Conn {
    Tcp(TcpStream),
    Ws(Box<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>>),
}

impl Conn {
    pub async fn send(&mut self, bytes: &[u8]) -> Result<(), ClientError> {
        match self {
            Conn::Tcp(s) => s.write_all(bytes).await.map_err(|_| ClientError::Closed),
            Conn::Ws(s) => s.send(Message::Binary(bytes.to_vec().into())).await.map_err(|_| ClientError::Closed),
        }
    }

    /// The next bytes that arrive; an error when the connection ended.
    pub async fn recv(&mut self) -> Result<Vec<u8>, ClientError> {
        match self {
            Conn::Tcp(s) => {
                let mut buf = vec![0u8; 64 * 1024];
                match s.read(&mut buf).await {
                    Ok(0) | Err(_) => Err(ClientError::Closed),
                    Ok(n) => Ok(buf[..n].to_vec()),
                }
            }
            Conn::Ws(s) => loop {
                match s.next().await {
                    Some(Ok(Message::Binary(b))) => return Ok(b.to_vec()),
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return Err(ClientError::Closed),
                    Some(Ok(_)) => continue,
                }
            },
        }
    }
}

/// Opens a connection over one route.
pub async fn connect(route: &Route, resolver: &dyn HostResolver) -> Result<Conn, ClientError> {
    match route {
        Route::Direct { host, port } => {
            let addresses = resolver.resolve(host, *port).await;
            if addresses.is_empty() {
                return Err(ClientError::Unreachable(format!("{host} niet gevonden")));
            }
            let mut last = ClientError::Unreachable(host.clone());
            for addr in addresses {
                match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
                    Ok(Ok(s)) => return Ok(Conn::Tcp(s)),
                    Ok(Err(e)) => last = ClientError::Unreachable(e.to_string()),
                    Err(_) => last = ClientError::Timeout,
                }
            }
            Err(last)
        }
        Route::Relay { relay, room } => {
            let url = relay_socket(relay, room).ok_or(ClientError::Unreachable("relay".into()))?;
            let (ws, _) = tokio::time::timeout(CONNECT_TIMEOUT * 2, tokio_tungstenite::connect_async(url))
                .await
                .map_err(|_| ClientError::Timeout)?
                .map_err(|e| ClientError::Unreachable(format!("relay: {e}")))?;
            Ok(Conn::Ws(Box::new(ws)))
        }
    }
}

// Compression (`CompanionWire`).

pub const WIRE_MAGIC: [u8; 3] = [0x00, 0x4E, 0x5A];
pub const WIRE_DEFLATE: u8 = 0x64;
pub const WIRE_THRESHOLD: usize = 2 * 1024;
pub const WIRE_MAX_EXPANDED: usize = 8 * 1024 * 1024;

/// A message as it travels: compressed from 2 KB when that makes it smaller, else as it was.
pub fn pack(json: &[u8], compress: bool) -> Vec<u8> {
    if !compress || json.len() < WIRE_THRESHOLD || json.len() > WIRE_MAX_EXPANDED {
        return json.to_vec();
    }
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
    if encoder.write_all(json).is_err() {
        return json.to_vec();
    }
    let Ok(packed) = encoder.finish() else { return json.to_vec() };
    if packed.len() + 8 >= json.len() {
        return json.to_vec();
    }
    let mut out = WIRE_MAGIC.to_vec();
    out.push(WIRE_DEFLATE);
    out.extend_from_slice(&(json.len() as u32).to_be_bytes());
    out.extend_from_slice(&packed);
    out
}

/// The JSON of a message, opened when it came compressed; refused when it says it opens to more than 8 MB or opens to
/// another length than it says.
pub fn unpack(payload: &[u8]) -> Result<Vec<u8>, ClientError> {
    if !payload.starts_with(&WIRE_MAGIC) {
        return Ok(payload.to_vec());
    }
    if payload.len() < 8 || payload[3] != WIRE_DEFLATE {
        return Err(ClientError::BadResponse);
    }
    let length = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]) as usize;
    if length == 0 || length > WIRE_MAX_EXPANDED {
        return Err(ClientError::BadResponse);
    }
    let mut out = Vec::with_capacity(length);
    flate2::read::DeflateDecoder::new(&payload[8..]).take(length as u64 + 1).read_to_end(&mut out).map_err(|_| ClientError::BadResponse)?;
    if out.len() != length {
        return Err(ClientError::BadResponse);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compresses_large_messages_and_reads_plain_ones() {
        let big = serde_json::to_vec(&serde_json::json!({ "text": "a".repeat(5000) })).unwrap();
        let packed = pack(&big, true);
        assert!(packed.starts_with(&WIRE_MAGIC) && packed.len() < big.len());
        assert_eq!(unpack(&packed).unwrap(), big);
        assert_eq!(pack(b"{\"a\":1}", true), b"{\"a\":1}");
        assert_eq!(pack(&big, false), big);
        assert_eq!(unpack(b"{\"a\":1}").unwrap(), b"{\"a\":1}");
        let mut lying = packed.clone();
        lying[7] ^= 1;
        assert!(unpack(&lying).is_err());
    }

    #[test]
    fn relay_room_and_address() {
        let room = relay_room(&[7u8; 32]);
        assert_eq!(room.len(), 32);
        assert!(room.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(normalize_relay("relay.example.com"), Some("https://relay.example.com".into()));
        assert_eq!(normalize_relay("http://relay.example.com"), None);
        assert_eq!(normalize_relay("http://localhost:8787"), Some("http://localhost:8787".into()));
        assert_eq!(relay_socket("https://r.example", &room), Some(format!("wss://r.example/v1/rooms/{room}?role=phone")));
    }

    #[test]
    fn routes_say_how_they_reach() {
        let d = |h: &str| Route::Direct { host: h.into(), port: 1 };
        assert_eq!(d("mac.local").kind(), "lan");
        assert_eq!(d("172.20.0.4").kind(), "lan");
        assert_eq!(d("100.101.1.2").kind(), "tailnet");
        assert_eq!(d("203.0.113.9").kind(), "internet");
        assert_eq!(Route::Relay { relay: "https://r".into(), room: "x".into() }.kind(), "relay");
    }
}
