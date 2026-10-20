//! The suggestion on screen and what keys and reads do to it: the platform-free part of the Mac's
//! `AutocompleteController` (accepting a word or all, typing through, dismissing).

use super::suggestion::{AcceptOptions, CompletionSuggestion};

/// A suggestion on screen in one field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub suggestion: CompletionSuggestion,
    /// The text before the cursor the suggestion continues; it grows as words are taken or typed through.
    pub anchor: String,
    /// The field it belongs to (`prompt::field_key`).
    pub field: String,
    /// The app it was made in (for the statistics).
    pub app: String,
    /// No word of it taken yet: the first take counts as a suggestion accepted.
    pub fresh: bool,
}

/// What a fresh read of the field did to the suggestion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadOutcome {
    /// Nothing on screen.
    None,
    /// It still fits (the same text, or letters typed that it predicted): show what is left.
    Kept,
    /// The user typed it to its end: suggest again right away, as after accepting all of it.
    Finished,
    /// The text went another way: it is gone.
    Dropped,
}

/// What an accept key typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Accepted {
    pub text: String,
    /// The first take of this suggestion.
    pub first: bool,
    /// Nothing is left of it.
    pub finished: bool,
    pub app: String,
}

#[derive(Debug, Default)]
pub struct Session {
    proposal: Option<Proposal>,
}

impl Session {
    pub fn proposal(&self) -> Option<&Proposal> {
        self.proposal.as_ref()
    }

    pub fn is_showing(&self) -> bool {
        self.proposal.is_some()
    }

    pub fn show(&mut self, suggestion: CompletionSuggestion, anchor: &str, field: &str, app: &str) {
        self.proposal = Some(Proposal { suggestion, anchor: anchor.into(), field: field.into(), app: app.into(), fresh: true });
    }

    /// Hides the suggestion; true when there was one.
    pub fn dismiss(&mut self) -> bool {
        self.proposal.take().is_some()
    }

    /// The field was read again (after a key, or after Nook typed): letters typed that the suggestion predicted move it
    /// on; anything else drops it.
    pub fn on_read(&mut self, field: &str, before: &str) -> ReadOutcome {
        let Some(proposal) = self.proposal.as_mut() else { return ReadOutcome::None };
        if proposal.field != field {
            self.proposal = None;
            return ReadOutcome::Dropped;
        }
        if before == proposal.anchor {
            return ReadOutcome::Kept;
        }
        let Some(typed) = before.strip_prefix(proposal.anchor.as_str()) else {
            self.proposal = None;
            return ReadOutcome::Dropped;
        };
        if !proposal.suggestion.consume(typed) {
            self.proposal = None;
            return ReadOutcome::Dropped;
        }
        proposal.anchor = before.to_string();
        if proposal.suggestion.is_empty() {
            self.proposal = None;
            return ReadOutcome::Finished;
        }
        ReadOutcome::Kept
    }

    /// Takes the next word (or all) for typing. `None` when nothing is on screen.
    pub fn accept(&mut self, all: bool, options: AcceptOptions) -> Option<Accepted> {
        let proposal = self.proposal.as_mut()?;
        let text = if all { proposal.suggestion.accept_all() } else { proposal.suggestion.accept_next_chunk(options) };
        if text.is_empty() {
            self.proposal = None;
            return None;
        }
        let first = proposal.fresh;
        proposal.fresh = false;
        proposal.anchor.push_str(&text);
        let app = proposal.app.clone();
        let finished = proposal.suggestion.is_empty();
        if finished {
            self.proposal = None;
        }
        Some(Accepted { text, first, finished, app })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        let mut s = Session::default();
        s.show(CompletionSuggestion::new(" see you tomorrow."), "I will", "field", "outlook");
        s
    }

    #[test]
    fn accepts_word_then_all() {
        let mut s = session();
        let a = s.accept(false, AcceptOptions::default()).unwrap();
        assert_eq!((a.text.as_str(), a.first, a.finished), (" see", true, false));
        assert_eq!(s.proposal().unwrap().anchor, "I will see");
        let a = s.accept(true, AcceptOptions::default()).unwrap();
        assert_eq!((a.text.as_str(), a.first, a.finished), (" you tomorrow.", false, true));
        assert!(!s.is_showing());
        assert!(s.accept(false, AcceptOptions::default()).is_none());
    }

    #[test]
    fn attached_punctuation_comes_with_the_last_word() {
        let mut s = Session::default();
        s.show(CompletionSuggestion::new(" now."), "Go", "f", "a");
        let options = AcceptOptions { attached_punctuation: true, trailing_space: false };
        let a = s.accept(false, options).unwrap();
        assert_eq!(a.text, " now.");
        assert!(a.finished);
    }

    #[test]
    fn typing_through_keeps_it() {
        let mut s = session();
        assert_eq!(s.on_read("field", "I will"), ReadOutcome::Kept);
        assert_eq!(s.on_read("field", "I will se"), ReadOutcome::Kept);
        assert_eq!(s.proposal().unwrap().suggestion.remaining(), "e you tomorrow.");
        assert_eq!(s.on_read("field", "I will see you tomorrow."), ReadOutcome::Finished);
        assert!(!s.is_showing());
        assert_eq!(s.on_read("field", "x"), ReadOutcome::None);
    }

    #[test]
    fn other_text_drops_it() {
        let mut s = session();
        assert_eq!(s.on_read("field", "I will go"), ReadOutcome::Dropped);
        let mut s = session();
        assert_eq!(s.on_read("field", "I wil"), ReadOutcome::Dropped);
        let mut s = session();
        assert_eq!(s.on_read("other", "I will"), ReadOutcome::Dropped);
        let mut s = session();
        assert!(s.dismiss());
        assert!(!s.dismiss());
    }

    #[test]
    fn accepted_word_then_read_keeps_rest() {
        let mut s = session();
        s.accept(false, AcceptOptions::default());
        // The app now shows the word Nook typed.
        assert_eq!(s.on_read("field", "I will see"), ReadOutcome::Kept);
        assert_eq!(s.proposal().unwrap().suggestion.remaining(), " you tomorrow.");
    }
}
