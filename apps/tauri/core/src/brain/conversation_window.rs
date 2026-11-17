//! The part of a conversation that goes to the brain with a new question, within a fixed size.
//!
//! Port of the Mac's `ConversationWindow`. Instead of a fixed "last 12 turns at 4,000 characters", the window:
//!
//! - keeps the newest turns in full, so "and on Friday?" or "make it shorter" still sees what it refers to; the very
//!   newest one (usually a long answer being asked about) may take up to two thirds of the budget;
//! - shortens older turns to their start (ending in "…"), so they cost little but still say what was asked;
//! - folds the turns that no longer fit into one recap turn listing what the user asked earlier, so the topic a
//!   conversation started with is never lost;
//! - stays within `budget` characters in total.

use super::profile::ModelProfile;
use super::ChatTurn;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Characters for the whole window, recap included.
    pub budget: usize,
    /// The newest turns that keep up to `full_length` characters.
    pub recent_turns: usize,
    pub full_length: usize,
    /// Older turns keep their first `short_length` characters.
    pub short_length: usize,
    /// Turns at most, before the rest is folded into the recap.
    pub max_turns: usize,
    /// Earlier questions the recap lists at most (the first ones and the latest ones before the window).
    pub recap_questions: usize,
    pub recap_question_length: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            budget: 24_000,
            recent_turns: 6,
            full_length: 4_000,
            short_length: 600,
            max_turns: 20,
            recap_questions: 6,
            recap_question_length: 140,
        }
    }
}

impl Limits {
    /// Sized to the model: a sixth of what its prompt can hold goes to the conversation, between 3,000 and 32,000
    /// characters, so a small local model is not handed the window of a cloud model.
    pub fn fitting(profile: &ModelProfile) -> Self {
        let mut limits = Self::default();
        limits.budget = (profile.prompt_character_budget() / 6).clamp(3_000, 32_000);
        limits.full_length = (limits.budget / 3).clamp(800, 4_000);
        limits.short_length = (limits.budget / 20).clamp(200, 600);
        if profile.is_small && !profile.rich_prompt {
            limits.recent_turns = 4;
            limits.max_turns = 12;
            limits.recap_questions = 4;
        }
        limits
    }
}

/// How the recap starts, so the code that reads the newest turns (intent, research, recall) can leave it out.
pub const RECAP_HEADER: &str = "[Earlier in this conversation (shortened), the user asked:";
const RECAP_FOOTER: &str = "\n]";

fn chars(text: &str) -> usize {
    text.chars().count()
}

/// The turns to send, oldest first. The recap, when there is one, is the first turn and comes from the user's side, so
/// every provider accepts it as the start of the conversation.
pub fn fit(turns: &[ChatTurn], limits: &Limits) -> Vec<ChatTurn> {
    let turns: Vec<&ChatTurn> = turns.iter().filter(|t| !t.text.trim().is_empty()).collect();
    if turns.is_empty() {
        return vec![];
    }

    // Newest first: each turn gets its length by how recent it is, until the budget or the turn limit is reached.
    let mut kept: Vec<ChatTurn> = vec![];
    let mut used = 0usize;
    let mut cut = turns.len();
    for (offset, turn) in turns.iter().rev().enumerate() {
        if kept.len() >= limits.max_turns {
            break;
        }
        // The newest turn, usually the answer a follow-up is about, may take up to two thirds of the window.
        let length = if offset == 0 {
            limits.full_length.max(limits.budget * 2 / 3)
        } else if offset < limits.recent_turns {
            limits.full_length
        } else {
            limits.short_length
        };
        let mut text = shortened(&turn.text, length);
        let left = limits.budget.saturating_sub(used);
        if chars(&text) > left {
            // The newest turn always comes along, cut to what fits; an older one that does not fit ends the window.
            if !kept.is_empty() || left == 0 {
                break;
            }
            text = shortened(&turn.text, left);
        }
        used += chars(&text);
        kept.push(ChatTurn { from_user: turn.from_user, text });
        cut = turns.len() - 1 - offset;
    }
    kept.reverse();

    // Turns that fell out of the window: what the user asked there, as one short recap at the start. When the recap
    // does not fit next to the window, the oldest kept turns make room for it (and join the recap themselves).
    let dropped = |cut: usize| turns[..cut].iter().map(|t| (*t).clone()).collect::<Vec<_>>();
    let mut recap_text = recap(&dropped(cut), limits);
    while let Some(text) = &recap_text {
        if used + chars(text) + 2 <= limits.budget || kept.len() <= 1 {
            break;
        }
        used -= chars(&kept.remove(0).text);
        cut += 1;
        recap_text = recap(&dropped(cut), limits);
    }
    let Some(recap_text) = recap_text else { return kept };
    // The recap speaks for the user, so the window always starts on the user's side.
    if kept.first().is_some_and(|t| t.from_user) {
        kept[0].text = format!("{recap_text}\n\n{}", kept[0].text);
        return kept;
    }
    let mut window = vec![ChatTurn { from_user: true, text: recap_text }];
    window.extend(kept);
    window
}

