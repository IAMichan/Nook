//! Linking a chat app through Nook's chat helper (`ChatLinkData` and `WebSignInAgent` on the Mac): which apps it can
//! link and with which accounts (`/v1/bridges`), the steps of one login (`/v1/bridges/{id}/login-sessions`), and what a
//! "sign in on the website" step collects in Nook's sign-in window. The window itself is in
//! `src-tauri/src/chats/sign_in.rs`.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Map, Value};

use super::chatd;

/// One app the helper can link, with the accounts already linked in it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    /// The helper's id for it (`local-whatsapp`): where its logins start.
    pub id: String,
    /// The app in Nook.
    pub app: String,
    pub name: String,
    /// It can link an account now.
    pub can_link: bool,
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    /// The login it belongs to, for unlinking it.
    pub login: Option<String>,
    /// Who is signed in: their name, else their username, phone number or email.
    pub name: String,
    pub is_connected: bool,
    /// Why it is not connected, in the helper's words.
    pub status: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionState {
    WaitingForInput,
    WaitingForCookies,
    WaitingForDisplay,
    Complete,
    Cancelled,
    Failed,
}

impl SessionState {
    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "waiting_for_input" => Self::WaitingForInput,
            "waiting_for_cookies" => Self::WaitingForCookies,
            "waiting_for_display" => Self::WaitingForDisplay,
            "complete" => Self::Complete,
            "cancelled" => Self::Cancelled,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

/// Where one login stands.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub network: String,
    pub state: SessionState,
    pub step: Option<Step>,
    /// Why it failed, in the network's own words.
    pub problem: Option<String>,
}

impl Session {
    pub fn is_over(&self) -> bool {
        matches!(self.state, SessionState::Complete | SessionState::Cancelled | SessionState::Failed)
    }
}

/// What the login asks for next.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Step {
    /// Fields to fill in (a phone number, a code, a password).
    Input { id: String, instructions: String, fields: Vec<Field> },
    /// Signing in on the app's own website, in the sign-in window: what to collect once the address matches. `extract`
    /// is the step's own script that finds the `special` values (Slack's token) in the page.
    Browser {
        id: String,
        instructions: String,
        url: String,
        user_agent: Option<String>,
        collect: Vec<Collect>,
        done: Option<String>,
        extract: Option<String>,
    },
    /// Something to show while the login waits (a QR code, a code to type on the phone).
    Display { id: String, instructions: String, show: Display },
    Complete { instructions: String },
}

impl Step {
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::Input { id, .. } | Self::Browser { id, .. } | Self::Display { id, .. } => Some(id),
            Self::Complete { .. } => None,
        }
    }

    /// The step's type, as it is sent back with what it asked for.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Input { .. } => "user_input",
            Self::Browser { .. } => "cookies",
            Self::Display { .. } => "display_and_wait",
            Self::Complete { .. } => "complete",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    pub id: String,
    pub label: String,
    pub placeholder: String,
    pub initial: String,
    pub is_secret: bool,
    pub is_optional: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Cookie,
    Header,
    LocalStorage,
    Special,
}

/// A value the browser step collects: a cookie, a request header the page sends, a local storage key, or one the step's
/// own script finds in the page (by the value's id).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Collect {
    pub id: String,
    pub source: Source,
    pub name: String,
    /// The sign-in is only handed over once every required value is there.
    pub is_required: bool,
    /// What the value must contain to count (a regular expression), when the step says so.
    pub pattern: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "type", content = "value")]
pub enum Display {
    Qr(String),
    Code(String),
    Image(String),
    Nothing,
}

