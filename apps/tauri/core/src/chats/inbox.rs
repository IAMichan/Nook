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
    /// The message this one answers (Nook's id of it), shown quoted at the top of its bubble.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// The reactions on it, when its app says them; `None` leaves what Nook knows as it is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reactions: Option<Vec<Reaction>>,
    /// What it said before it was edited or deleted for everyone, oldest first (`ChatVersion`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub versions: Vec<MessageVersion>,
    /// A poll this message asks, with the votes Nook knows (`ChatPoll`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poll: Option<super::poll::ChatPoll>,
    /// Someone came into the group or went out of it: the chat shows a centred line, not a message (`text` stays empty).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership: Option<super::membership::ChatMembership>,
    /// The group itself changed (a new name, picture...): a centred line like `membership`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_change: Option<super::membership::ChatGroupChange>,
}

/// One person in a group and how far your message got with them (`ChatReader` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageReader {
    pub name: String,
    pub receipt: Receipt,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<DateTime<Utc>>,
}

/// Extra receipt details kept per message id on a thread (`read_at`, group `read_by`, per-person `readers`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MessageReadDetail {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_by: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub readers: Vec<MessageReader>,
}

impl MessageReadDetail {
    pub fn is_empty(&self) -> bool {
        self.read_at.is_none() && self.read_by.is_empty() && self.readers.is_empty()
    }

    pub fn merge_from(&mut self, incoming: &MessageReadDetail) {
        if incoming.read_at.is_some() && self.read_at.is_none() {
            self.read_at = incoming.read_at;
        }
        for who in &incoming.read_by {
            if !who.is_empty() && !self.read_by.iter().any(|existing| existing.eq_ignore_ascii_case(who)) {
                self.read_by.push(who.clone());
            }
        }
        for reader in &incoming.readers {
            if let Some(existing) = self.readers.iter_mut().find(|r| r.name.eq_ignore_ascii_case(&reader.name)) {
                let next = existing.receipt.advanced(reader.receipt);
                if next != existing.receipt {
                    existing.receipt = next;
                    if reader.date.is_some() {
                        existing.date = reader.date;
                    }
                } else if existing.date.is_none() && reader.date.is_some() {
                    existing.date = reader.date;
                }
            } else if !reader.name.is_empty() {
                self.readers.push(reader.clone());
            }
        }
    }
}

/// A message serialized for the interface with filled ticks and optional `read_at` / `read_by` / `readers`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilledMessage {
    #[serde(flatten)]
    pub message: InboxMessage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_by: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub readers: Vec<MessageReader>,
}

/// Detailed metadata for one message (`MessageInfoPopover` on macOS, CH-47): sent/delivered/read timestamps,
/// sender handle, app/account, and version history.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageInfo {
    pub id: String,
    pub chat_key: String,
    pub app: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    pub sender: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    pub from_me: bool,
    pub sent_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Receipt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_by: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub readers: Vec<MessageReader>,
    pub edited: bool,
    pub deleted: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub versions: Vec<MessageVersion>,
}

/// Messages you deleted for yourself, per chat (`ChatHiddenMessages` on macOS, CH-47): the chat no longer shows them
/// locally, even when the bridge brings them in again at its next read.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ChatHiddenMessages {
    pub hidden: HashMap<String, HashSet<String>>,
}

impl ChatHiddenMessages {
    pub fn is_empty(&self) -> bool {
        self.hidden.is_empty() || self.hidden.values().all(HashSet::is_empty)
    }

    pub fn ids(&self, chat: &str) -> HashSet<String> {
        self.hidden.get(chat).cloned().unwrap_or_default()
    }

    pub fn is_hidden(&self, chat: &str, message_id: &str) -> bool {
        self.hidden.get(chat).is_some_and(|set| set.contains(message_id))
    }

    /// Hides `message_id` in `chat` from now on. Returns `true` if newly hidden.
    pub fn hide(&mut self, chat: &str, message_id: &str) -> bool {
        if chat.is_empty() || message_id.is_empty() {
            return false;
        }
        self.hidden.entry(chat.to_string()).or_default().insert(message_id.to_string())
    }

    /// Unhides `message_id` in `chat`.
    pub fn unhide(&mut self, chat: &str, message_id: &str) -> bool {
        let Some(set) = self.hidden.get_mut(chat) else {
            return false;
        };
        let removed = set.remove(message_id);
        if set.is_empty() {
            self.hidden.remove(chat);
        }
        removed
    }

    /// Filters a slice of items down to those not hidden in `chat`.
    pub fn visible<T>(&self, items: Vec<T>, chat: &str, id_of: impl Fn(&T) -> &str) -> Vec<T> {
        let Some(gone) = self.hidden.get(chat).filter(|s| !s.is_empty()) else {
            return items;
        };
        items.into_iter().filter(|item| !gone.contains(id_of(item))).collect()
    }

