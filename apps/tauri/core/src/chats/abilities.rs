//! Per-chat capabilities and action validation (`ChatAbilities`, `ChatAction` in `ChatContract.swift` on the Mac, CH-58).
//!
//! One list of what Nook can do in a chat, the same for every chat app, so menus, buttons, and backend handlers
//! never disagree.

use serde::{Deserialize, Serialize};

/// Outgoing attachment kinds a chat can accept besides plain text (`ChatOutgoing.Kind` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutgoingKind {
    Photo,
    Video,
    Gif,
    Audio,
    Voice,
    File,
}

impl OutgoingKind {
    pub const ALL: [Self; 6] = [Self::Photo, Self::Video, Self::Gif, Self::Audio, Self::Voice, Self::File];
}

/// What Nook can do in a chat, the same for every app (`ChatAbilities` on the Mac).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatAbilities {
    /// Text can be sent directly to the chat (else it is copied for the app).
    pub send: bool,
    /// Attachment kinds accepted besides text.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sends: Vec<OutgoingKind>,
    /// A reply can quote the message it answers.
    pub reply: bool,
    pub react: bool,
    /// Your own messages can be edited or revoked for everyone.
    pub edit: bool,
    pub delete: bool,
    /// "Mark as read in <app>" notifies the app itself.
    pub mark_read: bool,
    /// "Mark as unread" also marks the chat unread in its app (else in Nook only).
    pub mark_unread: bool,
    /// The chat can be pinned, muted, or archived in its app itself.
    pub pin: bool,
    pub mute: bool,
    pub archive: bool,
    /// The whole chat can be deleted in its app itself (else removed from Nook only).
    pub delete_chat: bool,
    /// Current state of the chat.
    pub pinned: bool,
    pub muted: bool,
    pub archived: bool,
    /// A poll in the chat can be voted on from Nook.
    pub vote: bool,
    /// "Delete for me" also deletes the message in the app itself (else in Nook only).
    pub delete_for_me: bool,
}

/// One user-initiated action in a chat (`ChatAction` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChatAction {
    Send,
    SendItem(OutgoingKind),
    React,
    Edit,
    Delete,
    MarkRead,
    MarkUnread,
    Pin,
    Mute,
    Archive,
    DeleteChat,
    Vote,
}

/// Why an action cannot proceed (`ChatAction.Refusal` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatActionRefusal {
    /// The chat's app does not support this action from Nook.
    Unsupported,
    /// No text to send or edit into.
    Empty,
    /// Only your own messages can be edited or deleted for everyone.
    NotMine,
}

impl ChatAbilities {
    /// Capabilities for a chat app given whether its bridge/gateway is connected and current flags.
    pub fn for_app(app: &str, connected: bool, pinned: bool, muted: bool, archived: bool) -> Self {
        let sends = if connected { OutgoingKind::ALL.to_vec() } else { vec![] };
        if app == "whatsapp" {
            Self {
                send: connected,
                sends,
                reply: connected,
                react: connected,
                edit: connected,
                delete: connected,
                mark_read: connected,
                // WhatsApp gateway does not expose in-app unread/pin/mute/archive/deleteChat;
                // Nook handles pin, mute, archive, mark-unread, and remove gracefully locally.
                mark_unread: false,
                pin: false,
                mute: false,
                archive: false,
                delete_chat: false,
                pinned,
                muted,
                archived,
                vote: false,
                delete_for_me: connected,
            }
        } else {
            Self {
                send: connected,
                sends,
                reply: connected,
                react: connected,
                edit: connected,
                delete: connected,
                mark_read: connected,
                mark_unread: connected,
                pin: connected,
                mute: connected,
                archive: connected,
                // nook-chatd supports read/unread/pin/mute/archive in-app; removing a chat stays local in Nook.
                delete_chat: false,
                pinned,
                muted,
                archived,
                vote: connected,
                delete_for_me: false,
            }
        }
    }