fn string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The apps of `/v1/bridges` that Nook knows, one per app (a local one before a cloud one), by name. `name` gives an
/// app's own name in Nook, when it has one.
pub fn networks(json: &Value, name: impl Fn(&str) -> Option<String>) -> Vec<Network> {
    let mut by_app: HashMap<String, (Network, bool)> = HashMap::new();
    for bridge in json.get("items").and_then(Value::as_array).into_iter().flatten() {
        let Some(id) = string(bridge.get("id")) else { continue };
        let words: Vec<String> =
            ["type", "displayName", "network"].iter().filter_map(|k| string(bridge.get(*k))).chain([id.clone()]).collect();
        let Some(app) = chatd::app(&words.join(" "), "") else { continue };
        let status = bridge.get("status").and_then(Value::as_str).unwrap_or_default();
        let network = Network {
            id: id.clone(),
            app: app.to_string(),
            name: name(app).or_else(|| string(bridge.get("displayName"))).unwrap_or(id),
            can_link: status == "available" || status == "connected",
            accounts: bridge.get("accounts").and_then(Value::as_array).into_iter().flatten().filter_map(account).collect(),
        };
        let local = bridge.get("provider").and_then(Value::as_str) == Some("local");
        match by_app.remove(app) {
            // The accounts of both show; links start where the first one runs.
            Some((mut known, known_local)) if known_local || !local => {
                known.accounts.extend(network.accounts);
                by_app.insert(app.to_string(), (known, known_local));
            }
            other => {
                let mut chosen = network;
                if let Some((known, _)) = other {
                    chosen.accounts.extend(known.accounts);
                }
                by_app.insert(app.to_string(), (chosen, local));
            }
        }
    }
    let mut list: Vec<Network> = by_app.into_values().map(|(n, _)| n).collect();
    list.sort_by_key(|n| n.name.to_lowercase());
    list
}

/// The name of the one account linked for `app`; `None` with none or with several, where a chat must say its own.
pub fn only_account(app: &str, networks: &[Network]) -> Option<String> {
    let accounts: Vec<&Account> = networks.iter().filter(|n| n.app == app).flat_map(|n| &n.accounts).collect();
    (accounts.len() == 1).then(|| accounts[0].name.clone())
}

pub fn account(json: &Value) -> Option<Account> {
    let id = string(json.get("accountID"))?;
    let user = json.get("user");
    let name = ["fullName", "username", "phoneNumber", "email"]
        .iter()
        .find_map(|k| string(user.and_then(|u| u.get(*k))))
        .unwrap_or_else(|| id.clone());
    let status = json.get("status").and_then(Value::as_str).unwrap_or_default();
    let connected = matches!(status, "connected" | "connecting" | "backfilling");
    Some(Account {
        id,
        login: string(json.get("loginID")),
        name,
        is_connected: connected,
        status: (!connected).then(|| string(json.get("statusText")).unwrap_or_else(|| status.to_string())),
    })
}

/// A login session as `/v1/bridges/{id}/login-sessions` answers it.
pub fn session(json: &Value) -> Option<Session> {
    Some(Session {
        id: string(json.get("loginSessionID"))?,
        network: string(json.get("bridgeID"))?,
        state: SessionState::parse(json.get("status")?.as_str()?)?,
        step: json.get("currentStep").and_then(step),
        problem: string(json.pointer("/error/message")),
    })
}

