//! Settings › Instructions beyond the answer style (`PromptLibrary`, `NookSpace`, `ContextBreakdown` on the Mac): the
//! prompts the user saved, with `{{variables}}` and a `/trigger`; spaces, whose instructions go with every
//! conversation filed in them; and what the model read for the last answer, part by part with its size. Kept in
//! `prompts.json` and `spaces.json` in Nook's folder; a file that cannot be read is kept aside before it is replaced.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use uuid::Uuid;

fn now() -> DateTime<Utc> {
    Utc::now()
}

/// One saved prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedPrompt {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    pub title: String,
    pub body: String,
    /// Lowercase letters, digits, `-` and `_`, without the slash; empty for a prompt that has no trigger.
    #[serde(default)]
    pub trigger: String,
    #[serde(default = "now")]
    pub updated_at: DateTime<Utc>,
}

/// A `{{name}}` or `{{name|default}}` in a prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Variable {
    pub name: String,
    pub default_value: String,
}

fn variable_pattern() -> &'static regex::Regex {
    static PATTERN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    PATTERN.get_or_init(|| regex::Regex::new(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|([^}]*))?\}\}").expect("valid pattern"))
}

impl SavedPrompt {
    pub fn new(title: &str, body: &str, trigger: &str) -> Self {
        Self { id: Uuid::new_v4(), title: title.into(), body: body.into(), trigger: trigger.into(), updated_at: now() }
    }

    /// The variables in the body, in the order they first appear.
    pub fn variables(&self) -> Vec<Variable> {
        let mut seen = HashSet::new();
        variable_pattern()
            .captures_iter(&self.body)
            .filter_map(|c| {
                let name = c.get(1)?.as_str().to_string();
                seen.insert(name.clone()).then(|| Variable { name, default_value: c.get(2).map_or("", |m| m.as_str()).into() })
            })
            .collect()
    }

    /// The body with each variable replaced by its value; one without a value gets its default, else stays empty.
    pub fn render(&self, values: &BTreeMap<String, String>) -> String {
        variable_pattern()
            .replace_all(&self.body, |c: &regex::Captures<'_>| {
                let name = &c[1];
                values.get(name).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| c.get(2).map_or("", |m| m.as_str()).into())
            })
            .into_owned()
    }

    /// A trigger as typed: the slash and anything but letters, digits, `-` and `_` taken out, lowercased.
    pub fn clean_trigger(raw: &str) -> String {
        raw.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_').collect()
    }
}

/// Reads a list entry by entry: one that cannot be read is left out instead of losing the whole file.
fn lossy<'de, D: Deserializer<'de>, T: serde::de::DeserializeOwned>(d: D) -> Result<Vec<T>, D::Error> {
    let raw = Option::<Vec<Value>>::deserialize(d)?.unwrap_or_default();
    Ok(raw.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect())
}

/// The prompts the user saved, newest edit first.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptLibrary {
    #[serde(default, deserialize_with = "lossy")]
    pub prompts: Vec<SavedPrompt>,
}

impl PromptLibrary {
    /// Adds or replaces a prompt. A trigger another prompt already has is dropped from the new one (a trigger names one
    /// prompt); a prompt with no words in it is not saved. Returns whether it was kept.
    pub fn save(&mut self, prompt: SavedPrompt) -> bool {
        let mut prompt = prompt;
        prompt.title = prompt.title.trim().into();
        prompt.body = prompt.body.trim().into();
        if prompt.title.is_empty() || prompt.body.is_empty() {
            return false;
        }
        prompt.trigger = SavedPrompt::clean_trigger(&prompt.trigger);
        if !prompt.trigger.is_empty() && self.prompts.iter().any(|p| p.trigger == prompt.trigger && p.id != prompt.id) {
            prompt.trigger.clear();
        }
        prompt.updated_at = now();
        self.prompts.retain(|p| p.id != prompt.id);
        self.prompts.insert(0, prompt);
        true
    }

    pub fn remove(&mut self, id: Uuid) {
        self.prompts.retain(|p| p.id != id);
    }

    pub fn prompt(&self, trigger: &str) -> Option<&SavedPrompt> {
        let wanted = SavedPrompt::clean_trigger(trigger);
        (!wanted.is_empty()).then(|| self.prompts.iter().find(|p| p.trigger == wanted)).flatten()
    }

    /// The prompts a typed word offers: a trigger that starts with it first, then a title or body that contains it.
    pub fn matches(&self, query: &str) -> Vec<&SavedPrompt> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return self.prompts.iter().collect();
        }
        let bare = SavedPrompt::clean_trigger(&q);
        let by_trigger: Vec<&SavedPrompt> = self.prompts.iter().filter(|p| !p.trigger.is_empty() && p.trigger.starts_with(&bare)).collect();
        let rest = self.prompts.iter().filter(|p| {
            !by_trigger.iter().any(|b| b.id == p.id) && (p.title.to_lowercase().contains(&q) || p.body.to_lowercase().contains(&q))
        });
        by_trigger.iter().copied().chain(rest).collect()
    }
}

