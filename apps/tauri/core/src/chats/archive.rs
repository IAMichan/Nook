//! Every chat message Nook has seen, from every app, in one SQLite file (`chats.sqlite`, `ChatStore` on the Mac): the
//! one place the Chats tab, scrolling back and search read from. The same tables as the Mac:
//!
//! - One row per message, its text stored once. Only the fields most messages lack (a file, ticks, reactions, an edit
//!   or deletion mark) go into a small JSON blob with short keys, and only when there is one.
//! - Paging by key, never by offset: `message_page (chat, at)` answers "the 50 before this one" with one index lookup.
//! - A contentless trigram index (`message_search`) finds any piece of text of three or more characters without a
//!   second copy of the text.
//! - Edits and deletions keep the text a message had (`message_version`).
//!
//! The inbox in memory ([`ChatInbox`]) holds each chat's newest messages; this holds all of them. A chat whose app
//! keeps its messages (`ephemeral`, WhatsApp through its gateway) is written without them, as it goes to
//! `chat-inbox.json`. The value shapes in the blobs are this port's own, so a file is not moved between a Mac and a PC.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use super::inbox::{fold, InboxReaction};
use super::{ChatInbox, ChatMedia, InboxMessage, InboxThread, Receipt};

pub const FILE_NAME: &str = "chats.sqlite";

const MIGRATIONS: [&str; 2] = [
    "CREATE TABLE IF NOT EXISTS chat (
        id INTEGER PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        app TEXT NOT NULL,
        shown INTEGER NOT NULL DEFAULT 1,
        complete INTEGER NOT NULL DEFAULT 0,
        meta BLOB
    );
    CREATE TABLE IF NOT EXISTS message (
        id INTEGER PRIMARY KEY,
        chat INTEGER NOT NULL,
        ext TEXT NOT NULL,
        at REAL NOT NULL,
        mine INTEGER,
        sender TEXT,
        text TEXT,
        extra BLOB,
        UNIQUE (chat, ext)
    );
    CREATE INDEX IF NOT EXISTS message_page ON message (chat);
    CREATE TABLE IF NOT EXISTS message_version (
        message INTEGER NOT NULL,
        at REAL NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS message_version_of ON message_version (message);
    CREATE TABLE IF NOT EXISTS state (
        key TEXT PRIMARY KEY,
        value BLOB
    ) WITHOUT ROWID;",
    "DROP INDEX IF EXISTS message_page;
    CREATE INDEX message_page ON message (chat, at);",
];

/// Seconds between 1970 and 2001: `at` counts from 2001, as on the Mac.
const REFERENCE: f64 = 978_307_200.0;

fn at(date: DateTime<Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0 - REFERENCE
}

fn date(at: f64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt(((at + REFERENCE) * 1000.0).round() as i64).single().unwrap_or_default()
}

/// What a message keeps beyond the columns, with the Mac's short keys.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
struct Extra {
    #[serde(rename = "f", default, skip_serializing_if = "ChatMedia::is_none")]
    media: ChatMedia,
    #[serde(rename = "r", default, skip_serializing_if = "Option::is_none")]
    receipt: Option<Receipt>,
    #[serde(rename = "e", default, skip_serializing_if = "Vec::is_empty")]
    reactions: Vec<InboxReaction>,
    #[serde(rename = "m", default, skip_serializing_if = "std::ops::Not::not")]
    mentions_me: bool,
    #[serde(rename = "s", default, skip_serializing_if = "Option::is_none")]
    sender_id: Option<String>,
    #[serde(rename = "d", default, skip_serializing_if = "std::ops::Not::not")]
    edited: bool,
    #[serde(rename = "x", default, skip_serializing_if = "std::ops::Not::not")]
    deleted: bool,
}

impl Extra {
    fn of(m: &InboxMessage) -> Self {
        Self {
            media: m.media.clone(),
            receipt: m.receipt,
            reactions: m.reactions.clone(),
            mentions_me: m.mentions_me,
            sender_id: m.sender_id.clone(),
            edited: m.edited,
            deleted: m.deleted,
        }
    }

    fn apply(self, m: &mut InboxMessage) {
        m.media = self.media;
        m.receipt = self.receipt;
        m.reactions = self.reactions;
        m.mentions_me = self.mentions_me;
        m.sender_id = self.sender_id;
        m.edited = self.edited;
        m.deleted = self.deleted;
    }
}

/// One earlier text of a message, with when it was replaced.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatVersion {
    pub replaced: DateTime<Utc>,
    pub text: String,
}

/// One search hit: the chat (as written) and its matching messages, oldest first.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub thread: InboxThread,
    pub messages: Vec<InboxMessage>,
}