    /// Loads `chat-hidden.json` from `path` (or returns empty if missing/invalid).
    pub fn load(path: &std::path::Path) -> Self {
        std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    /// Saves `chat-hidden.json` to `path`.
    pub fn save(&self, path: &std::path::Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_string(&self.hidden).map_err(|e| e.to_string())?;
        std::fs::write(path, json).map_err(|e| e.to_string())
    }
}

/// An earlier text of a message and until when it said that.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageVersion {
    pub text: String,
    pub replaced: DateTime<Utc>,
}

/// One emoji on a message and who put it there (`ChatReactions` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reaction {
    pub emoji: String,
    /// Who reacted with it, by name; "" for you.
    #[serde(default)]
    pub from: Vec<String>,
    /// You are one of them.
    #[serde(default)]
    pub mine: bool,
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
            reply_to: None,
            reactions: None,
            versions: vec![],
            poll: None,
            membership: None,
            group_change: None,
        }
    }

    /// A line about who is in the group, as the apps show it (yours when you did it).
    pub fn membership_notice(id: impl Into<String>, date: DateTime<Utc>, membership: super::membership::ChatMembership) -> Self {
        let mut line = Self::new(id, String::new(), date, membership.by_me());
        line.membership = Some(membership);
        line
    }

    /// A line about the group itself changing (yours when you did it, unless the app says whose it is).
    pub fn group_notice(
        id: impl Into<String>,
        date: DateTime<Utc>,
        change: super::membership::ChatGroupChange,
        from_me: Option<bool>,
    ) -> Self {
        let mut line = Self::new(id, String::new(), date, from_me.unwrap_or_else(|| change.by_me()));
        line.group_change = Some(change);
        line
    }

    /// A line about the group rather than a message.
    pub fn is_notice(&self) -> bool {
        self.membership.is_some() || self.group_change.is_some()
    }

    /// Someone else's message: what "unread" and "read" are about. A change in who is in a group does none of that.
    pub fn is_incoming(&self) -> bool {
        !self.from_me && !self.is_notice()
    }

    /// The message as it shows once deleted for everyone: no words, no file.
    pub fn withdrawn(&self) -> Self {
        let mut copy = self.clone();
        // What it said stays readable under "Before it was deleted".
        if !copy.text.is_empty() && !copy.deleted {
            copy.versions.push(MessageVersion { text: copy.text.clone(), replaced: Utc::now() });
        }
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
    /// What the app says of the chat itself (`ChatProfile`); `None` leaves what Nook knows as it is.
    pub profile: Option<super::ChatProfile>,
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
    pub pinned_in_app: Option<bool>,
    pub archived_in_app: Option<bool>,
    /// The app keeps the messages, Nook only shows them: they never reach the disk (`forDisk`).
    pub ephemeral: bool,
    /// A group you left or a chat deleted in the app: it goes, as one removed in Nook.
    pub gone: bool,
    /// Per-message read details (`read_at`, group `read_by`, per-person `readers`) keyed by message id.
    pub read_details: HashMap<String, MessageReadDetail>,
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
    /// What the app says of the chat itself: a group's description and admins, a person's number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<super::ChatProfile>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_in_app: Option<bool>,
    /// Pinned to the top of the Chats list in Nook (and synced in-app where supported).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// Archived in Nook (and in its app where supported).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub archived: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ephemeral: bool,
    /// Per-message read details (`read_at`, group `read_by`, per-person `readers`) keyed by message id.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub read_details: HashMap<String, MessageReadDetail>,
    /// People currently typing in this chat (live ephemeral state; cleared before writing to disk).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub typing: Vec<String>,
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
            profile: None,
            handle: None,
            has_older: None,
            activity: None,
            waits_in_app: None,
            muted_in_app: None,
            pinned_in_app: None,
            pinned: false,
            archived: false,
            ephemeral: false,
            read_details: HashMap::new(),
            typing: vec![],
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

    /// A bot in a private chat is automated (not a person in People).
    pub fn is_automated(&self) -> bool {
        self.profile.as_ref().is_some_and(|p| p.bot) && self.notice_kind() != ChatKind::Group
    }

    /// The other person's phone number as their app says it: the chat's profile, else its handle when that is a number.
    pub fn phone(&self) -> Option<&str> {
        if let Some(phone) = self.profile.as_ref().and_then(|p| p.phone.as_deref()).map(str::trim).filter(|s| !s.is_empty()) {
            return Some(phone);
        }
        let handle = self.handle.as_deref()?.trim();
        if super::ChatHandle::phone_key(handle).is_some() && (!handle.contains('@') || super::ChatHandle::is_number_id(handle)) {
            Some(handle)
        } else {
            None
        }
    }

    /// The other person's address as their app says it: the chat's profile, else its handle when that is one.
    pub fn email(&self) -> Option<&str> {
        if let Some(email) = self.profile.as_ref().and_then(|p| p.email.as_deref()).map(str::trim).filter(|s| !s.is_empty()) {
            return Some(email);
        }
        let handle = self.handle.as_deref()?.trim();
        if handle.contains('@') && !super::ChatHandle::is_number_id(handle) {
            Some(handle)
        } else {
            None
        }
    }

    /// Who the chat is with across apps (`ChatIdentity::key`): the same person in WhatsApp, Telegram, Slack and Mail is one.
    pub fn identity(&self) -> String {
        super::ChatIdentity::key(&self.name, self.phone(), self.email())
    }

    /// What finds the person in Contacts and People (a number, else an address): what the app said of them.
    pub fn contact_handle(&self) -> Option<&str> {
        self.phone().or_else(|| self.email())
    }

    /// Read here, read in Nook only, or read in the app too: the same three states for every chat app.
    pub fn read_state(&self) -> ChatReadState {
        ChatReadState::of(self.unread, self.app_unread, self.newest_incoming(), self.read_in_nook, self.read_in_app, self.waits_in_app)
    }

    /// Whether what they wrote last looks like phishing or a scam (`InboxThread.trust` on the Mac): their newest up to
    /// three non-deleted incoming messages, judged by who the chat says they are (name + email handle if present) and
    /// whether you ever wrote in this chat.
    pub fn trust(&self) -> crate::brain::message_trust::Verdict {
        let incoming: Vec<&str> = self
            .messages
            .iter()
            .filter(|m| m.is_incoming() && !m.deleted)
            .rev()
            .take(3)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .map(|m| m.text.as_str())
            .collect();
        if incoming.is_empty() {
            return crate::brain::message_trust::Verdict::default();
        }
        let sender = match self
            .handle
            .as_deref()
            .map(str::trim)
            .filter(|h| h.contains('@') && !h.ends_with("@s.whatsapp.net") && !h.ends_with("@g.us") && !h.ends_with("@lid"))
        {
            Some(email) => format!("{} <{email}>", self.name),
            None => self.name.clone(),
        };
        let known = self.messages.iter().any(|m| m.from_me);
        crate::brain::message_trust::assess(&sender, "", &incoming.join("\n"), known)
    }

    /// Whether Nook may automatically suggest a reply in the empty composer field: the newest non-deleted message must
    /// be someone else's AND the thread must not look like phishing or a scam (CH-39).
    pub fn should_suggest_reply(&self) -> bool {
        let last_is_theirs = self.messages.iter().rev().find(|m| !m.deleted && !m.is_notice()).is_some_and(|m| !m.from_me);
        last_is_theirs && !self.trust().is_suspicious()
    }

    /// This thread's messages with ticks and group read receipts propagated to older outgoing messages (`ChatReceipts`).
    pub fn filled_messages(&self) -> Vec<FilledMessage> {
        fill_messages(&self.messages, &self.read_details, !self.is_group())
    }

    /// Detailed metadata for one message in this thread (`MessageInfoPopover`, CH-47).
    pub fn message_info(&self, id: &str) -> Option<MessageInfo> {
        let filled = self.filled_messages().into_iter().find(|f| f.message.id == id)?;
        let msg = filled.message;
        let sender = if msg.from_me {
            "You".to_string()
        } else if !msg.sender.is_empty() {
            msg.sender.clone()
        } else {
            self.name.clone()
        };
        let handle = msg.sender_id.clone().or_else(|| (!msg.from_me).then(|| self.handle.clone()).flatten());
        Some(MessageInfo {
            id: msg.id,
            chat_key: self.id.clone(),
            app: self.app.clone(),
            account: self.account.clone(),
            sender,
            sender_id: msg.sender_id,
            handle,
            from_me: msg.from_me,
            sent_at: msg.date,
            receipt: msg.receipt,
            read_at: filled.read_at,
            read_by: filled.read_by,
            readers: filled.readers,
            edited: msg.edited,
            deleted: msg.deleted,
            versions: msg.versions,
        })
    }

    /// The newest message with filled ticks and read details (for list summaries).
    pub fn filled_last(&self) -> Option<FilledMessage> {
        self.filled_messages().pop()
    }
}

