//! Moving from Beeper Desktop (`BeeperImport`, `BeeperImporter` on the Mac, CH-20): bringing over, once, what someone
//! set up in Beeper Desktop so moving to Nook does not mean setting it all up again.
//!
//! Nook links chat apps itself through its own chat helper and WhatsApp gateway; for the move it asks Beeper Desktop's
//! local API (`http://localhost:23373`, Beeper › Settings › Developers, on this computer only) one last time: which
//! apps are linked there and as whom, the chats with their recent text history, and which chats are pinned, muted or
//! archived. History lands in the shared [`ChatInbox`], and the pins, mutes and archives follow each chat once its app
//! is linked in Nook.
//!
//! What cannot come over is an app's sign-in itself: Beeper keeps those and its API does not hand them out. Each app
//! is linked once more in Nook, with the account Beeper knew shown next to it. When the move is done the token is
//! forgotten and Nook never asks Beeper again.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::chatd::{self, ChatdClient, ServiceChat};
use super::{BridgedChat, ChatInbox, InboxMessage, InboxStore};
use crate::paths;
use crate::secrets::SecretStore;

/// Beeper Desktop's local API (runs on localhost:23373 on Windows, macOS, and Linux).
pub const DEFAULT_BASE: &str = "http://localhost:23373";
/// Where Nook stores Beeper's access token in the vault until the move finishes.
pub const TOKEN_ACCOUNT: &str = "chats.beeper.token";
/// Persisted move state (`done`, `was_whatsapp_gateway`, waiting per-chat settings).
pub const FILE_NAME: &str = "beeper-import.json";
/// Chats and messages per chat brought over, matching macOS `BeeperImport`.
pub const CHAT_COUNT: usize = 200;
pub const HISTORY: usize = 50;
/// How long a chat's setting waits for its app to be linked in Nook (60 days).
pub const SETTINGS_KEEP_DAYS: i64 = 60;
/// Apps whose chats come back with their own history once linked in Nook and are not brought over.
pub const OWN_HISTORY: &[&str] = &["whatsapp"];

/// One account linked in Beeper: the app in Nook it belongs to, and who it is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeeperAccount {
    pub id: String,
    /// The app id in Nook (e.g. `telegram`, `signal`, `instagram`, `slack`).
    pub app: String,
    /// Who it is: the display name, else username, phone number or email.
    pub name: String,
}

/// What Beeper had set for one chat. Matched by app + folded chat title once that app is linked in Nook, and applied
/// once in the chat's app through the chat helper.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSetting {
    pub app: String,
    pub name: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub archived: bool,
    /// When it was brought over: one whose chat never shows up is let go after [`SETTINGS_KEEP_DAYS`].
    pub since: DateTime<Utc>,
}

impl ChatSetting {
    pub fn key(&self) -> String {
        ChatInbox::key_by_name(&self.app, &self.name)
    }
}

/// What is still to be done in a chat Nook's chat helper lists, for the setting Beeper had: nothing when the chat
/// already is that way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SettingChange {
    pub pin: bool,
    pub mute: bool,
    pub archive: bool,
}

impl SettingChange {
    pub fn is_empty(&self) -> bool {
        !self.pin && !self.mute && !self.archive
    }
}

/// How many chats came over with their history and how many per-chat settings are waiting for their app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportedSummary {
    pub chats: usize,
    pub settings: usize,
}

/// Structured error returned by Beeper's local API so the UI can translate each failure cleanly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum BeeperProblem {
    Unreachable,
    Unauthorized,
    Failed(String),
}

/// Snapshot sent to Settings › Connections › Chat apps (`BeeperImportSection` / `BeeperImportSheet`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeeperImportStatus {
    /// Whether the "Moving from Beeper" row should be shown in Settings.
    pub offered: bool,
    pub done: bool,
    pub has_token: bool,
    pub busy: bool,
    pub installed: bool,
    pub problem: Option<BeeperProblem>,
    pub accounts: Vec<BeeperAccount>,
    /// Apps to link in Nook: those of Beeper's accounts, plus WhatsApp if it previously went through Beeper.
    pub apps: Vec<String>,
    pub imported: Option<ImportedSummary>,
    pub waiting_settings: usize,
}

