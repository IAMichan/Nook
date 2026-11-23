//! A poll in a chat, the same for every chat app (`ChatPoll`, `ChatPollDraft`, `WAPoll` on the Mac): its question, its
//! options with how many chose each and whether you did, and whether more than one may be chosen. WhatsApp's polls and
//! the helper's (WhatsApp and Signal through nook-chatd) both come in as this; the Chats tab draws it and lets you vote
//! where the app can, and a poll you write goes out where the app takes one.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One option of a poll.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PollOption {
    pub text: String,
    #[serde(default)]
    pub votes: usize,
    #[serde(default)]
    pub chosen: bool,
    /// Who chose it, by name ("You" first); `None` where the app does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voters: Option<Vec<String>>,
}

/// One person's choice on a WhatsApp poll, kept so a later vote of theirs replaces it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ballot {
    pub name: String,
    #[serde(default)]
    pub mine: bool,
    pub choice: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatPoll {
    pub question: String,
    pub options: Vec<PollOption>,
    /// More than one option may be chosen.
    #[serde(default)]
    pub multiple: bool,
    /// The votes are not all known (a poll Nook found later, whose app keeps the votes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unknown_counts: Option<bool>,
    /// Each voter's choice by their id, for the apps that send votes one by one (WhatsApp's gateway).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub ballots: BTreeMap<String, Ballot>,
}

/// How a poll names you among its voters; the interface shows it in your language.
pub const YOU: &str = "You";

impl ChatPoll {
    pub fn new(question: &str, options: &[String], multiple: bool) -> Self {
        Self {
            question: question.to_string(),
            options: options.iter().map(|t| PollOption { text: t.clone(), votes: 0, chosen: false, voters: None }).collect(),
            multiple,
            unknown_counts: None,
            ballots: BTreeMap::new(),
        }
    }

    /// Votes cast in all, for the share of each option.
    pub fn total(&self) -> usize {
        self.options.iter().map(|o| o.votes).sum()
    }

    /// Your choice now.
    pub fn chosen(&self) -> Vec<String> {
        self.options.iter().filter(|o| o.chosen).map(|o| o.text.clone()).collect()
    }

    /// Your choice after a click on `option`: in a poll of one answer it replaces your choice (a second click takes it
    /// back), in one of more answers it is added or taken off.
    pub fn choice_after(&self, option: &str) -> Vec<String> {
        let now = self.chosen();
        if now.iter().any(|o| o == option) {
            return now.into_iter().filter(|o| o != option).collect();
        }
        if self.multiple {
            [now, vec![option.to_string()]].concat()
        } else {
            vec![option.to_string()]
        }
    }

    /// The poll with `choice` as your vote: the counts move with it at once, before the app confirms.
    pub fn voting(&self, choice: &[String]) -> Self {
        let mut poll = self.clone();
        for o in &mut poll.options {
            let (was, now) = (o.chosen, choice.contains(&o.text));
            o.chosen = now;
            o.votes = (o.votes + usize::from(now)).saturating_sub(usize::from(was));
            if let Some(voters) = &mut o.voters {
                voters.retain(|v| v != YOU);
                if now {
                    voters.insert(0, YOU.into());
                }
            }
        }
        poll
    }

    /// `voter` chose `choice` (empty: took their vote back); one choice per person, so a new vote replaces theirs. The
    /// counts and names follow from all ballots.
    pub fn apply_ballot(&mut self, voter: &str, ballot: Ballot) {
        if ballot.choice.is_empty() {
            self.ballots.remove(voter);
        } else {
            self.ballots.insert(voter.to_string(), ballot);
        }
        for o in &mut self.options {
            let mut names: Vec<(bool, String)> =
                self.ballots.values().filter(|b| b.choice.contains(&o.text)).map(|b| (b.mine, b.name.clone())).collect();
            // You first, then names alphabetically, then the ones known only by their number.
            names.sort_by(|a, b| {
                b.0.cmp(&a.0).then(a.1.starts_with('+').cmp(&b.1.starts_with('+'))).then(a.1.to_lowercase().cmp(&b.1.to_lowercase()))
            });
            o.chosen = names.iter().any(|(mine, _)| *mine);
            o.votes = names.len();
            o.voters = Some(names.into_iter().map(|(mine, n)| if mine { YOU.to_string() } else { n }).collect());
        }
    }

    /// "📊 Lunch?": a poll in one line, for a chat's line in a list and for Nook.
    pub fn line(&self) -> String {
        format!("📊 {}", self.question)
    }

    /// The poll with its options, for Nook's reading of a chat.
    pub fn text(&self) -> String {
        let mut lines = vec![self.line()];
        for o in &self.options {
            lines.push(if self.unknown_counts == Some(true) { format!("• {}", o.text) } else { format!("• {} ({})", o.text, o.votes) });
        }
        lines.join("\n")
    }