/// Your messages' ticks as a chat shows them, oldest first (`ChatReceipts.filled` on the Mac): older outgoing messages
/// without an explicit receipt still get at least `Sent` and advance to match any later outgoing message; in a private
/// chat, an incoming reply after yours implies delivery.
pub fn filled_receipts(messages: &[InboxMessage], is_private: bool) -> Vec<Option<Receipt>> {
    let mut later: Option<Receipt> = None;
    let mut later_went_out = false;
    let mut theirs_later = false;
    let mut out = vec![None; messages.len()];
    for index in (0..messages.len()).rev() {
        let message = &messages[index];
        if !message.from_me {
            theirs_later = true;
            continue;
        }
        let mut receipt = message.receipt.unwrap_or(Receipt::Sent);
        if receipt == Receipt::Pending && later_went_out {
            receipt = Receipt::Sent;
        }
        if receipt >= Receipt::Sent {
            if let Some(l) = later {
                if l > receipt {
                    receipt = l;
                }
            }
        }
        if receipt == Receipt::Sent && is_private && theirs_later {
            receipt = Receipt::Delivered;
        }
        if receipt >= Receipt::Sent {
            later = Some(later.map_or(receipt, |l| l.max(receipt)));
        }
        if message.receipt.is_some_and(|said| said >= Receipt::Sent) {
            later_went_out = true;
        }
        out[index] = Some(receipt);
    }
    out
}

