//! Hoe JSON-RPC-berichten bij een server komen: een lokaal programma (regels over stdin/stdout) of een server op
//! internet (Streamable HTTP: elk bericht is een POST, het antwoord is JSON of een korte event stream).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::oneshot;

use super::PROTOCOL_VERSION;
use crate::connectors::{CResult, ConnectorError, ErrorKind};

#[async_trait::async_trait]
pub trait McpTransport: Send + Sync {
    /// Stuurt een verzoek en geeft het bijbehorende antwoord (op id).
    async fn request(&self, message: Value) -> CResult<Value>;
    /// Stuurt een melding (geen antwoord).
    async fn notify(&self, message: Value) -> CResult<()>;
    fn close(&self);
}

/// Een argument voor een shell: zonder aanhalingstekens als het kan.
pub fn quote(text: &str) -> String {
    if !text.is_empty() && text.chars().all(|c| c.is_alphanumeric() || "-_./:=@+,~".contains(c)) {
        return text.to_string();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<CResult<Value>>>>>;

/// Een lokaal serverprogramma: JSON-RPC per regel over zijn stdin en stdout.
pub struct StdioTransport {
    stdin: tokio::sync::Mutex<Option<ChildStdin>>,
    child: Mutex<Option<Child>>,
    pending: Pending,
    closed: Arc<AtomicBool>,
    timeout: Duration,
}

fn stopped() -> ConnectorError {
    ConnectorError::kind("De MCP-server is gestopt.", ErrorKind::Network)
}

impl StdioTransport {
    /// Start het programma. Op Linux en macOS via de login-shell van de gebruiker, zodat `npx`, `uvx` en dergelijke
    /// op zijn PATH gevonden worden; op Windows via `cmd /C` (voor `npx.cmd`), zonder consolevenster.
    pub fn spawn(command: &str, arguments: &[String], environment: &[(String, String)], timeout: Duration) -> CResult<Self> {
        let mut cmd = Self::command(command, arguments);
        for (k, v) in environment {
            cmd.env(k, v);
        }
        cmd.env("NOOK_INTERNAL", "1")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let mut child = cmd.spawn().map_err(|e| ConnectorError::kind(format!("Kon de MCP-server niet starten: {e}"), ErrorKind::Config))?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().ok_or_else(stopped)?;
        let pending: Pending = Arc::default();
        let closed = Arc::new(AtomicBool::new(false));
        let (reader_pending, reader_closed) = (pending.clone(), closed.clone());
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                // Verzoeken van de server zelf (zonder antwoord van ons) worden genegeerd.
                if message.get("method").is_some() {
                    continue;
                }
                let Some(id) = message.get("id").map(id_key) else { continue };
                if let Some(tx) = reader_pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
                    let _ = tx.send(Ok(message));
                }
            }
            reader_closed.store(true, Ordering::SeqCst);
            for (_, tx) in reader_pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
                let _ = tx.send(Err(stopped()));
            }
        });
        Ok(Self { stdin: tokio::sync::Mutex::new(stdin), child: Mutex::new(Some(child)), pending, closed, timeout })
    }

    #[cfg(not(target_os = "windows"))]
    fn command(command: &str, arguments: &[String]) -> Command {
        let line = std::iter::once(command).chain(arguments.iter().map(String::as_str)).map(quote).collect::<Vec<_>>().join(" ");
        let shell =
            std::env::var("SHELL").ok().filter(|s| !s.is_empty() && std::path::Path::new(s).exists()).unwrap_or_else(|| "/bin/sh".into());
        let mut cmd = Command::new(shell);
        cmd.arg("-l").arg("-c").arg(format!("exec {line}"));
        cmd
    }

    #[cfg(target_os = "windows")]
    fn command(command: &str, arguments: &[String]) -> Command {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let mut cmd = Command::new("cmd");
        cmd.arg("/C").arg(command).args(arguments);
        cmd.creation_flags(CREATE_NO_WINDOW);
        cmd
    }

    async fn write(&self, message: &Value) -> CResult<()> {
        let mut guard = self.stdin.lock().await;
        let stdin = guard.as_mut().ok_or_else(stopped)?;
        let mut line = serde_json::to_vec(message).map_err(|e| ConnectorError::new(e.to_string()))?;
        line.push(b'\n');
        stdin.write_all(&line).await.map_err(|_| stopped())?;
        stdin.flush().await.map_err(|_| stopped())
    }
}

