//! The shared inbox (`ChatInbox` in `apps/macos/Services/Messages/ChatInbox.swift`): every chat app's chats in one
//! place, with one set of rules for what is new, what is read and what is kept.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

use super::{ChatKind, ChatMedia, Receipt};

/// One message in a chat, the same for every app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxMessage {
    /// The app's own id for the message (unique within its chat).
    pub id: String,
    /// Who wrote it, by name; empty for your own and in a private chat when the chat itself is the person.
    #[serde(default)]
    pub sender: String,
    /// Who wrote it, by the app's id for them (a WhatsApp JID, a Slack user id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_id: Option<String>,
    pub text: String,
    pub date: DateTime<Utc>,
    #[serde(default)]
    pub from_me: bool,
    #[serde(default, skip_serializing_if = "ChatMedia::is_none")]
    pub media: ChatMedia,
    /// Your own message's ticks; `None` when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Receipt>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub mentions_me: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub edited: bool,
    /// Deleted for everyone: the row stays, without its words or file.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub deleted: bool,
}

impl InboxMessage {
    pub fn new(id: impl Into<String>, text: impl Into<String>, date: DateTime<Utc>, from_me: bool) -> Self {
        Self {
            id: id.into(),
            sender: String::new(),
            sender_id: None,
            text: text.into(),
            date,
            from_me,
            media: ChatMedia::None,
            receipt: None,
            mentions_me: false,
            edited: false,
            deleted: false,
        }
    }

    /// Someone else's message: what "unread" and "read" are about.
    pub fn is_incoming(&self) -> bool {
        !self.from_me
    }

    /// The message as it shows once deleted for everyone: no words, no file.
    pub fn withdrawn(&self) -> Self {
        let mut copy = self.clone();
        copy.text = String::new();
        copy.media = ChatMedia::None;
        copy.deleted = true;
        copy
    }
}

/// What one read of a chat app brought for one chat (`BridgedChat` on the Mac). Only `app`, `name` and `messages` are
/// required; every other field is what the app says when it says it, and `None` leaves what Nook knows as it is.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BridgedChat {
    pub app: String,
    pub name: String,
    pub messages: Vec<InboxMessage>,
    /// The app's own unread count; `None` lets Nook count the new messages from someone else.
    pub unread: Option<usize>,
    pub avatar: Option<String>,
    pub members: Option<Vec<String>>,
    /// The app lists this chat as one of yours (a chat list read): it stays, even when quiet.
    pub listed: bool,
    /// Messages deleted for everyone since the last read, by id.
    pub deleted: Vec<String>,
    /// The app's own id for the chat; chats with one are keyed by it, others by their name.
    pub chat_id: Option<String>,
    pub account: Option<String>,
    pub kind: Option<ChatKind>,
    /// The person's number or address, for a person's chat.
    pub handle: Option<String>,
    pub has_older: Option<bool>,
    /// Older messages fetched on request (opening a chat, scrolling back): never new.
    pub history: bool,
    /// When the app says the chat last had a message.
    pub activity: Option<DateTime<Utc>>,
    /// The app still holds the chat unread (its own read mark), when it says so.
    pub waits_in_app: Option<bool>,
    pub muted_in_app: Option<bool>,
    /// The app keeps the messages, Nook only shows them: they never reach the disk (`forDisk`).
    pub ephemeral: bool,
    /// A group you left or a chat deleted in the app: it goes, as one removed in Nook.
    pub gone: bool,
}

/// One chat in the inbox (`InboxThread` on the Mac).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxThread {
    pub id: String,
    pub app: String,
    pub name: String,
    #[serde(default)]
    pub messages: Vec<InboxMessage>,
    #[serde(default)]
    pub unread: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_unread: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub members: Option<Vec<String>>,
    /// When the app last listed this chat as one of yours.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listed: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_in_nook: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_in_app: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub marked_unread: Option<DateTime<Utc>>,
    /// Messages kept beyond [`ChatInbox::KEEP`] after scrolling back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capacity: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ChatKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_older: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waits_in_app: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub muted_in_app: Option<bool>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ephemeral: bool,
}

