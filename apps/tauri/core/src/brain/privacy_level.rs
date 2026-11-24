//! How tightly Nook guards what an external brain gets to see (Settings › Privacy › Privacy level; `PrivacyLevel` and
//! `PrivacyFilter` on the Mac). A brain on this computer sees everything: nothing leaves the computer. Whatever the
//! level, password managers and password fields are never read, keys stay in the system's secure storage and nothing
//! runs without a click.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::services::autocomplete::privacy;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrivacyLevel {
    /// Context goes as it is: the best answers, nothing taken out.
    Open,
    /// Secrets are taken out first: passwords, API keys and tokens, private keys, card numbers, IBANs and BSNs.
    #[default]
    Balanced,
    /// Secrets and contact details (e-mail addresses, phone numbers) are taken out, and the screen and the clipboard
    /// stay on this computer.
    Strict,
}

pub const EMAIL: &str = "[email]";
pub const PHONE: &str = "[phone]";

static EMAIL_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b").expect("valid email pattern"));
/// International numbers (+31 6 12345678, 0031 20 123 4567) and Dutch-style numbers with a leading zero (06-12345678,
/// 020 123 4567). Rust's `regex` has no look-behind, so the character before the number is matched and kept.
static PHONE_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(^|[^\w+])((?:\+|00)[1-9]\d{0,2}[ \-]?(?:\(0\)[ \-]?)?\d(?:[ \-]?\d){6,11}\b|0\d(?:[ \-]?\d){8}\b)")
        .expect("valid phone pattern")
});

impl PrivacyLevel {
    /// Sources an external brain never gets at this level, on top of the ones the user keeps on this computer by hand.
    pub fn local_only_sources(self) -> BTreeSet<String> {
        match self {
            Self::Strict => ["screen", "clipboard"].into_iter().map(String::from).collect(),
            _ => BTreeSet::new(),
        }
    }

    /// Text Nook gathered (context, screen text, what tools read) as an external brain may get it. What the user types
    /// is never changed: they chose to send that.
    pub fn apply(self, text: &str) -> String {
        match self {
            Self::Open => text.to_string(),
            Self::Balanced => privacy::sanitize(text),
            Self::Strict => {
                let result = privacy::sanitize(text);
                let result = EMAIL_PATTERN.replace_all(&result, EMAIL);
                PHONE_PATTERN.replace_all(&result, |c: &regex::Captures| format!("{}{PHONE}", &c[1])).into_owned()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_changes_nothing() {
        let text = "mail sam@example.com, key sk-live-abcdefghijklmnop1234";
        assert_eq!(PrivacyLevel::Open.apply(text), text);
    }

    #[test]
    fn balanced_takes_out_secrets_but_keeps_contacts() {
        let out = PrivacyLevel::Balanced.apply("mail sam@example.com, key sk-live-abcdefghijklmnop1234");
        assert!(out.contains("sam@example.com"));
        assert!(!out.contains("sk-live-abcdefghijklmnop1234"));
    }

    #[test]
    fn strict_takes_out_contacts_and_keeps_the_screen_here() {
        let out = PrivacyLevel::Strict.apply("Bel 06-12345678 of +31 20 123 4567, mail sam@example.com. Order 42.");
        assert_eq!(out, "Bel [phone] of [phone], mail [email]. Order 42.");
        assert!(PrivacyLevel::Strict.local_only_sources().contains("screen"));
        assert!(PrivacyLevel::Balanced.local_only_sources().is_empty());
    }

    #[test]
    fn reads_the_stored_value() {
        let level: PrivacyLevel = serde_json::from_str("\"strict\"").unwrap();
        assert_eq!(level, PrivacyLevel::Strict);
        assert_eq!(PrivacyLevel::default(), PrivacyLevel::Balanced);
    }
}
