//! What "Always" would allow, as words, before you press it (`PermissionScope` on the Mac): the line under a permission
//! request's buttons, such as "Always allows Bash(git status:*) · this project".
//!
//! Each agent says it differently: Claude Code sends `permission_suggestions` (rules with a destination: this project's
//! local settings, the project's shared settings, the user's settings, or only this session); Codex and the ACP agents
//! offer a plain "session" or "always" choice and say nothing about which command it covers. The match over `Reach` is
//! exhaustive on purpose: a new kind of answer has to say what it covers.

use serde_json::Value;

use crate::i18n::{tr, trf};

/// How far an "always" reaches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// This project, only on this computer (`.claude/settings.local.json`).
    Project,
    /// Everyone who uses the project (`.claude/settings.json`, checked in).
    SharedProject,
    /// Every project of the user.
    User,
    /// Until the session ends.
    Session,
    /// The agent remembers it, and does not say where.
    AgentDecides,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// `Bash(git status:*)`, `Edit`; empty when the agent names none.
    pub text: String,
    pub reach: Reach,
}

pub fn reach(destination: Option<&str>) -> Reach {
    match destination {
        Some("localSettings") => Reach::Project,
        Some("projectSettings") => Reach::SharedProject,
        Some("userSettings") => Reach::User,
        Some("session") | Some("cliArg") => Reach::Session,
        _ => Reach::AgentDecides,
    }
}

/// The rules a request's suggestions would add. Empty when the agent offers no "always".
pub fn rules(suggestions: Option<&Value>) -> Vec<Rule> {
    let Some(list) = suggestions.and_then(Value::as_array) else { return vec![] };
    let mut out = vec![];
    for item in list {
        if let Some(word) = item.as_str() {
            out.push(Rule { text: String::new(), reach: if word == "session" { Reach::Session } else { Reach::AgentDecides } });
        } else if let Some(entry) = item.as_object() {
            let reach = reach(entry.get("destination").and_then(Value::as_str));
            for rule in entry.get("rules").and_then(Value::as_array).into_iter().flatten() {
                let Some(tool) = rule.get("toolName").and_then(Value::as_str) else { continue };
                let content = rule.get("ruleContent").and_then(Value::as_str).unwrap_or("");
                out.push(Rule { text: if content.is_empty() { tool.to_string() } else { format!("{tool}({content})") }, reach });
            }
        }
    }
    out
}

pub fn word(reach: Reach) -> &'static str {
    match reach {
        Reach::Project => tr("dit project", "this project"),
        Reach::SharedProject => tr("iedereen in dit project", "everyone on this project"),
        Reach::User => tr("al je projecten", "all your projects"),
        Reach::Session => tr("deze sessie", "this session"),
        Reach::AgentDecides => tr("zoals de agent het onthoudt", "as the agent remembers it"),
    }
}

/// "Always allows Bash(git status:*) · this project"; `None` when nothing is offered.
pub fn preview(rules: &[Rule]) -> Option<String> {
    let first = rules.first()?;
    let named: Vec<&str> = rules.iter().map(|r| r.text.as_str()).filter(|t| !t.is_empty()).collect();
    let what = if named.is_empty() {
        word(first.reach).to_string()
    } else {
        let mut shown = named.iter().take(3).copied().collect::<Vec<_>>().join(", ");
        if named.len() > 3 {
            shown.push_str(&format!(" +{}", named.len() - 3));
        }
        format!("{shown} · {}", word(first.reach))
    };
    Some(trf("Staat altijd toe: {what}", "Always allows {what}", &[("what", &what)]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn says_what_always_covers() {
        let s =
            json!([{"type": "addRules", "destination": "localSettings", "rules": [{"toolName": "Bash", "ruleContent": "git status:*"}]}]);
        assert_eq!(preview(&rules(Some(&s))).as_deref(), Some("Always allows Bash(git status:*) · this project"));
        assert_eq!(preview(&rules(Some(&json!(["session"])))).as_deref(), Some("Always allows this session"));
        assert_eq!(preview(&rules(None)), None);
    }
}