/// One line per earlier question: the first ones (where the topic was set) and the latest ones before the window.
pub fn recap(dropped: &[ChatTurn], limits: &Limits) -> Option<String> {
    let questions: Vec<String> =
        dropped.iter().filter(|t| t.from_user).map(|t| one_line(&t.text, limits.recap_question_length)).filter(|q| !q.is_empty()).collect();
    if questions.is_empty() || limits.recap_questions == 0 {
        return None;
    }
    let head = limits.recap_questions.div_ceil(2);
    let (picked, skipped): (Vec<&String>, usize) = if questions.len() <= limits.recap_questions {
        (questions.iter().collect(), 0)
    } else {
        let tail = limits.recap_questions - head;
        let picked = questions[..head].iter().chain(questions[questions.len() - tail..].iter()).collect::<Vec<_>>();
        let skipped = questions.len() - picked.len();
        (picked, skipped)
    };
    let mut lines = vec![RECAP_HEADER.to_string()];
    for (index, question) in picked.iter().enumerate() {
        if skipped > 0 && index == head {
            lines.push(format!("- … {skipped} more"));
        }
        lines.push(format!("- {question}"));
    }
    lines.push("]".into());
    Some(lines.join("\n"))
}

/// The turns without the recap: what the user really said in the newest turns. Reading the recap as the latest request
/// would carry an old "send it to Anna" into a new question, or search for an old topic on "and the budget?".
pub fn without_recap(turns: &[ChatTurn]) -> Vec<ChatTurn> {
    turns
        .iter()
        .filter_map(|turn| {
            if !turn.from_user || !turn.text.starts_with(RECAP_HEADER) {
                return Some(turn.clone());
            }
            let end = turn.text.find(RECAP_FOOTER)?;
            let rest = turn.text[end + RECAP_FOOTER.len()..].trim();
            (!rest.is_empty()).then(|| ChatTurn { from_user: true, text: rest.to_string() })
        })
        .collect()
}

/// The turns as text before a prompt, for brains that take one prompt instead of a message history (Claude Code, small
/// local models). The window is already sized to the brain, so by default it goes along whole; a turn longer than
/// `length` is cut at a word and ends in "…", so the model knows it sees only the start.
pub fn as_text(turns: &[ChatTurn], limit: usize, length: usize) -> String {
    if turns.is_empty() {
        return String::new();
    }
    let start = turns.len().saturating_sub(limit);
    let lines: Vec<String> =
        turns[start..].iter().map(|t| format!("{}: {}", if t.from_user { "User" } else { "Nook" }, shortened(&t.text, length))).collect();
    format!("Conversation so far (for follow-up context):\n{}\n\n", lines.join("\n"))
}

/// The text cut at a word near `length`, marked with an ellipsis when something was left out.
pub fn shortened(text: &str, length: usize) -> String {
    let text = text.trim();
    if chars(text) <= length {
        return text.to_string();
    }
    if length <= 1 {
        return "…".into();
    }
    let head: String = text.chars().take(length - 1).collect();
    // Back to the last space when it is close, so a word is not cut in half.
    if let Some(space) = head.rfind([' ', '\n']) {
        if chars(&head[space..]) <= 40 {
            return format!("{}…", head[..space].trim());
        }
    }
    format!("{head}…")
}