/// `GET /v1/accounts` (either a JSON array or `{ "items": [...] }`): every account of an app Nook knows, one per
/// `(app, name)`, in Beeper's order. Beeper's own Matrix network is left out.
pub fn accounts(root: &Value) -> Vec<BeeperAccount> {
    let list = root.as_array().or_else(|| root.get("items").and_then(Value::as_array)).map_or(&[][..], Vec::as_slice);
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for account in list {
        let id = account.get("accountID").or_else(|| account.get("id")).and_then(Value::as_str).unwrap_or_default().trim().to_string();
        if id.is_empty() {
            continue;
        }
        let network = account.get("network").or_else(|| account.get("networkName")).and_then(Value::as_str).unwrap_or_default();
        let Some(app) = chatd::app(network, &id) else { continue };
        let user = account.get("user").and_then(Value::as_object);
        let name = ["fullName", "displayName", "username", "phoneNumber", "email"]
            .iter()
            .find_map(|key| user.and_then(|u| u.get(*key)).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()))
            .unwrap_or_default()
            .to_string();
        if !seen.insert(format!("{app}|{name}")) {
            continue;
        }
        out.push(BeeperAccount { id, app: app.to_string(), name });
    }
    out
}

/// The apps the accounts belong to, each once, in their order.
pub fn apps(accounts: &[BeeperAccount]) -> Vec<String> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut out = Vec::new();
    for account in accounts {
        if seen.insert(account.app.as_str()) {
            out.push(account.app.clone());
        }
    }
    out
}

/// The pinned, muted and archived chats of `GET /v1/chats`, archived ones included, of the apps Nook knows (WhatsApp
/// and merged rows aside).
pub fn settings(json: &Value, now: DateTime<Utc>) -> Vec<ChatSetting> {
    let list = json.get("items").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let mut out = Vec::new();
    for chat in list {
        if chat.get("merge").is_some_and(|m| !m.is_null())
            || chat.get("mergedIntoChatID").and_then(Value::as_str).is_some_and(|s| !s.is_empty())
        {
            continue;
        }
        let network = chat.get("network").and_then(Value::as_str).unwrap_or_default();
        let account = chat.get("accountID").and_then(Value::as_str).unwrap_or_default();
        let Some(app) = chatd::app(network, account) else { continue };
        if OWN_HISTORY.contains(&app) {
            continue;
        }
        let name = chat.get("title").and_then(Value::as_str).unwrap_or_default().trim().to_string();
        if name.is_empty() {
            continue;
        }
        let pinned = chat.get("isPinned").and_then(Value::as_bool) == Some(true);
        let muted = chat.get("isMuted").and_then(Value::as_bool) == Some(true);
        let archived = chat.get("isArchived").and_then(Value::as_bool) == Some(true);
        if !pinned && !muted && !archived {
            continue;
        }
        out.push(ChatSetting { app: app.to_string(), name, pinned, muted, archived, since: now });
    }
    out
}

/// The settings still waiting, with `new` ones added (a newer one for the same chat replaces the older), and those
/// that waited longer than [`SETTINGS_KEEP_DAYS`] let go.
pub fn merged(waiting: &[ChatSetting], new: &[ChatSetting], now: DateTime<Utc>) -> Vec<ChatSetting> {
    let mut by_key: HashMap<String, ChatSetting> = HashMap::new();
    for setting in waiting.iter().chain(new.iter()) {
        by_key.insert(setting.key(), setting.clone());
    }
    let keep = chrono::Duration::days(SETTINGS_KEEP_DAYS);
    let mut out: Vec<ChatSetting> = by_key.into_values().filter(|s| now - s.since < keep).collect();
    out.sort_by_key(|s| s.key());
    out
}

/// What is still to be done in `chat` for `setting` from Beeper.
pub fn change(setting: &ChatSetting, chat: &ServiceChat) -> SettingChange {
    SettingChange { pin: setting.pinned && !chat.is_pinned, mute: setting.muted && !chat.is_muted, archive: setting.archived }
}

/// The messages of a chat brought over: those with text only. Files stay in Beeper's own folder, which Nook does not
/// read; once the app is linked in Nook, its chats come in again with their files.
pub fn history(messages: Vec<InboxMessage>) -> Vec<InboxMessage> {
    messages.into_iter().filter(|m| m.media.is_none() && m.poll.is_none() && !m.text.is_empty()).collect()
}

