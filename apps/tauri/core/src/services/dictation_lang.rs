//! Dictation in several languages (`MultiDictation` on the Mac). "Automatic" (the default) listens for the languages you
//! use: the one that won last time first, then the system languages, the keyboard layouts, Nook's own language and
//! English, one per language, at most three. A fixed language can be chosen in Settings.
//!
//! How automatic is carried out depends on the engine: whisper.cpp and the cloud services detect the language
//! themselves (`-l auto`, or no `language` field) and tell which one they heard, which Nook remembers as the winner of
//! this round; the speech recognition of Windows listens in one language at a time and takes the first candidate.

/// The value of "Automatic".
pub const AUTOMATIC: &str = "auto";
/// The most languages Automatic listens for.
pub const MAX_CANDIDATES: usize = 3;

/// Languages whisper.cpp, OpenAI and Groq understand, by their two-letter code, with the English name Settings shows.
pub const LANGUAGES: &[(&str, &str)] = &[
    ("af", "Afrikaans"), ("ar", "Arabic"), ("bg", "Bulgarian"), ("ca", "Catalan"), ("cs", "Czech"), ("da", "Danish"),
    ("de", "German"), ("el", "Greek"), ("en", "English"), ("es", "Spanish"), ("et", "Estonian"), ("fa", "Persian"),
    ("fi", "Finnish"), ("fr", "French"), ("he", "Hebrew"), ("hi", "Hindi"), ("hr", "Croatian"), ("hu", "Hungarian"),
    ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("lt", "Lithuanian"), ("lv", "Latvian"),
    ("ms", "Malay"), ("nl", "Dutch"), ("no", "Norwegian"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"),
    ("ru", "Russian"), ("sk", "Slovak"), ("sl", "Slovenian"), ("sr", "Serbian"), ("sv", "Swedish"), ("sw", "Swahili"),
    ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"), ("zh", "Chinese"),
];

/// "nl-NL", "nl_NL", "NL" or "Dutch" → "nl"; `None` for a language the engines do not know.
pub fn code_of(text: &str) -> Option<&'static str> {
    let flat = text.trim().replace('_', "-").to_lowercase();
    let head = flat.split('-').next().unwrap_or("");
    if let Some((code, _)) = LANGUAGES.iter().find(|(code, _)| *code == head) {
        return Some(code);
    }
    // Whisper and OpenAI say the English name ("dutch"); "nb" and "nn" are Norwegian.
    if matches!(head, "nb" | "nn") {
        return Some("no");
    }
    LANGUAGES.iter().find(|(_, name)| name.to_lowercase() == flat).map(|(code, _)| *code)
}

/// The English name of a language code.
pub fn name_of(code: &str) -> Option<&'static str> {
    LANGUAGES.iter().find(|(c, _)| *c == code).map(|(_, name)| *name)
}

/// The languages Automatic listens for, in order, one per language: last winner, system languages, keyboard layouts,
/// Nook's own language, English; unknown languages are skipped.
pub fn automatic_languages(last_heard: &str, system: &[String], keyboards: &[String], app_language: &str) -> Vec<&'static str> {
    let mut out: Vec<&'static str> = vec![];
    let all = std::iter::once(last_heard).chain(system.iter().map(String::as_str)).chain(keyboards.iter().map(String::as_str)).chain([app_language, "en"]);
    for id in all {
        let Some(code) = code_of(id) else { continue };
        if !out.contains(&code) {
            out.push(code);
        }
        if out.len() == MAX_CANDIDATES {
            break;
        }
    }
    out
}

/// What to ask whisper.cpp or a cloud service for: a fixed language, or `None` to let the engine detect it.
pub fn fixed(setting: &str) -> Option<&'static str> {
    if setting.trim().is_empty() || setting == AUTOMATIC {
        None
    } else {
        code_of(setting)
    }
}

/// The language the speech recognition of Windows listens in: the fixed one, or the first candidate of Automatic.
pub fn windows_language(setting: &str, candidates: &[&'static str]) -> &'static str {
    fixed(setting).or_else(|| candidates.first().copied()).unwrap_or("en")
}

/// The Windows locale tag for a language code.
pub fn locale(code: &str) -> &'static str {
    match code {
        "en" => "en-US",
        "de" => "de-DE",
        "fr" => "fr-FR",
        "es" => "es-ES",
        "nl" => "nl-NL",
        "it" => "it-IT",
        "pt" => "pt-PT",
        "sv" => "sv-SE",
        "da" => "da-DK",
        "no" => "nb-NO",
        "fi" => "fi-FI",
        "pl" => "pl-PL",
        "ru" => "ru-RU",
        "ja" => "ja-JP",
        "ko" => "ko-KR",
        "zh" => "zh-CN",
        "tr" => "tr-TR",
        "cs" => "cs-CZ",
        "ca" => "ca-ES",
        _ => "en-US",
    }
}

/// One recogniser's result when several listened, as the Mac keeps it.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub language: &'static str,
    pub words: String,
    pub confidence: f32,
}

/// The transcript the recognisers were the most confident about; the leading one stays when none beats it.
pub fn best(candidates: &[Candidate], lead: usize) -> Option<&Candidate> {
    let leader = candidates.get(lead)?;
    let best = candidates.iter().filter(|c| !c.words.is_empty()).max_by(|a, b| a.confidence.total_cmp(&b.confidence));
    match best {
        Some(best) if best.confidence > leader.confidence => Some(best),
        _ => Some(leader),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn reads_codes_and_names() {
        assert_eq!(code_of("nl-NL"), Some("nl"));
        assert_eq!(code_of("pt_BR"), Some("pt"));
        assert_eq!(code_of("Dutch"), Some("nl"));
        assert_eq!(code_of("nb-NO"), Some("no"));
        assert_eq!(code_of("xx"), None);
        assert_eq!(name_of("fr"), Some("French"));
    }

    #[test]
    fn automatic_takes_the_winner_first_then_one_per_language_up_to_three() {
        let languages = automatic_languages("fr-FR", &ids(&["nl-NL", "en-US", "de-DE"]), &ids(&["nl"]), "nl");
        assert_eq!(languages, vec!["fr", "nl", "en"]);
        // Nothing known: Nook's language, then English.
        assert_eq!(automatic_languages("", &[], &[], "de"), vec!["de", "en"]);
        assert_eq!(automatic_languages("", &ids(&["xx"]), &[], "en"), vec!["en"]);
    }

    #[test]
    fn a_fixed_language_or_the_engines_own_detection() {
        assert_eq!(fixed("auto"), None);
        assert_eq!(fixed(""), None);
        assert_eq!(fixed("de-DE"), Some("de"));
        assert_eq!(windows_language("auto", &["fr", "nl"]), "fr");
        assert_eq!(windows_language("es", &["fr"]), "es");
        assert_eq!(locale("nl"), "nl-NL");
    }

    #[test]
    fn the_most_confident_transcript_wins() {
        let a = Candidate { language: "nl", words: "hallo".into(), confidence: 0.4 };
        let b = Candidate { language: "en", words: "hello there".into(), confidence: 0.9 };
        assert_eq!(best(&[a.clone(), b.clone()], 0), Some(&b));
        assert_eq!(best(&[b.clone(), a.clone()], 0), Some(&b));
        let empty = Candidate { language: "de", words: String::new(), confidence: 0.99 };
        assert_eq!(best(&[a.clone(), empty], 0), Some(&a));
        assert_eq!(best(&[], 0), None);
    }
}
