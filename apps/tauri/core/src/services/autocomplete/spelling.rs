//! British or American spelling: a suggestion follows the one the user writes ("colour" in a text with "favourite",
//! "color" in one with "favorite"), never mixes the two. Decided per kind of difference, since they do not always go
//! together: Oxford spelling writes "organize" next to "colour". Ported from `CompletionSpelling.swift`.

use std::collections::{BTreeMap, HashMap};
use std::sync::LazyLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Variant {
    British,
    American,
}

/// The kinds of difference, each decided on its own evidence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Family {
    /// organise, analyse / organize, analyze
    Ise,
    /// colour, favourite / color, favorite
    Our,
    /// centre, theatre / center, theater
    Re,
    /// travelled, cancelling / traveled, canceling
    DoubledL,
    /// defence, catalogue, grey, aluminium and other single words
    Other,
}

/// What the user writes, per family. A family without its own evidence follows the others, except `Ise`: "-ize" is
/// British too (Oxford), so "colour" says nothing about it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Habit {
    pub families: BTreeMap<Family, Variant>,
}

impl Habit {
    pub fn is_empty(&self) -> bool {
        self.families.is_empty()
    }

    pub fn variant(&self, family: Family) -> Option<Variant> {
        if let Some(own) = self.families.get(&family) {
            return Some(*own);
        }
        if family == Family::Ise {
            return None;
        }
        let mut others = self.families.iter().filter(|(f, _)| **f != Family::Ise).map(|(_, v)| *v);
        let first = others.next()?;
        others.all(|v| v == first).then_some(first)
    }
}

struct Pair {
    british: String,
    american: String,
    family: Family,
}

/// The habit `text` shows: per family, the variant written clearly more often (four times or more).
pub fn habit(text: &str) -> Habit {
    let mut counts: HashMap<Family, (usize, usize)> = HashMap::new();
    for word in text.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()) {
        let Some((pair, variant)) = LOOKUP.get(word.to_lowercase().as_str()) else { continue };
        let tally = counts.entry(pair.family).or_default();
        if *variant == Variant::British {
            tally.0 += 1;
        } else {
            tally.1 += 1;
        }
    }
    let mut habit = Habit::default();
    for (family, (british, american)) in counts {
        if british > 0 && american * 4 <= british {
            habit.families.insert(family, Variant::British);
        } else if american > 0 && british * 4 <= american {
            habit.families.insert(family, Variant::American);
        }
    }
    habit
}

/// `suggestion` in the user's spelling. `before` is the text it goes behind: a word the suggestion finishes ("colo" +
/// "ur") is judged whole, and left alone when what is typed already says otherwise.
pub fn apply(habit: &Habit, suggestion: &str, before: &str) -> String {
    if habit.is_empty() || suggestion.is_empty() {
        return suggestion.to_string();
    }
    let typed: String = before.chars().rev().take_while(|c| c.is_alphabetic()).collect::<Vec<_>>().into_iter().rev().collect();
    let mut result = String::new();
    let mut word = String::new();
    let mut first = true;
    let flush = |word: &mut String, first: &mut bool, result: &mut String| {
        if word.is_empty() {
            return;
        }
        if *first && !typed.is_empty() {
            // The word started before the cursor: convert it whole, and keep only what comes after the typed part.
            let converted = convert(&format!("{typed}{word}"), habit);
            if converted.to_lowercase().starts_with(&typed.to_lowercase()) {
                result.extend(converted.chars().skip(typed.chars().count()));
            } else {
                result.push_str(word);
            }
        } else {
            result.push_str(&convert(word, habit));
        }
        word.clear();
        *first = false;
    };
    for c in suggestion.chars() {
        if c.is_alphabetic() {
            word.push(c);
        } else {
            flush(&mut word, &mut first, &mut result);
            first = false;
            result.push(c);
        }
    }
    flush(&mut word, &mut first, &mut result);
    result
}

