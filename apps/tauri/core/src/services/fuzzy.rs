//! Een naam vinden die de gebruiker bedoelt ("rekenmachine" → "Rekenmachine", "spotfy" → "Spotify"). Zelfde regels
//! als `Fuzzy` op de Mac.

/// Kleine letters, zonder accenten, scheidingstekens of ".exe"/".desktop" aan het eind.
pub fn fold(text: &str) -> String {
    let mut out: String = text.to_lowercase().chars().map(strip_accent).collect();
    for suffix in [".app", ".exe", ".desktop", ".lnk"] {
        if let Some(stripped) = out.strip_suffix(suffix) {
            out = stripped.to_string();
        }
    }
    out.split(|c: char| !c.is_alphanumeric()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
}

fn strip_accent(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ç' => 'c',
        'ñ' => 'n',
        'ý' | 'ÿ' => 'y',
        other => other,
    }
}

/// De kandidaat die bedoeld is, of `None` als niets dichtbij genoeg is of twee even dichtbij zijn.
pub fn best(query: &str, candidates: &[String]) -> Option<String> {
    let wanted = fold(query);
    if wanted.is_empty() {
        return None;
    }
    let folded: Vec<(&String, String)> = candidates.iter().map(|c| (c, fold(c))).collect();
    let unique = |mut found: Vec<&String>| -> Option<String> {
        found.sort();
        found.dedup();
        (found.len() == 1).then(|| found[0].clone())
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
    let prefix: Vec<&String> =
        folded.iter().filter(|(_, f)| f.starts_with(&format!("{wanted} ")) || f.split(' ').any(|w| w == wanted)).map(|(c, _)| *c).collect();
    if !prefix.is_empty() {
        return unique(prefix);
    }
    // Tikfouten: één in een korte naam, twee in een langere.
    let length = wanted.chars().count();
    if length < 4 {
        return None;
    }
    let allowed = if length >= 7 { 2 } else { 1 };
    let scored: Vec<(&String, usize)> = folded.iter().map(|(c, f)| (*c, distance(&wanted, f))).filter(|(_, d)| *d <= allowed).collect();
    let least = scored.iter().map(|(_, d)| *d).min()?;
    unique(scored.into_iter().filter(|(_, d)| *d == least).map(|(c, _)| c).collect())
}

/// Levenshtein-afstand op tekens.
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
            let cost = usize::from(x[i - 1] != y[j - 1]);
            current[j] = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[y.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn finds_the_app_meant() {
        let apps = names(&["Rekenmachine", "Spotify", "Visual Studio Code", "Firefox Web Browser", "Terminal"]);
        assert_eq!(best("rekenmachine", &apps).as_deref(), Some("Rekenmachine"));
        assert_eq!(best("spotfy", &apps).as_deref(), Some("Spotify"));
        assert_eq!(best("code", &apps).as_deref(), Some("Visual Studio Code"));
        assert_eq!(best("firefox", &apps).as_deref(), Some("Firefox Web Browser"));
        assert_eq!(best("xy", &apps), None);
    }

    #[test]
    fn ties_give_nothing() {
        let apps = names(&["Notes", "Nodes"]);
        assert_eq!(best("Nohes", &apps), None);
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(fold("Café.exe"), "cafe");
    }
}
