//! What a chat's app says about the chat itself besides its messages (`ChatProfile` on the Mac), shown in the chat's
//! info: a group's description and admins, how long messages last; a person's number, address, username. Every field is
//! `None` while the app does not say it. Also the groups you share with a person (`ChatCommonGroups`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::inbox::InboxThread;
use super::membership::ME;
use super::ChatKind;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatProfile {
    /// A group's description or topic; a person's bio, status or "about" line.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    /// The group's admins by name, [`ME`] for you.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub admins: Option<Vec<String>>,
    /// Messages disappear after this many seconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disappear_after: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phone: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    /// The other person is a bot.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub bot: bool,
}

fn text(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

impl ChatProfile {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// What the helper's chat says (`ChatServiceData.profile`): its description and how long messages last; a group's
    /// admins; in a private chat the other person's number, address, username and whether they are a bot.
    pub fn helper(chat: &Value, people: &[Value], is_group: bool) -> Option<Self> {
        let mut profile = ChatProfile { about: text(chat.get("description")), ..Default::default() };
        let seconds = chat.get("disappearAfter").and_then(|v| v.as_u64().or_else(|| v.as_f64().map(|f| f.max(0.0) as u64))).unwrap_or(0);
        if seconds > 0 {
            profile.disappear_after = Some(seconds);
        }
        let is_self = |p: &Value| p.get("isSelf").and_then(Value::as_bool) == Some(true);
        if is_group {
            let admins: Vec<String> = people
                .iter()
                .filter(|p| p.get("isAdmin").and_then(Value::as_bool) == Some(true))
                .filter_map(|p| if is_self(p) { Some(ME.to_string()) } else { text(p.get("fullName")) })
                .collect();
            if !admins.is_empty() {
                profile.admins = Some(admins);
            }
        } else if let Some(other) = people.iter().find(|p| !is_self(p)) {
            for identifier in other.get("identifiers").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
                if let Some(phone) = identifier.strip_prefix("tel:") {
                    profile.phone.get_or_insert_with(|| phone.to_string());
                } else if let Some(email) = identifier.strip_prefix("mailto:") {
                    profile.email.get_or_insert_with(|| email.to_string());
                } else if let Some((_, name)) = identifier.split_once(':') {
                    // "instagram:anna.b", "x:anna": the username they go by on the network.
                    if !name.is_empty() && !name.chars().all(|c| c.is_ascii_digit()) && profile.username.is_none() {
                        profile.username = Some(format!("@{name}"));
                    }
                }
            }
            profile.bot = other.get("isBot").and_then(Value::as_bool) == Some(true);
        }
        (!profile.is_empty()).then_some(profile)
    }
}

fn fold(text: &str) -> String {
    text.trim().to_lowercase()
}

/// The groups of `app` whose people include `name`, newest first (`ChatCommonGroups.groups`).
pub fn common_groups<'a>(name: &str, app: &str, threads: impl IntoIterator<Item = &'a InboxThread>) -> Vec<&'a InboxThread> {
    let wanted = fold(name);
    if wanted.is_empty() {
        return vec![];
    }
    let mut shared: Vec<&InboxThread> = threads
        .into_iter()
        .filter(|t| t.app == app && (t.is_group() || t.kind == Some(ChatKind::Group)))
        .filter(|t| t.members.as_ref().is_some_and(|members| members.iter().any(|m| fold(m) == wanted)))
        .collect();
    shared.sort_by_key(|t| std::cmp::Reverse(t.activity.or_else(|| t.messages.last().map(|m| m.date))));
    shared
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_group_says_its_description_admins_and_timer() {
        let people = vec![
            json!({"fullName": "Anna", "isAdmin": true}),
            json!({"fullName": "Me", "isAdmin": true, "isSelf": true}),
            json!({"fullName": "Bo"}),
        ];
        let chat = json!({"description": "  Club news ", "disappearAfter": 604800});
        let profile = ChatProfile::helper(&chat, &people, true).unwrap();
        assert_eq!(profile.about.as_deref(), Some("Club news"));
        assert_eq!(profile.admins, Some(vec!["Anna".to_string(), ME.to_string()]));
        assert_eq!(profile.disappear_after, Some(604800));
    }

    #[test]
    fn a_person_says_number_address_username_and_bot() {
        let people = vec![
            json!({"isSelf": true, "identifiers": ["tel:+3100"]}),
            json!({"identifiers": ["tel:+31612345678", "mailto:a@b.nl", "instagram:anna.b", "x:12345"], "isBot": true}),
        ];
        let profile = ChatProfile::helper(&json!({}), &people, false).unwrap();
        assert_eq!(profile.phone.as_deref(), Some("+31612345678"));
        assert_eq!(profile.email.as_deref(), Some("a@b.nl"));
        assert_eq!(profile.username.as_deref(), Some("@anna.b"));
        assert!(profile.bot);
        assert!(ChatProfile::helper(&json!({}), &[], false).is_none());
    }

    #[test]
    fn common_groups_are_the_groups_of_the_app_with_that_person() {
        let mut group = InboxThread::new("a", "telegram", "Club");
        group.kind = Some(ChatKind::Group);
        group.members = Some(vec!["Anna".into(), "Bo".into()]);
        let mut other_app = InboxThread::new("b", "signal", "Club");
        other_app.kind = Some(ChatKind::Group);
        other_app.members = Some(vec!["Anna".into()]);
        let mut private = InboxThread::new("c", "telegram", "Anna");
        private.kind = Some(ChatKind::Person);
        private.members = Some(vec!["Anna".into()]);
        let all = [group, other_app, private];
        let found = common_groups(" anna ", "telegram", all.iter());
        assert_eq!(found.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["a"]);
        assert!(common_groups("", "telegram", all.iter()).is_empty());
    }
}