fn id_key(id: &Value) -> String {
    match id {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[async_trait::async_trait]
impl McpTransport for StdioTransport {
    async fn request(&self, message: Value) -> CResult<Value> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(ConnectorError::kind("De MCP-server draait niet.", ErrorKind::Network));
        }
        let id = message.get("id").map(id_key).ok_or_else(|| ConnectorError::new("MCP-verzoek zonder id."))?;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone(), tx);
        if let Err(e) = self.write(&message).await {
            self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
            return Err(e);
        }
        match tokio::time::timeout(self.timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(stopped()),
            Err(_) => {
                self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
                Err(ConnectorError::kind("De MCP-server antwoordde niet op tijd.", ErrorKind::Network))
            }
        }
    }

    async fn notify(&self, message: Value) -> CResult<()> {
        self.write(&message).await
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        if let Some(mut child) = self.child.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = child.start_kill();
        }
    }
}

impl Drop for StdioTransport {
    fn drop(&mut self) {
        self.close();
    }
}

/// Geeft het bearer-token van een server waarbij is ingelogd, vernieuwd als het (bijna) verlopen of geweigerd is.
#[async_trait::async_trait]
pub trait Authorizer: Send + Sync {
    async fn bearer_token(&self, force_refresh: bool) -> CResult<String>;
}

/// Een server op internet via Streamable HTTP.
pub struct HttpTransport {
    url: String,
    headers: Vec<(String, String)>,
    authorizer: Option<Arc<dyn Authorizer>>,
    session: Mutex<Option<String>>,
    client: reqwest::Client,
}

enum PostError {
    /// 401 met een token: vernieuwen en één keer opnieuw.
    Expired,
    Failed(ConnectorError),
}

impl HttpTransport {
    pub fn new(url: &str, headers: Vec<(String, String)>, authorizer: Option<Arc<dyn Authorizer>>) -> CResult<Self> {
        let parsed = url::Url::parse(url).map_err(|_| ConnectorError::kind(format!("Ongeldig adres: {url}"), ErrorKind::Config))?;
        let host = parsed.host_str().unwrap_or("");
        if parsed.scheme() != "https" && host != "localhost" && host != "127.0.0.1" {
            return Err(ConnectorError::kind("Een MCP-server op internet moet https gebruiken.", ErrorKind::Config));
        }
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60))
            .user_agent("Nook")
            .build()
            .unwrap_or_default();
        Ok(Self { url: url.into(), headers, authorizer, session: Mutex::new(None), client })
    }

    async fn post(&self, message: &Value) -> CResult<(String, Vec<u8>)> {
        let Some(authorizer) = &self.authorizer else {
            return self.post_with(message, None).await.map_err(|e| match e {
                PostError::Expired => expired(),
                PostError::Failed(e) => e,
            });
        };
        match self.post_with(message, Some(authorizer.bearer_token(false).await?)).await {
            Ok(r) => Ok(r),
            Err(PostError::Expired) => self.post_with(message, Some(authorizer.bearer_token(true).await?)).await.map_err(|e| match e {
                PostError::Expired => expired(),
                PostError::Failed(e) => e,
            }),
            Err(PostError::Failed(e)) => Err(e),
        }
    }

    async fn post_with(&self, message: &Value, token: Option<String>) -> Result<(String, Vec<u8>), PostError> {
        let mut request = self
            .client
            .post(&self.url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .header("MCP-Protocol-Version", PROTOCOL_VERSION)
            .body(message.to_string());
        for (k, v) in &self.headers {
            request = request.header(k, v);
        }
        if let Some(token) = &token {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        let session = self.session.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(session) = session {
            request = request.header("Mcp-Session-Id", session);
        }
        let response = request.send().await.map_err(|e| PostError::Failed(crate::connectors::network_error(e, "de MCP-server")))?;
        if let Some(id) = response.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()) {
            *self.session.lock().unwrap_or_else(|e| e.into_inner()) = Some(id.to_string());
        }
        let status = response.status().as_u16();
        let kind = response.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_lowercase();
        if !(200..300).contains(&status) {
            return Err(match status {
                401 if token.is_some() => PostError::Expired,
                401 | 403 => PostError::Failed(ConnectorError::kind(
                    format!(
                        "De MCP-server weigerde de toegang ({status}). Controleer de sleutel bij Instellingen › Accounts & koppelingen."
                    ),
                    ErrorKind::Auth,
                )),
                _ => PostError::Failed(ConnectorError::new(format!("De MCP-server gaf een fout ({status})."))),
            });
        }
        let bytes = response.bytes().await.map_err(|e| PostError::Failed(crate::connectors::network_error(e, "de MCP-server")))?;
        Ok((kind, bytes.to_vec()))
    }
}

