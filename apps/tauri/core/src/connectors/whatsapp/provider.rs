//! De twee lokale WhatsApp-koppelingen waar Nook mee praat. Elk verzoek gaat naar het adres uit de instellingen
//! (standaard 127.0.0.1) en nergens anders heen: niets van WhatsApps eigen servers. A photo or document is only
//! fetched when the card shows it or the user opens it, and then from the gateway.

use std::time::Duration;

use base64::Engine;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::{epoch, files, jid, rfc3339, text_mentions, GatewayKind, Media, Message, Receipt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaError {
    /// Op dat adres antwoordt niets.
    Unreachable,
    /// Verkeerde gebruiker:wachtwoord (GOWA) of API-sleutel (OpenWA).
    Unauthorized,
    /// De koppeling gaf een fout (haar eigen melding, nooit de inhoud van een bericht).
    Refused(String),
    /// WhatsApp is nog niet gekoppeld.
    NotLoggedIn,
}

pub type WaResult<T> = Result<T, WaError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkState {
    Connected,
    NeedsQr,
    Connecting,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub link: LinkState,
    /// De JID of het nummer van dit account, zodra gekoppeld.
    pub me: Option<String>,
}

/// A message's file as the gateway hands it over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaFile {
    pub data: Vec<u8>,
    /// The name the gateway gives it, if any.
    pub name: Option<String>,
    /// Its MIME type, if the gateway says.
    pub mime: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChatInfo {
    pub jid: String,
    pub name: String,
    pub last: DateTime<Utc>,
}

/// HTTP naar de lokale koppeling: geen cookies, geen proxy, geen redirect.
struct WaHttp {
    base: url::Url,
    headers: Vec<(String, String)>,
    client: reqwest::Client,
}

impl WaHttp {
    fn new(base: url::Url, headers: Vec<(String, String)>) -> Self {
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .build()
            .unwrap_or_default();
        Self { base, headers, client }
    }

    async fn call(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
        timeout: u64,
    ) -> WaResult<(Vec<u8>, u16)> {
        let response = self.send(method, path, query, body, timeout, "application/json").await?;
        let code = response.status().as_u16();
        let bytes = response.bytes().await.map_err(|_| WaError::Unreachable)?;
        Ok((bytes.to_vec(), code))
    }

    /// A file from the gateway: its bytes, status code and MIME type. Refused past [`files::MAX_BYTES`].
    async fn download(&self, path: &str) -> WaResult<(Vec<u8>, u16, Option<String>)> {
        let mut response = self.send("GET", path, &[], None, 60, "*/*").await?;
        let code = response.status().as_u16();
        let mime = response.headers().get("content-type").and_then(|v| v.to_str().ok()).map(str::to_string);
        if response.content_length().is_some_and(|n| n as usize > files::MAX_BYTES) {
            return Err(WaError::Refused("too large".into()));
        }
        let mut data = vec![];
        while let Some(chunk) = response.chunk().await.map_err(|_| WaError::Unreachable)? {
            data.extend_from_slice(&chunk);
            if data.len() > files::MAX_BYTES {
                return Err(WaError::Refused("too large".into()));
            }
        }
        Ok((data, code, mime))
    }

    async fn send(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
        timeout: u64,
        accept: &str,
    ) -> WaResult<reqwest::Response> {
        let mut url = self.base.clone();
        let prefix = url.path().trim_matches('/').to_string();
        url.set_path(&if prefix.is_empty() { path.to_string() } else { format!("/{prefix}{path}") });
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (k, v) in query {
                pairs.append_pair(k, v);
            }
        }
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap_or(reqwest::Method::GET);
        let mut request = self.client.request(method, url).header("Accept", accept).timeout(Duration::from_secs(timeout));
        for (k, v) in &self.headers {
            request = request.header(k, v);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        request.send().await.map_err(|_| WaError::Unreachable)
    }
}

fn path_component(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-._~@".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

fn non_empty(v: &Value) -> Option<String> {
    v.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

fn parse(data: &[u8]) -> Value {
    serde_json::from_slice(data).unwrap_or(Value::Null)
}

// GOWA

pub mod gowa {
    use super::*;

    /// De envelop van GOWA: `{code, message, results}`.
    pub fn results(data: &[u8]) -> Value {
        parse(data)["results"].clone()
    }

    /// `GET /devices`: het apparaat waar Nook mee werkt, een ingelogd apparaat eerst.
    pub fn device(data: &[u8]) -> Option<(String, Status)> {
        let r = results(data);
        let list = r.as_array().filter(|l| !l.is_empty())?;
        let pick = list.iter().find(|d| d["state"] == "logged_in").unwrap_or(&list[0]);
        let id = non_empty(&pick["id"])?;
        let me = non_empty(&pick["jid"]);
        let link = match pick["state"].as_str() {
            Some("logged_in") => LinkState::Connected,
            _ if me.is_none() => LinkState::NeedsQr,
            _ => LinkState::Connecting,
        };
        Some((id, Status { link, me }))
    }

    /// `GET /devices/{id}/login`: het pad van de QR-afbeelding, op te halen bij de koppeling zelf.
    pub fn qr_path(data: &[u8]) -> Option<(String, u64)> {
        let r = results(data);
        let link = r["qr_link"].as_str()?;
        let url = url::Url::parse(link).ok()?;
        (!url.path().is_empty()).then(|| (url.path().to_string(), r["qr_duration"].as_u64().unwrap_or(30)))
    }

    /// De foutcode van een geweigerde aanroep (`ALREADY_LOGGED_IN`, …).
    pub fn error_code(data: &[u8]) -> Option<String> {
        non_empty(&parse(data)["code"])
    }

    pub fn chats(data: &[u8]) -> Vec<ChatInfo> {
        crate::connectors::list(&results(data)["data"])
            .iter()
            .filter_map(|c| {
                Some(ChatInfo {
                    jid: non_empty(&c["jid"])?,
                    name: c["name"].as_str().unwrap_or("").to_string(),
                    last: rfc3339(&c["last_message_time"]).unwrap_or(DateTime::<Utc>::MIN_UTC),
                })
            })
            .collect()
    }

    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        let r = results(data);
        let chat_name = non_empty(&r["chat_info"]["name"]);
        crate::connectors::list(&r["data"])
            .iter()
            .filter_map(|m| {
                let id = m["id"].as_str()?;
                let chat = m["chat_jid"].as_str()?;
                let text = m["content"].as_str().unwrap_or("");
                let mut msg = Message::new(
                    id,
                    chat,
                    m["sender_jid"].as_str().unwrap_or(chat),
                    &non_empty(&m["sender_display_name"]).unwrap_or_default(),
                    text,
                    rfc3339(&m["timestamp"]).unwrap_or(DateTime::<Utc>::MIN_UTC),
                    m["is_from_me"].as_bool().unwrap_or(false),
                );
                msg.media = stored_media(m["media_type"].as_str(), non_empty(&m["filename"]));
                msg.chat_name = if jid::is_group(chat) { chat_name.clone() } else { None };
                msg.mentions_me = jid::is_group(chat) && text_mentions(text, me);
                Some(msg)
            })
            .collect()
    }

    /// `GET /message/{id}/download` → `results: {filename, file_path, file_url}`: the saved file's path on the gateway
    /// (from `file_url`, else `file_path` under statics/), to fetch from the gateway itself whatever host the link
    /// names, and its name.
    pub fn download(data: &[u8]) -> Option<(String, Option<String>)> {
        let r = results(data);
        let name = non_empty(&r["filename"]);
        if let Some(link) = r["file_url"].as_str().and_then(|l| url::Url::parse(l).ok()) {
            if link.path().len() > 1 && !link.path().contains("..") {
                return Some((link.path().to_string(), name));
            }
        }
        let file = r["file_path"].as_str()?;
        if !file.starts_with("statics/") || file.contains("..") {
            return None;
        }
        let encoded: Vec<String> = file.split('/').map(path_component).collect();
        Some((format!("/{}", encoded.join("/")), name))
    }

    pub fn stored_media(kind: Option<&str>, filename: Option<String>) -> Media {
        match kind.unwrap_or("") {
            "" => Media::None,
            "image" => Media::Image,
            "video" | "video_note" => Media::Video,
            "audio" => Media::Voice,
            "document" => Media::Document { name: filename },
            "sticker" => Media::Sticker,
            _ => Media::Other,
        }
    }

    /// `whatsapp rest` voor "GOWA automatisch starten": alleen op deze computer, op de poort uit het adres, en
    /// media nooit gedownload (Nook toont een label), zodat GOWA geen foto of spraakbericht bewaart.
    pub fn launch_arguments(url: &url::Url) -> Vec<String> {
        vec![
            "rest".into(),
            "--host=127.0.0.1".into(),
            format!("--port={}", url.port().unwrap_or(3000)),
            "--auto-download-media=false".into(),
        ]
    }
}

// OpenWA

pub mod openwa {
    use super::*;

    pub fn session(v: &Value) -> Option<(String, String, Option<String>)> {
        Some((non_empty(&v["id"])?, v["status"].as_str().unwrap_or("").to_string(), non_empty(&v["phone"])))
    }

    pub fn status(s: &(String, String, Option<String>)) -> Status {
        match s.1.as_str() {
            "ready" => Status { link: LinkState::Connected, me: s.2.clone() },
            "qr_ready" => Status { link: LinkState::NeedsQr, me: None },
            _ => Status { link: LinkState::Connecting, me: s.2.clone() },
        }
    }

    /// Sessies die gestart moeten worden voor er een QR kan komen.
    pub fn needs_start(status: &str) -> bool {
        matches!(status, "created" | "disconnected" | "failed")
    }

    /// `{qrCode: "data:image/png;base64,…"}`: de PNG-bytes.
    pub fn qr_png(data: &[u8]) -> Option<Vec<u8>> {
        let url = parse(data)["qrCode"].as_str()?.to_string();
        if !url.starts_with("data:image/png;base64") {
            return None;
        }
        let comma = url.find(',')?;
        base64::engine::general_purpose::STANDARD.decode(&url[comma + 1..]).ok()
    }

    pub fn chats(data: &[u8]) -> Vec<ChatInfo> {
        crate::connectors::list(&parse(data))
            .iter()
            .filter_map(|c| {
                Some(ChatInfo {
                    jid: non_empty(&c["id"])?,
                    name: c["name"].as_str().unwrap_or("").to_string(),
                    last: epoch(&c["timestamp"]).unwrap_or(DateTime::<Utc>::MIN_UTC),
                })
            })
            .collect()
    }

    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        crate::connectors::list(&parse(data)["messages"])
            .iter()
            .filter_map(|m| {
                let id = non_empty(&m["waMessageId"]).or_else(|| non_empty(&m["id"]))?;
                let chat = non_empty(&m["chatId"])?;
                let kind = m["type"].as_str().unwrap_or("text");
                if kind == "revoked" {
                    return None;
                }
                let mut msg = Message::new(
                    &id,
                    &chat,
                    &non_empty(&m["author"]).or_else(|| non_empty(&m["from"])).unwrap_or_else(|| chat.clone()),
                    "",
                    m["body"].as_str().unwrap_or(""),
                    epoch(&m["timestamp"]).unwrap_or(DateTime::<Utc>::MIN_UTC),
                    m["direction"] == "outgoing",
                );
                msg.media = super::super::openwa_media(kind, non_empty(&m["metadata"]["media"]["filename"]));
                msg.chat_name = non_empty(&m["chatName"]);
                if msg.from_me {
                    msg.receipt = m["status"].as_str().and_then(Receipt::from_status);
                }
                if jid::is_group(&chat) {
                    msg.mentions_me = text_mentions(&msg.text, me);
                }
                Some(msg)
            })
            .collect()
    }

    /// NestJS-fout: `{statusCode, message (tekst of lijst), error}`.
    pub fn error_message(data: &[u8]) -> Option<String> {
        let v = parse(data);
        if let Some(s) = v["message"].as_str() {
            return Some(s.into());
        }
        v["message"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "))
    }

    /// OpenWA noemt mensen `<nummer>@c.us`; Nook houdt intern de vorm @s.whatsapp.net.
    pub fn id(jid: &str) -> String {
        jid.strip_suffix("@s.whatsapp.net").map(|u| format!("{u}@c.us")).unwrap_or_else(|| jid.to_string())
    }
}

/// Eén van de twee koppelingen.
pub struct Provider {
    pub kind: GatewayKind,
    http: WaHttp,
    /// GOWA: het apparaat; OpenWA: de sessie.
    scope: tokio::sync::Mutex<Option<String>>,
}

impl Provider {
    /// GOWA: HTTP basic `user:pass` als de koppeling met `--basic-auth` draait. OpenWA: `X-API-Key`.
    pub fn new(kind: GatewayKind, base: &str, credential: Option<&str>) -> Option<Self> {
        let url = url::Url::parse(base).ok().filter(|u| u.scheme().starts_with("http") && u.host_str().is_some())?;
        let mut headers = vec![];
        match (kind, credential.filter(|c| !c.is_empty())) {
            (GatewayKind::Gowa, Some(auth)) if auth.contains(':') => {
                headers.push(("Authorization".into(), format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(auth))));
            }
            (GatewayKind::Openwa, Some(key)) => headers.push(("X-API-Key".into(), key.to_string())),
            _ => {}
        }
        Some(Self { kind, http: WaHttp::new(url, headers), scope: Default::default() })
    }

    fn check(&self, data: &[u8], code: u16) -> WaResult<()> {
        match self.kind {
            GatewayKind::Gowa => {
                if code == 401 && gowa::error_code(data).as_deref() != Some("AUTHENTICATION_ERROR") {
                    return Err(WaError::Unauthorized);
                }
                if code == 401 {
                    return Err(WaError::NotLoggedIn);
                }
                if !(200..300).contains(&code) {
                    return Err(WaError::Refused(gowa::error_code(data).unwrap_or(format!("HTTP {code}"))));
                }
            }
            GatewayKind::Openwa => {
                if code == 401 || code == 403 {
                    return Err(WaError::Unauthorized);
                }
                if !(200..300).contains(&code) {
                    return Err(WaError::Refused(openwa::error_message(data).unwrap_or(format!("HTTP {code}"))));
                }
            }
        }
        Ok(())
    }

    async fn call(&self, method: &str, path: &str, query: &[(&str, String)], body: Option<Value>) -> WaResult<Vec<u8>> {
        let (data, code) = self.http.call(method, path, query, body, 10).await?;
        self.check(&data, code)?;
        Ok(data)
    }

    // GOWA: één apparaat (het ingelogde, anders een nieuw met de naam "nook"), genoemd in `device_id`.

    async fn gowa_device(&self) -> WaResult<(String, Status)> {
        let data = self.call("GET", "/devices", &[], None).await?;
        if let Some(found) = gowa::device(&data) {
            *self.scope.lock().await = Some(found.0.clone());
            return Ok(found);
        }
        self.call("POST", "/devices", &[], Some(json!({"device_id": "nook"}))).await?;
        *self.scope.lock().await = Some("nook".into());
        Ok(("nook".into(), Status { link: LinkState::NeedsQr, me: None }))
    }

    async fn scope_id(&self) -> WaResult<String> {
        if let Some(id) = self.scope.lock().await.clone() {
            return Ok(id);
        }
        Ok(match self.kind {
            GatewayKind::Gowa => self.gowa_device().await?.0,
            GatewayKind::Openwa => self.openwa_session().await?.0,
        })
    }

    async fn gowa_scoped(&self, method: &str, path: &str, query: &[(&str, String)], body: Option<Value>) -> WaResult<Vec<u8>> {
        let id = self.scope_id().await?;
        let mut q = query.to_vec();
        q.push(("device_id", id));
        self.call(method, path, &q, body).await
    }

    // OpenWA: één sessie (de klare, anders "nook", aangemaakt en gestart als hij ontbreekt).

    async fn openwa_session(&self) -> WaResult<(String, String, Option<String>)> {
        let data = self.call("GET", "/api/sessions", &[], None).await?;
        let list = parse(&data);
        let all: Vec<_> = crate::connectors::list(&list).iter().filter_map(openwa::session).collect();
        let current = self.scope.lock().await.clone();
        let named = crate::connectors::list(&list).iter().find(|s| s["name"] == "nook").and_then(openwa::session);
        let pick = all
            .iter()
            .find(|s| s.1 == "ready")
            .cloned()
            .or_else(|| all.iter().find(|s| Some(&s.0) == current.as_ref()).cloned())
            .or(named)
            .or_else(|| all.first().cloned());
        let session = match pick {
            Some(s) => s,
            None => {
                let made = self.call("POST", "/api/sessions", &[], Some(json!({"name": "nook"}))).await?;
                openwa::session(&parse(&made)).ok_or_else(|| WaError::Refused("session".into()))?
            }
        };
        *self.scope.lock().await = Some(session.0.clone());
        if openwa::needs_start(&session.1) {
            let started = self.call("POST", &format!("/api/sessions/{}/start", session.0), &[], None).await?;
            return Ok(openwa::session(&parse(&started)).unwrap_or(session));
        }
        Ok(session)
    }

    async fn openwa_scoped(&self, method: &str, path: &str, query: &[(&str, String)], body: Option<Value>) -> WaResult<Vec<u8>> {
        let id = self.scope_id().await?;
        self.call(method, &format!("/api/sessions/{id}{path}"), query, body).await
    }

    /// De koppeling met WhatsApp (zet het apparaat of de sessie de eerste keer klaar).
    pub async fn status(&self) -> WaResult<Status> {
        match self.kind {
            GatewayKind::Gowa => Ok(self.gowa_device().await?.1),
            GatewayKind::Openwa => Ok(openwa::status(&self.openwa_session().await?)),
        }
    }

    /// De QR om te scannen (PNG) en hoe lang hij geldig is; `None` als er niets te tonen is.
    pub async fn qr_code(&self) -> WaResult<Option<(Vec<u8>, u64)>> {
        let id = self.scope_id().await?;
        match self.kind {
            GatewayKind::Gowa => {
                // GOWA antwoordt zodra WhatsApp de eerste code gaf: een paar seconden.
                let (data, code) = self.http.call("GET", &format!("/devices/{}/login", path_component(&id)), &[], None, 45).await?;
                if gowa::error_code(&data).as_deref() == Some("ALREADY_LOGGED_IN") {
                    return Ok(None);
                }
                self.check(&data, code)?;
                let Some((path, seconds)) = gowa::qr_path(&data) else { return Ok(None) };
                // De PNG komt van de koppeling zelf, welke host de link ook noemt.
                let (png, png_code) = self.http.call("GET", &path, &[], None, 10).await?;
                if png_code != 200 || !png.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
                    return Ok(None);
                }
                // qr_duration is de halve levensduur van de code; eerder opnieuw vragen herstart het koppelen.
                Ok(Some((png, (seconds * 2).saturating_sub(5).max(20))))
            }
            GatewayKind::Openwa => {
                let (data, code) = self.http.call("GET", &format!("/api/sessions/{id}/qr"), &[], None, 10).await?;
                if code == 400 {
                    return Ok(None);
                }
                self.check(&data, code)?;
                Ok(openwa::qr_png(&data).map(|p| (p, 15)))
            }
        }
    }

    /// Laat de koppeling nieuwe berichten naar Nooks webhook sturen, ondertekend met `secret`.
    pub async fn register_webhook(&self, url: &str, secret: &str) -> WaResult<()> {
        let id = self.scope_id().await?;
        match self.kind {
            GatewayKind::Gowa => {
                self.call(
                    "PATCH",
                    &format!("/devices/{}/webhook", path_component(&id)),
                    &[],
                    Some(json!({"webhook_url": url, "webhook_secret": secret, "webhook_events": "message,message.ack"})),
                )
                .await?;
            }
            GatewayKind::Openwa => {
                let body = json!({"url": url, "events": ["message.received", "message.sent", "message.ack"], "secret": secret});
                let list = self.call("GET", &format!("/api/sessions/{id}/webhooks"), &[], None).await?;
                let hooks = parse(&list);
                match crate::connectors::list(&hooks).iter().find(|h| h["url"] == url).and_then(|h| non_empty(&h["id"])) {
                    Some(hook) => self.call("PUT", &format!("/api/sessions/{id}/webhooks/{hook}"), &[], Some(body)).await?,
                    None => self.call("POST", &format!("/api/sessions/{id}/webhooks"), &[], Some(body)).await?,
                };
            }
        }
        Ok(())
    }

    /// Berichten uit alle chats sinds `date` (als er geen webhook komt), oudste eerst.
    pub async fn recent_messages(&self, since: DateTime<Utc>, me: Option<&str>) -> WaResult<Vec<Message>> {
        let mut out = vec![];
        match self.kind {
            GatewayKind::Gowa => {
                let chats = gowa::chats(&self.gowa_scoped("GET", "/chats", &[("limit", "20".into())], None).await?);
                for chat in chats.iter().take(8).filter(|c| c.last > since) {
                    let data = self
                        .gowa_scoped(
                            "GET",
                            &format!("/chat/{}/messages", path_component(&chat.jid)),
                            &[("limit", "10".into()), ("start_time", since.to_rfc3339())],
                            None,
                        )
                        .await?;
                    out.extend(gowa::messages(&data, me).into_iter().map(|mut m| {
                        if m.chat_name.is_none() && !chat.name.is_empty() && jid::is_group(&chat.jid) {
                            m.chat_name = Some(chat.name.clone());
                        }
                        m
                    }));
                }
            }
            GatewayKind::Openwa => {
                let data = self
                    .openwa_scoped(
                        "GET",
                        "/messages",
                        &[("since", since.timestamp_millis().to_string()), ("limit", "50".into()), ("inlineMedia", "false".into())],
                        None,
                    )
                    .await?;
                out = openwa::messages(&data, me);
            }
        }
        out.sort_by_key(|m| m.date);
        Ok(out)
    }

    /// De nieuwste `limit` berichten van één chat, oudste eerst.
    pub async fn messages(&self, chat: &str, limit: usize, me: Option<&str>) -> WaResult<Vec<Message>> {
        let mut out = match self.kind {
            GatewayKind::Gowa => gowa::messages(
                &self
                    .gowa_scoped("GET", &format!("/chat/{}/messages", path_component(chat)), &[("limit", limit.to_string())], None)
                    .await?,
                me,
            ),
            GatewayKind::Openwa => openwa::messages(
                &self
                    .openwa_scoped(
                        "GET",
                        "/messages",
                        &[("chatId", openwa::id(chat)), ("limit", limit.to_string()), ("inlineMedia", "false".into())],
                        None,
                    )
                    .await?,
                me,
            ),
        };
        out.sort_by_key(|m| m.date);
        Ok(out)
    }

    /// Stuurt tekst naar een bestaande chat; geeft het id van het nieuwe bericht als de koppeling het noemt.
    pub async fn send(&self, text: &str, chat: &str) -> WaResult<Option<String>> {
        Ok(match self.kind {
            GatewayKind::Gowa => {
                let data = self.gowa_scoped("POST", "/send/message", &[], Some(json!({"phone": chat, "message": text}))).await?;
                non_empty(&gowa::results(&data)["message_id"])
            }
            GatewayKind::Openwa => {
                let data =
                    self.openwa_scoped("POST", "/messages/send-text", &[], Some(json!({"chatId": openwa::id(chat), "text": text}))).await?;
                non_empty(&parse(&data)["messageId"])
            }
        })
    }

    /// Markeert de chat gelezen tot het nieuwste ontvangen bericht.
    pub async fn mark_read(&self, chat: &str, last_incoming: Option<&str>) -> WaResult<()> {
        match self.kind {
            GatewayKind::Gowa => {
                let Some(id) = last_incoming else { return Ok(()) };
                self.gowa_scoped("POST", &format!("/message/{}/read", path_component(id)), &[], Some(json!({"phone": chat}))).await?;
            }
            GatewayKind::Openwa => {
                self.openwa_scoped("POST", "/chats/read", &[], Some(json!({"chatId": openwa::id(chat)}))).await?;
            }
        }
        Ok(())
    }

    /// De naam van een groep, als de berichten hem niet meedragen.
    pub async fn group_name(&self, chat: &str) -> Option<String> {
        if !jid::is_group(chat) {
            return None;
        }
        match self.kind {
            GatewayKind::Gowa => {
                non_empty(&gowa::results(&self.gowa_scoped("GET", "/group/info", &[("group_id", chat.into())], None).await.ok()?)["Name"])
            }
            GatewayKind::Openwa => {
                non_empty(&parse(&self.openwa_scoped("GET", &format!("/groups/{}", path_component(chat)), &[], None).await.ok()?)["name"])
            }
        }
    }

    /// The file of one message (a document, photo, video or voice note), only when the card shows it or it is opened.
    pub async fn media(&self, chat: &str, message: &str) -> WaResult<WaFile> {
        let id = self.scope_id().await?;
        match self.kind {
            GatewayKind::Gowa => {
                // GOWA saves the file under its own statics/ first and says where; Nook then fetches it from the
                // configured address, whatever host the link names.
                let query = [("phone", chat.to_string()), ("device_id", id)];
                let (data, code) =
                    self.http.call("GET", &format!("/message/{}/download", path_component(message)), &query, None, 60).await?;
                self.check(&data, code)?;
                let (path, name) = gowa::download(&data).ok_or_else(|| WaError::Refused("media".into()))?;
                let (bytes, code, mime) = self.http.download(&path).await?;
                if code != 200 {
                    return Err(WaError::Refused(format!("HTTP {code}")));
                }
                Ok(WaFile { data: bytes, name, mime })
            }
            GatewayKind::Openwa => {
                let path = format!("/api/sessions/{id}/messages/{}/{}/media", path_component(&openwa::id(chat)), path_component(message));
                let (bytes, code, mime) = self.http.download(&path).await?;
                if code == 401 || code == 403 {
                    return Err(WaError::Unauthorized);
                }
                if code != 200 {
                    return Err(WaError::Refused(openwa::error_message(&bytes).unwrap_or(format!("HTTP {code}"))));
                }
                Ok(WaFile { data: bytes, name: None, mime })
            }
        }
    }

    /// De chats op de telefoon, nieuwste eerst: naar wie Nook op naam mag sturen.
    pub async fn chats(&self, limit: usize) -> WaResult<Vec<ChatInfo>> {
        Ok(match self.kind {
            GatewayKind::Gowa => gowa::chats(&self.gowa_scoped("GET", "/chats", &[("limit", limit.to_string())], None).await?),
            GatewayKind::Openwa => openwa::chats(&self.openwa_scoped("GET", "/chats", &[], None).await?)
                .into_iter()
                .take(limit)
                .map(|mut c| {
                    c.jid = jid::normalized(&c.jid);
                    c
                })
                .collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;

    #[test]
    fn gowa_answers() {
        let devices = br#"{"code":"SUCCESS","results":[{"id":"a","state":"disconnected"},{"id":"nook","state":"logged_in","jid":"31611111111@s.whatsapp.net"}]}"#;
        let (id, status) = gowa::device(devices).unwrap();
        assert_eq!(id, "nook");
        assert_eq!(status, Status { link: LinkState::Connected, me: Some("31611111111@s.whatsapp.net".into()) });
        assert_eq!(gowa::device(br#"{"results":[{"id":"x","state":"connecting"}]}"#).unwrap().1.link, LinkState::NeedsQr);
        assert_eq!(
            gowa::qr_path(br#"{"results":{"qr_link":"http://localhost:3000/statics/qrcode/scan-qr-1.png","qr_duration":30}}"#),
            Some(("/statics/qrcode/scan-qr-1.png".into(), 30))
        );
        let messages = gowa::messages(br#"{"results":{"data":[{"id":"m1","chat_jid":"1@g.us","sender_jid":"2@s.whatsapp.net","sender_display_name":"Piet","content":"hoi @31611111111","timestamp":"2026-10-18T12:00:00Z","is_from_me":false,"media_type":"image"}],"chat_info":{"name":"Familie"}}}"#, Some("31611111111@s.whatsapp.net"));
        assert_eq!(messages[0].chat_name.as_deref(), Some("Familie"));
        assert!(messages[0].mentions_me);
        assert_eq!(messages[0].media, Media::Image);
        let url = url::Url::parse("http://127.0.0.1:3005").unwrap();
        assert_eq!(gowa::launch_arguments(&url), ["rest", "--host=127.0.0.1", "--port=3005", "--auto-download-media=false"]);
    }

    #[test]
    fn gowa_download_is_fetched_from_the_gateway_itself() {
        let answer = br#"{"code":"SUCCESS","results":{"filename":"offerte.pdf","file_path":"statics/media/316/2026-10-20/offerte.pdf","file_url":"http://localhost:3000/statics/media/316/2026-10-20/offerte.pdf"}}"#;
        assert_eq!(gowa::download(answer), Some(("/statics/media/316/2026-10-20/offerte.pdf".into(), Some("offerte.pdf".into()))));
        let spaced = gowa::download(br#"{"results":{"file_path":"statics/media/a b.pdf"}}"#);
        assert_eq!(spaced.map(|d| d.0).as_deref(), Some("/statics/media/a%20b.pdf"));
        assert_eq!(gowa::download(br#"{"results":{"file_path":"/etc/passwd"}}"#), None);
        assert_eq!(gowa::download(br#"{"results":{"file_path":"statics/../../etc/passwd"}}"#), None);
    }

    #[tokio::test]
    async fn media_comes_from_the_gateway_with_its_type() {
        let server = TestServer::start(vec![
            ("GET /devices", 200, r#"{"results":[{"id":"nook","state":"logged_in","jid":"31611111111@s.whatsapp.net"}]}"#.into()),
            ("GET /message/*", 200, r#"{"results":{"filename":"a.pdf","file_path":"statics/media/a.pdf"}}"#.into()),
            ("GET /statics/*", 200, "%PDF-1.4".into()),
        ])
        .await;
        let provider = Provider::new(GatewayKind::Gowa, &server.url(""), None).unwrap();
        provider.status().await.unwrap();
        let file = provider.media("31622222222@s.whatsapp.net", "M1").await.unwrap();
        assert_eq!(file.data, b"%PDF-1.4");
        assert_eq!(file.name.as_deref(), Some("a.pdf"));
        assert_eq!(file.mime.as_deref(), Some("text/plain"));
        let asked = server.requests();
        assert!(asked[1].path.starts_with("/message/M1/download?"), "{}", asked[1].path);
        assert!(asked[1].path.contains("device_id=nook"));
        assert_eq!(asked[2].path, "/statics/media/a.pdf");
    }

    #[test]
    fn openwa_answers() {
        assert_eq!(openwa::id("316@s.whatsapp.net"), "316@c.us");
        assert_eq!(openwa::id("1@g.us"), "1@g.us");
        assert!(openwa::needs_start("created"));
        assert_eq!(openwa::error_message(br#"{"statusCode":400,"message":["a","b"]}"#).as_deref(), Some("a, b"));
        let png = base64::engine::general_purpose::STANDARD.encode([0x89, 0x50]);
        assert_eq!(openwa::qr_png(format!(r#"{{"qrCode":"data:image/png;base64,{png}"}}"#).as_bytes()), Some(vec![0x89, 0x50]));
    }

    #[tokio::test]
    async fn gowa_status_send_and_auth() {
        let server = TestServer::start(vec![
            ("GET /devices", 200, r#"{"results":[{"id":"nook","state":"logged_in","jid":"31611111111@s.whatsapp.net"}]}"#.into()),
            ("POST /send/message", 200, r#"{"results":{"message_id":"M9"}}"#.into()),
        ])
        .await;
        let provider = Provider::new(GatewayKind::Gowa, &server.url(""), Some("nook:geheim")).unwrap();
        assert_eq!(provider.status().await.unwrap().link, LinkState::Connected);
        assert_eq!(provider.send("Hoi", "31622222222@s.whatsapp.net").await.unwrap().as_deref(), Some("M9"));
        let sent = server.requests();
        assert_eq!(sent[0].header("authorization"), Some("Basic bm9vazpnZWhlaW0="));
        assert!(sent[1].path.contains("device_id=nook"));
        assert!(sent[1].body.contains("\"phone\":\"31622222222@s.whatsapp.net\""));
        let down = Provider::new(GatewayKind::Gowa, "http://127.0.0.1:9", None).unwrap();
        assert_eq!(down.status().await, Err(WaError::Unreachable));
    }
}
