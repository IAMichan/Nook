//! Checks that keep think-along offers useful (the Mac's `NudgeFilter`): no offers about things far away, none that
//! ask a question nothing would answer, none that are not about what is on screen, and no repeat of a suggestion
//! that was only reworded.

use std::collections::BTreeSet;

use chrono::NaiveDate;

/// Dates further away than this are never a reason to interrupt you.
pub const HORIZON_DAYS: i64 = 14;

/// Lowercased letters and digits, single spaces between them.
pub fn normalize(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn words(text: &str) -> BTreeSet<String> {
    normalize(text).split(' ').filter(|w| w.chars().count() >= 3).map(String::from).collect()
}

/// Two offers say the same thing when most of their words overlap, even if the brain rephrased them (Jaccard ≥ 0.6).
pub fn similar(a: &str, b: &str) -> bool {
    let (left, right) = (words(a), words(b));
    if left.is_empty() || right.is_empty() {
        return normalize(a) == normalize(b);
    }
    let shared = left.intersection(&right).count() as f64;
    shared / left.union(&right).count() as f64 >= 0.6
}

/// An offer without an action must not ask anything: accepting "Shall I…?" would then do nothing.
pub fn asks_without_action(body: &str, has_actions: bool) -> bool {
    !has_actions && body.chars().any(|c| matches!(c, '?' | '¿' | '？'))
}

/// Names, products and numbers in a text: words with a digit, or with a capital where a sentence does not start.
pub fn specific_words(text: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut sentence_start = true;
    for token in text.split_whitespace() {
        let core = token.trim_matches(|c: char| !c.is_alphanumeric());
        let specific = core.chars().any(|c| c.is_ascii_digit()) || (!sentence_start && core.chars().next().is_some_and(char::is_uppercase));
        if specific {
            out.extend(normalize(core).split(' ').filter(|w| w.chars().count() >= 3).map(String::from));
        }
        sentence_start = token.ends_with(['.', '?', '!', ':']);
    }
    out
}

/// An offer must be about what is on screen: it names something visible there, or shares at least two longer words.
pub fn is_grounded(body: &str, screen: &str) -> bool {
    let visible: BTreeSet<String> = normalize(screen).split(' ').filter(|w| !w.is_empty()).map(String::from).collect();
    if visible.is_empty() {
        return false;
    }
    if specific_words(body).iter().any(|w| visible.contains(w)) {
        return true;
    }
    words(body).iter().filter(|w| w.chars().count() >= 6 && visible.contains(*w)).count() >= 2
}

/// Numeric dates in a text: "2027-09-20", "20-09-2027" or "20/9/2027".
pub fn numeric_dates(text: &str) -> Vec<NaiveDate> {
    let re = regex::Regex::new(r"\b(\d{4})-(\d{1,2})-(\d{1,2})\b|\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})\b").expect("date pattern");
    re.captures_iter(text)
        .filter_map(|c| {
            let n = |i: usize| c.get(i).and_then(|m| m.as_str().parse::<i32>().ok());
            let (y, m, d) = if c.get(1).is_some() { (n(1)?, n(2)?, n(3)?) } else { (n(6)?, n(5)?, n(4)?) };
            NaiveDate::from_ymd_opt(y, m as u32, d as u32)
        })
        .collect()
}

/// True when every date the offer is about lies well in the future: a renewal next year is no reason to speak up now.
pub fn is_far_off(dates: &[NaiveDate], today: NaiveDate) -> bool {
    !dates.is_empty() && dates.iter().all(|d| (*d - today).num_days() > HORIZON_DAYS)
}

/// Why an offer is not shown, or none when it may be. `earlier` are the offers of the last hours.
pub fn reject(body: &str, has_actions: bool, screen: &str, earlier: &[String], today: NaiveDate) -> Option<&'static str> {
    if asks_without_action(body, has_actions) {
        return Some("asks without an action");
    }
    if !screen.trim().is_empty() && !is_grounded(body, screen) {
        return Some("not about what is on screen");
    }
    if is_far_off(&numeric_dates(body), today) {
        return Some("about something far off");
    }
    if earlier.iter().any(|e| similar(e, body)) {
        return Some("said before in other words");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn keeps_offers_about_the_screen_and_near() {
        let screen = "Invoice 2041 from Acme Corp, due 25-11-2026. Pay now";
        let today = day(2026, 11, 20);
        assert_eq!(reject("Shall I add the Acme invoice to your tasks?", true, screen, &[], today), None);
        assert_eq!(reject("Shall I add it to your tasks?", false, screen, &[], today), Some("asks without an action"));
        assert_eq!(reject("You could batch your mail in one go.", true, screen, &[], today), Some("not about what is on screen"));
        assert_eq!(reject("The Acme Corp invoice renews on 2027-09-20.", true, screen, &[], today), Some("about something far off"));
        let earlier = vec!["Shall I add the Acme invoice to your tasks?".to_string()];
        assert_eq!(
            reject("Shall I put the Acme invoice in your tasks?", true, screen, &earlier, today),
            Some("said before in other words")
        );
    }

    #[test]
    fn reads_numeric_dates_both_ways() {
        assert_eq!(numeric_dates("on 2027-09-20 or 20/9/2027"), vec![day(2027, 9, 20), day(2027, 9, 20)]);
        assert!(numeric_dates("version 1.2.3").is_empty());
        assert!(!is_far_off(&[], day(2026, 1, 1)));
    }

    #[test]
    fn finds_names_and_numbers() {
        let w = specific_words("Ask Peter about invoice 2041. Then rest.");
        assert!(w.contains("peter") && w.contains("2041") && !w.contains("then"));
    }
}
