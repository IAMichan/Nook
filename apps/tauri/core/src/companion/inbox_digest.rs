//! The Chats tab on the phone from a Windows or Linux computer (`InboxChatDigest`, `InboxLine`, `InboxTypist` and
//! `ChatAvatar` in `packages/protocol`), the way the Mac's `CompanionServer+Chats.swift` builds them. This app has one
//! chat app, WhatsApp through the linked gateway (`connectors::whatsapp`); the Mac's other chat apps come from macOS
//! notifications, which Windows and Linux do not offer. Pure: the same chats always give the same JSON, so a live phone
//! is only sent what changed (the server compares `inbox`, `inboxLines` and `inboxTyping` by value).
//!
//! Everything a message holds is untrusted text from other people: it is cut to size and passed on as text only.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::chat_digest::{clip, newest_fitting, LINES_BUDGET, LINE_LIMIT};
use crate::connectors::whatsapp::{ChatKind, Conversation, Media, Message, Receipt};

/// The app id and name the phone shows on a chat (`InboxChatDigest.app`, `.appName`).
pub const WHATSAPP: &str = "whatsapp";
pub const WHATSAPP_NAME: &str = "WhatsApp";
/// How many chats the phone lists, newest first (`CompanionServer.inboxLimit`).
pub const INBOX_LIMIT: usize = 80;
/// How many messages of one chat an answer holds at most, before the size budget (`ChatBubble.bubbles(last: 60)`).
pub const MAX_LINES: usize = 60;
/// A name and a preview in the list, and a quote, as the Mac cuts them.
pub const NAME_LIMIT: usize = 120;
pub const PREVIEW_LIMIT: usize = 200;
/// Why the list may be empty (`message` with `inbox`): no chat app is linked.
pub const CHATS_OFF: &str = "chatsoff";

