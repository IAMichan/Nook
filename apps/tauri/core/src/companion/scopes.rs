//! What a paired phone may do (`CompanionScopes.swift`, docs/COMPANION.md "What a phone may do"). Chosen when it pairs
//! and editable later in Settings › Companion; a phone paired before scopes existed may do everything, as before.
//!
//! Every op needs one scope or none (`requirement`, an exhaustive match: a new op does not compile without one). The
//! computer refuses a request outside the phone's scopes, leaves out of every answer what the phone may not see, and
//! lists only the features the phone may use, so the phone hides the rest. Scopes are stored by name: a name this build
//! does not know (from a newer Nook) is ignored.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use super::models::{feature, CompanionOp, CompanionResponse, PairedDevice};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompanionScope {
    /// See the sessions, their conversations, the home and the usage.
    Read,
    /// Allow or deny approvals and answer questions.
    Approve,
    /// Start sessions, send them messages, stop and manage them.
    Operate,
    /// The Chats tab: read chats, answer the ones Nook can answer, mark them read or unread.
    Chats,
    /// Play, pause and skip what plays on the computer.
    Music,
    /// Chat with Nook itself.
    NookChat,
}

impl CompanionScope {
    /// In the Mac's order (`CompanionScope.allCases`).
    pub const ALL: [CompanionScope; 6] = [Self::Read, Self::Approve, Self::Operate, Self::Chats, Self::Music, Self::NookChat];

    pub fn name(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Approve => "approve",
            Self::Operate => "operate",
            Self::Chats => "chats",
            Self::Music => "music",
            Self::NookChat => "nookChat",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.name() == name)
    }
}

pub type Scopes = BTreeSet<CompanionScope>;

/// Everything: a new pairing's default, and a phone paired before scopes.
pub fn all() -> Scopes {
    CompanionScope::ALL.into_iter().collect()
}

/// What one op needs (`CompanionScopes.table`): `None` keeps the connection and the phone's own registrations, which
/// are always allowed, or nothing works at all.
pub fn requirement(op: CompanionOp) -> Option<CompanionScope> {
    use CompanionOp::*;
    use CompanionScope::*;
    match op {
        Hello | List | Subscribe | Ping | Register | Unregister | RequestUpdate | BindKey => None,
        Timeline | Home | Usage | Watch | Diff | Pulls | Pull | History | Entry => Some(Read),
        Decide | Answer => Some(Approve),
        Send | Stop | Options | Start | Manage => Some(Operate),
        // Reviewing, merging and working on a pull request act for you, as sending and starting do.
        PullAct | PullWork => Some(Operate),
        // What the notification settings are is part of what the phone reads; changing them, for every paired phone,
        // acts for you as managing a session does.
        NotifySettings => Some(Read),
        NotifySet => Some(Operate),
        // What a project holds goes further than a session's own changes.
        Terminals | Files | FileData => Some(Operate),
        Inbox | InboxChat | InboxSend | InboxMark | WatchChat | Avatars | InboxAct | InboxOlder | InboxMedia | InboxInfo | InboxSearch => {
            Some(CompanionScope::Chats)
        }
        CompanionOp::Music => Some(CompanionScope::Music),
        CompanionOp::Chats | Chat | Ask | ChatStop | WatchConversation | ChatAct | ChatSearch => Some(NookChat),
    }
}

/// The scope a feature belongs to (`CompanionScopes.featureScopes`); `None`: it is about the connection, always offered.
pub fn feature_scope(name: &str) -> Option<CompanionScope> {
    use CompanionScope::*;
    Some(match name {
        feature::START
        | feature::MANAGE
        | feature::WORKSPACE
        | feature::STEER
        | feature::IMAGES
        | feature::ATTACHMENTS
        | feature::FILE_PREVIEW => Operate,
        feature::LIVE_TIMELINE
        | feature::RESUME
        | feature::DIFF
        | feature::TIMELINE
        | feature::HOME
        | feature::USAGE
        | feature::PULL_REQUESTS
        | feature::HISTORY
        | feature::FULL_TRANSCRIPT
        | feature::PULL_ACTIONS
        | feature::NOTIFY_SETTINGS
        | "liveActivity" => Read,
        feature::CHAT | feature::LIVE_CONVERSATION | feature::NOOK_CHATS => NookChat,
        feature::MUSIC => Music,
        feature::INBOX | feature::LIVE_CHATS | feature::AVATARS | feature::APP_ICONS | feature::CHAT_ACTIONS => Chats,
        _ => return None,
    })
}

/// Whether `granted` allows `op`.
pub fn allows(op: CompanionOp, granted: &Scopes) -> bool {
    requirement(op).is_none_or(|s| granted.contains(&s))
}

/// Scopes from stored names; names this build does not know are dropped. `None` (a phone paired before scopes) is all.
pub fn parse(names: Option<&[String]>) -> Scopes {
    match names {
        None => all(),
        Some(names) => names.iter().filter_map(|n| CompanionScope::from_name(n)).collect(),
    }
}

/// Names to store or send, in a stable order.
pub fn names(scopes: &Scopes) -> Vec<String> {
    CompanionScope::ALL.into_iter().filter(|s| scopes.contains(s)).map(|s| s.name().to_string()).collect()
}

