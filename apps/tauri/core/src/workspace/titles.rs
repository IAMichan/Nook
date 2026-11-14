//! Automatic titles for sessions (`TextGeneration.titlePrompt` and `WorkspaceManager.generateTitle` on the Mac). A new
//! session first shows the first line of its prompt ([`super::models::title_from`]); the chosen brain then writes a
//! short title from that prompt. The written title replaces the first line only while the session still has it, so a
//! title you typed meanwhile always wins. No brain, no answer or a useless one: the first line simply stays.

use serde_json::Value;

/// The system prompt for the brain: it answers with JSON only.
pub const SYSTEM: &str = "You write short titles for coding agent sessions. Answer with a JSON object only.";

fn limit(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        format!("{}…", text.chars().take(max).collect::<String>())
    }
}

/// The prompt for a title from the session's first message, with the user's own title rules when there are any.
pub fn prompt(message: &str, instructions: &str) -> String {
    let rules = instructions.trim();
    let rules = if rules.is_empty() {
        String::new()
    } else {
        format!("\nThe user's own rules for titles (follow them; the JSON format above still applies):\n{}\n", limit(rules, 2_000))
    };
    format!(
        "Generate a title that will help the user recognize this Nook session weeks later.
Return JSON with the key title.

Before answering, silently reduce the request to:
- Subject: What system, feature, or problem is this really about?
- Outcome: What does the user ultimately want to understand or change?
- Incidental instructions: What only describes how the agent should do the work?

Title the subject and outcome. Discard incidental instructions.

Editorial rules:
- 3-8 words, fewer than 40 characters.
- Write the title in the language of the user's message.
- Use a compact noun phrase or clear action phrase.
- Capture the umbrella goal when the request lists several symptoms or steps.
- Name the product change, not the mock, plan, report, branch, or PR used to produce it.
- Models, subagents, tools, output formats, and monitoring instructions do not belong in the title unless they are themselves the topic.
- For reviews, name what is being reviewed and the relevant concern.
- For research, name the question domain rather than the requested research process.
- Do not claim the work is complete.
- Do not copy and truncate the user's message.
- Avoid project names already visible in the UI, quotes, labels, filler, and trailing punctuation.
{rules}
User message:
{}",
        limit(message, 8_000)
    )
}

/// The first JSON object in a reply (a model may wrap it in a code fence or a sentence).
fn object(text: &str) -> Option<Value> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    (end > start).then(|| serde_json::from_str::<Value>(&text[start..=end]).ok()).flatten().filter(Value::is_object)
}

/// The title in a reply: the `title` of a JSON object, or the first line of plain text. One line, no quotes, single
/// spaces, at most 120 characters. `None` when nothing usable is left; then the session keeps its first line.
pub fn parse(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let text = match object(trimmed) {
        Some(o) => o.get("title").and_then(Value::as_str)?.to_string(),
        None if trimmed.starts_with('{') || trimmed.starts_with("```") => return None,
        None => trimmed.to_string(),
    };
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or_default();
    let line = line.trim_matches(|c: char| matches!(c, '\'' | '"' | '`' | '“' | '”') || c.is_whitespace());
    let line = line.trim_start_matches("Title:").trim();
    let clean = line.split_whitespace().collect::<Vec<_>>().join(" ");
    let clean = clean.trim_end_matches(['.', '!', ':']).to_string();
    if clean.is_empty() || clean.eq_ignore_ascii_case("new thread") || clean.eq_ignore_ascii_case("untitled") {
        return None;
    }
    Some(if clean.chars().count() > 120 { format!("{}...", clean.chars().take(117).collect::<String>()) } else { clean })
}

/// The title to show after the brain answered: the written one while the session still has the first line it got
/// (`seed`), otherwise nothing changes. `answer` is `None` when the brain was not reachable.
pub fn choose(seed: &str, current: &str, answer: Option<&str>) -> Option<String> {
    if current != seed {
        return None;
    }
    let title = parse(answer?)?;
    (title != current).then_some(title)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_has_the_message_and_the_users_rules() {
        let p = prompt("Fix the login on Safari", "");
        assert!(p.contains("User message:\nFix the login on Safari"));
        assert!(!p.contains("own rules"));
        let p = prompt("x", "Always start with a verb");
        assert!(p.contains("own rules for titles"));
        assert!(p.contains("Always start with a verb"));
    }

    #[test]
    fn parses_json_fences_and_plain_lines() {
        assert_eq!(parse(r#"{"title":"Safari login fix"}"#).as_deref(), Some("Safari login fix"));
        assert_eq!(parse("```json\n{\"title\": \"  Archive   button \"}\n```").as_deref(), Some("Archive button"));
        assert_eq!(parse("Sure! {\"title\":\"Dark mode toggle.\"}").as_deref(), Some("Dark mode toggle"));
        assert_eq!(parse("\"Retry flaky uploads\"\nmore text").as_deref(), Some("Retry flaky uploads"));
        assert_eq!(parse("Title: Faster search").as_deref(), Some("Faster search"));
    }

    #[test]
    fn falls_back_when_the_answer_is_useless() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("   "), None);
        assert_eq!(parse(r#"{"branch":"x"}"#), None);
        assert_eq!(parse(r#"{"title":""}"#), None);
        assert_eq!(parse("{not json"), None);
        assert_eq!(parse("New thread"), None);
        let long = "word ".repeat(40);
        assert_eq!(parse(&long).unwrap().chars().count(), 120);
    }

    #[test]
    fn a_title_you_typed_meanwhile_wins() {
        let seed = "Fix the login on Safari when the user has…";
        assert_eq!(choose(seed, seed, Some(r#"{"title":"Safari login fix"}"#)).as_deref(), Some("Safari login fix"));
        assert_eq!(choose(seed, "My own name", Some(r#"{"title":"Safari login fix"}"#)), None);
        // No brain or a useless answer: the first line stays.
        assert_eq!(choose(seed, seed, None), None);
        assert_eq!(choose(seed, seed, Some("")), None);
        assert_eq!(choose("Same", "Same", Some("Same")), None);
    }
}
