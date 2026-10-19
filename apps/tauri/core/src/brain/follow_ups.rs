//! Vervolgvoorstellen: het brein zet onder een antwoord hoogstens twee regels die met "»" beginnen, geschreven als wat
//! je tegen Nook zou zeggen ("» Zet dit in mijn agenda"). Nook haalt ze uit de tekst en toont ze als knoppen.

pub const MARKER: &str = "»";

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

/// De tekst zonder voorstellen, en de voorstellen zelf (hoogstens twee, zonder dubbele).
pub fn split(text: &str) -> (String, Vec<String>) {
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
    offers.truncate(2);
    (body.join("\n").trim().to_string(), offers)
}

/// Tijdens het streamen: alleen de tekst, ook als een voorstel nog maar half binnen is ("»" zonder tekst of ">" van ">>").
pub fn streaming_body(text: &str) -> String {
    let mut body = split(text).0;
    if let Some(last) = body.split('\n').next_back().map(str::trim).map(str::to_string) {
        if last == ">" || last == "-" {
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
    fn half_offers_are_hidden_while_streaming() {
        assert_eq!(streaming_body("Hallo\n>"), "Hallo");
        assert_eq!(streaming_body("Hallo\n»"), "Hallo");
    }
}