    /// Whether the chat's app allows this action directly from Nook.
    pub fn allows(&self, action: ChatAction) -> bool {
        match action {
            ChatAction::Send => self.send,
            ChatAction::SendItem(kind) => self.send && self.sends.contains(&kind),
            ChatAction::React => self.react,
            ChatAction::Edit => self.edit,
            ChatAction::Delete => self.delete,
            ChatAction::MarkRead => self.mark_read,
            ChatAction::MarkUnread => self.mark_unread,
            ChatAction::Pin => self.pin,
            ChatAction::Mute => self.mute,
            ChatAction::Archive => self.archive,
            ChatAction::DeleteChat => self.delete_chat,
            ChatAction::Vote => self.vote,
        }
    }
}

impl ChatAction {
    /// Audit tool name, identical across every chat app (`ChatAction.auditTool` on the Mac).
    pub fn audit_tool(self) -> &'static str {
        match self {
            Self::Send | Self::SendItem(_) => "chat_send",
            Self::React => "chat_react",
            Self::Edit => "chat_edit",
            Self::Delete => "chat_delete",
            Self::MarkRead => "chat_mark_read",
            Self::MarkUnread => "chat_mark_unread",
            Self::Pin => "chat_pin",
            Self::Mute => "chat_mute",
            Self::Archive => "chat_archive",
            Self::DeleteChat => "chat_delete_chat",
            Self::Vote => "chat_vote",
        }
    }

    /// Checks whether the action is allowed before hitting any bridge (`ChatAction.refusal` on the Mac).
    pub fn refusal(self, abilities: &ChatAbilities, text: Option<&str>, from_me: bool) -> Option<ChatActionRefusal> {
        if !abilities.allows(self) {
            return Some(ChatActionRefusal::Unsupported);
        }
        if matches!(self, Self::Send | Self::Edit) && text.unwrap_or_default().trim().is_empty() {
            return Some(ChatActionRefusal::Empty);
        }
        if matches!(self, Self::Edit | Self::Delete) && !from_me {
            return Some(ChatActionRefusal::NotMine);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whatsapp_and_helper_abilities_respect_per_app_contract() {
        let wa = ChatAbilities::for_app("whatsapp", true, false, false, false);
        assert!(wa.allows(ChatAction::Send));
        assert!(wa.allows(ChatAction::SendItem(OutgoingKind::Photo)));
        assert!(wa.allows(ChatAction::MarkRead));
        assert!(wa.delete_for_me);
        assert!(!wa.allows(ChatAction::Pin));
        assert!(!wa.allows(ChatAction::Archive));

        let tg = ChatAbilities::for_app("telegram", true, true, false, false);
        assert!(tg.allows(ChatAction::Send));
        assert!(tg.allows(ChatAction::MarkUnread));
        assert!(tg.allows(ChatAction::Pin));
        assert!(tg.allows(ChatAction::Mute));
        assert!(tg.allows(ChatAction::Archive));
        assert!(tg.pinned);

        let offline = ChatAbilities::for_app("telegram", false, false, true, true);
        assert!(!offline.allows(ChatAction::Send));
        assert!(!offline.allows(ChatAction::Archive));
        assert!(offline.muted);
        assert!(offline.archived);
    }

    #[test]
    fn action_refusals_and_audit_names_match_macos() {
        let tg = ChatAbilities::for_app("telegram", true, false, false, false);
        assert_eq!(ChatAction::Send.refusal(&tg, Some("   "), true), Some(ChatActionRefusal::Empty));
        assert_eq!(ChatAction::Send.refusal(&tg, Some("Hi"), true), None);
        assert_eq!(ChatAction::Edit.refusal(&tg, Some("Fixed"), false), Some(ChatActionRefusal::NotMine));
        assert_eq!(ChatAction::Delete.refusal(&tg, None, false), Some(ChatActionRefusal::NotMine));
        assert_eq!(ChatAction::Delete.refusal(&tg, None, true), None);
        assert_eq!(ChatAction::DeleteChat.refusal(&tg, None, true), Some(ChatActionRefusal::Unsupported));
        assert_eq!(ChatAction::Pin.audit_tool(), "chat_pin");
        assert_eq!(ChatAction::Archive.audit_tool(), "chat_archive");
        assert_eq!(ChatAction::MarkUnread.audit_tool(), "chat_mark_unread");
    }
}
