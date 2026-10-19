//! Namen zoals mensen ze zeggen of typen: "spotfy" is Spotify, "lsia" is Lisa. Naar open-source code (aliassen,
//! precies, woorden, dan Levenshtein ≤ 2; MIT, © 2026 Louis Raillé; zie THIRD-PARTY-NOTICES.md).

use std::collections::BTreeSet;

use super::text::fold as lower;

/// Kleine letters, zonder accenten, scheidingstekens of een ".app"/".exe" aan het eind.
pub fn fold(text: &str) -> String {
    let mut out = lower(text);
    for suffix in [".app", ".exe", ".desktop"] {
        if let Some(stripped) = out.strip_suffix(suffix) {
            out = stripped.to_string();
        }
    }
    out.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
}

/// De bedoelde kandidaat, of niets als niets dichtbij genoeg is of twee even dichtbij zijn.
pub fn best(query: &str, candidates: &[String]) -> Option<String> {
    let wanted = fold(query);
    if wanted.is_empty() {
        return None;
    }
    let folded: Vec<(&String, String)> = candidates.iter().map(|c| (c, fold(c))).collect();
    let unique = |found: Vec<&String>| -> Option<String> {
        let names: BTreeSet<&String> = found.into_iter().collect();
        if names.len() == 1 {
            names.into_iter().next().cloned()
        } else {
            None
        }
    };
    let exact: Vec<&String> = folded.iter().filter(|(_, f)| *f == wanted).map(|(c, _)| *c).collect();
    if !exact.is_empty() {
        return unique(exact);
    }
    let squash = |s: &str| s.replace(' ', "");
    let joined: Vec<&String> = folded.iter().filter(|(_, f)| squash(f) == squash(&wanted)).map(|(c, _)| *c).collect();
    if !joined.is_empty() {
        return unique(joined);
    }
    let spaced = format!("{wanted} ");
    let prefix: Vec<&String> =
        folded.iter().filter(|(_, f)| f.starts_with(&spaced) || f.split(' ').any(|w| w == wanted)).map(|(c, _)| *c).collect();
    if !prefix.is_empty() {
        return unique(prefix);
    }
    // Typefouten: één fout in een korte naam, twee in een langere.
    let length = wanted.chars().count();
    if length < 4 {
        return None;
    }
    let allowed = if length >= 7 { 2 } else { 1 };
    let scored: Vec<(&String, usize)> = folded.iter().map(|(c, f)| (*c, distance(&wanted, f))).filter(|(_, d)| *d <= allowed).collect();
    let least = scored.iter().map(|(_, d)| *d).min()?;
    unique(scored.into_iter().filter(|(_, d)| *d == least).map(|(c, _)| c).collect())
}

/// Levenshtein-afstand (Wagner–Fischer), op tekens.
pub fn distance(a: &str, b: &str) -> usize {
    let x: Vec<char> = a.chars().collect();
    let y: Vec<char> = b.chars().collect();
    if x.is_empty() {
        return y.len();
    }
    if y.is_empty() {
        return x.len();
    }
    let mut previous: Vec<usize> = (0..=y.len()).collect();
    let mut current = vec![0; y.len() + 1];
    for i in 1..=x.len() {
        current[0] = i;
        for j in 1..=y.len() {
            current[j] = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + usize::from(x[i - 1] != y[j - 1]));
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[y.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apps() -> Vec<String> {
        ["Spotify", "Safari", "Google Chrome", "Rekenmachine", "Visual Studio Code", "Notities", "Notion"].map(String::from).to_vec()
    }

    #[test]
    fn finds_the_meant_name() {
        let apps = apps();
        assert_eq!(best("spotify", &apps).as_deref(), Some("Spotify"));
        assert_eq!(best("spotfy", &apps).as_deref(), Some("Spotify"));
        assert_eq!(best("chrome", &apps).as_deref(), Some("Google Chrome"));
        assert_eq!(best("rekenmachien", &apps).as_deref(), Some("Rekenmachine"));
        assert_eq!(best("Spotify.app", &apps).as_deref(), Some("Spotify"));
        assert_eq!(best("visualstudio code", &apps).as_deref(), Some("Visual Studio Code"));
    }

    #[test]
    fn does_not_guess() {
        let apps = apps();
        assert_eq!(best("Notie", &apps), None);
        assert_eq!(best("Mail", &apps), None);
        assert_eq!(best("saf", &apps), None);
    }

    #[test]
    fn levenshtein() {
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(distance("", "abc"), 3);
    }
}
