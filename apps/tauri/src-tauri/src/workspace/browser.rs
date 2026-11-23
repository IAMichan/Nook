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

/// Wat je typt: een adres, of anders een zoekopdracht met de zoekmachine uit Instellingen › Sessies › Editor & browser.
/// Alleen http en https.
pub fn address(input: &str) -> Option<String> {
    address_with(input, nook_core::workspace::open_in::OpenInPrefs::current().search_engine)
}

fn address_with(input: &str, engine: nook_core::workspace::open_in::SearchEngine) -> Option<String> {
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
    Some(engine.url(text))
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
            let _ = window.unminimize();
            let _ = window.set_focus();
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
                            // "Remember visited pages": the pages you visit, never the ones an agent opened.
                            let s = ws.browser.state();
                            if s.opened_by.is_none() && nook_core::workspace::open_in::OpenInPrefs::current().remember_history {
                                tauri::async_runtime::spawn_blocking(move || nook_core::workspace::browser_history::record(&s.url, &s.title));
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
  var size = 30000, chunks = [];
  for (var at = 0; at < r.length || chunks.length === 0; ) {{
    var end = Math.min(at + size, r.length), last = r.charCodeAt(end - 1);
    // Never end a piece inside a surrogate pair (an emoji): encodeURIComponent throws on half of one.
    if (end < r.length && last >= 0xD800 && last <= 0xDBFF) end--;
    chunks.push(r.slice(at, end));
    at = end;
  }}
  var total = chunks.length;
  for (var i = 0; i < total; i++) {{
    (function (i) {{
      setTimeout(function () {{ location.href = '{SCHEME}://{nonce}/' + i + '/' + total + '?' + encodeURIComponent(chunks[i]); }}, i * 40);
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

    /// A JPEG of what the page shows now, at most `max_width` pixels wide, with the page's address.
    pub async fn screenshot(&self, app: &AppHandle, max_width: u32) -> Result<(Vec<u8>, String), String> {
        let state = self.state();
        let window = app
            .get_webview_window(LABEL)
            .filter(|_| state.open)
            .ok_or("There is no page open in Nook's browser. Open one with browser_open first.")?;
        let png = super::snapshot::png(&window).await?;
        let (jpeg, _, _) =
            tauri::async_runtime::spawn_blocking(move || super::snapshot::shrink(&png, max_width)).await.map_err(|e| e.to_string())??;
        Ok((jpeg, state.url))
    }

    pub fn close(&self, app: &AppHandle) {
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.close();
        }
        *lock(&self.state) = BrowserState::default();
        self.changed(app);
    }

    /// Starts interactive click-to-pick mode in Nook's browser window (`BrowserPickScript` on macOS, AG-105).
    /// Waits up to 60 seconds for the user to click an element in the browser window or press Escape.
    pub async fn pick_element(&self, app: &AppHandle) -> Result<Option<PickedElement>, String> {
        let state = self.state();
        if !state.open || state.url.is_empty() {
            return Err(nook_core::i18n::tr("Er staat geen pagina open in de browser van Nook.", "No page is open in Nook's browser.").into());
        }
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.show();
            let _ = w.unminimize();
            let _ = w.set_focus();
        }
        let nonce = uuid::Uuid::new_v4().simple().to_string();
        let (tx, rx) = tokio::sync::oneshot::channel();
        lock(&self.pending).insert(nonce.clone(), Pending { parts: vec![], reply: Some(tx) });
        let script = pick_script(&nonce);
        if let Err(e) = self.eval(app, &script) {
            lock(&self.pending).remove(&nonce);
            return Err(e);
        }
        let raw = match tokio::time::timeout(Duration::from_secs(60), rx).await {
            Ok(Ok(text)) => text,
            _ => {
                lock(&self.pending).remove(&nonce);
                let _ = self.cancel_pick(app);
                return Ok(None);
            }
        };
        if raw.trim().is_empty() || raw.trim() == "null" {
            return Ok(None);
        }
        let v: serde_json::Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        if v.get("cancelled").and_then(|c| c.as_bool()) == Some(true) {
            return Ok(None);
        }
        Ok(PickedElement::from_json(&v))
    }

    /// Cancels interactive element picking in the browser window (`BrowserPickScript.cancel`, AG-105).
    pub fn cancel_pick(&self, app: &AppHandle) -> Result<(), String> {
        self.eval(app, "if (window.__nookCancelPick) window.__nookCancelPick(true);")
    }

    /// Clears picked element outlines in the browser window (`BrowserPickScript.clear`, AG-105).
    pub fn clear_picks(&self, app: &AppHandle) -> Result<(), String> {
        self.eval(app, "if (window.__nookClearPicks) window.__nookClearPicks();")
    }

    /// Lists interactive & structural elements on the open page so the user can also pick directly from the Browser panel (AG-105).
    pub async fn page_elements(&self, app: &AppHandle) -> Result<Vec<PickedElement>, String> {
        let state = self.state();
        if !state.open || state.url.is_empty() {
            return Err(nook_core::i18n::tr("Er staat geen pagina open in de browser van Nook.", "No page is open in Nook's browser.").into());
        }
        let raw = self.evaluate(app, PAGE_ELEMENTS_SCRIPT).await?;
        let arr: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap_or_default();
        Ok(arr.iter().filter_map(PickedElement::from_json).collect())
    }
}

/// An element on a page in Nook's browser that you pointed at to talk about with the agent (`PickedElement` on macOS, AG-105).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedElement {
    pub url: String,
    pub selector: String,
    pub text: String,
    pub label: String,
    pub html: String,
    pub name: String,
    pub snippet: String,
}

impl PickedElement {
    pub fn new(url: String, selector: String, text: String, label: String, html: String) -> Self {
        let short_label: String = label.chars().take(36).collect();
        let name = if !short_label.is_empty() {
            format!("{selector} \"{short_label}\"")
        } else {
            selector.clone()
        };
        let mut lines = vec![format!("[Element on {url}: `{selector}`]")];
        if !label.is_empty() && label != text {
            lines.push(format!("Label: {label}"));
        }
        if !text.is_empty() {
            lines.push(format!("Text: \"{text}\""));
        }
        if !html.is_empty() {
            lines.push(format!("```html\n{html}\n```"));
        }
        let snippet = lines.join("\n");
        Self { url, selector, text, label, html, name, snippet }
    }

    pub fn from_json(v: &serde_json::Value) -> Option<Self> {
        let selector = v.get("selector").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        if selector.is_empty() {
            return None;
        }
        let url = v.get("url").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        let text = v.get("text").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        let label = v.get("label").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        let html = v.get("html").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        Some(Self::new(url, selector, text, label, html))
    }
}

fn pick_script(nonce: &str) -> String {
    format!(
        r##"(function () {{
  if (window.__nookCancelPick) window.__nookCancelPick(false);
  var box = document.createElement('div');
  box.setAttribute('data-nook-pick', '1');
  box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #2b6cb0;background:rgba(43,108,176,0.10);border-radius:4px;transition:all 40ms ease-out;display:none';
  document.documentElement.appendChild(box);
  var tag = document.createElement('div');
  tag.setAttribute('data-nook-pick', '1');
  tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#1a202c;color:#fff;font:500 11px/1.3 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;padding:2px 6px;border-radius:4px;white-space:nowrap;max-width:360px;overflow:hidden;text-overflow:ellipsis;display:none';
  document.documentElement.appendChild(tag);
  function cssEscape(s) {{ return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }}
  function part(el) {{
    var name = el.tagName.toLowerCase();
    if (el.id) return name + '#' + cssEscape(el.id);
    var testId = el.getAttribute('data-testid') || el.getAttribute('data-test');
    if (testId) return name + '[data-testid="' + testId.replace(/"/g, '\\"') + '"]';
    var classes = Array.from(el.classList || []).filter(function (c) {{ return c && c.length < 36 && !/^[0-9]/.test(c); }}).slice(0, 2);
    var s = name + (classes.length ? '.' + classes.map(cssEscape).join('.') : '');
    var parent = el.parentElement;
    if (parent) {{
      var same = Array.from(parent.children).filter(function (c) {{ return c.tagName === el.tagName; }});
      if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
    }}
    return s;
  }}
  function selector(el) {{
    var parts = [], cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.body && cur !== document.documentElement && parts.length < 4) {{
      var p = part(cur);
      parts.unshift(p);
      if (cur.id || cur.getAttribute('data-testid')) break;
      cur = cur.parentElement;
    }}
    return parts.join(' > ') || (el.tagName ? el.tagName.toLowerCase() : 'body');
  }}
  function clean(s, max) {{ return String(s || '').replace(/\s+/g, ' ').trim().slice(0, max); }}
  function target(e) {{
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el.getAttribute('data-nook-pick')) return null;
    return el;
  }}
  function move(e) {{
    var el = target(e);
    if (!el) {{ box.style.display = 'none'; tag.style.display = 'none'; return; }}
    var r = el.getBoundingClientRect();
    box.style.display = 'block';
    box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
    box.style.width = Math.max(r.width, 4) + 'px'; box.style.height = Math.max(r.height, 4) + 'px';
    tag.textContent = selector(el);
    tag.style.display = 'block';
    tag.style.left = Math.max(4, Math.min(r.left, window.innerWidth - 260)) + 'px';
    tag.style.top = (r.top > 24 ? r.top - 22 : r.bottom + 4) + 'px';
  }}
  function sendResult(obj) {{
    var r = JSON.stringify(obj);
    location.href = '{SCHEME}://{nonce}/0/1?' + encodeURIComponent(r);
  }}
  function click(e) {{
    e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
    var el = target(e) || e.target;
    stop();
    if (!el || !el.tagName) {{ sendResult({{ cancelled: true }}); return; }}
    markPicked(el);
    var clone = el.cloneNode(true);
    Array.from(clone.querySelectorAll('[data-nook-picked],[data-nook-pick]')).forEach(function (n) {{ n.removeAttribute('data-nook-picked'); }});
    clone.removeAttribute('data-nook-picked');
    sendResult({{
      url: location.href,
      selector: selector(el),
      text: clean(el.innerText || el.value || '', 280),
      label: clean(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('title') || '', 140),
      html: clean(clone.outerHTML || '', 600)
    }});
  }}
  function markPicked(el) {{
    if (!document.getElementById('__nook-picked-style')) {{
      var st = document.createElement('style');
      st.id = '__nook-picked-style';
      st.textContent = '[data-nook-picked]{{outline:2px solid #2b6cb0 !important;outline-offset:2px !important}}';
      document.head.appendChild(st);
    }}
    el.setAttribute('data-nook-picked', '1');
  }}
  window.__nookClearPicks = function () {{
    Array.from(document.querySelectorAll('[data-nook-picked]')).forEach(function (el) {{ el.removeAttribute('data-nook-picked'); }});
  }};
  function key(e) {{
    if (e.key === 'Escape') {{ e.preventDefault(); e.stopPropagation(); stop(); sendResult({{ cancelled: true }}); }}
  }}
  function stop() {{
    window.removeEventListener('mousemove', move, true);
    window.removeEventListener('click', click, true);
    window.removeEventListener('keydown', key, true);
    box.remove(); tag.remove();
    window.__nookCancelPick = null;
  }}
  window.__nookCancelPick = function (notify) {{
    stop();
    if (notify) sendResult({{ cancelled: true }});
  }};
  window.addEventListener('mousemove', move, true);
  window.addEventListener('click', click, true);
  window.addEventListener('keydown', key, true);
}})();"##
    )
}

