//! Takes out what looks like a secret before text is given to the model as context: card numbers, IBANs, citizen
//! service numbers (BSN), API keys and tokens, private keys, passwords after "password:". Ported from
//! `CompletionPrivacy.swift`.

use std::sync::LazyLock;

use regex::Regex;

pub const PLACEHOLDER: &str = "[redacted]";

#[derive(Clone, Copy)]
enum Check {
    None,
    Luhn,
    ElevenTest,
    /// Mixed letters and digits (Rust's `regex` has no look-ahead, so the Mac's `(?=…\d)(?=…[A-Za-z])` is checked here).
    Mixed,
}

static PATTERNS: LazyLock<Vec<(Regex, Check)>> = LazyLock::new(|| {
    [
        (r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b", Check::None),
        (r"\b\d(?:[ -]?\d){12,18}\b", Check::Luhn),
        (r"\b\d{9}\b|\b\d{4}\.\d{2}\.\d{3}\b", Check::ElevenTest),
        (r"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}\b", Check::None),
        (r"\b(?:ghp|gho|ghu|ghs|github_pat|glpat|xox[abprs]|AKIA|AIza|re_|whsec_)[A-Za-z0-9_\-]{12,}\b", Check::None),
        (r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b", Check::None),
        (r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", Check::None),
        (r"\b[A-Za-z0-9+/_\-]{32,}={0,2}", Check::Mixed),
        (r"(?i)\b(?:password|passwd|pwd|wachtwoord|secret|geheim|api[_-]?key|token|pincode|pin)\b\s*[:=]\s*\S+", Check::None),
    ]
    .into_iter()
    .map(|(pattern, check)| (Regex::new(pattern).expect("valid privacy pattern"), check))
    .collect()
});

/// The text with everything that looks like a secret replaced by [`PLACEHOLDER`].
pub fn sanitize(text: &str) -> String {
    let mut result = text.to_string();
    for (pattern, check) in PATTERNS.iter() {
        let mut output = String::with_capacity(result.len());
        let mut cursor = 0;
        for found in pattern.find_iter(&result) {
            let candidate = found.as_str();
            let secret = match check {
                Check::None => true,
                Check::Luhn => passes_luhn(candidate),
                Check::ElevenTest => passes_eleven_test(candidate),
                Check::Mixed => candidate.chars().any(|c| c.is_ascii_digit()) && candidate.chars().any(|c| c.is_ascii_alphabetic()),
            };
            if !secret {
                continue;
            }
            output.push_str(&result[cursor..found.start()]);
            output.push_str(PLACEHOLDER);
            cursor = found.end();
        }
        output.push_str(&result[cursor..]);
        result = output;
    }
    result
}

/// Whether the text contains anything [`sanitize`] would take out.
pub fn contains_secret(text: &str) -> bool {
    sanitize(text) != text
}

pub fn passes_luhn(text: &str) -> bool {
    let digits: Vec<u32> = text.chars().filter_map(|c| c.to_digit(10)).collect();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(offset, &digit)| {
            let doubled = if offset % 2 == 1 { digit * 2 } else { digit };
            if doubled > 9 {
                doubled - 9
            } else {
                doubled
            }
        })
        .sum();
    sum.is_multiple_of(10)
}

/// The BSN "elfproef": 9×d1 + 8×d2 + … + 2×d8 − 1×d9 is a multiple of 11 (and not zero).
pub fn passes_eleven_test(text: &str) -> bool {
    let digits: Vec<i64> = text.chars().filter_map(|c| c.to_digit(10)).map(i64::from).collect();
    if digits.len() != 9 || digits.iter().all(|&d| d == 0) {
        return false;
    }
    let sum: i64 = (0..8).map(|i| (9 - i as i64) * digits[i]).sum::<i64>() - digits[8];
    sum % 11 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_cards_ibans_and_bsn() {
        assert_eq!(sanitize("card 4111 1111 1111 1111 ok"), "card [redacted] ok");
        // Not a valid card number: a phone or order number stays.
        assert_eq!(sanitize("order 4111 1111 1111 1112"), "order 4111 1111 1111 1112");
        assert_eq!(sanitize("IBAN NL91 ABNA 0417 1643 00 please"), "IBAN [redacted] please");
        assert_eq!(sanitize("BSN 111222333."), "BSN [redacted].");
        assert_eq!(sanitize("number 123456789"), "number 123456789");
    }

    #[test]
    fn redacts_keys_and_passwords() {
        assert_eq!(sanitize("key sk-proj-abcdefghijklmnop1234"), "key [redacted]");
        assert_eq!(sanitize("token ghp_abcdefghijklmnopqrstuv"), "token [redacted]");
        assert_eq!(sanitize("password: hunter2 and more"), "[redacted] and more");
        assert_eq!(sanitize("Wachtwoord = geheim123"), "[redacted]");
        assert_eq!(sanitize("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY----- done"), "[redacted] done");
        assert_eq!(sanitize("x a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7 y"), "x [redacted] y");
        assert_eq!(sanitize("jwt eyJhbGciOiJI.eyJzdWIiOiIx.SflKxwRJSMeKK"), "jwt [redacted]");
    }

    #[test]
    fn leaves_plain_text() {
        let text = "See you tomorrow at 10.30 in the office, my pin is not here.";
        assert_eq!(sanitize(text), text);
        assert!(!contains_secret(text));
        assert!(contains_secret("pin: 1234"));
        // Long words without digits are no key.
        let word = "abcdefghijklmnopqrstuvwxyzabcdefghij";
        assert_eq!(sanitize(word), word);
    }

    #[test]
    fn checksums() {
        assert!(passes_luhn("4111111111111111"));
        assert!(!passes_luhn("4111111111111112"));
        assert!(!passes_luhn("123"));
        assert!(passes_eleven_test("111222333"));
        assert!(!passes_eleven_test("000000000"));
        assert!(!passes_eleven_test("123456789"));
    }
}