impl PairedDevice {
    /// What this phone may do; everything for a phone paired before scopes existed.
    pub fn granted_scopes(&self) -> Scopes {
        parse(self.scopes.as_deref())
    }
}

/// An answer as a phone with `granted` may see it (`CompanionScopes.redact`): what it may not see left out, only the
/// features it may use, and its scopes added to answers that list features (so the phone knows what to hide).
pub fn redact(mut r: CompanionResponse, granted: &Scopes) -> CompanionResponse {
    use CompanionScope::*;
    if !granted.contains(&Read) {
        r.sessions = r.sessions.map(|_| Vec::new());
        r.timeline = None;
        r.entry_text = None;
        r.home = None;
        r.usage = None;
        r.pulls = None;
        r.pull = None;
        r.notify = None;
        r.cursor = None;
    }
    if !granted.contains(&Operate) {
        r.launch = None;
        r.terminals = None;
        r.folder = None;
        r.file_chunk = None;
    }
    if !granted.contains(&Chats) {
        r.inbox = None;
        r.inbox_lines = None;
        r.inbox_typing = None;
        r.inbox_chat = None;
        r.avatars = None;
        r.inbox_media = None;
        r.inbox_info = None;
        r.inbox_before = None;
        r.inbox_more = None;
        r.inbox_found = None;
    }
    if !granted.contains(&NookChat) {
        r.conversations = None;
        r.messages = None;
        r.messages_conversation = None;
        r.messages_after = None;
        r.message_append = None;
        r.conversations_found = None;
        r.conversations_archived = None;
    }
    if let Some(features) = r.features.take() {
        r.features = Some(features.into_iter().filter(|f| feature_scope(f).is_none_or(|s| granted.contains(&s))).collect());
        r.scopes = Some(names(granted));
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::models::SessionDigest;

    #[test]
    fn the_table_matches_the_mac() {
        let read: Scopes = [CompanionScope::Read].into();
        assert!(allows(CompanionOp::Hello, &Scopes::new()), "keeping the connection is always allowed");
        assert!(allows(CompanionOp::BindKey, &Scopes::new()));
        assert!(allows(CompanionOp::Timeline, &read));
        assert!(!allows(CompanionOp::Decide, &read));
        assert!(!allows(CompanionOp::Send, &read));
        assert!(!allows(CompanionOp::Files, &read), "a project's files go further than reading");
        assert!(!allows(CompanionOp::InboxSend, &read));
        assert!(!allows(CompanionOp::Ask, &read));
        assert!(allows(CompanionOp::NotifySettings, &read));
        assert!(!allows(CompanionOp::NotifySet, &read));
        assert!(allows(CompanionOp::Music, &[CompanionScope::Music].into()));
        assert!(allows(CompanionOp::WatchConversation, &[CompanionScope::NookChat].into()));
    }

    #[test]
    fn names_round_trip_and_unknown_ones_drop() {
        assert_eq!(parse(None), all(), "a phone paired before scopes may do everything");
        let stored = vec!["music".to_string(), "read".into(), "teleport".into()];
        let scopes = parse(Some(&stored));
        assert_eq!(names(&scopes), vec!["read", "music"]);
        assert_eq!(names(&all()), vec!["read", "approve", "operate", "chats", "music", "nookChat"]);
        assert_eq!(serde_json::to_value(CompanionScope::NookChat).unwrap(), "nookChat");
    }

    #[test]
    fn redact_leaves_out_what_the_phone_may_not_see() {
        let response = CompanionResponse {
            sessions: Some(vec![serde_json::from_value::<SessionDigest>(serde_json::json!({
                "id": "S", "agent": "Claude", "title": "t", "attention": "working", "folder": "/p", "updated": 1.0,
                "excerpt": "", "items": []
            }))
            .unwrap()]),
            inbox: Some(serde_json::json!([])),
            conversations: Some(serde_json::json!([])),
            features: Some(vec![feature::STREAM.into(), feature::INBOX.into(), feature::TIMELINE.into(), feature::MUSIC.into()]),
            ..CompanionResponse::success("r")
        };
        let only_music: Scopes = [CompanionScope::Music].into();
        let r = redact(response.clone(), &only_music);
        assert_eq!(r.sessions.as_ref().map(Vec::len), Some(0));
        assert!(r.inbox.is_none() && r.conversations.is_none());
        assert_eq!(r.features, Some(vec![feature::STREAM.to_string(), feature::MUSIC.to_string()]));
        assert_eq!(r.scopes, Some(vec!["music".to_string()]));

        let r = redact(response, &all());
        assert_eq!(r.sessions.as_ref().map(Vec::len), Some(1));
        assert!(r.inbox.is_some() && r.conversations.is_some());
        assert_eq!(r.features.as_ref().map(Vec::len), Some(4));
    }

    #[test]
    fn redact_leaves_an_answer_without_features_alone() {
        let r = redact(CompanionResponse::success("r"), &Scopes::new());
        assert!(r.features.is_none() && r.scopes.is_none());
    }
}