impl InboxThread {
    pub fn new(id: impl Into<String>, app: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            app: app.into(),
            name: name.into(),
            messages: vec![],
            unread: 0,
            app_unread: None,
            avatar: None,
            members: None,
            listed: None,
            read_in_nook: None,
            read_in_app: None,
            marked_unread: None,
            capacity: None,
            chat_id: None,
            account: None,
            kind: None,
            handle: None,
            has_older: None,
            activity: None,
            waits_in_app: None,
            muted_in_app: None,
            ephemeral: false,
        }
    }

    /// How many messages it keeps.
    pub fn keeps(&self) -> usize {
        self.capacity.unwrap_or(0).max(ChatInbox::KEEP)
    }

    /// When the chat last had a message: it sorts and is dated by this. A chat without messages here goes by when its
    /// app says it last had one.
    pub fn last(&self) -> DateTime<Utc> {
        self.messages.last().map(|m| m.date).or(self.activity).unwrap_or(DateTime::<Utc>::MIN_UTC)
    }

    /// The newest message from someone else: what "read" is about.
    pub fn newest_incoming(&self) -> Option<DateTime<Utc>> {
        self.messages.iter().rev().find(|m| m.is_incoming()).map(|m| m.date)
    }

    /// What its app says, else a group when someone other than the chat wrote in it or more than one person is in it.
    pub fn is_group(&self) -> bool {
        if let Some(kind) = self.kind {
            return kind == ChatKind::Group;
        }
        self.members.as_ref().map_or(0, Vec::len) > 1 || self.messages.iter().any(|m| !m.from_me && !m.sender.is_empty())
    }

    /// The kind the notice rules go by.
    pub fn notice_kind(&self) -> ChatKind {
        self.kind.unwrap_or(if self.is_group() { ChatKind::Group } else { ChatKind::Person })
    }

    /// Read here, read in Nook only, or read in the app too: the same three states for every chat app.
    pub fn read_state(&self) -> ChatReadState {
        ChatReadState::of(
            self.unread,
            self.app_unread,
            self.newest_incoming(),
            self.read_in_nook,
            self.read_in_app,
            self.waits_in_app,
        )
    }
}

/// Where a chat stands, the same for every app (`ChatReadState` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state", content = "count")]
pub enum ChatReadState {
    /// New messages here: how many.
    Unread(usize),
    /// Read in Nook, still unread in the app: the people who wrote do not see that you read it.
    ReadInNook,
    /// Read in the app too (or nothing new in it).
    Read,
}

impl ChatReadState {
    pub fn of(
        unread: usize,
        app_unread: Option<usize>,
        newest_incoming: Option<DateTime<Utc>>,
        read_in_nook: Option<DateTime<Utc>>,
        read_in_app: Option<DateTime<Utc>>,
        waits_in_app: Option<bool>,
    ) -> Self {
        if unread > 0 {
            return Self::Unread(unread);
        }
        if let Some(read) = read_in_app {
            if newest_incoming.is_none_or(|n| read >= n) {
                return Self::Read;
            }
        }
        if let Some(waits) = waits_in_app {
            return if waits { Self::ReadInNook } else { Self::Read };
        }
        let Some(newest) = newest_incoming else { return Self::Read };
        if let Some(app) = app_unread {
            return if app > 0 { Self::ReadInNook } else { Self::Read };
        }
        if read_in_nook.is_some_and(|r| r >= newest) {
            return Self::ReadInNook;
        }
        Self::Read
    }

    pub fn is_unread(self) -> bool {
        matches!(self, Self::Unread(_))
    }
}

/// Every chat app's chats (`ChatInbox` on the Mac). Keys: `app#id` for a chat its app knows by an id of its own,
/// `app|folded name` otherwise; the two never meet.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatInbox {
    #[serde(default)]
    pub threads: HashMap<String, InboxThread>,
    /// Chats you removed, and when: a bridge brings back only what is newer, not the history you threw away.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub removed: HashMap<String, DateTime<Utc>>,
}

impl ChatInbox {
    /// Messages kept per chat a bridge reads, until you scroll back (the app keeps the rest).
    pub const KEEP: usize = 50;
    /// Chats kept; the quietest go first.
    pub const MAX_THREADS: usize = 200;
    /// Two copies of one message (seconds): the same words from the same side this close together are one.
    pub const SAME_MESSAGE_WINDOW: i64 = 60;
    /// A chat that had nothing new for this long is dropped (days).
    pub const MAX_AGE_DAYS: i64 = 30;
    /// How often a listed chat's `listed` date is renewed (hours): not on every read.
    pub const LISTED_RENEWAL_HOURS: i64 = 24;

    fn max_age() -> Duration {
        Duration::days(Self::MAX_AGE_DAYS)
    }

    fn same_message_window() -> Duration {
        Duration::seconds(Self::SAME_MESSAGE_WINDOW)
    }

    /// The key of a chat its app knows by an id of its own: `whatsapp#31612345678@s.whatsapp.net`.
    pub fn key(app: &str, id: &str) -> String {
        format!("{app}#{id}")
    }

    /// The key of a chat known only by its name: folded (case, accents, width, invisible marks, runs of spaces), so one
    /// chat named a little differently by two reads stays one.
    pub fn key_by_name(app: &str, chat: &str) -> String {
        format!("{app}|{}", fold(chat))
    }

    /// The key of a chat as a bridge brings it: by its id when it has one, else by its name.
    pub fn key_of(chat: &BridgedChat) -> String {
        match &chat.chat_id {
            Some(id) => Self::key(&chat.app, id),
            None => Self::key_by_name(&chat.app, &chat.name),
        }
    }