fn expired() -> ConnectorError {
    ConnectorError::kind("Je inlog is verlopen. Log opnieuw in.", ErrorKind::Auth)
}

#[async_trait::async_trait]
impl McpTransport for HttpTransport {
    async fn request(&self, message: Value) -> CResult<Value> {
        let (kind, bytes) = self.post(&message).await?;
        let id = message.get("id").cloned().unwrap_or(json!(null));
        let text = String::from_utf8_lossy(&bytes);
        let candidates = if kind.contains("event-stream") {
            super::events_in(&text)
        } else {
            serde_json::from_str::<Value>(&text).ok().into_iter().collect()
        };
        candidates
            .into_iter()
            .find(|m| m.get("id").map(id_key) == Some(id_key(&id)))
            .ok_or_else(|| ConnectorError::new("De MCP-server stuurde geen antwoord op het verzoek."))
    }

    async fn notify(&self, message: Value) -> CResult<()> {
        self.post(&message).await.map(|_| ())
    }

    fn close(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_requires_https_except_on_this_computer() {
        assert!(HttpTransport::new("http://example.com/mcp", vec![], None).is_err());
        assert!(HttpTransport::new("https://example.com/mcp", vec![], None).is_ok());
        assert!(HttpTransport::new("http://localhost:3000/mcp", vec![], None).is_ok());
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("@modelcontextprotocol/server-github"), "@modelcontextprotocol/server-github");
        assert_eq!(quote("my server"), "'my server'");
        assert_eq!(quote("it's"), "'it'\\''s'");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stdio_server_round_trip() {
        use crate::connectors::mcp::McpClient;

        // Een piepkleine MCP-server in shell: antwoordt op initialize en tools/list, regel voor regel.
        let script = r#"while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"serverInfo":{"name":"sh"}}}\n' "$id" ;;
    *'"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","annotations":{"readOnlyHint":true}}]}}\n' "$id" ;;
  esac
done
"#;
        let file = std::env::temp_dir().join(format!("mcp-{}.sh", uuid::Uuid::new_v4()));
        std::fs::write(&file, script).unwrap();
        let transport = StdioTransport::spawn("/bin/sh", &[file.display().to_string()], &[], Duration::from_secs(10)).unwrap();
        let client = McpClient::new(Arc::new(transport));
        client.initialize().await.unwrap();
        assert_eq!(*client.server_name.lock().unwrap(), "sh");
        let tools = client.list_tools().await.unwrap();
        assert_eq!(tools.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["echo"]);
        client.close();
        let _ = std::fs::remove_file(file);
    }

    #[tokio::test]
    async fn http_server_with_event_stream() {
        use crate::connectors::testserver::TestServer;
        let server = TestServer::start(vec![(
            "POST /mcp",
            200,
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"serverInfo\":{\"name\":\"web\"}}}\n\n".into(),
        )])
        .await;
        let transport = HttpTransport::new(&server.url("/mcp"), vec![("X-Key".into(), "geheim".into())], None).unwrap();
        let answer = transport.request(json!({"jsonrpc": "2.0", "id": 2, "method": "initialize"})).await.unwrap();
        assert_eq!(answer["result"]["serverInfo"]["name"], "web");
        let sent = server.requests();
        assert_eq!(sent[0].header("x-key"), Some("geheim"));
        assert_eq!(sent[0].header("mcp-protocol-version"), Some(PROTOCOL_VERSION));
    }
}