/// Best-effort detection of a Beeper Desktop installation on this computer (Windows, macOS, Linux).
pub fn installed_executable() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        let mut candidates = Vec::new();
        if let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
            candidates.push(local.join("Programs").join("BeeperTexts").join("Beeper.exe"));
            candidates.push(local.join("Programs").join("Beeper").join("Beeper.exe"));
            candidates.push(local.join("BeeperTexts").join("Beeper.exe"));
            candidates.push(local.join("Beeper").join("Beeper.exe"));
        }
        if let Some(pf) = std::env::var_os("ProgramFiles").map(PathBuf::from) {
            candidates.push(pf.join("BeeperTexts").join("Beeper.exe"));
            candidates.push(pf.join("Beeper").join("Beeper.exe"));
        }
        candidates.into_iter().find(|p| p.is_file())
    }
    #[cfg(target_os = "macos")]
    {
        let mut candidates = vec![PathBuf::from("/Applications/Beeper Desktop.app"), PathBuf::from("/Applications/Beeper.app")];
        if let Some(home) = dirs::home_dir() {
            candidates.push(home.join("Applications/Beeper Desktop.app"));
            candidates.push(home.join("Applications/Beeper.app"));
        }
        candidates.into_iter().find(|p| p.exists())
    }
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    {
        let mut candidates = vec![
            PathBuf::from("/usr/share/applications/beeper.desktop"),
            PathBuf::from("/usr/bin/beeper"),
            PathBuf::from("/opt/Beeper/beeper"),
        ];
        if let Some(home) = dirs::home_dir() {
            candidates.push(home.join(".local/share/applications/beeper.desktop"));
        }
        candidates.into_iter().find(|p| p.exists())
    }
}

/// Fast local check whether Beeper Desktop's API is currently listening on localhost:23373.
fn local_api_listening(base: &str) -> bool {
    let Ok(url) = url::Url::parse(base) else { return false };
    let host = url.host_str().unwrap_or("127.0.0.1");
    let port = url.port_or_known_default().unwrap_or(23373);
    let addr = if host.eq_ignore_ascii_case("localhost") { format!("127.0.0.1:{port}") } else { format!("{host}:{port}") };
    let Ok(sock) = addr.parse::<std::net::SocketAddr>() else { return false };
    std::net::TcpStream::connect_timeout(&sock, Duration::from_millis(120)).is_ok()
}

/// Persisted state on disk (`beeper-import.json`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Persisted {
    done: bool,
    was_whatsapp_gateway: bool,
    settings: Vec<ChatSetting>,
}

#[derive(Default)]
struct Runtime {
    persisted: Persisted,
    accounts: Vec<BeeperAccount>,
    imported: Option<ImportedSummary>,
    busy: bool,
    problem: Option<BeeperProblem>,
}

/// Reads Beeper Desktop's local API and moves accounts, recent text history, and waiting chat settings into Nook.
pub struct BeeperImporter {
    secrets: Arc<dyn SecretStore>,
    base: String,
    path: Option<PathBuf>,
    http: reqwest::Client,
    state: Mutex<Runtime>,
}

impl BeeperImporter {
    pub fn open_default(secrets: Arc<dyn SecretStore>) -> Arc<Self> {
        Self::open(secrets, DEFAULT_BASE.to_string(), Some(paths::support_directory().join(FILE_NAME)))
    }

    pub fn in_memory(secrets: Arc<dyn SecretStore>, base: impl Into<String>) -> Arc<Self> {
        Self::open(secrets, base.into(), None)
    }