    /// Brings in what a bridge read for one chat. With `chat.unread` the app's own count wins; without, a message from
    /// someone else newer than what the chat showed counts as unread, except on the first look at a chat (its history
    /// was likely read in the app already) and in history. False when nothing changed.
    pub fn merge(&mut self, chat: BridgedChat, now: DateTime<Utc>) -> bool {
        let changed = self.merge_one(chat, now);
        if changed {
            self.drop_quietest(now);
        }
        changed
    }

    /// Everything one read of a bridge brought, at once: the quietest chats beyond [`Self::MAX_THREADS`] go once at
    /// the end. True when anything changed.
    pub fn merge_all(&mut self, chats: Vec<BridgedChat>, now: DateTime<Utc>) -> bool {
        let mut changed = false;
        for chat in chats {
            changed |= self.merge_one(chat, now);
        }
        if changed {
            self.drop_quietest(now);
        }
        changed
    }

    fn merge_one(&mut self, chat: BridgedChat, now: DateTime<Utc>) -> bool {
        let key = Self::key_of(&chat);
        let known = self.threads.get(&key).cloned();
        if chat.gone {
            let Some(known) = known else { return false };
            let newest = chat.messages.iter().chain(known.messages.iter()).map(|m| m.date).chain(known.activity).max();
            self.remove(&key, now.max(newest.unwrap_or(now)));
            return true;
        }
        let gone = self.removed.get(&key).copied();
        let messages: Vec<InboxMessage> = match gone {
            Some(gone) => chat.messages.iter().filter(|m| m.date > gone).cloned().collect(),
            None => chat.messages.clone(),
        };
        let described = known.as_ref().is_some_and(|k| {
            chat.unread.is_some()
                || chat.members.is_some()
                || chat.listed
                || !chat.deleted.is_empty()
                || chat.avatar.as_ref().is_some_and(|a| Some(a) != k.avatar.as_ref())
                || chat.account.as_ref().is_some_and(|a| Some(a) != k.account.as_ref())
                || chat.kind.is_some_and(|c| Some(c) != k.kind)
                || chat.handle.as_ref().is_some_and(|h| Some(h) != k.handle.as_ref())
                || chat.has_older.is_some_and(|h| Some(h) != k.has_older)
                || (chat.chat_id.is_some() && chat.name != k.name)
                || chat.activity.is_some_and(|a| Some(a) != k.activity)
                || chat.waits_in_app.is_some_and(|w| Some(w) != k.waits_in_app)
                || chat.muted_in_app.is_some_and(|m| Some(m) != k.muted_in_app)
        });
        if messages.is_empty() && !described && !(known.is_none() && gone.is_none() && chat.listed) {
            return false;
        }
        let mut thread = known.clone().unwrap_or_else(|| InboxThread::new(&key, &chat.app, &chat.name));
        thread.chat_id = chat.chat_id.clone();
        let before = thread.clone();
        // What the chat had before, the app's own word on when it last moved included: a message no newer is no news.
        let newest_before = known.as_ref().map(|k| k.messages.last().map(|m| m.date).into_iter().chain(k.activity).max());
        let index_by_id: HashMap<String, usize> =
            thread.messages.iter().enumerate().rev().map(|(i, m)| (m.id.clone(), i)).collect();
        for message in &messages {
            let Some(&index) = index_by_id.get(&message.id) else { continue };
            let kept = &mut thread.messages[index];
            // Deleted for everyone stays deleted, whatever a later read still brings of it.
            if kept.deleted {
                continue;
            }
            if message.deleted {
                *kept = kept.withdrawn();
                continue;
            }
            if message.edited {
                kept.edited = true;
            }
            if !message.text.is_empty() && kept.text != message.text {
                kept.text = message.text.clone();
            }
            // A better name for who wrote it (the app learned it since).
            if !message.sender.is_empty() && kept.sender != message.sender {
                kept.sender = message.sender.clone();
            }
            if message.sender_id.is_some() && kept.sender_id != message.sender_id {
                kept.sender_id = message.sender_id.clone();
            }
            if !message.media.is_none() && kept.media != message.media {
                kept.media = message.media.clone();
            }
            if let Some(receipt) = message.receipt {
                kept.receipt = Some(kept.receipt.map_or(receipt, |k| k.advanced(receipt)));
            }
            if message.mentions_me {
                kept.mentions_me = true;
            }
        }
        if !chat.deleted.is_empty() {
            let gone: HashSet<&String> = chat.deleted.iter().collect();
            for m in thread.messages.iter_mut().filter(|m| gone.contains(&m.id) && !m.deleted) {
                *m = m.withdrawn();
            }
        }
        // You wrote in this chat, so what came before is read, in every app. A little before your message: a clock
        // behind yours must not hide an answer that came right after it.
        let answered = thread.messages.iter().chain(messages.iter()).filter(|m| m.from_me).map(|m| m.date).max()
            .map(|d| d - Self::same_message_window());
        let mut ids: HashSet<String> = thread.messages.iter().map(|m| m.id.clone()).collect();
        // A chat its app knows by an id gets every message under the app's own id: two "ok"s in a row are two.
        let by_id_only = chat.chat_id.is_some();
        for message in messages {
            if ids.contains(&message.id) {
                continue;
            }
            if !by_id_only
                && thread.messages.iter().any(|m| {
                    message.media.is_none()
                        && m.media.is_none()
                        && !message.deleted
                        && m.from_me == message.from_me
                        && m.text == message.text
                        && (m.date - message.date).abs() < Self::same_message_window()
                })
            {
                continue;
            }
            let index = thread.messages.iter().rposition(|m| m.date <= message.date).map_or(0, |i| i + 1);
            if chat.unread.is_none()
                && !chat.history
                && message.is_incoming()
                && !message.deleted
                && newest_before.is_some_and(|before| before.is_none_or(|b| message.date > b))
                && answered.is_none_or(|a| message.date > a)
            {
                thread.unread += 1;
            }
            ids.insert(message.id.clone());
            let message = if message.deleted { message.withdrawn() } else { message };
            thread.messages.insert(index, message);
        }
        let keeps = thread.keeps();
        if thread.messages.len() > keeps {
            let extra = thread.messages.len() - keeps;
            thread.messages.drain(..extra);
        }
        if let Some(activity) = chat.activity {
            if thread.activity.is_none_or(|a| activity > a) {
                thread.activity = Some(activity);
            }
        }
        if let Some(unread) = chat.unread {
            // Marked unread by hand stays so: your own message does not take that back.
            let read = [thread.read_in_nook, if thread.marked_unread.is_none() { answered } else { None }]
                .into_iter()
                .flatten()
                .max();
            if let Some(read) = read {
                // Read in Nook or answered: only what came in after that is new here, never more than the app counts.
                let fresh = thread.messages.iter().filter(|m| m.is_incoming() && m.date > read).count();
                thread.unread = if thread.messages.is_empty() {
                    if thread.activity.is_some_and(|a| a > read) { unread } else { 0 }
                } else {
                    unread.min(fresh)
                };
            } else if thread.marked_unread.is_some() {
                thread.unread = thread.unread.max(unread).max(1);
            } else if Some(unread) != thread.app_unread {
                thread.unread = unread;
            }
            thread.app_unread = Some(unread);
        }
        thread.name = chat.name;
        if chat.avatar.is_some() {
            thread.avatar = chat.avatar;
        }
        if chat.members.is_some() {
            thread.members = chat.members;
        }
        if chat.account.is_some() {
            thread.account = chat.account;
        }
        if chat.kind.is_some() {
            thread.kind = chat.kind;
        }
        if chat.handle.is_some() {
            thread.handle = chat.handle;
        }
        if chat.has_older.is_some() {
            thread.has_older = chat.has_older;
        }
        if chat.waits_in_app.is_some() {
            thread.waits_in_app = chat.waits_in_app;
        }
        if chat.muted_in_app.is_some() {
            thread.muted_in_app = chat.muted_in_app;
        }
        if chat.ephemeral {
            thread.ephemeral = true;
        }
        if chat.listed && thread.listed.is_none_or(|l| now - l >= Duration::hours(Self::LISTED_RENEWAL_HOURS)) {
            thread.listed = Some(now);
        }
        if thread == before && known.is_some() {
            return false;
        }
        self.threads.insert(key, thread);
        true
    }

