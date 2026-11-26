//! Chat messages from Windows' own notifications, for the chat apps Nook has no link of its own for here (Discord first:
//! linking a Discord account is not offered, see docs/ADR-CHAT-LINKS.md). This is the Windows side of what the Mac does
//! with macOS notifications: read-only previews of what came in, no history, no sending.
//!
//! Windows keeps every app's notifications in its own SQLite database (`wpndatabase.db` under
//! `%LOCALAPPDATA%\Microsoft\Windows\Notifications`), readable by the signed-in user. Nook opens it read-only, takes
//! the toasts of the chat apps below that arrived since its last look, and reads each through the app's notice layout
//! ([`super::apps::parse_notice`]) into a [`BridgedChat`]. A toast's text never leaves this computer.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use regex::Regex;

use super::apps::parse_notice;
use super::{BridgedChat, ChatBridge, InboxMessage};

/// The chat apps whose Windows notifications are their messages, by a word in the notification handler's id (its
/// AppUserModelID, such as `com.squirrel.Discord.Discord`). Lower case, most specific first.
const HANDLERS: [(&str, &str); 8] = [
    ("discord", "discord"),
    ("whatsapp", "whatsapp"),
    ("telegram", "telegram"),
    ("signal", "signal"),
    ("viber", "viber"),
    ("wechat", "wechat"),
    ("weixin", "wechat"),
    ("threema", "threema"),
];

/// How far back the first look goes: older toasts were seen in the app already.
const FIRST_LOOK_DAYS: i64 = 3;
/// Toasts one look reads at most.
const BATCH: usize = 500;
/// Nook's id of a message from a notification: `toast-<the database's id>`.
pub const ID_PREFIX: &str = "toast-";

/// The chat app of a notification handler; `None` for every other app.
pub fn app_for_handler(handler: &str) -> Option<&'static str> {
    let handler = handler.to_lowercase();
    HANDLERS.iter().find(|(word, _)| handler.contains(word)).map(|(_, app)| *app)
}

/// Windows' FILETIME (100 ns since 1601) as a date.
pub fn filetime(ticks: i64) -> Option<DateTime<Utc>> {
    const UNIX_EPOCH_MS: i64 = 11_644_473_600_000;
    Utc.timestamp_millis_opt(ticks / 10_000 - UNIX_EPOCH_MS).single()
}

fn unescape(text: &str) -> String {
    let numeric = Regex::new(r"&#(x[0-9a-fA-F]+|[0-9]+);").expect("valid");
    let text = numeric.replace_all(text, |c: &regex::Captures| {
        let code = &c[1];
        let n = match code.strip_prefix('x') {
            Some(hex) => u32::from_str_radix(hex, 16).ok(),
            None => code.parse().ok(),
        };
        n.and_then(char::from_u32).map(String::from).unwrap_or_default()
    });
    text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// The lines a toast's XML shows, in order: its `<text>` elements, without the attribution line.
pub fn toast_texts(xml: &str) -> Vec<String> {
    let text = Regex::new(r"(?s)<text(\s[^>]*)?>(.*?)</text>").expect("valid");
    text.captures_iter(xml)
        .filter(|c| !c.get(1).is_some_and(|a| a.as_str().contains("attribution")))
        .map(|c| unescape(c[2].trim()))
        .filter(|t| !t.is_empty())
        .collect()
}

/// One toast as the database holds it.
#[derive(Debug, Clone, PartialEq)]
pub struct Toast {
    pub id: i64,
    pub handler: String,
    pub arrival: i64,
    pub payload: String,
}

/// One toast as a message in its chat; `None` for another app or a toast without words.
pub fn chat_of(toast: &Toast) -> Option<BridgedChat> {
    let app = app_for_handler(&toast.handler)?;
    let lines = toast_texts(&toast.payload);
    let (title, body) = match lines.as_slice() {
        [] => return None,
        [only] => (only.clone(), String::new()),
        [title, rest @ ..] => (title.clone(), rest.join("\n")),
    };
    let notice = parse_notice(app, &title, "", &body, false);
    if notice.chat.is_empty() || notice.text.is_empty() {
        return None;
    }
    let date = filetime(toast.arrival)?;
    let mut message = InboxMessage::new(format!("{ID_PREFIX}{}", toast.id), notice.text, date, false);
    message.sender = notice.sender;
    Some(BridgedChat { app: app.to_string(), name: notice.chat, messages: vec![message], ..Default::default() })
}

/// Toasts of one look, folded into one [`BridgedChat`] per chat, oldest message first.
pub fn chats_of(toasts: &[Toast]) -> Vec<BridgedChat> {
    let mut chats: BTreeMap<(String, String), BridgedChat> = BTreeMap::new();
    for chat in toasts.iter().filter_map(chat_of) {
        match chats.get_mut(&(chat.app.clone(), chat.name.clone())) {
            Some(existing) => existing.messages.extend(chat.messages),
            None => {
                chats.insert((chat.app.clone(), chat.name.clone()), chat);
            }
        }
    }
    let mut chats: Vec<_> = chats.into_values().collect();
    for chat in &mut chats {
        chat.messages.sort_by_key(|m| m.date);
    }
    chats
}

/// Where Windows keeps the signed-in user's notifications.
pub fn default_database() -> Option<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA")?;
    Some(PathBuf::from(local).join("Microsoft").join("Windows").join("Notifications").join("wpndatabase.db"))
}

