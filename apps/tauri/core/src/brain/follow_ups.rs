//! Follow-up offers: the brain puts at most three lines starting with "»" under an answer, written as what you would say
//! to Nook ("» Zet dit in mijn agenda"). Nook takes them out of the text and shows them as buttons. Same as the Mac's
//! `FollowUps`.

pub const MARKER: &str = "»";
/// Offers the chat shows under an answer.
pub const LIMIT: usize = 3;
/// A card (thinking along, a card's own answer) has room for fewer.
pub const CARD_LIMIT: usize = 2;

fn offer_text(line: &str) -> Option<&str> {
    line.strip_prefix(MARKER).or_else(|| line.strip_prefix(">>"))
}

/// Algemene voorstellen zonder waarde ("Vertel meer", "Nog iets?") vallen weg.
fn is_generic(offer: &str) -> bool {
    super::matches(
        rx!(
            r"(?i)^(vertel (me )?meer|meer (info|informatie|details)|nog iets( anders)?|iets anders|leg (het|dat) uit|ga door|ga verder|help me( verder)?|kun je meer|wat nog meer|tell me more|anything else)\W*$"
        ),
        offer,
    )
}

/// The text without offers, and the offers themselves (at most [`LIMIT`], without duplicates).
pub fn split(text: &str) -> (String, Vec<String>) {
    split_limited(text, LIMIT)
}

/// [`split`] with room for `limit` offers.
pub fn split_limited(text: &str, limit: usize) -> (String, Vec<String>) {
    let mut body: Vec<&str> = vec![];
    let mut offers: Vec<String> = vec![];
    for line in text.split('\n') {
        let Some(rest) = offer_text(line.trim()) else {
            body.push(line);
            continue;
        };
        let offer = rest.trim_matches(|c: char| c.is_whitespace() || "*_\"“”".contains(c)).to_string();
        if !offer.is_empty()
            && offer.chars().count() <= 72
            && !is_generic(&offer)
            && !offers.iter().any(|o| o.to_lowercase() == offer.to_lowercase())
        {
            offers.push(offer);
        }
    }
    offers.truncate(limit);
    (body.join("\n").trim().to_string(), offers)
}

/// Tijdens het streamen: alleen de tekst, ook als een voorstel nog maar half binnen is ("»" zonder tekst of ">" van ">>").
pub fn streaming_body(text: &str) -> String {
    let mut body = split(text).0;
    if let Some(last) = body.split('\n').next_back().map(str::trim).map(str::to_string) {
        if last == ">" || last == "-" || last == "*" {
            body.truncate(body.len() - last.len());
            body = body.trim().to_string();
        }
    }
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offers_are_split_off_and_filtered() {
        let (body, offers) = split("Klaar.\n» Zet het in mijn agenda\n» Vertel meer\n>> Schrijf een antwoord\n» zet het in mijn agenda");
        assert_eq!(body, "Klaar.");
        assert_eq!(offers, vec!["Zet het in mijn agenda", "Schrijf een antwoord"]);
    }

    #[test]
    fn three_offers_in_the_chat_two_on_a_card() {
        let text = "Klaar.\n» Een\n» Twee\n» Drie\n» Vier";
        assert_eq!(split(text).1, vec!["Een", "Twee", "Drie"]);
        assert_eq!(split_limited(text, CARD_LIMIT).1, vec!["Een", "Twee"]);
    }

    #[test]
    fn half_offers_are_hidden_while_streaming() {
        assert_eq!(streaming_body("Hallo\n>"), "Hallo");
        assert_eq!(streaming_body("Hallo\n»"), "Hallo");
    }
}
