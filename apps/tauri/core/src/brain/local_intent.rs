//! Korte, vaste opdrachten ("volgende nummer", "volume 30", "open Firefox") doet Nook zelf, zonder het brein: meteen en
//! gratis. Alles wat niet past, gaat naar het brein.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "value")]
pub enum LocalIntent {
    /// play_pause, next, previous
    Media(String),
    Volume(u8),
    /// +10 of -10
    VolumeStep(i8),
    OpenApp(String),
    /// nook, agents, chat, connect, music
    ShowTab(String),
    WeekRecap,
    Time,
}

fn number(text: &str, re: &fancy_regex::Regex) -> Option<u32> {
    let caps = re.captures(text).ok()??;
    (1..caps.len()).rev().find_map(|i| caps.get(i).and_then(|m| m.as_str().parse().ok()))
}

impl LocalIntent {
    /// `installed_app` zoekt een app die echt op deze computer staat; "open Lisa's mail" valt zo vanzelf door naar het brein.
    pub fn parse(raw: &str, installed_app: &dyn Fn(&str) -> Option<String>) -> Option<Self> {
        let text = raw.to_lowercase();
        let text = text.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()).replace("  ", " ");
        if text.is_empty() || text.split(' ').count() > 7 {
            return None;
        }
        let polite = rx!(r"^(nook|hé nook|hey nook)[ ,]+").replace(&text, "").to_string();
        let polite = rx!(r"^(wil je|kun je|kan je|graag|please)\s+").replace(&polite, "").to_string();
        let polite = rx!(r"\s+(alsjeblieft|aub|graag|please)$").replace(&polite, "").to_string();
        let is = |pattern: &str| super::matches_pattern(&format!("^({pattern})$"), &polite);

        if is(r"(volgend[e]?|het volgende) ?(nummer|liedje|track)?|next( song| track)?|skip( dit)?( nummer)?") {
            return Some(Self::Media("next".into()));
        }
        if is(r"(vorig[e]?|het vorige) ?(nummer|liedje|track)?|previous( song| track)?") {
            return Some(Self::Media("previous".into()));
        }
        if is(
            r"pauze|pauzeer|pauzeer (de )?muziek|stop (de )?muziek|muziek (uit|stop)|pause( music)?|play|speel( verder| af)?|hervat|resume|muziek aan",
        ) {
            return Some(Self::Media("play_pause".into()));
        }
        if let Some(level) = number(&polite, rx!(r"^(zet )?(het )?(volume|geluid)( op| naar)? (\d{1,3})( ?%| procent)?$"))
            .or_else(|| number(&polite, rx!(r"^(set )?volume( to)? (\d{1,3})( ?%| percent)?$")))
        {
            return Some(Self::Volume(level.min(100) as u8));
        }
        if is(r"harder|luider|volume (omhoog|hoger)|louder|volume up") {
            return Some(Self::VolumeStep(10));
        }
        if is(r"zachter|stiller|volume (omlaag|lager)|quieter|volume down") {
            return Some(Self::VolumeStep(-10));
        }
        if is(r"(laat )?(mijn |de )?(agents|agenten)( zien| tab)?|(show )?agents") {
            return Some(Self::ShowTab("agents".into()));
        }
        if is(r"(open |toon )?(vandaag|today|nook|home|startpagina)") {
            return Some(Self::ShowTab("nook".into()));
        }
        if is(r"(open |toon )?(de )?chat") {
            return Some(Self::ShowTab("chat".into()));
        }
        if is(r"(open |toon )?(mijn |de )?(koppelingen|diensten|integraties|connections)( tab)?") {
            return Some(Self::ShowTab("connect".into()));
        }
        if is(r"(open |toon )?(de )?(muziek|music)( tab)?") {
            return Some(Self::ShowTab("music".into()));
        }
        if is(r"(mijn |het )?(weekoverzicht|week ?recap|weekrecap|weekly recap)|hoe was mijn week") {
            return Some(Self::WeekRecap);
        }
        if is(r"hoe laat is het|what time is it|tijd") {
            return Some(Self::Time);
        }
        if let Some(m) = rx!(r"^(open|start)\s+").find(&polite).ok().flatten() {
            let name = polite[m.end()..].trim();
            if !name.is_empty() && name.split(' ').count() <= 3 && !name.contains('/') && !name.contains('\\') {
                if let Some(app) = installed_app(name) {
                    return Some(Self::OpenApp(app));
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Option<LocalIntent> {
        LocalIntent::parse(text, &|name| (name == "firefox").then(|| "Firefox".to_string()))
    }

    #[test]
    fn quick_commands() {
        assert_eq!(parse("Volgende nummer"), Some(LocalIntent::Media("next".into())));
        assert_eq!(parse("nook, pauzeer de muziek"), Some(LocalIntent::Media("play_pause".into())));
        assert_eq!(parse("vorige"), Some(LocalIntent::Media("previous".into())));
        assert_eq!(parse("volume 30"), Some(LocalIntent::Volume(30)));
        assert_eq!(parse("Zet het volume op 250%"), Some(LocalIntent::Volume(100)));
        assert_eq!(parse("set volume to 15"), Some(LocalIntent::Volume(15)));
        assert_eq!(parse("harder"), Some(LocalIntent::VolumeStep(10)));
        assert_eq!(parse("open Firefox"), Some(LocalIntent::OpenApp("Firefox".into())));
        assert_eq!(parse("weekoverzicht"), Some(LocalIntent::WeekRecap));
        assert_eq!(parse("Hoe laat is het?"), Some(LocalIntent::Time));
        assert_eq!(parse("laat mijn agents zien"), Some(LocalIntent::ShowTab("agents".into())));
    }

    #[test]
    fn everything_else_goes_to_the_brain() {
        assert_eq!(parse("open de mail van Lisa"), None);
        assert_eq!(parse("open Spotify"), None);
        assert_eq!(parse("wat is het volume van een bol met straal 3"), None);
        assert_eq!(parse("speel iets rustigs van Bach voor me af alsjeblieft vanavond"), None);
    }
}