    /// Your own message's ticks, from a receipt that names messages by id: they only move forward. True when any changed.
    pub fn apply_receipt(&mut self, key: &str, ids: &[String], receipt: Receipt) -> bool {
        let Some(thread) = self.threads.get_mut(key) else { return false };
        let wanted: HashSet<&String> = ids.iter().collect();
        let mut changed = false;
        for m in thread.messages.iter_mut().filter(|m| m.from_me && wanted.contains(&m.id)) {
            let next = Some(m.receipt.unwrap_or(Receipt::Sent).advanced(receipt));
            if next != m.receipt {
                m.receipt = next;
                changed = true;
            }
        }
        changed
    }

    /// Lets a chat keep `step` more messages than it has. Its new capacity; `None` when Nook has no such chat.
    pub fn grow(&mut self, key: &str, step: usize) -> Option<usize> {
        let thread = self.threads.get_mut(key)?;
        let capacity = thread.keeps().max(thread.messages.len()) + step;
        thread.capacity = Some(capacity);
        Some(capacity)
    }

    /// Read in Nook: the badge goes and stays gone after a restart. The app itself is not told.
    pub fn mark_read(&mut self, key: &str, date: DateTime<Utc>) {
        let Some(thread) = self.threads.get_mut(key) else { return };
        thread.unread = 0;
        // Never before what it read: a message dated by another clock would otherwise count as new again.
        thread.read_in_nook = [Some(date), thread.newest_incoming(), thread.activity].into_iter().flatten().max();
        thread.marked_unread = None;
    }

