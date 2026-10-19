//! Een antwoord zoals het voorgelezen wordt: zonder Markdown, links, code of bronnummers, en zin voor zin terwijl
//! het nog geschreven wordt, zodat Nook meteen begint te praten. Zelfde regels als `SpokenText` op de Mac.

use std::sync::OnceLock;

use regex::Regex;

fn rx(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("geldig patroon"))
}

/// De woorden van een Markdown-antwoord, zoals iemand ze zou voorlezen.
pub fn plain(markdown: &str) -> String {
    static CODE: OnceLock<Regex> = OnceLock::new();
    static LINK: OnceLock<Regex> = OnceLock::new();
    static BARE: OnceLock<Regex> = OnceLock::new();
    static SOURCE: OnceLock<Regex> = OnceLock::new();
    static MARK: OnceLock<Regex> = OnceLock::new();
    static RULE: OnceLock<Regex> = OnceLock::new();
    static EMPHASIS: OnceLock<Regex> = OnceLock::new();
    static SPACES: OnceLock<Regex> = OnceLock::new();

    // Codeblokken worden niet voorgelezen.
    let text = rx(&CODE, r"```[\s\S]*?(```|$)").replace_all(markdown, " ");
    // [titel](link) → titel; losse links gaan weg.
    let text = rx(&LINK, r"\[([^\]]+)\]\([^)]*\)").replace_all(&text, "$1");
    let text = rx(&BARE, r"https?://\S+").replace_all(&text, "");
    // Bronnummers [1], [2].
    let text = rx(&SOURCE, r"\s?\[\d+\]").replace_all(&text, "");
    // Koppen, lijsttekens en citaten aan het begin van een regel; een regel van een lijst eindigt als zin.
    let mut lines: Vec<String> = Vec::new();
    for raw in text.split('\n') {
        let trimmed = raw.trim();
        let mut line = rx(&MARK, r"^(#{1,6}\s+|[-*•]\s+|\d+[.)]\s+|>\s*)").replace(trimmed, "").to_string();
        if line.is_empty() || rx(&RULE, r"^[|\-: ]+$").is_match(&line) {
            continue;
        }
        if line.starts_with('|') {
            // Een tabelrij: de cellen, met komma's ertussen.
            line = line.split('|').map(str::trim).filter(|c| !c.is_empty()).collect::<Vec<_>>().join(", ");
        }
        if let Some(last) = line.chars().last() {
            if !".!?:;".contains(last) {
                line.push('.');
            }
        }
        lines.push(line);
    }
    let text = lines.join(" ");
    // Nadruk- en codetekens.
    let text = rx(&EMPHASIS, r"(\*\*|__|\*|_|`|~~)").replace_all(&text, "");
    rx(&SPACES, r"\s{2,}").replace_all(&text, " ").trim().to_string()
}

/// Geeft de zinnen van een groeiend antwoord af zodra ze af zijn, zodat het praten kan beginnen voor het antwoord klaar is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SpeechQueue {
    /// Tekens van het antwoord die al afgegeven zijn.
    consumed: usize,
}

impl SpeechQueue {
    /// De hele zinnen die sinds de vorige keer binnenkwamen. `answer` is het hele antwoord tot nu toe.
    pub fn feed(&mut self, answer: &str) -> Vec<String> {
        let chars: Vec<char> = answer.chars().collect();
        if self.consumed >= chars.len() || chars.len() < 2 {
            return vec![];
        }
        // Het laatste zinseinde dat gevolgd wordt door een spatie of nieuwe regel: wat erna komt kan nog groeien.
        let mut end = None;
        let mut index = chars.len() as isize - 2;
        while index >= self.consumed as isize {
            let i = index as usize;
            let (c, next) = (chars[i], chars[i + 1]);
            if c == '\n' || (".!?".contains(c) && (next == ' ' || next == '\n')) {
                // "3.5" of "Dr. Jansen" is geen einde: een cijfer voor de punt.
                if c == '.' && i > 0 && chars[i - 1].is_numeric() && next != '\n' {
                    index -= 1;
                    continue;
                }
                end = Some(i);
                break;
            }
            index -= 1;
        }
        let Some(end) = end else { return vec![] };
        let piece: String = chars[self.consumed..=end].iter().collect();
        self.consumed = end + 1;
        sentences(&piece)
    }

    /// Wat er over is als het antwoord af is.
    pub fn finish(&mut self, answer: &str) -> Vec<String> {
        let chars: Vec<char> = answer.chars().collect();
        if self.consumed >= chars.len() {
            return vec![];
        }
        let piece: String = chars[self.consumed..].iter().collect();
        self.consumed = chars.len();
        sentences(&piece)
    }
}

fn sentences(piece: &str) -> Vec<String> {
    let spoken = plain(piece);
    if spoken.is_empty() {
        vec![]
    } else {
        vec![spoken]
    }
}

/// De taal waarin voorgelezen wordt: de antwoordtaal, of bij "auto" de taal van de tekst.
pub fn voice_language(code: &str, text: &str) -> &'static str {
    let code = if code == "auto" {
        match crate::settings::detect_language(text) {
            Some("English") => "en",
            Some("German") => "de",
            Some("French") => "fr",
            Some("Spanish") => "es",
            _ => "nl",
        }
    } else {
        code
    };
    match code {
        "en" => "en-US",
        "de" => "de-DE",
        "fr" => "fr-FR",
        "es" => "es-ES",
        _ => "nl-NL",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_becomes_plain_speech() {
        let spoken = plain(
            "## Je dag\n- **Om 10:00** overleg met [Lisa](https://example.com) [1]\n- Lunch\n```swift\nlet x = 1\n```\nZie https://nook.example voor meer.",
        );
        assert_eq!(spoken, "Je dag. Om 10:00 overleg met Lisa. Lunch. Zie voor meer.");
    }

    #[test]
    fn tables_are_read_as_cells() {
        assert_eq!(plain("| Dag | Afspraken |\n|---|---|\n| Ma | 3 |"), "Dag, Afspraken. Ma, 3.");
    }

    #[test]
    fn sentences_come_out_while_the_answer_grows() {
        let mut queue = SpeechQueue::default();
        assert!(queue.feed("Je hebt vandaag").is_empty());
        assert_eq!(queue.feed("Je hebt vandaag 3 afspraken. De eerste"), vec!["Je hebt vandaag 3 afspraken."]);
        assert!(queue.feed("Je hebt vandaag 3 afspraken. De eerste is om 9.30 uur").is_empty(), "9.30 is geen zinseinde");
        let done = "Je hebt vandaag 3 afspraken. De eerste is om 9.30 uur met Jan.";
        assert_eq!(queue.finish(done), vec!["De eerste is om 9.30 uur met Jan."]);
        assert!(queue.finish(done).is_empty());
    }

    #[test]
    fn picks_the_voice_language() {
        assert_eq!(voice_language("de", ""), "de-DE");
        assert_eq!(voice_language("auto", "what is on my calendar tomorrow please"), "en-US");
        assert_eq!(voice_language("auto", "hoi"), "nl-NL");
    }
}