/// `ChatAvatar`: the picture side, a batch, and what one picture may weigh (`ChatAvatar.side`, `.batch`, `.maxBytes`).
pub const AVATAR_SIDE: u32 = 120;
pub const AVATAR_BATCH: usize = 8;
pub const AVATAR_MAX_BYTES: usize = 16 * 1024;
/// `avatars` items with this start ask for an app's icon (`ChatAvatar.appPrefix`, `CompanionFeature.appIcons`).
pub const APP_PREFIX: &str = "app:";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxChatDigest {
    pub id: String,
    pub app: String,
    pub app_name: String,
    pub name: String,
    pub preview: String,
    pub last: f64,
    pub unread: i64,
    pub can_send: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticks: Option<String>,
    pub waits_in_app: bool,
    /// None: this computer does not say who is typing (the gateway does not tell it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub typing: Option<Vec<InboxTypist>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxTypist {
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxReader {
    pub name: String,
    pub receipt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxLine {
    pub id: String,
    pub text: String,
    pub date: f64,
    pub sender: String,
    pub from_me: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticks: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote_sender: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote_text: Option<String>,
    pub reactions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readers: Option<Vec<InboxReader>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatAvatar {
    pub chat: String,
    pub version: String,
    /// Base64 JPEG, `AVATAR_SIDE` pixels square.
    pub jpeg: String,
}

fn seconds(date: chrono::DateTime<chrono::Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

/// How far your own message got, as the phone names it.
pub fn ticks(receipt: Receipt) -> &'static str {
    match receipt {
        Receipt::Failed => "failed",
        Receipt::Pending => "pending",
        Receipt::Sent => "sent",
        Receipt::Delivered => "delivered",
        Receipt::Read => "read",
    }
}

/// A file that came with a message, by its name or its kind ("Photo"); it opens on the computer.
pub fn attachment(media: &Media) -> Option<String> {
    Some(match media {
        Media::None => return None,
        Media::Image => "Photo".into(),
        Media::Video => "Video".into(),
        Media::Audio => "Audio".into(),
        Media::Voice => "Voice message".into(),
        Media::Document { name } => name.as_deref().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("Document").to_string(),
        Media::Sticker => "Sticker".into(),
        Media::Location => "Location".into(),
        Media::Contact => "Contact".into(),
        Media::Other => "Attachment".into(),
    })
}

/// Your own words can go to this chat from the phone: a person or a group while WhatsApp is linked. Status updates and
/// channels are read only, as in WhatsApp itself.
pub fn can_send(kind: ChatKind, connected: bool) -> bool {
    connected && matches!(kind, ChatKind::Person | ChatKind::Group)
}

/// "@nook …" asks Nook to write the message (`ChatDraft.instruction` on the Mac): never sent as it is, and from the
/// phone not at all, since the phone never lets Nook write into a chat.
pub fn asks_nook(text: &str) -> bool {
    let trimmed = text.trim();
    let Some(head) = trimmed.get(..5) else { return false };
    if !head.eq_ignore_ascii_case("@nook") {
        return false;
    }
    // "@nookie" is no command; "@nook," and "@nook:" are.
    !trimmed[5..].chars().next().is_some_and(char::is_alphanumeric)
}

/// The newest message as a line under the chat's name, with who wrote it in a group ("Jan: dinner?").
pub fn preview(conversation: &Conversation) -> String {
    let Some(last) = conversation.messages.last() else { return String::new() };
    let text = if last.text.trim().is_empty() { attachment(&last.media).unwrap_or_default() } else { last.text.clone() };
    let line = if conversation.is_group && !last.from_me && !last.sender_name.trim().is_empty() {
        format!("{}: {text}", last.sender_name.trim())
    } else {
        text
    };
    clip(&line.replace('\n', " "), PREVIEW_LIMIT)
}

/// One chat of the list. `avatar` is the version of its picture when this computer has one (`avatar_version`).
pub fn digest(conversation: &Conversation, connected: bool, avatar: Option<String>) -> InboxChatDigest {
    let last = conversation.messages.last();
    InboxChatDigest {
        id: conversation.id.clone(),
        app: WHATSAPP.into(),
        app_name: WHATSAPP_NAME.into(),
        name: clip(&conversation.name, NAME_LIMIT),
        preview: preview(conversation),
        last: seconds(conversation.last_activity),
        unread: conversation.unread as i64,
        can_send: can_send(conversation.kind, connected),
        ticks: last.filter(|m| m.from_me).and_then(|m| m.receipt).map(|r| ticks(r).to_string()),
        // Reading here tells WhatsApp at once (or never, by the user's choice): nothing waits in the app.
        waits_in_app: false,
        typing: None,
        avatar,
    }
}

/// The chats of the list, newest first, at most `INBOX_LIMIT`; `avatar` gives a chat's picture version.
pub fn digests(chats: &[Conversation], connected: bool, avatar: impl Fn(&str) -> Option<String>) -> Vec<InboxChatDigest> {
    chats.iter().take(INBOX_LIMIT).map(|c| digest(c, connected, avatar(&c.id))).collect()
}

/// One message. In a group the sender's name goes with it; in a private chat and for your own it is empty.
pub fn line(message: &Message, is_group: bool) -> InboxLine {
    InboxLine {
        id: message.id.clone(),
        text: clip(&message.text, LINE_LIMIT),
        date: seconds(message.date),
        sender: if is_group && !message.from_me { clip(&message.sender_name, NAME_LIMIT) } else { String::new() },
        from_me: message.from_me,
        attachment: attachment(&message.media).map(|a| clip(&a, NAME_LIMIT)),
        ticks: message.receipt.filter(|_| message.from_me).map(|r| ticks(r).to_string()),
        // The gateway passes on neither quotes nor reactions nor who read a message in a group.
        quote_sender: None,
        quote_text: None,
        reactions: vec![],
        readers: None,
    }
}

/// The newest messages of a chat that fit in one answer, oldest first.
pub fn lines(conversation: &Conversation) -> Vec<InboxLine> {
    let start = conversation.messages.len().saturating_sub(MAX_LINES);
    let all = conversation.messages[start..].iter().map(|m| line(m, conversation.is_group)).collect();
    newest_fitting(all, LINES_BUDGET)
}

/// Which picture a chat has, as a short version the phone keeps it under: a hash of its size, start and end, so a new
/// picture counts as new without reading every byte each time the list is drawn.
pub fn avatar_version(bytes: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update((bytes.len() as u64).to_le_bytes());
    hash.update(&bytes[..bytes.len().min(512)]);
    hash.update(&bytes[bytes.len().saturating_sub(512)..]);
    hash.finalize()[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// The chats an `avatars` request may ask for: at most a batch, app icons left out (this computer does not send them).
pub fn wanted_avatars(items: &[String]) -> Vec<String> {
    items.iter().filter(|i| !i.is_empty() && !i.starts_with(APP_PREFIX)).take(AVATAR_BATCH).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn message(id: &str, text: &str, from_me: bool, sender: &str) -> Message {
        Message::new(id, "123@g.us", "1@s.whatsapp.net", sender, text, Utc.timestamp_opt(1_700_000_000, 0).unwrap(), from_me)
    }

    fn chat(kind: ChatKind, messages: Vec<Message>) -> Conversation {
        Conversation {
            id: if kind == ChatKind::Group { "123@g.us".into() } else { "31600000000@s.whatsapp.net".into() },
            name: "Family".into(),
            is_group: kind == ChatKind::Group,
            kind,
            messages,
            unread: 2,
            last_activity: Utc.timestamp_opt(1_700_000_100, 0).unwrap(),
        }
    }

    #[test]
    fn a_digest_has_the_macs_keys_and_leaves_out_what_it_does_not_know() {
        let mut mine = message("m2", "on my way", true, "");
        mine.receipt = Some(Receipt::Delivered);
        let c = chat(ChatKind::Group, vec![message("m1", "dinner?", false, "Jan"), mine]);
        let json = serde_json::to_value(digest(&c, true, Some("abcd".into()))).unwrap();
        assert_eq!(json["id"], "123@g.us");
        assert_eq!(json["app"], "whatsapp");
        assert_eq!(json["appName"], "WhatsApp");
        assert_eq!(json["preview"], "on my way");
        assert_eq!(json["last"], 1_700_000_100.0);
        assert_eq!(json["unread"], 2);
        assert_eq!(json["canSend"], true);
        assert_eq!(json["ticks"], "delivered");
        assert_eq!(json["waitsInApp"], false);
        assert_eq!(json["avatar"], "abcd");
        assert!(json.get("typing").is_none());
    }

    #[test]
    fn a_group_preview_says_who_wrote_it_and_a_photo_says_what_it_is() {
        let c = chat(ChatKind::Group, vec![message("m1", "dinner?\nat 7", false, "Jan")]);
        assert_eq!(preview(&c), "Jan: dinner? at 7");
        let mut photo = message("m2", "", false, "Jan");
        photo.media = Media::Image;
        assert_eq!(preview(&chat(ChatKind::Group, vec![photo])), "Jan: Photo");
        assert_eq!(preview(&chat(ChatKind::Person, vec![])), "");
    }

    #[test]
    fn only_people_and_groups_can_be_written_to_and_only_while_linked() {
        assert!(can_send(ChatKind::Person, true));
        assert!(can_send(ChatKind::Group, true));
        assert!(!can_send(ChatKind::Channel, true));
        assert!(!can_send(ChatKind::Status, true));
        assert!(!can_send(ChatKind::Person, false));
    }

    #[test]
    fn lines_name_the_sender_only_in_a_group_and_tick_only_your_own() {
        let mut mine = message("m2", "ok", true, "Me");
        mine.receipt = Some(Receipt::Read);
        let mut theirs = message("m1", "", false, "Jan");
        theirs.media = Media::Document { name: Some("plan.pdf".into()) };
        theirs.receipt = Some(Receipt::Read);
        let group = chat(ChatKind::Group, vec![theirs.clone(), mine.clone()]);
        let out = lines(&group);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].sender, "Jan");
        assert_eq!(out[0].attachment.as_deref(), Some("plan.pdf"));
        assert_eq!(out[0].ticks, None);
        assert_eq!(out[1].sender, "");
        assert_eq!(out[1].ticks.as_deref(), Some("read"));
        let person = chat(ChatKind::Person, vec![theirs]);
        assert_eq!(lines(&person)[0].sender, "");
        let json = serde_json::to_value(&out[1]).unwrap();
        assert_eq!(json["fromMe"], true);
        assert_eq!(json["reactions"], serde_json::json!([]));
        assert!(json.get("quoteText").is_none() && json.get("readers").is_none());
    }

    #[test]
    fn lines_keep_the_newest_sixty() {
        let all: Vec<Message> = (0..80).map(|i| message(&format!("m{i}"), "hi", false, "Jan")).collect();
        let out = lines(&chat(ChatKind::Group, all));
        assert_eq!(out.len(), MAX_LINES);
        assert_eq!(out[0].id, "m20");
        assert_eq!(out.last().unwrap().id, "m79");
    }

    #[test]
    fn the_same_chats_give_the_same_json() {
        let c = vec![chat(ChatKind::Person, vec![message("m1", "hi", false, "")])];
        let a = serde_json::to_value(digests(&c, true, |_| None)).unwrap();
        let b = serde_json::to_value(digests(&c, true, |_| None)).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn at_nook_is_an_instruction_but_at_nookie_is_not() {
        assert!(asks_nook("@nook"));
        assert!(asks_nook("  @Nook, say yes"));
        assert!(asks_nook("@nook: short"));
        assert!(!asks_nook("@nookie"));
        assert!(!asks_nook("hi @nook"));
        assert!(!asks_nook("@no"));
        assert!(!asks_nook("@nöök"));
    }

    #[test]
    fn an_avatar_version_follows_the_picture() {
        let a = avatar_version(&[1, 2, 3]);
        assert_eq!(a.len(), 16);
        assert_eq!(a, avatar_version(&[1, 2, 3]));
        assert_ne!(a, avatar_version(&[1, 2, 4]));
        assert_ne!(avatar_version(&vec![0; 2000]), avatar_version(&vec![0; 2001]));
    }

    #[test]
    fn avatars_ask_for_a_batch_of_chats_without_app_icons() {
        let items: Vec<String> = ["app:whatsapp", "", "a"].into_iter().map(String::from).chain((0..10).map(|i| format!("c{i}"))).collect();
        let wanted = wanted_avatars(&items);
        assert_eq!(wanted.len(), AVATAR_BATCH);
        assert_eq!(wanted[0], "a");
    }
}
