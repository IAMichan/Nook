//! A suggestion on screen and how it is made, shown and accepted. Ported from `CompletionSuggestion.swift`
//! (`CompletionSuggestion`, `CompletionPolicy`, `CompletionOptions`, `CompletionResult`, `CompletionStreaming`).

use serde::{Deserialize, Serialize};

/// Marks that close what is being written. Only these after the cursor still count as the end of the line: editing a
/// sentence before its period, or the words inside brackets or quotes, gets suggestions without `mid_line`.
pub const CLOSING: [char; 15] = ['.', ',', '!', '?', ';', ':', '…', ')', ']', '}', '"', '\'', '”', '’', '»'];

const SENTENCE_MARKS: &str = ".!?;:…";

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

/// Number of whitespace-separated words.
pub fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

/// How a key takes words from a suggestion.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AcceptOptions {
    /// Taking a word also takes the space after it.
    pub trailing_space: bool,
    /// Punctuation stuck to a word ("there,") comes with it. Off: the word first, its punctuation with the next press.
    pub attached_punctuation: bool,
}

/// A suggestion on screen: the text that would be typed at the cursor. It shrinks as words are accepted or typed through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletionSuggestion {
    remaining: String,
}

impl CompletionSuggestion {
    pub fn new(text: impl Into<String>) -> Self {
        Self { remaining: text.into() }
    }

    pub fn remaining(&self) -> &str {
        &self.remaining
    }

    pub fn is_empty(&self) -> bool {
        self.remaining.is_empty()
    }

    /// The model's answer as a suggestion, or `None` when nothing worth showing is left.
    ///
    /// - `before`: the text before the cursor.
    /// - `after`: the rest of the line after the cursor: a suggestion that runs into it stops where it starts.
    /// - `truncated`: the model hit its token limit, so the last word may be cut off; it is dropped unless it is the only one.
    /// - `unfinished`: the model stopped in the middle of a word (it was no longer sure how it goes on): that word is always
    ///   dropped, a half word is never shown.
    pub fn make(raw: &str, before: &str, after: &str, max_words: usize, truncated: bool, unfinished: bool) -> Option<Self> {
        let replaced = raw.replace('\t', " ");
        let line: &str = match replaced.find(is_newline) {
            Some(i) => &replaced[..i],
            None => &replaced,
        };
        let mut text: String = line.chars().filter(|c| !c.is_control()).collect();
        if before.chars().last().is_none_or(|c| c.is_whitespace()) {
            text = text.trim_start().to_string();
        }
        let ends_in_space = text.chars().last().is_some_and(|c| c.is_whitespace());
        let mut parts = chunks(&text);
        let cut_off = (unfinished && !parts.is_empty()) || (truncated && parts.len() > 1);
        if cut_off && !ends_in_space {
            parts.pop();
        }
        let mut result: String = parts.into_iter().take(max_words).collect();
        result = overlap_trimmed(&result, after);
        result = punctuation_trimmed(&result, after);
        let trimmed_len = result.trim_end().len();
        result.truncate(trimmed_len);
        if !result.chars().any(|c| !c.is_whitespace()) || repeats(&result, before) {
            return None;
        }
        Some(Self { remaining: result })
    }

    /// The next word with the whitespace before it. Without attached punctuation only the marks at the end of a word wait
    /// ("there" then ","); inside it ("3.5", "nook.app") they stay, and punctuation on its own ("...") is one chunk.
    pub fn next_chunk(&self, options: AcceptOptions) -> String {
        let Some(first) = chunks(&self.remaining).into_iter().next() else { return String::new() };
        let mut chunk = first.to_string();
        if !options.attached_punctuation {
            if let Some((index, c)) = chunk.char_indices().rfind(|(_, c)| is_word_char(*c)) {
                chunk.truncate(index + c.len_utf8());
            }
        }
        if options.trailing_space && self.remaining[chunk.len()..].starts_with(' ') {
            chunk.push(' ');
        }
        chunk
    }

    pub fn accept_next_chunk(&mut self, options: AcceptOptions) -> String {
        let chunk = self.next_chunk(options);
        self.remaining.drain(..chunk.len());
        chunk
    }

    /// Punctuation right at the start, stuck to the word before it (". Then" or "!"), taken off; `None` when there is none.
    pub fn take_attached_punctuation(&mut self) -> Option<String> {
        let mark_len: usize = self.remaining.chars().take_while(|c| ".,!?;:…".contains(*c)).map(char::len_utf8).sum();
        if mark_len == 0 {
            return None;
        }
        if !self.remaining[mark_len..].chars().next().is_none_or(char::is_whitespace) {
            return None;
        }
        let mark: String = self.remaining.drain(..mark_len).collect();
        if self.remaining.chars().all(char::is_whitespace) {
            self.remaining.clear();
        }
        Some(mark)
    }