    /// Read in the app too: Nook told it. `through`: what the app was told, when telling it took a while; a message that
    /// came in meanwhile stays new. `None` reads everything there is now.
    pub fn mark_read_in_app(&mut self, key: &str, date: DateTime<Utc>, through: Option<DateTime<Utc>>) {
        let Some(through) = through else {
            self.mark_read(key, date);
            let Some(thread) = self.threads.get_mut(key) else { return };
            thread.read_in_app = thread.read_in_nook;
            if thread.app_unread.is_some() {
                thread.app_unread = Some(0);
            }
            if thread.waits_in_app == Some(true) {
                thread.waits_in_app = Some(false);
            }
            return;
        };
        let Some(thread) = self.threads.get_mut(key) else { return };
        let fresh = thread.messages.iter().filter(|m| m.is_incoming() && m.date > through).count();
        thread.unread = fresh;
        thread.read_in_nook = Some(thread.read_in_nook.map_or(through, |r| r.max(through)));
        thread.read_in_app = Some(through);
        if thread.app_unread.is_some() {
            thread.app_unread = Some(fresh);
        }
        if fresh == 0 {
            if thread.waits_in_app == Some(true) {
                thread.waits_in_app = Some(false);
            }
            thread.marked_unread = None;
        }
    }

    /// Until when the chat counts as read in Nook now: what passing the read on tells the app.
    pub fn read_mark(&self, key: &str) -> Option<DateTime<Utc>> {
        let thread = self.threads.get(key)?;
        if thread.unread > 0 {
            return thread.read_in_nook;
        }
        [thread.read_in_nook, thread.newest_incoming()].into_iter().flatten().max()
    }

    /// "Mark as unread": the chat shows a badge again, until it is read. In Nook only. False when it already had one.
    pub fn mark_unread(&mut self, key: &str, date: DateTime<Utc>) -> bool {
        let Some(thread) = self.threads.get_mut(key) else { return false };
        if thread.unread != 0 {
            return false;
        }
        thread.unread = 1;
        thread.read_in_nook = None;
        thread.marked_unread = Some(date);
        true
    }

    /// Unread in the app too: Nook told the app after your "Mark as unread".
    pub fn mark_unread_in_app(&mut self, key: &str) {
        let Some(thread) = self.threads.get_mut(key) else { return };
        thread.read_in_app = None;
        if thread.waits_in_app.is_some() {
            thread.waits_in_app = Some(true);
        }
        if let Some(counted) = thread.app_unread {
            thread.app_unread = Some(counted.max(1));
        }
    }

    /// Every chat with something new read in Nook.
    pub fn mark_all_read(&mut self, date: DateTime<Utc>) {
        let keys: Vec<String> = self.threads.iter().filter(|(_, t)| t.unread > 0).map(|(k, _)| k.clone()).collect();
        for key in keys {
            self.mark_read(&key, date);
        }
    }

    pub fn rename(&mut self, key: &str, name: &str) {
        if let Some(thread) = self.threads.get_mut(key).filter(|_| !name.is_empty()) {
            thread.name = name.to_string();
        }
    }

    /// Removes a chat; its app brings back only what is newer.
    pub fn remove(&mut self, key: &str, date: DateTime<Utc>) {
        self.threads.remove(key);
        self.removed.retain(|_, when| date - *when < Self::max_age());
        self.removed.insert(key.to_string(), date);
    }

    /// Drops chats with nothing new for [`Self::MAX_AGE_DAYS`], then the quietest beyond [`Self::MAX_THREADS`]. A chat
    /// its app still lists stays either way.
    pub fn trim(&mut self, now: DateTime<Utc>) {
        self.threads.retain(|_, t| now - t.last() < Self::max_age() || Self::is_listed(t, now));
        self.removed.retain(|_, when| now - *when < Self::max_age());
        self.drop_quietest(now);
    }

    /// A bridge listed this chat as one of yours lately.
    pub fn is_listed(thread: &InboxThread, now: DateTime<Utc>) -> bool {
        thread.listed.is_some_and(|l| now - l < Self::max_age())
    }

    fn drop_quietest(&mut self, now: DateTime<Utc>) {
        if self.threads.len() <= Self::MAX_THREADS {
            return;
        }
        let mut droppable: Vec<(DateTime<Utc>, String)> =
            self.threads.values().filter(|t| !Self::is_listed(t, now)).map(|t| (t.last(), t.id.clone())).collect();
        if droppable.len() <= Self::MAX_THREADS {
            return;
        }
        droppable.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        for (_, key) in droppable.into_iter().skip(Self::MAX_THREADS) {
            self.threads.remove(&key);
        }
    }