pub fn step(json: &Value) -> Option<Step> {
    let id = json.get("stepID").and_then(Value::as_str).unwrap_or_default().to_string();
    let instructions = json.get("instructions").and_then(Value::as_str).unwrap_or_default().trim().to_string();
    let fields = || json.get("fields").and_then(Value::as_array).into_iter().flatten();
    match json.get("type").and_then(Value::as_str)? {
        "user_input" if !id.is_empty() => Some(Step::Input {
            id,
            instructions,
            fields: fields()
                .filter_map(|f| {
                    let field = string(f.get("id"))?;
                    Some(Field {
                        label: string(f.get("label")).unwrap_or_else(|| field.clone()),
                        placeholder: string(f.get("placeholder")).unwrap_or_default(),
                        initial: f.get("initialValue").and_then(Value::as_str).unwrap_or_default().to_string(),
                        is_secret: f.get("type").and_then(Value::as_str) == Some("password"),
                        is_optional: f.get("optional").and_then(Value::as_bool) == Some(true),
                        id: field,
                    })
                })
                .collect(),
        }),
        "cookies" if !id.is_empty() => {
            let url = string(json.get("url")).filter(|u| url::Url::parse(u).is_ok_and(|u| u.scheme() == "https"))?;
            Some(Step::Browser {
                id,
                instructions,
                url,
                user_agent: string(json.get("userAgent")),
                collect: fields()
                    .filter_map(|f| {
                        let field = string(f.get("id"))?;
                        let source = match f.get("type").and_then(Value::as_str).unwrap_or("cookie") {
                            "header" => Source::Header,
                            "local_storage" => Source::LocalStorage,
                            "special" => Source::Special,
                            _ => Source::Cookie,
                        };
                        Some(Collect {
                            name: string(f.get("name")).unwrap_or_else(|| field.clone()),
                            id: field,
                            source,
                            is_required: f.get("required").and_then(Value::as_bool).unwrap_or(true),
                            pattern: string(f.get("pattern")),
                        })
                    })
                    .collect(),
                done: string(json.get("expectedFinalURLRegex")),
                extract: string(json.get("extractJS")),
            })
        }
        "display_and_wait" if !id.is_empty() => {
            let display = json.get("display");
            let data = string(display.and_then(|d| d.get("data")));
            let show = match display.and_then(|d| d.get("type")).and_then(Value::as_str) {
                Some("qr") => data.map(Display::Qr),
                Some("code") => data.map(Display::Code),
                Some("emoji") => string(display.and_then(|d| d.get("imageURL"))).map(Display::Image),
                _ => None,
            };
            Some(Step::Display { id, instructions, show: show.unwrap_or(Display::Nothing) })
        }
        "complete" => Some(Step::Complete { instructions }),
        _ => None,
    }
}

/// What goes back for a step: its type, and the values it asked for by their ids.
pub fn answer(step: &Step, values: &HashMap<String, String>, last_url: Option<&str>) -> Value {
    let mut body = Map::new();
    body.insert("type".into(), json!(step.kind()));
    if !values.is_empty() {
        body.insert("fields".into(), json!(values));
    }
    if matches!(step, Step::Browser { .. }) {
        body.insert("source".into(), json!("webview"));
        if let Some(last) = last_url {
            body.insert("lastURL".into(), json!(last));
        }
    }
    Value::Object(body)
}

fn matches(text: &str, pattern: &str) -> bool {
    Regex::new(pattern).is_ok_and(|r| r.is_match(text))
}

/// Whether the browser reached the address that says the sign-in is done; without a pattern the values are enough.
pub fn is_done(address: &str, pattern: Option<&str>) -> bool {
    pattern.is_some_and(|p| matches(address, p))
}

/// The values a browser step collects from the cookies there (by name), the request headers the page sent (by name, any
/// case; a "Cookie" header is the cookies themselves), local storage (by key) and the step's script (by id). A value
/// that does not match the step's pattern does not count.
pub fn collected(
    collect: &[Collect],
    cookies: &HashMap<String, String>,
    storage: &HashMap<String, String>,
    headers: &HashMap<String, String>,
    special: &HashMap<String, String>,
) -> HashMap<String, String> {
    let mut values = HashMap::new();
    for item in collect {
        let value = match item.source {
            Source::Cookie => cookies.get(&item.name).cloned(),
            Source::LocalStorage => storage.get(&item.name).cloned(),
            Source::Special => special.get(&item.id).cloned(),
            Source::Header if item.name.eq_ignore_ascii_case("cookie") => cookie_header(cookies),
            Source::Header => headers.get(&item.name.to_lowercase()).cloned(),
        };
        let Some(value) = value.filter(|v| !v.is_empty()) else { continue };
        if item.pattern.as_deref().is_some_and(|p| !matches(&value, p)) {
            continue;
        }
        values.insert(item.id.clone(), value);
    }
    values
}

