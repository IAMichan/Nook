//! Saved prompts (`SavedPrompt` and `PromptLibrary` on the Mac): a title, a body that may hold `{{variables}}`, and an
//! optional trigger typed in the composer (`/summarize`). `{{name}}` is asked for when the prompt is used;
//! `{{name|default}}` starts with a default. Kept in `prompts.json` in Nook's folder, newest edit first.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedPrompt {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    pub title: String,
    pub body: String,
    /// Lowercase letters, digits, `-` and `_`, without the slash; empty for a prompt without a trigger.
    #[serde(default)]
    pub trigger: String,
    #[serde(default = "Utc::now")]
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Variable {
    pub name: String,
    pub default_value: String,
}

static PATTERN: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|([^}]*))?\}\}").unwrap());

impl SavedPrompt {
    /// The variables in the body, in the order they first appear; the same name used twice is asked once.
    pub fn variables(&self) -> Vec<Variable> {
        let mut out: Vec<Variable> = vec![];
        for c in PATTERN.captures_iter(&self.body) {
            let name = c[1].to_string();
            if !out.iter().any(|v| v.name == name) {
                out.push(Variable { name, default_value: c.get(2).map_or("", |m| m.as_str()).to_string() });
            }
        }
        out
    }

    /// The body with each variable replaced by its value; one without a value gets its default, else stays empty.
    pub fn render(&self, values: &std::collections::HashMap<String, String>) -> String {
        PATTERN
            .replace_all(&self.body, |c: &regex::Captures| {
                values.get(&c[1]).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| c.get(2).map_or("", |m| m.as_str()).to_string())
            })
            .into_owned()
    }

    /// A trigger as typed: the slash and anything but letters, digits, `-` and `_` taken out, lowercased.
    pub fn clean_trigger(raw: &str) -> String {
        raw.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_').collect()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PromptLibrary {
    #[serde(default)]
    pub prompts: Vec<SavedPrompt>,
}

impl PromptLibrary {
    /// Adds or replaces a prompt. A trigger another prompt already has is dropped from the new one; a prompt with no
    /// words is not saved. Returns whether it was kept.
    pub fn save(&mut self, mut prompt: SavedPrompt) -> bool {
        prompt.title = prompt.title.trim().to_string();
        prompt.body = prompt.body.trim().to_string();
        if prompt.title.is_empty() || prompt.body.is_empty() {
            return false;
        }
        prompt.trigger = SavedPrompt::clean_trigger(&prompt.trigger);
        if !prompt.trigger.is_empty() && self.prompts.iter().any(|p| p.trigger == prompt.trigger && p.id != prompt.id) {
            prompt.trigger.clear();
        }
        prompt.updated_at = Utc::now();
        self.prompts.retain(|p| p.id != prompt.id);
        self.prompts.insert(0, prompt);
        true
    }

    pub fn remove(&mut self, id: Uuid) {
        self.prompts.retain(|p| p.id != id);
    }

    /// One that cannot be read is left out; an unreadable file gives an empty library and is kept aside.
    pub fn load(file: &Path) -> Self {
        let Ok(bytes) = std::fs::read(file) else { return Self::default() };
        #[derive(Deserialize)]
        struct Stored {
            #[serde(default)]
            prompts: Vec<serde_json::Value>,
        }
        match serde_json::from_slice::<Stored>(&bytes) {
            Ok(s) => Self { prompts: s.prompts.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect() },
            Err(_) => {
                let _ = std::fs::copy(file, file.with_extension("json.unreadable"));
                Self::default()
            }
        }
    }

    pub fn save_to(&self, file: &Path) -> std::io::Result<()> {
        crate::paths::write_atomic(file, &serde_json::to_vec_pretty(self).unwrap_or_default())
    }

    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("prompts.json")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(title: &str, body: &str, trigger: &str) -> SavedPrompt {
        SavedPrompt { id: Uuid::new_v4(), title: title.into(), body: body.into(), trigger: trigger.into(), updated_at: Utc::now() }
    }

    #[test]
    fn fills_variables_with_values_or_defaults() {
        let prompt = p("Review", "Review {{file}} for {{focus|bugs}}; then {{file}} again.", "");
        assert_eq!(
            prompt.variables().iter().map(|v| (v.name.as_str(), v.default_value.as_str())).collect::<Vec<_>>(),
            vec![("file", ""), ("focus", "bugs")]
        );
        let values = [("file".to_string(), "a.rs".to_string())].into_iter().collect();
        assert_eq!(prompt.render(&values), "Review a.rs for bugs; then a.rs again.");
    }

    #[test]
    fn a_trigger_names_one_prompt() {
        let mut lib = PromptLibrary::default();
        assert!(lib.save(p("One", "first", "/Sum Up!")));
        assert_eq!(lib.prompts[0].trigger, "sumup");
        assert!(lib.save(p("Two", "second", "sumup")));
        assert_eq!(lib.prompts[0].trigger, "", "taken by the first");
        assert!(!lib.save(p(" ", "x", "")));
    }
}