    /// The inbox as it goes to disk: a chat whose messages its app keeps (`ephemeral`) goes without them, so none of its
    /// messages ever reaches the disk. What Nook knows of the chat itself stays (read, unread, its kind, when it last
    /// had a message, so it still sorts in its place).
    pub fn for_disk(&self) -> ChatInbox {
        let mut copy = self.clone();
        let ids: HashSet<String> = copy.threads.values().filter(|t| t.ephemeral).map(|t| t.id.clone()).collect();
        copy.forget_messages(&ids);
        copy
    }

    /// Lets go of the messages of these chats (their app was turned off): only what Nook knows of each chat stays.
    pub fn forget_messages(&mut self, keys: &HashSet<String>) {
        for key in keys {
            let Some(thread) = self.threads.get_mut(key) else { continue };
            let last = thread.last();
            if thread.activity.is_none_or(|a| last > a) && !thread.messages.is_empty() {
                thread.activity = Some(last);
            }
            thread.messages.clear();
        }
    }

    /// The chats of one app: the newest first.
    pub fn sorted_of(&self, app: &str) -> Vec<&InboxThread> {
        self.sorted().into_iter().filter(|t| t.app == app).collect()
    }

    /// Newest first.
    pub fn sorted(&self) -> Vec<&InboxThread> {
        let mut list: Vec<(DateTime<Utc>, &InboxThread)> = self.threads.values().map(|t| (t.last(), t)).collect();
        list.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
        list.into_iter().map(|(_, t)| t).collect()
    }

    pub fn total_unread(&self) -> usize {
        self.threads.values().map(|t| t.unread).sum()
    }

    /// The apps that have chats here, the busiest first.
    pub fn apps(&self) -> Vec<String> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for t in self.threads.values() {
            *counts.entry(t.app.as_str()).or_default() += 1;
        }
        let mut apps: Vec<(&str, usize)> = counts.into_iter().collect();
        apps.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        apps.into_iter().map(|(a, _)| a.to_string()).collect()
    }

    /// The chats someone else wrote in between `before` and `self`: their newest message from someone else is new, no
    /// older than `since`, and still unread. Oldest first, so the newest notice comes last.
    pub fn fresh(&self, before: &ChatInbox, since: DateTime<Utc>) -> Vec<String> {
        let mut list: Vec<(String, DateTime<Utc>)> = self
            .threads
            .values()
            .filter(|t| t.unread > 0)
            .filter_map(|t| {
                let old = before.threads.get(&t.id).map(|o| &o.messages);
                if old == Some(&t.messages) {
                    return None;
                }
                let newest = t.messages.iter().rev().find(|m| m.is_incoming())?;
                let was = old.and_then(|o| o.iter().rev().find(|m| m.is_incoming())).map(|m| &m.id);
                (newest.date >= since && was != Some(&newest.id)).then(|| (t.id.clone(), newest.date))
            })
            .collect();
        list.sort_by_key(|(_, d)| *d);
        list.into_iter().map(|(k, _)| k).collect()
    }
}

