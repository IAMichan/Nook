//! Lines about a group in the middle of a chat: someone coming in or going out (`ChatMembership`), or the group itself
//! changing (`ChatGroupChange`), the same for every app. They count as no new message (`InboxMessage::is_incoming`).
//! The words are made by the views in the user's language from this data; `by` and `people` hold names, with
//! [`ME`] standing for you.

use serde::{Deserialize, Serialize};

/// You, among `by` and `people`: the line says "You" or "you" in your language.
pub const ME: &str = "\u{1}me";

/// Somebody the chat does not name: the line says "Someone" in your language.
pub const SOMEONE: &str = "\u{1}someone";

fn clean(name: &str) -> Option<String> {
    let name = name.trim();
    (!name.is_empty()).then(|| name.to_string())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MembershipChange {
    /// Someone (`by`) added them.
    Added,
    /// Someone (`by`) removed them.
    Removed,
    /// They came in: by themselves, or the app does not say who added them.
    Joined,
    /// They left by themselves.
    Left,
    /// They are no longer in it, and the app does not say whether they left or were removed.
    Gone,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMembership {
    pub change: MembershipChange,
    /// Who added or removed them, by name; `None` when the app does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    pub people: Vec<String>,
}

impl ChatMembership {
    /// What the app says, put plainly: someone who added or removed only themselves joined or left, and an addition or
    /// removal without who did it is only a coming in or a going out. Names without letters are left out.
    pub fn new(change: MembershipChange, by: Option<&str>, people: &[String]) -> Self {
        let mut unique: Vec<String> = vec![];
        for person in people.iter().filter_map(|p| clean(p)) {
            if !unique.contains(&person) {
                unique.push(person);
            }
        }
        let by = by.and_then(clean);
        let by_themselves = by.as_ref().is_some_and(|b| unique.len() == 1 && &unique[0] == b);
        let (change, by) = match change {
            MembershipChange::Added if by.is_none() || by_themselves => (MembershipChange::Joined, None),
            MembershipChange::Removed if by_themselves => (MembershipChange::Left, None),
            MembershipChange::Removed if by.is_none() => (MembershipChange::Gone, None),
            other => (other, by),
        };
        Self { change, by, people: unique }
    }

    pub fn by_me(&self) -> bool {
        self.by.as_deref() == Some(ME)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupChangeKind {
    /// A new name (`text`).
    Renamed,
    /// A new description (`text`, when the app gives it), or taken away (`text` empty).
    Described,
    Photo,
    PhotoRemoved,
    /// `people` made admin.
    Promoted,
    /// `people` no longer admin.
    Demoted,
    /// The group made (`text` its first name, when the app says).
    Created,
    AdminsOnly,
    Everyone,
    /// A message pinned to the top of the chat (`text` the start of it).
    Pinned,
    /// Messages now disappear after `text` seconds; "0" (or nothing) turns that off.
    Disappearing,
}

impl GroupChangeKind {
    /// The app's word for it (`ChatGroupChange.Kind` raw values on the Mac).
    pub fn parse(word: &str) -> Option<Self> {
        Some(match word {
            "renamed" => Self::Renamed,
            "described" => Self::Described,
            "photo" => Self::Photo,
            "photoRemoved" => Self::PhotoRemoved,
            "promoted" => Self::Promoted,
            "demoted" => Self::Demoted,
            "created" => Self::Created,
            "adminsOnly" => Self::AdminsOnly,
            "everyone" => Self::Everyone,
            "pinned" => Self::Pinned,
            "disappearing" => Self::Disappearing,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGroupChange {
    pub kind: GroupChangeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub people: Vec<String>,
}

impl ChatGroupChange {
    pub fn new(kind: GroupChangeKind, by: Option<&str>, text: Option<&str>, people: &[String]) -> Self {
        Self {
            kind,
            by: by.and_then(clean),
            text: text.map(|t| t.trim().to_string()),
            people: people.iter().filter_map(|p| clean(p)).collect(),
        }
    }

    pub fn by_me(&self) -> bool {
        self.by.as_deref() == Some(ME)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn adding_yourself_is_joining_and_removing_nobody_is_gone() {
        let joined = ChatMembership::new(MembershipChange::Added, Some("Anna"), &names(&["Anna"]));
        assert_eq!((joined.change, joined.by), (MembershipChange::Joined, None));
        let unknown = ChatMembership::new(MembershipChange::Added, None, &names(&["Anna"]));
        assert_eq!(unknown.change, MembershipChange::Joined);
        let left = ChatMembership::new(MembershipChange::Removed, Some("Jan"), &names(&["Jan"]));
        assert_eq!(left.change, MembershipChange::Left);
        let gone = ChatMembership::new(MembershipChange::Removed, None, &names(&["Jan"]));
        assert_eq!(gone.change, MembershipChange::Gone);
        let added = ChatMembership::new(MembershipChange::Added, Some("Ruben"), &names(&["David", " ", "David", "Anna"]));
        assert_eq!((added.change, added.by.as_deref(), added.people), (MembershipChange::Added, Some("Ruben"), names(&["David", "Anna"])));
    }

    #[test]
    fn group_change_words_and_you() {
        assert_eq!(GroupChangeKind::parse("photoRemoved"), Some(GroupChangeKind::PhotoRemoved));
        assert_eq!(GroupChangeKind::parse("nope"), None);
        let change = ChatGroupChange::new(GroupChangeKind::Renamed, Some(ME), Some(" Club "), &[]);
        assert!(change.by_me());
        assert_eq!(change.text.as_deref(), Some("Club"));
    }
}