/// A space: instructions that go with every Nook conversation filed in it ("Taxes 2026", "Garden project"). Not a
/// coding project. Attached files are paths on this computer, never copied.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NookSpace {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    pub name: String,
    #[serde(default)]
    pub instructions: String,
    #[serde(default)]
    pub attachments: Vec<String>,
    #[serde(default = "now")]
    pub created_at: DateTime<Utc>,
}

impl NookSpace {
    pub fn new(name: &str) -> Self {
        Self { id: Uuid::new_v4(), name: name.into(), instructions: String::new(), attachments: vec![], created_at: now() }
    }

    /// The instruction block for the model, empty when the space has none.
    pub fn context_text(&self) -> String {
        let text = self.instructions.trim();
        if text.is_empty() {
            return String::new();
        }
        format!("Instructions of the space \"{}\" (written by the user; follow them):\n{text}", self.name)
    }
}

/// The user's spaces and which conversation is filed in which.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NookSpaceBook {
    #[serde(default, deserialize_with = "lossy")]
    pub spaces: Vec<NookSpace>,
    /// Conversation id to space id.
    #[serde(default)]
    pub membership: BTreeMap<String, Uuid>,
}

impl NookSpaceBook {
    pub fn save(&mut self, space: NookSpace) {
        let mut space = space;
        space.name = space.name.trim().into();
        if space.name.is_empty() {
            return;
        }
        match self.spaces.iter_mut().find(|s| s.id == space.id) {
            Some(slot) => *slot = space,
            None => self.spaces.push(space),
        }
    }

    pub fn remove(&mut self, id: Uuid) {
        self.spaces.retain(|s| s.id != id);
        self.membership.retain(|_, space| *space != id);
    }

    /// Files a conversation in a space; `None` (or a space that is gone) takes it out of any space.
    pub fn assign(&mut self, conversation: &str, space: Option<Uuid>) {
        match space.filter(|s| self.spaces.iter().any(|x| x.id == *s)) {
            Some(space) => {
                self.membership.insert(conversation.into(), space);
            }
            None => {
                self.membership.remove(conversation);
            }
        }
    }

    pub fn space_of(&self, conversation: &str) -> Option<&NookSpace> {
        self.membership.get(conversation).and_then(|id| self.spaces.iter().find(|s| s.id == *id))
    }

    pub fn conversations_in(&self, space: Uuid) -> usize {
        self.membership.values().filter(|s| **s == space).count()
    }
}

/// Reads a JSON file; one that is there but cannot be read is kept aside (`.unreadable.json`) so the next save never
/// takes the user's data with it.
pub fn load<T: serde::de::DeserializeOwned + Default>(file: &Path) -> T {
    let Ok(text) = std::fs::read_to_string(file) else { return T::default() };
    match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(_) => {
            let _ = std::fs::copy(file, file.with_extension("unreadable.json"));
            T::default()
        }
    }
}

pub fn save<T: Serialize>(value: &T, file: &Path) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let text = serde_json::to_string_pretty(value).map_err(std::io::Error::other)?;
    let temp = file.with_extension("json.tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(temp, file)
}

/// The kinds of part the inspector shows, in the order the model reads them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PartKind {
    Style,
    Space,
    Memory,
    LookedUp,
    Overview,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextPart {
    pub kind: PartKind,
    pub text: String,
    pub tokens: usize,
}

/// What goes into the model for one answer, part by part, with its size.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextBreakdown {
    pub parts: Vec<ContextPart>,
    /// The model's window in tokens; 0 when unknown.
    pub budget: usize,
    pub total_tokens: usize,
    /// Percent of the window used; `None` when the window is unknown.
    pub fill: Option<u32>,
}

/// About four characters to a token for Latin text; a rough size, said as an estimate everywhere it is shown.
pub fn estimate_tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

