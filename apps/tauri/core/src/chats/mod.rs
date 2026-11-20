//! One inbox for every chat app (`ChatInbox`, `InboxThread`, `BridgedChat`, `ChatBridge` on the Mac).
//!
//! Each chat app only translates what its app says into a [`BridgedChat`]; the shared [`ChatInbox`] decides what is
//! new, what is read, what is kept and what goes, the same for every app. WhatsApp was the first app on it; Telegram,
//! Signal, Slack and the others reach it through the chat helper (CH-02) and their own bridges.

pub mod bridge;
pub mod call;
pub mod chatd;
pub mod draft;
pub mod follow_up;
pub mod person_notes;
pub mod voice;
pub mod inbox;
pub mod link;
pub mod link_preview;
pub mod store;
pub mod tools;

use serde::{Deserialize, Serialize};

pub use bridge::ChatBridge;
pub use inbox::{BridgedChat, ChatInbox, ChatReadState, InboxMessage, InboxThread};
pub use store::InboxStore;

/// The kinds of chat, the same for every app (`ChatKind` on the Mac): its app says which, else Nook guesses a person's
/// chat or a group by who wrote in it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatKind {
    Person,
    Group,
    Status,
    Channel,
}

/// How far your own message got: one grey tick when the server has it, two when it reached the other side, two blue
/// ones once it was read. Ordered, so ticks only move forward.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Receipt {
    Failed,
    Pending,
    Sent,
    Delivered,
    Read,
}

impl Receipt {
    /// An app's status word: `pending|sent|delivered|read|played|failed` and the like.
    pub fn from_status(status: &str) -> Option<Self> {
        Some(match status.to_lowercase().as_str() {
            "pending" => Self::Pending,
            "sent" | "server" => Self::Sent,
            "delivered" | "delivery" => Self::Delivered,
            "read" | "played" => Self::Read,
            "failed" | "error" => Self::Failed,
            _ => return None,
        })
    }

    /// Ticks only move forward; a failure always shows.
    pub fn advanced(self, new: Receipt) -> Receipt {
        if new == Receipt::Failed || new > self {
            new
        } else {
            self
        }
    }
}

/// What a message holds besides text: a label is shown, and the file itself is only fetched when the card shows it or
/// the user opens it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ChatMedia {
    #[default]
    None,
    Image,
    Video,
    Audio,
    Voice,
    Document {
        name: Option<String>,
    },
    Sticker,
    Location,
    Contact,
    Other,
}

impl ChatMedia {
    /// A file Nook can fetch from the app and open on this computer.
    pub fn is_openable(&self) -> bool {
        matches!(self, Self::Image | Self::Video | Self::Audio | Self::Voice | Self::Document { .. })
    }

    /// A file the card fetches by itself to show: a photo, a video or a document (a voice note stays a button).
    pub fn is_previewed(&self) -> bool {
        matches!(self, Self::Image | Self::Video | Self::Document { .. })
    }

    pub fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }
}