    /// GOWA's `poll: {type: "creation"|"vote", poll_id, question, options: [{name}], selectable_options_count,
    /// selected_options}`: a new poll, or a vote on one (by the poll's message id).
    pub fn gowa(value: &Value) -> (Option<ChatPoll>, Option<(String, Vec<String>)>) {
        if !value.is_object() {
            return (None, None);
        }
        let strings = |v: &Value| -> Vec<String> {
            crate::connectors::list(v).iter().filter_map(|o| o["name"].as_str().or(o.as_str())).map(str::to_string).collect()
        };
        match value["type"].as_str() {
            Some("vote") => match value["poll_id"].as_str().filter(|i| !i.is_empty()) {
                Some(id) => (None, Some((id.to_string(), strings(&value["selected_options"])))),
                None => (None, None),
            },
            Some("edit") | Some("add_option") => (None, None),
            _ => {
                let Some(question) = value["question"].as_str().or(value["name"].as_str()) else { return (None, None) };
                // 0 is "any number", 1 is one answer.
                let count = value["selectable_options_count"].as_i64().unwrap_or(1);
                (Some(ChatPoll::new(question, &strings(&value["options"]), count != 1)), None)
            }
        }
    }

    /// OpenWA's `poll: {name, options, allowMultipleAnswers}`.
    pub fn openwa(value: &Value) -> Option<ChatPoll> {
        let question = value["name"].as_str()?;
        let options: Vec<String> = crate::connectors::list(&value["options"])
            .iter()
            .filter_map(|o| o.as_str().or(o["name"].as_str()))
            .map(str::to_string)
            .collect();
        Some(ChatPoll::new(question, &options, value["allowMultipleAnswers"].as_bool() == Some(true)))
    }

    /// The helper's `type: POLL` message: `poll: {question, multiple, options: [{text, voters: [ids]}]}`, with `me` your
    /// own id there and `name` the chat's names for the others.
    pub fn helper(message: &Value, me: Option<&str>, name: &dyn Fn(&str) -> Option<String>) -> Option<ChatPoll> {
        if message["type"].as_str() != Some("POLL") {
            return None;
        }
        let poll = &message["poll"];
        let options: Vec<PollOption> = crate::connectors::list(&poll["options"])
            .iter()
            .filter_map(|o| {
                let text = o["text"].as_str().filter(|t| !t.is_empty())?;
                let ids: Vec<&str> = crate::connectors::list(&o["voters"]).iter().filter_map(Value::as_str).collect();
                let mine = me.is_some_and(|m| ids.contains(&m));
                let mut others: Vec<String> =
                    ids.iter().filter(|i| Some(**i) != me).filter_map(|i| name(i)).filter(|n| !n.is_empty()).collect();
                others.sort_by_key(|n| n.to_lowercase());
                let voters = if mine { [vec![YOU.to_string()], others].concat() } else { others };
                Some(PollOption { text: text.into(), votes: ids.len(), chosen: mine, voters: Some(voters) })
            })
            .collect();
        if options.is_empty() {
            return None;
        }
        Some(ChatPoll {
            question: poll["question"].as_str().unwrap_or("").into(),
            options,
            multiple: poll["multiple"].as_bool() == Some(true),
            unknown_counts: None,
            ballots: BTreeMap::new(),
        })
    }
}

/// A poll you are about to send (`ChatPollDraft`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PollDraft {
    pub question: String,
    pub options: Vec<String>,
    #[serde(default)]
    pub multiple: bool,
}

/// Why a poll cannot go yet (`ChatPollDraft.problem`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PollProblem {
    NoQuestion,
    QuestionTooLong,
    Duplicate,
    TooFew,
    TooMany,
    OptionTooLong,
}

impl PollDraft {
    /// What WhatsApp allows, and Telegram within it: 2 to 12 options of at most 100 characters, a question of 255.
    pub const MIN_OPTIONS: usize = 2;
    pub const MAX_OPTIONS: usize = 12;
    pub const MAX_QUESTION: usize = 255;
    pub const MAX_OPTION: usize = 100;

