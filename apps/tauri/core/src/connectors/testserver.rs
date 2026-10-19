//! Een piepkleine HTTP-server voor tests: vaste antwoorden per pad, en wat er binnenkwam.

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Received {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Received {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

pub struct TestServer {
    pub port: u16,
    pub received: Arc<Mutex<Vec<Received>>>,
}

impl TestServer {
    /// `routes`: ("/pad" of "POST /pad", status, body). Het pad wordt zonder querystring vergeleken; de langste
    /// passende route wint, een route die op `*` eindigt past op alles wat ermee begint.
    pub async fn start(routes: Vec<(&'static str, u16, String)>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let received = Arc::new(Mutex::new(vec![]));
        let log = received.clone();
        let routes = Arc::new(routes);
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { break };
                let routes = routes.clone();
                let log = log.clone();
                tokio::spawn(async move {
                    let mut buffer = vec![];
                    let mut chunk = [0u8; 8192];
                    let (head, body) = loop {
                        let Ok(n) = socket.read(&mut chunk).await else { return };
                        if n == 0 {
                            return;
                        }
                        buffer.extend_from_slice(&chunk[..n]);
                        if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&buffer[..end]).to_string();
                            let length = head
                                .lines()
                                .find_map(|l| {
                                    l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0))
                                })
                                .unwrap_or(0);
                            while buffer.len() < end + 4 + length {
                                let Ok(n) = socket.read(&mut chunk).await else { return };
                                if n == 0 {
                                    break;
                                }
                                buffer.extend_from_slice(&chunk[..n]);
                            }
                            let body = String::from_utf8_lossy(&buffer[end + 4..(end + 4 + length).min(buffer.len())]).to_string();
                            break (head, body);
                        }
                    };
                    let mut lines = head.lines();
                    let first: Vec<&str> = lines.next().unwrap_or("").split(' ').collect();
                    let method = first.first().copied().unwrap_or("").to_string();
                    let path = first.get(1).copied().unwrap_or("").to_string();
                    let headers =
                        lines.filter_map(|l| l.split_once(':').map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))).collect();
                    log.lock().unwrap().push(Received { method: method.clone(), path: path.clone(), headers, body });
                    let bare = path.split('?').next().unwrap_or("");
                    let matches = |route: &str| {
                        let (m, p) = route.split_once(' ').unwrap_or(("", route));
                        let method_ok = m.is_empty() || m == method;
                        let path_ok = match p.strip_suffix('*') {
                            Some(prefix) => bare.starts_with(prefix),
                            None => p == bare,
                        };
                        method_ok && path_ok
                    };
                    let found = routes.iter().filter(|(r, _, _)| matches(r)).max_by_key(|(r, _, _)| r.len());
                    let (status, body) = found.map(|(_, s, b)| (*s, b.clone())).unwrap_or((404, "{}".into()));
                    let trimmed = body.trim_start();
                    let kind = if trimmed.starts_with('{') || trimmed.starts_with('[') {
                        "application/json"
                    } else if trimmed.starts_with("event:") || trimmed.starts_with("data:") {
                        "text/event-stream"
                    } else {
                        "text/plain"
                    };
                    let response = format!(
                        "HTTP/1.1 {status} X\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        Self { port, received }
    }

    pub fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    pub fn requests(&self) -> Vec<Received> {
        self.received.lock().unwrap().clone()
    }
}