/// A chat name as a key: invisible marks out, case and accents folded, runs of spaces as one.
fn fold(text: &str) -> String {
    let visible: String = text
        .chars()
        .filter(|c| !matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2069}' | '\u{FEFF}'))
        .collect();
    let folded: String = visible.nfkd().filter(|c| !is_combining_mark(*c)).collect::<String>().to_lowercase();
    folded.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(min: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 17, 12, 0, 0).unwrap() + Duration::minutes(min)
    }

    fn msg(id: &str, min: i64, from_me: bool) -> InboxMessage {
        InboxMessage::new(id, format!("text {id}"), at(min), from_me)
    }

    fn chat(app: &str, id: &str, messages: Vec<InboxMessage>) -> BridgedChat {
        BridgedChat { app: app.into(), name: format!("Chat {id}"), chat_id: Some(id.into()), messages, ..Default::default() }
    }

    #[test]
    fn keys_by_id_and_by_folded_name_never_meet() {
        assert_eq!(ChatInbox::key("whatsapp", "31@s.whatsapp.net"), "whatsapp#31@s.whatsapp.net");
        assert_eq!(ChatInbox::key_by_name("slack", "  Ána\u{200B}  Bél "), "slack|ana bel");
        assert_eq!(ChatInbox::key_by_name("slack", "ANA BEL"), ChatInbox::key_by_name("slack", "Ána Bél"));
    }

    #[test]
    fn the_first_look_at_a_chat_is_not_new_but_what_comes_after_is() {
        let mut inbox = ChatInbox::default();
        assert!(inbox.merge(chat("telegram", "a", vec![msg("1", 0, false), msg("2", 1, false)]), at(2)));
        let key = ChatInbox::key("telegram", "a");
        assert_eq!(inbox.threads[&key].unread, 0);
        assert!(inbox.merge(chat("telegram", "a", vec![msg("2", 1, false), msg("3", 3, false)]), at(3)));
        assert_eq!(inbox.threads[&key].unread, 1);
        assert_eq!(inbox.threads[&key].messages.len(), 3);
        // The same read again changes nothing.
        assert!(!inbox.merge(chat("telegram", "a", vec![msg("3", 3, false)]), at(4)));
    }

    #[test]
    fn history_and_your_own_answer_are_never_new() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("signal", "a");
        inbox.merge(chat("signal", "a", vec![msg("1", 0, false)]), at(0));
        let mut old = chat("signal", "a", vec![msg("0", 5, false)]);
        old.history = true;
        inbox.merge(old, at(5));
        assert_eq!(inbox.threads[&key].unread, 0);
        inbox.merge(chat("signal", "a", vec![msg("2", 10, true), msg("3", 9, false)]), at(10));
        assert_eq!(inbox.threads[&key].unread, 0, "an answer reads what came before it");
    }

    #[test]
    fn the_apps_own_count_wins_until_read_in_nook() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("slack", "c");
        let mut c = chat("slack", "c", vec![msg("1", 0, false), msg("2", 1, false)]);
        c.unread = Some(2);
        inbox.merge(c, at(1));
        assert_eq!(inbox.threads[&key].unread, 2);
        inbox.mark_read(&key, at(2));
        assert_eq!(inbox.threads[&key].read_state(), ChatReadState::ReadInNook);
        let mut c = chat("slack", "c", vec![msg("3", 3, false)]);
        c.unread = Some(3);
        inbox.merge(c, at(3));
        assert_eq!(inbox.threads[&key].unread, 1, "only what came after the read in Nook");
        inbox.mark_read_in_app(&key, at(4), None);
        assert_eq!(inbox.threads[&key].read_state(), ChatReadState::Read);
    }

    #[test]
    fn marked_unread_stays_until_read() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("whatsapp", "p");
        inbox.merge(chat("whatsapp", "p", vec![msg("1", 0, false)]), at(0));
        assert!(inbox.mark_unread(&key, at(1)));
        assert!(!inbox.mark_unread(&key, at(1)));
        let mut c = chat("whatsapp", "p", vec![msg("2", 2, true)]);
        c.unread = Some(0);
        inbox.merge(c, at(2));
        assert_eq!(inbox.threads[&key].unread, 1);
        inbox.mark_read(&key, at(3));
        assert_eq!(inbox.threads[&key].unread, 0);
    }

    #[test]
    fn edits_deletions_and_ticks_land_on_the_known_message() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("telegram", "a");
        let mut mine = msg("1", 0, true);
        mine.receipt = Some(Receipt::Delivered);
        inbox.merge(chat("telegram", "a", vec![mine, msg("2", 1, false)]), at(1));
        let mut edited = msg("2", 1, false);
        edited.text = "new words".into();
        edited.edited = true;
        let mut older_tick = msg("1", 0, true);
        older_tick.receipt = Some(Receipt::Sent);
        inbox.merge(chat("telegram", "a", vec![older_tick, edited]), at(2));
        let t = &inbox.threads[&key];
        assert_eq!(t.messages[0].receipt, Some(Receipt::Delivered), "ticks only move forward");
        assert_eq!(t.messages[1].text, "new words");
        assert!(t.messages[1].edited);
        let mut c = chat("telegram", "a", vec![]);
        c.deleted = vec!["2".into()];
        inbox.merge(c, at(3));
        assert!(inbox.threads[&key].messages[1].deleted);
        assert!(inbox.threads[&key].messages[1].text.is_empty());
        assert!(inbox.apply_receipt(&key, &["1".into()], Receipt::Read));
        assert_eq!(inbox.threads[&key].messages[0].receipt, Some(Receipt::Read));
    }

    #[test]
    fn a_removed_chat_comes_back_only_with_newer_messages() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("signal", "a");
        inbox.merge(chat("signal", "a", vec![msg("1", 0, false)]), at(0));
        inbox.remove(&key, at(5));
        assert!(!inbox.merge(chat("signal", "a", vec![msg("1", 0, false)]), at(6)));
        assert!(inbox.merge(chat("signal", "a", vec![msg("1", 0, false), msg("2", 7, false)]), at(7)));
        assert_eq!(inbox.threads[&key].messages.len(), 1);
    }

    #[test]
    fn a_gone_chat_goes() {
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("whatsapp", "g", vec![msg("1", 0, false)]), at(0));
        let mut c = chat("whatsapp", "g", vec![]);
        c.gone = true;
        assert!(inbox.merge(c, at(1)));
        assert!(inbox.threads.is_empty());
        assert!(inbox.removed.contains_key(&ChatInbox::key("whatsapp", "g")));
    }

    #[test]
    fn without_an_id_the_same_words_within_a_minute_are_one_message() {
        let mut inbox = ChatInbox::default();
        let named = |id: &str, min: i64| BridgedChat {
            app: "discord".into(),
            name: "Ann".into(),
            messages: vec![InboxMessage::new(id, "hi", at(min), false)],
            ..Default::default()
        };
        inbox.merge(named("n1", 0), at(0));
        assert!(!inbox.merge(named("b1", 0), at(0)));
        // By id, two "hi"s are two.
        inbox.merge(chat("telegram", "x", vec![InboxMessage::new("1", "hi", at(0), false)]), at(0));
        inbox.merge(chat("telegram", "x", vec![InboxMessage::new("2", "hi", at(0), false)]), at(0));
        assert_eq!(inbox.threads[&ChatInbox::key("telegram", "x")].messages.len(), 2);
    }

    #[test]
    fn keeps_a_bounded_number_of_messages_until_grown() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("slack", "big");
        let many: Vec<InboxMessage> = (0..80).map(|i| msg(&i.to_string(), i, false)).collect();
        inbox.merge(chat("slack", "big", many.clone()), at(90));
        assert_eq!(inbox.threads[&key].messages.len(), ChatInbox::KEEP);
        assert_eq!(inbox.grow(&key, 30), Some(80));
        let mut older = chat("slack", "big", many);
        older.history = true;
        inbox.merge(older, at(91));
        assert_eq!(inbox.threads[&key].messages.len(), 80);
    }

    #[test]
    fn trim_drops_old_and_quietest_chats_but_keeps_listed_ones() {
        let mut inbox = ChatInbox::default();
        let mut listed = chat("telegram", "listed", vec![msg("1", 0, false)]);
        listed.listed = true;
        inbox.merge(listed.clone(), at(0));
        inbox.merge(chat("telegram", "old", vec![msg("1", 0, false)]), at(0));
        // Listed again two days later: its app still has it.
        inbox.merge(listed, at(0) + Duration::days(2));
        inbox.trim(at(0) + Duration::days(31));
        assert!(!inbox.threads.contains_key(&ChatInbox::key("telegram", "old")));
        assert!(inbox.threads.contains_key(&ChatInbox::key("telegram", "listed")));
        let later = at(0) + Duration::days(1);
        let mut inbox = ChatInbox::default();
        let chats: Vec<BridgedChat> =
            (0..(ChatInbox::MAX_THREADS + 5)).map(|i| chat("x", &i.to_string(), vec![msg("1", i as i64, false)])).collect();
        inbox.merge_all(chats, later);
        assert_eq!(inbox.threads.len(), ChatInbox::MAX_THREADS);
        assert!(!inbox.threads.contains_key(&ChatInbox::key("x", "0")), "the quietest go first");
    }

    #[test]
    fn ephemeral_chats_reach_the_disk_without_their_messages() {
        let mut inbox = ChatInbox::default();
        let mut c = chat("whatsapp", "p", vec![msg("1", 3, false)]);
        c.ephemeral = true;
        inbox.merge(c, at(3));
        inbox.merge(chat("mail", "m", vec![msg("1", 1, false)]), at(3));
        let disk = inbox.for_disk();
        let p = &disk.threads[&ChatInbox::key("whatsapp", "p")];
        assert!(p.messages.is_empty());
        assert_eq!(p.activity, Some(at(3)), "it still sorts in its place");
        assert_eq!(disk.threads[&ChatInbox::key("mail", "m")].messages.len(), 1);
    }

    #[test]
    fn read_state_rules() {
        assert_eq!(ChatReadState::of(2, None, Some(at(0)), None, None, None), ChatReadState::Unread(2));
        assert_eq!(ChatReadState::of(0, None, Some(at(0)), Some(at(1)), None, None), ChatReadState::ReadInNook);
        assert_eq!(ChatReadState::of(0, None, Some(at(0)), Some(at(1)), Some(at(1)), None), ChatReadState::Read);
        assert_eq!(ChatReadState::of(0, Some(1), Some(at(0)), None, None, None), ChatReadState::ReadInNook);
        assert_eq!(ChatReadState::of(0, None, Some(at(0)), Some(at(1)), None, Some(false)), ChatReadState::Read);
    }

    #[test]
    fn fresh_lists_chats_with_a_new_message_from_someone_else_oldest_first() {
        let mut before = ChatInbox::default();
        before.merge(chat("a", "1", vec![msg("1", 0, false)]), at(0));
        before.merge(chat("a", "2", vec![msg("1", 0, false)]), at(0));
        let mut after = before.clone();
        after.merge(chat("a", "2", vec![msg("2", 5, false)]), at(5));
        after.merge(chat("a", "1", vec![msg("2", 4, false)]), at(5));
        assert_eq!(after.fresh(&before, at(1)), vec![ChatInbox::key("a", "1"), ChatInbox::key("a", "2")]);
    }

    #[test]
    fn serializes_round_trip() {
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("mail", "m", vec![msg("1", 1, false)]), at(3));
        let json = serde_json::to_string(&inbox).unwrap();
        let back: ChatInbox = serde_json::from_str(&json).unwrap();
        assert_eq!(back, inbox);
    }
}