    pub fn accept_all(&mut self) -> String {
        std::mem::take(&mut self.remaining)
    }

    /// The user typed `typed` themselves: if it is how the suggestion goes on, the suggestion stays (typing through).
    pub fn consume(&mut self, typed: &str) -> bool {
        if typed.is_empty() || !self.remaining.starts_with(typed) {
            return false;
        }
        self.remaining.drain(..typed.len());
        true
    }
}

/// `whitespace* non-whitespace+` pieces; trailing whitespace is dropped.
pub fn chunks(text: &str) -> Vec<&str> {
    let mut result = Vec::new();
    let mut iter = text.char_indices().peekable();
    while let Some(&(start, _)) = iter.peek() {
        while iter.peek().is_some_and(|(_, c)| c.is_whitespace()) {
            iter.next();
        }
        if iter.peek().is_none() {
            break;
        }
        while iter.peek().is_some_and(|(_, c)| !c.is_whitespace()) {
            iter.next();
        }
        let end = iter.peek().map(|(i, _)| *i).unwrap_or(text.len());
        result.push(&text[start..end]);
    }
    result
}

/// A model that is lost tends to copy what was just written. Three words or more that already stand in the last lines
/// before the cursor are not a suggestion.
pub fn repeats(text: &str, before: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() < 3 {
        return false;
    }
    let tail: String = {
        let count = before.chars().count();
        before.chars().skip(count.saturating_sub(300)).collect()
    };
    tail.to_lowercase().contains(&words.join(" ").to_lowercase())
}

/// Mid-line: when the suggestion runs into the words already after the cursor, keep only what comes before them.
pub fn overlap_trimmed(text: &str, after: &str) -> String {
    let rest = after.trim_matches(|c: char| c == ' ' || c == '\t').to_lowercase();
    if rest.chars().count() < 2 {
        return text.to_string();
    }
    let mut previous: Option<char> = None;
    for (index, c) in text.char_indices() {
        let starts_word = !c.is_whitespace() && previous.is_none_or(char::is_whitespace);
        previous = Some(c);
        if !starts_word {
            continue;
        }
        let tail = text[index..].trim_matches(|c: char| c == ' ' || c == '\t').to_lowercase();
        if tail.chars().count() >= 2 && (rest.starts_with(&tail) || tail.starts_with(&rest)) {
            return text[..index].to_string();
        }
    }
    text.to_string()
}

/// Closing punctuation already after the cursor (the period of a sentence being edited, a closing bracket): the
/// suggestion stops where its own sentence or clause would end, so it never doubles that mark.
pub fn punctuation_trimmed(text: &str, after: &str) -> String {
    let line: String = after.chars().take_while(|c| !is_newline(*c)).collect();
    let rest = line.trim_matches(|c: char| c == ' ' || c == '\t');
    let Some(first) = rest.chars().next() else { return text.to_string() };
    if !CLOSING.contains(&first) {
        return text.to_string();
    }
    // An apostrophe in the line after is no reason to cut "it's" short.
    let closer = if "'’".contains(first) || SENTENCE_MARKS.contains(first) { None } else { Some(first) };
    // A mark ends the sentence only before a space or at the end: "10.30", "e.g." and "nook.app" stay whole.
    let mut iter = text.char_indices().peekable();
    while let Some((index, c)) = iter.next() {
        if Some(c) == closer {
            return text[..index].to_string();
        }
        if SENTENCE_MARKS.contains(c) && iter.peek().is_none_or(|(_, next)| next.is_whitespace()) {
            return text[..index].to_string();
        }
    }
    text.to_string()
}

/// Whether to ask the model at all for this cursor position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompletionPolicy {
    /// Letters (not spaces) before the cursor.
    pub minimum_context: usize,
    /// Also with text after the cursor on the same line.
    pub mid_line: bool,
}

impl Default for CompletionPolicy {
    fn default() -> Self {
        Self { minimum_context: 3, mid_line: false }
    }
}

impl CompletionPolicy {
    pub fn should_complete(&self, before: &str, after: &str, has_selection: bool) -> bool {
        if has_selection {
            return false;
        }
        if before.chars().filter(|c| !c.is_whitespace()).take(self.minimum_context).count() < self.minimum_context {
            return false;
        }
        // Inside a word ("mor|gen"): whatever the model writes would split it.
        if let (Some(next), Some(last)) = (after.chars().next(), before.chars().last()) {
            if is_word_char(next) && is_word_char(last) {
                return false;
            }
        }
        if self.mid_line {
            return true;
        }
        after.chars().take_while(|c| !is_newline(*c)).all(|c| c.is_whitespace() || CLOSING.contains(&c))
    }
}