    pub fn open(secrets: Arc<dyn SecretStore>, base: String, path: Option<PathBuf>) -> Arc<Self> {
        let persisted: Persisted = path.as_ref().map(|p| crate::storage_recovery::read_json_plain(p)).unwrap_or_default();
        let http = reqwest::Client::builder().timeout(Duration::from_secs(20)).no_proxy().build().unwrap_or_default();
        Arc::new(Self {
            secrets,
            base: base.trim_end_matches('/').to_string(),
            path,
            http,
            state: Mutex::new(Runtime { persisted, ..Default::default() }),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Runtime> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn save_persisted(&self, persisted: &Persisted) {
        let Some(path) = &self.path else { return };
        if let Ok(bytes) = serde_json::to_vec_pretty(persisted) {
            let _ = paths::write_atomic(path, &bytes);
        }
    }

    fn has_token(&self) -> bool {
        self.secrets.read(TOKEN_ACCOUNT).is_some_and(|t| !t.trim().is_empty())
    }

    /// Snapshot of the current Beeper import state for Settings UI.
    pub fn status(&self) -> BeeperImportStatus {
        let has_token = self.has_token();
        let installed = installed_executable().is_some();
        let g = self.lock();
        let done = g.persisted.done;
        let was_wa = g.persisted.was_whatsapp_gateway;
        let mut app_list = apps(&g.accounts);
        if was_wa && !app_list.iter().any(|a| a == "whatsapp") {
            app_list.insert(0, "whatsapp".to_string());
        }
        let listening = if !done && !has_token && !was_wa && !installed { local_api_listening(&self.base) } else { false };
        let offered = !done && (has_token || was_wa || installed || listening);
        BeeperImportStatus {
            offered,
            done,
            has_token,
            busy: g.busy,
            installed: installed || listening,
            problem: g.problem.clone(),
            accounts: g.accounts.clone(),
            apps: app_list,
            imported: g.imported,
            waiting_settings: g.persisted.settings.len(),
        }
    }

    /// Stores the Beeper Desktop access token pasted in Settings.
    pub fn save_token(&self, token: &str) -> Result<BeeperImportStatus, String> {
        let value = token.trim();
        if value.is_empty() {
            return Err("Beeper access token is empty.".into());
        }
        self.secrets.write(TOKEN_ACCOUNT, value)?;
        {
            let mut g = self.lock();
            g.problem = None;
            // Saving a token explicitly makes the move active again if previously dismissed.
            if g.persisted.done {
                g.persisted.done = false;
                self.save_persisted(&g.persisted);
            }
        }
        Ok(self.status())
    }

    /// Marks the move as done: forgets Beeper's token and stops offering the move in Settings.
    /// Waiting per-chat settings stay so linking an app later still applies them.
    pub fn finish(&self) -> BeeperImportStatus {
        let _ = self.secrets.remove(TOKEN_ACCOUNT);
        {
            let mut g = self.lock();
            g.persisted.done = true;
            g.persisted.was_whatsapp_gateway = false;
            g.accounts.clear();
            g.imported = None;
            g.problem = None;
            self.save_persisted(&g.persisted);
        }
        self.status()
    }

    /// Whether there are any waiting per-chat settings from Beeper.
    pub fn has_waiting_settings(&self) -> bool {
        !self.lock().persisted.settings.is_empty()
    }

    /// Reads Beeper Desktop's local API, imports text history into `inbox`, and saves waiting per-chat settings
    /// (pins, mutes, archives) for helper apps.
    pub async fn run(&self, inbox: &InboxStore) -> Result<BeeperImportStatus, BeeperProblem> {
        let token = self.secrets.read(TOKEN_ACCOUNT).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let Some(token) = token else {
            return Err(BeeperProblem::Unauthorized);
        };
        {
            let mut g = self.lock();
            if g.busy {
                drop(g);
                return Ok(self.status());
            }
            g.busy = true;
            g.problem = None;
        }

        let outcome = self.run_inner(&token, inbox).await;
        match outcome {
            Ok((found_accounts, summary, new_settings)) => {
                let mut g = self.lock();
                g.busy = false;
                g.accounts = found_accounts;
                g.imported = Some(summary);
                g.problem = None;
                g.persisted.settings = merged(&g.persisted.settings, &new_settings, Utc::now());
                self.save_persisted(&g.persisted);
                drop(g);
                Ok(self.status())
            }
            Err(problem) => {
                let mut g = self.lock();
                g.busy = false;
                g.problem = Some(problem.clone());
                drop(g);
                Err(problem)
            }
        }
    }

    async fn run_inner(
        &self,
        token: &str,
        inbox: &InboxStore,
    ) -> Result<(Vec<BeeperAccount>, ImportedSummary, Vec<ChatSetting>), BeeperProblem> {
        let accounts_json = self.get_json("/v1/accounts", &[], token).await?;
        let found_accounts = accounts(&accounts_json);

        let chats_json = self.get_json("/v1/chats", &[("limit", CHAT_COUNT.to_string())], token).await?;
        let mut bridged_chats: Vec<BridgedChat> = Vec::new();
        for chat in chatd::chats(&chats_json) {
            if OWN_HISTORY.contains(&chat.app.as_str()) {
                continue;
            }
            let encoded = percent_encoding::utf8_percent_encode(&chat.id, percent_encoding::NON_ALPHANUMERIC);
            let path = format!("/v1/chats/{encoded}/messages");
            let answer = self.get_json(&path, &[("limit", HISTORY.to_string())], token).await?;
            let msgs = history(chatd::messages(&answer, &chat));
            if msgs.is_empty() {
                continue;
            }
            // The unread count stays Nook's: these chats were read (or not) in Beeper, not here.
            bridged_chats.push(BridgedChat {
                app: chat.app,
                name: chat.title,
                chat_id: None,
                messages: msgs,
                unread: None,
                members: (!chat.members.is_empty()).then_some(chat.members),
                history: true,
                ..Default::default()
            });
        }

        let now = Utc::now();
        let brought = inbox.with(|i| {
            let mut count = 0usize;
            for chat in bridged_chats {
                if i.merge(chat, now) {
                    count += 1;
                }
            }
            count
        });

        // Only the apps Nook's chat helper links can have a chat pinned, muted or archived from Nook.
        let new_settings: Vec<ChatSetting> =
            settings(&chats_json, now).into_iter().filter(|s| chatd::APPS.contains(&s.app.as_str())).collect();
        let summary = ImportedSummary { chats: brought, settings: new_settings.len() };
        Ok((found_accounts, summary, new_settings))
    }

    /// Applies any waiting Beeper chat settings (pin, mute, archive) to chats newly listed by Nook's chat helper.
    /// Each matched chat is removed from the waiting list first so a refused change is never retried endlessly.
    /// Returns the helper-side ids of chats that were archived.
    pub async fn apply_settings(&self, listed: &[ServiceChat], client: &ChatdClient) -> HashSet<String> {
        let mut waiting = {
            let g = self.lock();
            if g.persisted.settings.is_empty() {
                return HashSet::new();
            }
            g.persisted.settings.clone()
        };

        let mut archived = HashSet::new();
        for chat in listed {
            let key = ChatInbox::key_by_name(&chat.app, &chat.title);
            let Some(pos) = waiting.iter().position(|s| s.key() == key) else { continue };
            let setting = waiting.remove(pos);
            // Persist removal immediately so a failure does not retry at every read.
            {
                let mut g = self.lock();
                g.persisted.settings = waiting.clone();
                self.save_persisted(&g.persisted);
            }
            let diff = change(&setting, chat);
            if diff.is_empty() {
                continue;
            }
            if diff.pin || diff.mute {
                if let Err(error) = client.set_chat(&chat.id, diff.pin.then_some(true), diff.mute.then_some(true)).await {
                    log::info!("Chats: Beeper pin/mute setting could not be applied: {error}");
                }
            }
            if diff.archive {
                match client.archive(&chat.id, true).await {
                    Ok(()) => {
                        archived.insert(chat.id.clone());
                    }
                    Err(error) => {
                        log::info!("Chats: Beeper archive setting could not be applied: {error}");
                    }
                }
            }
        }

        let pruned = merged(&waiting, &[], Utc::now());
        {
            let mut g = self.lock();
            if g.persisted.settings != pruned {
                g.persisted.settings = pruned;
                self.save_persisted(&g.persisted);
            }
        }
        archived
    }

    async fn get_json(&self, path: &str, query: &[(&str, String)], token: &str) -> Result<Value, BeeperProblem> {
        let url = format!("{}{path}", self.base);
        let response = self.http.get(url).bearer_auth(token).query(query).send().await.map_err(|_| BeeperProblem::Unreachable)?;
        let status = response.status();
        let data = response.bytes().await.map_err(|_| BeeperProblem::Unreachable)?;
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(BeeperProblem::Unauthorized);
        }
        let json: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
        if !status.is_success() {
            let reason = ["message", "error", "code"]
                .iter()
                .find_map(|k| json.get(*k).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string));
            return Err(BeeperProblem::Failed(reason.unwrap_or_else(|| format!("HTTP {}", status.as_u16()))));
        }
        Ok(json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::ChatMedia;
    use crate::connectors::testserver::TestServer;
    use crate::secrets::MemorySecrets;
    use chrono::TimeZone;
    use serde_json::json;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    #[test]
    fn accounts_go_to_their_apps() {
        let listed = json!([
            {"accountID": "instagramgo", "network": "Instagram", "user": {"username": "anna.ig"}},
            {"accountID": "local-telegram_1", "network": "Telegram", "user": {"fullName": " ", "phoneNumber": "+316"}},
            {"accountID": "hungryserv", "network": "Beeper", "user": {"fullName": "Anna"}},
            {"accountID": "gmessages", "network": "Google Messages", "user": {"fullName": "Anna"}},
            {"accountID": "instagramgo", "network": "Instagram", "user": {"username": "anna.ig"}},
            {"accountID": "", "network": "Signal"}
        ]);
        let found = accounts(&listed);
        let app_names: Vec<&str> = found.iter().map(|a| a.app.as_str()).collect();
        let user_names: Vec<&str> = found.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(app_names, vec!["instagram", "telegram"], "Beeper's own network, unknown ones and repeats left out");
        assert_eq!(user_names, vec!["anna.ig", "+316"], "the first name there is");

        let wrapped = json!({"items": [{"accountID": "signal", "network": "Signal"}]});
        assert_eq!(accounts(&wrapped).iter().map(|a| a.app.as_str()).collect::<Vec<_>>(), vec!["signal"]);
        assert!(accounts(&Value::Null).is_empty());
    }

    #[test]
    fn apps_once_each() {
        let list = vec![
            BeeperAccount { id: "a".into(), app: "signal".into(), name: "Anna".into() },
            BeeperAccount { id: "b".into(), app: "x".into(), name: "anna".into() },
            BeeperAccount { id: "c".into(), app: "signal".into(), name: "Werk".into() },
        ];
        assert_eq!(apps(&list), vec!["signal", "x"]);
    }

    #[test]
    fn chat_settings_filter_merged_whatsapp_and_unset() {
        let found = settings(
            &json!({"items": [
                {"id": "!a", "accountID": "instagramgo", "network": "Instagram", "title": "Anna", "isPinned": true},
                {"id": "!b", "accountID": "signal", "network": "Signal", "title": "Club", "isMuted": true, "isArchived": true},
                {"id": "!c", "accountID": "signal", "network": "Signal", "title": "Jan"},
                {"id": "!d", "accountID": "whatsapp", "network": "WhatsApp", "title": "Familie", "isPinned": true},
                {"id": "!e", "accountID": "signal", "network": "Signal", "title": "Alles", "isPinned": true, "merge": {}},
                {"id": "!f", "accountID": "signal", "network": "Signal", "title": " ", "isPinned": true}
            ]}),
            now(),
        );
        let keys: Vec<String> = found.iter().map(ChatSetting::key).collect();
        assert_eq!(keys, vec![ChatInbox::key_by_name("instagram", "Anna"), ChatInbox::key_by_name("signal", "Club")]);
        assert!(found[0].pinned);
        assert!(found[1].muted && found[1].archived);
        assert!(!found[1].pinned);
    }

    #[test]
    fn settings_wait_then_expire() {
        let old = ChatSetting { app: "signal".into(), name: "Club".into(), pinned: true, muted: false, archived: false, since: now() };
        let newer = ChatSetting {
            app: "signal".into(),
            name: "Club".into(),
            pinned: false,
            muted: true,
            archived: false,
            since: now() + chrono::Duration::seconds(60),
        };
        let other = ChatSetting { app: "x".into(), name: "Jan".into(), pinned: true, muted: false, archived: false, since: now() };
        let out = merged(&[old, other.clone()], std::slice::from_ref(&newer), now() + chrono::Duration::seconds(120));
        let mut expected = vec![newer, other];
        expected.sort_by_key(|s| s.key());
        assert_eq!(out, expected, "a newer setting for a chat replaces the older");

        let expired = merged(&out, &[], now() + chrono::Duration::days(SETTINGS_KEEP_DAYS) + chrono::Duration::seconds(61));
        assert!(expired.is_empty(), "settings whose chat never shows up are let go");
    }

    #[test]
    fn only_what_is_not_done_yet_changes() {
        let setting = ChatSetting { app: "signal".into(), name: "Club".into(), pinned: true, muted: true, archived: false, since: now() };
        let mut chat = ServiceChat { id: "!b".into(), app: "signal".into(), title: "Club".into(), is_group: true, ..Default::default() };
        assert_eq!(change(&setting, &chat), SettingChange { pin: true, mute: true, archive: false });
        chat.is_pinned = true;
        chat.is_muted = true;
        assert!(change(&setting, &chat).is_empty());

        let archived = ChatSetting { app: "signal".into(), name: "Club".into(), pinned: false, muted: false, archived: true, since: now() };
        assert_eq!(change(&archived, &chat), SettingChange { pin: false, mute: false, archive: true });
    }

    #[test]
    fn history_keeps_text_only() {
        let mut img = InboxMessage::new("2", "", now(), false);
        img.media = ChatMedia::Image;
        let mut img_with_caption = InboxMessage::new("3", "kijk", now(), false);
        img_with_caption.media = ChatMedia::Image;
        let messages = vec![InboxMessage::new("1", "hoi", now(), false), img, img_with_caption, InboxMessage::new("4", "", now(), false)];
        let ids: Vec<String> = history(messages).into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["1"], "files stay in Beeper's folder");
    }

    #[tokio::test]
    async fn importer_reads_beeper_imports_history_and_applies_waiting_settings() {
        let beeper_server = TestServer::start(vec![
            (
                "GET /v1/accounts",
                200,
                json!([
                    {"accountID": "signal_1", "network": "Signal", "user": {"fullName": "Anna"}},
                    {"accountID": "whatsapp_1", "network": "WhatsApp", "user": {"phoneNumber": "+316123"}}
                ])
                .to_string(),
            ),
            (
                "GET /v1/chats",
                200,
                json!({"items": [
                    {"id": "!sig1", "accountID": "signal_1", "network": "Signal", "title": "Club", "type": "group", "isPinned": true, "isMuted": true},
                    {"id": "!wa1", "accountID": "whatsapp_1", "network": "WhatsApp", "title": "Familie", "isPinned": true}
                ]})
                .to_string(),
            ),
            (
                "GET /v1/chats/*",
                200,
                json!({"items": [
                    {"id": "m1", "timestamp": "2026-10-18T12:00:00Z", "isSender": false, "senderName": "Bo", "text": "Welkom!"},
                    {"id": "m2", "timestamp": "2026-10-18T12:01:00Z", "isSender": false, "text": "", "attachments": [{"type": "img", "mimeType": "image/jpeg"}]}
                ]})
                .to_string(),
            ),
        ])
        .await;

        let secrets = Arc::new(MemorySecrets::default());
        let importer = BeeperImporter::in_memory(secrets.clone(), beeper_server.url(""));
        importer.save_token("beeper-secret").unwrap();
        let inbox = InboxStore::memory();

        let status = importer.run(&inbox).await.unwrap();
        assert_eq!(status.apps, vec!["signal", "whatsapp"]);
        assert_eq!(status.imported, Some(ImportedSummary { chats: 1, settings: 1 }));
        assert_eq!(status.waiting_settings, 1);

        // Text history landed in the inbox; WhatsApp and media-only messages were skipped.
        let threads = inbox.read(|i| i.threads.clone());
        assert_eq!(threads.len(), 1);
        let key = ChatInbox::key_by_name("signal", "Club");
        let thread = threads.get(&key).expect("signal Club thread imported");
        assert_eq!(thread.messages.len(), 1);
        assert_eq!(thread.messages[0].text, "Welkom!");

        // Applying waiting settings against a linked helper server pins & mutes Club once.
        let helper_server = TestServer::start(vec![("PATCH /v1/chats/*", 200, "{}".into())]).await;
        let client = ChatdClient::new(helper_server.url(""), "helper-tok");
        let listed = vec![ServiceChat { id: "helper-club".into(), app: "signal".into(), title: "Club".into(), ..Default::default() }];
        let archived = importer.apply_settings(&listed, &client).await;
        assert!(archived.is_empty());
        assert!(!importer.has_waiting_settings());
        let seen = helper_server.received.lock().unwrap().clone();
        assert_eq!(seen.len(), 1);
        assert!(seen[0].body.contains("\"isPinned\":true") && seen[0].body.contains("\"isMuted\":true"));

        // Finishing forgets the token and marks done.
        let finished = importer.finish();
        assert!(finished.done);
        assert!(!finished.has_token);
        assert!(!finished.offered);
    }
}