impl ContextBreakdown {
    /// Parts with something in them only. `overview` is the whole context; the memory and what was looked up are taken
    /// out of it so nothing is counted twice.
    pub fn new(style: &str, space: &str, memory: &str, looked_up: &[String], context: &str, budget: usize) -> Self {
        let mut overview = context.to_string();
        for piece in std::iter::once(memory).chain(looked_up.iter().map(String::as_str)).filter(|p| !p.is_empty()) {
            overview = overview.replace(piece, "");
        }
        let looked = looked_up.join("\n\n");
        let parts: Vec<ContextPart> = [
            (PartKind::Style, style),
            (PartKind::Space, space),
            (PartKind::Memory, memory),
            (PartKind::LookedUp, looked.as_str()),
            (PartKind::Overview, overview.trim()),
        ]
        .into_iter()
        .filter(|(_, text)| !text.trim().is_empty())
        .map(|(kind, text)| ContextPart { kind, text: text.into(), tokens: estimate_tokens(text) })
        .collect();
        let total_tokens = parts.iter().map(|p| p.tokens).sum();
        let fill = (budget > 0).then(|| ((total_tokens as f64 / budget as f64).min(1.0) * 100.0).round() as u32);
        Self { parts, budget, total_tokens, fill }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variables_and_their_defaults_fill_in() {
        let prompt = SavedPrompt::new("Mail", "Write to {{ name }} about {{topic}} in a {{tone|friendly}} tone. {{name}}!", "");
        let names: Vec<String> = prompt.variables().into_iter().map(|v| format!("{}={}", v.name, v.default_value)).collect();
        assert_eq!(names, ["name=", "topic=", "tone=friendly"]);
        let values = BTreeMap::from([("name".to_string(), "Lisa".to_string()), ("topic".to_string(), String::new())]);
        assert_eq!(prompt.render(&values), "Write to Lisa about  in a friendly tone. Lisa!");
    }

    #[test]
    fn a_trigger_names_one_prompt() {
        let mut library = PromptLibrary::default();
        assert!(library.save(SavedPrompt::new(" Standup ", "What did I do yesterday?", "/Stand Up!")));
        assert_eq!(library.prompts[0].trigger, "standup");
        assert_eq!(library.prompts[0].title, "Standup");
        assert!(library.save(SavedPrompt::new("Other", "x", "standup")));
        assert_eq!(library.prompts[0].trigger, "", "the trigger stays with the first prompt");
        assert!(!library.save(SavedPrompt::new("Empty", "   ", "")));
        assert_eq!(library.prompt("/STANDUP").unwrap().title, "Standup");
        assert_eq!(library.matches("stan")[0].title, "Standup");
        assert_eq!(library.matches("x").len(), 1);
        let id = library.prompts[1].id;
        library.remove(id);
        assert_eq!(library.prompts.len(), 1);
    }

    #[test]
    fn a_space_files_conversations_and_gives_its_instructions() {
        let mut book = NookSpaceBook::default();
        let mut space = NookSpace::new(" Taxes 2026 ");
        space.instructions = "Answer in Dutch.".into();
        let id = space.id;
        book.save(space);
        book.save(NookSpace::new("   "));
        assert_eq!(book.spaces.len(), 1);
        book.assign("c1", Some(id));
        book.assign("c2", Some(Uuid::new_v4()));
        assert_eq!(book.conversations_in(id), 1);
        assert!(book.space_of("c1").unwrap().context_text().starts_with("Instructions of the space \"Taxes 2026\""));
        assert!(book.space_of("c2").is_none());
        book.remove(id);
        assert!(book.membership.is_empty());
    }

    #[test]
    fn unreadable_entries_are_skipped_not_the_whole_file() {
        let library: PromptLibrary =
            serde_json::from_value(serde_json::json!({"prompts": [{"title": "A", "body": "b"}, {"nope": 1}]})).unwrap();
        assert_eq!(library.prompts.len(), 1);
        let dir = std::env::temp_dir().join(format!("nook-prompts-{}", Uuid::new_v4()));
        let file = dir.join("prompts.json");
        save(&library, &file).unwrap();
        assert_eq!(load::<PromptLibrary>(&file), library);
        std::fs::write(&file, "not json").unwrap();
        assert_eq!(load::<PromptLibrary>(&file), PromptLibrary::default());
        assert!(file.with_extension("unreadable.json").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_breakdown_counts_each_part_once() {
        let memory = "What Nook remembers:\n- Sam likes tea";
        let looked = vec!["Mail from Lisa: the offer".to_string()];
        let context = format!("Now: Tuesday\n\n{memory}\n\n{}\n\nSources: mail", looked[0]);
        let breakdown = ContextBreakdown::new("Answer style chosen by the user: concise", "", memory, &looked, &context, 100);
        let kinds: Vec<PartKind> = breakdown.parts.iter().map(|p| p.kind).collect();
        assert_eq!(kinds, [PartKind::Style, PartKind::Memory, PartKind::LookedUp, PartKind::Overview]);
        assert!(!breakdown.parts[3].text.contains("Sam likes tea"));
        assert_eq!(breakdown.total_tokens, breakdown.parts.iter().map(|p| p.tokens).sum::<usize>());
        assert!(breakdown.fill.is_some());
        assert_eq!(ContextBreakdown::new("", "", "", &[], "", 0).fill, None);
        assert_eq!(estimate_tokens("abcde"), 2);
    }
}
