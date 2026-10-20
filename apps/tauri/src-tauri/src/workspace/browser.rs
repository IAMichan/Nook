//! De browser van Nook (`BrowserStore` op de Mac), als tweede webview-venster: je surft zoals gewoonlijk; Nook leest de
//! open pagina alleen als jij of een agent erom vraagt, en gaat alleen zelf ergens heen na jouw goedkeuring. Niets
//! blijft bewaard: het venster is incognito (geen cookies of opslag op schijf).
//!
//! Een webview geeft het resultaat van JavaScript hier niet terug. Daarom navigeert het script naar
//! `nook-result://<nonce>/<deel>/<totaal>?<tekst>`; Nook vangt die navigatie af (en annuleert hem) en plakt de delen
//! aan elkaar. Wat zo binnenkomt, is onbetrouwbare data van de pagina.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::agents::lock;

pub const LABEL: &str = "browser";
const SCHEME: &str = "nook-result";

/// Vangt console-fouten en -waarschuwingen (en onafgevangen fouten) van elke pagina op, zodat een agent die zijn
/// dev-server controleert ziet wat er misging. De lijst leeft in de pagina zelf en begint bij elke pagina leeg.
const CONSOLE_CAPTURE: &str = r#"(function () {
  if (window.__nookConsole) { return; }
  var log = [];
  window.__nookConsole = log;
  function keep(level, parts) {
    try {
      var text = Array.prototype.map.call(parts, function (p) {
        if (p instanceof Error) { return p.stack || String(p); }
        if (typeof p === 'object') { try { return JSON.stringify(p); } catch (e) { return String(p); } }
        return String(p);
      }).join(' ');
      log.push(level + ': ' + text.slice(0, 2000));
      if (log.length > 100) { log.shift(); }
    } catch (e) {}
  }
  ['error', 'warn'].forEach(function (level) {
    var original = console[level];
    console[level] = function () { keep(level, arguments); return original.apply(console, arguments); };
  });
  window.addEventListener('error', function (e) {
    keep('error', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]);
  });
  window.addEventListener('unhandledrejection', function (e) { keep('error', ['Unhandled rejection: ' + e.reason]); });
})();"#;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserState {
    pub open: bool,
    pub url: String,
    pub title: String,
    pub loading: bool,
    /// De agent die de huidige pagina via de werkruimte-brug opende; leeg zodra je zelf surft.
    pub opened_by: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Default)]
struct Pending {
    parts: Vec<Option<String>>,
    reply: Option<tokio::sync::oneshot::Sender<String>>,
}

#[derive(Default)]
pub struct Browser {
    state: Arc<Mutex<BrowserState>>,
    pending: Arc<Mutex<HashMap<String, Pending>>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageText {
    pub title: String,
    pub url: String,
    pub text: String,
}

/// Wat je typt: een adres, of anders een zoekopdracht (DuckDuckGo). Alleen http en https.
pub fn address(input: &str) -> Option<String> {
    let text = input.trim();
    if text.is_empty() {
        return None;
    }
    let lower = text.to_lowercase();
    // An explicit address, such as http://localhost:3000 from a dev server chip: open it as is, when it has a host.
    if (lower.starts_with("http://") || lower.starts_with("https://")) && !text.contains(' ') {
        return web_address(text);
    }
    if text.contains('.') && !text.contains(' ') || lower.starts_with("localhost") {
        let full = if lower.starts_with("localhost") || lower.starts_with("127.0.0.1") {
            format!("http://{text}")
        } else {
            format!("https://{text}")
        };
        return web_address(&full);
    }
    Some(format!("https://duckduckgo.com/?q={}", nook_core::workspace::source_control::encode(text)))
}

/// The address itself when it parses as http or https with a host; anything else (javascript:, file:) never reaches
/// the browser.
fn web_address(full: &str) -> Option<String> {
    let parsed = url::Url::parse(full).ok()?;
    (matches!(parsed.scheme(), "http" | "https") && parsed.host_str().is_some_and(|h| !h.is_empty())).then(|| full.to_string())
}

impl Browser {
    pub fn state(&self) -> BrowserState {
        lock(&self.state).clone()
    }

    fn changed(&self, app: &AppHandle) {
        let _ = app.emit("browser-changed", self.state());
    }

