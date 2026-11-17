//! A short title for a Nook, written by the chosen brain after its first answer, in place of the first words of the
//! question the list shows until then (`Conversation::title_from`). Port of the Mac's `ConversationTitle`.

/// The longest title kept, in characters; a longer answer is not a title.
pub const MAX_LENGTH: usize = 48;

pub const SYSTEM: &str = "You name conversations for a list. Reply with only a title of two to five words that says what the conversation is about, so the user recognizes it weeks later. Write it in the language of the user's message. Name the subject (a person, a thing, a task), not the request: \"Offer from Infaris\", not \"Can you check the mail\". No quotes, no final period, no emoji, nothing else.";

/// The question and the start of the answer, enough to see what the conversation is about.
pub fn prompt(question: &str, answer: &str) -> String {
    let question: String = question.chars().take(1_500).collect();
    let answer: String = answer.chars().take(1_000).collect();
    format!("User message:\n{question}\n\nAnswer:\n{answer}")
}

/// The title in the brain's reply: its first line, without quotes, a label ("Title:"), markdown or a final period.
/// `None` when nothing usable is left or it is too long to be a title.
pub fn clean(reply: &str) -> Option<String> {
    let mut line = reply.lines().map(str::trim).find(|l| !l.is_empty())?.to_string();
    if let Some(colon) = line.find(':') {
        let label = line[..colon].trim().to_lowercase();
        if !label.contains(' ') && ["title", "titel", "titre", "título"].contains(&label.as_str()) {
            line = line[colon + 1..].to_string();
        }
    }
    let line = line.trim_matches(|c: char| c.is_whitespace() || "\"'“”‘’«»*_#`.".contains(c));
    if line.is_empty() || line.chars().count() > MAX_LENGTH {
        return None;
    }
    let mut chars = line.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().collect::<String>() + chars.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_reply_becomes_a_clean_title() {
        assert_eq!(clean("Offer from Infaris").as_deref(), Some("Offer from Infaris"));
        assert_eq!(clean("\n  \"offerte van Infaris\".\nmore").as_deref(), Some("Offerte van Infaris"));
        assert_eq!(clean("Title: **Trip to Lisbon**").as_deref(), Some("Trip to Lisbon"));
        assert_eq!(clean("Titel: Belasting 2026").as_deref(), Some("Belasting 2026"));
        assert_eq!(clean("Meeting: budget").as_deref(), Some("Meeting: budget"), "only a title label goes");
        assert_eq!(clean("  "), None);
        assert_eq!(clean(&"word ".repeat(20)), None, "too long to be a title");
    }

    #[test]
    fn the_prompt_is_capped() {
        let prompt = prompt(&"q".repeat(3_000), &"a".repeat(3_000));
        assert_eq!(prompt.matches('q').count(), 1_500);
        assert!(prompt.matches('a').count() <= 1_002, "the answer's start only");
    }
}