/// One word in the habit's spelling, in the same case ("Colour" → "Color", "COLOUR" → "COLOR").
pub fn convert(word: &str, habit: &Habit) -> String {
    let Some((pair, variant)) = LOOKUP.get(word.to_lowercase().as_str()) else { return word.to_string() };
    let Some(wanted) = habit.variant(pair.family) else { return word.to_string() };
    if wanted == *variant {
        return word.to_string();
    }
    let target = if wanted == Variant::British { &pair.british } else { &pair.american };
    if word.chars().count() > 1 && word == word.to_uppercase() {
        return target.to_uppercase();
    }
    if word.chars().next().is_some_and(char::is_uppercase) {
        let mut chars = target.chars();
        return chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
    }
    target.clone()
}

/// Every pair, each word in all the forms that are written (organise, organised, organising, organisation…). The same
/// table as on the Mac.
static PAIRS: LazyLock<Vec<Pair>> = LazyLock::new(|| {
    let mut pairs = Vec::new();
    let mut add = |british: String, american: String, family: Family| pairs.push(Pair { british, american, family });
    // -ise / -ize: only stems where both are words; "advertise", "surprise", "exercise" are -ise everywhere.
    const ISE_STEMS: &[&str] = &[
        "organ",
        "real",
        "recogn",
        "apolog",
        "summar",
        "special",
        "emphas",
        "critic",
        "author",
        "minim",
        "maxim",
        "optim",
        "util",
        "categor",
        "character",
        "standard",
        "custom",
        "final",
        "visual",
        "memor",
        "modern",
        "normal",
        "personal",
        "general",
        "central",
        "capital",
        "digit",
        "familiar",
        "harmon",
        "jeopard",
        "legal",
        "local",
        "material",
        "mobil",
        "neutral",
        "global",
        "priorit",
        "symbol",
        "synchron",
        "sympath",
        "theor",
        "agon",
        "anonym",
        "fantas",
        "fertil",
        "galvan",
        "hospital",
        "ideal",
        "immun",
        "industrial",
        "initial",
        "internal",
        "liberal",
        "monopol",
        "moral",
        "patron",
        "polar",
        "popular",
        "rational",
        "revolution",
        "scrutin",
        "steril",
        "stabil",
        "subsid",
        "terror",
        "tranquil",
        "vandal",
        "victim",
        "colon",
        "democrat",
        "econom",
        "energ",
        "equal",
        "eulog",
        "random",
        "minimal",
        "commercial",
        "hypothes",
    ];
    for stem in ISE_STEMS {
        for (b, a) in [
            ("ise", "ize"),
            ("ises", "izes"),
            ("ised", "ized"),
            ("ising", "izing"),
            ("isation", "ization"),
            ("isations", "izations"),
            ("iser", "izer"),
            ("isers", "izers"),
        ] {
            add(format!("{stem}{b}"), format!("{stem}{a}"), Family::Ise);
        }
    }
    for stem in ["analy", "paraly", "cataly", "electroly"] {
        for (b, a) in [("se", "ze"), ("ses", "zes"), ("sed", "zed"), ("sing", "zing"), ("ser", "zer")] {
            add(format!("{stem}{b}"), format!("{stem}{a}"), Family::Ise);
        }
    }
    // -our / -or
    for stem in [
        "colo", "flavo", "favo", "hono", "humo", "labo", "neighbo", "behavio", "harbo", "rumo", "vapo", "vigo", "endeavo", "savo", "odo",
        "armo", "splendo", "parlo",
    ] {
        for suffix in ["", "s", "ed", "ing", "ful", "fully", "less", "able", "ite", "ites", "hood", "hoods", "al", "ally", "y"] {
            add(format!("{stem}ur{suffix}"), format!("{stem}r{suffix}"), Family::Our);
        }
    }
    // -re / -er
    for stem in ["cent", "theat", "fib", "lit", "calib", "somb", "spect", "lust", "sab", "manoeuv", "meag", "sepulch"] {
        let american = if stem == "manoeuv" { "maneuv" } else { stem };
        add(format!("{stem}re"), format!("{american}er"), Family::Re);
        add(format!("{stem}res"), format!("{american}ers"), Family::Re);
        if ["cent", "manoeuv"].contains(&stem) {
            add(format!("{stem}red"), format!("{american}ered"), Family::Re);
            add(format!("{stem}ring"), format!("{american}ering"), Family::Re);
        }
    }
    // Doubled l before -ed, -ing, -er
    for stem in [
        "travel", "cancel", "model", "label", "level", "signal", "fuel", "marvel", "counsel", "dial", "total", "quarrel", "channel",
        "funnel", "tunnel", "shovel", "snorkel", "unravel", "panel", "rival", "duel", "pedal",
    ] {
        for (b, a) in [("led", "ed"), ("ling", "ing"), ("ler", "er"), ("lers", "ers")] {
            add(format!("{stem}{b}"), format!("{stem}{a}"), Family::DoubledL);
        }
    }
    // Single words. Not here: pairs whose American spelling is another word in British too (cheque/check, storey/story,
    // programme/program, draught/draft, kerb/curb, licence/license).
    for (b, a) in [
        ("defence", "defense"),
        ("defences", "defenses"),
        ("offence", "offense"),
        ("offences", "offenses"),
        ("pretence", "pretense"),
        ("catalogue", "catalog"),
        ("catalogues", "catalogs"),
        ("catalogued", "cataloged"),
        ("analogue", "analog"),
        ("grey", "gray"),
        ("greys", "grays"),
        ("greyish", "grayish"),
        ("aluminium", "aluminum"),
        ("jewellery", "jewelry"),
        ("jeweller", "jeweler"),
        ("jewellers", "jewelers"),
        ("mould", "mold"),
        ("moulds", "molds"),
        ("plough", "plow"),
        ("sceptical", "skeptical"),
        ("sceptic", "skeptic"),
        ("sceptics", "skeptics"),
        ("paediatric", "pediatric"),
        ("encyclopaedia", "encyclopedia"),
        ("enrolment", "enrollment"),
        ("fulfilment", "fulfillment"),
        ("skilful", "skillful"),
        ("wilful", "willful"),
        ("instalment", "installment"),
        ("instalments", "installments"),
        ("pyjamas", "pajamas"),
        ("cosy", "cozy"),
        ("moustache", "mustache"),
        ("artefact", "artifact"),
        ("artefacts", "artifacts"),
        ("woollen", "woolen"),
        ("ageing", "aging"),
    ] {
        add(b.into(), a.into(), Family::Other);
    }
    pairs
});