/// The cookies as a browser sends them in its "Cookie" header.
pub fn cookie_header(cookies: &HashMap<String, String>) -> Option<String> {
    if cookies.is_empty() {
        return None;
    }
    let mut pairs: Vec<(&String, &String)> = cookies.iter().collect();
    pairs.sort();
    Some(pairs.into_iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
}

/// Every cookie and header the step needs is there.
pub fn has_cookies(collect: &[Collect], values: &HashMap<String, String>) -> bool {
    let needed: Vec<&Collect> = collect.iter().filter(|c| c.source != Source::LocalStorage && c.is_required).collect();
    !needed.is_empty() && needed.iter().all(|c| values.contains_key(&c.id))
}

/// The request headers a step asks for that the page itself sets (all but "Cookie"), in lower case.
pub fn page_headers(collect: &[Collect]) -> Vec<String> {
    collect
        .iter()
        .filter(|c| c.source == Source::Header && !c.name.eq_ignore_ascii_case("cookie"))
        .map(|c| c.name.to_lowercase())
        .collect()
}

/// A cookie of the site the step started on, or of a domain it belongs to (".instagram.com").
pub fn belongs(domain: &str, start: &str) -> bool {
    let Some(host) = url::Url::parse(start).ok().and_then(|u| u.host_str().map(str::to_lowercase)) else { return false };
    let lower = domain.to_lowercase();
    let bare = lower.trim_start_matches('.');
    let parts: Vec<&str> = host.split('.').collect();
    let site = parts[parts.len().saturating_sub(2)..].join(".");
    host == bare || host.ends_with(&format!(".{bare}")) || bare == site || bare.ends_with(&format!(".{site}"))
}

/// The cookies of the sign-in, by name: the store holds only this sign-in, so every cookie may be asked for (Messenger
/// signs in on facebook.com too); one of the site the step started on wins over one of the same name elsewhere.
pub fn jar(cookies: &[(String, String, String)], start: &str) -> HashMap<String, String> {
    let mut jar = HashMap::new();
    for (domain, name, value) in cookies.iter().filter(|(d, _, _)| !belongs(d, start)) {
        let _ = domain;
        jar.insert(name.clone(), value.clone());
    }
    for (_, name, value) in cookies.iter().filter(|(d, _, _)| belongs(d, start)) {
        jar.insert(name.clone(), value.clone());
    }
    jar
}

/// How the sign-in window presents itself (`WebSignInAgent` on the Mac). Google turns away sign-ins in an app's own
/// browser but lets a desktop Firefox in; so on Google's sign-in pages the window calls itself Firefox, and everywhere
/// else what the step asked for (or the web view's own).
pub mod agent {
    use super::*;

    /// Google's sign-in pages.
    pub fn is_google_sign_in(address: &str) -> bool {
        let Some(host) = url::Url::parse(address).ok().and_then(|u| u.host_str().map(str::to_lowercase)) else { return false };
        host == "accounts.google.com" || host.ends_with(".accounts.google.com") || host == "accounts.youtube.com"
    }

    /// A desktop Firefox of about the current version (one comes out every four weeks), on this computer's system.
    pub fn firefox(now: DateTime<Utc>) -> String {
        let first = DateTime::<Utc>::from_timestamp(1_741_046_400, 0).unwrap_or_default(); // Firefox 136, 4 March 2025
        let version = 136 + ((now - first).num_days().max(0) / 28);
        let system = if cfg!(windows) {
            "Windows NT 10.0; Win64; x64"
        } else if cfg!(target_os = "macos") {
            "Macintosh; Intel Mac OS X 10.15"
        } else {
            "X11; Linux x86_64"
        };
        format!("Mozilla/5.0 ({system}; rv:{version}.0) Gecko/20100101 Firefox/{version}.0")
    }

    /// The agent a page in the main frame is asked for with: Firefox on Google's sign-in pages, `otherwise` elsewhere.
    pub fn for_address(address: &str, otherwise: Option<&str>, now: DateTime<Utc>) -> Option<String> {
        if is_google_sign_in(address) {
            Some(firefox(now))
        } else {
            otherwise.map(str::to_string)
        }
    }

    /// Runs on Google's sign-in pages before Google's own scripts: the page hears there is no passkey here and a passkey
    /// request is answered at once as if cancelled, so "Try another way" leads to your password or your phone. An app's
    /// own browser cannot use passkeys for other sites' sign-ins. Every change is a Proxy, which reads as the
    /// browser's own function.
    pub const GOOGLE_PASSKEYS: &str = r#"(() => {
  if (!/(^|\.)accounts\.google\.com$/i.test(location.hostname)) return;
  const wrap = (owner, name, apply) => {
    try {
      const original = owner && owner[name];
      if (typeof original !== 'function') return;
      const descriptor = Object.getOwnPropertyDescriptor(owner, name) || { configurable: true, enumerable: false, writable: true };
      Object.defineProperty(owner, name, { ...descriptor, value: new Proxy(original, { apply }) });
    } catch (error) {}
  };
  const none = () => Promise.resolve(false);
  const key = window.PublicKeyCredential;
  wrap(key, 'isUserVerifyingPlatformAuthenticatorAvailable', none);
  wrap(key, 'isConditionalMediationAvailable', none);
  const refuse = () => Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
  const container = window.CredentialsContainer && CredentialsContainer.prototype;
  for (const name of ['get', 'create']) {
    wrap(container, name, (target, self, args) => (args[0] && args[0].publicKey ? refuse() : Reflect.apply(target, self, args)));
  }
})();"#;

    /// A script that changes the page starts with this and returns on Google's sign-in pages.
    pub const SKIP_ON_GOOGLE: &str = r"if (/(^|\.)accounts\.google\.com$/i.test(location.hostname)) return;";
}