/// Returns `FilledMessage`s with filled receipts and propagated group `read_by` / `readers` on older outgoing
/// messages (`ChatReceipts.filled` + `ChatReceipts.filledReaders` on the Mac).
pub fn fill_messages(messages: &[InboxMessage], details: &HashMap<String, MessageReadDetail>, is_private: bool) -> Vec<FilledMessage> {
    let receipts = filled_receipts(messages, is_private);
    let mut out: Vec<FilledMessage> = messages
        .iter()
        .zip(receipts)
        .map(|(msg, receipt)| {
            let mut copy = msg.clone();
            if copy.from_me {
                copy.receipt = receipt;
            }
            let detail = details.get(&msg.id).cloned().unwrap_or_default();
            FilledMessage { message: copy, read_at: detail.read_at, read_by: detail.read_by, readers: detail.readers }
        })
        .collect();
    if !is_private {
        // Someone who read or spoke after an outgoing message has also read the earlier ones.
        let mut later_readers: HashMap<String, (String, Receipt)> = HashMap::new();
        let mut spoken: HashMap<String, (String, DateTime<Utc>)> = HashMap::new();
        for msg in out.iter_mut().rev() {
            if !msg.message.from_me {
                let name = msg.message.sender.trim();
                if !name.is_empty() {
                    spoken.insert(name.to_lowercase(), (name.to_string(), msg.message.date));
                }
                continue;
            }
            for (lower, (name, when)) in &spoken {
                if let Some(existing) = msg.readers.iter_mut().find(|r| r.name.to_lowercase() == *lower) {
                    if existing.receipt < Receipt::Read {
                        existing.receipt = Receipt::Read;
                        if existing.date.is_none() {
                            existing.date = Some(*when);
                        }
                    }
                } else {
                    msg.readers.push(MessageReader { name: name.clone(), receipt: Receipt::Read, date: Some(*when) });
                }
                if !msg.read_by.iter().any(|n| n.eq_ignore_ascii_case(name)) {
                    msg.read_by.push(name.clone());
                }
            }
            for (lower, (name, step)) in &later_readers {
                if let Some(existing) = msg.readers.iter_mut().find(|r| r.name.to_lowercase() == *lower) {
                    if *step > existing.receipt {
                        existing.receipt = *step;
                    }
                } else {
                    msg.readers.push(MessageReader { name: name.clone(), receipt: *step, date: None });
                }
                if *step == Receipt::Read && !msg.read_by.iter().any(|n| n.eq_ignore_ascii_case(name)) {
                    msg.read_by.push(name.clone());
                }
            }
            for name in &msg.read_by {
                if !msg.readers.iter().any(|r| r.name.eq_ignore_ascii_case(name)) {
                    msg.readers.push(MessageReader { name: name.clone(), receipt: Receipt::Read, date: msg.read_at });
                }
            }
            for reader in &msg.readers {
                if reader.receipt >= Receipt::Delivered && !reader.name.is_empty() {
                    let key = reader.name.to_lowercase();
                    later_readers
                        .entry(key)
                        .and_modify(|(_, r)| *r = (*r).max(reader.receipt))
                        .or_insert_with(|| (reader.name.clone(), reader.receipt));
                }
            }
        }
    }
    out
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
    /// Messages deleted for you alone (`ChatHiddenMessages` on the Mac, CH-47), per chat key.
    #[serde(default, skip_serializing_if = "ChatHiddenMessages::is_empty")]
    pub hidden: ChatHiddenMessages,
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
        let messages: Vec<InboxMessage> =
            chat.messages.iter().filter(|m| gone.is_none_or(|g| m.date > g) && !self.hidden.is_hidden(&key, &m.id)).cloned().collect();
        let described = known.as_ref().is_some_and(|k| {
            chat.unread.is_some()
                || chat.members.is_some()
                || chat.listed
                || !chat.deleted.is_empty()
                || !chat.read_details.is_empty()
                || chat.avatar.as_ref().is_some_and(|a| Some(a) != k.avatar.as_ref())
                || chat.profile.as_ref().is_some_and(|p| Some(p) != k.profile.as_ref())
                || chat.account.as_ref().is_some_and(|a| Some(a) != k.account.as_ref())
                || chat.kind.is_some_and(|c| Some(c) != k.kind)
                || chat.handle.as_ref().is_some_and(|h| Some(h) != k.handle.as_ref())
                || chat.has_older.is_some_and(|h| Some(h) != k.has_older)
                || (chat.chat_id.is_some() && chat.name != k.name)
                || chat.activity.is_some_and(|a| Some(a) != k.activity)
                || chat.waits_in_app.is_some_and(|w| Some(w) != k.waits_in_app)
                || chat.muted_in_app.is_some_and(|m| Some(m) != k.muted_in_app)
                || chat.pinned_in_app.is_some_and(|p| Some(p) != k.pinned_in_app)
                || chat.archived_in_app.is_some_and(|a| a != k.archived)
        });
        if messages.is_empty() && !described && !(known.is_none() && gone.is_none() && chat.listed) {
            return false;
        }
        // Two chats that shared a row now each have their own: the old row held both, and their app has their messages.
        if known.is_none() && chat.chat_id.is_none() {
            if let Some(shared) = super::ChatNames::unmarked(&chat.name) {
                let old = Self::key_by_name(&chat.app, shared);
                self.threads.remove(&old);
            }
        }
        let mut thread = known.clone().unwrap_or_else(|| InboxThread::new(&key, &chat.app, &chat.name));
        thread.chat_id = chat.chat_id.clone();
        let before = thread.clone();
        // What the chat had before, the app's own word on when it last moved included: a message no newer is no news.
        let newest_before = known.as_ref().map(|k| k.messages.last().map(|m| m.date).into_iter().chain(k.activity).max());
        let index_by_id: HashMap<String, usize> = thread.messages.iter().enumerate().rev().map(|(i, m)| (m.id.clone(), i)).collect();
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
                if !kept.text.is_empty() {
                    kept.versions.push(MessageVersion { text: kept.text.clone(), replaced: now });
                }
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
            if message.reply_to.is_some() && kept.reply_to != message.reply_to {
                kept.reply_to = message.reply_to.clone();
            }
            if message.reactions.is_some() && kept.reactions != message.reactions {
                kept.reactions = message.reactions.clone();
            }
            // A poll read again: its app's own counts win; a WhatsApp poll keeps the ballots Nook gathered for it.
            if let Some(poll) = &message.poll {
                if kept.poll.is_none()
                    || (poll.ballots.is_empty()
                        && kept.poll.as_ref().is_none_or(|k| k.ballots.is_empty())
                        && kept.poll.as_ref() != Some(poll))
                {
                    kept.poll = Some(poll.clone());
                }
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
        let answered = thread
            .messages
            .iter()
            .chain(messages.iter())
            .filter(|m| m.from_me)
            .map(|m| m.date)
            .max()
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
        for (id, detail) in &chat.read_details {
            if detail.is_empty() {
                continue;
            }
            let entry = thread.read_details.entry(id.clone()).or_default();
            entry.merge_from(detail);
        }
        if !thread.read_details.is_empty() {
            let live_ids: HashSet<&str> = thread.messages.iter().map(|m| m.id.as_str()).collect();
            thread.read_details.retain(|id, d| live_ids.contains(id.as_str()) && !d.is_empty());
        }
        if let Some(activity) = chat.activity {
            if thread.activity.is_none_or(|a| activity > a) {
                thread.activity = Some(activity);
            }
        }
        if let Some(unread) = chat.unread {
            // Marked unread by hand stays so: your own message does not take that back.
            let read = [thread.read_in_nook, if thread.marked_unread.is_none() { answered } else { None }].into_iter().flatten().max();
            if let Some(read) = read {
                // Read in Nook or answered: only what came in after that is new here, never more than the app counts.
                let fresh = thread.messages.iter().filter(|m| m.is_incoming() && m.date > read).count();
                thread.unread = if thread.messages.is_empty() {
                    if thread.activity.is_some_and(|a| a > read) {
                        unread
                    } else {
                        0
                    }
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
        if chat.profile.is_some() {
            thread.profile = chat.profile;
        }
        if chat.account.is_some() {
            thread.account = chat.account;
        }
        if chat.kind.is_some() {
            thread.kind = chat.kind;
        }
        if chat.handle.is_some() {
            thread.handle = chat.handle;
        } else if thread.handle.is_none() && thread.notice_kind() == ChatKind::Person {
            // An app that names the person by a number or address in what it says of them (Telegram, Slack, Teams,
            // the chat helper) finds them in People as WhatsApp's handle does.
            if let Some(known_handle) = thread.contact_handle().map(str::to_string) {
                thread.handle = Some(known_handle);
            }
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
        if let Some(pinned) = chat.pinned_in_app {
            thread.pinned_in_app = Some(pinned);
            thread.pinned = pinned;
        }
        if let Some(archived) = chat.archived_in_app {
            thread.archived = archived;
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
        let now = Utc::now();
        let mut stamped: Vec<String> = Vec::new();
        for m in thread.messages.iter_mut().filter(|m| m.from_me && wanted.contains(&m.id)) {
            let next = Some(m.receipt.unwrap_or(Receipt::Sent).advanced(receipt));
            if next != m.receipt {
                m.receipt = next;
                changed = true;
                if next == Some(Receipt::Read) {
                    stamped.push(m.id.clone());
                }
            }
        }
        for id in stamped {
            let entry = thread.read_details.entry(id).or_default();
            if entry.read_at.is_none() {
                entry.read_at = Some(now);
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

    /// Your own message got new words (after its app took them).
    pub fn edit_message(&mut self, key: &str, id: &str, text: &str) {
        if let Some(m) = self.message_mut(key, id) {
            if m.text != text {
                if !m.text.is_empty() {
                    m.versions.push(MessageVersion { text: m.text.clone(), replaced: Utc::now() });
                }
                m.text = text.to_string();
            }
            m.edited = true;
        }
    }

    /// Deleted for everyone: the row stays, without its words or file.
    pub fn withdraw_message(&mut self, key: &str, id: &str) {
        if let Some(m) = self.message_mut(key, id) {
            *m = m.withdrawn();
        }
    }

    /// Deleted for everyone (`delete_for_everyone`, CH-47): withdraws the message in place, preserving its earlier version.
    pub fn delete_for_everyone(&mut self, key: &str, id: &str) {
        self.withdraw_message(key, id);
    }

    /// Deleted for you: records `id` in `hidden` so future reads do not bring it back, and removes it from the chat in Nook.
    pub fn forget_message(&mut self, key: &str, id: &str) {
        self.hidden.hide(key, id);
        if let Some(thread) = self.threads.get_mut(key) {
            thread.messages.retain(|m| m.id != id);
            thread.read_details.remove(id);
        }
    }

    /// Deleted for you alone (`delete_for_me`, CH-47): hides the message locally and removes it from the thread.
    pub fn delete_for_me(&mut self, key: &str, id: &str) {
        self.forget_message(key, id);
    }

    /// Detailed metadata for one message in `key` (`message_info`, CH-47).
    pub fn message_info(&self, key: &str, id: &str) -> Option<MessageInfo> {
        self.threads.get(key)?.message_info(id)
    }

    /// Someone's vote on a poll in this chat, by the poll's message id (WhatsApp sends votes one by one). False when the
    /// poll is not here.
    pub fn ballot(&mut self, key: &str, poll: &str, voter: &str, ballot: super::poll::Ballot) -> bool {
        let Some(m) = self.message_mut(key, poll) else { return false };
        let Some(p) = m.poll.as_mut() else { return false };
        p.apply_ballot(voter, ballot);
        true
    }

    /// Your vote shown at once, before the app confirms it (`ChatPoll.voting`).
    pub fn vote_mine(&mut self, key: &str, poll: &str, choice: &[String]) {
        if let Some(p) = self.message_mut(key, poll).and_then(|m| m.poll.as_mut()) {
            if p.ballots.is_empty() {
                *p = p.voting(choice);
            } else {
                p.apply_ballot("\u{1}me", super::poll::Ballot { name: String::new(), mine: true, choice: choice.to_vec() });
            }
        }
    }

    /// Your reaction on a message: `emoji`, or none ("" takes yours off). One reaction of yours per message, as the apps
    /// have it.
    pub fn react_mine(&mut self, key: &str, id: &str, emoji: &str) {
        self.react_as(key, id, emoji, "");
    }

    /// Someone's reaction on a message (`who` by name, "" for you), in place of the one they had: an empty `emoji` takes
    /// theirs off. As the apps have it, everyone has one reaction per message.
    pub fn react_as(&mut self, key: &str, id: &str, emoji: &str, who: &str) {
        let Some(m) = self.message_mut(key, id) else { return };
        let mut list = m.reactions.clone().unwrap_or_default();
        for r in &mut list {
            if let Some(at) = r.from.iter().position(|w| w == who) {
                r.from.remove(at);
                if who.is_empty() {
                    r.mine = false;
                }
            }
        }
        list.retain(|r| !r.from.is_empty());
        if !emoji.is_empty() {
            match list.iter_mut().find(|r| r.emoji == emoji) {
                Some(r) => {
                    r.mine |= who.is_empty();
                    r.from.push(who.to_string());
                }
                None => list.push(Reaction { emoji: emoji.to_string(), from: vec![who.to_string()], mine: who.is_empty() }),
            }
        }
        m.reactions = Some(list);
    }

    fn message_mut(&mut self, key: &str, id: &str) -> Option<&mut InboxMessage> {
        self.threads.get_mut(key)?.messages.iter_mut().find(|m| m.id == id)
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

    /// Pins or unpins a chat in Nook (and records the in-app state when synced with the app).
    pub fn set_pinned(&mut self, key: &str, pinned: bool, in_app: bool) -> bool {
        let Some(thread) = self.threads.get_mut(key) else { return false };
        thread.pinned = pinned;
        if in_app {
            thread.pinned_in_app = Some(pinned);
        }
        true
    }

    /// Mutes or unmutes a chat.
    pub fn set_muted(&mut self, key: &str, muted: bool) -> bool {
        let Some(thread) = self.threads.get_mut(key) else { return false };
        thread.muted_in_app = Some(muted);
        true
    }

    /// Archives or unarchives a chat.
    pub fn set_archived(&mut self, key: &str, archived: bool) -> bool {
        let Some(thread) = self.threads.get_mut(key) else { return false };
        thread.archived = archived;
        true
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
        for thread in copy.threads.values_mut() {
            thread.typing.clear();
        }
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
            thread.read_details.clear();
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

    /// The chat a name, number or id means, in one app or any (`ChatRecipients::pick`): by its id, by the person's
    /// number, else by name (exact, a whole word, a part >= 3 chars, a typo). Two different chats that fit equally
    /// well are [`super::ChatPick::Several`]: an answer never goes to a guess.
    pub fn pick<'a>(&'a self, name: &str, app: Option<&str>, shown: impl Fn(&InboxThread) -> bool) -> super::ChatPick<&'a InboxThread> {
        let candidates: Vec<&'a InboxThread> = self.sorted().into_iter().filter(|t| app.is_none_or(|a| t.app == a) && shown(t)).collect();
        match super::ChatRecipients::pick(
            name,
            &candidates,
            |t| t.id.as_str(),
            |t| t.name.as_str(),
            |t| t.phone(),
            |wanted, t| t.id == wanted || t.chat_id.as_deref() == Some(wanted),
        ) {
            super::ChatPick::One(t) => super::ChatPick::One(t),
            super::ChatPick::Several(list) => super::ChatPick::Several(list.into_iter().copied().collect()),
            super::ChatPick::None => super::ChatPick::None,
        }
    }

    /// The one chat a name means (`pick`); `None` when none does, or when several do equally well.
    pub fn thread_named<'a>(&'a self, name: &str, app: Option<&str>, shown: impl Fn(&InboxThread) -> bool) -> Option<&'a InboxThread> {
        self.pick(name, app, shown).found()
    }

    /// What Nook says when a name fits several chats (`ChatInbox.which` on the Mac).
    pub fn which(name: &str, among: &[&InboxThread]) -> String {
        super::tools::which(name, among)
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

    #[test]
    fn edits_and_deletions_keep_what_it_said_before() {
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("telegram", "1", vec![msg("a", 0, false)]), at(1));
        let key = ChatInbox::key("telegram", "1");
        let mut edited = msg("a", 0, false);
        edited.text = "second".into();
        edited.edited = true;
        inbox.merge(chat("telegram", "1", vec![edited]), at(2));
        inbox.edit_message(&key, "a", "third");
        inbox.withdraw_message(&key, "a");
        let m = &inbox.threads[&key].messages[0];
        assert!(m.deleted && m.text.is_empty());
        assert_eq!(m.versions.iter().map(|v| v.text.as_str()).collect::<Vec<_>>(), vec!["text a", "second", "third"]);
    }

    #[test]
    fn message_steps_change_only_that_message() {
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("telegram", "1", vec![msg("a", 0, true), msg("b", 1, false)]), at(2));
        let key = ChatInbox::key("telegram", "1");
        inbox.edit_message(&key, "a", "fixed");
        inbox.react_mine(&key, "b", "👍");
        inbox.react_mine(&key, "b", "❤️");
        inbox.withdraw_message(&key, "zz");
        let t = &inbox.threads[&key];
        assert_eq!((t.messages[0].text.as_str(), t.messages[0].edited), ("fixed", true));
        let r = t.messages[1].reactions.clone().unwrap();
        assert_eq!(r, vec![Reaction { emoji: "❤️".into(), from: vec![String::new()], mine: true }]);
        inbox.react_mine(&key, "b", "");
        assert_eq!(inbox.threads[&key].messages[1].reactions, Some(vec![]));
        inbox.withdraw_message(&key, "b");
        assert!(inbox.threads[&key].messages[1].deleted);
        inbox.forget_message(&key, "a");
        assert_eq!(inbox.threads[&key].messages.len(), 1);
    }

    #[test]
    fn a_read_brings_reactions_and_the_quoted_message() {
        let mut inbox = ChatInbox::default();
        inbox.merge(chat("telegram", "1", vec![msg("a", 0, false)]), at(1));
        let mut again = msg("a", 0, false);
        again.reply_to = Some("x".into());
        again.reactions = Some(vec![Reaction { emoji: "😂".into(), from: vec!["Eva".into()], mine: false }]);
        inbox.merge(chat("telegram", "1", vec![again]), at(2));
        let m = &inbox.threads[&ChatInbox::key("telegram", "1")].messages[0];
        assert_eq!(m.reply_to.as_deref(), Some("x"));
        assert_eq!(m.reactions.as_ref().unwrap()[0].from, vec!["Eva".to_string()]);
        // A read that does not say them (WhatsApp's webhook) leaves them.
        inbox.merge(chat("telegram", "1", vec![msg("a", 0, false)]), at(3));
        assert!(inbox.threads[&ChatInbox::key("telegram", "1")].messages[0].reactions.is_some());
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

    #[test]
    fn older_messages_fill_ticks_and_group_readers() {
        let mut m1 = msg("1", 0, true);
        m1.receipt = None;
        let mut m2 = msg("2", 1, true);
        m2.receipt = Some(Receipt::Pending);
        let mut m3 = msg("3", 2, true);
        m3.receipt = Some(Receipt::Read);
        let mut reply = msg("4", 4, false);
        reply.sender = "Bo".into();

        let mut details = HashMap::new();
        details.insert("3".to_string(), MessageReadDetail { read_at: Some(at(3)), read_by: vec!["Anna".into()], readers: vec![] });

        // Private chat: m1 and m2 advance to Read because m3 was read.
        let filled_private = fill_messages(&[m1.clone(), m2.clone(), m3.clone()], &details, true);
        assert_eq!(filled_private[0].message.receipt, Some(Receipt::Read));
        assert_eq!(filled_private[1].message.receipt, Some(Receipt::Read));
        assert_eq!(filled_private[2].message.receipt, Some(Receipt::Read));
        assert_eq!(filled_private[2].read_at, Some(at(3)));

        // Private chat: incoming reply after a sent message implies delivered.
        let mut sent = msg("s", 0, true);
        sent.receipt = Some(Receipt::Sent);
        let filled_reply = fill_messages(&[sent, msg("r", 1, false)], &HashMap::new(), true);
        assert_eq!(filled_reply[0].message.receipt, Some(Receipt::Delivered));
        assert_eq!(filled_reply[1].message.receipt, None);

        // Group chat: Anna reading m3 and Bo replying after m3 both propagate to older outgoing messages.
        let filled_group = fill_messages(&[m1, m3, reply], &details, false);
        assert!(filled_group[0].read_by.contains(&"Anna".to_string()));
        assert!(filled_group[0].read_by.contains(&"Bo".to_string()));
        assert!(filled_group[1].read_by.contains(&"Bo".to_string()));

        // FilledMessage flattens InboxMessage fields cleanly at the JSON top level.
        let json = serde_json::to_value(&filled_group[1]).unwrap();
        assert_eq!(json["id"], "3");
        assert_eq!(json["receipt"], "read");
        assert!(json["readAt"].is_string());
        assert!(json["readBy"].is_array());
    }

    #[test]
    fn deserializes_legacy_json_without_read_or_typing_fields_and_clears_typing_for_disk() {
        let legacy = r#"{"threads":{"telegram#1":{"id":"telegram#1","app":"telegram","name":"Anna","messages":[{"id":"m1","text":"hi","date":"2026-11-17T12:00:00Z","fromMe":true}]}}}"#;
        let mut inbox: ChatInbox = serde_json::from_str(legacy).unwrap();
        let thread = inbox.threads.get_mut("telegram#1").unwrap();
        assert!(thread.typing.is_empty());
        assert!(thread.read_details.is_empty());
        let filled = thread.filled_messages();
        assert_eq!(filled[0].message.receipt, Some(Receipt::Sent));
        assert_eq!(filled[0].read_at, None);
        assert!(filled[0].read_by.is_empty());
        thread.typing = vec!["Anna".into()];
        let disk = inbox.for_disk();
        assert!(disk.threads["telegram#1"].typing.is_empty());
    }

    #[test]
    fn pin_mute_and_archive_state_updates_and_merges() {
        let mut inbox = ChatInbox::default();
        let now = at(10);
        let bridged = BridgedChat {
            app: "telegram".into(),
            name: "Design".into(),
            chat_id: Some("42".into()),
            listed: true,
            pinned_in_app: Some(true),
            muted_in_app: Some(false),
            ..Default::default()
        };
        assert!(inbox.merge(bridged, now));
        let key = ChatInbox::key("telegram", "42");
        assert!(inbox.threads[&key].pinned);
        assert_eq!(inbox.threads[&key].pinned_in_app, Some(true));

        assert!(inbox.set_pinned(&key, false, true));
        assert!(!inbox.threads[&key].pinned);
        assert_eq!(inbox.threads[&key].pinned_in_app, Some(false));

        assert!(inbox.set_muted(&key, true));
        assert_eq!(inbox.threads[&key].muted_in_app, Some(true));

        assert!(inbox.set_archived(&key, true));
        assert!(inbox.threads[&key].archived);
    }

    #[test]
    fn delete_for_me_hides_message_across_future_reads_and_message_info_inspects_details() {
        let mut inbox = ChatInbox::default();
        let key = ChatInbox::key("telegram", "1");
        let mut m1 = msg("a", 0, true);
        m1.receipt = Some(Receipt::Read);
        let mut m2 = msg("b", 1, false);
        m2.sender = "Anna".into();
        m2.sender_id = Some("u_anna".into());
        inbox.merge(chat("telegram", "1", vec![m1.clone(), m2.clone()]), at(2));

        inbox.edit_message(&key, "a", "updated text");
        let info_a = inbox.message_info(&key, "a").unwrap();
        assert!(info_a.from_me);
        assert!(info_a.edited);
        assert_eq!(info_a.versions.len(), 1);
        assert_eq!(info_a.versions[0].text, "text a");
        assert_eq!(info_a.receipt, Some(Receipt::Read));

        let info_b = inbox.message_info(&key, "b").unwrap();
        assert!(!info_b.from_me);
        assert_eq!(info_b.sender, "Anna");
        assert_eq!(info_b.handle.as_deref(), Some("u_anna"));

        // Delete for everyone keeps the row withdrawn with version history
        inbox.delete_for_everyone(&key, "a");
        let withdrawn = inbox.message_info(&key, "a").unwrap();
        assert!(withdrawn.deleted);
        assert_eq!(withdrawn.versions.len(), 2);

        // Delete for me hides message locally and prevents future bridge merges from restoring it
        inbox.delete_for_me(&key, "b");
        assert!(inbox.hidden.is_hidden(&key, "b"));
        assert!(inbox.message_info(&key, "b").is_none());

        inbox.merge(chat("telegram", "1", vec![m1, m2]), at(3));
        assert!(inbox.message_info(&key, "b").is_none());
        assert_eq!(inbox.threads[&key].messages.len(), 1);
    }
}