    /// The options as they go out: trimmed, empty ones left out, each once.
    pub fn clean_options(&self) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        self.options.iter().map(|o| o.trim().to_string()).filter(|o| !o.is_empty() && seen.insert(o.to_lowercase())).collect()
    }

    pub fn clean_question(&self) -> String {
        self.question.trim().to_string()
    }

    pub fn problem(&self) -> Option<PollProblem> {
        let question = self.clean_question();
        if question.is_empty() {
            return Some(PollProblem::NoQuestion);
        }
        if question.chars().count() > Self::MAX_QUESTION {
            return Some(PollProblem::QuestionTooLong);
        }
        let clean = self.clean_options();
        if self.options.iter().filter(|o| !o.trim().is_empty()).count() != clean.len() {
            return Some(PollProblem::Duplicate);
        }
        if clean.len() < Self::MIN_OPTIONS {
            return Some(PollProblem::TooFew);
        }
        if clean.len() > Self::MAX_OPTIONS {
            return Some(PollProblem::TooMany);
        }
        if clean.iter().any(|o| o.chars().count() > Self::MAX_OPTION) {
            return Some(PollProblem::OptionTooLong);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn poll(multiple: bool) -> ChatPoll {
        ChatPoll::new("Lunch?", &["Sushi".into(), "Pizza".into()], multiple)
    }

    #[test]
    fn a_click_picks_replaces_or_takes_back() {
        let one = poll(false).voting(&["Sushi".into()]);
        assert_eq!(one.choice_after("Pizza"), vec!["Pizza"]);
        assert!(one.choice_after("Sushi").is_empty());
        assert_eq!((one.options[0].votes, one.total()), (1, 1));
        let more = poll(true).voting(&["Sushi".into()]);
        assert_eq!(more.choice_after("Pizza"), vec!["Sushi", "Pizza"]);
        let back = one.voting(&[]);
        assert_eq!(back.total(), 0);
    }

    #[test]
    fn whatsapp_ballots_replace_each_other() {
        let mut p = poll(false);
        p.apply_ballot("1@s", Ballot { name: "Bea".into(), mine: false, choice: vec!["Sushi".into()] });
        p.apply_ballot("me", Ballot { name: String::new(), mine: true, choice: vec!["Sushi".into()] });
        p.apply_ballot("2@s", Ballot { name: "+316".into(), mine: false, choice: vec!["Sushi".into()] });
        p.apply_ballot("3@s", Ballot { name: "Ann".into(), mine: false, choice: vec!["Pizza".into()] });
        assert_eq!(p.options[0].voters.as_deref(), Some(&["You".to_string(), "Bea".into(), "+316".into()][..]));
        assert!(p.options[0].chosen);
        // Bea changes her mind, Ann takes hers back.
        p.apply_ballot("1@s", Ballot { name: "Bea".into(), mine: false, choice: vec!["Pizza".into()] });
        p.apply_ballot("3@s", Ballot { name: "Ann".into(), mine: false, choice: vec![] });
        assert_eq!((p.options[0].votes, p.options[1].votes), (2, 1));
        assert_eq!(p.text(), "📊 Lunch?\n• Sushi (2)\n• Pizza (1)");
    }

    #[test]
    fn the_gateways_and_the_helper_say_polls_their_own_way() {
        let (made, _) = ChatPoll::gowa(
            &json!({"type": "creation", "question": "Q", "options": [{"name": "A"}, {"name": "B"}], "selectable_options_count": 0}),
        );
        let made = made.unwrap();
        assert!(made.multiple && made.options.len() == 2);
        let (_, vote) = ChatPoll::gowa(&json!({"type": "vote", "poll_id": "P1", "selected_options": ["A"]}));
        assert_eq!(vote, Some(("P1".into(), vec!["A".into()])));
        assert_eq!(ChatPoll::gowa(&json!({"type": "edit"})), (None, None));
        assert!(!ChatPoll::openwa(&json!({"name": "Q", "options": ["A", "B"]})).unwrap().multiple);
        let names = |id: &str| (id == "u2").then(|| "Zoe".to_string());
        let helper = ChatPoll::helper(
            &json!({"type": "POLL", "poll": {"question": "Q", "options": [{"text": "A", "voters": ["me", "u2"]}, {"text": "B"}]}}),
            Some("me"),
            &names,
        )
        .unwrap();
        assert_eq!(helper.options[0].voters.as_deref(), Some(&["You".to_string(), "Zoe".into()][..]));
        assert!(helper.options[0].chosen && helper.options[0].votes == 2);
    }

    #[test]
    fn a_draft_needs_a_question_and_two_different_options() {
        let mut d = PollDraft { question: " ".into(), options: vec!["A".into(), "".into()], multiple: false };
        assert_eq!(d.problem(), Some(PollProblem::NoQuestion));
        d.question = "Lunch?".into();
        assert_eq!(d.problem(), Some(PollProblem::TooFew));
        d.options = vec!["A".into(), "a ".into()];
        assert_eq!(d.problem(), Some(PollProblem::Duplicate));
        d.options = vec!["A".into(), "B".into(), "".into()];
        assert_eq!(d.problem(), None);
        assert_eq!(d.clean_options(), vec!["A", "B"]);
    }
}