/// The archive. Not shared between threads by itself: one connection, behind the inbox store's lock.
pub struct ChatStore {
    db: Connection,
    search_available: bool,
}

const COLUMNS: &str = "m.id, m.ext, m.at, m.mine, m.sender, m.text, m.extra";

/// A message's row id: its second times 16, plus a slot, so rows sort by time on their own and the newest search hits
/// come straight out of the index. Two messages of one second take the next free id.
pub fn row_id(date: DateTime<Utc>, slot: i64) -> i64 {
    let seconds = at(date).floor().clamp(-100_000_000_000.0, 100_000_000_000.0) as i64;
    seconds * SLOTS + slot
}

const SLOTS: i64 = 16;
const MAX_SPILL: i64 = 256;
/// At most this many index rows are looked at per word.
const SEARCH_BUDGET: usize = 20_000;

/// FNV-1a, the same on every launch.
pub fn hash(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// What the search index holds for a message: its text and who wrote it, folded the way search compares.
pub fn search_body(m: &InboxMessage) -> String {
    fold(&format!("{} {}", m.text, m.sender))
}

/// A change of its text that its app calls an edit, or a deletion that took someone else's text away: the text it had
/// is kept. Your own deleted message keeps nothing of what it said.
pub fn is_edit(old: &InboxMessage, new: &InboxMessage) -> bool {
    if old.text.is_empty() || old.text == new.text || old.deleted {
        return false;
    }
    if new.deleted {
        !old.from_me
    } else {
        new.edited
    }
}

/// What a read says of a message the archive may hold already, over what it holds: a deleted one stays deleted, an
/// edit brings the new text and the mark, a read that brings less keeps what was there.
pub fn merged(old: &InboxMessage, new: &InboxMessage) -> InboxMessage {
    if old.deleted {
        return old.clone();
    }
    if new.deleted {
        return old.withdrawn();
    }
    let mut m = old.clone();
    if new.edited {
        m.edited = true;
    }
    if !new.text.is_empty() {
        m.text = new.text.clone();
    }
    if !new.sender.is_empty() {
        m.sender = new.sender.clone();
    }
    if new.sender_id.is_some() {
        m.sender_id = new.sender_id.clone();
    }
    if !new.media.is_none() {
        m.media = new.media.clone();
    }
    if let Some(r) = new.receipt {
        m.receipt = Some(old.receipt.map_or(r, |o| o.advanced(r)));
    }
    if new.mentions_me {
        m.mentions_me = true;
    }
    if !new.reactions.is_empty() {
        m.reactions = new.reactions.clone();
    }
    m
}

/// The messages that went from within a chat's window, not off its old end: those before the oldest one it still
/// shows stay; any newer than its new first message, or after one it still shows, went.
pub fn removed_from_window(before: &[InboxMessage], now: &[InboxMessage], first: DateTime<Utc>) -> Vec<String> {
    let kept: HashSet<&str> = now.iter().map(|m| m.id.as_str()).collect();
    let first_kept = before.iter().position(|m| kept.contains(m.id.as_str()));
    before
        .iter()
        .enumerate()
        .filter(|(i, m)| !kept.contains(m.id.as_str()) && (m.date > first || first_kept.is_some_and(|f| *i > f)))
        .map(|(_, m)| m.id.clone())
        .collect()
}

fn description(thread: Option<&InboxThread>) -> Option<InboxThread> {
    thread.map(|t| InboxThread { messages: vec![], ..t.clone() })
}

fn inbox_state(inbox: &ChatInbox) -> ChatInbox {
    ChatInbox { threads: HashMap::new(), ..inbox.clone() }
}

type Hit = (i64, i64, InboxMessage);

impl ChatStore {
    /// Opens (or creates) the archive. A file that cannot be opened or set up gives `None`: the inbox then goes to
    /// `chat-inbox.json` as before.
    pub fn open(path: &Path) -> Option<Self> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let db = Connection::open(path).ok()?;
        crate::paths::restrict(path, 0o600);
        db.busy_timeout(std::time::Duration::from_secs(5)).ok()?;
        // Before the first table, or it has no effect.
        db.execute_batch(
            "PRAGMA temp_store = MEMORY; PRAGMA cache_size = -4000; PRAGMA auto_vacuum = INCREMENTAL;
             PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA journal_size_limit = 8388608;",
        )
        .ok()?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0)).ok()?;
        let version = version.max(0) as usize;
        for (index, sql) in MIGRATIONS.iter().enumerate().skip(version) {
            db.execute_batch(&format!("BEGIN; {sql} PRAGMA user_version = {}; COMMIT;", index + 1)).ok()?;
        }
        let schema = |contentless: bool| {
            format!(
                "CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(body, tokenize = 'trigram', detail = none{});",
                if contentless { ", content = '', contentless_delete = 1" } else { "" }
            )
        };
        let search_available = db.execute_batch(&schema(true)).is_ok() || db.execute_batch(&schema(false)).is_ok();
        Some(Self { db, search_available })
    }

    pub fn search_available(&self) -> bool {
        self.search_available
    }

    fn message(row: &rusqlite::Row<'_>, first: usize) -> rusqlite::Result<InboxMessage> {
        let mut m = InboxMessage::new(
            row.get::<_, String>(first + 1)?,
            row.get::<_, Option<String>>(first + 5)?.unwrap_or_default(),
            date(row.get(first + 2)?),
            row.get::<_, Option<i64>>(first + 3)?.unwrap_or(0) != 0,
        );
        m.sender = row.get::<_, Option<String>>(first + 4)?.unwrap_or_default();
        if let Some(extra) = row.get::<_, Option<Vec<u8>>>(first + 6)?.and_then(|d| serde_json::from_slice::<Extra>(&d).ok()) {
            extra.apply(&mut m);
        }
        Ok(m)
    }

    /// The id of the chat row for `thread`, made when it is not there; its description (`meta`) is written too.
    pub fn save_chat(&self, thread: &InboxThread) -> Option<i64> {
        let meta = serde_json::to_vec(&description(Some(thread))?).ok()?;
        self.db
            .query_row(
                "INSERT INTO chat (key, app, shown, meta) VALUES (?1, ?2, 1, ?3)
                 ON CONFLICT (key) DO UPDATE SET app = excluded.app, shown = 1, meta = excluded.meta RETURNING id",
                params![thread.id, thread.app, meta],
                |r| r.get(0),
            )
            .ok()
    }

    pub fn chat_id(&self, key: &str) -> Option<i64> {
        self.db.query_row("SELECT id FROM chat WHERE key = ?1", [key], |r| r.get(0)).optional().ok().flatten()
    }

    /// Writes a message of a chat, over the one with its id. `reindex` false leaves the search index as it is.
    pub fn save_message(&self, m: &InboxMessage, chat: i64, reindex: bool) -> bool {
        let extra = Extra::of(m);
        let extra = (extra != Extra::default()).then(|| serde_json::to_vec(&extra).ok()).flatten();
        let first = row_id(m.date, (hash(&m.id) % SLOTS as u64) as i64);
        let mut id = None;
        for attempt in 0..=MAX_SPILL {
            let row = if attempt == MAX_SPILL { None } else { Some(first + attempt) };
            let result = self.db.query_row(
                "INSERT INTO message (id, chat, ext, at, mine, sender, text, extra) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT (chat, ext) DO UPDATE SET at = excluded.at, mine = excluded.mine, sender = excluded.sender,
                     text = excluded.text, extra = excluded.extra
                 RETURNING id",
                params![row, chat, m.id, at(m.date), m.from_me as i64, m.sender, m.text, extra],
                |r| r.get::<_, i64>(0),
            );
            match result {
                Ok(row) => {
                    id = Some(row);
                    break;
                }
                // The id is taken by another message of the same second: the next one.
                Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => continue,
                Err(_) => return false,
            }
        }
        let Some(id) = id else { return false };
        if !reindex || !self.search_available {
            return true;
        }
        self.index(id, &search_body(m))
    }

    fn index(&self, id: i64, body: &str) -> bool {
        if self.db.execute("DELETE FROM message_search WHERE rowid = ?1", [id]).is_err() {
            return false;
        }
        body.is_empty() || self.db.execute("INSERT INTO message_search (rowid, body) VALUES (?1, ?2)", params![id, body]).is_ok()
    }

    /// The message stored under its id in the app, in a chat.
    pub fn stored(&self, id: &str, chat: i64) -> Option<(i64, InboxMessage)> {
        self.db
            .query_row(&format!("SELECT {COLUMNS} FROM message m WHERE m.chat = ?1 AND m.ext = ?2"), params![chat, id], |r| {
                Ok((r.get(0)?, Self::message(r, 0)?))
            })
            .optional()
            .ok()
            .flatten()
    }

    fn keep_version(&self, old: &InboxMessage, chat: i64, now: DateTime<Utc>) -> bool {
        let Some((row, _)) = self.stored(&old.id, chat) else { return true };
        self.db
            .execute("INSERT INTO message_version (message, at, text) VALUES (?1, ?2, ?3)", params![row, at(now).floor(), old.text])
            .is_ok()
    }

    /// The texts a message had before it was edited (or deleted), oldest first.
    pub fn versions(&self, id: &str, key: &str) -> Vec<ChatVersion> {
        let Some(chat) = self.chat_id(key) else { return vec![] };
        let Some((row, _)) = self.stored(id, chat) else { return vec![] };
        let Ok(mut stmt) = self.db.prepare("SELECT at, text FROM message_version WHERE message = ?1 ORDER BY rowid") else {
            return vec![];
        };
        stmt.query_map([row], |r| Ok(ChatVersion { replaced: date(r.get(0)?), text: r.get(1)? }))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    /// Writes what a read brought of a message outside what the inbox shows: new, it is kept as it came; known, the two
    /// are put together, keeping the text an edit or deletion replaced.
    pub fn save_merged(&self, incoming: &InboxMessage, chat: i64) -> bool {
        let Some((_, known)) = self.stored(&incoming.id, chat) else {
            let m = if incoming.deleted { incoming.withdrawn() } else { incoming.clone() };
            return self.save_message(&m, chat, true);
        };
        let next = merged(&known, incoming);
        if next == known {
            return true;
        }
        if is_edit(&known, &next) && !self.keep_version(&known, chat, Utc::now()) {
            return false;
        }
        self.save_message(&next, chat, search_body(&next) != search_body(&known))
    }

    fn transaction(&self, body: impl FnOnce() -> bool) -> bool {
        if self.db.execute_batch("BEGIN IMMEDIATE;").is_err() {
            return false;
        }
        if body() && self.db.execute_batch("COMMIT;").is_ok() {
            return true;
        }
        let _ = self.db.execute_batch("ROLLBACK;");
        false
    }

    fn set_state(&self, key: &str, value: &[u8]) -> bool {
        self.db
            .execute("INSERT INTO state (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value", params![key, value])
            .is_ok()
    }

    fn state(&self, key: &str) -> Option<Vec<u8>> {
        self.db.query_row("SELECT value FROM state WHERE key = ?1", [key], |r| r.get(0)).optional().ok().flatten()
    }

    /// Writes what changed between two states of the inbox, in one transaction. A message that left a chat's window
    /// because it got older stays here; one that went from within the window goes. A chat that left the inbox stays
    /// for search unless you removed it.
    pub fn apply(&self, old: Option<&ChatInbox>, new: &ChatInbox) -> bool {
        self.transaction(|| {
            let state = inbox_state(new);
            if old.map(inbox_state).as_ref() != Some(&state) {
                let Ok(data) = serde_json::to_vec(&state) else { return false };
                if !self.set_state("inbox", &data) {
                    return false;
                }
            }
            for (key, thread) in &new.threads {
                let before = old.and_then(|o| o.threads.get(key));
                if before == Some(thread) {
                    continue;
                }
                let chat = if description(before) == description(Some(thread)) {
                    self.chat_id(key).or_else(|| self.save_chat(thread))
                } else {
                    self.save_chat(thread)
                };
                let Some(chat) = chat else { return false };
                let known: HashMap<&str, &InboxMessage> =
                    before.map(|b| b.messages.iter().map(|m| (m.id.as_str(), m)).collect()).unwrap_or_default();
                for m in &thread.messages {
                    let was = known.get(m.id.as_str()).copied();
                    if was == Some(m) {
                        continue;
                    }
                    if let Some(was) = was {
                        if is_edit(was, m) && !self.keep_version(was, chat, Utc::now()) {
                            return false;
                        }
                    }
                    let reindex = was.is_none_or(|w| search_body(w) != search_body(m));
                    if !self.save_message(m, chat, reindex) {
                        return false;
                    }
                }
                if let (Some(before), Some(first)) = (before, thread.messages.first()) {
                    if !self.delete_messages(&removed_from_window(&before.messages, &thread.messages, first.date), chat) {
                        return false;
                    }
                }
            }
            if old.is_none() && !self.settle_left(new) {
                return false;
            }
            let Some(old) = old else { return true };
            let everywhere: HashSet<&str> = new.threads.values().flat_map(|t| t.messages.iter().map(|m| m.id.as_str())).collect();
            for key in old.threads.keys().filter(|k| !new.threads.contains_key(*k)) {
                if new.removed.get(key).is_some_and(|r| old.removed.get(key) != Some(r)) {
                    if !self.delete_chat(key) {
                        return false;
                    }
                    continue;
                }
                self.hide_chat(key);
                // Its messages that now show in another chat (a group took back what its notifications put here).
                if let Some(chat) = self.chat_id(key) {
                    let moved: Vec<String> =
                        old.threads[key].messages.iter().map(|m| m.id.clone()).filter(|id| everywhere.contains(id.as_str())).collect();
                    if !self.delete_messages(&moved, chat) {
                        return false;
                    }
                }
            }
            true
        })
    }

    fn settle_left(&self, inbox: &ChatInbox) -> bool {
        let keys: Vec<String> = match self.db.prepare("SELECT key FROM chat WHERE shown = 1") {
            Ok(mut stmt) => stmt.query_map([], |r| r.get(0)).map(|rows| rows.flatten().collect()).unwrap_or_default(),
            Err(_) => return false,
        };
        for key in keys.iter().filter(|k| !inbox.threads.contains_key(*k)) {
            if inbox.removed.contains_key(key) {
                if !self.delete_chat(key) {
                    return false;
                }
            } else {
                self.hide_chat(key);
            }
        }
        true
    }

    pub fn delete_messages(&self, ids: &[String], chat: i64) -> bool {
        for id in ids {
            let Some((row, _)) = self.stored(id, chat) else { continue };
            if self.search_available && self.db.execute("DELETE FROM message_search WHERE rowid = ?1", [row]).is_err() {
                return false;
            }
            if self.db.execute("DELETE FROM message_version WHERE message = ?1", [row]).is_err()
                || self.db.execute("DELETE FROM message WHERE id = ?1", [row]).is_err()
            {
                return false;
            }
        }
        true
    }

    /// Marks these messages deleted for everyone, keeping someone else's text as an earlier version.
    pub fn withdraw(&self, ids: &[String], chat: i64) -> bool {
        ids.iter().all(|id| match self.stored(id, chat) {
            Some((_, known)) => {
                let mut gone = known.clone();
                gone.deleted = true;
                self.save_merged(&gone, chat)
            }
            None => true,
        })
    }

    /// Removes a chat and all it held.
    pub fn delete_chat(&self, key: &str) -> bool {
        let Some(chat) = self.chat_id(key) else { return true };
        let rows: Vec<i64> = match self.db.prepare("SELECT id FROM message WHERE chat = ?1") {
            Ok(mut stmt) => stmt.query_map([chat], |r| r.get(0)).map(|rows| rows.flatten().collect()).unwrap_or_default(),
            Err(_) => return false,
        };
        for row in rows {
            if self.search_available && self.db.execute("DELETE FROM message_search WHERE rowid = ?1", [row]).is_err() {
                return false;
            }
            let _ = self.db.execute("DELETE FROM message_version WHERE message = ?1", [row]);
        }
        self.db.execute("DELETE FROM message WHERE chat = ?1", [chat]).is_ok() && self.db.execute("DELETE FROM chat WHERE id = ?1", [chat]).is_ok()
    }

    /// A chat that left the inbox stays for search, out of the list.
    pub fn hide_chat(&self, key: &str) {
        let _ = self.db.execute("UPDATE chat SET shown = 0 WHERE key = ?1", [key]);
    }

    /// Every message of the history was read in (scrolling back reached the start).
    pub fn mark_complete(&self, key: &str, complete: bool) {
        let _ = self.db.execute("UPDATE chat SET complete = ?2 WHERE key = ?1", params![key, complete as i64]);
    }

    pub fn is_complete(&self, key: &str) -> bool {
        self.db.query_row("SELECT complete FROM chat WHERE key = ?1", [key], |r| r.get::<_, i64>(0)).is_ok_and(|c| c == 1)
    }

    fn newest(&self, chat: i64, limit: usize) -> Vec<InboxMessage> {
        let sql = format!("SELECT {COLUMNS} FROM message m WHERE m.chat = ?1 ORDER BY m.at DESC, m.id DESC LIMIT ?2");
        let mut list: Vec<InboxMessage> = match self.db.prepare(&sql) {
            Ok(mut stmt) => stmt
                .query_map(params![chat, limit as i64], |r| Self::message(r, 0))
                .map(|rows| rows.flatten().collect())
                .unwrap_or_default(),
            Err(_) => vec![],
        };
        list.reverse();
        list
    }

    /// The inbox as it was written: every chat it shows with its newest `window` messages. `None` when nothing was
    /// ever written.
    pub fn load_inbox(&self, window: usize) -> Option<ChatInbox> {
        let mut inbox: ChatInbox = serde_json::from_slice(&self.state("inbox")?).ok()?;
        inbox.threads.clear();
        let rows: Vec<(i64, String, Vec<u8>)> = {
            let mut stmt = self.db.prepare("SELECT id, key, meta FROM chat WHERE shown = 1").ok()?;
            let rows: Vec<(i64, String, Vec<u8>)> =
                stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).ok()?.flatten().collect();
            rows
        };
        for (id, key, meta) in rows {
            let Ok(mut thread) = serde_json::from_slice::<InboxThread>(&meta) else { continue };
            thread.id = key.clone();
            // Everything older is here: scrolling back reads it again.
            thread.capacity = None;
            thread.messages = self.newest(id, window);
            inbox.threads.insert(key, thread);
        }
        Some(inbox)
    }

    /// The `limit` messages of a chat before `date` (and those at `date` not in `excluding`), oldest first.
    pub fn older(&self, key: &str, before: DateTime<Utc>, excluding: &HashSet<String>, limit: usize) -> Vec<InboxMessage> {
        let Some(chat) = self.chat_id(key) else { return vec![] };
        let sql = format!("SELECT {COLUMNS} FROM message m WHERE m.chat = ?1 AND m.at <= ?2 ORDER BY m.at DESC, m.id DESC LIMIT ?3");
        let mut list: Vec<InboxMessage> = match self.db.prepare(&sql) {
            Ok(mut stmt) => stmt
                .query_map(params![chat, at(before), (limit + excluding.len()) as i64], |r| Self::message(r, 0))
                .map(|rows| rows.flatten().filter(|m| !excluding.contains(&m.id)).take(limit).collect())
                .unwrap_or_default(),
            Err(_) => vec![],
        };
        list.reverse();
        list
    }

    /// The oldest message stored for a chat: where scrolling back to the app goes on from.
    pub fn oldest(&self, key: &str) -> Option<InboxMessage> {
        let chat = self.chat_id(key)?;
        self.db
            .query_row(&format!("SELECT {COLUMNS} FROM message m WHERE m.chat = ?1 ORDER BY m.at ASC, m.id ASC LIMIT 1"), [chat], |r| {
                Self::message(r, 0)
            })
            .optional()
            .ok()
            .flatten()
    }

    pub fn message_count(&self, key: Option<&str>) -> usize {
        let count: rusqlite::Result<i64> = match key {
            Some(key) => self.db.query_row(
                "SELECT COUNT(*) FROM message WHERE chat = (SELECT id FROM chat WHERE key = ?1)",
                [key],
                |r| r.get(0),
            ),
            None => self.db.query_row("SELECT COUNT(*) FROM message", [], |r| r.get(0)),
        };
        count.unwrap_or(0) as usize
    }

    /// The messages that hold any of `words` (folded), the newest `limit` per word, grouped by chat. Words of three
    /// characters or more go through the trigram index, newest first; shorter ones scan from the newest back.
    pub fn search(&self, words: &[String], limit: usize) -> Vec<Found> {
        let mut by_chat: HashMap<i64, Vec<InboxMessage>> = HashMap::new();
        let mut seen = HashSet::new();
        for word in words.iter().filter(|w| !w.is_empty()) {
            let hits = if self.search_available && word.chars().count() >= 3 { self.indexed(word, limit) } else { self.scanned(word, limit) };
            for (row, chat, m) in hits {
                if seen.insert(row) {
                    by_chat.entry(chat).or_default().push(m);
                }
            }
        }
        by_chat
            .into_iter()
            .filter_map(|(chat, mut messages)| {
                let thread = self.described_thread(chat)?;
                messages.sort_by_key(|m| m.date);
                Some(Found { thread, messages })
            })
            .collect()
    }

    fn matches(m: &InboxMessage, word: &str) -> bool {
        search_body(m).contains(word)
    }

    fn indexed(&self, word: &str, limit: usize) -> Vec<Hit> {
        // Every trigram of the word, each as a term of its own: the index keeps no positions.
        let chars: Vec<char> = word.chars().collect();
        let grams: HashSet<String> = (0..=chars.len() - 3).map(|i| chars[i..i + 3].iter().collect()).collect();
        let query = grams.iter().map(|g| format!("\"{}\"", g.replace('"', "\"\""))).collect::<Vec<_>>().join(" AND ");
        let Ok(mut stmt) =
            self.db.prepare("SELECT rowid FROM message_search WHERE message_search MATCH ?1 AND rowid < ?2 ORDER BY rowid DESC LIMIT ?3")
        else {
            return vec![];
        };
        let batch = (limit * 4).max(200);
        let mut hits = vec![];
        let mut below = i64::MAX;
        let mut looked = 0;
        while hits.len() < limit && looked < SEARCH_BUDGET {
            let rows: Vec<i64> = stmt
                .query_map(params![query, below, batch as i64], |r| r.get(0))
                .map(|rows| rows.flatten().collect())
                .unwrap_or_default();
            looked += rows.len();
            for row in &rows {
                if hits.len() >= limit {
                    break;
                }
                if let Some(hit) = self.message_row(*row).filter(|h| Self::matches(&h.2, word)) {
                    hits.push(hit);
                }
            }
            match rows.last() {
                Some(last) if rows.len() == batch => below = *last,
                _ => break,
            }
        }
        hits
    }

    fn scanned(&self, word: &str, limit: usize) -> Vec<Hit> {
        let Ok(mut stmt) = self.db.prepare(&format!("SELECT m.chat, {COLUMNS} FROM message m ORDER BY m.id DESC")) else {
            return vec![];
        };
        let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, i64>(1)?, r.get::<_, i64>(0)?, Self::message(r, 1)?))) else {
            return vec![];
        };
        rows.flatten().take(SEARCH_BUDGET * 10).filter(|h| Self::matches(&h.2, word)).take(limit).collect()
    }

    fn message_row(&self, row: i64) -> Option<Hit> {
        self.db
            .query_row(&format!("SELECT m.chat, {COLUMNS} FROM message m WHERE m.id = ?1"), [row], |r| {
                Ok((row, r.get::<_, i64>(0)?, Self::message(r, 1)?))
            })
            .optional()
            .ok()
            .flatten()
    }

    fn described_thread(&self, chat: i64) -> Option<InboxThread> {
        let (key, meta): (String, Vec<u8>) =
            self.db.query_row("SELECT key, meta FROM chat WHERE id = ?1", [chat], |r| Ok((r.get(0)?, r.get(1)?))).ok()?;
        let mut thread: InboxThread = serde_json::from_slice(&meta).ok()?;
        thread.id = key;
        Some(thread)
    }

    /// While Nook is idle: gives free pages back once they are a tenth of the file, merges the search index a little,
    /// refreshes what SQLite knows of the tables, and empties the write-ahead log.
    pub fn maintain(&self) {
        let free: i64 = self.db.query_row("PRAGMA freelist_count", [], |r| r.get(0)).unwrap_or(0);
        let pages: i64 = self.db.query_row("PRAGMA page_count", [], |r| r.get(0)).unwrap_or(0);
        if pages > 0 && free * 10 > pages {
            let _ = self.db.execute_batch("PRAGMA incremental_vacuum;");
        }
        if self.search_available {
            let _ = self.db.execute_batch("INSERT INTO message_search (message_search, rank) VALUES ('merge', 64);");
        }
        let _ = self.db.execute_batch("PRAGMA optimize; PRAGMA wal_checkpoint(TRUNCATE);");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::BridgedChat;
    use chrono::Duration;

    fn t(min: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 17, 12, 0, 0).unwrap() + Duration::minutes(min)
    }

    fn msg(id: &str, text: &str, min: i64, mine: bool) -> InboxMessage {
        InboxMessage::new(id, text, t(min), mine)
    }

    fn store() -> (ChatStore, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("nook-archive-{}", uuid::Uuid::new_v4()));
        let store = ChatStore::open(&dir.join(FILE_NAME)).unwrap();
        (store, dir)
    }

    fn chat(id: &str, messages: Vec<InboxMessage>) -> BridgedChat {
        BridgedChat { app: "telegram".into(), name: format!("Chat {id}"), chat_id: Some(id.into()), messages, ..Default::default() }
    }

    #[test]
    fn writes_the_inbox_and_reads_it_back_with_its_window() {
        let (store, dir) = store();
        assert!(store.search_available(), "the trigram index is there");
        let mut inbox = ChatInbox::default();
        let many: Vec<InboxMessage> = (0..80).map(|i| msg(&i.to_string(), &format!("bericht {i}"), i, i % 2 == 0)).collect();
        inbox.merge(chat("a", many), t(90));
        inbox.mark_read(&ChatInbox::key("telegram", "a"), t(91));
        assert!(store.apply(None, &inbox));
        let back = store.load_inbox(ChatInbox::KEEP).unwrap();
        let key = ChatInbox::key("telegram", "a");
        assert_eq!(back.threads[&key].messages, inbox.threads[&key].messages);
        assert_eq!(back.threads[&key].read_in_nook, inbox.threads[&key].read_in_nook);
        // Older than the window: from the archive (only the 50 newest were in the inbox).
        let before = back.threads[&key].messages[0].date;
        let older = store.older(&key, before, &HashSet::from([back.threads[&key].messages[0].id.clone()]), 10);
        assert!(older.is_empty(), "the inbox only ever held its newest 50");
        assert_eq!(store.message_count(Some(&key)), 50);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn keeps_what_leaves_the_window_and_scrolls_back_by_key() {
        let (store, dir) = store();
        let key = ChatInbox::key("telegram", "a");
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("a", (0..50).map(|i| msg(&i.to_string(), "x", i, false)).collect()), t(60));
        assert!(store.apply(None, &inbox));
        let old = inbox.clone();
        inbox.merge(chat("a", (50..60).map(|i| msg(&i.to_string(), "y", i, false)).collect()), t(70));
        assert!(store.apply(Some(&old), &inbox));
        assert_eq!(store.message_count(Some(&key)), 60, "trimmed off the old end, still in the archive");
        let first = inbox.threads[&key].messages[0].date;
        let page = store.older(&key, first, &HashSet::from([inbox.threads[&key].messages[0].id.clone()]), 5);
        assert_eq!(page.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), vec!["5", "6", "7", "8", "9"]);
        assert_eq!(store.oldest(&key).map(|m| m.id), Some("0".into()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn edits_and_deletions_keep_the_earlier_text() {
        let (store, dir) = store();
        let key = ChatInbox::key("telegram", "a");
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("a", vec![msg("1", "first words", 0, false), msg("2", "mine", 1, true)]), t(2));
        store.apply(None, &inbox);
        let old = inbox.clone();
        let mut edited = msg("1", "second words", 0, false);
        edited.edited = true;
        let mut c = chat("a", vec![edited]);
        c.deleted = vec!["2".into()];
        inbox.merge(c, t(3));
        assert!(store.apply(Some(&old), &inbox));
        let versions = store.versions("1", &key);
        assert_eq!(versions.iter().map(|v| v.text.as_str()).collect::<Vec<_>>(), vec!["first words"]);
        assert!(store.versions("2", &key).is_empty(), "your own deleted message keeps nothing of what it said");
        let chat_row = store.chat_id(&key).unwrap();
        assert!(store.stored("2", chat_row).unwrap().1.deleted);
        // Someone else's message deleted later keeps its text as a version.
        assert!(store.withdraw(&["1".into()], chat_row));
        assert_eq!(store.versions("1", &key).len(), 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn search_finds_pieces_of_words_newest_first() {
        let (store, dir) = store();
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("a", vec![msg("1", "De voetbalploeg wint", 0, false), msg("2", "Café om acht", 1, false)]), t(2));
        inbox.merge(chat("b", vec![msg("1", "geen ploeg vandaag", 3, false)]), t(4));
        store.apply(None, &inbox);
        let found = store.search(&["ploeg".into()], 10);
        assert_eq!(found.iter().map(|f| f.messages.len()).sum::<usize>(), 2);
        assert_eq!(store.search(&["cafe".into()], 10).len(), 1, "accents folded");
        assert_eq!(store.search(&["om".into()], 10).len(), 1, "short words scan");
        assert!(store.search(&["xyz".into()], 10).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn removed_chats_go_and_ephemeral_ones_stay_out() {
        let (store, dir) = store();
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("a", vec![msg("1", "hello", 0, false)]), t(1));
        store.apply(None, &inbox);
        let old = inbox.clone();
        inbox.remove(&ChatInbox::key("telegram", "a"), t(2));
        assert!(store.apply(Some(&old), &inbox));
        assert_eq!(store.message_count(None), 0);
        assert!(store.search(&["hello".into()], 5).is_empty(), "nothing of it left in the index");
        let mut wa = chat("w", vec![msg("1", "secret", 3, false)]);
        wa.ephemeral = true;
        let old = inbox.clone();
        inbox.merge(wa, t(3));
        assert!(store.apply(Some(&old.for_disk()), &inbox.for_disk()));
        assert_eq!(store.message_count(None), 0, "an app that keeps its messages has none here");
        let back = store.load_inbox(10).unwrap();
        assert!(back.threads.contains_key(&ChatInbox::key("telegram", "w")), "the chat itself is known");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn small_rules() {
        assert_eq!(row_id(t(0), 3) % SLOTS, 3);
        assert!(row_id(t(1), 0) > row_id(t(0), 15));
        assert_eq!(hash("a"), hash("a"));
        let before = vec![msg("1", "", 0, false), msg("2", "", 1, false), msg("3", "", 2, false)];
        let now = vec![msg("2", "", 1, false), msg("4", "", 3, false)];
        assert_eq!(removed_from_window(&before, &now, t(1)), vec!["3".to_string()]);
        assert_eq!(date(at(t(5))), t(5));
    }
}