const PAGE_ELEMENTS_SCRIPT: &str = r##"JSON.stringify((function () {
  function cssEscape(s) { return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
  function part(el) {
    var name = el.tagName.toLowerCase();
    if (el.id) return name + '#' + cssEscape(el.id);
    var testId = el.getAttribute('data-testid') || el.getAttribute('data-test');
    if (testId) return name + '[data-testid="' + testId.replace(/"/g, '\\"') + '"]';
    var classes = Array.from(el.classList || []).filter(function (c) { return c && c.length < 36 && !/^[0-9]/.test(c); }).slice(0, 2);
    var s = name + (classes.length ? '.' + classes.map(cssEscape).join('.') : '');
    var parent = el.parentElement;
    if (parent) {
      var same = Array.from(parent.children).filter(function (c) { return c.tagName === el.tagName; });
      if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
    }
    return s;
  }
  function selector(el) {
    var parts = [], cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.body && cur !== document.documentElement && parts.length < 4) {
      var p = part(cur);
      parts.unshift(p);
      if (cur.id || cur.getAttribute('data-testid')) break;
      cur = cur.parentElement;
    }
    return parts.join(' > ') || (el.tagName ? el.tagName.toLowerCase() : 'body');
  }
  function clean(s, max) { return String(s || '').replace(/\s+/g, ' ').trim().slice(0, max); }
  var nodes = Array.from(document.querySelectorAll('h1,h2,h3,button,a[href],input,textarea,select,[role="button"],[data-testid],form,nav,header,main,section'));
  var seen = {}, out = [];
  for (var i = 0; i < nodes.length && out.length < 32; i++) {
    var el = nodes[i];
    if (!el || !el.tagName || el.getAttribute('data-nook-pick')) continue;
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    var sel = selector(el);
    if (!sel || seen[sel]) continue;
    var text = clean(el.innerText || el.value || '', 280);
    var label = clean(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('title') || '', 140);
    if (!text && !label && !el.id && !el.getAttribute('data-testid')) continue;
    seen[sel] = true;
    out.push({
      url: location.href,
      selector: sel,
      text: text,
      label: label,
      html: clean(el.outerHTML || '', 600)
    });
  }
  return out;
})())"##;

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
        use nook_core::workspace::open_in::SearchEngine;
        let address = |input: &str| address_with(input, SearchEngine::DuckDuckGo);
        assert_eq!(address_with("nook settings", SearchEngine::Google).as_deref(), Some("https://www.google.com/search?q=nook%20settings"));
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

    #[test]
    fn picked_element_formats_snippet() {
        let el = PickedElement::new(
            "http://localhost:3000/login".into(),
            "form > button.submit".into(),
            "Sign in".into(),
            "Submit login form".into(),
            "<button class=\"submit\">Sign in</button>".into(),
        );
        assert_eq!(el.name, "form > button.submit \"Submit login form\"");
        assert!(el.snippet.contains("[Element on http://localhost:3000/login: `form > button.submit`]"));
        assert!(el.snippet.contains("Label: Submit login form"));
        assert!(el.snippet.contains("Text: \"Sign in\""));
        assert!(el.snippet.contains("```html\n<button class=\"submit\">Sign in</button>\n```"));
    }
}