    /// Opent (of hergebruikt) het venster en gaat naar `url`. `agent`: wie hem opende via de brug.
    pub fn go(&self, app: &AppHandle, url: &str, agent: Option<String>) -> Result<(), String> {
        let parsed: tauri::Url = url.parse().map_err(|_| format!("Geen geldig adres: {url}"))?;
        {
            let mut s = lock(&self.state);
            s.opened_by = agent;
            s.last_error = None;
            s.loading = true;
            s.url = url.into();
        }
        if let Some(window) = app.get_webview_window(LABEL) {
            window.navigate(parsed).map_err(|e| e.to_string())?;
            let _ = window.show();
        } else {
            let state = self.state.clone();
            let pending = self.pending.clone();
            let handle = app.clone();
            let loads = self.state.clone();
            let load_handle = app.clone();
            WebviewWindowBuilder::new(app, LABEL, WebviewUrl::External(parsed))
                .title("Nook — Browser")
                .inner_size(1280.0, 800.0)
                .incognito(true)
                .initialization_script(CONSOLE_CAPTURE)
                .on_navigation(move |u| {
                    if u.scheme() == SCHEME {
                        receive(&pending, u);
                        return false;
                    }
                    if u.scheme() == "http" || u.scheme() == "https" || u.scheme() == "about" {
                        lock(&state).url = u.to_string();
                        return true;
                    }
                    let _ = handle.emit("browser-blocked", u.to_string());
                    false
                })
                .on_page_load(move |webview, payload| {
                    let mut s = lock(&loads);
                    s.url = payload.url().to_string();
                    s.loading = matches!(payload.event(), tauri::webview::PageLoadEvent::Started);
                    s.open = true;
                    drop(s);
                    let _ = load_handle.emit("browser-changed", ());
                    if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                        let app = webview.app_handle().clone();
                        tauri::async_runtime::spawn(async move {
                            let Some(ws) = app.try_state::<super::WorkspaceState>() else { return };
                            if let Ok(title) = ws.browser.evaluate(&app, "document.title").await {
                                lock(&ws.browser.state).title = title;
                                let _ = app.emit("browser-changed", ());
                            }
                        });
                    }
                })
                .build()
                .map_err(|e| format!("De browser openen lukte niet: {e}"))?;
            if let Some(w) = app.get_webview_window(LABEL) {
                let state = self.state.clone();
                let h = app.clone();
                w.on_window_event(move |e| {
                    if let tauri::WindowEvent::Destroyed = e {
                        *lock(&state) = BrowserState::default();
                        let _ = h.emit("browser-changed", ());
                    }
                });
            }
        }
        lock(&self.state).open = true;
        self.changed(app);
        Ok(())
    }

    /// Opent een pagina voor een agent en wacht (hooguit `timeout`) tot hij geladen is. Geeft de fout als het misging.
    pub async fn load_for(&self, app: &AppHandle, url: &str, agent: &str, timeout: Duration) -> Option<String> {
        if let Err(e) = self.go(app, url, Some(agent.into())) {
            return Some(e);
        }
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            tokio::time::sleep(Duration::from_millis(200)).await;
            if !lock(&self.state).loading {
                return lock(&self.state).last_error.clone();
            }
        }
        Some(format!("Still loading after {} seconds.", timeout.as_secs()))
    }

    pub fn eval(&self, app: &AppHandle, js: &str) -> Result<(), String> {
        let window = app.get_webview_window(LABEL).ok_or("Er staat geen pagina open in de browser van Nook.")?;
        window.eval(js).map_err(|e| e.to_string())
    }

    /// Voert `expression` uit in de pagina en geeft het resultaat als tekst.
    pub async fn evaluate(&self, app: &AppHandle, expression: &str) -> Result<String, String> {
        let nonce = uuid::Uuid::new_v4().simple().to_string();
        let (tx, rx) = tokio::sync::oneshot::channel();
        lock(&self.pending).insert(nonce.clone(), Pending { parts: vec![], reply: Some(tx) });
        let script = format!(
            r#"(function () {{
  var r = '';
  try {{ r = String((function () {{ return {expression}; }})()); }} catch (e) {{ r = ''; }}
  var size = 30000, total = Math.max(1, Math.ceil(r.length / size));
  for (var i = 0; i < total; i++) {{
    (function (i) {{
      setTimeout(function () {{ location.href = '{SCHEME}://{nonce}/' + i + '/' + total + '?' + encodeURIComponent(r.slice(i * size, (i + 1) * size)); }}, i * 40);
    }})(i);
  }}
}})();"#
        );
        if let Err(e) = self.eval(app, &script) {
            lock(&self.pending).remove(&nonce);
            return Err(e);
        }
        match tokio::time::timeout(Duration::from_secs(8), rx).await {
            Ok(Ok(text)) => Ok(text),
            _ => {
                lock(&self.pending).remove(&nonce);
                Err("De pagina antwoordde niet.".into())
            }
        }
    }

    /// De zichtbare tekst van de open pagina, met titel en adres.
    pub async fn page_text(&self, app: &AppHandle) -> Result<PageText, String> {
        let state = self.state();
        if !state.open || state.url.is_empty() {
            return Err("Er staat geen pagina open in de browser van Nook.".into());
        }
        let raw = self
            .evaluate(app, "JSON.stringify({t: document.title, u: location.href, x: document.body ? document.body.innerText : ''})")
            .await?;
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap_or_default();
        let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
        let text: String = s("x").trim().chars().take(14_000).collect();
        let url = if s("u").is_empty() { state.url.clone() } else { s("u") };
        let title = if s("t").is_empty() { url.clone() } else { s("t") };
        lock(&self.state).title = title.clone();
        Ok(PageText { title, url, text })
    }

    /// Console-fouten en -waarschuwingen sinds de pagina laadde.
    pub async fn console(&self, app: &AppHandle) -> Vec<String> {
        let Ok(raw) = self.evaluate(app, "JSON.stringify(window.__nookConsole || [])").await else { return vec![] };
        serde_json::from_str(&raw).unwrap_or_default()
    }

    pub fn close(&self, app: &AppHandle) {
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.close();
        }
        *lock(&self.state) = BrowserState::default();
        self.changed(app);
    }
}