/// The toasts after `after` (by id), oldest first, opening the database read-only.
pub fn read_toasts(path: &std::path::Path, after: i64, since: i64) -> Result<Vec<Toast>, String> {
    use rusqlite::OpenFlags;
    let db = rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .map_err(|e| e.to_string())?;
    db.busy_timeout(Duration::from_secs(2)).map_err(|e| e.to_string())?;
    let mut query = db
        .prepare(
            "SELECT n.Id, h.PrimaryId, n.ArrivalTime, n.Payload FROM Notification n \
             JOIN NotificationHandler h ON h.RecordId = n.HandlerId \
             WHERE n.Type = 'toast' AND n.Id > ?1 AND n.ArrivalTime >= ?2 ORDER BY n.Id LIMIT ?3",
        )
        .map_err(|e| e.to_string())?;
    let rows = query
        .query_map(rusqlite::params![after, since, BATCH as i64], |row| {
            let payload: Vec<u8> = row.get::<_, Option<Vec<u8>>>(3)?.unwrap_or_default();
            Ok(Toast {
                id: row.get(0)?,
                handler: row.get(1)?,
                arrival: row.get(2)?,
                payload: String::from_utf8_lossy(&payload).into_owned(),
            })
        })
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

/// Whether an app has a link of its own right now (WhatsApp's gateway, the chat helper): its notifications are then
/// left to that link, so a message does not show twice.
pub type Linked = Arc<dyn Fn(&str) -> bool + Send + Sync>;

/// The chat apps' Windows notifications as a bridge of the shared inbox.
pub struct SystemNoticeBridge {
    path: PathBuf,
    linked: Linked,
    /// The newest toast id read; `None` before the first look.
    last: Mutex<Option<i64>>,
}

impl SystemNoticeBridge {
    pub fn new(path: PathBuf, linked: Linked) -> Self {
        Self { path, linked, last: Mutex::new(None) }
    }
}

#[async_trait]
impl ChatBridge for SystemNoticeBridge {
    fn app(&self) -> &str {
        "notifications"
    }

    fn is_ready(&self) -> bool {
        self.path.is_file()
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(5)
    }

    fn history_changes(&self) -> bool {
        false
    }

    async fn read(&self) -> Result<Vec<BridgedChat>, String> {
        let after = self.last.lock().unwrap_or_else(|e| e.into_inner()).unwrap_or(0);
        let since = (Utc::now() - chrono::Duration::days(FIRST_LOOK_DAYS)).timestamp_millis();
        // FILETIME of `since`.
        let since = (since + 11_644_473_600_000) * 10_000;
        let path = self.path.clone();
        let toasts = tokio::task::spawn_blocking(move || read_toasts(&path, after, since)).await.map_err(|e| e.to_string())??;
        if let Some(newest) = toasts.iter().map(|t| t.id).max() {
            *self.last.lock().unwrap_or_else(|e| e.into_inner()) = Some(newest);
        }
        Ok(chats_of(&toasts).into_iter().filter(|c| !(self.linked)(&c.app)).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISCORD_TOAST: &str = r#"<toast launch="discord://"><visual><binding template="ToastGeneric"><text hint-maxLines="1">Anna (#general, Nook &amp; Co)</text><text>see you at 8 &#x1F44B;</text><text placement="attribution">Discord</text><image placement="appLogoOverride" src="x.png"/></binding></visual></toast>"#;

    fn toast(id: i64, handler: &str, payload: &str) -> Toast {
        // 2026-11-26 12:00 UTC as FILETIME.
        let arrival = (1_795_694_400_000 + 11_644_473_600_000) * 10_000 + id * 10_000_000;
        Toast { id, handler: handler.into(), arrival, payload: payload.into() }
    }

    #[test]
    fn handlers_name_their_chat_app() {
        assert_eq!(app_for_handler("com.squirrel.Discord.Discord"), Some("discord"));
        assert_eq!(app_for_handler("com.squirrel.DiscordPTB.DiscordPTB"), Some("discord"));
        assert_eq!(app_for_handler("5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App"), Some("whatsapp"));
        assert_eq!(app_for_handler("Claude_pzs8sxrjxfjjc!Claude"), None);
    }

    #[test]
    fn a_toast_reads_without_its_attribution_and_with_its_entities() {
        assert_eq!(toast_texts(DISCORD_TOAST), ["Anna (#general, Nook & Co)", "see you at 8 👋"]);
    }

    #[test]
    fn a_discord_channel_toast_is_a_message_in_that_channel() {
        let chat = chat_of(&toast(7, "com.squirrel.Discord.Discord", DISCORD_TOAST)).unwrap();
        assert_eq!(chat.app, "discord");
        assert_eq!(chat.name, "#general, Nook & Co");
        assert_eq!(chat.messages[0].sender, "Anna");
        assert_eq!(chat.messages[0].text, "see you at 8 👋");
        assert_eq!(chat.messages[0].id, "toast-7");
        assert!(!chat.messages[0].from_me);
    }

    #[test]
    fn toasts_of_one_chat_fold_into_one_and_other_apps_are_left_out() {
        let direct = |id, text: &str| {
            toast(
                id,
                "com.squirrel.Discord.Discord",
                &format!("<toast><visual><binding><text>Bo</text><text>{text}</text></binding></visual></toast>"),
            )
        };
        let chats = chats_of(&[
            direct(2, "two"),
            direct(1, "one"),
            toast(3, "Chrome", "<toast><visual><binding><text>x</text><text>y</text></binding></visual></toast>"),
            toast(4, "com.squirrel.Discord.Discord", "<toast><visual><binding></binding></visual></toast>"),
        ]);
        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].name, "Bo");
        let texts: Vec<_> = chats[0].messages.iter().map(|m| m.text.as_str()).collect();
        assert_eq!(texts, ["one", "two"]);
    }

    #[test]
    fn filetime_is_unix_time_from_1601() {
        assert_eq!(filetime(116_444_736_000_000_000).unwrap().timestamp(), 0);
    }

    #[tokio::test]
    async fn the_bridge_reads_new_toasts_once_and_skips_linked_apps() {
        let dir = std::env::temp_dir().join(format!("nook-wpn-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("wpndatabase.db");
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch(
            "CREATE TABLE NotificationHandler (RecordId INTEGER PRIMARY KEY, PrimaryId TEXT);
             CREATE TABLE Notification (Id INTEGER PRIMARY KEY, HandlerId INTEGER, Type TEXT, Payload BLOB, ArrivalTime INTEGER);
             INSERT INTO NotificationHandler VALUES (1, 'com.squirrel.Discord.Discord'), (2, '5319275A.WhatsAppDesktop_x!App');",
        )
        .unwrap();
        let now = (Utc::now().timestamp_millis() + 11_644_473_600_000) * 10_000;
        let add = |id: i64, handler: i64, kind: &str| {
            db.execute(
                "INSERT INTO Notification VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![id, handler, kind, DISCORD_TOAST.as_bytes(), now],
            )
            .unwrap();
        };
        add(1, 1, "toast");
        add(2, 1, "badge");
        add(3, 2, "toast");
        let bridge = SystemNoticeBridge::new(path.clone(), Arc::new(|app: &str| app == "whatsapp"));
        let first = bridge.read().await.unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].app, "discord");
        assert!(bridge.read().await.unwrap().is_empty(), "a toast is read once");
        add(4, 1, "toast");
        assert_eq!(bridge.read().await.unwrap()[0].messages[0].id, "toast-4");
        drop(db);
        let _ = std::fs::remove_dir_all(dir);
    }
}