/// How much the model may suggest and how sure it must be.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CompletionOptions {
    pub max_words: usize,
    pub max_tokens: usize,
    /// Show nothing when the model is less sure than this of the first token: a wrong suggestion costs more than none.
    pub min_first_probability: f32,
    /// Stop the suggestion where the model's certainty drops below this.
    pub min_probability: f32,
    /// How sure the model must stay of the suggestion as a whole (the product of its tokens' probabilities).
    pub min_sequence_probability: f32,
}

impl CompletionOptions {
    /// `eagerness`: 0 only very sure suggestions … 1 eager.
    pub fn new(max_words: usize, eagerness: f64) -> Self {
        let caution = (1.0 - eagerness.clamp(0.0, 1.0)) as f32;
        Self {
            max_words,
            max_tokens: (max_words * 3).max(6),
            min_first_probability: 0.05 + 0.3 * caution,
            min_probability: 0.02 + 0.13 * caution,
            min_sequence_probability: 0.01 + 0.09 * caution,
        }
    }

    /// For the suggestion after one that was taken whole: every suggestion ends where the model got unsure, so the next
    /// one starts at an unsure point. The user is writing along with the model, so it may go on with less certainty.
    pub fn continuing(mut self) -> Self {
        self.min_first_probability *= 0.4;
        self.min_probability *= 0.6;
        self.min_sequence_probability *= 0.4;
        self
    }
}

/// What the model wrote.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompletionResult {
    pub text: String,
    /// Stopped at the token limit: the last word may be cut off.
    pub truncated: bool,
    /// Stopped in the middle of a word because the model was no longer sure.
    pub unfinished: bool,
}

/// Words in `text` that are finished: all of them when it ends in a space or punctuation, otherwise all but the last.
pub fn finished_words(text: &str) -> usize {
    let words = word_count(text);
    match text.chars().last() {
        None => 0,
        Some(c) if c.is_whitespace() || ".,!?;:".contains(c) => words,
        Some(_) => words.saturating_sub(1),
    }
}