fn one_line(text: &str, limit: usize) -> String {
    let flat = text.lines().filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join(" ").replace("  ", " ");
    shortened(&flat, limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn long() -> String {
        vec!["word"; 200].join(" ") // 999 characters
    }

    fn conversation(count: usize, text: impl Fn(usize) -> String) -> Vec<ChatTurn> {
        (0..count).map(|i| ChatTurn { from_user: i % 2 == 0, text: text(i) }).collect()
    }

    fn total(window: &[ChatTurn]) -> usize {
        window.iter().map(|t| chars(&t.text)).sum()
    }

    #[test]
    fn a_short_conversation_goes_as_it_is() {
        let turns = conversation(4, |i| format!("turn {i}"));
        assert_eq!(fit(&turns, &Limits::default()), turns);
    }

    #[test]
    fn empty_turns_are_left_out() {
        let window =
            fit(&[ChatTurn { from_user: true, text: "  \n".into() }, ChatTurn { from_user: false, text: "hi".into() }], &Limits::default());
        assert_eq!(window.iter().map(|t| t.text.as_str()).collect::<Vec<_>>(), ["hi"]);
    }

    #[test]
    fn the_newest_turns_stay_whole_and_older_ones_are_shortened() {
        let window = fit(&conversation(10, |_| long()), &Limits::default());
        assert_eq!(window.len(), 10);
        for turn in &window[..4] {
            assert!(chars(&turn.text) <= Limits::default().short_length);
            assert!(turn.text.ends_with('…'));
        }
        for turn in &window[4..] {
            assert_eq!(turn.text, long(), "the six newest turns are sent in full");
        }
    }

    #[test]
    fn turns_beyond_the_window_become_a_recap_of_what_was_asked() {
        let window = fit(&conversation(30, |i| if i % 2 == 0 { format!("q{i}") } else { format!("a{i}") }), &Limits::default());
        assert_eq!(window.len(), Limits::default().max_turns);
        let first = &window[0];
        assert!(first.from_user);
        assert!(first.text.starts_with("[Earlier in this conversation"));
        assert!(first.text.contains("- q0"), "the question the conversation started with is kept");
        assert!(first.text.contains("- q8"));
        assert!(!first.text.contains("a1"), "answers are not repeated in the recap");
        assert!(first.text.ends_with("q10"), "the recap joins the first user turn of the window");
        assert_eq!(window.last().unwrap().text, "a29");
    }

    #[test]
    fn a_recap_of_many_questions_keeps_the_first_and_the_latest() {
        let dropped: Vec<ChatTurn> = (0..20).map(|i| ChatTurn { from_user: true, text: format!("q{i}") }).collect();
        let recap = recap(&dropped, &Limits::default()).unwrap();
        let lines: Vec<&str> = recap.lines().collect();
        assert_eq!(&lines[1..lines.len() - 1], ["- q0", "- q1", "- q2", "- … 14 more", "- q17", "- q18", "- q19"]);
    }

    #[test]
    fn no_recap_without_earlier_questions() {
        assert!(recap(&[ChatTurn { from_user: false, text: "answer".into() }], &Limits::default()).is_none());
    }

    #[test]
    fn the_window_stays_within_its_budget() {
        let limits = Limits { budget: 2_000, ..Limits::default() };
        let window = fit(&conversation(10, |_| long()), &limits);
        assert!(total(&window) <= limits.budget);
        assert_eq!(window.len(), 2, "the recap made room by folding the oldest kept turn into it");
        assert!(window[0].from_user, "the window starts on the user's side");
        assert!(window[0].text.starts_with("[Earlier in this conversation"));
        assert_eq!(window[1].text, long());
    }

    #[test]
    fn the_newest_turn_always_comes_along_cut_to_the_budget() {
        let limits = Limits { budget: 500, ..Limits::default() };
        let window = fit(&[ChatTurn { from_user: false, text: long() }], &limits);
        assert_eq!(window.len(), 1);
        assert!(chars(&window[0].text) <= 500);
        assert!(window[0].text.ends_with('…'));
    }

    #[test]
    fn shortened_cuts_at_a_word() {
        assert_eq!(shortened("hello world", 20), "hello world");
        assert_eq!(shortened("hello world", 9), "hello…");
        assert_eq!(shortened("abcdefghij", 5), "abcd…");
        assert_eq!(shortened("ëëëëëëëëëë", 5), "ëëëë…", "counts characters, not bytes");
    }

    #[test]
    fn the_window_is_sized_to_the_model() {
        let cloud = Limits::fitting(&ModelProfile::CLOUD);
        assert_eq!(cloud.budget, 32_000, "a cloud model gets the most room, capped");
        assert_eq!(cloud.full_length, 4_000);
        assert_eq!(cloud.recent_turns, 6);

        let local = Limits::fitting(&ModelProfile::LOCAL_LARGE);
        assert!(local.budget < cloud.budget);
        assert_eq!(local.budget, ModelProfile::LOCAL_LARGE.prompt_character_budget() / 6);
        assert_eq!(local.max_turns, 12, "a small model keeps fewer turns");

        let tiny = ModelProfile { context_tokens: 4_096, ..ModelProfile::LOCAL_SMALL };
        let tiny = Limits::fitting(&tiny);
        assert_eq!(tiny.budget, 3_000, "never below the floor");
        assert_eq!(tiny.full_length, 1_000);

        // A strong local model works like an external one, with the window its context allows.
        assert_eq!(Limits::fitting(&ModelProfile::LOCAL_PRO).max_turns, Limits::default().max_turns);
    }

    #[test]
    fn every_turn_fits_the_window_of_a_small_model() {
        let limits = Limits::fitting(&ModelProfile::LOCAL_SMALL);
        let window = fit(&conversation(40, |_| long()), &limits);
        assert!(total(&window) <= limits.budget);
        assert!(!window.is_empty());
    }

    #[test]
    fn the_recap_is_not_read_as_the_latest_request() {
        let window = fit(&conversation(30, |i| if i % 2 == 0 { format!("q{i}") } else { format!("a{i}") }), &Limits::default());
        let plain = without_recap(&window);
        assert_eq!(plain.len(), window.len(), "a recap merged into a turn leaves the turn itself");
        assert_eq!(plain[0].text, "q10");
        assert!(!plain.iter().any(|t| t.text.contains(RECAP_HEADER)));

        let recap = recap(&[ChatTurn { from_user: true, text: "send it to Anna".into() }], &Limits::default()).unwrap();
        let alone = [ChatTurn { from_user: true, text: recap }, ChatTurn { from_user: false, text: "Sure.".into() }];
        assert_eq!(without_recap(&alone).iter().map(|t| t.text.as_str()).collect::<Vec<_>>(), ["Sure."]);
    }

    #[test]
    fn a_follow_up_does_not_inherit_terms_from_the_recap() {
        let question = ChatTurn { from_user: true, text: "Wat staat er in de offerte van Apollo?".into() };
        let answer = ChatTurn { from_user: false, text: "Here it is.".into() };
        let recap = recap(std::slice::from_ref(&question), &Limits::default()).unwrap();
        let history = [ChatTurn { from_user: true, text: recap }, answer.clone()];
        assert!(!super::super::research::terms("En het budget?", &without_recap(&history)).inherited);
        assert!(super::super::research::terms("En het budget?", &[question, answer]).inherited);
    }

    /// Brains that take one text prompt (Claude Code) see the previous answer whole: it used to be cut to its first
    /// 1,500 characters, so a follow-up on the end of a long briefing found nothing to refer to.
    #[test]
    fn prompt_brains_see_the_whole_previous_answer() {
        let answer = vec!["briefing line"; 300].join("\n") + "\nInfaris.com: check the payment";
        let window = fit(
            &[ChatTurn { from_user: true, text: "Wat moet ik vandaag doen?".into() }, ChatTurn { from_user: false, text: answer }],
            &Limits::fitting(&ModelProfile::CLOUD),
        );
        let prefix = as_text(&window, usize::MAX, usize::MAX);
        assert!(prefix.contains("Infaris.com: check the payment"));
        assert!(prefix.contains("User: Wat moet ik vandaag doen?"));
    }

    #[test]
    fn a_shortened_history_turn_says_it_was_cut() {
        let prefix = as_text(&[ChatTurn { from_user: false, text: long() }], 4, 300);
        assert!(prefix.contains('…'));
        assert!(!prefix.contains(&long()));
    }
}