/// Where the window's page scripts leave what they found, for Nook to read (the page never talks to Nook itself).
pub const PAGE_STATE: &str = "__nookSignIn";

/// Runs in the website before its own scripts: when the page sets one of the request headers the step asks for (on a
/// fetch or an XMLHttpRequest), its value is kept in [`PAGE_STATE`] for the window to read. Nothing else is looked at.
/// The names go in as JSON, never as code.
pub fn header_script(names: &[String]) -> Option<String> {
    if names.is_empty() {
        return None;
    }
    let list = serde_json::to_string(names).ok()?;
    Some(format!(
        r#"(() => {{
  {skip}
  const state = (window.{state} = window.{state} || {{ headers: {{}}, special: null }});
  const wanted = new Set({list});
  const tell = (name, value) => {{
    const key = String(name).toLowerCase();
    if (wanted.has(key) && value) state.headers[key] = String(value);
  }};
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {{ tell(name, value); return setHeader.call(this, name, value); }};
  const nativeFetch = window.fetch;
  window.fetch = function (input, init) {{
    try {{
      const given = (init && init.headers) || (input && input.headers);
      if (given) new Headers(given).forEach((value, name) => tell(name, value));
    }} catch (error) {{}}
    return nativeFetch.apply(this, arguments);
  }};
}})();"#,
        skip = agent::SKIP_ON_GOOGLE,
        state = PAGE_STATE,
    ))
}