/// The cursor stands right after a letter or digit: the model has to finish that word first.
pub fn mid_word(before: &str) -> bool {
    before.chars().last().is_some_and(is_word_char)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make(raw: &str, before: &str) -> Option<String> {
        CompletionSuggestion::make(raw, before, "", 8, false, false).map(|s| s.remaining().to_string())
    }

    #[test]
    fn cuts_at_newline_and_trims() {
        assert_eq!(make(" hello there\nnext", "Well,"), Some(" hello there".into()));
        assert_eq!(make(" hello there  ", "Well, "), Some("hello there".into()));
        assert_eq!(make("\t\u{7}a b", "x "), Some("a b".into()));
        assert_eq!(make("   ", "x"), None);
    }

    #[test]
    fn stops_at_last_whole_word() {
        let s = CompletionSuggestion::make(" see you tomor", "I will", "", 8, false, true).unwrap();
        assert_eq!(s.remaining(), " see you");
        let s = CompletionSuggestion::make(" see you ", "I will", "", 8, false, true).unwrap();
        assert_eq!(s.remaining(), " see you");
        let s = CompletionSuggestion::make(" see you tomor", "I will", "", 8, true, false).unwrap();
        assert_eq!(s.remaining(), " see you");
        // Truncated with one word only: the word stays.
        let s = CompletionSuggestion::make(" tomor", "I will", "", 8, true, false).unwrap();
        assert_eq!(s.remaining(), " tomor");
        // Unfinished with one word only: nothing.
        assert!(CompletionSuggestion::make(" tomor", "I will", "", 8, false, true).is_none());
    }

    #[test]
    fn limits_words() {
        let s = CompletionSuggestion::make(" a b c d e", "x", "", 2, false, false).unwrap();
        assert_eq!(s.remaining(), " a b");
    }

    #[test]
    fn drops_copies_of_preceding_lines() {
        let before = "We meet on Monday at the office.\nSee you ";
        assert_eq!(make("on Monday at the office", before), None);
        assert_eq!(make("On monday at", before), None);
        assert_eq!(make("on Monday", before), Some("on Monday".into()));
        assert_eq!(make("tomorrow at noon", before), Some("tomorrow at noon".into()));
    }

    #[test]
    fn stops_where_text_after_begins() {
        let s = CompletionSuggestion::make(" to the shop tomorrow", "I go", "tomorrow", 8, false, false).unwrap();
        assert_eq!(s.remaining(), " to the shop");
        let s = CompletionSuggestion::make(" really nice. And then", "It was", ".", 8, false, false).unwrap();
        assert_eq!(s.remaining(), " really nice");
        // "10.30" stays whole.
        let s = CompletionSuggestion::make(" at 10.30 sharp", "Meet", ".", 8, false, false).unwrap();
        assert_eq!(s.remaining(), " at 10.30 sharp");
        let s = CompletionSuggestion::make(" a list) of", "(with", ")", 8, false, false).unwrap();
        assert_eq!(s.remaining(), " a list");
    }

    #[test]
    fn accepts_word_by_word() {
        let mut s = CompletionSuggestion::new(" there, my friend.");
        let options = AcceptOptions::default();
        assert_eq!(s.accept_next_chunk(options), " there");
        assert_eq!(s.accept_next_chunk(options), ",");
        assert_eq!(s.accept_next_chunk(options), " my");
        let attached = AcceptOptions { attached_punctuation: true, trailing_space: false };
        assert_eq!(s.accept_next_chunk(attached), " friend.");
        assert!(s.is_empty());

        let mut s = CompletionSuggestion::new(" one two");
        let spaced = AcceptOptions { trailing_space: true, attached_punctuation: false };
        assert_eq!(s.accept_next_chunk(spaced), " one ");
        assert_eq!(s.remaining(), "two");

        let mut s = CompletionSuggestion::new(" nook.app is 3.5 ...");
        assert_eq!(s.accept_next_chunk(options), " nook.app");
        assert_eq!(s.accept_next_chunk(options), " is");
        assert_eq!(s.accept_next_chunk(options), " 3.5");
        assert_eq!(s.accept_next_chunk(options), " ...");
    }

    #[test]
    fn accepts_all_and_punctuation() {
        let mut s = CompletionSuggestion::new(". Then we go");
        assert_eq!(s.take_attached_punctuation(), Some(".".into()));
        assert_eq!(s.remaining(), " Then we go");
        assert_eq!(s.accept_all(), " Then we go");
        assert!(s.is_empty());
        let mut s = CompletionSuggestion::new("!");
        assert_eq!(s.take_attached_punctuation(), Some("!".into()));
        assert!(s.is_empty());
        let mut s = CompletionSuggestion::new(".com");
        assert_eq!(s.take_attached_punctuation(), None);
    }

    #[test]
    fn typing_through_advances() {
        let mut s = CompletionSuggestion::new(" tomorrow");
        assert!(s.consume(" to"));
        assert_eq!(s.remaining(), "morrow");
        assert!(!s.consume("x"));
        assert!(!s.consume(""));
        assert!(s.consume("morrow"));
        assert!(s.is_empty());
    }

    #[test]
    fn policy() {
        let p = CompletionPolicy::default();
        assert!(!p.should_complete("hi", "", false));
        assert!(p.should_complete("hello", "", false));
        assert!(!p.should_complete("hello", "", true));
        assert!(!p.should_complete("hel", "lo", false));
        assert!(p.should_complete("hello ", ".", false));
        assert!(!p.should_complete("hello ", "world", false));
        let mid = CompletionPolicy { mid_line: true, ..Default::default() };
        assert!(mid.should_complete("hello ", "world", false));
        assert!(p.should_complete("hello ", "\nnext line", false));
    }

    #[test]
    fn options_scale_with_eagerness() {
        let careful = CompletionOptions::new(8, 0.0);
        let eager = CompletionOptions::new(8, 1.0);
        assert!(careful.min_first_probability > eager.min_first_probability);
        assert_eq!(careful.max_tokens, 24);
        assert_eq!(CompletionOptions::new(1, 0.5).max_tokens, 6);
        let next = careful.continuing();
        assert!(next.min_probability < careful.min_probability);
    }

    #[test]
    fn streaming_words() {
        assert_eq!(finished_words("one two thr"), 2);
        assert_eq!(finished_words("one two "), 2);
        assert_eq!(finished_words("one two."), 2);
        assert_eq!(finished_words(""), 0);
        assert!(mid_word("hel"));
        assert!(!mid_word("hel "));
    }

    #[test]
    fn chunks_split() {
        assert_eq!(chunks(" a  bb c "), vec![" a", "  bb", " c"]);
        assert_eq!(chunks("x"), vec!["x"]);
        assert!(chunks("   ").is_empty());
    }
}