/// Every spelling of every pair, with the pair and which variant it is.
static LOOKUP: LazyLock<HashMap<&'static str, (&'static Pair, Variant)>> = LazyLock::new(|| {
    let mut lookup = HashMap::new();
    for pair in PAIRS.iter().filter(|p| p.british != p.american) {
        lookup.insert(pair.british.as_str(), (pair, Variant::British));
        lookup.insert(pair.american.as_str(), (pair, Variant::American));
    }
    lookup
});

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_the_field_per_family() {
        let british = habit("My favourite colour is grey.");
        assert_eq!(british.variant(Family::Our), Some(Variant::British));
        assert_eq!(apply(&british, " flavor and behavior", "the "), " flavour and behaviour");
        assert_eq!(british.variant(Family::Ise), None);
        let american = habit("We will organize the center and analyze the color.");
        assert_eq!(apply(&american, " Organised, centred and travelled", "It was"), " Organized, centered and traveled");
        assert_eq!(convert("COLOUR", &american), "COLOR");
    }

    #[test]
    fn leaves_mixed_text_and_other_words_alone() {
        assert!(habit("colour color").is_empty());
        let american = habit("color");
        assert_eq!(apply(&american, " surprise and advertise the programme", "a"), " surprise and advertise the programme");
    }

    #[test]
    fn finishes_the_typed_word_in_the_users_variant() {
        let american = habit("favorite");
        assert_eq!(apply(&american, "ur scheme", "the colo"), "r scheme");
        assert_eq!(apply(&american, "r scheme", "the colou"), "r scheme");
    }
}