/// Starts the step's own script in the page, once per page: it waits there until it finds what the step asks for and
/// its answer is kept in [`PAGE_STATE`]. The script comes from the chat helper on this computer.
pub fn extract_script(script: &str) -> String {
    format!(
        r#"(() => {{
  const state = (window.{state} = window.{state} || {{ headers: {{}}, special: null }});
  if (state.extracting) return;
  state.extracting = true;
  Promise.resolve().then(async () => await ({script})).then(
    (found) => {{ state.special = found && typeof found === 'object' ? found : null; state.extracting = false; }},
    () => {{ state.extracting = false; }}
  );
}})();"#,
        state = PAGE_STATE,
    )
}

/// What the window reads from the page each second: its address, the local storage keys the step asks for, the headers
/// heard, and what the step's script found. Answers as JSON text.
pub fn read_script(storage_keys: &[String]) -> String {
    let keys = serde_json::to_string(storage_keys).unwrap_or_else(|_| "[]".into());
    format!(
        r#"JSON.stringify((() => {{
  const state = window.{state} || {{ headers: {{}}, special: null }};
  let storage = {{}};
  try {{ storage = Object.fromEntries({keys}.map((k) => [k, localStorage.getItem(k) || ''])); }} catch (error) {{}}
  return {{ address: location.href, storage, headers: state.headers || {{}}, special: state.special || {{}} }};
}})())"#,
        state = PAGE_STATE,
    )
}

/// What [`read_script`] answered.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PageRead {
    pub address: String,
    pub storage: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub special: HashMap<String, String>,
}

impl PageRead {
    /// Reads the answer, which a web view may hand over as the JSON text itself or as that text quoted once more.
    pub fn parse(answer: &str) -> Option<Self> {
        let mut value: Value = serde_json::from_str(answer).ok()?;
        if let Value::String(inner) = &value {
            value = serde_json::from_str(inner).ok()?;
        }
        let strings = |key: &str| -> HashMap<String, String> {
            value
                .get(key)
                .and_then(Value::as_object)
                .map(|o| o.iter().filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string()))).collect())
                .unwrap_or_default()
        };
        Some(Self {
            address: value.get("address").and_then(Value::as_str).unwrap_or_default().to_string(),
            storage: strings("storage"),
            headers: strings("headers"),
            special: strings("special"),
        })
    }
}

impl chatd::ChatdClient {
    /// The apps the helper links and their accounts.
    pub async fn networks(&self, name: impl Fn(&str) -> Option<String>) -> Result<Vec<Network>, String> {
        Ok(networks(&self.bridges().await?, name))
    }

    /// Starts linking an account in `network`.
    pub async fn start_login(&self, network: &str) -> Result<Session, String> {
        let path = format!("/v1/bridges/{}/login-sessions", segment(network));
        session(&self.request(reqwest::Method::POST, &path, Some(json!({}))).await?).ok_or_else(|| "login".to_string())
    }

    pub async fn login(&self, network: &str, id: &str) -> Result<Session, String> {
        let path = format!("/v1/bridges/{}/login-sessions/{}", segment(network), segment(id));
        session(&self.request(reqwest::Method::GET, &path, None).await?).ok_or_else(|| "login".to_string())
    }

    /// Answers the step the login waits on.
    pub async fn submit_step(&self, network: &str, id: &str, step: &Step, body: Value) -> Result<Session, String> {
        let step_id = step.id().ok_or_else(|| "step".to_string())?;
        let path = format!("/v1/bridges/{}/login-sessions/{}/steps/{}", segment(network), segment(id), segment(step_id));
        session(&self.request(reqwest::Method::POST, &path, Some(body)).await?).ok_or_else(|| "login".to_string())
    }

    pub async fn cancel_login(&self, network: &str, id: &str) -> Result<(), String> {
        let path = format!("/v1/bridges/{}/login-sessions/{}", segment(network), segment(id));
        self.request(reqwest::Method::DELETE, &path, None).await.map(|_| ())
    }

    /// Unlinks an account.
    pub async fn remove_login(&self, network: &str, login: &str) -> Result<(), String> {
        let path = format!("/v1/bridges/{}/logins/{}/remove", segment(network), segment(login));
        self.request(reqwest::Method::POST, &path, Some(json!({}))).await.map(|_| ())
    }
}