fn receive(pending: &Mutex<HashMap<String, Pending>>, url: &tauri::Url) {
    let nonce = url.host_str().unwrap_or("").to_string();
    let parts: Vec<&str> = url.path().trim_start_matches('/').split('/').collect();
    let (Some(index), Some(total)) =
        (parts.first().and_then(|p| p.parse::<usize>().ok()), parts.get(1).and_then(|p| p.parse::<usize>().ok()))
    else {
        return;
    };
    if total == 0 || total > 200 || index >= total {
        return;
    }
    let text = url.query().map(percent_decode).unwrap_or_default();
    let mut map = lock(pending);
    let Some(entry) = map.get_mut(&nonce) else { return };
    if entry.parts.len() != total {
        entry.parts = vec![None; total];
    }
    entry.parts[index] = Some(text);
    if entry.parts.iter().all(Option::is_some) {
        let whole: String = entry.parts.iter().flatten().cloned().collect();
        if let Some(reply) = entry.reply.take() {
            let _ = reply.send(whole);
        }
        map.remove(&nonce);
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_and_searches() {
        assert_eq!(address("example.com").as_deref(), Some("https://example.com"));
        assert_eq!(address("localhost:5173").as_deref(), Some("http://localhost:5173"));
        assert_eq!(address("http://localhost:3000/x").as_deref(), Some("http://localhost:3000/x"));
        assert_eq!(address("http://localhost:3000").as_deref(), Some("http://localhost:3000"));
        assert_eq!(address("https://localhost:5173/app").as_deref(), Some("https://localhost:5173/app"));
        assert_eq!(address("HTTP://devbox:8080").as_deref(), Some("HTTP://devbox:8080"));
        assert_eq!(address("http://"), None);
        assert!(address("javascript:alert(1)").is_some_and(|a| a.starts_with("https://duckduckgo.com/?q=")));
        assert!(address("file:///etc/passwd").is_some_and(|a| a.starts_with("https://duckduckgo.com/?q=")));
        assert_eq!(address("rust borrow checker").as_deref(), Some("https://duckduckgo.com/?q=rust%20borrow%20checker"));
        assert!(address("  ").is_none());
    }

    #[test]
    fn decoding_and_parts() {
        assert_eq!(percent_decode("a%20b%C3%A9%2"), "a bé%2");
        let pending = Mutex::new(HashMap::new());
        let (tx, mut rx) = tokio::sync::oneshot::channel();
        lock(&pending).insert("abc".to_string(), Pending { parts: vec![], reply: Some(tx) });
        receive(&pending, &"nook-result://abc/1/2?wereld".parse().unwrap());
        assert!(rx.try_recv().is_err());
        receive(&pending, &"nook-result://abc/0/2?hallo%20".parse().unwrap());
        assert_eq!(rx.try_recv().unwrap(), "hallo wereld");
        assert!(lock(&pending).is_empty());
    }
}