fn segment(text: &str) -> String {
    percent_encoding::utf8_percent_encode(text, percent_encoding::NON_ALPHANUMERIC).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn browser_step() -> Value {
        json!({"type": "cookies", "stepID": "s1", "url": "https://www.instagram.com/accounts/login/",
               "userAgent": "UA", "expectedFinalURLRegex": "^https://www\\.instagram\\.com/$",
               "fields": [
                   {"id": "sessionid", "type": "cookie", "name": "sessionid"},
                   {"id": "csrf", "type": "header", "name": "X-CSRFToken", "pattern": "^[a-z0-9]+$"},
                   {"id": "jar", "type": "header", "name": "Cookie", "required": false},
                   {"id": "ls", "type": "local_storage", "name": "token"},
                   {"id": "tok", "type": "special", "name": "token"}
               ]})
    }

    #[test]
    fn reads_networks_one_per_app_local_first() {
        let json = json!({"items": [
            {"id": "cloud-wa", "type": "whatsapp", "status": "available", "provider": "cloud",
             "accounts": [{"accountID": "a1", "status": "connected", "user": {"fullName": "Ann"}}]},
            {"id": "local-whatsapp", "type": "whatsapp", "status": "available", "provider": "local",
             "accounts": [{"accountID": "a2", "loginID": "l2", "status": "bad", "statusText": "Reconnect required",
                           "user": {"phoneNumber": "+31"}}]},
            {"id": "local-signal", "displayName": "Signal", "status": "unavailable"},
            {"id": "local-mystery", "displayName": "Mystery"}
        ]});
        let list = networks(&json, |app| (app == "whatsapp").then(|| "WhatsApp".to_string()));
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].name, "Signal");
        assert!(!list[0].can_link);
        let wa = &list[1];
        assert_eq!(wa.id, "local-whatsapp", "links start where the local one runs");
        assert_eq!(wa.accounts.len(), 2);
        assert_eq!(wa.accounts[0].name, "+31");
        assert_eq!(wa.accounts[0].status.as_deref(), Some("Reconnect required"));
        assert!(wa.accounts[1].is_connected);
        assert_eq!(only_account("whatsapp", &list), None);
        assert_eq!(only_account("signal", &list), None);
    }

    #[test]
    fn reads_sessions_and_steps() {
        let s = session(&json!({"loginSessionID": "L", "bridgeID": "local-instagram", "status": "waiting_for_cookies",
                                "currentStep": browser_step()}))
        .unwrap();
        assert_eq!(s.state, SessionState::WaitingForCookies);
        let Some(Step::Browser { url, collect, done, user_agent, .. }) = &s.step else { panic!("browser step") };
        assert_eq!(url, "https://www.instagram.com/accounts/login/");
        assert_eq!(collect.len(), 5);
        assert_eq!(collect[1].source, Source::Header);
        assert!(!collect[2].is_required);
        assert!(done.is_some() && user_agent.as_deref() == Some("UA"));
        assert!(step(&json!({"type": "cookies", "stepID": "x", "url": "http://insecure"})).is_none(), "https only");
        let qr = step(&json!({"type": "display_and_wait", "stepID": "q", "display": {"type": "qr", "data": "2@abc"}})).unwrap();
        assert_eq!(qr, Step::Display { id: "q".into(), instructions: String::new(), show: Display::Qr("2@abc".into()) });
        let input = step(&json!({"type": "user_input", "stepID": "i", "fields": [{"id": "pw", "type": "password", "optional": true}]})).unwrap();
        let Step::Input { fields, .. } = input else { panic!() };
        assert!(fields[0].is_secret && fields[0].is_optional && fields[0].label == "pw");
        let failed = session(&json!({"loginSessionID": "L", "bridgeID": "b", "status": "failed", "error": {"message": "nope"}})).unwrap();
        assert!(failed.is_over());
        assert_eq!(failed.problem.as_deref(), Some("nope"));
    }

    #[test]
    fn collects_what_the_step_asks_for() {
        let Some(Step::Browser { collect, done, .. }) = step(&browser_step()) else { panic!() };
        let cookies: HashMap<String, String> = [("sessionid".into(), "S".into()), ("ds".into(), "1".into())].into();
        let mut headers: HashMap<String, String> = [("x-csrftoken".into(), "NOT VALID".into())].into();
        let none = HashMap::new();
        let values = collected(&collect, &cookies, &none, &headers, &none);
        assert!(!has_cookies(&collect, &values), "a value that misses its pattern does not count");
        headers.insert("x-csrftoken".into(), "abc123".into());
        let special: HashMap<String, String> = [("tok".into(), "T".into())].into();
        let values = collected(&collect, &cookies, &none, &headers, &special);
        assert!(has_cookies(&collect, &values));
        assert_eq!(values["jar"], "ds=1; sessionid=S");
        assert!(!is_done("https://www.instagram.com/accounts/login/", done.as_deref()));
        assert!(is_done("https://www.instagram.com/", done.as_deref()));
        assert_eq!(page_headers(&collect), vec!["x-csrftoken"]);
        let body = answer(&step(&browser_step()).unwrap(), &values, Some("https://www.instagram.com/"));
        assert_eq!(body["type"], "cookies");
        assert_eq!(body["source"], "webview");
        assert_eq!(body["fields"]["sessionid"], "S");
    }

    #[test]
    fn cookies_of_the_start_site_win() {
        assert!(belongs(".instagram.com", "https://www.instagram.com/x"));
        assert!(belongs("www.instagram.com", "https://www.instagram.com/x"));
        assert!(!belongs(".facebook.com", "https://www.messenger.com/"));
        let jar = jar(
            &[
                ("www.instagram.com".into(), "c".into(), "mine".into()),
                (".facebook.com".into(), "c".into(), "other".into()),
                (".facebook.com".into(), "xs".into(), "x".into()),
            ],
            "https://www.instagram.com/",
        );
        assert_eq!(jar["c"], "mine");
        assert_eq!(jar["xs"], "x");
    }

    #[test]
    fn calls_itself_firefox_on_google_only() {
        let now = DateTime::<Utc>::from_timestamp(1_741_046_400 + 56 * 86_400, 0).unwrap();
        assert!(agent::firefox(now).contains("Firefox/138.0"));
        assert!(agent::is_google_sign_in("https://accounts.google.com/signin"));
        assert!(!agent::is_google_sign_in("https://google.com/"));
        assert_eq!(agent::for_address("https://www.slack.com/", Some("UA"), now).as_deref(), Some("UA"));
        assert!(agent::for_address("https://accounts.google.com/x", Some("UA"), now).unwrap().contains("Firefox"));
    }

    #[test]
    fn page_scripts_carry_names_as_json_and_answers_parse() {
        assert!(header_script(&[]).is_none());
        let script = header_script(&["x-csrftoken".into(), "a\"b".into()]).unwrap();
        assert!(script.contains(r#"["x-csrftoken","a\"b"]"#));
        assert!(script.contains(PAGE_STATE));
        assert!(extract_script("findToken()").contains("await (findToken())"));
        let answer = json!({"address": "https://slack.com/", "storage": {"t": "1"}, "headers": {"x": "2"}, "special": {"tok": "3", "n": 4}})
            .to_string();
        let read = PageRead::parse(&answer).unwrap();
        assert_eq!(read.special.get("tok").map(String::as_str), Some("3"));
        assert!(!read.special.contains_key("n"));
        let quoted = serde_json::to_string(&answer).unwrap();
        assert_eq!(PageRead::parse(&quoted), Some(read));
    }
}
